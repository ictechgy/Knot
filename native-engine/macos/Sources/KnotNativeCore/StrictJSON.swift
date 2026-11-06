import Foundation

public enum NativeFailure: Error, Equatable, Sendable {
    case malformed, oversized, unsupported, state, saturated, transport, trust, decoder
    case certificatePinMismatch, certificatePolicy
}

public enum JSONValue: Equatable, Sendable {
    case string(String), integer(Int), boolean(Bool)
}

/// Small schema-oriented parser: rejects duplicate keys (including escaped aliases),
/// non-integral numbers, nested containers, unknown value kinds and trailing bytes.
public enum StrictJSON {
    public static func object(_ data: Data, keys: Set<String>, limit: Int) throws -> [String: JSONValue] {
        guard !data.isEmpty, data.count <= limit, String(data: data, encoding: .utf8) != nil else { throw NativeFailure.malformed }
        var parser = Parser(bytes: Array(data))
        let result = try parser.object()
        guard Set(result.keys) == keys else { throw NativeFailure.malformed }
        return result
    }

    private struct Parser {
        let bytes: [UInt8]
        var position = 0
        mutating func whitespace() { while position < bytes.count && [9, 10, 13, 32].contains(bytes[position]) { position += 1 } }
        mutating func take(_ byte: UInt8) throws { whitespace(); guard position < bytes.count, bytes[position] == byte else { throw NativeFailure.malformed }; position += 1 }
        mutating func string() throws -> String {
            whitespace()
            let start = position
            try take(34)
            var escaped = false
            while position < bytes.count {
                let byte = bytes[position]; position += 1
                guard byte >= 32 else { throw NativeFailure.malformed }
                if !escaped && byte == 34 {
                    let data = Data(bytes[start..<position])
                    guard let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? String else { throw NativeFailure.malformed }
                    return value
                }
                if escaped { escaped = false } else if byte == 92 { escaped = true }
            }
            throw NativeFailure.malformed
        }
        mutating func value() throws -> JSONValue {
            whitespace(); guard position < bytes.count else { throw NativeFailure.malformed }
            if bytes[position] == 34 { return .string(try string()) }
            for (literal, value) in [("true", true), ("false", false)] {
                let encoded = Array(literal.utf8)
                if bytes[position...].starts(with: encoded) { position += encoded.count; return .boolean(value) }
            }
            let start = position
            if bytes[position] == 45 { position += 1 }
            guard position < bytes.count, (48...57).contains(bytes[position]) else { throw NativeFailure.malformed }
            if bytes[position] == 48 { position += 1 }
            else { while position < bytes.count, (48...57).contains(bytes[position]) { position += 1 } }
            guard let number = Int(String(decoding: bytes[start..<position], as: UTF8.self)) else { throw NativeFailure.malformed }
            return .integer(number)
        }
        mutating func object() throws -> [String: JSONValue] {
            try take(123)
            var result: [String: JSONValue] = [:]
            whitespace()
            if position < bytes.count, bytes[position] == 125 { position += 1 }
            else {
                while true {
                    let key = try string()
                    guard result[key] == nil else { throw NativeFailure.malformed }
                    try take(58); result[key] = try value(); whitespace()
                    guard position < bytes.count else { throw NativeFailure.malformed }
                    if bytes[position] == 125 { position += 1; break }
                    try take(44)
                }
            }
            whitespace(); guard position == bytes.count else { throw NativeFailure.malformed }
            return result
        }
    }
}

public extension Dictionary where Key == String, Value == JSONValue {
    func string(_ key: String) throws -> String { guard case let .string(value)? = self[key] else { throw NativeFailure.malformed }; return value }
    func integer(_ key: String) throws -> Int { guard case let .integer(value)? = self[key] else { throw NativeFailure.malformed }; return value }
    func boolean(_ key: String) throws -> Bool { guard case let .boolean(value)? = self[key] else { throw NativeFailure.malformed }; return value }
}
