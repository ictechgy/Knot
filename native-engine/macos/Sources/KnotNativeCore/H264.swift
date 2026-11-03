import Foundation

public struct AccessUnit: Sendable {
    public let nals: [Data]
    public let isIDR: Bool
    public let sps: [Data], pps: [Data]
    public let avcc: Data
    public init(annexB data: Data) throws {
        guard !data.isEmpty, data.count <= 4_194_287 else { throw NativeFailure.oversized }
        let parsed = try data.withUnsafeBytes { bytes in try Self.parse(bytes) }
        self.nals = parsed.nals; self.isIDR = parsed.isIDR; self.sps = parsed.sps; self.pps = parsed.pps
        // Construct once on the serial media reader, rather than copying and
        // growing this buffer during a MainActor decoder submission.
        var avcc = Data()
        avcc.reserveCapacity(parsed.nals.reduce(0) { $0 + 4 + $1.count })
        for nal in parsed.nals { avcc.appendBE(UInt32(nal.count)); avcc.append(nal) }
        self.avcc = avcc
    }
    // The borrowed buffer is zero-based even when Data is a nonzero-index slice.
    // Only owned NAL copies escape this closure; no whole-access-unit Array copy.
    private static func parse(_ bytes: UnsafeRawBufferPointer) throws -> (nals: [Data], isIDR: Bool, sps: [Data], pps: [Data]) {
        guard let base = bytes.baseAddress else { throw NativeFailure.malformed }
        func prefix(_ i: Int) -> Int {
            if i + 3 <= bytes.count, bytes[i] == 0, bytes[i+1] == 0, bytes[i+2] == 1 { return 3 }
            if i + 4 <= bytes.count, bytes[i] == 0, bytes[i+1] == 0, bytes[i+2] == 0, bytes[i+3] == 1 { return 4 }
            return 0
        }
        guard prefix(0) > 0 else { throw NativeFailure.malformed }
        var nals: [Data] = [], setsSPS: [Data] = [], setsPPS: [Data] = []
        var cursor = 0, hasIDR = false, hasSlice = false
        while cursor < bytes.count {
            let length = prefix(cursor)
            guard length > 0 else { throw NativeFailure.malformed }
            let begin = cursor + length
            cursor = begin
            while cursor < bytes.count && prefix(cursor) == 0 { cursor += 1 }
            var end = cursor
            // Annex B permits trailing_zero_8bits between/after NAL units.
            while end > begin && bytes[end-1] == 0 { end -= 1 }
            guard end > begin, nals.count < 128 else { throw NativeFailure.malformed }
            let nal = Data(bytes: base.advanced(by: begin), count: end - begin), type = bytes[begin] & 31
            guard bytes[begin] & 128 == 0, (1...23).contains(type) else { throw NativeFailure.malformed }
            if type == 7 || type == 8 {
                guard nal.count <= 65_536 else { throw NativeFailure.oversized }
                if type == 7 { guard setsSPS.count < 8 else { throw NativeFailure.oversized }; setsSPS.append(nal) }
                else { guard setsPPS.count < 8 else { throw NativeFailure.oversized }; setsPPS.append(nal) }
            }
            if type == 5 { hasIDR = true }; if type == 1 || type == 5 { hasSlice = true }
            nals.append(nal)
        }
        guard hasSlice else { throw NativeFailure.malformed }
        return (nals, hasIDR, setsSPS, setsPPS)
    }
}
