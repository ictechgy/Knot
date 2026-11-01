# Experimental Windows media backend

The owned DLL uses only Windows SDK APIs. `kn_media.h` is the authoritative C
ABI: cdecl, pack4, 16-byte config and 36-byte info. Create/read/close must all run
on one dedicated MTA thread. The DLL balances its own COM and Media Foundation
startup after releasing its codec and capture interfaces. Info width/height are
encoded dimensions; left/top/desktopWidth/desktopHeight describe the physical
captured primary monitor before scaling, for pointer mapping.

Normal create enumerates **only** `MFT_ENUM_FLAG_HARDWARE`. It has no software
fallback or synthetic input entry point. Capture uses primary-monitor DXGI
Desktop Duplication on a hardware D3D11 device. An owned BGRA texture is scaled
and converted to limited-range BT.709 NV12 by the D3D11 video processor. An
asynchronous, nonblocking GPU staging readback supplies independently allocated,
aligned NV12 media buffers to the hardware H264 MFT. This deliberately accepts
one GPU-to-CPU copy to avoid coupling duplication-frame/texture reuse to a
vendor encoder's asynchronous lifetime. This is not a zero-copy performance
claim.

The hardware MFT must accept low-latency mode, a two-second GOP and periodic
force-keyframe requests. Baseline profile prevents reordered B frames. Event
polling is nonblocking, with at most two submitted samples and bounded event,
NAL, parameter-set and access-unit counts/sizes: at most 128 NALs per access unit,
8 SPS and 8 PPS, and 65,536 bytes per parameter-set NAL. Output is normalized to AnnexB;
SPS/PPS from MFT sequence headers or encoded samples are repeated for IDRs.
Native read refuses to return a flagged IDR without both SPS and PPS. A stalled
codec fails the session after two seconds of pending output; no raw/encoded
queue grows while a network writer is blocked.

Caller-owned MFT output scratch is separate from the compressed access-unit
limit. `MFT_OUTPUT_STREAM_INFO.cbSize` is the minimum required output allocation,
not the actual compressed sample length. The observed synthetic Windows 4K MFT
requests 15,552,000 bytes. `CodecOutputScratch` admits a minimum only within
`max(4,194,287, width × height × 3)` bytes after validating the dimensions, then
allocates only `max(4,194,287, cbSize)`. This is a finite two-NV12-frame budget:
at most 24,883,200 caller-visible bytes for 3840×2160. It is a resource policy,
not a guarantee about every encoder; a larger requirement fails explicitly.
Actual H.264 access units remain capped at 4,194,287 bytes and the video wire
payload at 4,194,304 bytes. Encoder in-flight capacity remains two.

The encoder retains the selected `IMFActivate` until teardown, including any
partially configured candidate until its failure cleanup. Enumeration releases
only candidates it never activated. Shutdown runs while transform interfaces
are still alive and owned references are released once. This does not depend
on the optional `DetachObject` method succeeding.

Capture results distinguish an unchanged desktop from a pending GPU readback.
The production `CapturePacer::Pump` polls pending readbacks on the next loop
iteration (normally 1 ms), without submitting old pixels or spending a frame
period. Reported pending readiness without progress fails the session after two
seconds; this does not make a wedged OS call interruptible. After the first encoder output, unchanged cached pixels are repeated at
one frame per second while capture readiness is still checked at the negotiated
frame rate. Fresh pixels bypass the idle-repeat limit. Startup retains bounded
full-rate priming until the first output; encoder backpressure still caps samples
in flight at two. These are source and pure-policy guarantees, not measured GPU
performance or latency claims.

Encoded media time advances from explicit monotonic stream presentation time,
independently of the original pixel capture timestamp retained in each video
packet. Repeated static pixels therefore keep their real capture timestamp while
their Media Foundation timestamps strictly increase. A keyframe is requested at
the first accepted sample and every two seconds of media time; a due request can
override the one-second idle repeat to avoid postponement by a recent update.
Each current sample uses the configured nominal frame duration, rounded down to
the whole-microsecond presentation-time grid (333,330 in 100ns units at 30fps).
The previous static gap is never assigned as a fresh frame's duration.
The synthetic codec fixture supplies explicit 30fps media times, so running it
faster than real time still tests 120 frames and the two-second IDR interval.
Video output must contain a type-1 or type-5 slice, and its keyframe flag is
derived from actual type-5 IDR content. Parameter-only sequence headers remain
valid internally. AnnexB trailing zero padding is trimmed before validation.

Read has a 450 ms application polling budget and uses `AcquireNextFrame(0)`,
`GetEvent(MF_EVENT_FLAG_NO_WAIT)` and `Map(DO_NOT_WAIT)`. COM and driver API calls
cannot be preempted in-process, so a defective driver can exceed that budget;
a hard OS-call deadline would require isolating media in another process. The
DLL never creates a worker that could outlive close or access freed buffers.

Unsupported rotation, HDR/advanced color, remote sessions, changed display
geometry, secure/locked/alternate input desktops and masked protected content
fail with fixed statuses. Device/access loss ends the session and requires a
new user-approved connection. The hardware cursor is not composited separately
in this first slice; adapters that return it separately can show video without
the host cursor. Real GPU/Home, cursor, color, lock/UAC and disconnect behavior
require manual hardware acceptance. No such acceptance is implied by CI.

## Build with VS 2022/Windows SDK, x64 Native Tools command prompt

Run from the repository root, with an existing owned output directory. `/MT`
keeps the CRT static. The integration script owns output-directory creation,
packaging, and errors. Use explicit source lists because the test files each
provide their own executable main.

