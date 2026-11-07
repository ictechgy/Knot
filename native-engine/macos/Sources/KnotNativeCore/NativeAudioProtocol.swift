import Foundation
import CryptoKit

/// Audio is optional and has its own authority, framing and connection. It
/// neither extends the video hello nor grants access to the file channel.
public struct NativeAudioEndpoint: Sendable {
    public static let port: UInt16 = 48636
    public let address: String
    public let certificateSHA256: String
    private let key: Data

    public init(invitation: Invitation) throws {
        address = invitation.address
        certificateSHA256 = invitation.certificateSHA256
        key = try NativeAudioWire.deriveKey(mediaToken: Invitation.base64URL(invitation.token))
    }

    public func hello() throws -> Packet {
        Packet(kind: .hello, payload: try JSONSerialization.data(withJSONObject: [
            "v": 1, "token": Invitation.encodeBase64URL(key)
        ]))
    }
}

public enum NativeAudioWire {
    public static let sampleRate = 48_000
    public static let channels = 2
    public static let maximumFrames = 960
    public static let maximumPayload = 3_860
    public static let errorCodes: Set<String> = ["auth", "closed", "unavailable", "protocol", "timeout"]

    public static func deriveKey(mediaToken: Data) throws -> Data {
        guard mediaToken.count == 32 else { throw NativeFailure.malformed }
        return Data(HMAC<SHA256>.authenticationCode(for: Data("knot-audio-v1".utf8),
            using: SymmetricKey(data: mediaToken)))
    }
}

public enum NativeAudioKind: UInt8, Sendable {
    case hello = 1, ready = 2, pcm = 3, heartbeat = 4, error = 127
}

public struct NativeAudioPacket: Sendable, Equatable {
    public let kind: NativeAudioKind
    public let payload: Data
    public init(kind: NativeAudioKind, payload: Data = Data()) { self.kind = kind; self.payload = payload }
    public var encoded: Data {
        var bytes = Data([kind.rawValue]); bytes.appendBE(UInt32(payload.count)); bytes.append(payload); return bytes
    }

    /// Validate before allocating or receiving a body. Audio never uses the
    /// larger video or clipboard packet limits.
    public static func serverHeader(_ bytes: Data) throws -> (NativeAudioKind, Int) {
        guard bytes.count == 5, let kind = NativeAudioKind(rawValue: bytes[bytes.startIndex]) else { throw NativeFailure.malformed }
        let count = Int(bytes.readBE(UInt32.self, at: 1))
        switch kind {
        case .ready: guard (1...256).contains(count) else { throw NativeFailure.oversized }
        case .pcm: guard (24...NativeAudioWire.maximumPayload).contains(count) else { throw NativeFailure.oversized }
        case .heartbeat: guard count == 0 else { throw NativeFailure.malformed }
        case .error: guard (1...128).contains(count) else { throw NativeFailure.oversized }
        case .hello: throw NativeFailure.state
        }
        return (kind, count)
    }
}

public struct NativeAudioPCM: Sendable, Equatable {
    public let sequence: UInt64
    public let firstSampleIndex: UInt64
    public let frames: Int
    public let bytes: Data
    public let hasSampleGap: Bool

    public init(_ payload: Data, after sequence: UInt64, previousEnd: UInt64?) throws {
        guard (24...NativeAudioWire.maximumPayload).contains(payload.count) else { throw NativeFailure.oversized }
        let next = payload.readBE(UInt64.self, at: 0)
        let first = payload.readBE(UInt64.self, at: 8)
        let count = Int(payload.readBE(UInt32.self, at: 16))
        guard sequence != .max, next == sequence + 1,
              (1...NativeAudioWire.maximumFrames).contains(count),
              payload.count == 20 + count * 4,
              first <= UInt64.max - UInt64(count),
              previousEnd == nil || first >= previousEnd! else { throw NativeFailure.malformed }
        self.sequence = next; firstSampleIndex = first; frames = count
        bytes = Data(payload.dropFirst(20))
        hasSampleGap = previousEnd.map { first > $0 } ?? false
    }

    /// Integer PCM on the wire is explicitly little endian, regardless of the
    /// host architecture. Conversion is performed by the output actor.
    public func sample(frame: Int, channel: Int) -> Float {
        precondition((0..<frames).contains(frame) && (0..<2).contains(channel))
        let offset = bytes.startIndex + (frame * 2 + channel) * 2
        let bits = UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
        return Float(Int16(bitPattern: bits)) / 32_768
    }
}

public enum NativeAudioEvent: Sendable, Equatable {
    case ready, heartbeat, pcm(NativeAudioPCM), failure(String)
}

public struct NativeAudioReceiveState: Sendable {
    public private(set) var isReady = false
    public private(set) var sequence: UInt64 = 0
    public private(set) var endSampleIndex: UInt64?
    private var ended = false
    public init() {}

    public mutating func accept(_ packet: NativeAudioPacket) throws -> NativeAudioEvent {
        guard !ended else { throw NativeFailure.state }
        switch packet.kind {
        case .ready:
            guard !isReady else { throw NativeFailure.state }
            let object = try StrictJSON.object(packet.payload, keys: ["v", "codec", "sampleRate", "channels"], limit: 256)
            guard try object.integer("v") == 1, try object.string("codec") == "pcm-s16le",
                  try object.integer("sampleRate") == NativeAudioWire.sampleRate,
                  try object.integer("channels") == NativeAudioWire.channels else { throw NativeFailure.unsupported }
            isReady = true; return .ready
        case .pcm:
            guard isReady else { throw NativeFailure.state }
            let pcm = try NativeAudioPCM(packet.payload, after: sequence, previousEnd: endSampleIndex)
            sequence = pcm.sequence; endSampleIndex = pcm.firstSampleIndex + UInt64(pcm.frames)
            return .pcm(pcm)
        case .heartbeat:
            guard isReady, packet.payload.isEmpty else { throw NativeFailure.state }
            return .heartbeat
        case .error:
            let code = try StrictJSON.object(packet.payload, keys: ["code"], limit: 128).string("code")
            guard NativeAudioWire.errorCodes.contains(code) else { throw NativeFailure.malformed }
            ended = true; return .failure(code)
        case .hello: throw NativeFailure.state
        }
    }
}
