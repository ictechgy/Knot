// SPDX-License-Identifier: GPL-3.0-only
import Darwin
import Foundation
import Security

struct KnotInstallIdentity: Equatable {
    let build: UInt64
    let version: String
    let codeHash: Data
    let team: String?
}

enum KnotInstallFailure: Error, LocalizedError {
    case unsafePath, invalidApplication, protectedLocation, olderVersion, changedApplication, cannotReplace
    var errorDescription: String? {
        switch self {
        case .unsafePath: "링크 또는 안전하지 않은 설치 경로입니다. 기존 앱과 설정은 보존했습니다."
        case .invalidApplication: "Knot 앱의 서명·버전·구성을 확인하지 못했습니다. 공식 설치 파일을 다시 받으세요."
        case .protectedLocation: "이 위치를 변경할 권한이 없습니다. 관리자가 Applications의 Knot 앱을 교체해야 합니다. 앱은 아직 종료하지 않았습니다."
        case .olderVersion: "현재 앱보다 새로운 버전만 설치할 수 있습니다."
        case .changedApplication: "설치 중 앱이나 설치 위치가 바뀌었습니다. 기존 파일은 자동으로 덮어쓰지 않습니다."
        case .cannotReplace: "앱을 교체하지 못했습니다. 기존 앱과 연결 설정은 보존했습니다."
        }
    }
}

/// The user explicitly launches this local installer. Ad-hoc validation checks
/// integrity, not publisher authenticity; it is never an online update bypass.
enum KnotInstallValidation {
    static func ordinaryDirectory(_ url: URL) throws -> stat {
        // standardizedFileURL resolves Apple's /private/var alias, so it cannot
        // be used as a lexical path check. Inspect every original component.
        let parts = url.path.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
        guard url.isFileURL, url.path.hasPrefix("/"),
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { throw KnotInstallFailure.unsafePath }
        var current = URL(fileURLWithPath: "/", isDirectory: true)
        for part in url.pathComponents.dropFirst() {
            current.appendPathComponent(part)
            var value = stat()
            guard lstat(current.path, &value) == 0,
                  value.st_mode & S_IFMT == S_IFDIR,
                  value.st_mode & 0o002 == 0 else { throw KnotInstallFailure.unsafePath }
        }
        var value = stat()
        guard lstat(url.path, &value) == 0 else { throw KnotInstallFailure.unsafePath }
        return value
    }

    static func sameNode(_ a: stat, _ b: stat) -> Bool {
        a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_uid == b.st_uid
    }

    static func identity(_ url: URL) throws -> KnotInstallIdentity {
        _ = try ordinaryDirectory(url)
        guard url.pathExtension == "app" else { throw KnotInstallFailure.invalidApplication }
        var code: SecStaticCode?, information: CFDictionary?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckNestedCode | kSecCSCheckAllArchitectures), nil) == errSecSuccess,
              SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let info = information as? [String: Any],
              info[kSecCodeInfoIdentifier as String] as? String == "org.deskbridge.app",
              let hash = info[kSecCodeInfoUnique as String] as? Data, !hash.isEmpty,
              let plist = info[kSecCodeInfoPList as String] as? [String: Any],
              plist["CFBundleIdentifier"] as? String == "org.deskbridge.app",
              plist["CFBundleExecutable"] as? String == "DeskBridge",
              let number = plist["CFBundleVersion"] as? String,
              !number.isEmpty, number.count <= 16, number.first != "0",
              number.utf8.allSatisfy({ (48...57).contains($0) }), let build = UInt64(number),
              let version = plist["DeskBridgeVersion"] as? String,
              !version.isEmpty, version.utf8.count <= 64 else {
            throw KnotInstallFailure.invalidApplication
        }
        let team = info[kSecCodeInfoTeamIdentifier as String] as? String
        if let team {
            guard team.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) }) else { throw KnotInstallFailure.invalidApplication }
            var requirement: SecRequirement?
            guard SecRequirementCreateWithString(("anchor apple generic and certificate leaf[subject.OU] = \"" + team + "\"") as CFString, [], &requirement) == errSecSuccess,
                  SecStaticCodeCheckValidity(code, [], requirement) == errSecSuccess else { throw KnotInstallFailure.invalidApplication }
        }
        return KnotInstallIdentity(build: build, version: version, codeHash: hash, team: team)
    }

    static func permits(_ new: KnotInstallIdentity, replacing old: KnotInstallIdentity?) throws {
        guard let old else { return }
        guard new.build > old.build else { throw KnotInstallFailure.olderVersion }
        // A local preview may advance to a signed app. A signed installation may
        // never be replaced by an ad-hoc app or a different Apple team.
        if let team = old.team, new.team != team { throw KnotInstallFailure.invalidApplication }
    }
}

/// One adjacent staged bundle and an atomic exchange: the installed path is
/// never temporarily missing. No app data, credentials or settings are touched.
final class KnotInstallTransaction {
    typealias Validate = (URL) throws -> KnotInstallIdentity
    let destination: URL
    let staged: URL
    let payload: KnotInstallIdentity
    let previous: KnotInstallIdentity?
    private let parent: URL, parentNode: stat, validate: Validate
    private var lock: Int32 = -1
    private var stagedNode: stat?
    private var destinationNode: stat?
    private(set) var committed = false

