import Foundation
import Darwin
import KnotNativeCore

final class NativeFileSource {
    let name: String, size: Int64
    private let descriptor: Int32
    private let parent: Int32
    private let leaf: String
    private let initial: stat
    init(url: URL) throws {
        guard url.isFileURL, FileWire.validName(url.lastPathComponent) else { throw NativeFileError.unsupported }
        name = url.lastPathComponent
        parent = try FileTreeFS.openDirectory(url.deletingLastPathComponent())
        leaf = url.lastPathComponent
        descriptor = openat(parent, leaf, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { Darwin.close(parent); throw NativeFileError.denied }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1,
              FileWire.validSize(Int64(info.st_size)) else {
            Darwin.close(descriptor); Darwin.close(parent); throw NativeFileError.unsupported
        }
        initial = info; size = Int64(info.st_size)
    }
    init(descriptor: Int32, parent: Int32, name: String, captured: stat) throws {
        self.descriptor = descriptor; self.parent = parent; leaf = name; self.name = name; initial = captured; size = Int64(captured.st_size)
        do { try requireIdentity() } catch { Darwin.close(descriptor); Darwin.close(parent); throw error }
    }
    deinit { Darwin.close(descriptor); Darwin.close(parent) }
    private func requireIdentity() throws {
        var live = stat(), path = stat()
        guard fstat(descriptor, &live) == 0, fstatat(parent, leaf, &path, AT_SYMLINK_NOFOLLOW) == 0,
              FileTreeFS.same(live, initial), FileTreeFS.same(path, initial), live.st_nlink == 1 else { throw NativeFileError.changed }
    }
    func read(_ count: Int) throws -> Data {
        guard count > 0, count <= FileWire.chunkBytes else { throw NativeFileError.protocolViolation }
        var bytes = Data(count: count)
        let result = bytes.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, count) }
        guard result >= 0 else { throw NativeFileError.io }
        bytes.count = result; return bytes
    }
    func requireUnchanged() throws {
        try requireIdentity()
        var final = stat()
        guard fstat(descriptor, &final) == 0, final.st_dev == initial.st_dev, final.st_ino == initial.st_ino,
              final.st_size == initial.st_size, final.st_mtimespec.tv_sec == initial.st_mtimespec.tv_sec,
              final.st_mtimespec.tv_nsec == initial.st_mtimespec.tv_nsec,
              final.st_ctimespec.tv_sec == initial.st_ctimespec.tv_sec,
              final.st_ctimespec.tv_nsec == initial.st_ctimespec.tv_nsec else { throw NativeFileError.changed }
        var extra: UInt8 = 0
        guard Darwin.read(descriptor, &extra, 1) == 0 else { throw NativeFileError.changed }
    }
}

