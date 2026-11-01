import Foundation

public enum Kind: UInt8, Sendable {
    case hello = 1, ready = 2, video = 3, hostHeartbeat = 4
    case key = 0x20, text = 0x21, pointer = 0x22, wheel = 0x23, releaseAll = 0x24, heartbeat = 0x25, error = 0x7f
}
public struct Packet: Sendable, Equatable {
    public let kind: Kind
    public let payload: Data
    public init(kind: Kind, payload: Data = Data()) { self.kind = kind; self.payload = payload }
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
        case .error: guard (1...128).contains(size) else { throw NativeFailure.oversized }
        default: throw NativeFailure.malformed
        }
        return (kind, size)
    }
}

public struct Ready: Sendable, Equatable {
    public let width: Int, height: Int, fps: Int, bitrate: Int
    public init(_ bytes: Data) throws {
        let json = try StrictJSON.object(bytes, keys: ["v", "codec", "width", "height", "fps", "bitrate", "hardwareEncoder"], limit: 4096)
        let width = try json.integer("width"), height = try json.integer("height")
        let fps = try json.integer("fps"), bitrate = try json.integer("bitrate")
        guard try json.integer("v") == 1, try json.string("codec") == "h264-annexb", try json.boolean("hardwareEncoder"),
              (16...1920).contains(width), (16...1080).contains(height), width % 2 == 0, height % 2 == 0,
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
    public init() {}
    public mutating func accept(_ packet: Packet) throws -> VideoPacket? {
        switch packet.kind {
        case .ready: guard ready == nil else { throw NativeFailure.state }; ready = try Ready(packet.payload)
        case .video: guard ready != nil else { throw NativeFailure.state }; let video = try VideoPacket(packet.payload, after: sequence); sequence = video.sequence; return video
        case .hostHeartbeat: guard packet.payload.isEmpty else { throw NativeFailure.malformed }
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
