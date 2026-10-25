// SPDX-License-Identifier: GPL-3.0-only
// The runner injects immutable baseline and current production extensions here.
// All access units are generated below; no decoder, display, app or network runs.
import Foundation
import CoreMedia
import Darwin

__PRODUCTION__

private struct Fixture {
    let name: String
    let input: Data
    let expectedAVCC: Data
    let expectedBuffers: [(Int, Data)]
    let hevc: Bool
}

private struct PRNG {
    var value: UInt64 = 0x53b9_401d_62ca_77e3
    mutating func next() -> UInt64 {
        value ^= value << 13; value ^= value >> 7; value ^= value << 17
        return value
    }
}

private enum Failure: Error, CustomStringConvertible {
    case check(String)
    var description: String { switch self { case let .check(message): return message } }
}

// The harness is synchronous and creates no threads/tasks.
nonisolated(unsafe) private var checks = 0
private func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try condition() else { throw Failure.check(message) }
    checks += 1
}

private func kind(_ value: DecodeBuffer.Kind) -> Int {
    switch value { case .picData: return 0; case .sps: return 1; case .pps: return 2; case .vps: return 3 }
}

private func bufferPairs(_ values: [DecodeBuffer]) -> [(Int, Data)] { values.map { (kind($0.kind), $0.data) } }
private func same(_ lhs: [(Int, Data)], _ rhs: [(Int, Data)]) -> Bool {
    lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
}

private func prefix(_ value: Int) -> [UInt8] {
    [UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16),
     UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)]
}

/// A fixture constructor with an independent oracle: boundaries are known before
/// encoding, so expected bytes never come from a copy of the production scanner.
private func fixture(name: String, bytes: Int, slices: Int, dense: Bool = false,
                     hevc: Bool = false, keyframe: Bool = false) -> Fixture {
    var random = PRNG()
    var nals: [(code: [UInt8], payload: Data, kind: Int)] = []
    func add(_ type: UInt8, _ payloadSize: Int, _ bufferKind: Int) {
        var payload = Data([hevc ? type << 1 : type])
        if hevc { payload.append(1) }
        while payload.count < payloadSize {
            if dense {
                payload.append(contentsOf: [0, 0, 3, 0, 0, 3, 1, 2])
            } else if payload.count % 1031 < 4 {
                payload.append(contentsOf: [0, 0, 3, UInt8(random.next() % 4)])
            } else { payload.append(UInt8(random.next() % 255 + 1)) }
        }
        if payload.count > max(hevc ? 2 : 1, payloadSize) { payload = Data(payload.prefix(payloadSize)) }
        // Annex-B trailing_zero_8bits are intentionally covered separately.
        if payload.count > (hevc ? 2 : 1) { payload[payload.count - 1] = 0x7f }
        nals.append((nals.count % 2 == 0 ? [0, 0, 0, 1] : [0, 0, 1], payload, bufferKind))
    }
    if keyframe {
        add(hevc ? 35 : 9, 5, 0)  // AUD before parameters
        add(hevc ? 39 : 6, 13, 0) // SEI must remain in picture order
        if hevc { add(32, 17, 3) }
        add(hevc ? 33 : 7, 23, 1)
        add(hevc ? 34 : 8, 11, 2)
        add(hevc ? 39 : 6, 9, 0) // Interleaved metadata
        add(hevc ? 33 : 7, 29, 1) // Repeated parameter: last wins
    }
    let overhead = nals.reduce(0) { $0 + $1.code.count + $1.payload.count } + slices * 4
    let perSlice = max(hevc ? 2 : 1, (bytes - overhead) / max(1, slices))
    for _ in 0..<slices { add(hevc ? (keyframe ? 19 : 1) : (keyframe ? 5 : 1), perSlice, 0) }
    var input = Data(), avcc = Data(), picture = Data(), parameters: [Int: Data] = [:]
    for nal in nals {
        let encoded = Data(nal.code) + nal.payload
        input.append(encoded)
        avcc.append(contentsOf: prefix(nal.payload.count)); avcc.append(nal.payload)
        if nal.kind == 0 { picture.append(encoded) } else { parameters[nal.kind] = encoded }
    }
    var expected: [(Int, Data)] = []
    for type in [3, 1, 2] { if let value = parameters[type] { expected.append((type, value)) } }
    expected.append((0, picture))
    return Fixture(name: name, input: input, expectedAVCC: avcc, expectedBuffers: expected, hevc: hevc)
}

