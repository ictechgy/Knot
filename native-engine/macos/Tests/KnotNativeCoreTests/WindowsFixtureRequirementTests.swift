import Foundation
import Testing

/// CI's cross-platform checks may not silently become local optional skips.
enum WindowsFixtureRequirement {
    enum Failure: Error, Equatable { case missingDirectory, invalidArtifact(String) }
    static let files = ["synthetic.h264", "synthetic-codec.json", "synthetic-4k.h264", "synthetic-codec-4k.json",
                        "synthetic-4k60.h264", "synthetic-4k60.json", "synthetic-reconfigure.h264", "synthetic-reconfigure.json",
                        "native-test-public.cer", "native-test-public.sha256", "native-file-vectors.json"]
    static func validate(environment: [String: String],
                         attributes: (String) throws -> [FileAttributeKey: Any] = {
                             try FileManager.default.attributesOfItem(atPath: $0)
                         }) throws {
        guard environment["KNOT_NATIVE_REQUIRE_WINDOWS_FIXTURES"] == "1" else { return }
        guard let path = environment["KNOT_NATIVE_WINDOWS_FIXTURES"], !path.isEmpty,
              let root = try? attributes(path), root[.type] as? FileAttributeType == .typeDirectory else {
            throw Failure.missingDirectory
        }
        for name in files {
            let path = URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent(name).path
            guard let value = try? attributes(path), value[.type] as? FileAttributeType == .typeRegular,
                  let size = value[.size] as? NSNumber, size.int64Value > 0 else {
                throw Failure.invalidArtifact(name)
            }
        }
    }
}

enum WindowsPersistentCertificateRequirement {
    enum Failure: Error, Equatable { case missingPath, invalidArtifact }
    static func validate(environment: [String: String],
                         attributes: (String) throws -> [FileAttributeKey: Any] = {
                             try FileManager.default.attributesOfItem(atPath: $0)
                         }) throws -> String? {
        guard let path = environment["KNOT_NATIVE_WINDOWS_PERSISTENT_CERTIFICATE"], !path.isEmpty else {
            if environment["KNOT_NATIVE_REQUIRE_WINDOWS_FIXTURES"] == "1" { throw Failure.missingPath }
            return nil
        }
        guard let value = try? attributes(path), value[.type] as? FileAttributeType == .typeRegular,
              let size = value[.size] as? NSNumber, size.int64Value > 0, size.int64Value <= 65_536 else {
            throw Failure.invalidArtifact
        }
        return path
    }
}

@Test func requiredWindowsFixtureInputsArePresent() throws {
    try WindowsFixtureRequirement.validate(environment: ProcessInfo.processInfo.environment)
    _ = try WindowsPersistentCertificateRequirement.validate(environment: ProcessInfo.processInfo.environment)
}

@Test func persistentCertificateFixtureCannotSilentlySkipRequiredCI() throws {
    var queries = 0
    let attributes: (String) throws -> [FileAttributeKey: Any] = { _ in
        queries += 1
        return [.type: FileAttributeType.typeRegular, .size: NSNumber(value: 1024)]
    }
    #expect(try WindowsPersistentCertificateRequirement.validate(environment: [:], attributes: attributes) == nil)
    #expect(throws: WindowsPersistentCertificateRequirement.Failure.missingPath) {
        try WindowsPersistentCertificateRequirement.validate(environment: ["KNOT_NATIVE_REQUIRE_WINDOWS_FIXTURES": "1"], attributes: attributes)
    }
    #expect(queries == 0)
    let environment = ["KNOT_NATIVE_REQUIRE_WINDOWS_FIXTURES": "1", "KNOT_NATIVE_WINDOWS_PERSISTENT_CERTIFICATE": "/synthetic/persistent-certificate.cer"]
    #expect(try WindowsPersistentCertificateRequirement.validate(environment: environment, attributes: attributes) == environment["KNOT_NATIVE_WINDOWS_PERSISTENT_CERTIFICATE"])
    for value: [FileAttributeKey: Any] in [[.type: FileAttributeType.typeDirectory, .size: NSNumber(value: 1024)],
                                         [.type: FileAttributeType.typeSymbolicLink, .size: NSNumber(value: 1024)],
                                         [.type: FileAttributeType.typeRegular, .size: NSNumber(value: 0)],
                                         [.type: FileAttributeType.typeRegular, .size: NSNumber(value: 65_537)]] {
        #expect(throws: WindowsPersistentCertificateRequirement.Failure.invalidArtifact) {
            try WindowsPersistentCertificateRequirement.validate(environment: environment, attributes: { _ in value })
        }
    }
}

@Test func requiredFixtureFlagFailsWithoutAPathAndOptionalLocalRunDoesNotInspectOne() throws {
    var queries = 0
    let attributes: (String) throws -> [FileAttributeKey: Any] = { _ in
        queries += 1; throw WindowsFixtureRequirement.Failure.missingDirectory
    }
    try WindowsFixtureRequirement.validate(environment: [:], attributes: attributes)
    try WindowsFixtureRequirement.validate(environment: ["KNOT_NATIVE_WINDOWS_FIXTURES": "/unused-synthetic-path"], attributes: attributes)
    #expect(throws: WindowsFixtureRequirement.Failure.missingDirectory) {
        try WindowsFixtureRequirement.validate(environment: ["KNOT_NATIVE_REQUIRE_WINDOWS_FIXTURES": "1"], attributes: attributes)
    }
    #expect(queries == 0)
}

@Test func requiredFixtureSetRejectsEachMissingEmptyDirectoryOrSymlinkArtifact() throws {
    let manager = FileManager.default
    let root = manager.temporaryDirectory.appendingPathComponent("knot-required-fixtures-" + UUID().uuidString, isDirectory: true)
    try manager.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? manager.removeItem(at: root) }
    let environment = ["KNOT_NATIVE_REQUIRE_WINDOWS_FIXTURES": "1", "KNOT_NATIVE_WINDOWS_FIXTURES": root.path]
    for name in WindowsFixtureRequirement.files { try Data([1]).write(to: root.appendingPathComponent(name)) }
    try WindowsFixtureRequirement.validate(environment: environment)
    for name in WindowsFixtureRequirement.files {
        let path = root.appendingPathComponent(name)
        try manager.removeItem(at: path)
        #expect(throws: WindowsFixtureRequirement.Failure.invalidArtifact(name)) {
            try WindowsFixtureRequirement.validate(environment: environment)
        }
        try Data([1]).write(to: path)
    }
    let name = WindowsFixtureRequirement.files[0], path = root.appendingPathComponent(name)
    try Data().write(to: path)
    #expect(throws: WindowsFixtureRequirement.Failure.invalidArtifact(name)) {
        try WindowsFixtureRequirement.validate(environment: environment)
    }
    try manager.removeItem(at: path)
    try manager.createDirectory(at: path, withIntermediateDirectories: false)
    #expect(throws: WindowsFixtureRequirement.Failure.invalidArtifact(name)) {
        try WindowsFixtureRequirement.validate(environment: environment)
    }
    try manager.removeItem(at: path)
    try manager.createSymbolicLink(at: path, withDestinationURL: root.appendingPathComponent(WindowsFixtureRequirement.files[1]))
    #expect(throws: WindowsFixtureRequirement.Failure.invalidArtifact(name)) {
        try WindowsFixtureRequirement.validate(environment: environment)
    }
}
