// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// The short-lived file enrollment channel is separate from screen pairing and
/// address-only discovery invitations. Never persist or log its capability link.
public enum EnrollmentProtocol {
    public static let maximumFrame = 16_384
    public static let lifetime: TimeInterval = 120
    public static let authenticatedLifetime: TimeInterval = 600
    public enum Failure: Error, LocalizedError, Sendable {
        case invalid, expired, peer, frame, replay
        public var errorDescription: String? { "자동 파일 설정을 완료하지 못했습니다. 두 PC의 주소를 확인하고 Mac에서 새 설정 연결을 시작하세요. 기존 파일 설정은 유지됩니다." }
    }
    public struct Link: Sendable, Equatable {
        public let address: String
        public let port: UInt16
        public let sessionID: String
        public let certificateSHA256: String
        public let capability: String
        public init(address: String, port: UInt16, sessionID: String, certificateSHA256: String, capability: String) throws {
            guard try EndpointPolicy.validatedAddress(address) == address, !address.hasPrefix("169.254."),
                  port >= 1024, UUID(uuidString: sessionID)?.uuidString.lowercased() == sessionID,
                  Self.hex(certificateSHA256), Self.hex(capability) else { throw Failure.invalid }
            self.address = address; self.port = port; self.sessionID = sessionID
            self.certificateSHA256 = certificateSHA256; self.capability = capability
        }
        public init(_ text: String) throws {
            guard text.utf8.count <= 512, let url = URLComponents(string: text),
                  url.scheme == "knot-enroll", url.user == nil, url.password == nil, url.query == nil,
                  let address = url.host, let port = url.port, (1024...65535).contains(port),
                  let fragment = url.fragment else { throw Failure.invalid }
            let parts = fragment.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count == 2, url.path.hasPrefix("/"), !url.path.dropFirst().contains("/") else { throw Failure.invalid }
            try self.init(address: address, port: UInt16(port), sessionID: String(url.path.dropFirst()),
                          certificateSHA256: String(parts[0]), capability: String(parts[1]))
            guard text == self.text else { throw Failure.invalid }
        }
        public var text: String { "knot-enroll://\(address):\(port)/\(sessionID)#\(certificateSHA256).\(capability)" }
        private static func hex(_ value: String) -> Bool { value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
    }
    public struct Authentication: Codable, Sendable {
        public let kind: String
        public let version: Int
        public let sessionID: String
        public let capability: String
    }
    public static func authenticate(_ data: Data, link: Link) throws {
        guard !data.isEmpty, data.count <= maximumFrame,
              let fields = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(fields.keys) == ["kind", "version", "sessionID", "capability"] else { throw Failure.invalid }
        let value = try JSONDecoder().decode(Authentication.self, from: data)
        guard value.kind == "knot.enroll.auth", value.version == 1, value.sessionID == link.sessionID,
              constantTimeEqual(value.capability, link.capability) else { throw Failure.invalid }
    }
    public static func validateReply(_ data: Data, request: SetupExchange.MacRequest, expectedWindowsAddress: String) throws -> SetupExchange.Preview {
        let preview = try SetupExchange.preview(data, clientPublicKey: request.clientPublicKey)
        guard preview.reply.requestID == request.requestID, preview.reply.address == expectedWindowsAddress else { throw Failure.peer }
        return preview
    }
    /// Pure one-use admission state used by the native listener. Times are
    /// monotonic uptime, never wall-clock dates supplied by the peer.
    public struct SessionGate: Sendable {
        private enum Phase: Sendable { case waiting, authorized, received, closed }
        private var phase: Phase = .waiting
        private var deadline: TimeInterval
        private var observedAt: TimeInterval
        private let link: Link
        private let request: SetupExchange.MacRequest
        private let windowsAddress: String
        public init(link: Link, request: SetupExchange.MacRequest, windowsAddress: String, now: TimeInterval) throws {
            guard now.isFinite, now >= 0, (now + lifetime).isFinite, link.sessionID == request.requestID,
                  request.allowedClientAddresses.contains(link.address),
                  try EndpointPolicy.validatedAddress(windowsAddress) == windowsAddress else { throw Failure.invalid }
            self.link = link; self.request = request; self.windowsAddress = windowsAddress
            deadline = now + lifetime; observedAt = now
        }
        public mutating func authorize(_ data: Data, peer: String, now: TimeInterval) throws {
            try check(now)
            guard phase == .waiting else { throw Failure.replay }
            guard peer == windowsAddress else { throw Failure.peer }
            try EnrollmentProtocol.authenticate(data, link: link)
            // Only the first valid authentication exchanges the short admission
            // budget for a fixed provisioning/reply budget. Replay cannot renew it.
            deadline = now + authenticatedLifetime
            phase = .authorized
        }
        public mutating func receive(_ data: Data, now: TimeInterval) throws -> SetupExchange.Preview {
            try check(now)
            guard phase == .authorized else { throw Failure.replay }
            let preview = try EnrollmentProtocol.validateReply(data, request: request, expectedWindowsAddress: windowsAddress)
            phase = .received
            return preview
        }
        public mutating func cancel() { phase = .closed }
        private mutating func check(_ now: TimeInterval) throws {
            guard phase != .closed else { throw Failure.expired }
            guard now.isFinite, now >= observedAt, now < deadline else {
                phase = .closed
                throw Failure.expired
            }
            observedAt = now
        }
    }
    public static func frame(_ data: Data) throws -> Data {
        guard !data.isEmpty, data.count <= maximumFrame else { throw Failure.frame }
        var length = UInt32(data.count).bigEndian
        return withUnsafeBytes(of: &length) { Data($0) } + data
    }
    public static func length(_ bytes: Data) throws -> Int {
        guard bytes.count == 4 else { throw Failure.frame }
        let value = bytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard value > 0, value <= maximumFrame else { throw Failure.frame }
        return Int(value)
    }
    private static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let left = Array(a.utf8), right = Array(b.utf8)
        guard left.count == right.count else { return false }
        var difference: UInt8 = 0
        for i in left.indices { difference |= left[i] ^ right[i] }
        return difference == 0
    }
}