private func format() throws -> CMVideoFormatDescription {
    var result: CMVideoFormatDescription?
    let status = CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault,
        codecType: kCMVideoCodecType_H264, width: 16, height: 16,
        extensions: nil, formatDescriptionOut: &result)
    guard status == noErr, let result else { throw Failure.check("synthetic format description: \(status)") }
    return result
}

private func contents(_ sample: CMSampleBuffer?) throws -> Data {
    guard let sample, let block = CMSampleBufferGetDataBuffer(sample) else {
        throw Failure.check("missing sample/block buffer")
    }
    let length = CMBlockBufferGetDataLength(block)
    var result = Data(count: length)
    if length > 0 {
        let status = result.withUnsafeMutableBytes { raw in
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: raw.baseAddress!)
        }
        guard status == noErr else { throw Failure.check("sample copy: \(status)") }
    }
    return result
}

@inline(never) private func candidateSample(_ decoder: CandidateVideoDecoder, _ input: Data,
                                           _ timestamp: UInt32) -> CMSampleBuffer? {
    __CANDIDATE_SAMPLE__
}
@inline(never) private func baselineSample(_ decoder: BaselineVideoDecoder, _ input: Data,
                                          _ timestamp: UInt32) -> CMSampleBuffer? {
    decoder.makeSampleBuffer(rawData: decoder.convertAnnexBToAVCC(input), rtpTimestamp: timestamp)
}

