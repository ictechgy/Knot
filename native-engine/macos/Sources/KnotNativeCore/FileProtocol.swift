import Foundation

public enum NativeFileError: String, Error, Sendable, Equatable {
    case auth, busy, protocolViolation = "protocol", timeout, denied, missing, changed, quota, io
    case cancelled, unsupported, closed, trust, exists, unconfirmed
    public var message: String {
        switch self {
        case .auth, .trust: return "파일 연결의 인증을 확인하지 못했어요. 연결을 종료하고 두 앱을 업데이트한 뒤 다시 연결하세요."
        case .busy: return "다른 파일 작업이 진행 중이에요. 완료하거나 취소한 뒤 다시 시도하세요."
        case .timeout: return "파일 전송 응답이 늦어 중단했어요. 화면 연결은 유지돼요. 다시 시도하세요."
        case .denied: return "공유 폴더나 저장 위치의 파일 권한을 확인해주세요."
        case .exists: return "같은 이름의 파일이 이미 있어요. 다른 이름이나 저장 위치를 선택해주세요. 기존 파일은 바꾸지 않아요."
        case .unconfirmed: return "전송 완료를 확인하지 못했어요. Windows 공유 폴더를 확인한 뒤 다시 시도하세요. 이미 저장된 파일은 자동으로 지우지 않아요."
        case .missing: return "이 파일을 찾지 못했어요. 목록을 새로고침해주세요."
        case .changed: return "전송 중 원본 파일이 바뀌었어요. 원본을 닫고 목록을 새로고침해주세요."
        case .quota: return "이번 연결은 8GiB·8192개 항목까지, 폴더 하나는 4096개 항목·16단계까지 전송할 수 있어요. 저장 공간도 확인해주세요."
        case .cancelled: return "파일 전송을 취소했어요. 화면 연결은 유지돼요."
        case .unsupported: return "일반 파일과 폴더를 전송할 수 있어요. 앱 패키지·링크·특수 파일과 지원하지 않는 이름은 제외해주세요."
        case .closed: return "연결이 종료되어 파일 작업을 중단했어요. 다시 연결해주세요."
        case .protocolViolation: return "파일 전송 형식을 확인하지 못했어요. 두 앱을 업데이트한 뒤 다시 시도하세요."
        case .io: return "파일을 읽거나 저장하지 못했어요. 권한과 저장 공간을 확인해주세요."
        }
    }
    public static func authored(_ error: any Error) -> Self {
        if let error = error as? Self { return error }
        if error is CancellationError { return .cancelled }
        if let error = error as? NativeFailure {
            switch error {
            case .transport: return .timeout
            case .trust, .certificatePinMismatch, .certificatePolicy: return .trust
            case .malformed, .oversized, .unsupported, .state: return .protocolViolation
            default: return .io
            }
        }
        return .io
    }
}

public struct NativeFileOffer: Sendable, Equatable {
    public let port: UInt16
    public let token: String
    public let rootName: String
    public init(port: Int, token: String, rootName: String) throws {
        guard port == 48634, token.utf8.count == 43,
              (try? Invitation.base64URL(token).count) == 32,
              Invitation.validViewerLabel(rootName) else { throw NativeFileError.protocolViolation }
        self.port = UInt16(port); self.token = token; self.rootName = rootName
    }
}

public enum NativeFileEntryKind: String, Sendable, Equatable { case file, folder }

public struct NativeFileEntry: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let size: Int64
    public let kind: NativeFileEntryKind
    public var isFolder: Bool { kind == .folder }
    public init(id: String, name: String, size: Int64, kind: NativeFileEntryKind = .file) throws {
        guard FileWire.isHex(id, count: 32), FileWire.validName(name), FileWire.validSize(size), kind != .folder || (size == 0 && FileWire.validFolderName(name)) else {
            throw NativeFileError.protocolViolation
        }
        self.id = id; self.name = name; self.size = size; self.kind = kind
    }
    public init(_ data: Data) throws {
        let object = try FileWire.object(data, keys: ["entry", "name", "size", "kind"])
        guard let kind = NativeFileEntryKind(rawValue: try object.string("kind")) else { throw NativeFileError.protocolViolation }
        try self.init(id: object.string("entry"), name: object.string("name"), size: Int64(object.integer("size")), kind: kind)
    }
}

