# Knot 자체 엔진 실험판

Sunshine·Moonlight를 설치하거나 실행하지 않는 별도 시험 앱입니다. 기존 Knot과 나란히 둘 수 있습니다.

1. Windows11 x64에서 설치 EXE로 **Knot Native Preview**를 설치해 엽니다. WindowsHome도 대상입니다. **Share → Copy invitation**으로 새 연결 코드를 만듭니다. 필요한 LAN/Tailscale 주소는 Windows에서 선택합니다.
2. Mac에 DMG의 **Knot Native Preview.app**을 Applications로 옮겨 실행합니다. 코드를 붙여 넣고 주소·인증서 지문을 확인한 뒤 연결합니다.
3. Windows에서 표시된 Mac 요청을 확인하고 **Approve**를 누르면 화면과 입력을 시작합니다. **Stop / revoke all** 또는 연결 종료로 이번 권한을 없앱니다.

코드는120초·1회용이며 매 연결마다 새로 필요합니다. 선샤인 계정·웹 PIN·SSH 설정은 없습니다. 파일·오디오·무모니터·HDR·다중 모니터·로그인/잠금/UAC 화면·저장된 페어링·자동 업데이트는 아직 이 실험판 범위가 아닙니다. 실제GPU의 하드웨어H.264 인코더가 필요하고, 지원하지 않으면 소프트웨어로 몰래 전환하지 않고 안내합니다. 초기는 로그인한 기본 SDR 가로 화면으로 시험해 주세요.

Mac은 AppleSilicon/macOS26 이상이 필요합니다. Windows는 미서명, Mac은 ad-hoc서명·미공증 프리뷰라 실행 차단이 남을 수 있습니다. 기존 앱의 인증서·페어링·설정을 가져오거나 초기화하지 않습니다.

자동검사는 실제 캡처·사용자 화면·키보드 주입 없이 새 합성 영상과 임시 TLS 인증서로 실행합니다. 실제 WindowsHome/GPU와 두 기기 화면·입력·색·지연은 별도 실기기 검증이 필요합니다. [영문 구현·빌드·제한](README.md), [프로토콜](PROTOCOL.md).