private func correctness(_ baseline: BaselineVideoDecoder, _ candidate: CandidateVideoDecoder) throws -> [String: Any] {
    let fixtures = [
        fixture(name: "H264-aud-sei-last-wins", bytes: 512, slices: 4, keyframe: true),
        fixture(name: "HEVC-aud-sei-last-wins", bytes: 2048, slices: 4, hevc: true, keyframe: true),
        fixture(name: "mixed-startcodes", bytes: 1024, slices: 32),
        fixture(name: "emulation-prevention", bytes: 8192, slices: 4, dense: true),
        fixture(name: "large-retention", bytes: 2 * 1024 * 1024, slices: 32),
        fixture(name: "8MiB-IDR", bytes: 8 * 1024 * 1024, slices: 32, keyframe: true)
    ]
    for value in fixtures {
        let oldDepacketizer = BaselineVideoDepacketizer(isHEVC: value.hevc)
        let newDepacketizer = CandidateVideoDepacketizer(isHEVC: value.hevc)
        try expect(same(bufferPairs(oldDepacketizer.splitAnnexBParamSets(value.input)), value.expectedBuffers), "baseline typed oracle: \(value.name)")
        try expect(same(bufferPairs(newDepacketizer.splitAnnexBParamSets(value.input)), value.expectedBuffers), "candidate typed oracle: \(value.name)")
        try expect(baseline.convertAnnexBToAVCC(value.input) == value.expectedAVCC, "baseline AVCC oracle: \(value.name)")
        let expectedIDR = value.expectedBuffers.contains { $0.0 == (value.hevc ? 3 : 1) }
        try expect(BaselineVideoDepacketizer.isIdrFrameStart(value.input, hevc: value.hevc) == expectedIDR,
                   "baseline IDR independent oracle")
        try expect(CandidateVideoDepacketizer.isIdrFrameStart(value.input, hevc: value.hevc) == expectedIDR,
                   "candidate IDR independent oracle")
        let trailingEmpty = value.input + Data([0, 0, 1])
        try expect(same(bufferPairs(newDepacketizer.splitAnnexBParamSets(trailingEmpty)), value.expectedBuffers),
                   "trailing empty NAL does not become picture or parameter")
        try expect(try contents(candidateSample(candidate, trailingEmpty, 12)) == value.expectedAVCC,
                   "trailing empty NAL does not enter AVCC")
        for timestamp: UInt32 in [0, 90_001, UInt32.max] {
            let old = baselineSample(baseline, value.input, timestamp)
            let new = candidateSample(candidate, value.input, timestamp)
            try expect(try contents(old) == value.expectedAVCC, "baseline sample byte oracle: \(value.name)")
            try expect(try contents(new) == value.expectedAVCC, "candidate sample byte oracle: \(value.name)")
            for sample in [old!, new!] {
                try expect(CMSampleBufferGetNumSamples(sample) == 1, "one compressed sample")
                try expect(CMSampleBufferGetSampleSize(sample, at: 0) == value.expectedAVCC.count, "compressed sample size")
                let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                if timestamp == 0 { try expect(!pts.isValid, "zero RTP means unavailable PTS") }
                else { try expect(pts == CMTime(value: Int64(timestamp), timescale: 90_000), "90kHz host RTP PTS") }
            }
        }
        // Keep the sample alive while the caller mutates/releases its input.
        // Force a separate allocation: sharing fixture.input would let COW
        // accidentally keep a borrowed, unowned production pointer alive.
        var mutableInput = value.input.withUnsafeBytes { Data(bytes: $0.baseAddress!, count: $0.count) }
        let retained = candidateSample(candidate, mutableInput, 12)
        mutableInput.resetBytes(in: mutableInput.startIndex..<mutableInput.endIndex)
        mutableInput.removeAll(keepingCapacity: false)
        try expect(try contents(retained) == value.expectedAVCC, "CoreMedia owns input independently")
        __NONZERO_SLICE_CHECK__
    }
    let malformed: [[UInt8]] = [[], [0], [0, 0], [0, 0, 1], [0, 0, 0, 1],
        [0, 0, 1, 5, 0, 0, 1], [0, 0, 1, 7, 0, 0, 0, 1, 8, 0, 0, 1],
        [99, 0, 0, 1, 1, 2], [0, 0, 0, 0, 1, 5, 0, 0], [0, 0, 1, 5, 0, 0, 0, 0, 1, 6],
        [0, 0, 1, 9, 0, 0, 1, 6, 0, 0, 0, 1, 7, 1, 0, 0, 1, 8, 1, 0, 0, 1, 5, 1]]
    var random = PRNG()
    var fuzz = malformed.map(Data.init)
    for index in 0..<1500 {
        let count = Int(random.next() % 193)
        var bytes = (0..<count).map { _ in UInt8(random.next() % (index % 2 == 0 ? 4 : 256)) }
        if count > 8 && index % 3 == 0 {
            let offset = Int(random.next() % UInt64(count - 4))
            bytes.replaceSubrange(offset..<(offset + 4), with: [0, 0, 1, UInt8(random.next() % 64)])
        }
        fuzz.append(Data(bytes))
    }
    for (index, value) in fuzz.enumerated() {
        let expected = baseline.convertAnnexBToAVCC(value)
        let old = baselineSample(baseline, value, 123)
        let new = candidateSample(candidate, value, 123)
        try expect((old == nil) == (new == nil), "sample acceptance differential \(index)")
        if let old, let new {
            try expect(try contents(old) == expected, "baseline differential bytes \(index)")
            try expect(try contents(new) == expected, "candidate differential bytes \(index)")
        }
        for hevc in [false, true] {
            let old = BaselineVideoDepacketizer(isHEVC: hevc).splitAnnexBParamSets(value)
            let new = CandidateVideoDepacketizer(isHEVC: hevc).splitAnnexBParamSets(value)
            try expect(same(bufferPairs(old), bufferPairs(new)), "typed split differential \(index) hevc=\(hevc)")
            let oldIDR = BaselineVideoDepacketizer.isIdrFrameStart(value, hevc: hevc)
            let newIDR = CandidateVideoDepacketizer.isIdrFrameStart(value, hevc: hevc)
            try expect(oldIDR == newIDR, "IDR detection differential \(index)")
        }
    }
    // AV1/default raw path must not gain Annex-B conversion.
    let rawBytes = (0..<4096).map { UInt8(truncatingIfNeeded: $0) } + [0x12, 0x00, 0x00, 0x01, 0x7f, 0x03]
    var raw = Data(rawBytes)
    let expectedRaw = Data(rawBytes)
    let oldRawSample = baseline.makeSampleBuffer(rawData: raw, rtpTimestamp: 900)
    let rawSample = candidate.makeSampleBuffer(rawData: raw, rtpTimestamp: 900)
    try expect(try contents(rawSample) == raw, "default raw AV1 path unchanged")
    try expect(try contents(oldRawSample) == raw, "baseline raw path")
    try expect(CMSampleBufferGetSampleSize(rawSample!, at: 0) == expectedRaw.count, "raw path sample size")
    try expect(CMSampleBufferGetPresentationTimeStamp(rawSample!) == CMTime(value: 900, timescale: 90_000), "raw path PTS")
    raw.resetBytes(in: raw.startIndex..<raw.endIndex)
    raw.removeAll(keepingCapacity: false)
    try expect(try contents(rawSample) == expectedRaw, "raw sample owns bytes independently")
    try expect(try contents(oldRawSample) == expectedRaw, "baseline raw sample owns bytes independently")
    return ["checks": checks, "generated_oracle_fixtures": fixtures.count,
            "malformed_and_fuzz_cases": fuzz.count, "nonzero_data_slice": __SLICE_STATUS__]
}

