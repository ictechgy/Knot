import Foundation

public enum VideoControlOperation: UInt8, Sendable { case profile = 1, pause = 2, resume = 3 }
public enum VideoControlOutcome: UInt8, Sendable { case preparing = 0, applied = 1, rejected = 2, rolledBack = 3 }
public enum VideoControlReason: UInt8, Sendable { case none = 0, unsupported = 1, outOfPolicy = 2, busy = 3, initializationFailed = 4 }
public enum VideoControlState: UInt8, Sendable { case running = 0, paused = 1 }

/// Host-confirmed encoder configuration, distinct from requested bounds and throughput.
public struct VideoConfiguration: Sendable, Equatable {
    public let width: Int, height: Int, fps: Int, bitrate: Int
    public init(width: Int, height: Int, fps: Int, bitrate: Int) {
        self.width = width; self.height = height; self.fps = fps; self.bitrate = bitrate
    }
    public var isValid: Bool {
        VideoLimits.accepts(width: width, height: height) && (1...60).contains(fps) && (1_000_000...40_000_000).contains(bitrate)
    }
    public var isRequestedProfile: Bool {
        [(1920, 1080), (2560, 1440), (3840, 2160)].contains { $0.0 == width && $0.1 == height } &&
        [30, 60].contains(fps) && (1_000_000...40_000_000).contains(bitrate)
    }
}

public struct VideoControlRequest: Sendable, Equatable {
    public let operation: VideoControlOperation
    public let requestID: UInt64
    public let profile: VideoConfiguration?
    public init(operation: VideoControlOperation, requestID: UInt64, profile: VideoConfiguration? = nil) throws {
        guard requestID > 0, (operation == .profile ? profile?.isRequestedProfile == true : profile == nil) else { throw NativeFailure.malformed }
        self.operation = operation; self.requestID = requestID; self.profile = profile
    }
    public init(_ bytes: Data) throws {
        guard bytes.count == 26, bytes[bytes.startIndex] == 1,
              let operation = VideoControlOperation(rawValue: bytes[bytes.startIndex + 1]) else { throw NativeFailure.malformed }
        let id = bytes.readBE(UInt64.self, at: 2)
        let configuration = VideoConfiguration(width: Int(bytes.readBE(UInt32.self, at: 10)), height: Int(bytes.readBE(UInt32.self, at: 14)),
                                               fps: Int(bytes.readBE(UInt32.self, at: 18)), bitrate: Int(bytes.readBE(UInt32.self, at: 22)))
        if operation != .profile {
            guard configuration == VideoConfiguration(width: 0, height: 0, fps: 0, bitrate: 0) else { throw NativeFailure.malformed }
        }
        try self.init(operation: operation, requestID: id, profile: operation == .profile ? configuration : nil)
    }
    public var packet: Packet {
        var bytes = Data([1, operation.rawValue]); bytes.appendBE(requestID)
        bytes.appendBE(UInt32(profile?.width ?? 0)); bytes.appendBE(UInt32(profile?.height ?? 0))
        bytes.appendBE(UInt32(profile?.fps ?? 0)); bytes.appendBE(UInt32(profile?.bitrate ?? 0))
        return Packet(kind: .videoControl, payload: bytes)
    }
}

public struct VideoControlStatus: Sendable, Equatable {
    public let operation: VideoControlOperation
    public let requestID: UInt64, videoEpoch: UInt64
    public let outcome: VideoControlOutcome
    public let reason: VideoControlReason
    public let state: VideoControlState
    public let actual: VideoConfiguration
    public let nextSequence: UInt64
    public init(_ bytes: Data) throws {
        guard bytes.count == 45, bytes[bytes.startIndex] == 1,
              let operation = VideoControlOperation(rawValue: bytes[bytes.startIndex + 1]),
              let outcome = VideoControlOutcome(rawValue: bytes[bytes.startIndex + 18]),
              let reason = VideoControlReason(rawValue: bytes[bytes.startIndex + 19]),
              let state = VideoControlState(rawValue: bytes[bytes.startIndex + 20]) else { throw NativeFailure.malformed }
        self.operation = operation; requestID = bytes.readBE(UInt64.self, at: 2); videoEpoch = bytes.readBE(UInt64.self, at: 10)
        self.outcome = outcome; self.reason = reason; self.state = state
        actual = VideoConfiguration(width: Int(bytes.readBE(UInt32.self, at: 21)), height: Int(bytes.readBE(UInt32.self, at: 25)),
                                    fps: Int(bytes.readBE(UInt32.self, at: 29)), bitrate: Int(bytes.readBE(UInt32.self, at: 33)))
        nextSequence = bytes.readBE(UInt64.self, at: 37)
        guard requestID > 0, actual.isValid,
              (outcome == .preparing || outcome == .applied ? reason == .none : reason != .none),
              outcome != .rolledBack || reason == .initializationFailed else { throw NativeFailure.malformed }
    }
    public var requiresReset: Bool { nextSequence != 0 }
}

