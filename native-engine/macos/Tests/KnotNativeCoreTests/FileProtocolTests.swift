import Foundation
import CryptoKit
import Testing
@testable import KnotNativeCore

@Test func portableBasenameRejectsSupplementaryFormatScalars() {
    for scalar in ["\u{E0001}", "\u{E0020}", "\u{E007F}"] {
        #expect(!FileWire.validName("ordinary" + scalar + ".txt"))
    }
    #expect(FileWire.validName("ordinary😀.txt"))
}

@Test func fileTLSCertificateFailuresKeepAuthenticationGuidance() {
    for failure in [NativeFailure.certificatePinMismatch, .certificatePolicy] {
        #expect(NativeFileError.authored(failure) == .trust)
        #expect(NativeFileError.authored(failure).message.contains("인증"))
    }
    #expect(NativeFileError.authored(NativeFailure.transport) == .timeout)
}

private func fileVectorData(_ object: [String: Any], _ key: String) throws -> Data {
    let text = try #require(object[key] as? String)
    return try #require(Data(base64Encoded: text))
}

private func validateWindowsFileVector(kind: FileKind, payload: Data) throws {
    switch kind {
    case .hello:
        let object = try FileWire.object(payload, keys: ["v", "token"])
        #expect(try object.integer("v") == 2)
        let token = try object.string("token"), decoded = try Invitation.base64URL(object.string("token"))
        #expect(token.utf8.count == 43 && decoded.count == 32)
    case .authorized: #expect(try FileWire.object(payload, keys: ["v"]).integer("v") == 2)
    case .list: #expect(payload.isEmpty)
    case .entry: _ = try NativeFileEntry(payload)
    case .listEnd:
        let object = try FileWire.object(payload, keys: ["count", "truncated"])
        #expect(try (0...256).contains(object.integer("count"))); _ = try object.boolean("truncated")
    case .put: _ = try FileWire.metadata(payload)
    case .accepted: _ = try FileWire.accepted(payload)
    case .treePut: _ = try FileWire.treeMetadata(payload)
    case .node: _ = try NativeFileNode(payload)
    case .treeEnd: _ = try FileWire.treeEnd(payload)
    case .explorerCapture, .explorerCancel: _ = try FileWire.explorerNonce(payload)
    case .get: #expect(try FileWire.isHex(FileWire.object(payload, keys: ["entry"]).string("entry"), count: 32))
    case .chunk: #expect(payload.readBE(UInt64.self, at: 0) <= UInt64(FileWire.maximumSize))
    case .finish: #expect(payload.readBE(UInt64.self, at: 0) <= UInt64(FileWire.maximumSize))
    case .complete: _ = try FileWire.completion(payload)
    case .error: _ = try FileWire.remoteError(payload)
    }
}

@Test func filesReadyRequiresWholeTypedGroupAndDoesNotReplaceMediaTrust() throws {
    let base: [String: Any] = ["v": 1, "codec": "h264-annexb", "width": 64, "height": 64, "fps": 30,
                                "bitrate": 1_000_000, "hardwareEncoder": true]
    #expect(try Ready(JSONSerialization.data(withJSONObject: base)).files == nil)
    let token = Invitation.encodeBase64URL(Data(repeating: 0x37, count: 32))
    let group: [String: Any] = ["filesVersion": 2, "filePort": 48634, "fileToken": token, "fileRootName": "Knot Files"]
    let ready = try Ready(JSONSerialization.data(withJSONObject: base.merging(group) { _, new in new }))
    #expect(ready.files?.port == 48634 && ready.files?.rootName == "Knot Files")
    for key in group.keys {
        var incomplete = base.merging(group) { _, new in new }; incomplete.removeValue(forKey: key)
        #expect(throws: (any Error).self) { try Ready(JSONSerialization.data(withJSONObject: incomplete)) }
    }
    for mutation: [String: Any] in [["filePort": 80], ["filesVersion": true], ["filesVersion": 1],
                                   ["fileToken": token + "="], ["fileRootName": "bad\nfolder"], ["fileAddress": "8.8.8.8"]] {
        let invalid = base.merging(group) { _, new in new }.merging(mutation) { _, new in new }
        #expect(throws: (any Error).self) { try Ready(JSONSerialization.data(withJSONObject: invalid)) }
    }
}