    init(source: URL, destination: URL, validate: @escaping Validate = KnotInstallValidation.identity) throws {
        let fm = FileManager.default
        self.validate = validate; self.destination = destination
        parent = destination.deletingLastPathComponent()
        parentNode = try KnotInstallValidation.ordinaryDirectory(parent)
        guard fm.isWritableFile(atPath: parent.path) else { throw KnotInstallFailure.protectedLocation }
        guard destination.lastPathComponent == "Knot.app" || destination.lastPathComponent == "DeskBridge.app",
              source.standardizedFileURL != destination.standardizedFileURL else { throw KnotInstallFailure.unsafePath }
        // Lock the directory itself: a persistent user-owned lock file would
        // prevent another administrator from updating a shared installation.
        // The descriptor also anchors the eventual atomic rename.
        lock = open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard lock >= 0 else { throw KnotInstallFailure.protectedLocation }
        var lockNode = stat()
        guard fstat(lock, &lockNode) == 0, KnotInstallValidation.sameNode(parentNode, lockNode),
              flock(lock, LOCK_EX | LOCK_NB) == 0 else {
            close(lock); lock = -1; throw KnotInstallFailure.protectedLocation
        }
        staged = parent.appendingPathComponent(".Knot-update-" + UUID().uuidString + ".app")
        do {
            payload = try validate(source)
            var node = stat()
            if lstat(destination.path, &node) == 0 {
                destinationNode = try KnotInstallValidation.ordinaryDirectory(destination)
                previous = try validate(destination)
            } else {
                guard errno == ENOENT else { throw KnotInstallFailure.unsafePath }
                previous = nil
            }
            try KnotInstallValidation.permits(payload, replacing: previous)
            try fm.copyItem(at: source, to: staged)
            stagedNode = try KnotInstallValidation.ordinaryDirectory(staged)
            guard try validate(staged) == payload else { throw KnotInstallFailure.changedApplication }
        } catch {
            // Only remove a bundle created by this invocation, after checking its inode.
            if let node = stagedNode, let current = try? KnotInstallValidation.ordinaryDirectory(staged), KnotInstallValidation.sameNode(node, current) {
                try? fm.removeItem(at: staged)
            }
            close(lock); lock = -1; throw error
        }
    }

    deinit { if lock >= 0 { close(lock) } }

    private func checkParent() throws {
        guard KnotInstallValidation.sameNode(parentNode, try KnotInstallValidation.ordinaryDirectory(parent)) else { throw KnotInstallFailure.changedApplication }
    }

    func commit() throws {
        guard !committed else { throw KnotInstallFailure.changedApplication }
        try checkParent()
        guard let stagedNode, KnotInstallValidation.sameNode(stagedNode, try KnotInstallValidation.ordinaryDirectory(staged)),
              try validate(staged) == payload else { throw KnotInstallFailure.changedApplication }
        let flags: UInt32
        if let previous, let destinationNode {
            guard KnotInstallValidation.sameNode(destinationNode, try KnotInstallValidation.ordinaryDirectory(destination)),
                  try validate(destination) == previous else { throw KnotInstallFailure.changedApplication }
            flags = UInt32(RENAME_SWAP)
        } else {
            var node = stat()
            guard lstat(destination.path, &node) != 0, errno == ENOENT else { throw KnotInstallFailure.changedApplication }
            flags = UInt32(RENAME_EXCL)
        }
        guard renameatx_np(lock, staged.lastPathComponent, lock, destination.lastPathComponent, flags) == 0 else { throw KnotInstallFailure.cannotReplace }
        let newNode = stagedNode
        self.stagedNode = destinationNode; destinationNode = newNode
        committed = true
    }

    func rollback() throws {
        guard committed, let previous else { return }
        try checkParent()
        guard let destinationNode, let stagedNode,
              KnotInstallValidation.sameNode(destinationNode, try KnotInstallValidation.ordinaryDirectory(destination)),
              KnotInstallValidation.sameNode(stagedNode, try KnotInstallValidation.ordinaryDirectory(staged)),
              try validate(destination) == payload, try validate(staged) == previous,
              renameatx_np(lock, staged.lastPathComponent, lock, destination.lastPathComponent, UInt32(RENAME_SWAP)) == 0 else { throw KnotInstallFailure.changedApplication }
        self.destinationNode = stagedNode; self.stagedNode = destinationNode
        committed = false
    }

    /// Call after the new app has launched, or after a failed pre-commit attempt.
    /// A rollback leaves the unused new payload at the generated staging name.
    func discardStaged() throws {
        try checkParent()
        let expected = committed ? previous : payload
        guard let expected else { return } // Fresh install consumed its staging path.
        guard let stagedNode, KnotInstallValidation.sameNode(stagedNode, try KnotInstallValidation.ordinaryDirectory(staged)),
              try validate(staged) == expected else { throw KnotInstallFailure.changedApplication }
        try FileManager.default.removeItem(at: staged)
    }
}
