import Foundation

public enum Kind: UInt8, Sendable {
    case hello = 1, ready = 2, video = 3, hostHeartbeat = 4
    case key = 0x20, text = 0x21, pointer = 0x22, wheel = 0x23, releaseAll = 0x24, heartbeat = 0x25, explorerDrag = 0x26, clipboardRequest = 0x30, clipboardResponse = 0x31, qualityPreference = 0x32, qualityFeedback = 0x33, qualityStatus = 0x34, videoControl = 0x35, videoControlStatus = 0x36, error = 0x7f
}
public struct Packet: Sendable, Equatable {
    public let kind: Kind
    public let payload: Data
    public init(kind: Kind, payload: Data = Data()) { self.kind = kind; self.payload = payload }
    public var wireByteCount: Int { payload.count + 5 }
    public var encoded: Data {
        var bytes = Data([kind.rawValue]); bytes.appendBE(UInt32(payload.count)); bytes.append(payload); return bytes
    }
    public static func serverHeader(_ bytes: Data) throws -> (Kind, Int) {
        guard bytes.count == 5, let kind = Kind(rawValue: bytes[bytes.startIndex]) else { throw NativeFailure.malformed }
        let size = Int(bytes.readBE(UInt32.self, at: 1))
        switch kind {
        case .ready: guard (1...4096).contains(size) else { throw NativeFailure.oversized }
        case .video: guard (18...4_194_304).contains(size) else { throw NativeFailure.oversized }
        case .hostHeartbeat: guard size == 0 else { throw NativeFailure.malformed }
        case .qualityStatus: guard size == 9 else { throw NativeFailure.malformed }
        case .videoControlStatus: guard size == 45 else { throw NativeFailure.malformed }
        case .clipboardResponse: guard (18...ClipboardProtocol.maximumTextBytes + 18).contains(size) else { throw NativeFailure.oversized }
        case .error: guard (1...128).contains(size) else { throw NativeFailure.oversized }
        default: throw NativeFailure.malformed
        }
        return (kind, size)
    }
}

public enum VideoLimits {
    public static let maximumWidth = 3840
    public static let maximumHeight = 2160
    public static let maximumPixels = 8_294_400
    public static func accepts(width: Int, height: Int) -> Bool {
        (16...maximumWidth).contains(width) && (16...maximumHeight).contains(height) &&
        width % 2 == 0 && height % 2 == 0 && width * height <= maximumPixels
    }
}

public struct Ready: Sendable, Equatable {
    public let width: Int, height: Int, fps: Int, bitrate: Int
    public let files: NativeFileOffer?
    public let clipboardVersion: Int
    public let qualityVersion: Int
    public let trustedVersion: Int
    public let videoControlVersion: Int
    public init(_ bytes: Data) throws {
        let base: Set<String> = ["v", "codec", "width", "height", "fps", "bitrate", "hardwareEncoder"]
        let fileKeys: Set<String> = ["filesVersion", "filePort", "fileToken", "fileRootName"]
        let extensions: [String] = ["clipboardVersion", "qualityVersion", "trustedVersion", "videoControlVersion"]
        var parsed: [String: JSONValue]?
        // Only these complete schemas are accepted; unknown/partial features fail closed.
        for mask in 0..<16 {
            let featureKeys = Set(extensions.enumerated().compactMap { mask & (1 << $0.offset) != 0 ? $0.element : nil })
            for files in [false, true] {
                let keys = base.union(featureKeys).union(files ? fileKeys : [])
                if let candidate = try? StrictJSON.object(bytes, keys: keys, limit: 4096) { parsed = candidate }
            }
        }
        guard let json = parsed else { throw NativeFailure.malformed }
        if json["filesVersion"] != nil {
            guard try json.integer("filesVersion") == 2 else { throw NativeFailure.unsupported }
            files = try NativeFileOffer(port: json.integer("filePort"), token: json.string("fileToken"), rootName: json.string("fileRootName"))
        } else { files = nil }
        func version(_ key: String) throws -> Int {
            guard json[key] != nil else { return 0 }
            guard try json.integer(key) == 1 else { throw NativeFailure.unsupported }; return 1
        }
        clipboardVersion = try version("clipboardVersion")
        qualityVersion = try version("qualityVersion")
        trustedVersion = try version("trustedVersion")
        videoControlVersion = try version("videoControlVersion")
        guard videoControlVersion == 0 || qualityVersion == 1 else { throw NativeFailure.malformed }
        let width = try json.integer("width"), height = try json.integer("height")
        let fps = try json.integer("fps"), bitrate = try json.integer("bitrate")
        guard try json.integer("v") == 1, try json.string("codec") == "h264-annexb", try json.boolean("hardwareEncoder"),
              VideoLimits.accepts(width: width, height: height),
              (1...60).contains(fps), (1_000_000...40_000_000).contains(bitrate) else { throw NativeFailure.malformed }
        self.width = width; self.height = height; self.fps = fps; self.bitrate = bitrate
    }
}

