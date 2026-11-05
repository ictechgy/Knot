import Foundation

public enum EnrollmentFailure: Error, Equatable, Sendable {
    case invalidCode, invalidTarget, invalidMessage, authentication, expired, busy, transport, cancelled
}

public struct EnrollmentCandidate: Identifiable, Equatable, Sendable {
    public let address: String
    public let port: UInt16
    public let slot: Data
    public let name: String
    public var id: String { address + ":" + String(port) + ":" + Invitation.encodeBase64URL(slot) }
    public init(address: String, port: UInt16, slot: Data, name: String) throws {
        guard Invitation.isPrivateIPv4(address), port == EnrollmentWire.enrollmentPort,
              slot.count == 16, Invitation.validViewerLabel(name) else {
            throw EnrollmentFailure.invalidTarget
        }
        self.address = address; self.port = port; self.slot = slot; self.name = name
    }
}

public enum EnrollmentWire {
    public static let preamble = Data([75, 78, 79, 84, 80, 50, 0, 0])
    public static let discoveryPrefix = Data([75, 78, 79, 84, 68, 50, 0, 0])
    public static let enrollmentPort: UInt16 = 48632
    public static let discoveryPort: UInt16 = 48633
    public static let candidateLimit = 16
    public static func password(_ code: String) throws -> Data {
        guard code.utf8.count == 8, code.utf8.allSatisfy({ (48...57).contains($0) }) else {
            throw EnrollmentFailure.invalidCode
        }
        return Data(code.utf8)
    }
    public static func identifier(_ text: String) throws -> Data {
        let bytes = try Invitation.base64URL(text)
        guard bytes.count == 16 else { throw EnrollmentFailure.invalidMessage }
        return bytes
    }
    public static func discoveryQuery(nonce: Data) throws -> Data {
        guard nonce.count == 16 else { throw EnrollmentFailure.invalidMessage }
        return discoveryPrefix + nonce
    }
    public static func discoveryReply(_ data: Data, nonce: Data, sourceIPv4: String) throws -> EnrollmentCandidate {
        guard nonce.count == 16, Invitation.isPrivateIPv4(sourceIPv4) else { throw EnrollmentFailure.invalidTarget }
        let object = try StrictJSON.object(data, keys: ["v", "nonce", "slot", "name", "port"], limit: 1024)
        let port = try object.integer("port")
        guard try object.integer("v") == 2, try identifier(object.string("nonce")) == nonce,
              port == Int(enrollmentPort) else { throw EnrollmentFailure.invalidMessage }
        return try EnrollmentCandidate(address: sourceIPv4, port: UInt16(port),
            slot: identifier(object.string("slot")), name: object.string("name"))
    }
    public static func hello(slot: Data, message: Data) throws -> Data {
        guard slot.count == 16, message.count == 32 else { throw EnrollmentFailure.invalidMessage }
        return slot + message
    }
    public static func serverMessage(_ data: Data, slot: Data) throws -> Data {
        guard data.count == 48, slot.count == 16, data.prefix(16) == slot else { throw EnrollmentFailure.invalidMessage }
        return Data(data.dropFirst(16))
    }
    public static func confirm(slot: Data, name: String) throws -> Data {
        guard slot.count == 16, Invitation.validViewerLabel(name) else { throw EnrollmentFailure.invalidMessage }
        let data = try JSONSerialization.data(withJSONObject: ["v": 2, "slot": Invitation.encodeBase64URL(slot),
            "name": name, "permissions": "screen,input,files"], options: [.sortedKeys])
        guard data.count <= 484 else { throw EnrollmentFailure.invalidMessage }
        return data
    }
    public static func serverError(_ data: Data) throws -> EnrollmentFailure {
        let value = try StrictJSON.object(data, keys: ["code"], limit: 128).string("code")
        switch value {
        case "auth": return .authentication
        case "expired": return .expired
        case "busy": return .busy
        case "protocol": return .invalidMessage
        case "closed": return .cancelled
        default: throw EnrollmentFailure.invalidMessage
        }
    }
}

public struct EnrollmentFrame: Equatable, Sendable {
    public enum Kind: UInt8, Sendable { case clientHello = 1, serverHello = 2, clientConfirm = 3, serverOffer = 4, error = 0x7f }
    public let kind: Kind
    public let payload: Data
    public init(kind: Kind, payload: Data) throws {
        try Self.validate(kind: kind, length: payload.count)
        self.kind = kind; self.payload = payload
    }
    public var encoded: Data {
        var bytes = Data([kind.rawValue]); bytes.appendBE(UInt32(payload.count)); bytes.append(payload); return bytes
    }
    public static func header(_ data: Data) throws -> (Kind, Int) {
        guard data.count == 5, let kind = Kind(rawValue: data[data.startIndex]) else { throw EnrollmentFailure.invalidMessage }
        let size = Int(data.readBE(UInt32.self, at: 1))
        try validate(kind: kind, length: size)
        return (kind, size)
    }
    private static func validate(kind: Kind, length: Int) throws {
        let valid: Bool
        switch kind {
        case .clientHello, .serverHello: valid = length == 48
        case .clientConfirm: valid = (29...512).contains(length)
        case .serverOffer: valid = (29...4096).contains(length)
        case .error: valid = (1...128).contains(length)
        }
        guard valid else { throw EnrollmentFailure.invalidMessage }
    }
}

public struct EnrollmentOffer: Sendable {
    public let invitation: Invitation
    public let grant: Data
    public let ttlMilliseconds: Int
    public init(_ data: Data, candidate: EnrollmentCandidate) throws {
        let object = try StrictJSON.object(data, keys: ["v", "slot", "grant", "invitation", "ttlMs"], limit: 3072)
        let ttl = try object.integer("ttlMs")
        guard try object.integer("v") == 2, try EnrollmentWire.identifier(object.string("slot")) == candidate.slot,
              (1...30000).contains(ttl) else { throw EnrollmentFailure.invalidMessage }
        let invitation = try Invitation(object.string("invitation"))
        guard invitation.address == candidate.address else { throw EnrollmentFailure.invalidTarget }
        self.invitation = invitation; self.grant = try EnrollmentWire.identifier(object.string("grant")); ttlMilliseconds = ttl
    }
}
