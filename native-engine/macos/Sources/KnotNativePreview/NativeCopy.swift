import Foundation

@MainActor
enum NativeCopy {
    static let certificatePinMismatchGuidance = "Windows PC의 인증서가 연결 정보와 달라 연결을 중단했어요. Windows를 확인하고 새 8자리 번호로 다시 등록하세요."
    static let certificatePolicyGuidance = "macOS가 Windows 인증서를 허용하지 않았어요. Windows Knot native.12 이상에서 ‘호환 인증서로 전환하고 공유’를 선택한 뒤 새 8자리 번호로 다시 연결하세요."
    static func phase(_ phase: SessionModel.Phase) -> String {
        switch phase {
        case .idle: "연결 전"
        case .connecting: "PC 확인 중"
        case .approval: "Windows 승인 대기"
        case .decoding: "화면 준비 중"
        case .streaming: "화면 수신 중"
        case .failed: "연결 확인 필요"
        }
    }
    static func status(_ source: String, reconnectMethod: SessionModel.ReconnectMethod = .invitation) -> String {
        if reconnectMethod == .registered, let reason = numberReconnectReasons[source] {
            let registeredReason = source == "Invitation was rejected or expired. Create a new invitation."
                ? "Windows에서 연결을 허용하지 않았거나 연결 정보가 만료됐어요." : reason
            return registeredReason + " Windows의 공유 상태를 확인한 뒤 ‘내 PC’에서 다시 연결하세요."
        }
        if reconnectMethod == .number, let reason = numberReconnectReasons[source] {
            return reason + " Windows에서 공유를 다시 시작하고 새 8자리 번호로 연결하세요."
        }
        if let copy = statuses[source] { return copy }
        if source.hasPrefix("Display is behind; still receiving decoded images.") {
            return source.contains("Input paused") ? "화면 표시가 지연되고 있어요. 입력을 다시 시작하려면 화면을 클릭하세요." : "화면은 수신 중이지만 표시가 지연되고 있어요."
        }
        if source.hasPrefix("Receiving the host desktop.") {
            if source.contains("Input paused") { return "입력이 일시 중지됐어요. 화면을 클릭하면 다시 시작해요." }
            return source.contains("Registered device; encrypted connection.")
                ? "Windows 화면을 수신하고 있어요. 등록된 PC와 암호화해 연결됐어요."
                : "Windows 화면을 수신하고 있어요. 이번 연결만 허용돼요."
        }
        // The lifecycle owns meaning. Unknown authored guidance stays visible;
        // translation never becomes an authentication or readiness predicate.
        return source
    }
    private static let numberReconnectReasons: [String: String] = [
        "The native decoder stopped. Create a new invitation to reconnect.": "영상 처리가 중단됐어요.",
        "The native display stopped. Create a new invitation to reconnect.": "화면 표시가 중단됐어요.",
        "Connection ended or validation failed. Ask the host for a new invitation.": "연결이 끝났거나 확인에 실패했어요.",
        "The network connection stopped. Check Windows sharing and the network before reconnecting.": "네트워크 연결이 중단됐어요. Windows의 공유 상태, 같은 네트워크와 방화벽을 확인하세요.",
        "Invitation was rejected or expired. Create a new invitation.": "연결 번호가 만료됐거나 연결을 확인하지 못했어요.",
        "The host declined the request. Create a new invitation to try again.": "Windows에서 연결을 종료했어요.",
        "The host stopped accepting input. Create a new invitation.": "입력을 안전하게 처리할 수 없어 연결을 중단했어요.",
        "The connection timed out. Create a new invitation.": "연결 대기 시간이 지났어요.",
        "The host closed the connection. Create a new invitation to reconnect.": "Windows에서 연결을 종료했어요.",
        "The peer or host approval timed out. Create a new invitation.": "Windows의 응답을 기다리는 시간이 지났어요.",
        "The first decoded image did not arrive. Create a new invitation.": "첫 화면이 도착하지 않았어요.",
        "Input transport stopped. Create a new invitation to reconnect.": "입력 연결이 중단됐어요.",
        "Disconnected. Reconnect with a fresh invitation.": "연결을 종료했어요."
    ]
    private static let statuses: [String: String] = [
        "Paste a fresh invitation, review its target and certificate, then connect.": "Windows에서 새 연결 코드를 복사해 주세요.",
        "Review the private address and exact certificate pin below. Trust lasts for this connection only.": "Windows에 표시된 인증서 지문과 같은지 확인한 뒤 연결하세요.",
        "Invalid invitation. Ask the host to create a fresh native invitation.": "연결 코드를 확인할 수 없어요. Windows에서 새 코드를 만들어 다시 입력해 주세요.",
        "Choose a viewer label of 1–64 UTF-8 bytes without control characters.": "Mac 이름을 짧게 입력해 주세요. 제어 문자 없이 64바이트까지 사용할 수 있어요.",
        "Checking the secure connection…": "보안 연결을 확인하고 있어요.",
        "Sending the connection request…": "Windows에 연결 요청을 보내고 있어요.",
        "The network connection stopped. Check Windows sharing and the network before reconnecting.": "네트워크 연결이 중단됐어요. Windows의 공유 상태, 같은 네트워크와 방화벽을 확인한 뒤 새 연결 코드로 다시 연결하세요.",
        "Certificate verified. Waiting for host approval and native encoder startup…": "Windows에서 연결 요청을 허용해 주세요. 승인 후 화면을 준비해요.",
        "Number verified. Preparing the host desktop…": "번호를 확인했어요. Windows 화면과 인코더를 준비해요.",
        "Host approved and encoder ready. Waiting for the first decoded image…": "Windows가 연결을 허용했어요. 첫 화면이 도착하기를 기다려요.",
        "The native decoder stopped. Create a new invitation to reconnect.": "영상 처리가 중단됐어요. Windows에서 새 연결 코드를 만들어 주세요.",
        "The native display stopped. Create a new invitation to reconnect.": "화면 표시가 중단됐어요. Windows에서 새 연결 코드를 만들어 주세요.",
        "Connection ended or validation failed. Ask the host for a new invitation.": "연결이 끝났거나 확인에 실패했어요. Windows에서 새 연결 코드를 만들어 주세요.",
        "Invitation was rejected or expired. Create a new invitation.": "연결 코드가 만료됐거나 거절됐어요. Windows에서 새 코드를 만들어 주세요.",
        "The host declined the request. Create a new invitation to try again.": "Windows에서 요청을 거절했어요. 다시 연결하려면 새 코드가 필요해요.",
        "The host is already handling another request.": "Windows가 다른 연결 요청을 처리하고 있어요.",
        "Host capture is unavailable. Check its logged-in SDR primary display.": "Windows 화면을 가져올 수 없어요. 로그인된 기본 모니터와 SDR 설정을 확인해 주세요.",
        "The host hardware H.264 encoder could not start.": "Windows의 하드웨어 영상 인코더를 시작할 수 없어요. 그래픽 드라이버와 지원 여부를 확인해 주세요.",
        "The host stopped accepting input. Create a new invitation.": "입력을 안전하게 처리할 수 없어 연결을 중단했어요. 새 연결 코드로 다시 시도해 주세요.",
        "The connection timed out. Create a new invitation.": "연결 대기 시간이 지났어요. Windows에서 새 연결 코드를 만들어 주세요.",
        "The host closed the connection. Create a new invitation to reconnect.": "Windows에서 연결을 종료했어요. 새 연결 코드로 다시 연결해 주세요.",
        "The peer or host approval timed out. Create a new invitation.": "Windows의 응답이나 승인을 기다리는 시간이 지났어요. 새 연결 코드를 만들어 주세요.",
        "The first decoded image did not arrive. Create a new invitation.": "첫 화면이 도착하지 않았어요. Windows에서 새 연결 코드를 만들어 다시 시도해 주세요.",
        "Input paused after queue saturation. Click the desktop to resume.": "입력이 밀려 일시 중지했어요. 화면을 클릭하면 다시 시작해요.",
        "Text was too long or contained unsupported characters. Click the desktop and enter smaller parts.": "긴 글이나 지원하지 않는 문자는 전달하지 못했어요. 화면을 클릭한 뒤 글을 나누어 입력해주세요.",
        "Input paused. Click the desktop to resume.": "입력이 일시 중지됐어요. 화면을 클릭하면 다시 시작해요.",
        "Input transport stopped. Create a new invitation to reconnect.": "입력 연결이 중단됐어요. 새 연결 코드로 다시 연결해 주세요.",
        "Disconnected. Reconnect with a fresh invitation.": "연결을 종료했어요. 다시 연결하려면 Windows에서 새 코드를 만들어 주세요."
    ]
}
