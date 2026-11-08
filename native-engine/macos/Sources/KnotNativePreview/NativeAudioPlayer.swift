import Foundation
import AVFAudio
import KnotNativeCore

protocol NativeAudioPlaying: Sendable {
    func start(muted: Bool) async throws
    func enqueue(_ pcm: NativeAudioPCM) async throws
    func setMuted(_ muted: Bool) async
    func stop() async
    func setFailureHandler(_ handler: @escaping @Sendable () async -> Void) async
}
extension NativeAudioPlaying {
    func setFailureHandler(_ handler: @escaping @Sendable () async -> Void) async {}
}

/// Frame accounting is independent of AVAudioEngine, so overflow, mute and
/// obsolete completion behavior can be verified without touching an output.
struct NativeAudioQueue: Sendable {
    struct Ticket: Sendable, Equatable {
        let generation: UUID
        let id: UInt64
    }
    static let maximumFrames = 4_800
    static let prebufferFrames = 960
    private(set) var generation = UUID()
    private(set) var queuedFrames = 0
    private var nextID: UInt64 = 0
    private var pending: [UInt64: Int] = [:]

    mutating func reserve(frames: Int, sampleGap: Bool) -> (ticket: Ticket, flushed: Bool) {
        precondition((1...NativeAudioWire.maximumFrames).contains(frames))
        let flushed = sampleGap || queuedFrames + frames > Self.maximumFrames || nextID == .max
        if flushed { flush() }
        nextID += 1; pending[nextID] = frames; queuedFrames += frames
        return (Ticket(generation: generation, id: nextID), flushed)
    }
    mutating func complete(_ ticket: Ticket) {
        guard ticket.generation == generation, let frames = pending.removeValue(forKey: ticket.id) else { return }
        queuedFrames -= frames
    }
    mutating func flush() {
        generation = UUID(); nextID = 0; queuedFrames = 0; pending.removeAll(keepingCapacity: true)
    }
}

/// Accessed synchronously by NativeAudioPlayer's actor. Test sinks never create
/// an AVAudioEngine or touch an output device.
protocol NativeAudioOutputSink: AnyObject {
    func start(muted: Bool) throws
    func schedule(_ pcm: NativeAudioPCM, completion: @escaping @Sendable () async -> Void) throws
    func play() throws
    func pause()
    func flush()
    func setMuted(_ muted: Bool)
    func stop()
    func setInvalidationHandler(_ handler: @escaping @Sendable () async -> Void)
}
extension NativeAudioOutputSink {
    func setInvalidationHandler(_ handler: @escaping @Sendable () async -> Void) {}
}

protocol NativeAudioPrebufferClock: Sendable {
    /// The returned cancellation is idempotent; a callback already dispatched
    /// may still arrive, so the player also checks its identity and generation.
    func schedule(after delay: Duration, _ action: @escaping @Sendable () async -> Void) -> @Sendable () -> Void
}

private struct NativeAudioSystemPrebufferClock: NativeAudioPrebufferClock {
    func schedule(after delay: Duration, _ action: @escaping @Sendable () async -> Void) -> @Sendable () -> Void {
        let task = Task {
            do { try await Task.sleep(for: delay) }
            catch { return }
            guard !Task.isCancelled else { return }
            await action()
        }
        return { task.cancel() }
    }
}

private final class NativeAudioEngineNotification: @unchecked Sendable {
    let center: NotificationCenter
    let token: NSObjectProtocol
    init(center: NotificationCenter, token: NSObjectProtocol) { self.center = center; self.token = token }
    deinit { center.removeObserver(token) }
}

private final class NativeAVAudioOutputSink: NativeAudioOutputSink {
    private var engine: AVAudioEngine?
    private var node: AVAudioPlayerNode?
    private var format: AVAudioFormat?
    private var configurationChange: NativeAudioEngineNotification?
    private var invalidated: (@Sendable () async -> Void)?
    func setInvalidationHandler(_ handler: @escaping @Sendable () async -> Void) { invalidated = handler }