/// An exact picker/Finder destination. Existing files are never replaced or
/// silently renamed; only this object's fresh partial can be cleaned up.
final class NativeFileDestination {
    let url: URL
    private let directory: Int32
    private let staging: Int32
    private let stagingName: String
    private let stagingIdentity: stat
    private let canRemoveStagingPath: Bool
    private var descriptor: Int32
    private let partial: String
    private let name: String
    private var identity = stat()
    private var published = false
    private var ownsPartial = false
    init(url: URL, size: Int64) throws {
        guard url.isFileURL, FileWire.validName(url.lastPathComponent), FileWire.validSize(size) else { throw NativeFileError.unsupported }
        let localName = url.lastPathComponent, localStage = ".knot-\(UUID().uuidString).part", localPartial = "payload.part"
        let folderFD = try FileTreeFS.openDirectory(url.deletingLastPathComponent())
        guard folderFD >= 0 else { throw NativeFileError.denied }
        let privateParent = Self.privateParent(folderFD)
        var fileFD: Int32 = -1, stageFD: Int32 = -1, info = stat(), stageInfo = stat(), owns = false, createdStage = false
        do {
            var existing = stat()
            if fstatat(folderFD, localName, &existing, AT_SYMLINK_NOFOLLOW) == 0 { throw NativeFileError.exists }
            guard errno == ENOENT else { throw NativeFileError.io }
            var volume = statfs()
            if fstatfs(folderFD, &volume) == 0 {
                let available = UInt64(volume.f_bavail).multipliedReportingOverflow(by: UInt64(volume.f_bsize))
                guard !available.overflow, available.partialValue >= UInt64(size) + 67_108_864 else { throw NativeFileError.quota }
            }
            guard mkdirat(folderFD, localStage, 0o700) == 0 else { throw NativeFileError.io }
            createdStage = true
            stageFD = openat(folderFD, localStage, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard stageFD >= 0, fstat(stageFD, &stageInfo) == 0, stageInfo.st_uid == geteuid(),
                  (stageInfo.st_mode & S_IFMT) == S_IFDIR else { throw NativeFileError.denied }
            try Self.makePrivate(stageFD, mode: 0o700)
            fileFD = openat(stageFD, localPartial, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fileFD >= 0, fstat(fileFD, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
                  info.st_uid == geteuid(), info.st_nlink == 1 else { throw NativeFileError.io }
            owns = true
            try Self.makePrivate(fileFD, mode: 0o600)
            let marker = Data("0081;\(String(Int(Date().timeIntervalSince1970), radix: 16));Knot;".utf8)
            guard marker.withUnsafeBytes({ fsetxattr(fileFD, "com.apple.quarantine", $0.baseAddress, $0.count, 0, 0) }) == 0 else {
                throw NativeFileError.denied
            }
        } catch {
            if fileFD >= 0 { Darwin.close(fileFD) }
            var current = stat()
            if owns, stageFD >= 0, fstatat(stageFD, localPartial, &current, AT_SYMLINK_NOFOLLOW) == 0,
               current.st_dev == info.st_dev, current.st_ino == info.st_ino { unlinkat(stageFD, localPartial, 0) }
            if createdStage, privateParent, stageFD >= 0,
               fstatat(folderFD, localStage, &current, AT_SYMLINK_NOFOLLOW) == 0,
               current.st_dev == stageInfo.st_dev, current.st_ino == stageInfo.st_ino { unlinkat(folderFD, localStage, AT_REMOVEDIR) }
            if stageFD >= 0 { Darwin.close(stageFD) }
            Darwin.close(folderFD); throw error
        }
        self.url = url; name = localName; partial = localPartial
        directory = folderFD; staging = stageFD; stagingName = localStage; stagingIdentity = stageInfo
        canRemoveStagingPath = privateParent; descriptor = fileFD; identity = info; ownsPartial = true
    }
    deinit {
        if descriptor >= 0 { Darwin.close(descriptor) }
        if !published { removeOwnedPartial() }
        removeOwnedStagingPath()
        Darwin.close(staging)
        Darwin.close(directory)
    }
    func write(_ data: Data) throws {
        guard !data.isEmpty, data.count <= FileWire.chunkBytes, descriptor >= 0 else { throw NativeFileError.protocolViolation }
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let count = Darwin.write(descriptor, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                guard count > 0 else { throw NativeFileError.io }; offset += count
            }
        }
    }
    private func removeOwnedPartial() {
        var current = stat()
        if ownsPartial, fstatat(staging, partial, &current, AT_SYMLINK_NOFOLLOW) == 0,
           current.st_dev == identity.st_dev, current.st_ino == identity.st_ino,
           (current.st_mode & S_IFMT) == S_IFREG { unlinkat(staging, partial, 0) }
    }
    private func removeOwnedStagingPath() {
        // Never race rmdir against another UID in a shared writable parent.
        // Leaving an empty private stage is safer than deleting a replacement.
        var current = stat()
        if canRemoveStagingPath, fstatat(directory, stagingName, &current, AT_SYMLINK_NOFOLLOW) == 0,
           current.st_dev == stagingIdentity.st_dev, current.st_ino == stagingIdentity.st_ino,
           (current.st_mode & S_IFMT) == S_IFDIR { unlinkat(directory, stagingName, AT_REMOVEDIR) }
    }
    static func noACL(_ fd: Int32) -> Bool {
        guard let acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED) else { return errno == ENOENT }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        guard acl_valid(acl) == 0 else { return false }
        var entry: acl_entry_t?; errno = 0
        return acl_get_entry(acl, Int32(ACL_FIRST_ENTRY.rawValue), &entry) == -1 && errno == EINVAL
    }
    static func privateParent(_ fd: Int32) -> Bool {
        var info = stat()
        return fstat(fd, &info) == 0 && info.st_uid == geteuid() && (info.st_mode & 0o022) == 0 && noACL(fd)
    }
    static func makePrivate(_ fd: Int32, mode: mode_t) throws {
        guard fchmod(fd, mode) == 0, let acl = acl_init(0) else { throw NativeFileError.denied }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        guard acl_set_fd_np(fd, acl, ACL_TYPE_EXTENDED) == 0, noACL(fd) else { throw NativeFileError.denied }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == geteuid(), (info.st_mode & 0o7777) == mode else { throw NativeFileError.denied }
    }
    func prepare() throws {
        guard descriptor >= 0, fsync(descriptor) == 0 else { throw NativeFileError.io }
    }
    func publish() throws -> URL {
        var current = stat()
        guard !published, fstatat(staging, partial, &current, AT_SYMLINK_NOFOLLOW) == 0,
              current.st_dev == identity.st_dev, current.st_ino == identity.st_ino,
              (current.st_mode & S_IFMT) == S_IFREG else { throw NativeFileError.changed }
        guard renameatx_np(staging, partial, directory, name, UInt32(RENAME_EXCL)) == 0 else {
            throw errno == EEXIST ? NativeFileError.exists : .io
        }
        published = true; return url
    }
}