/// Ordered reset barriers are validated on the media reader before decoding.
/// Only the sole writer may register the next request, immediately before send.
public struct VideoControlReceiveState: Sendable {
    public private(set) var epoch: UInt64 = 0
    public private(set) var state: VideoControlState = .running
    public private(set) var actual: VideoConfiguration?
    public private(set) var pending: VideoControlRequest?
    public private(set) var firstSequence: UInt64?
    private var acceptedBounds: VideoConfiguration?
    private var lastRequestID: UInt64 = 0
    private var preparing = false
    public init() {}
    mutating func start(profile: VideoConfiguration) { actual = profile; acceptedBounds = profile }
    public mutating func expect(_ request: VideoControlRequest) throws {
        guard actual != nil, pending == nil, firstSequence == nil, lastRequestID != UInt64.max,
              request.requestID > lastRequestID, lastRequestID != 0 || request.requestID == 1 else { throw NativeFailure.state }
        pending = request; lastRequestID = request.requestID; preparing = false
    }
    public mutating func accept(_ status: VideoControlStatus, sequence: UInt64) throws {
        guard let pending, status.requestID == pending.requestID, status.operation == pending.operation,
              let actual else { throw NativeFailure.state }
        switch status.outcome {
        case .preparing:
            guard !preparing, status.videoEpoch == epoch, status.nextSequence == 0,
                  status.state == state, status.actual == actual else { throw NativeFailure.state }
            preparing = true; return
        case .rejected:
            guard status.videoEpoch == epoch, status.nextSequence == 0, status.state == state, status.actual == actual else { throw NativeFailure.state }
        case .applied, .rolledBack:
            if status.outcome == .applied, let requested = pending.profile {
                guard status.actual.width <= requested.width, status.actual.height <= requested.height,
                      status.actual.fps <= requested.fps, status.actual.bitrate <= requested.bitrate else { throw NativeFailure.state }
            }
            if status.state == .paused {
                guard status.outcome == .applied, pending.operation == .pause, status.videoEpoch == epoch,
                      status.nextSequence == 0, status.actual == actual, state == .paused || preparing else { throw NativeFailure.state }
            } else if status.videoEpoch == epoch {
                guard status.outcome == .applied, state == .running, status.nextSequence == 0, status.actual == actual,
                      pending.operation == .resume else { throw NativeFailure.state }
            } else {
                guard preparing, epoch != UInt64.max, status.videoEpoch == epoch + 1, sequence != UInt64.max,
                      status.nextSequence == sequence + 1, pending.operation != .pause,
                      status.outcome != .rolledBack || pending.operation == .profile else { throw NativeFailure.state }
                if status.outcome == .rolledBack || pending.operation == .resume {
                    guard let bounds = acceptedBounds, status.actual.width == actual.width, status.actual.height == actual.height,
                          status.actual.fps <= bounds.fps, status.actual.bitrate <= bounds.bitrate else { throw NativeFailure.state }
                }
                epoch = status.videoEpoch; firstSequence = status.nextSequence
            }
            if status.outcome == .applied, let profile = pending.profile { acceptedBounds = profile }
            self.actual = status.actual; state = status.state
        }
        self.pending = nil; preparing = false
    }
    public mutating func acceptQuality(fps: Int, bitrate: Int) {
        guard let actual else { return }
        self.actual = VideoConfiguration(width: actual.width, height: actual.height, fps: fps, bitrate: bitrate)
    }
    public mutating func acceptVideo(_ video: VideoPacket) throws {
        guard state == .running else { throw NativeFailure.state }
        if let expected = firstSequence {
            guard video.sequence == expected, video.accessUnit.isIDR, !video.accessUnit.sps.isEmpty, !video.accessUnit.pps.isEmpty else { throw NativeFailure.state }
            firstSequence = nil
        }
    }
}

public typealias VideoProfile = VideoConfiguration