public struct VideoPacket: Sendable {
    public let sequence: UInt64, captureMicroseconds: UInt64
    public let accessUnit: AccessUnit
    public init(_ bytes: Data, after previous: UInt64) throws {
        guard (18...4_194_304).contains(bytes.count) else { throw NativeFailure.oversized }
        sequence = bytes.readBE(UInt64.self, at: 0); captureMicroseconds = bytes.readBE(UInt64.self, at: 8)
        let flags = bytes[bytes.startIndex + 16]
        guard sequence > previous, previous != 0 || sequence == 1, flags & ~1 == 0 else { throw NativeFailure.malformed }
        accessUnit = try AccessUnit(annexB: Data(bytes.dropFirst(17)))
        guard accessUnit.isIDR == (flags == 1) else { throw NativeFailure.malformed }
    }
}

public struct ReceiveState: Sendable {
    public private(set) var ready: Ready?
    public private(set) var sequence: UInt64 = 0
    public private(set) var videoControl = VideoControlReceiveState()
    private let offeredVideoControlVersion: Int
    public init(videoControlVersion: Int = 0) { offeredVideoControlVersion = videoControlVersion }
    public mutating func expectVideoControl(_ request: VideoControlRequest) throws {
        guard ready?.videoControlVersion == 1 else { throw NativeFailure.state }
        try videoControl.expect(request)
    }
    public mutating func accept(_ packet: Packet) throws -> VideoPacket? {
        switch packet.kind {
        case .ready:
            guard ready == nil else { throw NativeFailure.state }
            let candidate = try Ready(packet.payload)
            guard candidate.videoControlVersion <= offeredVideoControlVersion else { throw NativeFailure.state }
            ready = candidate
            videoControl.start(profile: VideoConfiguration(width: candidate.width, height: candidate.height, fps: candidate.fps, bitrate: candidate.bitrate))
        case .video:
            guard ready != nil else { throw NativeFailure.state }
            let video = try VideoPacket(packet.payload, after: sequence)
            try videoControl.acceptVideo(video)
            sequence = video.sequence; return video
        case .videoControlStatus:
            guard ready?.videoControlVersion == 1 else { throw NativeFailure.state }
            try videoControl.accept(VideoControlStatus(packet.payload), sequence: sequence)
        case .hostHeartbeat: guard packet.payload.isEmpty else { throw NativeFailure.malformed }
        case .qualityStatus:
            guard ready?.qualityVersion == 1, packet.payload.count == 9,
                  (1...60).contains(packet.payload.readBE(UInt32.self, at: 0)),
                  (1_000_000...40_000_000).contains(packet.payload.readBE(UInt32.self, at: 4)),
                  packet.payload.last! <= 1 else { throw NativeFailure.malformed }
            videoControl.acceptQuality(fps: Int(packet.payload.readBE(UInt32.self, at: 0)), bitrate: Int(packet.payload.readBE(UInt32.self, at: 4)))
        case .clipboardResponse:
            guard ready?.clipboardVersion == 1 else { throw NativeFailure.state }
            _ = try ClipboardResponse(packet.payload)
        case .error:
            let value = try StrictJSON.object(packet.payload, keys: ["code"], limit: 128).string("code")
            guard ["auth", "expired", "declined", "busy", "capture", "encoder", "input", "protocol", "timeout", "closed"].contains(value) else { throw NativeFailure.malformed }
        default: throw NativeFailure.state
        }
        return nil
    }
}

public extension Data {
    mutating func appendBE<T: FixedWidthInteger>(_ value: T) { var big = value.bigEndian; Swift.withUnsafeBytes(of: &big) { append(contentsOf: $0) } }
    func readBE<T: FixedWidthInteger>(_ type: T.Type, at offset: Int) -> T {
        precondition(offset >= 0 && offset + MemoryLayout<T>.size <= count)
        return self[(startIndex + offset)..<(startIndex + offset + MemoryLayout<T>.size)].reduce(T(0)) { ($0 << 8) | T($1) }
    }
}
