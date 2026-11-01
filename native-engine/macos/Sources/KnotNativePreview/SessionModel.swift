import Foundation
import Combine
import CoreVideo
import KnotNativeCore

@MainActor
final class SessionModel: ObservableObject {
    enum Phase: Equatable { case idle, connecting, approval, decoding, streaming, failed }
    @Published var phase: Phase = .idle
    @Published var status = "Paste a fresh invitation, review its target and certificate, then connect."
    @Published var invitation: Invitation?
    @Published var videoSize = CGSize(width: 1920, height: 1080)
    @Published var inputRecovery = false
    @Published var textMode = false
    weak var surface: DesktopView?
    private var channel: (any NativeChannel)?
    private let makeChannel: @Sendable (Invitation) throws -> any NativeChannel
    private var reader: Task<Void, Never>?
    private var writer: Task<Void, Never>?
    private var ticker: Task<Void, Never>?
    private var decoder: NativeDecoder?
    private var input = InputBuffer()
    private var receiveState = ReceiveState()
    private var identity = UUID()
    private var connectedAt = ContinuousClock.now
    private var lastIncoming = ContinuousClock.now
    private var lastHeartbeat = ContinuousClock.now
    private var readyAt = ContinuousClock.now
    private var nextInput = ContinuousClock.now
    private var writerBusy = false
    private var inputEpoch: UInt64 = 0
    var active: Bool { [.connecting, .approval, .decoding, .streaming].contains(phase) }

    init(makeChannel: @escaping @Sendable (Invitation) throws -> any NativeChannel = { try TLSChannel(invitation: $0) }) { self.makeChannel = makeChannel }

