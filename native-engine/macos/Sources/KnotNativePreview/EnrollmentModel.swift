import Foundation
import Combine
import KnotNativeCore

@MainActor
final class EnrollmentModel: ObservableObject {
    enum Phase: Equatable { case idle, discovering, authenticating, failed }
    static let authenticationGuidance = "8자리 번호를 확인하거나 주변 PC를 다시 찾아 선택해주세요. 번호가 바뀌었거나 여러 번 실패했다면 Windows에서 공유를 다시 시작하세요."
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var candidates: [EnrollmentCandidate] = []
    @Published private(set) var selectedID: String?
    @Published var code = ""
    @Published var manualAddress = ""
    @Published private(set) var status = "Windows에서 화면 공유를 시작한 뒤 주변 PC를 찾아주세요."
    var selected: EnrollmentCandidate? { candidates.first { $0.id == selectedID } }
    var busy: Bool { phase == .discovering || phase == .authenticating }
    private let makeDiscovery: @Sendable () -> any EnrollmentDiscovering
    private let makeClient: @Sendable (EnrollmentCandidate, Data) throws -> any EnrollmentAuthenticating
    private var task: Task<Void, Never>?
    private var discovery: (any EnrollmentDiscovering)?
    private var client: (any EnrollmentAuthenticating)?
    private var generation = UUID()

    init(makeDiscovery: @escaping @Sendable () -> any EnrollmentDiscovering = { DiscoveryClient() },
         makeClient: @escaping @Sendable (EnrollmentCandidate, Data) throws -> any EnrollmentAuthenticating = {
             try EnrollmentClient(candidate: $0, password: $1)
         }, initialCandidates: [EnrollmentCandidate] = [], initialPhase: Phase = .idle, initialStatus: String? = nil) {
        self.makeDiscovery = makeDiscovery; self.makeClient = makeClient
        candidates = Array(initialCandidates.prefix(EnrollmentWire.candidateLimit))
        selectedID = candidates.count == 1 ? candidates.first?.id : nil
        phase = initialPhase
        if let initialStatus { status = initialStatus }
    }
    @discardableResult func find(manual: Bool = false) -> Task<Void, Never>? {
        let address = manual ? manualAddress : nil
        if let address, !Invitation.isPrivateIPv4(address) {
            fail(.invalidTarget); return nil
        }
        cancel()
        let id = generation
        let discovery = makeDiscovery(); self.discovery = discovery
        phase = .discovering; status = "공유 중인 PC를 찾고 있어요…"
        task = Task { [weak self] in
            defer { discovery.close() }
            do {
                let values = try await discovery.discover(address: address)
                guard let self, self.generation == id, !Task.isCancelled else { return }
                self.discovery = nil; self.task = nil
                self.candidates = Array(values.prefix(EnrollmentWire.candidateLimit))
                self.selectedID = values.count == 1 ? values.first?.id : nil
                self.phase = .idle
                self.status = values.isEmpty ? "공유 중인 PC를 찾지 못했어요. Windows에서 공유를 시작했는지 확인하거나 주소로 찾아주세요." :
                    "연결할 PC를 선택하고 Windows에 표시된 8자리 번호를 입력하세요."
            } catch {
                guard let self, self.generation == id, !Task.isCancelled else { return }
                self.fail(Self.failure(error))
            }
        }
        return task
    }
    func select(_ id: String) {
        guard candidates.contains(where: { $0.id == id }) else { return }
        if selectedID != id || busy {
            generation = UUID(); task?.cancel(); discovery?.close(); client?.close()
            task = nil; discovery = nil; client = nil; code = ""
        }
        selectedID = id; phase = .idle
        status = "Windows에 표시된 8자리 번호를 입력하세요. 번호를 아는 Mac 한 대에 이번 연결만 허용돼요."
    }
    @discardableResult func connect(name: String, authenticated: @escaping @MainActor (AuthenticatedEnrollment) -> Void) -> Task<Void, Never>? {
        guard !busy, let candidate = selected, Invitation.validViewerLabel(name) else { return nil }
        var password: Data
        do { password = try EnrollmentWire.password(code) }
        catch { fail(.invalidCode, keepCandidates: true); return nil }
        code = ""
        defer { password.resetBytes(in: 0..<password.count) }
        let id = UUID(); generation = id
        do {
            let run = try makeClient(candidate, password); client = run
            phase = .authenticating; status = "8자리 번호를 확인하고 연결 정보를 안전하게 받고 있어요…"
            task = Task { [weak self] in
                do {
                    let result = try await run.authenticate(name: name)
                    guard let self, self.generation == id, !Task.isCancelled else { return }
                    guard ContinuousClock.now < result.expiresAt else { self.fail(.expired); return }
                    self.client = nil; self.task = nil; self.code = ""
                    self.phase = .idle; self.status = "번호를 확인했어요. 화면 연결을 준비해요."
                    authenticated(result)
                } catch {
                    guard let self, self.generation == id, !Task.isCancelled else { return }
                    let failure = Self.failure(error)
                    self.fail(failure, keepCandidates: failure == .authentication || failure == .invalidCode)
                }
            }
        } catch { fail(Self.failure(error)); return nil }
        return task
    }
    private static func failure(_ error: any Error) -> EnrollmentFailure {
        if let failure = error as? EnrollmentFailure { return failure }
        if let failure = error as? NativeFailure {
            switch failure {
            case .transport: return .transport
            default: return .invalidMessage
            }
        }
        if error is CancellationError { return .cancelled }
        return .transport
    }
    func cancel() {
        generation = UUID(); task?.cancel(); task = nil
        discovery?.close(); discovery = nil; client?.close(); client = nil
        code = ""; candidates = []; selectedID = nil
        phase = .idle; status = "Windows에서 공유를 시작한 뒤 PC를 찾아주세요."
    }
    private func fail(_ error: EnrollmentFailure, keepCandidates: Bool = false) {
        let saved = keepCandidates ? candidates : [], selected = keepCandidates ? selectedID : nil
        cancel(); candidates = saved; selectedID = selected; phase = .failed
        switch error {
        case .invalidCode, .authentication:
            status = Self.authenticationGuidance
        case .invalidTarget:
            status = "개인 LAN 또는 Tailscale IPv4 주소를 입력해주세요. 인터넷 주소나 웹 링크는 사용할 수 없어요."
        case .expired: status = "연결 번호가 만료됐어요. Windows에서 공유를 다시 시작하고 PC를 다시 찾아주세요."
        case .busy: status = "Windows가 다른 연결을 처리하고 있어요. 해당 연결을 마친 뒤 다시 시도하세요."
        case .invalidMessage: status = "연결 정보를 확인하지 못했어요. 두 기기의 앱 버전을 확인하고 다시 시도하세요."
        case .cancelled: status = "연결 준비가 중단됐어요. 다시 연결하려면 PC를 찾아주세요."
        case .transport: status = "PC에 연결하지 못했어요. 같은 Wi-Fi·Tailscale 주소와 Windows 방화벽을 확인하세요."
        }
    }
}
