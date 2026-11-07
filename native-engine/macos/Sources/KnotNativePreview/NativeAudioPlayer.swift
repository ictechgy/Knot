import Foundation
import AVFAudio
import KnotNativeCore

protocol NativeAudioPlaying: Sendable {
    func start(muted: Bool) async throws
    func enqueue(_ pcm: NativeAudioPCM) async throws
    func setMuted(_ muted: Bool) async
    func stop() async
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

/// This actor creates an output graph only after the audio server has passed
/// TLS authentication and its ready schema. It never accesses inputNode.
actor NativeAudioPlayer: NativeAudioPlaying {
    private var engine: AVAudioEngine?
    private var node: AVAudioPlayerNode?
    private var format: AVAudioFormat?
    private var queue = NativeAudioQueue()
    private var playing = false
    private var stopped = false

    func start(muted: Bool) throws {
        guard engine == nil, !stopped else { throw NativeFailure.state }
        guard let format = AVAudioFormat(standardFormatWithSampleRate: Double(NativeAudioWire.sampleRate), channels: 2) else { throw NativeFailure.unsupported }
        let engine = AVAudioEngine(), node = AVAudioPlayerNode()
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        node.volume = muted ? 0 : 1
        engine.prepare()
        do { try engine.start() }
        catch { engine.stop(); throw NativeFailure.transport }
        self.format = format; self.node = node; self.engine = engine
    }

    func enqueue(_ pcm: NativeAudioPCM) throws {
        guard !stopped, let node, let format,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(pcm.frames)),
              let channels = buffer.floatChannelData else { throw NativeFailure.state }
        buffer.frameLength = AVAudioFrameCount(pcm.frames)
        for frame in 0..<pcm.frames {
            channels[0][frame] = pcm.sample(frame: frame, channel: 0)
            channels[1][frame] = pcm.sample(frame: frame, channel: 1)
        }
        let admission = queue.reserve(frames: pcm.frames, sampleGap: pcm.hasSampleGap)
        if admission.flushed { node.stop(); playing = false }
        node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { await self?.completed(admission.ticket) }
        }
        if !playing && queue.queuedFrames >= NativeAudioQueue.prebufferFrames { node.play(); playing = true }
    }

    private func completed(_ ticket: NativeAudioQueue.Ticket) {
        guard !stopped, ticket.generation == queue.generation else { return }
        queue.complete(ticket)
        if queue.queuedFrames == 0 { node?.pause(); playing = false }
    }

    func setMuted(_ muted: Bool) { node?.volume = muted ? 0 : 1 }

    func stop() {
        stopped = true; queue.flush(); playing = false
        node?.stop(); engine?.stop()
        node = nil; engine = nil; format = nil
    }
}
