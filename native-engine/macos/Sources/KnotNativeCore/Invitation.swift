import Foundation

public struct Invitation: Sendable, Equatable {
    public let address: String
    public let port: UInt16
    public let certificateSHA256: String
    public let token: String

    public init(_ text: String) throws {
        let prefix = "knot-native:v1:"
        guard text.utf8.count <= 2048, text.hasPrefix(prefix) else { throw NativeFailure.malformed }
        let encoded = String(text.dropFirst(prefix.count))
        let bytes = try Self.base64URL(encoded)
        let json = try StrictJSON.object(bytes, keys: ["v", "address", "port", "certificateSHA256", "token"], limit: 1536)
        guard try json.integer("v") == 1 else { throw NativeFailure.unsupported }
        let address = try json.string("address")
        guard Self.isPrivateIPv4(address) else { throw NativeFailure.malformed }
        let port = try json.integer("port")
        let pin = try json.string("certificateSHA256")
        let token = try json.string("token")
        guard (1...65535).contains(port), pin.utf8.count == 64,
              pin.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              token.utf8.count == 43, try Self.base64URL(token).count == 32 else { throw NativeFailure.malformed }
        self.address = address; self.port = UInt16(port); self.certificateSHA256 = pin; self.token = token
    }

    public static func base64URL(_ text: String) throws -> Data {
        guard !text.isEmpty, text.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }), text.count % 4 != 1 else { throw NativeFailure.malformed }
        let padded = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + String(repeating: "=", count: (4 - text.count % 4) % 4)
        guard let result = Data(base64Encoded: padded), encodeBase64URL(result) == text else { throw NativeFailure.malformed }
        return result
    }
    public static func encodeBase64URL(_ data: Data) -> String { data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
    public static func isPrivateIPv4(_ text: String) -> Bool {
        let pieces = text.split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count == 4 else { return false }
        var bytes: [Int] = []
        for piece in pieces {
            guard !piece.isEmpty, piece.utf8.allSatisfy({ (48...57).contains($0) }), let number = Int(piece), (0...255).contains(number), String(number) == piece else { return false }
            bytes.append(number)
        }
        return bytes[0] == 10 || (bytes[0] == 172 && (16...31).contains(bytes[1])) || (bytes[0] == 192 && bytes[1] == 168) || (bytes[0] == 100 && (64...127).contains(bytes[1]))
    }
    public static func validViewerLabel(_ name: String) -> Bool {
        guard (1...64).contains(name.utf8.count) else { return false }
        return name.unicodeScalars.allSatisfy {
            switch $0.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator: return false
            default: return true
            }
        }
    }
    public func hello(name: String = "Mac viewer") throws -> Packet {
        guard Self.validViewerLabel(name) else { throw NativeFailure.malformed }
        let body = try JSONSerialization.data(withJSONObject: ["v": 1, "token": token, "name": name])
        return Packet(kind: .hello, payload: body)
    }
}