public enum FileKind: UInt8, Sendable {
    case hello = 0x40, authorized = 0x41, list = 0x42, entry = 0x43, listEnd = 0x44
    case put = 0x45, get = 0x46, accepted = 0x47, chunk = 0x48, finish = 0x49, complete = 0x4a
    case treePut = 0x4b, node = 0x4c, treeEnd = 0x4d, explorerCapture = 0x4e, explorerCancel = 0x4f, error = 0x7f
}

public struct FilePacket: Sendable, Equatable {
    public let kind: FileKind
    public let payload: Data
    public init(kind: FileKind, payload: Data = Data()) throws {
        try Self.validate(kind, size: payload.count)
        self.kind = kind; self.payload = payload
    }
    public var encoded: Data {
        var result = Data([kind.rawValue]); result.appendBE(UInt32(payload.count)); result.append(payload); return result
    }
    public static func header(_ data: Data) throws -> (FileKind, Int) {
        guard data.count == 5, let kind = FileKind(rawValue: data[data.startIndex]) else { throw NativeFileError.protocolViolation }
        let length = Int(data.readBE(UInt32.self, at: 1)); try validate(kind, size: length); return (kind, length)
    }
    private static func validate(_ kind: FileKind, size: Int) throws {
        let valid: Bool
        switch kind {
        case .list: valid = size == 0
        case .chunk: valid = (9...65_544).contains(size)
        case .finish: valid = size == 40
        case .error: valid = (1...128).contains(size)
        default: valid = (1...4096).contains(size)
        }
        guard valid else { throw NativeFileError.protocolViolation }
    }
}

public enum FileWire {
    public static let chunkBytes = 65_536
    public static let maximumSize: Int64 = 8_589_934_592
    public static let maximumEntries = 256
    public static let maximumTreeNodes = 4096
    public static let maximumRunNodes = 8192
    public static let maximumTreeDepth = 16
    public static let maximumTreeMetadata = 1_048_576
    public static let bytesPerSecond: Int64 = 2_097_152
    public static let remoteErrors: Set<String> = ["auth", "busy", "protocol", "timeout", "denied", "missing", "changed", "quota", "io"]

