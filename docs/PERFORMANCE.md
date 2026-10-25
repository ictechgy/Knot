# Streaming preparation performance

This work targets CPU preparation of compressed video on the Mac. Synthetic
results describe these functions, not total remote-desktop latency, delivered FPS,
encoder performance, network speed or superiority over another product.

## Critical path and changes

Video packets are authenticated and owned before RTP/FEC queuing. The receive
thread completes blocks and access units, including IDR parameter splitting,
before handing a frame to the serial decode queue. That queue prepares a sample
for asynchronous VideoToolbox decoding; decoded frames then pass through the
bounded pacer to the display layer.

Two existing copies were removed:

| Path | Previous work | Current work |
| --- | --- | --- |
| IDR parameter splitting on the receive thread | Whole access unit copied to an array, scalar boundary scan, temporary `subdata` for each NAL, then picture-NAL concatenation | Borrow bytes only during `withUnsafeBytes`, scan bounded raw pointers, copy parameter sets and append picture spans directly into one reserved output |
| H.264/HEVC sample preparation on the decode queue | Build AVCC/HVCC `Data`, allocate a CoreMedia block, copy the converted frame into that block | Determine NAL spans/output size and write length prefixes and payloads directly into one CoreMedia-owned block |

The block is allocated and checked for contiguous writable memory before it is
filled. No source pointer escapes `withUnsafeBytes`, and asynchronous decoder
retention owns the block rather than borrowing Swift storage. Sample size and RTP
PTS come from the completed block and original timestamp. AV1 keeps its raw-OBU
input semantics and an owned block.

Reference APIs: Apple's [block-buffer memory allocation](https://developer.apple.com/documentation/coremedia/cmblockbuffercreatewithmemoryblock(allocator:memoryblock:blocklength:blockallocator:customblocksource:offsettodata:datalength:flags:blockbufferout:))
and the [upstream WebRTC NAL rewriter](https://webrtc.googlesource.com/src/+/ce5c7eff7373220a4912eccb456927d1e721549d/sdk/objc/components/video_codec/nalu_rewriter.cc)
show the owned-block/direct-write pattern. These references establish ownership
and construction semantics, not a measured speedup for Knot.

## Reproduce the validation

```sh
python3 scripts/benchmarks/video_prepare.py --checks-only
python3 scripts/benchmarks/video_prepare.py --benchmark --output /tmp/knot-video-preparation-new-run
```

Use a new output directory for each benchmark. The tool compiles the production
functions with release optimization and compares them with immutable source
snapshots from `a9bd368f9281ac0c6c0d9cf140604b16ebb1d462`. Pinned baseline files
and hashes allow offline checks in a shallow CI checkout. Generated independent
oracles and differential malformed-input checks validate bytes, parameter routing,
mixed start-code lengths, repeated parameter sets, sample size, RTP PTS, raw OBU
behavior and ownership after source mutation/release. No actual codec decoding,
capture, display, connection, preferences or existing media is involved.

Timing excludes fixture generation and expected-byte comparisons. Seven paired
repetitions alternate baseline/candidate order after two warmup pairs, using the
same batch size for each pair. Results preserve raw samples and report median,
minimum and maximum; seven repetitions do not establish p95/p99. A small checksum
consumes outputs, and a bounded set of samples remains retained to exercise block
lifetime. Check source/compiler provenance and unchanged input hashes before
using results. CI enforces correctness, not machine-specific microsecond limits.

## Other findings and tradeoffs

- After an out-of-order packet disables the RTP append fast path, subsequent
  insertions scan pending entries. A bounded block-relative occupancy structure
  could reduce worst-case quadratic work. It needs dedicated sequence-wrap,
  duplicate, parity and actual Reed-Solomon recovery differential tests first.
- Receive timing takes a lock per packet. Batch-local histogram accumulation
  could reduce lock frequency, but must preserve all observations, reporting/reset
  boundaries and the one-packet fallback's cost.
- Disabled frame tracing still takes a shared-state lock at lookup. That lock
  protects tracker lifetime; an unmanaged atomic pointer is not a safe substitute.
- Packet storage must survive socket-buffer reuse while FEC/deferred packets are
  pending. Removing ownership copies without a lifetime design would be unsafe.
- SFTP currently waits for each 64 KiB response. Its existing benchmark identifies
  delay sensitivity; pipeline comparisons require calibrated serialization,
  reordering, cancellation, server limits and video-fairness tests.
- The pacer FIFO is already bounded at six entries. Its short `removeFirst`
  operations are a lower priority than frame-sized copying. HUD pixel sampling
  requires an enabled overlay and a nonempty sampling rectangle; it is not an
  established active Knot bottleneck in this source snapshot.

These findings do not justify increasing decode/pacer queues, dropping undecoded
reference frames, weakening authentication, altering color interpretation or
blindly changing bitrate. Actual host-to-display and input-to-visible gains need
same-device tests with fresh synthetic content and an observed connection path.
