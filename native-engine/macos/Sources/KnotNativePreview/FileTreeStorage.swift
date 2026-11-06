import Foundation
import Darwin
import UniformTypeIdentifiers
import KnotNativeCore

enum FileTreeFS {
    static func same(_ a: stat, _ b: stat) -> Bool {
        a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_mode == b.st_mode && a.st_size == b.st_size &&
        a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec &&
        a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
    }
    static func identity(_ a: stat, _ b: stat) -> Bool { a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_gen == b.st_gen && a.st_birthtimespec.tv_sec == b.st_birthtimespec.tv_sec && a.st_birthtimespec.tv_nsec == b.st_birthtimespec.tv_nsec && (a.st_mode & S_IFMT) == (b.st_mode & S_IFMT) }
    static func openDirectory(_ url: URL) throws -> Int32 {
        guard url.isFileURL, url.path.hasPrefix("/") else { throw NativeFileError.unsupported }
        var fd = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw NativeFileError.denied }
        do {
            for part in url.path.split(separator: "/").map(String.init) {
                guard part != ".", part != ".." else { throw NativeFileError.unsupported }
                let next = openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                guard next >= 0 else { throw NativeFileError.denied }
                Darwin.close(fd); fd = next
            }
            return fd
        } catch { Darwin.close(fd); throw error }
    }
    static func package(_ name: String) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        return ["app", "bundle", "framework", "plugin", "kext", "xpc", "appex", "rtfd", "photoslibrary", "playground", "pkg"].contains(ext) || UTType(filenameExtension: ext)?.conforms(to: .package) == true
    }
    static func quarantine(_ fd: Int32) throws {
        let marker = Data("0081;\(String(Int(Date().timeIntervalSince1970), radix: 16));Knot;".utf8)
        guard marker.withUnsafeBytes({ fsetxattr(fd, "com.apple.quarantine", $0.baseAddress, $0.count, 0, 0) }) == 0 else { throw NativeFileError.denied }
    }
    static func write(_ fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let count = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                guard count > 0 else { throw NativeFileError.io }; offset += count
            }
        }
    }
}

