import Foundation
import Combine
import Network
import KnotNativeCore

enum NativeAudioSessionState: Sendable, Equatable {
    case idle, connecting, playing, unavailable, stopped
}

/// A best-effort child of one established video session. Nothing here can fail
/// its parent's media connection or retain the original invitation token.
@MainActor final class NativeAudioSession: ObservableObject {
    typealias ChannelFactory = @Sendable (NativeAudioEndpoint) throws -> any NativeChannel
    typealias PlayerFactory = @Sendable () -> any NativeAudioPlaying
    @Published private(set) var state: NativeAudioSessionState = .idle
    @Published private(set) var status = "Windows 소리 연결을 기다리고 있습니다."
    @Published private(set) var muted = false
    @Published private(set) var isAvailable = false
    var onChange: (() -> Void)?

    private let endpoint: NativeAudioEndpoint
    private let makeChannel: ChannelFactory
    private let makePlayer: PlayerFactory
    private var operation: Task<Void, Never>?
    private var muteDelivery: Task<Void, Never>?
    private var generation = UUID()
    private var channel: (any NativeChannel)?
    private var player: (any NativeAudioPlaying)?

    init(invitation: Invitation,
         makeChannel: @escaping ChannelFactory = { endpoint in
             guard Invitation.isPrivateIPv4(endpoint.address), let port = NWEndpoint.Port(rawValue: NativeAudioEndpoint.port) else { throw NativeFailure.malformed }
             return TLSChannel(endpoint: .hostPort(host: NWEndpoint.Host(endpoint.address), port: port), pin: endpoint.certificateSHA256)
         },
         makePlayer: @escaping PlayerFactory = { NativeAudioPlayer() }) throws {
        endpoint = try NativeAudioEndpoint(invitation: invitation)
        self.makeChannel = makeChannel; self.makePlayer = makePlayer
    }

    @discardableResult func start() -> Task<Void, Never>? {
        guard state == .idle else { return nil }
        state = .connecting; status = "Windows 소리에 연결 중입니다."; onChange?()
        let current = generation
        let operation = Task { [weak self] in
            guard let self else { return }
            await self.run(generation: current)
        }
        self.operation = operation
        return operation
    }

    /// An explicit user action retries only this optional sidecar using the
    /// same active media session's endpoint and derived audio authority.
    @discardableResult func retry() -> Task<Void, Never>? {
        guard state == .unavailable else { return nil }
        generation = UUID(); operation?.cancel(); operation = nil
        cancelMuteDelivery()
        channel?.close(); channel = nil
        if let player { Task { await player.stop() } }
        player = nil; state = .idle
        return start()
    }

    private func run(generation current: UUID) async {
        var ownedPlayer: (any NativeAudioPlaying)?
        var ownedChannel: (any NativeChannel)?
        defer { ownedChannel?.close() }
        do {
            try Task.checkCancellation()
            let channel = try makeChannel(endpoint); ownedChannel = channel
            guard current == generation else { return }
            self.channel = channel
            try await withTaskCancellationHandler {
                try await channel.start()
                try Task.checkCancellation()
                try await channel.send(endpoint.hello())
                var receiver = NativeAudioReceiveState()
                while current == generation {
                    try Task.checkCancellation()
                    let packet = try await Self.readPacket(channel)
                    guard current == generation else { return }
                    switch try receiver.accept(packet) {
                    case .ready:
                        let player = makePlayer(); ownedPlayer = player; self.player = player
                        let initialMuted = muted
                        await player.setFailureHandler { [weak self] in await self?.playerFailed(generation: current) }
                        guard current == generation else { await player.stop(); return }
                        try await player.start(muted: initialMuted)
                        guard current == generation else { await player.stop(); return }
                        isAvailable = true; state = .playing; refreshStatus(); onChange?()
                        if muted != initialMuted { deliverLatestMute() }
                    case .pcm(let pcm):
                        guard let player = ownedPlayer else { throw NativeFailure.state }
                        try await player.enqueue(pcm)
                    case .heartbeat: break
                    case .failure(let code): throw AudioPeerFailure(code: code)
                    }
                }
            } onCancel: { channel.close() }
        } catch {
            if current == generation {
                cancelMuteDelivery()
                isAvailable = false; state = .unavailable
                status = (error as? AudioPeerFailure)?.code == "auth"
                    ? "Windows 소리 연결을 인증할 수 없습니다."
                    : "Windows 소리를 사용할 수 없습니다."
                self.channel?.close(); self.channel = nil; self.player = nil; onChange?()
            }
        }
        if let ownedPlayer { await ownedPlayer.stop() }
    }

    private func playerFailed(generation current: UUID) {
        guard current == generation, state != .stopped else { return }
        generation = UUID(); operation?.cancel(); operation = nil; cancelMuteDelivery()
        channel?.close(); channel = nil; player = nil
        isAvailable = false; state = .unavailable; status = "소리 출력 장치가 바뀌었어요. 소리 연결을 다시 시도해주세요."
        onChange?()
    }

    /// One five-second budget covers header and body together; fragmentation
    /// cannot extend the peer's liveness deadline.
    nonisolated static func readPacket(_ channel: any NativeChannel) async throws -> NativeAudioPacket {
        let deadline = ContinuousClock.now + .seconds(5)
        let header = try await channel.readExactly(5, timeout: .seconds(5))
        let (kind, count) = try NativeAudioPacket.serverHeader(header)
        guard ContinuousClock.now < deadline else { throw NativeFailure.transport }
        let payload = try await channel.readExactly(count, timeout: deadline - ContinuousClock.now)
        guard payload.count == count else { throw NativeFailure.malformed }
        return NativeAudioPacket(kind: kind, payload: payload)
    }

    func setMuted(_ value: Bool) {
        guard state != .stopped else { return }
        muted = value; refreshStatus(); onChange?()
        deliverLatestMute()
    }
    func toggleMuted() { setMuted(!muted) }

    /// Coalesce input while the one player call is suspended. A new desired
    /// value is read only after that call finishes, so stale calls cannot race
    /// a newer mute delivery and rapid input cannot build a task queue.
    private func deliverLatestMute() {
        guard state == .playing, muteDelivery == nil, let player else { return }
        let current = generation
        muteDelivery = Task { [weak self] in
            guard let self else { return }
            defer { if current == self.generation { self.muteDelivery = nil } }
            while current == self.generation && !Task.isCancelled && self.state == .playing {
                let desired = self.muted
                await player.setMuted(desired)
                guard current == self.generation, !Task.isCancelled, self.state == .playing else { return }
                if self.muted == desired { return }
            }
        }
    }

    private func cancelMuteDelivery() {
        muteDelivery?.cancel(); muteDelivery = nil
    }

    func stop() {
        guard state != .stopped else { return }
        generation = UUID(); operation?.cancel(); operation = nil
        cancelMuteDelivery()
        channel?.close(); channel = nil
        if let player { Task { await player.stop() } }
        player = nil; state = .stopped; isAvailable = false
        status = "Windows 소리가 꺼졌습니다."; onChange?()
    }

    private func refreshStatus() {
        if state == .playing { status = muted ? "Windows 소리가 음소거되었습니다." : "Windows 소리를 재생 중입니다." }
    }
}

private struct AudioPeerFailure: Error { let code: String }
