# Native.13 playback audio

Native.13 can send the default Windows playback output to the connected Mac. Update both apps. Before starting a Windows share, explicitly select **Windows 재생 소리 포함 · 마이크 제외**. The checkbox is off on every app launch, including a relaunch after an update. Consent belongs to the current manually started share; a previous run's resume grant cannot enable audio. Stop/disconnect revokes audio with media.

This is WASAPI render-loopback capture, never microphone capture or a microphone fallback. It shares the default playback mix, with no per-app source selection or volume controls. Protected/DRM playback, every device format and a device change during a session are not guaranteed. The Mac speaker control mutes or restores the local player; it does not change Windows volume. Muting keeps receiving and draining packets.

An automatic registered-device reconnect that starts a fresh Windows share clears playback consent. To include sound again, stop that Windows share, select the playback checkbox and start sharing manually. Reauthenticating the audio connection within the same active share keeps that share's existing permission.

## Independent authority and transport

- TCP48636 is a separate TLS connection to the authenticated media host's same private IPv4 address, using the same exact certificate pin and strict macOS certificate policy. The Windows service restricts the connection to the current claimed media peer. No trust downgrade or replacement pin is accepted.
- Audio is available only for an active, audio-authorized media session. Capture starts only after a valid audio hello. Mac starts the optional connection asynchronously after media Ready, and creates its output engine only after authenticated TLS and audio Ready.
- Derive a32-byte audio key as `HMAC-SHA256(key: mediaInvitation.token32, message: UTF8("knot-audio-v1"))`. The audio endpoint retains the address, certificate pin and derived key, without retaining the original media token. Audio grants no input or file authority.
- Media-v1 Hello and Ready schemas are unchanged. An older server, refusal, unsupported audio, malformed packet, timeout or device failure affects audio only and never terminates the video session. Do not infer audio support from a video connection alone.

## Wire contract

Each audio envelope has a one-byte kind, a four-byte unsigned big-endian payload length and exactly that many payload bytes. The receiver validates the kind-specific cap before reading a body. A five-second read budget covers header and body together.

| Kind | Direction | Payload |
| --- | --- | --- |
| 1 hello | Mac → Windows | Strict JSON `{"v":1,"token":"<43-character base64url derived key>"}`, at most256bytes. |
| 2 ready | Windows → Mac | Strict JSON `{"v":1,"codec":"pcm-s16le","sampleRate":48000,"channels":2}`, at most256bytes. |
| 3 PCM | Windows → Mac | `sequence:u64BE`, `firstSampleIndex:u64BE`, `frames:u32BE`, then interleaved stereo signed16-bit little-endian PCM. |
| 4 heartbeat | Windows → Mac | Empty payload, sent about once per second while capture is idle. |
| 127 error | Windows → Mac | Strict JSON `{"code":"..."}`, at most128bytes. Codes are exactly `auth`, `closed`, `unavailable`, `protocol`, `timeout`. |

Ready must precede PCM and heartbeat and may occur only once. JSON rejects duplicate/unknown fields, wrong types and trailing bytes. Unknown kinds, truncated envelopes and invalid lengths terminate audio only.

PCM is fixed at48,000sample frames/second, two channels and16bits/channel:1,536,000bits/second before envelope/TLS/TCP overhead. A packet contains1–960frames; its exact payload size is `20 + frames * 4`, at most3,860bytes. Sequence starts at1 and increases exactly by1, with no wrap. Sample indices may have forward gaps but cannot overlap, move backward or overflow. A forward gap flushes stale playback.

## Bounded playback and acceptance

The output-only Mac player prebuffers960frames (20ms), caps queued audio at4,800frames (100ms), and flushes stale buffers on overflow or a sample gap. Generation-checked completion callbacks cannot decrement a later queue after flush/stop. Muting sets local output volume to zero without applying TCP backpressure. Stop cancels the reader, closes TLS, flushes queued audio and stops the owned player.

Audio and video have independent clocks and transport queues. This first slice provides no precise audiovisual synchronization, measured latency or performance guarantee. Separate connections still compete for shared network capacity.

Automated checks use fresh synthetic PCM/packets, fake capture and fake output sinks. They verify HMAC vectors, schema/framing/state limits, sequencing, sample bounds, queue flushing, mute and cancellation without capturing or playing real audio, opening microphones or enumerating user devices. Real Windows playback, Mac output, protected-content behavior, device changes and two-device audiovisual quality require separate device acceptance.