    func start(muted: Bool) throws {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: Double(NativeAudioWire.sampleRate), channels: 2) else { throw NativeFailure.unsupported }
        let engine = AVAudioEngine(), node = AVAudioPlayerNode()
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        node.volume = muted ? 0 : 1
        engine.prepare()
        do { try engine.start() }
        catch { engine.stop(); throw NativeFailure.transport }
        self.format = format; self.node = node; self.engine = engine
        if let invalidated {
            let center = NotificationCenter.default
            let token = center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { _ in
                // AVFAudio owns this notification queue. Never tear the graph
                // down synchronously here; marshal to the player's actor.
                Task { await invalidated() }
            }
            configurationChange = NativeAudioEngineNotification(center: center, token: token)
        }
    }

    func schedule(_ pcm: NativeAudioPCM, completion: @escaping @Sendable () async -> Void) throws {
        guard engine?.isRunning == true, let node, let format,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(pcm.frames)),
              let channels = buffer.floatChannelData else { throw NativeFailure.state }
        buffer.frameLength = AVAudioFrameCount(pcm.frames)
        for frame in 0..<pcm.frames {
            channels[0][frame] = pcm.sample(frame: frame, channel: 0)
            channels[1][frame] = pcm.sample(frame: frame, channel: 1)
        }
        node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in
            Task { await completion() }
        }
    }

    func play() throws { guard engine?.isRunning == true else { throw NativeFailure.state }; node?.play() }
    func pause() { node?.pause() }
    func flush() { node?.stop() }
    func setMuted(_ muted: Bool) { node?.volume = muted ? 0 : 1 }
    func stop() {
        configurationChange = nil
        node?.stop(); engine?.stop()
        node = nil; engine = nil; format = nil
    }
}

/// This actor creates an output graph only after the audio server has passed
/// TLS authentication and its ready schema. It never accesses inputNode.
actor NativeAudioPlayer: NativeAudioPlaying {
    static let prebufferDelay: Duration = .milliseconds(20)
    private let makeOutput: @Sendable () -> any NativeAudioOutputSink
    private let prebufferClock: any NativeAudioPrebufferClock
    private var output: (any NativeAudioOutputSink)?
    private var queue = NativeAudioQueue()
    private var playing = false
    private var stopped = false
    private var prebufferID: UUID?
    private var cancelPrebuffer: (@Sendable () -> Void)?
    private var outputID = UUID()
    private var failureHandler: (@Sendable () async -> Void)?

    init(makeOutput: @escaping @Sendable () -> any NativeAudioOutputSink = { NativeAVAudioOutputSink() },
         prebufferClock: any NativeAudioPrebufferClock = NativeAudioSystemPrebufferClock()) {
        self.makeOutput = makeOutput; self.prebufferClock = prebufferClock
    }

    func start(muted: Bool) throws {
        guard output == nil, !stopped else { throw NativeFailure.state }
        let output = makeOutput(), id = UUID()
        outputID = id
        output.setInvalidationHandler { [weak self] in await self?.outputInvalidated(id: id) }
        do { try output.start(muted: muted) }
        catch { output.stop(); throw error }
        self.output = output
    }

    func setFailureHandler(_ handler: @escaping @Sendable () async -> Void) async { failureHandler = handler }

    private func outputInvalidated(id: UUID) async {
        guard !stopped, id == outputID, output != nil else { return }
        let handler = failureHandler
        stop()
        await handler?()
    }

    func enqueue(_ pcm: NativeAudioPCM) throws {
        guard !stopped, let output else { throw NativeFailure.state }
        let admission = queue.reserve(frames: pcm.frames, sampleGap: pcm.hasSampleGap)
        if admission.flushed {
            cancelPrebufferWait(); output.flush(); playing = false
        }
        do {
            try output.schedule(pcm) { [weak self] in await self?.completed(admission.ticket) }
        } catch {
            queue.flush(); cancelPrebufferWait(); output.flush(); playing = false
            throw error
        }
        guard !playing else { return }
        if queue.queuedFrames >= NativeAudioQueue.prebufferFrames {
            cancelPrebufferWait()
            do { try output.play(); playing = true }
            catch { queue.flush(); output.flush(); playing = false; throw error }
        } else if prebufferID == nil {
            // The protocol permits a final short PCM burst followed only by
            // heartbeats. Its first frame must not wait for another packet.
            let id = UUID(), generation = queue.generation
            prebufferID = id
            cancelPrebuffer = prebufferClock.schedule(after: Self.prebufferDelay) { [weak self] in
                await self?.prebufferExpired(id: id, generation: generation)
            }
        }
    }

    private func prebufferExpired(id: UUID, generation: UUID) async {
        guard !stopped, prebufferID == id, generation == queue.generation,
              !playing, queue.queuedFrames > 0, let output else { return }
        cancelPrebufferWait()
        do { try output.play(); playing = true }
        catch { await outputInvalidated(id: outputID) }
    }

    private func cancelPrebufferWait() {
        prebufferID = nil
        let cancel = cancelPrebuffer; cancelPrebuffer = nil
        cancel?()
    }

    private func completed(_ ticket: NativeAudioQueue.Ticket) {
        guard !stopped, ticket.generation == queue.generation else { return }
        queue.complete(ticket)
        if queue.queuedFrames == 0 {
            cancelPrebufferWait(); output?.pause(); playing = false
        }
    }

    func setMuted(_ muted: Bool) {
        guard !stopped else { return }
        output?.setMuted(muted)
    }

    func stop() {
        guard !stopped else { return }
        stopped = true; outputID = UUID(); failureHandler = nil; queue.flush(); playing = false; cancelPrebufferWait()
        output?.stop(); output = nil
    }
}
