# Native preview changes

## 0.1.0-native.3

- Scan H.264 access units through borrowed bytes instead of an extra full-buffer array copy; NAL data remains independently owned and all parser limits are unchanged. Sliced-data regression checks cover nonzero source indices and lifetime independence.
- Reuse one bounded Windows video payload buffer, writing only its valid prefix. Consecutive different-size frame checks reject stale trailing bytes and invalid lengths before an envelope is emitted. Authentication comparison explicitly retains its full-length loop across JIT optimization/inlining.
- Retain each selected Media Foundation activation until encoder teardown, without depending on the optional `DetachObject` method. A portable production-policy fixture checks failed candidates, successful selection, replacement and repeated cleanup; real hardware acceptance remains separate.
- Use one Mac window for the one-session/one-surface preview. Sustained presentation backpressure gets a status message after two seconds, clears after successful display and preserves the input recovery state.
- Windows installation metadata now shows the full preview version; numeric PE versions and the Mac bundle revision advance together. The Windows builder reads the newly built setup's version resources and rejects mismatches without executing the installer.

These are source, synthetic-fixture and build changes. Parser microbenchmarks do not measure actual streaming latency or hardware performance. The v1 wire format and temporary consent/trust model are unchanged; the device and signing gates below still apply.

## 0.1.0-native.2

- Decoder admission waits within its three-slot bound, including decoded images awaiting MainActor delivery. Cancellation wakes the reader; documented dropped-frame completions retire safely. The Windows-generated120-frame synthetic fixture now also exercises burst submission.
- Physical keys retain ownership through text/IME modifier changes. Mouse moves coalesce only across consecutive moves; scroll/key/button actions remain order barriers. Wheel units, zero deltas, keypad Enter/Divide, recovery status and focused drag release are handled explicitly.
- Windows shows the exact current-run certificate pin and socket-observed peer IPv4, with a claimed viewer label explicitly marked unverified. Run-bound presentation rejects stale callbacks.
- The input receiver permits a bounded1000-envelope delivery burst while retaining a500/s refill limit. Adapter choices include friendly context and prefer a usable LAN; host messages, DPI layout and embedded branding are clearer.
- Pending readback never causes a stale submission or advances the frame interval. Static repeats fall to1fps after first output; media timestamps and the2second IDR deadline remain coherent. Native release media is optimized and parser/pacing harnesses run in CI, with ASan/UBSan on macOS.
- Windows-generated public DER and its independently generated pin are evaluated by the actual Mac trust implementation. Clock-skew tolerance is separate from the unchanged120second, one-use invitation policy. Startup waiting is stage-aware and remains bounded.

Update both host and viewer to this preview. Existing pairing/state is not imported. Real hardware capture/encoding, actual application input, two-device quality/latency and trusted platform signing remain device/distribution acceptance gates. In-process OS/GPU calls cannot be forcibly preempted; the bounded private-network preclaim handshake remains an availability tradeoff.

Unconfirmed encoder-alignment, physical-repeat and supplementary-Unicode hypotheses were not used to rewrite working platform behavior. Separate hardware/API evidence is required before those changes.