    func review(_ secret: String) {
        guard !active else { return }
        do { invitation = try Invitation(secret); phase = .idle; status = "Review the private address and exact certificate pin below. Trust lasts for this connection only." }
        catch { invitation = nil; phase = .failed; status = "Invalid invitation. Ask the host to create a fresh native invitation." }
    }
    func connect() {
        guard !active, let invitation else { return }
        let id = UUID(); identity = id; phase = .connecting; status = "Verifying the host certificate…"
        receiveState = ReceiveState(); input = InputBuffer(); inputRecovery = false
        connectedAt = .now; lastIncoming = .now; lastHeartbeat = .now
        reader = Task { [weak self] in
            guard let self else { return }
            do {
                let transport = try self.makeChannel(invitation); self.channel = transport
                try await transport.start()
                guard self.identity == id else { transport.close(); return }
                // This write completes before the sole post-Hello writer starts.
                try await transport.send(invitation.hello())
                guard self.identity == id else { transport.close(); return }
                self.invitation = nil // one-use token must not become reusable trust
                self.connectedAt = .now
                self.lastIncoming = .now
                self.phase = .approval; self.status = "Certificate verified. Waiting for the host’s explicit approval…"
                self.startTicker(id: id)
                while !Task.isCancelled, self.identity == id {
                    let header = try await transport.readExactly(5)
                    let (kind, size) = try Packet.serverHeader(header)
                    let bytes = try await transport.readExactly(size)
                    guard self.identity == id else { return }
                    self.lastIncoming = .now
                    let packet = Packet(kind: kind, payload: bytes)
                    let video = try self.receiveState.accept(packet)
                    switch kind {
                    case .ready:
                        guard let ready = self.receiveState.ready else { throw NativeFailure.state }
                        self.videoSize = CGSize(width: ready.width, height: ready.height)
                        let decoder = NativeDecoder(width: ready.width, height: ready.height)
                        decoder.onImage = { [weak self] image in
                            guard let self, self.identity == id else { return }
                            guard self.surface?.display(image) == true else { return }
                            self.phase = .streaming; self.status = "Receiving the host desktop. Temporary trust; no saved pairing."
                        }
                        decoder.onFailure = { [weak self] in
                            guard let self, self.identity == id else { return }
                            self.fail("The native decoder stopped. Create a new invitation to reconnect.")
                        }
                        self.decoder = decoder; self.phase = .decoding
                        self.readyAt = .now
                        self.status = "Host approved and encoder ready. Waiting for the first decoded image…"
                    case .video: if let video { try self.decoder?.decode(video.accessUnit) }
                    case .error:
                        let code = try StrictJSON.object(bytes, keys: ["code"], limit: 128).string("code")
                        self.fail(Self.message(code)); return
                    default: break
                    }
                }
            } catch {
                if self.identity == id { self.fail("Connection ended or validation failed. Ask the host for a new invitation.") }
            }
        }
    }
    private static func message(_ code: String) -> String {
        switch code {
        case "auth", "expired": "Invitation was rejected or expired. Create a new invitation."
        case "declined": "The host declined the request. Create a new invitation to try again."
        case "busy": "The host is already handling another request."
        case "capture": "Host capture is unavailable. Check its logged-in SDR primary display."
        case "encoder": "The host hardware H.264 encoder could not start."
        case "input": "The host stopped accepting input. Create a new invitation."
        case "timeout": "The connection timed out. Create a new invitation."
        default: "The host closed the connection. Create a new invitation to reconnect."
        }
    }
    private func startTicker(id: UUID) {
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, self.identity == id, !Task.isCancelled else { return }
                let now = ContinuousClock.now
                guard self.checkDeadlines(now: now) else { return }
                if now - self.lastHeartbeat >= .seconds(2) { self.pumpWriter() }
            }
        }
    }
    /// Shared by the real ticker and inert lifecycle tests; host activity cannot
    /// indefinitely extend approval or the first decoded-image deadline.
    func checkDeadlines(now: ContinuousClock.Instant) -> Bool {
        guard active else { return false }
        guard now - lastIncoming < .seconds(10), phase != .approval || now - connectedAt < .seconds(60) else {
            fail("The peer or host approval timed out. Create a new invitation."); return false
        }
        guard phase != .decoding || now - readyAt < .seconds(15) else {
            fail("The first decoded image did not arrive. Create a new invitation."); return false
        }
        return true
    }
    func send(_ packet: Packet) {
        guard phase == .streaming, !inputRecovery else { return }
        do { try input.append(packet); pumpWriter() }
        catch {
            inputEpoch &+= 1
            inputRecovery = true; status = "Input paused after queue saturation. Click the desktop to resume."; pumpWriter()
        }
    }
    func releaseInput() {
        guard active else { return }
        inputEpoch &+= 1
        input.revoke(); inputRecovery = true; surface?.forgetHeldKeys(); pumpWriter()
        if phase == .streaming { status = "Input paused. Click the desktop to resume." }
    }
    func recoverInput() {
        guard phase == .streaming else { return }
        input.recover(); inputRecovery = false
        status = "Receiving the host desktop. Temporary trust; no saved pairing."
    }
    private func pumpWriter() {
        guard !writerBusy, let channel, [.approval, .decoding, .streaming].contains(phase) else { return }
        writerBusy = true
        let id = identity
        writer = Task { [weak self] in
            guard let self else { return }
            do {
                while !Task.isCancelled, self.identity == id {
                    let packet: Packet
                    let epoch = self.inputEpoch
                    if ContinuousClock.now - self.lastHeartbeat >= .seconds(2) { packet = Packet(kind: .heartbeat); self.lastHeartbeat = .now }
                    else if let pending = self.input.pop() { packet = pending }
                    else { break }
                    if ContinuousClock.now < self.nextInput { try await Task.sleep(until: self.nextInput) }
                    try Task.checkCancellation()
                    guard self.inputEpoch == epoch else { continue }
                    try await channel.send(packet)
                    self.nextInput = .now + .milliseconds(2) // <=500 input envelopes/second
                }
                if self.identity == id { self.writerBusy = false }
            } catch { if self.identity == id { self.fail("Input transport stopped. Create a new invitation to reconnect.") } }
        }
    }
    func disconnect() { close(message: "Disconnected. Reconnect with a fresh invitation.", failed: false) }
    private func fail(_ message: String) { close(message: message, failed: true) }
    private func close(message: String, failed: Bool) {
        identity = UUID(); ticker?.cancel(); reader?.cancel(); writer?.cancel()
        let oldWriter = writer
        ticker = nil; reader = nil; writer = nil; writerBusy = false
        let old = channel; channel = nil
        // The final release follows the sole writer's completion, preserving the
        // single sender invariant. The host also releases when TLS closes.
        Task { await oldWriter?.value; if let old { try? await old.send(Packet(kind: .releaseAll)); old.close() } }
        decoder?.stop(); decoder = nil; surface?.clear(); surface?.forgetHeldKeys()
        invitation = nil; input = InputBuffer(); inputRecovery = false
        phase = failed ? .failed : .idle; status = message
    }
}