@Test func fileFramesRejectUnknownLengthsAndKeepMediaSendLimitsSeparate() throws {
    var valid = Data(); valid.appendBE(UInt64(0)); valid.append(Data(repeating: 1, count: FileWire.chunkBytes))
    let packet = try FilePacket(kind: .chunk, payload: valid)
    #expect(try FilePacket.header(Data(packet.encoded.prefix(5))).1 == 65_544)
    let cases: [(UInt8, UInt32)] = [(0x48, 8), (0x48, 65_545), (0x49, 39), (0x49, 41),
                                   (0x42, 1), (0x7f, 129), (0x40, 0), (0x40, 4097), (0x11, 1)]
    for (kind, size) in cases {
        var header = Data([kind]); header.appendBE(size)
        #expect(throws: (any Error).self) { try FilePacket.header(header) }
    }
    #expect(throws: (any Error).self) { try Packet.serverHeader(Data(packet.encoded.prefix(5))) }
}

@Test func fileBasenamesRejectPathDeviceControlAndPrivatePartialForms() throws {
    for bad in ["", ".", "..", "a/b", "a\\b", "a:stream", "x?", "<x>", "x|y", "x*", "x\"y", "a.", "a ",
                "NUL.txt", "con", "COM0.log", "COM1.log", "LPT¹.txt", "CON .txt", "CLOCK$", ".Knot-hidden", "bad\0name", "bad\u{202e}name", "bad\u{2028}name",
                String(repeating: "가", count: 86)] {
        #expect(!FileWire.validName(bad), Comment(rawValue: bad.debugDescription))
    }
    for good in ["검증.txt", "ordinary file.txt", "plain😀.bin", "אבג.txt", "COM10.txt", "a..b", "data.zip"] {
        #expect(FileWire.validName(good))
    }
    #expect(try NativeFileEntry(id: String(repeating: "a", count: 32), name: "검증.txt", size: FileWire.maximumSize).size == 8_589_934_592)
    #expect(throws: (any Error).self) { try NativeFileEntry(id: "../escape", name: "file", size: 0) }
    #expect(throws: (any Error).self) { try NativeFileEntry(id: String(repeating: "a", count: 32), name: "file", size: FileWire.maximumSize + 1) }
}

@Test func fileMetadataRejectsDuplicateUnknownAndWrongTypedOrUnboundedValues() throws {
    for invalid in ["{\"name\":\"a\",\"size\":0,\"size\":0}", "{\"name\":\"a\",\"size\":true}",
                    "{\"name\":\"a\",\"size\":0,\"path\":\"x\"}", "{\"name\":\"a\",\"size\":-1}",
                    "{\"name\":\"a\",\"size\":8589934593}", "{\"name\":\"a\",\"size\":0}true"] {
        #expect(throws: (any Error).self) { try FileWire.metadata(Data(invalid.utf8)) }
    }
    let digest = Data(SHA256.hash(data: Data()))
    let finish = try FileWire.finish(size: 0, digest: digest)
    try FileWire.checkFinish(finish.payload, size: 0, digest: digest)
    #expect(throws: (any Error).self) { try FileWire.checkFinish(finish.payload, size: -1, digest: digest) }
    #expect(throws: (any Error).self) { try FileWire.checkFinish(finish.payload, size: 1, digest: digest) }
    #expect(throws: (any Error).self) { try FileWire.remoteError(Data("{\"code\":\"private OS path\"}".utf8)) }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["KNOT_NATIVE_WINDOWS_FIXTURES"] != nil,
               "Windows file codec vectors are supplied and required by full CI."))
