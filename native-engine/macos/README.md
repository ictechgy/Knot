# Knot Native Preview — standalone Mac viewer

Experimental Apple Silicon macOS 26+ application. This package has no dependencies on Glimmer, Moonlight, Sunshine or the production Knot app. Swift 6 language mode is required. System Network/Security, VideoToolbox, AVFoundation, SwiftUI and AppKit implement transport, decoding and presentation.

From the repository root:

```sh
swift build -c release --package-path native-engine/macos --scratch-path build/native-engine/macos
swift test --package-path native-engine/macos --scratch-path build/native-engine/macos
```

`KnotNativePreview` is the executable product; `KnotNativeCore` contains strict invitation/JSON/framing, H.264 structure and input policy. The repository's separate preview packager creates the `.app`; these commands never launch its UI. No existing preferences, clipboard, keys, screens, histories or private caches are test inputs.

Paste a fresh secret invitation into the secure field using the normal user action, review its private IPv4 and exact certificate pin, then explicitly connect. The TLS verifier requires the pinned leaf DER, sole leaf trust anchor, current validity, server-auth purpose and DNS `knot-native`, without trust network fetch. After the one-use Hello, the app shows host approval pending, then encoder ready, then the first locally decoded/presented image. Nothing persists pairing/trust or reconnects automatically. The standalone preview is unsigned unless separately signed and is not a production release.

The native view uses aspect-fit image/input coordinates and a real fullscreen Space. Physical mode maps common ANSI keys, modifiers, navigation, function and numeric keypad keys to Windows set-1 codes. Committed-text mode uses `NSTextInputClient` for local IME composition and sends committed Unicode only; composition is bounded, is never sent before commit, and has no remote preedit protocol. Control-arrow remains a Mac Space shortcut. Layout-specific keys, Korean/other IME behavior, remote shortcuts and pointer behavior need actual two-device acceptance. No global hooks, clipboard synchronization or audio are present.

The input queue caps 256 queued actions/16 KiB, coalesces unsent mouse movement and latches recovery after saturation or focus loss. A click explicitly restores input. Focus loss and close revoke pending actions and send ReleaseAll; disconnect waits for the single writer before a final best-effort ReleaseAll, and TLS closure independently causes host-side release. One reader and one writer share the full-duplex TLS channel, with bounded reads/writes, two-second heartbeats and ten-second peer inactivity handling. Each pending operation owns a cancellable timer; completed fragment reads retain no deadline backlog. Host approval has an independent 60-second deadline and Ready has a 15-second first-decoded-image deadline, so heartbeats alone never establish streaming success. H.264 allocation/parameter-set/dimension limits and three in-flight VideoToolbox requests bound decoder work. Late callbacks from invalidated decoder generations cannot display frames.

Tests use malformed/duplicate/oversize protocol cases, fresh in-memory certificate trust checks, a real fresh loopback TLS peer and mismatched pin, an inert transport lifecycle and a fresh 64×64 synthetic software-H.264 encode/real decoder round trip. Software encoding exists only inside that named test. Runtime never falls back to software host capture/encoding or to another engine. No app window, screen capture, real keyboard injection or user data is involved in these tests.

Cross-platform CI also sets `KNOT_NATIVE_WINDOWS_FIXTURES` to the fresh Windows media-test artifact directory containing `synthetic.h264` and `synthetic-codec.json`. The Mac test validates all 120 bounded Annex B access units and decodes actual 320×180 pixels serially through the runtime decoder, including periodic SPS/PPS+IDR. Missing or invalid files fail when the variable is set; without it the cross-platform test is explicitly skipped. This synthetic MF→VT result is separate from Windows hardware capture/encoding acceptance.

Unverified device gates: real Windows 11 Home Desktop Duplication/hardware MF encoding, HDR/rotation failure behavior, LAN/Tailscale/Wi-Fi latency, macOS fullscreen rendering, keyboard layouts, IME, focus transitions and signed distribution. Host timestamps are recorded as host monotonic values, never claimed as one-way latency.