private enum Path: String { case baseline, candidate }
private enum Operation: String { case sample, split }

/// Observation is deliberately constant-cost: sample length plus four retained
/// samples, or typed buffer count/size. No byte copy/hash/oracle in timed loops.
@inline(never) private func timed(_ path: Path, operation: Operation, input: Data,
                                  baseline: BaselineVideoDecoder, candidate: CandidateVideoDecoder,
                                  baselineSplit: BaselineVideoDepacketizer,
                                  candidateSplit: CandidateVideoDepacketizer,
                                  iterations: Int) throws -> (ns: UInt64, checksum: UInt64) {
    var retained = [CMSampleBuffer?](repeating: nil, count: 4)
    var checksum: UInt64 = 0
    let start = DispatchTime.now().uptimeNanoseconds
    switch operation {
    case .sample:
        if path == .baseline {
            for index in 0..<iterations {
                guard let sample = baselineSample(baseline, input, UInt32(index + 1)) else { throw Failure.check("baseline timed sample") }
                retained[index & 3] = sample
                checksum &+= UInt64(CMSampleBufferGetTotalSampleSize(sample))
            }
        } else {
            for index in 0..<iterations {
                guard let sample = candidateSample(candidate, input, UInt32(index + 1)) else { throw Failure.check("candidate timed sample") }
                retained[index & 3] = sample
                checksum &+= UInt64(CMSampleBufferGetTotalSampleSize(sample))
            }
        }
    case .split:
        if path == .baseline {
            for _ in 0..<iterations {
                let buffers = baselineSplit.splitAnnexBParamSets(input)
                checksum &+= UInt64(buffers.count)
                for buffer in buffers { checksum &+= UInt64(buffer.data.count + kind(buffer.kind)) }
            }
        } else {
            for _ in 0..<iterations {
                let buffers = candidateSplit.splitAnnexBParamSets(input)
                checksum &+= UInt64(buffers.count)
                for buffer in buffers { checksum &+= UInt64(buffer.data.count + kind(buffer.kind)) }
            }
        }
    }
    let elapsed = DispatchTime.now().uptimeNanoseconds - start
    withExtendedLifetime(retained) {}
    return (elapsed, checksum)
}