func actualWindowsFileCodecVectorsAndChunkedTransfersAreAcceptedExactly() throws {
    let root = try #require(ProcessInfo.processInfo.environment["KNOT_NATIVE_WINDOWS_FIXTURES"])
    let path = URL(fileURLWithPath: root).appendingPathComponent("native-file-vectors.json")
    let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
    try #require(attributes[.type] as? FileAttributeType == .typeRegular)
    let maximum = try #require(attributes[.size] as? NSNumber)
    try #require(maximum.int64Value > 0 && maximum.int64Value <= 1_048_576)
    let raw = try Data(contentsOf: path, options: [.mappedIfSafe])
    let object = try #require(JSONSerialization.jsonObject(with: raw) as? [String: Any])
    #expect(object["schema"] as? Int == 1 && object["status"] as? String == "passed")
    #expect(object["freshSyntheticOnly"] as? Bool == true && object["actualCapture"] as? Bool == false && object["actualInput"] as? Bool == false)
    let vectors = try #require(object["vectors"] as? [[String: Any]])
    #expect(vectors.count >= 12)
    for vector in vectors {
        let encoded = try fileVectorData(vector, "encodedBase64")
        let payload = try fileVectorData(vector, "payloadBase64")
        let (kind, size) = try FilePacket.header(Data(encoded.prefix(5)))
        #expect(Int(kind.rawValue) == vector["kind"] as? Int)
        #expect(size == payload.count && encoded.dropFirst(5) == payload)
        #expect(try FilePacket(kind: kind, payload: payload).encoded == encoded)
        try validateWindowsFileVector(kind: kind, payload: payload)
    }
    let files = try #require(object["files"] as? [[String: Any]])
    #expect(files.count >= 2)
    for file in files {
        let bytes = try fileVectorData(file, "bytesBase64"), name = try #require(file["name"] as? String)
        let hash = Data(SHA256.hash(data: bytes)).map { String(format: "%02x", $0) }.joined()
        #expect(FileWire.validName(name) && file["size"] as? Int == bytes.count && file["sha256"] as? String == hash)
    }
    let transfers = try #require(object["transfers"] as? [[String: Any]]); #expect(transfers.count == 3)
    var hasEmpty = false, hasBoundary = false
    for transfer in transfers {
        let expected = try fileVectorData(transfer, "bytesBase64")
        let encoded = try fileVectorData(transfer, "encodedBase64")
        let expectedName = try #require(transfer["fileName"] as? String), expectedHash = try #require(transfer["sha256"] as? String)
        var cursor = 0, offset: UInt64 = 0, received = Data(), hash = SHA256(), accepted = false, finished = false
        while cursor < encoded.count {
            #expect(cursor + 5 <= encoded.count)
            let (kind, count) = try FilePacket.header(encoded.subdata(in: cursor..<(cursor + 5))); cursor += 5
            #expect(cursor + count <= encoded.count)
            let data = encoded.subdata(in: cursor..<(cursor + count)); cursor += count
            switch kind {
            case .accepted:
                #expect(!accepted && offset == 0); let info = try FileWire.accepted(data)
                #expect(info.name == expectedName && info.size == Int64(expected.count)); accepted = true
            case .chunk:
                #expect(accepted && !finished && data.readBE(UInt64.self, at: 0) == offset)
                let bytes = Data(data.dropFirst(8)); received.append(bytes); hash.update(data: bytes); offset += UInt64(bytes.count)
            case .finish:
                #expect(accepted && !finished && cursor == encoded.count)
                let digest = Data(hash.finalize()); try FileWire.checkFinish(data, size: Int64(expected.count), digest: digest)
                #expect(digest.map { String(format: "%02x", $0) }.joined() == expectedHash); finished = true
            default: Issue.record("Unexpected transfer vector frame")
            }
        }
        #expect(finished && received == expected && transfer["size"] as? Int == expected.count)
        hasEmpty = hasEmpty || expected.isEmpty; hasBoundary = hasBoundary || expected.count == 65_541
    }
    #expect(hasEmpty && hasBoundary)
}

