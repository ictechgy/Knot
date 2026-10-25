// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Darwin

/// Operates only on newly generated, inert, ad-hoc-signed fixtures supplied by
/// test_mac_installer.py. Never launches an application or reads user app data.
@main struct MacInstallerChecks {
    static func main() {
        do { try run() } catch { print("Synthetic installer check failed: \(error)"); exit(1) }
    }
    static func run() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let fm = FileManager.default
        let payload = root.appendingPathComponent("payload/Knot.app")
        let old = root.appendingPathComponent("old/Knot.app")
        var count = 0
        func check(_ value: Bool, _ label: String) throws {
            guard value else { throw NSError(domain: label, code: 1) }; count += 1
        }
        func refuses(_ label: String, _ operation: () throws -> Void) throws {
            do { try operation() } catch is KnotInstallFailure { count += 1; return }
            throw NSError(domain: label, code: 2)
        }
        func destination(_ name: String, existing: Bool = true) throws -> URL {
            let parent = root.appendingPathComponent("cases/" + name, isDirectory: true)
            try fm.createDirectory(at: parent, withIntermediateDirectories: true)
            let path = parent.appendingPathComponent("Knot.app")
            if existing { try fm.copyItem(at: old, to: path) }
            return path
        }
        let newID = try KnotInstallValidation.identity(payload)
        let oldID = try KnotInstallValidation.identity(old)
        print("Synthetic identities validated")
        try check(newID.build == 201 && oldID.build == 200, "signed Info.plist identities")
        try refuses("same build") { try KnotInstallValidation.permits(oldID, replacing: oldID) }
        try refuses("downgrade") { try KnotInstallValidation.permits(oldID, replacing: newID) }
        let teamID = KnotInstallIdentity(build: 200, version: "fixture", codeHash: Data([1]), team: "TEAM123")
        try refuses("signed to ad-hoc") { try KnotInstallValidation.permits(newID, replacing: teamID) }
        try refuses("tampered code") { _ = try KnotInstallValidation.identity(root.appendingPathComponent("tampered/Knot.app")) }
        try refuses("foreign identity") { _ = try KnotInstallValidation.identity(root.appendingPathComponent("foreign/Knot.app")) }

        let path = try destination("replace")
        let sentinel = path.deletingLastPathComponent().appendingPathComponent("synthetic-settings")
        try Data("unchanged".utf8).write(to: sentinel)
        do {
            let tx = try KnotInstallTransaction(source: payload, destination: path)
            print("Synthetic replacement staged")
            try check(try KnotInstallValidation.identity(path) == oldID, "stage preserves old app")
            try refuses("concurrent transaction") { _ = try KnotInstallTransaction(source: payload, destination: path) }
            try tx.commit()
            try check(try KnotInstallValidation.identity(path) == newID, "atomic replacement")
            try check(try KnotInstallValidation.identity(tx.staged) == oldID, "rollback bundle retained")
            try tx.rollback()
            try check(try KnotInstallValidation.identity(path) == oldID, "atomic rollback")
            try tx.discardStaged()
            try check(!fm.fileExists(atPath: tx.staged.path), "discard own staged payload")
        }
        do {
            let tx = try KnotInstallTransaction(source: payload, destination: path)
            try tx.commit(); try tx.discardStaged()
            try check(try KnotInstallValidation.identity(path) == newID, "upgrade after lock release")
        }
        try check(try Data(contentsOf: sentinel) == Data("unchanged".utf8), "settings untouched")
        let fresh = try destination("fresh", existing: false)
        do {
            let tx = try KnotInstallTransaction(source: payload, destination: fresh)
            try check(tx.previous == nil, "first install")
            try tx.commit(); try tx.discardStaged()
            try check(try KnotInstallValidation.identity(fresh) == newID, "first install identity")
        }
        let changed = try destination("changed")
        do {
            let tx = try KnotInstallTransaction(source: payload, destination: changed)
            try fm.removeItem(at: changed); try fm.copyItem(at: payload, to: changed)
            try refuses("destination changed during drain") { try tx.commit() }
            try check(try KnotInstallValidation.identity(changed) == newID, "changed app not overwritten")
            try tx.discardStaged()
        }
        let changedStage = try destination("stage-changed")
        do {
            let tx = try KnotInstallTransaction(source: payload, destination: changedStage)
            try fm.removeItem(at: tx.staged); try fm.copyItem(at: old, to: tx.staged)
            try refuses("stage changed during drain") { try tx.commit() }
            try check(try KnotInstallValidation.identity(changedStage) == oldID, "old app survives tampered stage")
        }
        let collision = try destination("collision", existing: false)
        do {
            let tx = try KnotInstallTransaction(source: payload, destination: collision)
            try fm.copyItem(at: old, to: collision)
            try refuses("first-install collision") { try tx.commit() }
            try tx.discardStaged()
        }
        let link = root.appendingPathComponent("source-link.app")
        try fm.createSymbolicLink(at: link, withDestinationURL: payload)
        try refuses("source symlink") { _ = try KnotInstallTransaction(source: link, destination: destination("source-link")) }
        let linkedDestination = try destination("destination-link", existing: false)
        try fm.createSymbolicLink(at: linkedDestination, withDestinationURL: old)
        try refuses("destination symlink") { _ = try KnotInstallTransaction(source: payload, destination: linkedDestination) }
        let linkedParent = root.appendingPathComponent("parent-link")
        try fm.createSymbolicLink(at: linkedParent, withDestinationURL: path.deletingLastPathComponent())
        try refuses("parent symlink") { _ = try KnotInstallTransaction(source: payload, destination: linkedParent.appendingPathComponent("Knot.app")) }
        try check(!(try fm.contentsOfDirectory(atPath: path.deletingLastPathComponent().path)).contains(".knot-install.lock"), "no persistent user-owned lock")
        print("Mac installer: \(count) checks passed; synthetic signed bundles only; no app launched")
    }
}