@main private struct VideoPrepareBenchmark {
    static func main() throws {
        let baseline = BaselineVideoDecoder(), candidate = CandidateVideoDecoder()
        baseline.formatDescription = try format(); candidate.formatDescription = try format()
        let correctness = try correctness(baseline, candidate)
        var output: [String: Any] = ["correctness": correctness,
            "scope": "Synthetic compressed H264/HEVC preparation only. No decoder, capture, display, transport or full-session/FPS/input-to-photon measurement."]
        if CommandLine.arguments.contains("--benchmark") {
            var rows: [[String: Any]] = []
            var checksum: UInt64 = 0
            for bytes in [512, 32 * 1024, 256 * 1024, 2 * 1024 * 1024] {
                for slices in [1, 4, 32] {
                    for dense in [false, true] {
                        for operation in [Operation.sample, .split] {
                            let value = fixture(name: "\(bytes)-\(slices)-\(dense ? "dense" : "sparse")", bytes: bytes,
                                                slices: slices, dense: dense, keyframe: operation == .split)
                            let oldSplit = BaselineVideoDepacketizer(isHEVC: false)
                            let newSplit = CandidateVideoDepacketizer(isHEVC: false)
                            func run(_ path: Path, _ count: Int) throws -> (ns: UInt64, checksum: UInt64) {
                                try timed(path, operation: operation, input: value.input, baseline: baseline,
                                          candidate: candidate, baselineSplit: oldSplit,
                                          candidateSplit: newSplit, iterations: count)
                            }
                            // Calibrate against both paths, then use identical batch sizes.
                            let calibrationCount = max(2, min(128, 2 * 1024 * 1024 / bytes))
                            let calibrationOld = try run(.baseline, calibrationCount)
                            let calibrationNew = try run(.candidate, calibrationCount)
                            let slowerNS = Double(max(calibrationOld.ns, calibrationNew.ns)) / Double(calibrationCount)
                            let iterations = max(2, min(100_000, Int(12_000_000 / max(1, slowerNS))))
                            for warmup in 0..<2 {
                                for path in warmup % 2 == 0 ? [Path.baseline, .candidate] : [.candidate, .baseline] {
                                    checksum &+= try run(path, iterations).checksum
                                }
                            }
                            var pairs: [[String: Any]] = []
                            for repetition in 0..<7 {
                                let order: [Path] = repetition % 2 == 0 ? [.baseline, .candidate] : [.candidate, .baseline]
                                var pair: [String: Any] = ["repetition": repetition, "order": order.map(\.rawValue), "iterations": iterations]
                                for path in order {
                                    let result = try run(path, iterations)
                                    checksum &+= result.checksum
                                    pair[path.rawValue + "_ns_total"] = result.ns
                                    pair[path.rawValue + "_ns_per_op"] = Double(result.ns) / Double(iterations)
                                    pair[path.rawValue + "_checksum"] = result.checksum
                                }
                                pairs.append(pair)
                            }
                            let old = pairs.map { $0["baseline_ns_per_op"] as! Double }.sorted()
                            let new = pairs.map { $0["candidate_ns_per_op"] as! Double }.sorted()
                            rows.append(["operation": operation.rawValue, "requested_bytes": bytes,
                                "actual_input_bytes": value.input.count, "slices": slices,
                                "pattern": dense ? "dense-emulation-prevention" : "sparse-zeros",
                                "paired_repetitions": pairs,
                                "baseline_ns_per_op": ["min": old.first!, "median": old[3], "max": old.last!],
                                "candidate_ns_per_op": ["min": new.first!, "median": new[3], "max": new.last!],
                                "baseline_over_candidate_median": old[3] / new[3]])
                        }
                    }
                }
            }
            output["benchmark"] = rows; output["checksum"] = checksum
            output["measurement"] = ["paired_repetitions": 7, "warmup_pairs": 2,
                "target_batch_ns": 12_000_000, "maximum_batch_iterations": 100_000,
                "percentiles": "No p95/p99 estimated from seven repetitions.",
                "observation": "Constant-cost size/count checksum and four retained CoreMedia samples; no oracle copy/hash in timed loop."]
        }
        let data = try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
        FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data([10]))
    }
}
