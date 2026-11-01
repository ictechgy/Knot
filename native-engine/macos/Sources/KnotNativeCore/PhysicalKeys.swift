import Foundation

/// Mac virtual key codes to Windows set-1 physical scan codes.
public enum WindowsScanCodes {
    public static let map: [UInt16:(UInt16,Bool)] = {
        var table: [UInt16:(UInt16,Bool)] = [:]
        let plain: [UInt16:UInt16] = [0:0x1e,1:0x1f,2:0x20,3:0x21,4:0x23,5:0x22,6:0x2c,7:0x2d,8:0x2e,9:0x2f,11:0x30,12:0x10,13:0x11,14:0x12,15:0x13,16:0x15,17:0x14,18:2,19:3,20:4,21:5,22:7,23:6,24:0x0d,25:0x0a,26:8,27:0x0c,28:9,29:0x0b,30:0x1b,31:0x18,32:0x16,33:0x1a,34:0x17,35:0x19,36:0x1c,37:0x26,38:0x24,39:0x28,40:0x25,41:0x27,42:0x2b,43:0x33,44:0x35,45:0x31,46:0x32,47:0x34,48:0x0f,49:0x39,50:0x29,51:0x0e,53:1,56:0x2a,60:0x36,59:0x1d,58:0x38,61:0x38,122:0x3b,120:0x3c,99:0x3d,118:0x3e,96:0x3f,97:0x40,98:0x41,100:0x42,101:0x43,109:0x44,103:0x57,111:0x58]
        for (key,scan) in plain { table[key] = (scan, false) }
        for (key,scan): (UInt16,UInt16) in [65:0x53,67:0x37,69:0x4e,71:0x45,78:0x4a,82:0x52,83:0x4f,84:0x50,85:0x51,86:0x4b,87:0x4c,88:0x4d,89:0x47,91:0x48,92:0x49] { table[key] = (scan,false) }
        let extended: [UInt16:UInt16] = [76:0x1c,75:0x35,123:0x4b,124:0x4d,125:0x50,126:0x48,115:0x47,119:0x4f,116:0x49,121:0x51,117:0x53,114:0x52,55:0x5b,54:0x5c,62:0x1d,61:0x38]
        for (key,scan) in extended { table[key] = (scan, true) }; return table
    }()
}

/// Ownership, rather than current modifiers or mode, determines key-up routing.
public struct PhysicalKeyOwnership: Sendable {
    private var down: Set<UInt16> = []
    public init() {}
    public var count: Int { down.count }
    public func routesDown(_ keyCode: UInt16, textMode: Bool, shortcutModifier: Bool) -> Bool {
        WindowsScanCodes.map[keyCode] != nil && (!textMode || shortcutModifier || down.contains(keyCode))
    }
    public mutating func press(_ keyCode: UInt16) { if WindowsScanCodes.map[keyCode] != nil { down.insert(keyCode) } }
    public mutating func release(_ keyCode: UInt16) -> Bool { down.remove(keyCode) != nil }
    public mutating func reset() { down.removeAll() }
}