@Test func treeGrammarRejectsForwardParentsCaseNormalizationCollisionsAndBounds() throws {
    let id = String(repeating: "a", count: 32)
    #expect(try NativeFileEntry(id: id, name: "folder", size: 0, kind: .folder).isFolder)
    #expect(throws: (any Error).self) { try NativeFileEntry(id: id, name: "folder", size: 1, kind: .folder) }
    #expect(throws: (any Error).self) { try NativeFileEntry(Data("{\"entry\":\"\(id)\",\"name\":\"a\",\"size\":0}".utf8)) }
    for raw in ["{\"id\":1,\"parent\":1,\"name\":\"a\",\"kind\":\"file\",\"size\":0}",
                "{\"id\":1,\"parent\":0,\"name\":\"a\",\"kind\":\"folder\",\"size\":1}",
                "{\"id\":1,\"parent\":0,\"name\":\"a\",\"kind\":\"file\",\"size\":0,\"path\":\"x\"}"] {
        #expect(throws: (any Error).self) { try NativeFileNode(Data(raw.utf8)) }
    }
    for pair in [("same", "SAME"), ("é", "e\u{301}")] {
        var tree = try NativeFileTreeAdmission(count: 2, size: 0)
        try tree.append(NativeFileNode(id: 1, parent: 0, name: pair.0, kind: .folder, size: 0).json)
        #expect(throws: NativeFileError.protocolViolation) { try tree.append(NativeFileNode(id: 2, parent: 0, name: pair.1, kind: .file, size: 0).json) }
    }
    var depth = try NativeFileTreeAdmission(count: 17, size: 0)
    for id in 1...16 { try depth.append(NativeFileNode(id: id, parent: id - 1, name: "dir", kind: .folder, size: 0).json) }
    #expect(throws: NativeFileError.quota) { try depth.append(NativeFileNode(id: 17, parent: 16, name: "leaf", kind: .file, size: 0).json) }
    #expect(throws: (any Error).self) { try NativeFileTreeAdmission(count: 4097, size: 0) }
    #expect(throws: (any Error).self) { try NativeFileTreeAdmission(count: 0, size: 1) }
    var missing = try NativeFileTreeAdmission(count: 1, size: 1)
    try missing.append(NativeFileNode(id: 1, parent: 0, name: "a", kind: .file, size: 0).json)
    #expect(throws: NativeFileError.protocolViolation) { try missing.finish() }
    #expect(throws: (any Error).self) { try FileWire.explorerNonce(Data("{\"nonce\":\"ABC\"}".utf8)) }
    #expect(throws: (any Error).self) { try FileWire.accepted(FileWire.json(["name": "a", "size": 0, "kind": "file", "count": 1])) }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["KNOT_NATIVE_WINDOWS_FIXTURES"] != nil,
               "Actual Windows tree codec vectors are supplied by full CI."))
func actualWindowsTreeVectorsBindRawNodeJSONAndAllFileBytes() throws {
    let root = try #require(ProcessInfo.processInfo.environment["KNOT_NATIVE_WINDOWS_FIXTURES"])
    let path = URL(fileURLWithPath: root).appendingPathComponent("native-file-vectors.json")
    let raw = try Data(contentsOf: path)
    try #require(raw.count <= 1_048_576)
    let object = try #require(JSONSerialization.jsonObject(with: raw) as? [String: Any])
    let rejected = try #require(object["rejectedFolderNames"] as? [String])
    #expect(rejected.count == 13 && Set(rejected) == Set(rejectedPortablePackageFolderNames))
    for name in rejected { try checkPackageFolderWireRejection(name) }
    let trees = try #require(object["trees"] as? [[String: Any]])
    #expect(trees.count >= 3)
    var empty = false, unicode = false, boundary = false
    for tree in trees {
        let count = try #require(tree["count"] as? Int), size = try #require(tree["size"] as? Int)
        var admission = try NativeFileTreeAdmission(count: count, size: Int64(size)), hash = SHA256(), cursor = 0, offset: Int64 = 0
        let stream = try fileVectorData(tree, "encodedBase64"), nodes = try #require(tree["nodes"] as? [[String: Any]])
        var current: NativeFileNode?, leafHash = SHA256(), finished = false, accepted = false
        for item in nodes {
            let raw = try fileVectorData(item, "jsonBase64"), bytes = try fileVectorData(item, "bytesBase64")
            let node = try NativeFileNode(raw)
            #expect(node.kind == .file ? node.size == Int64(bytes.count) : bytes.isEmpty)
        }
        while cursor < stream.count {
            try #require(cursor + 5 <= stream.count)
            let (kind, length) = try FilePacket.header(stream.subdata(in: cursor..<(cursor + 5))); cursor += 5
            try #require(cursor + length <= stream.count)
            let payload = stream.subdata(in: cursor..<(cursor + length)); cursor += length
            switch kind {
            case .accepted:
                #expect(!accepted); let info = try FileWire.accepted(payload)
                #expect(info.kind == .folder && info.count == count && info.size == Int64(size)); accepted = true
            case .node:
                #expect(accepted && !finished && current == nil)
                let node = try admission.append(payload)
                let expected = try fileVectorData(nodes[node.id - 1], "jsonBase64"); #expect(expected == payload)
                var length = Data(); length.appendBE(UInt32(payload.count)); hash.update(data: length); hash.update(data: payload)
                unicode = unicode || node.name.unicodeScalars.contains(where: { $0.value > 127 })
                if node.kind == .file { current = node; leafHash = SHA256(); offset = 0; boundary = boundary || node.size == 65_541 }
            case .chunk:
                let node = try #require(current)
                #expect(payload.readBE(UInt64.self, at: 0) == UInt64(offset))
                let bytes = Data(payload.dropFirst(8)); offset += Int64(bytes.count); #expect(offset <= node.size)
                hash.update(data: bytes); leafHash.update(data: bytes)
            case .finish:
                let node = try #require(current); #expect(offset == node.size)
                try FileWire.checkFinish(payload, size: node.size, digest: Data(leafHash.finalize())); current = nil
            case .treeEnd:
                #expect(current == nil && cursor == stream.count); try admission.finish()
                let end = try FileWire.treeEnd(payload), digest = Data(hash.finalize()).map { String(format: "%02x", $0) }.joined()
                #expect(end.count == count && end.size == Int64(size) && end.hash == digest && tree["sha256"] as? String == digest); finished = true
            default: Issue.record("Unexpected tree vector frame")
            }
        }
        empty = empty || count == 0
        #expect(accepted && finished && nodes.count == count)
    }
    #expect(empty && unicode && boundary)
}

