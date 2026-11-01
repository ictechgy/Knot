# Native preview changes

## 0.1.0-native.2

- Decoder admission waits within its three-slot bound, including decoded images awaiting MainActor delivery. Cancellation wakes the reader; documented dropped-frame completions retire safely. The Windows-generated120-frame synthetic fixture now also exercises burst submission.
- Physical keys retain ownership through text/IME modifier changes. Mouse moves coalesce only across consecutive moves; scroll/key/button actions remain order barriers. Wheel units, zero deltas, keypad Enter/Divide, recovery status and focused drag release are handled explicitly.
- Windows shows the exact current-run certificate pin and socket-observed peer IPv4, with a claimed viewer label explicitly marked unverified. Run-bound presentation rejects stale callbacks.
- The input receiver permits a bounded1000-envelope delivery burst while retaining a500/s refill limit. Adapter choices include friendly context and prefer a usable LAN; host messages, DPI layout and embedded branding are clearer.
- Pending readback never causes a stale submission or advances the frame interval. Static repeats fall to1fps after first output; media timestamps and the2second IDR deadline remain coherent. Native release media is optimized and parser/pacing harnesses run in CI, with ASan/UBSan on macOS.
- Windows-generated public DER and its independently generated pin are evaluated by the actual Mac trust implementation. Clock-skew tolerance is separate from the unchanged120second, one-use invitation policy. Startup waiting is stage-aware and remains bounded.

Update both host and viewer to this preview. Existing pairing/state is not imported. Real hardware capture/encoding, actual application input, two-device quality/latency and trusted platform signing remain device/distribution acceptance gates. In-process OS/GPU calls cannot be forcibly preempted; the bounded private-network preclaim handshake remains an availability tradeoff.

Unconfirmed encoder-alignment, physical-repeat and supplementary-Unicode hypotheses were not used to rewrite working platform behavior. Separate hardware/API evidence is required before those changes.
