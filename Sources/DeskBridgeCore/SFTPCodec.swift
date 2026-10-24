import Foundation

public enum SFTPError: Error, LocalizedError, Sendable, Equatable {
    case invalidConfiguration(String)
    case invalidPath(String)
    case protocolViolation(String)
    case remoteStatus(UInt32, String)
    case disconnected
    case sshConnectionFailure(SFTPSSHFailure)
    case cancelled
    case timedOut
    case connectionLost(String)
    case targetChanged
    case destinationExists
    case sourceChanged
    case unsupportedFile
    case localIO(String)

    /// The transport/session is no longer reusable. Remote file errors such as
    /// no-such-file (2) and permission-denied (3) leave the connection usable.
    public static func requiresReconnect(after error: any Error) -> Bool {
        if error is CancellationError { return true }
        guard let error = error as? SFTPError else { return false }
        switch error {
        case .protocolViolation, .disconnected, .sshConnectionFailure, .cancelled, .timedOut, .connectionLost, .targetChanged:
            return true
        case .remoteStatus(let code, _):
            return code == 6 || code == 7 // SSH_FX_NO_CONNECTION / SSH_FX_CONNECTION_LOST
        default:
            return false
        }
    }

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration: return "파일 접속 설정을 확인하세요. PC 주소·SSH 포트·파일 전용 계정·Mac 개인 키·Windows 호스트 공개 키를 확인한 뒤 다시 접속하세요."
        case .invalidPath: return "파일 이름과 경로를 확인하세요. 공유 폴더 안의 경로를 사용하고 Windows에서 지원하지 않는 이름·제어 문자·숨은 서식 문자를 피하세요."
        case .protocolViolation: return "파일 서버 응답을 확인하지 못했습니다. 파일 연결을 끊고 다시 접속하세요."
        case .remoteStatus(let code, _):
            switch code {
            case 2: return "Windows에서 파일이나 폴더를 찾지 못했습니다. 목록을 새로 고침하고 다시 선택하세요."
            case 3: return "Windows에서 파일 접근을 허용하지 않았습니다. 공유 폴더와 전용 계정의 접근 권한을 확인하세요."
            default: return "Windows에서 파일 작업을 완료하지 못했습니다. SFTP 오류 코드: \(code)"
            }
        case .disconnected: return "파일 연결이 끊어졌습니다. 다시 접속하세요."
        case .sshConnectionFailure(let failure):
            switch failure {
            case .hostKeyVerificationFailed:
                return "Windows의 SSH 호스트 키가 저장된 키와 다르거나 확인되지 않았습니다. Windows에서 호스트 키를 직접 확인한 뒤 파일 연결 설정을 갱신하세요."
            case .authenticationRejected:
                return "파일 연결용 SSH 키 인증을 확인하지 못했습니다. Mac에서 선택한 개인 키와 Windows 전용 계정에 등록한 Mac 공개 키를 함께 확인하세요."
            case .connectionRefused:
                return "Windows의 SSH 포트가 연결을 거절했습니다. Windows에서 파일 전송 설정과 OpenSSH 서비스가 켜져 있는지 확인하세요."
            case .networkUnavailable:
                return "Windows의 SSH 서비스에 도달하지 못했습니다. 같은 네트워크 또는 Tailscale 연결, PC 주소와 방화벽을 확인하세요."
            }
        case .cancelled: return "파일 전송을 취소했습니다. Windows에 미완료 업로드가 남을 수 있습니다."
        case .timedOut: return "파일 작업 시간이 초과되었습니다. 다시 접속하세요."
        case .connectionLost: return "파일 연결이 끊어졌습니다. PC 주소와 네트워크를 확인한 뒤 다시 접속하세요."
        case .targetChanged: return "대상 PC가 바뀌어 파일 연결을 끊었습니다. PC 주소를 확인한 뒤 다시 접속하세요."
        case .destinationExists: return "같은 이름의 파일이 있습니다. 다른 이름을 선택하세요."
        case .sourceChanged: return "전송 중 원본 파일이 바뀌었습니다. 다시 시도하세요."
        case .unsupportedFile: return "128GiB 이하의 일반 파일을 선택하세요. 폴더·앱 패키지·심볼릭 링크는 전송하지 않습니다."
        case .localIO: return "Mac에서 파일 작업을 완료하지 못했습니다. 저장 폴더의 접근 권한·남은 공간을 확인하고, 다운로드는 macOS 격리 표식을 지원하는 로컬 폴더에 저장하세요."
        }
    }
}

public struct SFTPEntry: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable { case file, directory, symlink, other }
    public let name: String
    public let path: String
    public let kind: Kind
    public let size: UInt64?
    public var id: String { path }
}

public struct TransferProgress: Sendable, Equatable {
    public let bytesTransferred: UInt64
    public let totalBytes: UInt64
    public var fractionCompleted: Double {
        totalBytes == 0 ? 1 : min(1, Double(bytesTransferred) / Double(totalBytes))
    }
}

