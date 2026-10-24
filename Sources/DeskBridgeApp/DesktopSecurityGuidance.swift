// SPDX-License-Identifier: GPL-3.0-only
import GlimmerEngine

/// Fixed copy shared by the operation catch and the streaming recovery shell.
/// Pure presentation keeps remote diagnostics and app state out of this boundary.
enum DesktopSecurityGuidance {
    static let unclassified = "화면 보안 연결을 확인하지 못해 중단했습니다. Sunshine을 다시 시작한 뒤 다시 연결하세요. 계속되면 Knot과 Sunshine 버전을 확인하세요. 저장된 인증서는 유지됩니다. [S03]"
    static func negotiation(_ failure: StreamSecurityPolicy.Failure) -> String {
        switch failure {
        case .plaintextSignalling:
            return "필수 화면 암호화의 보안 신호 연결을 확인하지 못했습니다. 연결 대상 PC의 Sunshine을 업데이트하고 다시 시작한 뒤 연결하세요. PIN 페어링과 저장된 인증서는 유지됩니다. [S01]"
        case .missingEncryption:
            return "필수 화면 암호화 채널을 확인하지 못했습니다. 연결 대상 PC의 브라우저에서 https://localhost:47990/config#lan_encryption_mode 를 여세요. LAN 암호화 모드와 WAN 암호화 모드를 ‘모든 사용자에게 필수’(Required for all clients)로 선택한 뒤 Save → Apply를 누르세요. 다시 연결해도 같으면 Knot과 Sunshine 버전을 확인하세요. PIN 페어링은 유지됩니다. [S02]"
        }
    }
}
