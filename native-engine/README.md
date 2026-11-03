# Knot Native Engine — independent vertical slice

This experimental host/viewer uses **no Sunshine, Moonlight, Glimmer, browser, OpenSSH, relay service or external media executable**. It is a separate `Knot Native Preview` app so the existing Knot product remains available for comparison.

Windows uses DXGI Desktop Duplication, D3D11 SDR/NV12 processing and a **hardware-only Media Foundation H.264 encoder**. Mac owns its OS TLS transport, strict parser, VideoToolbox decoder and native AppKit/SwiftUI desktop. A pinned, vendored BoringSSL crypto library provides short-code enrollment; it is compiled into the app, never downloaded at startup. Windows currently reads back GPU pixels before hardware encoding; this is not a zero-copy claim.

## Scope

- Windows11 x64/Home, logged-in unlocked primary SDR landscape display; supported hardware H.264 MFT required.
- AppleSilicon macOS26+ viewer; one peer, one display, one window and bounded H.264/TLS-TCP.
- Windows Share authorizes one holder of the current short code. Advanced legacy invitation mode retains its separate approval step.
- Native fullscreen, pointer/keyboard input and committed Mac input-method text. Source aspect ratio is preserved.

**Audio, files, saved pairing, automatic reconnect/update, headless/virtual displays, secure desktop/UAC/lock screen, HDR, rotation and multiple displays remain unsupported.** Existing production desktop/files/reverse/Linux apps remain separate. The host cursor's separate DXGI overlay is not composited. Real GPU/Home, input/IME, fullscreen and network quality require device acceptance; codec or TLS failure does not select a weaker backend.

## Connect

Native.6 targets the reported delay between an immediate local Mac pointer and a following Windows window at4K60: serial video parsing/AVCC preparation runs away from the UI actor, input TCP uses `noDelay`, input selection follows pacing, and Windows uses a session-owned high-resolution poll timer. Actual timer measurements and a separate4K60 software-codec interoperability fixture are recorded by CI. Update both apps. These changes do not claim measured two-device latency, remove GPU readback or guarantee every GPU can sustain4K60.

Use a private network or an already configured Tailscale connection. The Korean interface follows the Quiet Sidebar design, with advanced settings and help secondary.

1. Open `Knot Native Preview` on Windows and start sharing. The eight-digit number lasts120seconds and authorizes one matching Mac for screen/input. Quality is frozen for that run: maximum4K/30fps/40Mbps by default, optional maximum4K/60fps/40Mbps or1080p/60fps/20Mbps compatibility mode.
2. On Mac, find nearby PCs, select the candidate, enter the number and connect. Discovery names/addresses are unverified context. PAKE and directional authenticated encryption transfer the complete secret invitation; the Mac then opens a **new** existing TLS connection with its exact full DER pin and OS certificate checks. The provisioning socket never becomes media.
3. This explicitly preauthorized code-holder path requires no second Windows approval. Capture/input still starts only after the valid, unused T2 claim on pinned TLS, and Mac reports streaming only after a decoded image is presented.
4. Stop, disconnect, window close or timeout revokes this permission and requests release of owned injected input. Windows can refuse release during desktop transitions; retries are bounded. Reconnect with a new number. There is no saved pairing or silent certificate repair.

LAN broadcast does not discover devices across Tailscale. A secondary explicit private/Tailscale IPv4 entry can send a bounded unicast discovery query. Advanced legacy mode starts a distinct new Windows run: copy its full invitation, review address/pin on Mac, then explicitly approve on Windows. Changing modes cancels the prior slot/grant; old legacy tokens are never preapproved.

The number and invitation are secret capabilities. Neither is advertised or logged; clipboard copy is explicit and neither app automatically reads the clipboard. Copy requests Windows clipboard-history/cloud exclusions, which cannot prevent other software reading the current clipboard. [Media contract](PROTOCOL.md), [enrollment contract](ENROLLMENT.md).

A received frame may reach3840×2160 without upscaling a lower-resolution source. True4K therefore requires a4K Windows desktop; the app does not change display modes or create a virtual monitor. Actual GPU4K/60 support is device-dependent and unsupported hardware fails honestly.

Fullscreen removes reserved toolbar/footer height. Floating controls provide disconnect, native fullscreen exit and actual received dimensions. One desktop/presenter remains mounted; genuine source/viewer ratio differences still letterbox. Ordinary typing uses the Mac input method by default, preserving local Caps Lock language/capitalization behavior. Physical-keyboard fallback is secondary. Focus loss/revocation cancels composition and rejects late commits; physical shortcuts and owned key-ups remain separate from Unicode text.

Normal Windows execution needs no elevation. OS private-network/application-control prompts may apply; the app changes no firewall, forwarding or system-security setting. Media TCP48631, enrollment TCP48632 and discovery UDP48633 remain private-network services. Packages are development previews: Windows unsigned, Mac ad-hoc/unnotarized.

## Build

