# Knot Native Engine — independent vertical slice

This experimental host/viewer uses **no Sunshine, Moonlight, Glimmer, browser, OpenSSH, relay service or external media executable**. It is a separate `Knot Native Preview` app so the existing Knot product remains available for comparison.

The Windows host uses DXGI Desktop Duplication and D3D11 SDR/NV12 processing, followed by an asynchronous **hardware-only Media Foundation H.264 encoder**. The macOS viewer owns its TLS transport, packet parser, VideoToolbox decoder and native AppKit/SwiftUI fullscreen/input surface. System frameworks, the .NET Framework and OS crypto/TLS implementations are reused. The Windows GPU path currently performs a readback before feeding hardware encoding; this is not a zero-copy claim.

## Scope

- Windows11 x64, including Home, logged-in unlocked **primary SDR landscape display**; supported hardware H.264 MFT required.
- AppleSilicon macOS26+ viewer; native fullscreen Space, keyboard/mouse and committed Unicode text.
- One peer, one display and one viewer window, bounded H.264/TLS-TCP stream, explicit host approval and temporary invitation trust.
- Existing production desktop/files/reverse/Linux apps are not modified or selected as an automatic fallback.

This is not the finished replacement for the current product. **Audio, files, saved pairing, automatic reconnect/update, headless displays, secure desktop/UAC/lock screen, HDR, rotation and multiple displays are out of scope.** The host cursor's separate DXGI overlay is not composited in v1. Fullscreen/input/IME, actual WindowsHome/GPU/driver and Wi-Fi performance require two-device acceptance. Hardware or TLS failure is not permission to silently switch to a weaker path.

## Connect

Use only a private network or an already configured Tailscale connection.

1. Install/open `Knot Native Preview` on Windows. Select its LAN/Tailscale address, click **Share**, then **Copy invitation**. Sharing creates a temporary identity and a secret invitation valid120seconds. It does not create a Sunshine account or start capture immediately.
2. Open the Mac native preview. Paste the invitation, review its address, compare the exact certificate pin with the Windows sharing window, and explicitly connect.
3. On Windows, review the observed peer address and claimed viewer label, then click **Approve**. The label and IP are context, not authenticated identity; keep the invitation secret. Native capture/input starts only after valid pinnedTLS, an unused invitation and this approval. The Mac reports streaming only after a decoded frame reaches its display surface.
4. **Stop / revoke all**, disconnect, window close or timeout ends this temporary permission and requests release of injected keys/buttons. Windows can refuse release during a desktop transition; retries are bounded, so successful OS cleanup is not guaranteed. Reconnection needs a new invitation; no old pairing or certificate is imported, reset or persisted.

The invitation is a secret capability, unlike the current product's address-only QR links. Copying it is an explicit user action. The apps do not automatically read the clipboard. Never put an actual invitation in an issue or log. [Wire and security contract](PROTOCOL.md).

The Windows Copy action requests the documented clipboard-history/cloud exclusions. This does not prevent other software from reading the current clipboard. Adapter choices show their names and LAN/private-overlay context, with a usable gateway-backed LAN preferred over a virtual adapter by default.

Normal Windows execution requires no elevation. Windows networking/application-control prompts may still apply. No firewall, port-forwarding, system security setting or existing service is changed by the app. Packages are development previews: Windows unsigned, Mac ad-hoc/unnotarized. Engine independence does not confer trusted platform signing.

## Build

Build from a committed clean checkout; the builder verifies exact source/archive bytes before compiling. Output is confined to its owned `build/native-engine/<platform>` directory.

```sh
python3 scripts/build_native_engine.py --platform macos
```

macOS needs Xcode command-line tools/Swift6 and the macOS26SDK or newer. The independent Swift package has no external package dependencies. Only synthetic/core/TLS checks run; the GUI is packaged but never launched by the builder.

On Windows, install VisualStudio C++x64 tools/WindowsSDK, .NET Framework4.8 reference assemblies/compiler, and InnoSetup. The optional `INNO_COMPILER` environment variable selects ISCC. Then:

```powershell
python scripts/build_native_engine.py --platform windows
```

The C++DLL, x64 managed host, native codec fixture and managed tests are compiled from source. Full builds inspect the setup's PE resources without running it: the product version must contain the full preview suffix and the numeric file/product revision must match this build. The result is recorded in `native-installer-metadata.json`. `--media-only` is a diagnostic mode that proves only DLL compilation and synthetic codec behavior. It is never a full host/app result.

The separate `Build independent native engine preview` workflow builds Windows first and supplies its **fresh software-MFT synthetic H.264 fixture and exported public test certificate** to the Mac tests. The Mac must decode all120frames using the actual independent VideoToolbox decoder, including bounded burst admission, and evaluate that Windows-generated certificate using its actual pin/trust implementation. No test private key is transferred. Test software encoding is never exposed as a normal host fallback. Both jobs run portable H.264 parser, pacing and activation-ownership harnesses; the Mac runs them with AddressSanitizer/UndefinedBehaviorSanitizer. Native Windows release media uses MSVC optimization.

## Evidence and limits

`NATIVE-INPUTS.json` records inputs only. A completed successful build writes `NATIVE-BUILD.json`, per-command stdout/stderr/argv, source manifest, product hashes and `SHA256SUMS`. Exact compiler and synthetic checks are distinguished from device acceptance. A green compile/codec/TLS fixture does not establish real hardware capture, input injection, Home runtime or end-to-end quality.

Runtime packet sizes, input actions and decoder work are capped. A single media writer applies socket backpressure before acquiring the next frame; input travels in the opposite TLS direction. Codec/device operations have application polling budgets but an in-process app cannot preempt a wedged OS/GPU call; hard isolation is future work. TCP is a deliberate first-slice transport with head-of-line/recovery tradeoffs, not a claimed replacement for a tuned real-time media stack.

Pending GPU readback is polled without submitting stale pixels or consuming the next capture period. After the encoder produces its first output, an unchanged desktop is repeated at most once per second, with the periodic IDR deadline preserved. Capture timestamps remain the original pixels' capture time; separate stream presentation time drives encoder timestamps and the two-second IDR target. Sample duration is the nominal frame interval, never the preceding idle gap. Windows reuses a bounded video payload buffer; the Mac parser avoids an extra full-access-unit copy. These are source/fixture-verified policies, not a measured hardware performance claim. [Preview changes](CHANGES.md).

The viewer waits up to65seconds of silence for approval/encoder startup and125seconds overall before Ready, then uses a10second silence budget and15second first-image deadline. The certificate's ±24hour validity window tolerates clock skew; the secret invitation still expires after120seconds and is one-use. Preclaim handshakes remain serial and bounded to10seconds/remaining invitation life, so a hostile private-network peer can still consume availability. Physical-device acceptance is required for startup time, high-DPI layout, scroll/IME feel and hardware codec behavior. Fixed input/codec queue limits do not measure end-to-end latency or OS socket buffering.

The protocol does not compare host/client monotonic timestamps as latency; independent clocks would need synchronization. Measure input-to-display/frame age, CPU/GPU, text/color and recovery on the same hardware/settings as the existing product before choosing the default engine.

## License

This experiment follows the repository's GPL-3.0-only license. Corresponding source is supplied with the previews. It does not link the existing vendored streaming engine. OS/platform codec capabilities and capture/input permissions remain required.
