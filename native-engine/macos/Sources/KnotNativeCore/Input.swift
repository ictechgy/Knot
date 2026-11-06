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
    /// Explicitly separate AppKit's approximate pixel and line deltas. These
    /// authored scales are a preview policy, not a universal device calibration.
    /// Ignore zero/nonfinite events rather than consuming a transport action.
    public static func scroll(vertical: Double, horizontal: Double, precise: Bool) -> Packet? {
        guard vertical.isFinite, horizontal.isFinite else { return nil }
        let scale = precise ? 12.0 : 120.0
        func ticks(_ value: Double) -> Int32 {
            // Clamp before multiplication as very large finite input can overflow.
            Int32((max(-1200 / scale, min(1200 / scale, value)) * scale).rounded())
        }
        let verticalTicks = ticks(vertical), horizontalTicks = ticks(horizontal)
        guard verticalTicks != 0 || horizontalTicks != 0 else { return nil }
        return try? wheel(vertical: verticalTicks, horizontal: horizontalTicks)
    }
    /// Full image bounds in view coordinates, including letterboxing. Y is flipped by the caller.
    /// Clamp is opt-in for a focused, already-held button release; ordinary
    /// letterbox clicks must retain the default rejection behavior.
    public static func point(x: Double, y: Double, viewWidth: Double, viewHeight: Double, imageWidth: Double, imageHeight: Double, clamp: Bool = false) -> (UInt16, UInt16)? {
        guard [x,y,viewWidth,viewHeight,imageWidth,imageHeight].allSatisfy(\.isFinite), viewWidth > 0, viewHeight > 0, imageWidth > 0, imageHeight > 0 else { return nil }
        let scale = min(viewWidth / imageWidth, viewHeight / imageHeight), width = imageWidth * scale, height = imageHeight * scale
        guard scale.isFinite, scale > 0, width.isFinite, height.isFinite, width > 0, height > 0 else { return nil }
        let left = (viewWidth - width) / 2, top = (viewHeight - height) / 2
        guard clamp || (x >= left && x <= left + width && y >= top && y <= top + height) else { return nil }
        let normalizedX = max(0, min(1, (x-left) / width)), normalizedY = max(0, min(1, (y-top) / height))
        return (UInt16((normalizedX * 65535).rounded()), UInt16((normalizedY * 65535).rounded()))
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
        guard [.key, .text, .pointer, .wheel, .explorerDrag].contains(packet.kind) else { throw NativeFailure.malformed }
        if packet.kind == .explorerDrag, packet.payload.count != 16 { throw NativeFailure.malformed }
        if packet.kind == .wheel {
            guard packet.payload.count == 8 else { throw NativeFailure.malformed }
            let vertical = packet.payload.readBE(Int32.self, at: 0), horizontal = packet.payload.readBE(Int32.self, at: 4)
            guard (-1200...1200).contains(vertical), (-1200...1200).contains(horizontal) else { throw NativeFailure.malformed }
            guard vertical != 0 || horizontal != 0 else { return }
            if let last = queue.last, last.kind == .wheel {
                let previousVertical = last.payload.readBE(Int32.self, at: 0), previousHorizontal = last.payload.readBE(Int32.self, at: 4)
                let combinedVertical = previousVertical + vertical, combinedHorizontal = previousHorizontal + horizontal
                // Reversals can have observable effects at a scroll boundary;
                // preserve them rather than cancelling away an action barrier.
                func sameDirection(_ a: Int32, _ b: Int32) -> Bool { a == 0 || b == 0 || a.signum() == b.signum() }
                if sameDirection(previousVertical, vertical), sameDirection(previousHorizontal, horizontal),
                   (-1200...1200).contains(combinedVertical), (-1200...1200).contains(combinedHorizontal) {
                    byteCount -= last.encoded.count; queue.removeLast()
                    if combinedVertical != 0 || combinedHorizontal != 0 {
                        let combined = try Input.wheel(vertical: combinedVertical, horizontal: combinedHorizontal)
                        queue.append(combined); byteCount += combined.encoded.count
                    }
                    return
                }
            }
        }
        if packet.kind == .pointer, packet.payload.first == 0,
           let last = queue.last, last.kind == .pointer, last.payload.first == 0 {
            byteCount -= last.encoded.count; queue.removeLast()
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
