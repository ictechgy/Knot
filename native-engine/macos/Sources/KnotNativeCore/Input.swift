import Foundation

public enum Input {
    public static func key(down: Bool, scan: UInt16, extended: Bool) throws -> Packet {
        guard (1...255).contains(scan) else { throw NativeFailure.malformed }
        var data = Data([down ? 1 : 0]); data.appendBE(scan); data.append(extended ? 1 : 0); return Packet(kind: .key, payload: data)
    }
    public static func text(_ text: String) throws -> Packet {
        let data = Data(text.utf8)
        guard (1...1024).contains(data.count), text.utf16.count <= 512, !text.unicodeScalars.contains(where: { $0.value == 0 }) else { throw NativeFailure.malformed }
        return Packet(kind: .text, payload: data)
    }
    public static func pointer(action: UInt8, x: UInt16, y: UInt16) throws -> Packet {
        guard action <= 6 else { throw NativeFailure.malformed }
        var data = Data([action]); data.appendBE(x); data.appendBE(y); return Packet(kind: .pointer, payload: data)
    }
    public static func wheel(vertical: Int32, horizontal: Int32) throws -> Packet {
        guard (-1200...1200).contains(vertical), (-1200...1200).contains(horizontal) else { throw NativeFailure.malformed }
        var data = Data(); data.appendBE(vertical); data.appendBE(horizontal); return Packet(kind: .wheel, payload: data)
    }
    /// Full image bounds in view coordinates, including letterboxing. Y is flipped by the caller.
    public static func point(x: Double, y: Double, viewWidth: Double, viewHeight: Double, imageWidth: Double, imageHeight: Double) -> (UInt16, UInt16)? {
        guard [x,y,viewWidth,viewHeight,imageWidth,imageHeight].allSatisfy(\.isFinite), viewWidth > 0, viewHeight > 0, imageWidth > 0, imageHeight > 0 else { return nil }
        let scale = min(viewWidth / imageWidth, viewHeight / imageHeight), width = imageWidth * scale, height = imageHeight * scale
        let left = (viewWidth - width) / 2, top = (viewHeight - height) / 2
        guard x >= left, x <= left + width, y >= top, y <= top + height else { return nil }
        return (UInt16(((x-left) / width * 65535).rounded()), UInt16(((y-top) / height * 65535).rounded()))
    }
}

public struct InputBuffer: Sendable {
    private var queue: [Packet] = []
    public private(set) var byteCount = 0
    public private(set) var needsRecovery = false
    public var count: Int { queue.count }
    public init() {}
    public mutating func append(_ packet: Packet) throws {
        guard !needsRecovery else { throw NativeFailure.saturated }
        guard [.key, .text, .pointer, .wheel].contains(packet.kind) else { throw NativeFailure.malformed }
        if packet.kind == .pointer, packet.payload.first == 0,
           let index = queue.lastIndex(where: { $0.kind == .pointer && $0.payload.first == 0 }) {
            byteCount -= queue[index].encoded.count; queue.remove(at: index)
        }
        guard queue.count < 256, byteCount + packet.encoded.count <= 16_384 else { revoke(); throw NativeFailure.saturated }
        queue.append(packet); byteCount += packet.encoded.count
    }
    public mutating func pop() -> Packet? {
        guard !queue.isEmpty else { return nil }; let packet = queue.removeFirst(); byteCount -= packet.encoded.count; return packet
    }
    public mutating func revoke() { queue = [Packet(kind: .releaseAll)]; byteCount = 5; needsRecovery = true }
    /// Only an explicit focus/click recovery may re-admit input; release remains first in line.
    public mutating func recover() { needsRecovery = false }
}