/// A complete metadata snapshot, anchored at a no-follow root and its parent.
/// Directory handles are reopened component by component, keeping descriptor use bounded.
final class NativeFileTreeSource {
    struct Item { let node: NativeFileNode; let raw: Data; let captured: stat }
    let name: String
    private(set) var items: [Item] = []
    private(set) var size: Int64 = 0
    private let parent: Int32, root: Int32
    private let initial: stat
    private var admission = try! NativeFileTreeAdmission(count: FileWire.maximumTreeNodes, size: FileWire.maximumSize)
    init(url: URL) throws {
        guard url.isFileURL, FileWire.validName(url.lastPathComponent), !FileTreeFS.package(url.lastPathComponent) else { throw NativeFileError.unsupported }
        name = url.lastPathComponent
        parent = try FileTreeFS.openDirectory(url.deletingLastPathComponent())
        root = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        var info = stat()
        guard root >= 0, fstat(root, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else {
            if root >= 0 { Darwin.close(root) }; Darwin.close(parent); throw NativeFileError.unsupported
        }
        initial = info
        do { try scan(root, parentID: 0); try requireUnchanged() }
        catch { Darwin.close(root); Darwin.close(parent); throw error }
    }
    deinit { Darwin.close(root); Darwin.close(parent) }
    private func scan(_ directory: Int32, parentID: Int) throws {
        guard let stream = fdopendir(dup(directory)) else { throw NativeFileError.io }
        defer { closedir(stream) }
        var names: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(stream) else { guard errno == 0 else { throw NativeFileError.io }; break }
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(validatingCString: $0) }
            }
            guard let name else { throw NativeFileError.unsupported }
            if name == "." || name == ".." { continue }
            guard names.count < FileWire.maximumTreeNodes else { throw NativeFileError.quota }; names.append(name)
        }
        for name in names.sorted() {
            try Task.checkCancellation()
            var captured = stat()
            guard FileWire.validName(name), fstatat(directory, name, &captured, AT_SYMLINK_NOFOLLOW) == 0 else { throw NativeFileError.unsupported }
            let kind: NativeFileEntryKind
            switch captured.st_mode & S_IFMT {
            case S_IFDIR: guard !FileTreeFS.package(name) else { throw NativeFileError.unsupported }; kind = .folder
            case S_IFREG: guard captured.st_nlink == 1 else { throw NativeFileError.unsupported }; kind = .file
            default: throw NativeFileError.unsupported
            }
            guard items.count < FileWire.maximumTreeNodes else { throw NativeFileError.quota }
            let node = try NativeFileNode(id: items.count + 1, parent: parentID, name: name, kind: kind, size: kind == .file ? Int64(captured.st_size) : 0)
            let raw = try node.json; try admission.append(raw)
            items.append(Item(node: node, raw: raw, captured: captured)); size += node.size
            if kind == .folder {
                let child = openat(directory, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                guard child >= 0 else { throw NativeFileError.changed }
                defer { Darwin.close(child) }
                var live = stat()
                guard fstat(child, &live) == 0, FileTreeFS.same(live, captured) else { throw NativeFileError.changed }
                try scan(child, parentID: node.id)
                guard fstat(child, &live) == 0, FileTreeFS.same(live, captured) else { throw NativeFileError.changed }
            }
        }
    }
    private func openParent(_ id: Int) throws -> Int32 {
        var ancestry: [Int] = [], current = id
        while current > 0 { ancestry.append(current); current = items[current - 1].node.parent }
        var fd = dup(root); guard fd >= 0 else { throw NativeFileError.io }
        do {
            for id in ancestry.reversed() {
                let item = items[id - 1], next = openat(fd, item.node.name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                guard next >= 0 else { throw NativeFileError.changed }
                var live = stat()
                guard fstat(next, &live) == 0, FileTreeFS.same(live, item.captured) else { Darwin.close(next); throw NativeFileError.changed }
                Darwin.close(fd); fd = next
            }
            return fd
        } catch { Darwin.close(fd); throw error }
    }
    func openFile(_ item: Item) throws -> NativeFileSource {
        try requireRootUnchanged()
        let directory = try openParent(item.node.parent)
        let fd = openat(directory, item.node.name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { Darwin.close(directory); throw NativeFileError.changed }
        return try NativeFileSource(descriptor: fd, parent: directory, name: item.node.name, captured: item.captured)
    }
    private func requireRootUnchanged() throws {
        var live = stat(), path = stat()
        guard fstat(root, &live) == 0, fstatat(parent, name, &path, AT_SYMLINK_NOFOLLOW) == 0,
              FileTreeFS.same(live, initial), FileTreeFS.same(path, initial) else { throw NativeFileError.changed }
    }
    func requireUnchanged() throws {
        try requireRootUnchanged()
        var path = stat()
        for item in items {
            let directory = try openParent(item.node.parent); defer { Darwin.close(directory) }
            guard fstatat(directory, item.node.name, &path, AT_SYMLINK_NOFOLLOW) == 0,
                  FileTreeFS.same(path, item.captured) else { throw NativeFileError.changed }
        }
    }
}

/// One private tree, created exclusively and renamed as a single root only
/// after every leaf, structure/hash check and live-run check has succeeded.
final class NativeFileTreeDestination {
    private struct Owned { let node: NativeFileNode; let identity: stat }
    let url: URL
    private let directory: Int32, staging: Int32, root: Int32
    private let stagingName: String, rootName = "payload", name: String
    private let stageIdentity: stat, rootIdentity: stat, mayRemoveStage: Bool
    private var owned: [Owned] = []
    private var file: Int32 = -1, fileSize: Int64 = 0, fileWritten: Int64 = 0
    private var published = false
    init(url: URL, size: Int64) throws {
        guard url.isFileURL, FileWire.validName(url.lastPathComponent), FileWire.validSize(size) else { throw NativeFileError.unsupported }
        self.url = url; name = url.lastPathComponent; stagingName = ".knot-\(UUID().uuidString).part"
        directory = try FileTreeFS.openDirectory(url.deletingLastPathComponent())
        mayRemoveStage = NativeFileDestination.privateParent(directory)
        var stageFD: Int32 = -1, rootFD: Int32 = -1, stageInfo = stat(), rootInfo = stat()
        do {
            var existing = stat()
            guard fstatat(directory, name, &existing, AT_SYMLINK_NOFOLLOW) != 0 else { throw NativeFileError.exists }
            guard errno == ENOENT else { throw NativeFileError.io }
            var volume = statfs()
            if fstatfs(directory, &volume) == 0 {
                let available = UInt64(volume.f_bavail).multipliedReportingOverflow(by: UInt64(volume.f_bsize))
                guard !available.overflow, available.partialValue >= UInt64(size) + 67_108_864 else { throw NativeFileError.quota }
            }
            guard mkdirat(directory, stagingName, 0o700) == 0 else { throw NativeFileError.io }
            stageFD = openat(directory, stagingName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard stageFD >= 0, fstat(stageFD, &stageInfo) == 0 else { throw NativeFileError.io }
            try NativeFileDestination.makePrivate(stageFD, mode: 0o700)
            guard mkdirat(stageFD, rootName, 0o700) == 0 else { throw NativeFileError.io }
            rootFD = openat(stageFD, rootName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard rootFD >= 0, fstat(rootFD, &rootInfo) == 0 else { throw NativeFileError.io }
            try NativeFileDestination.makePrivate(rootFD, mode: 0o700)
        } catch {
            if rootFD >= 0 {
                var current = stat()
                if fstatat(stageFD, "payload", &current, AT_SYMLINK_NOFOLLOW) == 0, FileTreeFS.identity(current, rootInfo) { unlinkat(stageFD, "payload", AT_REMOVEDIR) }
                Darwin.close(rootFD)
            }
            if stageFD >= 0 { Darwin.close(stageFD) }
            if mayRemoveStage { var current = stat(); if fstatat(directory, stagingName, &current, AT_SYMLINK_NOFOLLOW) == 0, FileTreeFS.identity(current, stageInfo) { unlinkat(directory, stagingName, AT_REMOVEDIR) } }
            Darwin.close(directory); throw error
        }
        staging = stageFD; root = rootFD; stageIdentity = stageInfo; rootIdentity = rootInfo
    }
    deinit {
        if file >= 0 { Darwin.close(file) }
        if !published {
            for item in owned.reversed() {
                guard let parent = try? openParent(item.node.parent) else { continue }
                var live = stat()
                if fstatat(parent, item.node.name, &live, AT_SYMLINK_NOFOLLOW) == 0, FileTreeFS.identity(live, item.identity) {
                    unlinkat(parent, item.node.name, item.node.kind == .folder ? AT_REMOVEDIR : 0)
                }
                Darwin.close(parent)
            }
            var live = stat()
            if fstatat(staging, rootName, &live, AT_SYMLINK_NOFOLLOW) == 0, FileTreeFS.identity(live, rootIdentity) { unlinkat(staging, rootName, AT_REMOVEDIR) }
        }
        var live = stat()
        if mayRemoveStage, fstatat(directory, stagingName, &live, AT_SYMLINK_NOFOLLOW) == 0, FileTreeFS.identity(live, stageIdentity) { unlinkat(directory, stagingName, AT_REMOVEDIR) }
        Darwin.close(root); Darwin.close(staging); Darwin.close(directory)
    }
    private func openParent(_ id: Int) throws -> Int32 {
        var ancestry: [Int] = [], current = id
        while current > 0 { guard current <= owned.count else { throw NativeFileError.protocolViolation }; ancestry.append(current); current = owned[current - 1].node.parent }
        var fd = dup(root); guard fd >= 0 else { throw NativeFileError.io }
        do {
            for id in ancestry.reversed() {
                let item = owned[id - 1], next = openat(fd, item.node.name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                guard next >= 0 else { throw NativeFileError.changed }
                var live = stat()
                guard fstat(next, &live) == 0, FileTreeFS.identity(live, item.identity) else { Darwin.close(next); throw NativeFileError.changed }
                Darwin.close(fd); fd = next
            }
            return fd
        } catch { Darwin.close(fd); throw error }
    }
    func create(_ node: NativeFileNode) throws {
        guard file < 0, node.id == owned.count + 1 else { throw NativeFileError.protocolViolation }
        let parent = try openParent(node.parent); defer { Darwin.close(parent) }
        let fd: Int32
        if node.kind == .folder {
            guard mkdirat(parent, node.name, 0o700) == 0 else { throw NativeFileError.io }
            fd = openat(parent, node.name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        } else { fd = openat(parent, node.name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600) }
        guard fd >= 0 else { throw NativeFileError.io }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == geteuid(),
              (info.st_mode & S_IFMT) == (node.kind == .folder ? S_IFDIR : S_IFREG), node.kind == .folder || info.st_nlink == 1 else { Darwin.close(fd); throw NativeFileError.io }
        owned.append(Owned(node: node, identity: info))
        do {
            try NativeFileDestination.makePrivate(fd, mode: node.kind == .folder ? 0o700 : 0o600)
            if node.kind == .file { try FileTreeFS.quarantine(fd); file = fd; fileSize = node.size; fileWritten = 0 }
            else { guard fsync(fd) == 0 else { throw NativeFileError.io }; Darwin.close(fd) }
        } catch { Darwin.close(fd); throw error }
    }
    func write(_ data: Data) throws {
        guard file >= 0, !data.isEmpty, data.count <= FileWire.chunkBytes, Int64(data.count) <= fileSize - fileWritten else { throw NativeFileError.protocolViolation }
        try FileTreeFS.write(file, data); fileWritten += Int64(data.count)
    }
    func finishFile() throws {
        guard file >= 0, fileWritten == fileSize, fsync(file) == 0 else { throw NativeFileError.io }
        var live = stat()
        guard fstat(file, &live) == 0, live.st_nlink == 1, live.st_size == fileSize else { throw NativeFileError.changed }
        Darwin.close(file); file = -1
    }
    func prepare() throws {
        guard file < 0 else { throw NativeFileError.protocolViolation }
        for item in owned.reversed() {
            let parent = try openParent(item.node.parent); defer { Darwin.close(parent) }
            var live = stat()
            guard fstatat(parent, item.node.name, &live, AT_SYMLINK_NOFOLLOW) == 0, FileTreeFS.identity(live, item.identity),
                  item.node.kind == .folder || (live.st_size == item.node.size && live.st_nlink == 1) else { throw NativeFileError.changed }
            guard fsync(parent) == 0 else { throw NativeFileError.io }
        }
        guard fsync(root) == 0, fsync(staging) == 0 else { throw NativeFileError.io }
    }
    func publish() throws -> URL {
        var live = stat(), stage = stat()
        guard !published, fstatat(staging, rootName, &live, AT_SYMLINK_NOFOLLOW) == 0, FileTreeFS.identity(live, rootIdentity),
              fstatat(directory, stagingName, &stage, AT_SYMLINK_NOFOLLOW) == 0, FileTreeFS.identity(stage, stageIdentity) else { throw NativeFileError.changed }
        guard renameatx_np(staging, rootName, directory, name, UInt32(RENAME_EXCL)) == 0 else { throw errno == EEXIST ? NativeFileError.exists : .io }
        published = true; return url
    }
}
