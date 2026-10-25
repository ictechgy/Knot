# Desktop stream color

Knot's Mac client interprets Sunshine's ordinary Rec.709 SDR desktop streams as
sRGB desktop code values. This avoids applying a video transfer interpretation to
already encoded desktop RGB values, which can lift midtones on macOS. The change
affects presentation metadata; it does not increase saturation, rewrite YUV
planes, add a per-frame image conversion, or change wire encoding or encryption.

The reusable engine keeps its source-preserving default. The Mac desktop shell
explicitly selects `SDRColorMode.desktopSRGB` in the same connection configuration
used to create the decoder. The policy applies only when HDR control is off,
resolved primaries and matrix are both Rec.709, the resolved transfer is Rec.709,
and no explicit gamma is present. Missing transfer tags qualify only for an
8-bit stream using the existing Rec.709 fallback. PQ, HLG, HDR inference,
explicit gamma, other transfers and other gamuts
retain their existing interpretation. Transfer and the derived `CGColorSpace`
are attached coherently before constructing the display sample's format.

The **decoded output pixel format** remains authoritative for quantization range.
VideoToolbox currently outputs video-range YUV, even though the network request
asks for full range. Relabeling that output as full range would raise black levels
and compress contrast. The policy does not relabel range.

## Evidence and limits

The pinned Sunshine revision
[`63d35f702ee9e362e43263742981836ec0710384`](https://github.com/LizardByte/Sunshine/tree/63d35f702ee9e362e43263742981836ec0710384)
declares [Rec.709 transfer for SDR](https://github.com/LizardByte/Sunshine/blob/63d35f702ee9e362e43263742981836ec0710384/src/video_colorspace.cpp#L92)
while the [ordinary RGB conversion shader](https://github.com/LizardByte/Sunshine/blob/63d35f702ee9e362e43263742981836ec0710384/src_assets/windows/assets/shaders/directx/include/convert_base.hlsl)
uses the desktop RGB values without a transfer-curve conversion. Apple's
[transfer-function documentation](https://developer.apple.com/documentation/corevideo/image-buffer-transfer-function-constants)
describes these tags as inputs to color matching. This policy addresses that
desktop-capture convention rather than redefining Rec.709 video generally.

`python3 scripts/tests/test_video_color.py` compiles the complete production color
resolver and attachment code with inert lifecycle leaves, using real CoreVideo,
CoreMedia and CoreImage. Fresh 8/10-bit full/video-range buffers exercise gray
ramps, black/white endpoints, RGB patches, unmodified plane bytes, coherent sample
format tags, source-preserving mode, explicit-metadata exclusions and HDR-to-SDR
cache/attachment cleanup. On the development Mac, the original interpretation
renders synthetic neutral 128 as sRGB 139. Desktop interpretation preserves it
within quantization tolerance; the measured maximum gray error is one 8-bit level.

These checks do not capture a real desktop or establish visual acceptance through
AVSampleBufferDisplayLayer on every display. Host HDR, ICC profiles, display
calibration, True Tone and Night Shift can still affect perceived matches. Device
acceptance should compare a freshly generated sRGB gray ramp and color chart on
the host and client, including window/full-screen and HDR-to-SDR transitions.

Resolution/bitrate controls remain up to 4K60 and 100 Mbps. The Mac client still
negotiates 8-bit 4:2:0 H.264/HEVC. Higher bitrate cannot correct a transfer mismatch;
10-bit and 4:4:4 require separate host/profile and hardware validation before they
can be advertised safely.
