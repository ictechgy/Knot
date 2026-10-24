# Knot 설치

개발 프리뷰 **0.2.0-preview.16**입니다. 실제 기기 설치와 두 기기 연결 검증은 아직 남아 있습니다.

| 컴퓨터 | 다운로드 | 요구 사항 |
| --- | --- | --- |
| Mac | [DMG](https://github.com/ictechgy/Knot/releases/download/v0.2.0-preview.16/Knot-0.2.0-preview.16-macos-arm64-preview.dmg) | Apple Silicon, macOS 26 이상 |
| Windows | [설치 EXE](https://github.com/ictechgy/Knot/releases/download/v0.2.0-preview.16/Knot-0.2.0-preview.16-windows-x64-setup.exe) | Windows 11 x64, Home 포함 |
| Linux 호스트 | [DEB](https://github.com/ictechgy/Knot/releases/download/v0.2.0-preview.16/Knot-0.2.0-preview.16-ubuntu24.04-amd64-preview.deb) | Ubuntu 24.04 LTS amd64, 로그인한 X11 데스크톱 |

[릴리스 안내·대응 소스](https://github.com/ictechgy/Knot/releases/tag/v0.2.0-preview.16) · [SHA256SUMS](https://github.com/ictechgy/Knot/releases/download/v0.2.0-preview.16/SHA256SUMS)

Mac 패키지는 ad-hoc 서명·미공증, Windows EXE는 미서명입니다. 이 배포 프리뷰의 가상 화면 자동 설치는 드라이버 안전성 검토로 비활성화되어 있습니다. 무모니터 동작을 전제로 사용하지 마세요.

## Mac에서 Windows 열기

**최신 소스 빌드:** Windows에서 **연결 준비 · 자동 설정**을 누르세요. 필요한 Sunshine 설치 후 Knot의 계정·보안·PIN 창이 이어집니다. 기존 계정은 로그인하며, 첫 계정만 새로 만듭니다. 보안 설정 적용 시 Sunshine이 재시작될 수 있으니 다른 Sunshine 설정 창과 화면 세션을 먼저 닫으세요. Windows에서 준비를 마친 그 창을 열어 둔 채 Mac에서 PIN 연결을 시작한 뒤 요청을 선택하고 Mac의 번호를 승인합니다. 저장된 보안 설정이 맞으면 PIN 승인 때문에 다시 시작하지 않습니다. 보안 설정 다시 적용을 선택했다면 기존 Mac PIN을 취소하고 준비 후 새 PIN을 만드세요. UAC·계정·PIN 확인은 직접 하며, 인증서와 기존 페어링은 유지됩니다. 아래는 공개 preview.16 및 **고급·수동 설정** 경로입니다.

1. **Windows:** **Knot-…-windows-x64-setup.exe**를 두 번 클릭하고 설치 과정의 UAC 요청을 승인합니다. 설치 후 시작 메뉴의 **Knot 설정**을 열고 **이 Windows 공유**를 고릅니다. 설치 프로그램은 시작 메뉴와 제거 기능을 제공하며 설치 후 도우미를 원래 사용자 권한으로 엽니다. ZIP 압축 해제나 PowerShell 명령 입력은 필요 없습니다. EXE를 **관리자 권한으로 실행**할 필요는 없습니다.
2. 안내창의 **Sunshine 설치**를 누릅니다. 고정된 공식 MSI의 크기·SHA256를 검증한 뒤 설치 화면이 열립니다. 이미 Sunshine이 있다면 설치를 건너뛰세요. 설치 프로그램의 성공은 화면 연결 준비 완료를 뜻하지 않습니다. Knot은 설치 후 최대 15초 동안 로컬 설정 포트 응답을 확인하며, 이 확인은 취소할 수 있습니다.
3. **이 Windows에서 Sunshine 설정 열기**를 누릅니다. Sunshine은 별도 창 없이 백그라운드에서 실행됩니다. 이 **Windows PC의 Edge/Chrome**에서 초기 계정을 만들고 로그인하세요. **영상 암호화 설정 열기**를 누르고 **LAN Encryption Mode / WAN Encryption Mode**를 둘 다 **Required for all clients**로 선택한 뒤 **Save → Apply/재시작** 순서로 적용합니다. 한국어 화면의 이름은 **LAN/WAN 암호화 모드 → 모든 사용자에게 필수**입니다. Wi-Fi와 Tailscale 연결도 LAN으로 분류될 수 있으므로 WAN 설정만 바꾸면 충분하지 않습니다. Desktop 앱을 확인하세요. 이 초기 설정은 아직 직접 해야 합니다. 계정·암호는 Knot에 전달하지 않습니다. 게임패드 드라이버는 업무용 키보드·마우스 연결에 필요하지 않습니다.
4. **Mac:** DMG를 열고 **Knot.app → Applications**로 드래그해 실행합니다. 로컬 네트워크 권한을 허용하고 **근처 Windows PC → 이 PC 확인 → PIN으로 연결**을 누릅니다. **Windows:** Knot의 **이 Windows에서 PIN 입력 화면 열기**를 누릅니다. Sunshine에 로그인한 뒤 **Mac에 표시된 PIN을 이 Windows 브라우저의 PIN 화면에 입력**합니다. **Mac:** PIN 승인을 마치면 **Windows 열기**를 누릅니다.

**설정 페이지가 열리지 않으면:** 이 Windows의 브라우저 주소창에 `https://localhost:47990/`를 직접 입력하세요. PIN 화면은 `https://localhost:47990/pin`, 암호화 설정 바로가기는 `https://localhost:47990/config#lan_encryption_mode`입니다. `localhost`는 브라우저를 연 컴퓨터 자신을 뜻하므로 Mac에서 열면 Windows Sunshine에 연결되지 않습니다. Knot의 **설정 상태 새로고침**은 IPv4 루프백 `127.0.0.1:47990`에 TCP 연결만 확인합니다. 포트 응답은 Sunshine의 신원·웹 로그인·암호화 설정·화면 전송 성공을 검증하지 않습니다. 설치 후 잠시 기다리거나 Windows 재시작 후 다시 확인하세요. 계속 열리지 않으면 **Windows 서비스 상태 직접 확인**에서 Sunshine 상태를 직접 확인할 수 있습니다. Knot은 서비스를 자동 시작하거나 인증서 검증을 해제하지 않습니다.

**PIN 승인 후 ‘화면 보안 연결을 확인하지 못해 중단’되면:** Windows의 Knot에서 **영상 암호화 설정 열기**를 누르고 **LAN Encryption Mode / WAN Encryption Mode → Required for all clients**(한국어: **LAN/WAN 암호화 모드 → 모든 사용자에게 필수**)를 둘 다 적용하고 **Save → Apply/재시작**까지 완료한 뒤 Mac에서 연결을 다시 시도하세요. LAN 기본값이나 Opportunistic은 Knot이 요구하는 화면·제어 암호화를 보장하지 않습니다. 이 설정을 바꿀 때 기존 PIN 페어링을 삭제하거나 Mac의 연결 인증 파일을 지울 필요는 없습니다.

화면 연결에는 JSON, SSH 키, 파일 계정 설정이 필요 없습니다. Windows 주소가 여러 개면 양쪽 기기에서 도달 가능한 Wi-Fi/Tailscale 주소를 선택하세요. 주소의 나열 순서는 연결 가능 여부를 보장하지 않습니다. 자동 검색과 Mac 주소 제안은 169.254 링크 로컬 주소를 제외합니다. 의도적으로 구성한 직접 연결에서 필요하면 고급 수동 주소 입력·설정 경로로 지정할 수 있습니다.

### PC가 목록에 없다면 QR / 링크

Windows 도우미의 **연결 QR / 링크 보기**를 엽니다. Mac에서 **QR 이미지 열기**로 저장된 PNG를 가져오거나 **카메라로 QR 스캔**을 선택합니다. 같은 모니터를 번갈아 쓴다면 QR 이미지를 Mac으로 전달하거나 **연결 링크 복사 → Mac 연결 링크 입력**을 사용하세요. 카메라는 스캔 창을 열었을 때만 사용하며 사진을 저장·전송하지 않습니다.

Mac의 확인 창에서 PC 이름과 LAN/Tailscale 주소를 고르면 기존 PC 확인·PIN 페어링으로 이어집니다. QR에는 PC 이름·주소만 있고 암호·개인 키·파일 접속 정보는 없습니다. 링크를 Mac에서 열어도 먼저 이 확인 창이 뜹니다. **주소 직접 입력**은 접힌 보조 경로로 남습니다.

자동 검색은 같은 로컬 네트워크의 Sunshine Bonjour 알림을 사용하며 Tailscale 너머의 PC를 자동 열거하지 않습니다. 게스트 Wi-Fi의 기기 격리나 mDNS 차단, 거부된 Mac 로컬 네트워크 권한, 중지된 Sunshine에서는 목록이 비어 있을 수 있습니다. 이때 QR/링크 경로를 사용하세요. 이 프리뷰의 검색/QR은 Sunshine 기본 포트를 전제로 합니다.

설치 없이 안내창만 바로 열고 싶다면 릴리스의 `…-windows-x64-quick-setup-preview.exe`를 일반 사용자로 실행할 수 있습니다. 이 고급 대체 경로는 시작 메뉴에 등록하지 않으므로 다시 설정하려면 원래 EXE를 여세요. 일반 화면은 사용자 전용 임시 폴더, 관리자 작업은 보호된 Program Files 아래의 임시 폴더를 사용하고 종료 시 자신이 만든 파일만 정리합니다.

## Windows에서 Mac 열기

1. **Mac:** Knot의 **이 Mac 공유**를 엽니다. **Sunshine DMG 받기**로 고정된 공식 설치 파일을 받고, DMG 안의 Sunshine을 Applications로 옮깁니다. 이 앱은 DMG의 크기·SHA256와 설치된 앱의 공식 서명·버전을 확인합니다. 기존 Sunshine의 설정이나 실행 중인 프로세스는 자동으로 가져오거나 바꾸지 않습니다.
2. 공유 범위 안내를 확인하고 사용할 LAN/Tailscale 주소를 선택한 뒤 **이 Mac 공유 시작**을 누릅니다. macOS의 화면 및 시스템 오디오 기록·손쉬운 사용 권한은 **실제 권한 요청에 표시된 앱**에 직접 승인하세요. Knot가 공유 프로세스를 시작하므로 Knot가 권한 대상이 될 수 있으며, Sunshine만 승인하면 충분하다고 가정하지 마세요. 시스템 설정에서 요청에 표시된 Knot 또는 Sunshine을 확인한 뒤 공유를 껐다가 다시 켭니다. 이 단계는 자동으로 승인할 수 없습니다.
3. **Sunshine 초기 설정 / PIN**에서 이 Mac의 `https://localhost:47990`을 열어 공유 시작 전에 앱에서 준비한 관리자 계정으로 로그인합니다. 최초 실행은 앱에 웹 관리자 이름과 16~128바이트 비밀번호를 입력하세요. 기존 계정은 유지하고 평문 비밀번호는 저장하지 않습니다. localhost 자체 서명 인증서 안내가 나타날 수 있습니다. 공유 시작 시 LAN/WAN 암호화 필수, UPnP 끄기, 로컬 전용 관리 UI를 강제합니다. 공유기 포트를 열지 마세요.
4. **QR 이미지 저장…** 또는 **연결 링크 저장…**으로 주소 안내를 만듭니다. Windows에 전달하거나 Windows에서 **같은 Wi-Fi에서 찾기**를 사용합니다. QR/검색만으로 인증되지는 않습니다. Tailscale 너머의 기기는 자동 열거하지 않습니다.
5. **Windows:** 같은 EXE에서 **Mac 열기**를 선택합니다. QR 이미지나 링크를 미리 보고 주소를 선택합니다. 최초 **화면 엔진 받기**는 공식 Moonlight Portable을 인터넷에서 받아 크기·SHA256·전체 파일을 확인하며 관리자 권한은 필요 없습니다.
6. **PIN으로 Mac 연결**을 누르고 Moonlight 창의 PIN을 Mac의 Sunshine PIN 화면에 입력합니다. 승인 후 **Mac 화면 열기**를 누릅니다. 실행 파일을 시작했다는 상태와 실제 영상 연결 성공은 구분하며, 실제 연결 오류·PIN 결과는 엔진 창에서도 확인하세요.

Mac은 사용자가 로그인한 Desktop을 대상으로 합니다. 공유를 끄거나 Knot를 정상 종료하면 이 앱이 시작한 호스트와 그 자식만 종료합니다. Sunshine 웹 UI의 Restart 대신 Knot의 공유 끄기/시작을 사용하세요. 강제 앱 종료·전원 손실 이후의 종료 보장은 하지 않습니다. Mac SSH/원격 로그인·자동 클립보드·파일 접근은 켜지지 않습니다. **역방향 파일 전송은 아직 지원하지 않습니다.** 아래 파일 설정은 기존 Mac→Windows 방향입니다.

기본은 Windows 단축키를 로컬에 남깁니다. 전체 화면에서 **Windows 키를 Mac Command로 보내기**를 선택하면 Windows 키가 Mac Command로 전달되며 Alt+Tab도 Mac으로 갈 수 있습니다. Ctrl은 Mac Control, Alt는 Option입니다. **Ctrl+Alt+Shift+K**로 시스템 키 전달을 켜고 끄고, **Ctrl+Alt+Shift+Q**로 화면 연결을 닫습니다. 전달을 끈 뒤 Windows의 Win+Ctrl+←/→를 사용할 수 있습니다. 다른 실행 중인 앱을 종료하겠다는 Moonlight 안내는 취소하세요. 이 앱은 원격 앱 종료 명령을 만들지 않습니다.

Moonlight는 전용 portable 프로필을 쓰며 기존 사용자 설정·인증서를 자동 가져오지 않습니다. LAN/Tailscale 주소마다 별도 PIN 승인이 필요할 수 있습니다. 선택한 Mac과 화면을 직접 교환하지만, unmodified 엔진은 호환성·게임패드·업데이트 유무를 upstream에 조회할 수 있습니다. 자동 설치 업데이트는 추가하지 않습니다. Sunshine의 Mac 지원은 실험 단계이며 실제 Windows 실행·Mac 권한·한글 입력·오디오·잠금·절전·모니터 전환·네트워크 품질은 기기 검증이 남아 있습니다.

## 화면 화질 선택 (preview.17 소스 빌드)

Mac의 **Windows 화면 / Linux 화면 → 화면 설정**에서 **4K (2160p)**, **60 fps**, 비트레이트 **자동** 또는 **10–100 Mbps**를 선택한 뒤 화면을 여세요. 자동은 1080p에서 20 Mbps, 1440p에서 30 Mbps, 4K에서 60 Mbps를 사용합니다. Windows에서 Mac/Linux를 여는 클라이언트도 **3840x2160**과 최대 **100 Mbps**를 선택할 수 있습니다. 연결 중에는 먼저 화면 연결을 끊고 변경하세요.

상대 PC의 화면·캡처·인코더가 해당 해상도를 지원해야 합니다. Knot은 호스트 화면 해상도나 가상 모니터를 자동 설정하지 않습니다. 높은 비트레이트에서 끊긴다면 값을 낮춰 다시 연결하세요. 실제 4K 화질·프레임·지연은 기기 검증이 필요하며, 공개 preview.16 설치 파일에는 이 설정이 없습니다.

## 파일 전송은 필요할 때 추가

1. Mac에서 연결할 Windows PC를 선택한 뒤 **파일 → Mac 주소 찾기**를 누릅니다. Windows에서 허용할 Mac의 LAN/Tailscale 주소만 남기고, **설정에 사용할 Mac 주소**를 선택합니다.
2. **자동 파일 설정 시작**을 누릅니다. 선택한 Mac 키가 없으면 전용 키를 한 번 만들고 기존 키는 유지합니다. 일회용 연결과 QR의 첫 인증은 2분 안에 완료해야 합니다. 인증 후에는 설치와 결과 전달을 위한 10분이 주어지며 연장되지 않습니다.
3. Windows Knot 도우미에서 **＋ 파일 전송도 설정하기 (선택)**을 펼치고 Mac에 표시된 연결을 붙여 넣은 뒤 **자동 파일 설정 · Mac 연결 받기**를 누릅니다. Windows가 Mac으로 보안 연결하므로 새 Windows 수신 포트나 별도 설정 서버는 만들지 않습니다.
4. Windows 주소, Mac 공개 키 지문과 허용 주소를 확인하고 관리자 요청을 승인합니다. 기존 제한된 설정 경로가 Windows OpenSSH, 전용 일반 계정, `C:\DeskBridgeShare\files`, 선택한 Mac IP 전용 방화벽을 준비합니다. 설치 직후에도 이 승인은 필요합니다. 화면 PIN만으로 파일 권한을 부여하지 않습니다.
5. 연결 결과가 Mac으로 자동 전달되면 **Windows 화면의 SSH 지문을 Mac 확인 창과 직접 비교**하고 등록합니다. 이후 **파일 연결**을 누르면 송수신을 사용할 수 있습니다. 개인 키와 암호는 전송하지 않습니다.

자동 설정 연결은 비밀 일회용 초대입니다. 신뢰하는 Windows에만 전달하고 공개 채팅·이슈·로그에 붙이지 마세요. 선택한 Mac 주소에서만 잠시 수신하며, 선택한 Windows 주소의 연결 하나를 받으면 새 접속을 닫습니다. 완료·취소·시간 만료·앱 종료 시 연결을 닫습니다. 같은 Wi-Fi의 공유기 격리나 Mac 방화벽이 수신을 막는다면 Tailscale 주소를 선택하거나 아래 수동 복구를 사용하세요. 방화벽을 끌 필요는 없습니다.

**수동 복구:** Mac의 **설정 파일로 복구 · 수동 교환**에서 설정 JSON을 저장해 Windows의 **Mac 설정 파일 불러오기**로 가져옵니다. Windows **파일 전송 설정 · 연결 파일 만들기** 후 연결 JSON을 Mac에 가져오고 같은 SSH 지문 비교를 진행합니다. 공개 JSON에는 개인 키가 없습니다. 자동 연결이 관리자 작업 도중 만료되면 Windows 설정이 이미 완료됐을 수 있습니다. 설정을 지우지 말고 새 자동 연결 또는 **이미 설정한 연결 파일 다시 저장**으로 결과를 다시 전달하세요.

자세한 동작과 보안 경계는 [자동 파일 설정](docs/FILE_ENROLLMENT.md)을 참고하세요.

## 프리뷰 서명 상태

현재 개발 프리뷰의 Mac 패키지는 ad-hoc 서명이며 Apple 공증이 없습니다. 정식 릴리스는 Developer ID 서명·공증을 완료해야 합니다. Gatekeeper나 조직 보안 정책을 끄는 설치법은 제공하지 않습니다.

Windows 설치·quick-setup EXE는 Authenticode 서명이 없는 프리뷰이므로 SmartScreen 경고가 나타날 수 있습니다. quick-setup EXE는 Mac에서도 교차 컴파일합니다. Windows 실행·UAC·설치 동작은 실제 Windows에서 검증해야 합니다. 네이티브 실행 파일이 내장 관리 도우미의 해시를 확인하고 제한된 환경에서 Windows 기본 .NET Framework와 PowerShell을 시작합니다. 사용자가 별도 개발 도구를 설치할 필요는 없습니다.

동봉 PowerShell 스크립트는 정확한 소스 바이트를 유지하며 Authenticode 서명이 없습니다. EXE/설치 프로그램에 서명해도 스크립트의 개별 서명이 생기지는 않습니다. 도우미는 해당 PowerShell 프로세스에만 RemoteSigned를 요청하며 영구 정책을 바꾸지 않습니다. 조직에서 AllSigned를 강제하면 별도로 서명한 스크립트나 조직에서 승인한 수동 배포가 필요합니다. 정책을 끄거나 우회하지 마세요. 로컬 portable ZIP과 Setup.cmd는 개발자 대체 경로입니다.

## 업데이트와 제거

Mac은 실행 중인 기존 앱을 종료하고 새 `Knot.app`을 응용 프로그램에 옮깁니다. 이전 이름의 `DeskBridge.app`은 앱 번들만 제거해 같은 번들 ID를 가진 두 앱이 나란히 남지 않게 하세요. Application Support·설정·인증서는 지우지 마세요. ad-hoc 서명에서는 macOS 권한을 다시 요청할 수 있습니다. [이름 변경과 호환성](docs/BRAND_COMPATIBILITY.md)을 확인하세요. 설정·키를 자동 삭제하지 않습니다. 제거는 앱을 휴지통으로 옮깁니다. 파일 접속 권한도 폐기하려면 Windows에서 해제하세요.

Mac 공유를 사용했다면 제거 전에 **공유 끄기**로 중지하고 Sunshine의 페어링 기기를 직접 해제하세요. 화면 기록·시스템 오디오·손쉬운 사용 권한도 실제 승인한 Knot 또는 Sunshine 항목에서 직접 해제할 수 있습니다. Sunshine 앱과 앱 전용 공유 구성은 자동 삭제하지 않습니다. Windows EXE를 삭제해도 전용 Moonlight 엔진·portable 프로필은 LocalAppData의 `DeskBridge-Reverse-v1` 아래에 남습니다. 삭제·재설치만으로 Mac 쪽 페어링 기기 권한이 폐기되었다고 간주하지 마세요.

quick-setup EXE는 새 파일로 교체합니다. EXE를 삭제해도 이미 설정한 Sunshine·파일 접속은 남습니다. 파일 권한을 없애려면 먼저 도우미의 **파일 접속 해제**를 누르세요. 별도 Inno 설치 프로그램으로 설치한 도우미는 새 설치 프로그램으로 교체하며, 제거 시 구성된 전용 SSH 접속 해제에 실패하면 제거를 중단합니다. Sunshine은 별도로 업데이트합니다. 공유 파일·Sunshine·호스트 키를 삭제하지 않습니다. [기존 전용 배포의 잔여 계정·자료 관리](host/windows/README.md)를 확인하세요.

이미 파일 접속을 해제한 뒤 전용 계정이나 OpenSSH를 따로 제거했다면, 도우미는 고정 SSH 설정·전용 방화벽 규칙이 없고 계정·서비스·세션이 모두 비활성인지 확인해 아무것도 변경하지 않고 제거를 계속할 수 있습니다. 상태를 확인하지 못하거나 설정·규칙·활성 세션이 남아 있으면 기존 엄격한 검증 또는 수동 확인이 필요합니다. 이 경로도 공유 파일과 보존한 설정 기록을 삭제하지 않습니다.

전체 설정 스크립트는 공개 소스에 포함됩니다. [공개 배포 빌드](docs/RELEASING.md)를 참고하세요.

이 버전으로 만든 전용 배포는 해제 후 **파일 전송 설정**을 다시 눌러 재활성화할 수 있습니다. 새 Mac 키·주소를 쓰려면 먼저 해제한 뒤 새 자동 설정 연결 또는 설정 JSON을 사용합니다. 보존한 계정 SID·폴더 ACL·설정 해시·서비스 경로를 확인한 후에만 복구합니다. 이전 프리뷰의 메타데이터 없는 배포나 수동으로 바꾼 SSH 설정은 자동 복구하지 않습니다.

Windows 빠른 설정은 OneDrive·동기화·연결 경로 밖의 로컬 폴더(예: Downloads)에서 실행하세요. 실행 파일 경로 보호를 위해 해당 경로는 거부합니다. 고급 소스 ZIP의 스크립트가 다운로드 보호로 차단됐다면 먼저 출처와 소스를 확인하고, 신뢰하는 ZIP에만 속성 → 차단 해제를 적용한 뒤 다시 압축을 푸세요. 조직의 서명·앱 실행 정책은 해제하지 마세요.

Windows에서 엔진 파일 확인이 계속 실패하면 Knot와 Moonlight 창을 모두 닫고, `%LOCALAPPDATA%\DeskBridge-Reverse-v1` 아래의 `engine-6.2.0` 폴더만 다른 이름으로 옮긴 뒤 **화면 엔진 받기**를 다시 누르세요. `profiles`의 페어링 상태는 보존하세요. 백신이 파일을 격리했다면 보안 정책을 먼저 확인하고 보호 기능을 끄지 마세요. 이 프리뷰는 손상된 엔진을 자동 삭제하지 않습니다. OneDrive/클라우드·링크 폴더의 EXE나 QR을 거부하면 일반 로컬 폴더로 옮겨 다시 실행하세요.

## Mac 연결 인증 파일 복구

연결 인증 파일이 없거나 손상되었다는 안내가 나오면 기존 파일과 앱 설정을 보존하세요. Mac 클라이언트의 인증서·개인 키·클라이언트 ID 세 파일을 **같은 원본 백업**에서 함께 복원해야 합니다. Windows 연결은 `~/Library/Application Support/DeskBridge/Glimmer/Identity`, Linux 연결은 `~/Library/Application Support/DeskBridgeLinux/Glimmer/Identity`를 사용합니다. 백업의 소유권과 개인 접근 권한도 유지하세요.

이 프리뷰에는 연결 인증 초기화·자동 복구 기능이 없습니다. 앱 재설치나 인증 폴더 삭제만으로 초기화되지 않으므로 추가로 파일이나 설정을 지우지 마세요. 원본 백업이 없다면 호스트 Sunshine에서 해당 Mac의 페어링 권한을 취소하고 프로젝트에 복구 지원을 요청하세요. 보고에는 앱·OS 버전과 표시된 오류 안내만 포함하고 개인 키·인증 파일·설정 전체를 첨부하지 마세요. 새 연결을 자동으로 만들거나 기존 권한을 대체하지 않습니다.

## Linux에서 공유하기 (프리뷰)

Ubuntu 24.04 LTS amd64의 로그인한 X11 데스크톱을 지원합니다. Linux용 `.deb`를 시스템 설치 프로그램으로 열고 앱 목록의 **Knot Linux Host**를 실행하세요. 앱에서 공식 Sunshine 받기 → 시스템 설치 → 최초 웹 관리자 계정 입력 → 이 Linux 공유 시작 → 웹 로그인 → QR 순서로 진행합니다. Mac은 **Linux 화면**, Windows는 **Linux 열기**를 선택하세요. 자세한 설치·방화벽·입력 권한·삭제 안내는 함께 제공한 `LINUX-INSTALLATION.md` 또는 소스의 `host/linux/README.md`를 확인하세요.

Wayland·로그인 화면·헤드리스·Linux 파일 전송·Linux 클라이언트는 아직 지원하지 않습니다. Linux 실제 GPU/입력/오디오와 네트워크 성능은 기기에서 검증해야 합니다. 기존 Mac→Windows 파일 기능과 Windows→Mac 화면 연결은 유지합니다.

## 모니터가 없는 Windows PC

Windows 도우미의 **모니터 없이 사용**에서 상태와 설정 안내를 확인할 수 있습니다. 외부 드라이버의 보안 검토가 끝날 때까지 가상 화면 자동 설치는 차단되어 있습니다. 현재는 모니터 또는 HDMI/DisplayPort 더미 플러그로 화면을 제공해야 합니다. 최초 설정에는 다른 접속 수단이 필요하며, 로그인·잠금 해제·절전 복귀는 지원 범위가 아닙니다. [상세 안내](docs/HEADLESS_WINDOWS.md).