```bat
cl /nologo /LD /EHsc /std:c++17 /MT /W4 /WX /utf-8 /DUNICODE /D_UNICODE /D_WIN32_WINNT=0x0A00 /DKN_MEDIA_EXPORTS native-engine\windows\media\media.cpp native-engine\windows\media\capture.cpp native-engine\windows\media\encoder.cpp native-engine\windows\media\h264.cpp /link /OUT:out\KnotNativeMedia.dll d3d11.lib dxgi.lib mfplat.lib mf.lib mfuuid.lib ole32.lib oleaut32.lib uuid.lib strmiids.lib user32.lib
cl /nologo /EHsc /std:c++17 /MT /W4 /WX /utf-8 /DUNICODE /D_UNICODE /D_WIN32_WINNT=0x0A00 native-engine\windows\media\synthetic_codec_test.cpp native-engine\windows\media\encoder.cpp native-engine\windows\media\h264.cpp /Fe:out\KnotNativeMediaSynthetic.exe /link mfplat.lib mf.lib mfuuid.lib ole32.lib oleaut32.lib uuid.lib strmiids.lib
out\KnotNativeMediaSynthetic.exe --software out\synthetic.h264 out\synthetic.json
```

The separately linked synthetic executable never includes `capture.cpp` or
`media.cpp`. `--software` explicitly selects the actual inbox synchronous H264
MFT; `--hardware` explicitly selects hardware. There is no implicit mode. It
creates 120 fresh 320x180 NV12 frames with changing pixels, requires actual
encoded output and periodic SPS/PPS/IDR, and writes an H264 fixture plus strict
JSON metadata containing `synthetic:true`, `captureInvoked:false`, the actual
`hardwareEncoder` value and every access-unit boundary/timestamp. Software VM
evidence proves codec framing only, not Desktop Duplication or hardware capture.

Portable parser check, including deterministic hostile synthetic bytes:

```sh
c++ -std=c++17 -Wall -Wextra -Werror -fsanitize=address,undefined -fno-omit-frame-pointer native-engine/windows/media/h264.cpp native-engine/windows/media/h264_parser_test.cpp -o /tmp/knot-native-h264-parser-test
/tmp/knot-native-h264-parser-test
c++ -std=c++17 -Wall -Wextra -Werror -fsanitize=address,undefined -fno-omit-frame-pointer native-engine/windows/media/media_pacing_test.cpp -o /tmp/knot-native-media-pacing-test
/tmp/knot-native-media-pacing-test
c++ -std=c++17 -Wall -Wextra -Werror -fsanitize=address,undefined -fno-omit-frame-pointer native-engine/windows/media/media_activation_test.cpp -o /tmp/knot-native-media-activation-test
/tmp/knot-native-media-activation-test
```

`media_pacing_test.cpp` calls the actual header-only production pacing and media
timeline policy with fresh fake capture readiness/pixels. It never links a
Windows, capture, input or codec implementation. It covers 1ms pending-to-fresh
progress without stale submission, reduced static encoding cadence, first-frame
and startup priming, backpressure/retry, monotonic media time and the two-second
IDR target including the explicit 120-frame fixture timeline.
The same production timeline also checks one-Hz static to active-60fps transitions
and the 120-frame fixture for nominal current-frame duration without inherited
idle gaps or three-tick rounding overlap.

`media_activation_test.cpp` exercises the exact production activation ownership
helpers with fresh fake references. It checks candidate failure, enumeration
cleanup after successful selection, replacement, repeated reset and teardown
without optional detach support. It uses no Windows, codec, capture or input API;
the separate synthetic MFT fixture and real hardware acceptance remain distinct.

## Primary API references

- [Desktop Duplication API](https://learn.microsoft.com/en-us/windows/win32/direct3ddxgi/desktop-dup-api)
- [Video processor input resource requirements](https://learn.microsoft.com/en-us/windows/win32/api/d3d11/nf-d3d11-id3d11videodevice-createvideoprocessorinputview)
- [Video processor SDR color space](https://learn.microsoft.com/en-us/windows/win32/api/d3d11/ns-d3d11-d3d11_video_processor_color_space)
- [MFT enumeration and hardware category](https://learn.microsoft.com/en-us/windows/win32/api/mfapi/nf-mfapi-mftenumex)
- [Asynchronous MFT event/lifetime model](https://learn.microsoft.com/en-us/windows/win32/medfound/asynchronous-mfts)
- [Optional activation detach behavior](https://learn.microsoft.com/en-us/windows/win32/api/mfobjects/nf-mfobjects-imfactivate-detachobject)
- [H264 encoder types and parameters](https://learn.microsoft.com/en-us/windows/win32/medfound/h-264-video-encoder)
- [MFT output minimum allocation](https://learn.microsoft.com/en-us/windows/win32/api/mftransform/ns-mftransform-mft_output_stream_info)
- [Owned aligned media buffer allocation](https://learn.microsoft.com/en-us/windows/win32/api/mfapi/nf-mfapi-mfcreatealignedmemorybuffer)
- [Low-latency property type](https://learn.microsoft.com/en-us/windows/win32/medfound/codecapi-avlowlatencymode)
- [Force-keyframe property type](https://learn.microsoft.com/en-us/windows/win32/medfound/codecapi-avencvideoforcekeyframe)
- [Current-sample duration contract](https://learn.microsoft.com/en-us/windows/win32/api/mfobjects/nf-mfobjects-imfsample-setsampleduration)
- [Media sample timestamp and duration meaning](https://learn.microsoft.com/en-us/windows/win32/medfound/working-with-media-samples)