    public static func validSize(_ size: Int64) -> Bool { size >= 0 && size <= maximumSize }
    public static func isHex(_ text: String, count: Int) -> Bool {
        text.utf8.count == count && text.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    public static func validName(_ name: String) -> Bool {
        guard (1...255).contains(name.utf8.count), name != ".", name != "..", !name.lowercased().hasPrefix(".knot-"),
              !name.hasSuffix("."), !name.hasSuffix(" "),
              !name.unicodeScalars.contains(where: {
                  if ["/", "\\", ":", "\0", "<", ">", "\"", "|", "?", "*"].contains(String($0)) { return true }
                  switch $0.properties.generalCategory {
                  case .control, .format, .lineSeparator, .paragraphSeparator: return true
                  default: return false
                  }
              }) else { return false }
        let rawStem = name.split(separator: ".", omittingEmptySubsequences: false).first.map(String.init) ?? ""
        let stem = String(rawStem.reversed().drop(while: { $0 == " " }).reversed()).uppercased()
        if ["CON", "PRN", "AUX", "NUL", "CLOCK$", "CONIN$", "CONOUT$"].contains(stem) { return false }
        if stem.count == 4, stem.hasPrefix("COM") || stem.hasPrefix("LPT"), let last = stem.last,
           "0123456789¹²³".contains(last) { return false }
        return true
    }
    // Portable folder-package policy shared with the Windows tree receiver.
    // These suffixes remain valid for ordinary files, which receive quarantine.
    public static func isPackageFolderName(_ name: String) -> Bool {
        guard let dot = name.lastIndex(of: ".") else { return false }
        let suffix = name[name.index(after: dot)...].lowercased()
        return ["app", "bundle", "framework", "plugin", "kext", "xpc", "appex", "rtfd", "photoslibrary", "playground", "pkg"].contains(suffix)
    }
    public static func validFolderName(_ name: String) -> Bool {
        validName(name) && !isPackageFolderName(name)
    }
    public static func object(_ data: Data, keys: Set<String>) throws -> [String: JSONValue] {
        do { return try StrictJSON.object(data, keys: keys, limit: 4096) }
        catch { throw NativeFileError.protocolViolation }
    }
    public static func json(_ values: [String: Any]) throws -> Data {
        let data = try JSONSerialization.data(withJSONObject: values, options: [.sortedKeys])
        guard data.count <= 4096 else { throw NativeFileError.protocolViolation }; return data
    }
    public static func metadata(_ data: Data) throws -> (name: String, size: Int64) {
        let object = try object(data, keys: ["name", "size"])
        let name = try object.string("name"), size = Int64(try object.integer("size"))
        guard validName(name), validSize(size) else { throw NativeFileError.protocolViolation }; return (name, size)
    }
    public static func accepted(_ data: Data) throws -> (name: String, size: Int64, kind: NativeFileEntryKind, count: Int) {
        let object = try object(data, keys: ["name", "size", "kind", "count"])
        let name = try object.string("name"), size = Int64(try object.integer("size")), count = try object.integer("count")
        guard let kind = NativeFileEntryKind(rawValue: try object.string("kind")), validName(name), validSize(size),
              (0...maximumTreeNodes).contains(count), kind != .file || count == 0, kind != .folder || validFolderName(name), kind != .folder || count != 0 || size == 0 else { throw NativeFileError.protocolViolation }
        return (name, size, kind, count)
    }
    public static func treeMetadata(_ data: Data) throws -> (name: String, size: Int64, count: Int) {
        let object = try object(data, keys: ["name", "size", "count"])
        let name = try object.string("name"), size = Int64(try object.integer("size")), count = try object.integer("count")
        guard validFolderName(name), validSize(size), (0...maximumTreeNodes).contains(count), count != 0 || size == 0 else { throw NativeFileError.protocolViolation }
        return (name, size, count)
    }
    public static func treeEnd(_ data: Data) throws -> (count: Int, size: Int64, hash: String) {
        let object = try object(data, keys: ["count", "size", "sha256"])
        let count = try object.integer("count"), size = Int64(try object.integer("size")), hash = try object.string("sha256")
        guard (0...maximumTreeNodes).contains(count), validSize(size), count != 0 || size == 0, isHex(hash, count: 64) else { throw NativeFileError.protocolViolation }
        return (count, size, hash)
    }
    public static func explorerNonce(_ data: Data) throws -> String {
        let nonce = try object(data, keys: ["nonce"]).string("nonce")
        guard isHex(nonce, count: 32) else { throw NativeFileError.protocolViolation }; return nonce
    }
    public static func siblingKey(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
    public static func completion(_ data: Data) throws -> (name: String, size: Int64, hash: String) {
        let object = try object(data, keys: ["name", "size", "sha256"])
        let name = try object.string("name"), size = Int64(try object.integer("size")), hash = try object.string("sha256")
        guard validName(name), validSize(size), isHex(hash, count: 64) else { throw NativeFileError.protocolViolation }
        return (name, size, hash)
    }
    public static func finish(size: Int64, digest: Data) throws -> FilePacket {
        guard validSize(size), digest.count == 32 else { throw NativeFileError.protocolViolation }
        var data = Data(); data.appendBE(UInt64(size)); data.append(digest); return try FilePacket(kind: .finish, payload: data)
    }
    public static func checkFinish(_ data: Data, size: Int64, digest: Data) throws {
        guard validSize(size), digest.count == 32, data.count == 40,
              data.readBE(UInt64.self, at: 0) == UInt64(size), data.dropFirst(8) == digest else {
            throw NativeFileError.changed
        }
    }
    public static func remoteError(_ data: Data) throws -> NativeFileError {
        let value = try object(data, keys: ["code"]).string("code")
        guard remoteErrors.contains(value), let error = NativeFileError(rawValue: value) else { throw NativeFileError.protocolViolation }
        return error
    }
}
