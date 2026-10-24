// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// App quality choices shared by the settings surface and stream admission.
/// Zero bitrate means the existing resolution-based default, not unlimited data.
public struct DesktopVideoPolicy: Equatable, Sendable {
    public static let resolutions = [1080, 1440, 2160]
    public static let frameRates = [30, 60]
    public static let bitratesKbps = [0, 10000, 20000, 30000, 40000, 60000, 80000, 100000]
    public let width: Int
    public let height: Int
    public let frameRate: Int
    public let bitrateKbps: Int

    public init(resolution: Int, frameRate: Int, bitrateKbps: Int) throws {
        guard Self.frameRates.contains(frameRate), Self.bitratesKbps.contains(bitrateKbps) else {
            throw Failure.unsupportedSettings
        }
        let automatic: Int
        switch resolution {
        case 1080: width = 1920; automatic = 20000
        case 1440: width = 2560; automatic = 30000
        case 2160: width = 3840; automatic = 60000
        default: throw Failure.unsupportedSettings
        }
        height = resolution
        self.frameRate = frameRate
        self.bitrateKbps = bitrateKbps == 0 ? automatic : bitrateKbps
    }

    public enum Failure: LocalizedError {
        case unsupportedSettings
        public var errorDescription: String? { "지원하는 해상도·프레임·비트레이트를 선택한 뒤 다시 연결하세요." }
    }
}
