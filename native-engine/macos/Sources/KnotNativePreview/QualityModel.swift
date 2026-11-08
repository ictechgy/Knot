import Foundation
import Combine
import KnotNativeCore

@MainActor
final class QualityModel: ObservableObject {
    enum Preference: UInt8, CaseIterable, Identifiable {
        case automatic, sharp, responsive
        var id: UInt8 { rawValue }
        var title: String { switch self { case .automatic: "자동"; case .sharp: "글자 선명도 우선"; case .responsive: "반응 우선" } }
    }
    @Published private(set) var preference: Preference = .automatic
    @Published private(set) var status = "네트워크와 화면 처리 상태에 맞춰 조절해요."
    private let send: (Packet) -> Bool
    private var lastFeedback = ContinuousClock.now
    init(send: @escaping (Packet) -> Bool) { self.send = send }
    func choose(_ value: Preference) {
        guard send(Packet(kind: .qualityPreference, payload: Data([value.rawValue]))) else { return }
        preference = value
    }
    func reportPressure(_ overloaded: Bool, now: ContinuousClock.Instant = .now) {
        guard now - lastFeedback >= .seconds(2) else { return }
        lastFeedback = now
        _ = send(Packet(kind: .qualityFeedback, payload: Data([overloaded ? 1 : 0])))
    }
    func accept(_ payload: Data) {
        guard payload.count == 9 else { return }
        let bytes = Array(payload)
        func uint(_ at: Int) -> UInt32 { bytes[at..<at+4].reduce(0) { ($0 << 8) | UInt32($1) } }
        let fps = uint(0), bitrate = uint(4)
        guard (1...60).contains(fps), (1_000_000...40_000_000).contains(bitrate), bytes[8] <= 1 else { return }
        status = bytes[8] == 1 ? "현재 최대 \(fps)fps · \(bitrate / 1_000_000)Mbps" : "이 인코더는 자동 FPS·전송률 조정을 지원하지 않아 현재 값을 유지해요."
    }
}
