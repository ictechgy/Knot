import Foundation

public struct NativeFileNode: Sendable, Equatable {
    public let id: Int, parent: Int
    public let name: String
    public let kind: NativeFileEntryKind
    public let size: Int64
    public init(id: Int, parent: Int, name: String, kind: NativeFileEntryKind, size: Int64) throws {
        guard (1...FileWire.maximumTreeNodes).contains(id), parent >= 0, parent < id,
              FileWire.validName(name), FileWire.validSize(size), kind != .folder || size == 0 else { throw NativeFileError.protocolViolation }
        self.id = id; self.parent = parent; self.name = name; self.kind = kind; self.size = size
    }
    public init(_ raw: Data) throws {
        let object = try FileWire.object(raw, keys: ["id", "parent", "name", "kind", "size"])
        guard let kind = NativeFileEntryKind(rawValue: try object.string("kind")) else { throw NativeFileError.protocolViolation }
        try self.init(id: object.integer("id"), parent: object.integer("parent"), name: object.string("name"), kind: kind, size: Int64(object.integer("size")))
    }
    public var json: Data {
        get throws { try FileWire.json(["id": id, "parent": parent, "name": name, "kind": kind.rawValue, "size": size]) }
    }
}

/// Validates the flat, ordered grammar before any node is created on disk.
public struct NativeFileTreeAdmission: Sendable {
    public let count: Int, size: Int64
    public private(set) var nodes: [NativeFileNode] = []
    public private(set) var metadataBytes = 0
    public private(set) var dataBytes: Int64 = 0
    private var depths = [0]
    private var siblings: [Int: Set<String>] = [:]
    public init(count: Int, size: Int64) throws {
        guard (0...FileWire.maximumTreeNodes).contains(count), FileWire.validSize(size), count != 0 || size == 0 else { throw NativeFileError.protocolViolation }
        self.count = count; self.size = size
    }
    @discardableResult public mutating func append(_ raw: Data) throws -> NativeFileNode {
        guard nodes.count < count, raw.count <= FileWire.maximumTreeMetadata - metadataBytes else { throw NativeFileError.quota }
        let node = try NativeFileNode(raw)
        guard node.id == nodes.count + 1, node.parent == 0 || nodes[node.parent - 1].kind == .folder else { throw NativeFileError.protocolViolation }
        let depth = depths[node.parent] + 1
        guard depth <= FileWire.maximumTreeDepth else { throw NativeFileError.quota }
        guard siblings[node.parent, default: []].insert(FileWire.siblingKey(node.name)).inserted else { throw NativeFileError.protocolViolation }
        guard node.size <= size - dataBytes else { throw NativeFileError.protocolViolation }
        metadataBytes += raw.count; dataBytes += node.size; depths.append(depth); nodes.append(node)
        return node
    }
    public func finish() throws {
        guard nodes.count == count, dataBytes == size else { throw NativeFileError.protocolViolation }
    }
}