Use a committed clean checkout. The builder checks source/archive parity and confines output to its owned `build/native-engine/<platform>` directory.

```sh
python3 scripts/build_native_engine.py --platform macos
```

Mac needs Xcode/Swift6, macOS26SDK+ and CMake3.22+. `KNOT_NATIVE_CMAKE` selects a trusted CMake executable if it is not on PATH. The builder compiles pinned vendored crypto first and supplies its owned static-library directory; no external Swift packages are fetched. The production GUI is packaged, never launched by the builder.

Windows needs VisualStudio C++x64 tools/WindowsSDK, CMake3.22+, .NET Framework4.8 compiler/reference assemblies and InnoSetup (`INNO_COMPILER` may select ISCC):

```powershell
python scripts/build_native_engine.py --platform windows
```

Both native DLLs, the C#5 host and fresh test executables are built from source. Setup PE resources are inspected without execution: full preview version and numeric revision must match. `--media-only` is diagnostic, never complete app acceptance.

The native CI workflow builds Windows first, then Mac. It transfers fresh software-MFT fixtures and a public test DER certificate, never a private key. Actual VideoToolbox tests decode the existing120-frame burst and an additional six-frame3840×2160 fixture within their slot bounds. Software encoding exists only in the separate synthetic executable, not as a runtime fallback. Both platforms run native crypto known-answer/state/authentication checks and upstream SPAKE2 tests. Portable H.264 parser/pacing/resolution/activation checks use ASan/UBSan on Mac; native Windows release media is optimized.

## Evidence and limits
The encoder retains at most two in-flight samples and the decoder three outstanding images. MFT output scratch is distinct from compressed size: the chosen resource budget is two validated NV12 frames (at most24,883,200bytes at4K), while allocation is only max(AUlimit, reported minimum). This supports the actual15,552,000byte software-MFT minimum observed in the4K fixture; it is not a guarantee for every encoder. The compressed wire envelope remains4MiB and existing NAL limits still apply. This is not permission for larger wire frames or unbounded queues.


`NATIVE-INPUTS.json` records inputs only. A completed successful build writes `NATIVE-BUILD.json`, per-command stdout/stderr/argv, source manifest, product hashes and `SHA256SUMS`. Exact compiler and synthetic checks are distinguished from device acceptance. A green compile/codec/TLS fixture does not establish real hardware capture, input injection, Home runtime or end-to-end quality.

Runtime packet sizes, input actions and decoder work are capped. A single media writer applies socket backpressure before acquiring the next frame; input travels in the opposite TLS direction. Codec/device operations have application polling budgets but an in-process app cannot preempt a wedged OS/GPU call; hard isolation is future work. TCP is a deliberate first-slice transport with head-of-line/recovery tradeoffs, not a claimed replacement for a tuned real-time media stack.

Full builds also render fresh synthetic UI states from the actual view sources. `native-ui-visual-checks.json` binds the renderer, assets, image hashes and layout checks; the separate `native-macos-ui` and `native-windows-ui` CI artifacts contain those images. These fixtures never enter the production app entry point, connect a host, create certificates, read the clipboard or capture an existing screen. A successful render is not a visual approval: human inspection is recorded separately, and real display/input/DPI behavior still needs device acceptance.

Pending GPU readback is polled without submitting stale pixels or consuming the next capture period. After the encoder produces its first output, an unchanged desktop is repeated at most once per second, with the periodic IDR deadline preserved. Capture timestamps remain the original pixels' capture time; separate stream presentation time drives encoder timestamps and the two-second IDR target. Sample duration is the nominal frame interval, never the preceding idle gap. Windows reuses a bounded video payload buffer; the Mac parser avoids an extra full-access-unit copy. These are source/fixture-verified policies, not a measured hardware performance claim. [Preview changes](CHANGES.md).

The viewer waits up to65seconds of silence for approval/encoder startup and125seconds overall before Ready, then uses a10second silence budget and15second first-image deadline. The certificate's ±24hour validity window tolerates clock skew; the secret invitation still expires after120seconds and is one-use. Preclaim handshakes remain serial and bounded to10seconds/remaining invitation life, so a hostile private-network peer can still consume availability. Physical-device acceptance is required for startup time, high-DPI layout, scroll/IME feel and hardware codec behavior. Fixed input/codec queue limits do not measure end-to-end latency or OS socket buffering.

The protocol does not compare host/client monotonic timestamps as latency; independent clocks would need synchronization. Measure input-to-display/frame age, CPU/GPU, text/color and recovery on the same hardware/settings as the existing product before choosing the default engine.

## License

The app follows the repository GPL-3.0-only license. Corresponding source includes the exact pinned BoringSSL source and its Apache-2.0/support-code notices. It does not link the existing vendored streaming engine. OS codec capabilities and capture/input permissions remain required.

When distributing the preview installers, publish the generated corresponding-source archive and its SHA256SUMS alongside them. Individual check JSON files describe only their substeps; a successful complete build also requires the matching NATIVE-BUILD.json and product hashes.