/// SFTP v3 binary framing only; SSH authentication and cryptography belong to OpenSSH.
public struct SFTPBinaryWriter: Sendable {
    public private(set) var data = Data()
    public init() {}
    public mutating func byte(_ value: UInt8) { data.append(value) }
    public mutating func uint32(_ value: UInt32) {
        data.append(contentsOf: [UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16), UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)])
    }
    public mutating func uint64(_ value: UInt64) {
        uint32(UInt32(truncatingIfNeeded: value >> 32)); uint32(UInt32(truncatingIfNeeded: value))
    }
    public mutating func bytes(_ value: Data) {
        precondition(value.count <= Int(UInt32.max))
        uint32(UInt32(value.count)); data.append(value)
    }
    public mutating func string(_ value: String) { bytes(Data(value.utf8)) }
    public var framed: Data {
        var header = SFTPBinaryWriter(); header.uint32(UInt32(data.count)); return header.data + data
    }
}

public struct SFTPBinaryReader: Sendable {
    private let data: Data
    private var offset = 0
    public init(_ data: Data) { self.data = Data(data) }
    public var remaining: Int { data.count - offset }
    public mutating func byte() throws -> UInt8 {
        guard remaining >= 1 else { throw SFTPError.protocolViolation("truncated byte") }
        defer { offset += 1 }; return data[offset]
    }
    public mutating func uint32() throws -> UInt32 {
        guard remaining >= 4 else { throw SFTPError.protocolViolation("truncated integer") }
        var value: UInt32 = 0
        for _ in 0..<4 { value = (value << 8) | UInt32(try byte()) }
        return value
    }
    public mutating func uint64() throws -> UInt64 { (UInt64(try uint32()) << 32) | UInt64(try uint32()) }
    public mutating func bytes(maximum: Int = 1_048_576) throws -> Data {
        let count = Int(try uint32())
        guard count <= maximum, count <= remaining else { throw SFTPError.protocolViolation("invalid string length") }
        defer { offset += count }; return data.subdata(in: offset..<(offset + count))
    }
    public mutating func string(maximum: Int = 8192) throws -> String {
        guard let value = String(data: try bytes(maximum: maximum), encoding: .utf8) else {
            throw SFTPError.protocolViolation("invalid UTF-8 filename")
        }
        return value
    }
    public func requireEnd() throws {
        guard remaining == 0 else { throw SFTPError.protocolViolation("unexpected trailing data") }
    }
}

struct SFTPAttributes: Sendable {
    let size: UInt64?
    let permissions: UInt32?
    let modificationTime: UInt32?
    var kind: SFTPEntry.Kind {
        guard let permissions else { return .other }
        switch permissions & 0o170000 {
        case 0o100000: return .file
        case 0o040000: return .directory
        case 0o120000: return .symlink
        default: return .other
        }
    }
    static func decode(_ reader: inout SFTPBinaryReader) throws -> Self {
        let flags = try reader.uint32()
        guard flags & ~UInt32(0x8000_000f) == 0 else { throw SFTPError.protocolViolation("unknown attribute flags") }
        let size: UInt64? = flags & 1 != 0 ? try reader.uint64() : nil
        if flags & 2 != 0 { _ = try reader.uint32(); _ = try reader.uint32() }
        let permissions: UInt32? = flags & 4 != 0 ? try reader.uint32() : nil
        var modificationTime: UInt32?
        if flags & 8 != 0 { _ = try reader.uint32(); modificationTime = try reader.uint32() }
        if flags & 0x8000_0000 != 0 {
            let count = try reader.uint32()
            guard count <= 64 else { throw SFTPError.protocolViolation("too many extended attributes") }
            for _ in 0..<count { _ = try reader.bytes(); _ = try reader.bytes() }
        }
        return Self(size: size, permissions: permissions, modificationTime: modificationTime)
    }
}

enum SFTPPaths {
    static func remote(_ path: String) throws -> String {
        guard path.hasPrefix("/"), path.utf8.count <= 8192,
              !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || $0.properties.generalCategory == .format }),
              !path.contains("\\"), !path.contains(":") else {
            throw SFTPError.invalidPath("use an absolute SFTP path inside the configured share")
        }
        let components = path.split(separator: "/")
        guard !components.contains("."), !components.contains("..") else {
            throw SFTPError.invalidPath("parent and dot components are not allowed")
        }
        return "/" + components.joined(separator: "/")
    }
    static func append(_ name: String, to parent: String) throws -> String {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\\") else {
            throw SFTPError.invalidPath("invalid filename component")
        }
        return try remote((parent == "/" ? "" : parent) + "/" + name)
    }
    static func windowsFilename(_ name: String) throws {
        guard !name.isEmpty, name.utf16.count <= 240, name != ".", name != "..",
              !name.hasSuffix(" "), !name.hasSuffix("."),
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || $0.properties.generalCategory == .format }),
              name.rangeOfCharacter(from: CharacterSet(charactersIn: "<>:\"/\\|?*")) == nil else {
            throw SFTPError.invalidPath("filename is not supported by Windows")
        }
        let stem = String(name.split(separator: ".", omittingEmptySubsequences: false).first ?? "")
        let base = String(stem.reversed().drop(while: { $0 == " " }).reversed()).uppercased()
        let reserved = ["CON", "PRN", "AUX", "NUL", "CONIN$", "CONOUT$"] + (1...9).map { "COM\($0)" } + (1...9).map { "LPT\($0)" } + ["COM¹", "COM²", "COM³", "LPT¹", "LPT²", "LPT³"]
        guard !reserved.contains(base) else { throw SFTPError.invalidPath("reserved Windows filename") }
    }
}
