import Foundation
import KnotNativeCore

enum NativeIncoming: Sendable {
    case ready(Ready)
    case video(VideoPacket)
    case clipboard(ClipboardResponse)
    case quality(Data)
    case videoControl(VideoControlStatus)
    case heartbeat
    case error(String)
}

/// One ordered, bounded reader owns validation and compressed-frame preparation.
/// Annex B scanning and AVCC construction must not run on the AppKit/input actor.
actor NativePacketReader {
    typealias Parser = @Sendable (Packet, inout ReceiveState) throws -> VideoPacket?
    private let channel: any NativeChannel
    private let parse: Parser
    private var state: ReceiveState
    private var reading = false
    private var failed = false

    // Parser injection is internal and synchronous: fresh fixtures can hold media
    // work to verify UI/input independence without capturing or injecting input.
    init(channel: any NativeChannel, videoControlVersion: Int = 0, parse: @escaping Parser = { try $1.accept($0) }) {
        self.channel = channel
        self.state = ReceiveState(videoControlVersion: videoControlVersion)
        self.parse = parse
    }

    func expectVideoControl(_ request: VideoControlRequest) throws { try state.expectVideoControl(request) }

    func next(timeout: Duration) async throws -> NativeIncoming {
        try Task.checkCancellation()
        guard !reading, !failed else { throw NativeFailure.state }
        reading = true
        defer { reading = false }
        do {
            let header = try await channel.readExactly(5, timeout: timeout)
            try Task.checkCancellation()
            let (kind, size) = try Packet.serverHeader(header)
            let bytes = try await channel.readExactly(size, timeout: timeout)
            try Task.checkCancellation()
            let packet = Packet(kind: kind, payload: bytes)
            let video = try parse(packet, &state)
            try Task.checkCancellation()
            switch kind {
            case .ready:
                guard let ready = state.ready else { throw NativeFailure.state }
                return .ready(ready)
            case .video:
                guard let video else { throw NativeFailure.state }
                return .video(video)
            case .qualityStatus: return .quality(bytes)
            case .videoControlStatus: return .videoControl(try VideoControlStatus(bytes))
            case .clipboardResponse: return .clipboard(try ClipboardResponse(bytes))
            case .hostHeartbeat: return .heartbeat
            case .error:
                return .error(try StrictJSON.object(bytes, keys: ["code"], limit: 128).string("code"))
            default: throw NativeFailure.state
            }
        } catch {
            failed = true
            throw error
        }
    }
}