@Test func treeRawMetadataBudgetIsEnforcedWithoutAcceptingExtraNode() throws {
    var admission = try NativeFileTreeAdmission(count: 4096, size: 0), rejected = false
    for id in 1...4096 {
        let name = String(repeating: "a", count: 245) + String(format: "%010d", id)
        do { try admission.append(NativeFileNode(id: id, parent: 0, name: name, kind: .file, size: 0).json) }
        catch { #expect(error as? NativeFileError == .quota); rejected = true; break }
    }
    #expect(rejected && admission.nodes.count < 4096 && admission.metadataBytes <= FileWire.maximumTreeMetadata)
}

private let rejectedPortablePackageFolderNames = ["Rejected.app", "Rejected.bundle", "Rejected.framework", "Rejected.plugin", "Rejected.kext", "Rejected.xpc", "Rejected.appex", "Rejected.rtfd", "Rejected.photoslibrary", "Rejected.playground", "Rejected.pkg", "HELPER.XPC", ".app"]

private func checkPackageFolderWireRejection(_ name: String) throws {
    let id = String(repeating: "a", count: 32)
    #expect(FileWire.validName(name) && FileWire.isPackageFolderName(name) && !FileWire.validFolderName(name))
    #expect(throws: NativeFileError.protocolViolation) { try NativeFileEntry(id: id, name: name, size: 0, kind: .folder) }
    #expect(throws: NativeFileError.protocolViolation) {
        try NativeFileEntry(FileWire.json(["entry": id, "name": name, "size": 0, "kind": "folder"]))
    }
    #expect(throws: NativeFileError.protocolViolation) {
        try FileWire.accepted(FileWire.json(["name": name, "size": 0, "kind": "folder", "count": 0]))
    }
    #expect(throws: NativeFileError.protocolViolation) { try FileWire.treeMetadata(FileWire.json(["name": name, "size": 0, "count": 0])) }
    let raw = try FileWire.json(["id": 1, "parent": 0, "name": name, "kind": "folder", "size": 0])
    #expect(throws: NativeFileError.protocolViolation) { try NativeFileNode(raw) }
    var admission = try NativeFileTreeAdmission(count: 1, size: 0)
    #expect(throws: NativeFileError.protocolViolation) { try admission.append(raw) }
    // A regular installer/executable-looking filename is still an ordinary file.
    #expect(try NativeFileEntry(id: id, name: name, size: 0).kind == .file)
    #expect(try NativeFileNode(id: 1, parent: 0, name: name, kind: .file, size: 0).kind == .file)
    #expect(try FileWire.accepted(FileWire.json(["name": name, "size": 0, "kind": "file", "count": 0])).kind == .file)
}

@Test func portablePackageFolderPolicyCoversEveryTypedWireBoundaryAndPreservesRegularFiles() throws {
    for name in rejectedPortablePackageFolderNames { try checkPackageFolderWireRejection(name) }
    for name in ["ordinary", "app", "pkg", "archive.zip", "application.app.txt", "검증 폴더"] {
        #expect(FileWire.validFolderName(name) && !FileWire.isPackageFolderName(name))
    }
    #expect(try NativeFileEntry(id: String(repeating: "a", count: 32), name: "installer.exe", size: 0).kind == .file)
}
