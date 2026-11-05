import Foundation
import CryptoKit
import Testing
@testable import KnotNativeCore

private func fileVectorData(_ object: [String: Any], _ key: String) throws -> Data {
    let text = try #require(object[key] as? String)
    return try #require(Data(base64Encoded: text))
}

private func validateWindowsFileVector(kind: FileKind, payload: Data) throws {
    switch kind {
    case .hello:
        let object = try FileWire.object(payload, keys: ["v", "token"])
        #expect(try object.integer("v") == 1)
        let token = try object.string("token"), decoded = try Invitation.base64URL(object.string("token"))
        #expect(token.utf8.count == 43 && decoded.count == 32)
    case .authorized: #expect(try FileWire.object(payload, keys: ["v"]).integer("v") == 1)
    case .list: #expect(payload.isEmpty)
    case .entry: _ = try NativeFileEntry(payload)
    case .listEnd:
        let object = try FileWire.object(payload, keys: ["count", "truncated"])
        #expect(try (0...256).contains(object.integer("count"))); _ = try object.boolean("truncated")
    case .put, .accepted: _ = try FileWire.metadata(payload)
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
    let group: [String: Any] = ["filesVersion": 1, "filePort": 48634, "fileToken": token, "fileRootName": "Knot Files"]
    let ready = try Ready(JSONSerialization.data(withJSONObject: base.merging(group) { _, new in new }))
    #expect(ready.files?.port == 48634 && ready.files?.rootName == "Knot Files")
    for key in group.keys {
        var incomplete = base.merging(group) { _, new in new }; incomplete.removeValue(forKey: key)
        #expect(throws: (any Error).self) { try Ready(JSONSerialization.data(withJSONObject: incomplete)) }
    }
    for mutation: [String: Any] in [["filePort": 80], ["filesVersion": true], ["filesVersion": 2],
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
                #expect(!accepted && offset == 0); let info = try FileWire.metadata(data)
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
