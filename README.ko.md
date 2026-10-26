<p align="center">
  <img src="Assets/Brand/knot.png" alt="Knot 로고" width="88">
</p>

# Knot

**컴퓨터를 잇다. 작업을 이어가다.**

Mac에서 Windows 화면을 전체 화면 Space로 열고, Windows에서 Mac을 제어하거나 Mac·Windows에서 Linux 데스크톱에 연결하는 무료 오픈소스 원격 업무 앱입니다. 같은 LAN/Wi-Fi 또는 이미 설정한 Tailscale을 사용합니다.

[English](README.md) · 한국어

> **개발 프리뷰**
>
> 실제 기기의 설치·화면·입력·오디오·연결 성능은 검증이 남아 있습니다. Mac 패키지는 ad-hoc 서명·미공증, Windows 실행 파일은 미서명 프리뷰입니다. 다른 원격 데스크톱보다 빠르거나 안전하다는 비교 결과는 없습니다.

[설치 안내](INSTALLATION.md) · [보안 범위](SECURITY.md) · [빌드·패키징](docs/RELEASING.md) · [검증 항목](docs/VALIDATION.md)

현재 소스는 **0.2.0-preview.25**입니다. 아래의 공개 preview.16 설치 파일에는 새 첫 설정·고화질·업데이트 기능이 포함되지 않습니다. 배포용 키·피드·플랫폼 서명을 구성하기 전에는 자동 업데이트를 사용할 수 없습니다. [업데이트 구성과 제한](docs/UPDATES.md)을 확인하세요.

## 지원하는 연결

화살표 왼쪽은 조작하는 컴퓨터, 오른쪽은 화면을 공유하는 컴퓨터입니다.

| 연결 방향 | 화면·키보드·마우스·오디오 | 파일 보내기·받기 |
| --- | --- | --- |
| Mac → Windows 11 x64 (Home 포함) | 프리뷰 | 프리뷰 · 별도 SFTP 설정 |
| Windows 11 x64 → Mac | 프리뷰 · Mac 호스트는 실험 지원 | 미지원 |
| Mac 또는 Windows 11 x64 → Ubuntu 24.04 LTS amd64 | 프리뷰 · 로그인한 X11 세션 | 미지원 |

- **Mac 앱:** Apple Silicon, macOS 26 이상.
- **Linux:** 호스트 기능만 제공합니다. Linux 클라이언트, Wayland, 헤드리스, 로그인 전 화면은 지원하지 않습니다.
- 로그인·잠금 해제·절전 복귀·가상 모니터는 보장하지 않습니다. 공유할 컴퓨터에 사용자가 로그인해 있어야 합니다.

Windows 도우미에 **모니터 없이 사용** 설정 창을 추가했습니다. 외부 드라이버의 보안 검토가 끝날 때까지 자동 설치를 차단했으므로 아직 바로 사용할 수 있는 헤드리스 기능은 아닙니다. [현재 상태와 설정 안내](docs/HEADLESS_WINDOWS.md)를 확인하세요.

## 주요 기능

- **Mac 전체 화면 Space:** 원격 화면을 열고 macOS 작업 공간을 오갑니다. 기본 설정은 Control+↑/←/→를 Mac에서 처리합니다.
- **검색·QR·연결 링크:** 같은 LAN의 Bonjour 검색이나 주소 QR·링크로 PC를 선택합니다. Mac은 QR 이미지·카메라 스캔·링크 입력, Windows 클라이언트는 QR 이미지와 링크를 지원합니다.
- **명시적 페어링:** QR과 검색 결과는 주소 안내입니다. PIN 승인과 저장된 인증서 확인을 통해 연결합니다.
- **화질 선택:** 소스 빌드는 최대 4K (3840×2160)·60 fps·100 Mbps를 선택할 수 있습니다. Mac의 자동 비트레이트는 1080p/1440p/4K에서 각각 20/30/60 Mbps입니다. 연결 전에 선택하며 높은 비트레이트는 더 많은 대역폭이 필요합니다. 4K는 상대 PC의 화면·캡처·인코더 지원이 필요하고 호스트 화면 해상도는 자동 변경하지 않습니다.
- **선택적 파일 전송:** Mac 클라이언트에서 Windows 공유 폴더를 조회하고 개별 파일을 보내고 받습니다. 진행률과 취소를 제공하며 기존 파일은 덮어쓰지 않습니다.
- **네이티브 앱:** Mac은 SwiftUI/AppKit, Windows는 WinForms, Linux 호스트는 GTK를 사용합니다. Windows 화면 엔진은 별도의 Moonlight 창에서 실행됩니다.

Knot 자체의 클라우드 계정이나 중계 서버는 없습니다. Tailscale은 양쪽 기기에 별도로 준비해야 하며, [Tailscale의 연결 경로](https://tailscale.com/docs/reference/connection-types)에 따라 DERP 중계를 거칠 수 있습니다. Bonjour 검색은 Tailscale 너머의 PC를 자동 열거하지 않으므로 QR·링크 또는 주소를 사용하세요.

## 설치 파일과 시작하기

**0.2.0-preview.16** 설치 파일을 [GitHub Releases](https://github.com/ictechgy/Knot/releases/tag/v0.2.0-preview.16)에서 받으세요.

| 컴퓨터 | 다운로드 | 요구 사항 |
| --- | --- | --- |
| Mac | [DMG](https://github.com/ictechgy/Knot/releases/download/v0.2.0-preview.16/Knot-0.2.0-preview.16-macos-arm64-preview.dmg) | Apple Silicon, macOS 26 이상 |
| Windows | [설치 EXE](https://github.com/ictechgy/Knot/releases/download/v0.2.0-preview.16/Knot-0.2.0-preview.16-windows-x64-setup.exe) | Windows 11 x64, Home 포함 |
| Linux 호스트 | [DEB](https://github.com/ictechgy/Knot/releases/download/v0.2.0-preview.16/Knot-0.2.0-preview.16-ubuntu24.04-amd64-preview.deb) | Ubuntu 24.04 LTS amd64, 로그인한 X11 데스크톱 |

Mac은 DMG를 열고 **Knot.app**을 **Applications**로 옮깁니다. Windows는 설치 EXE를 일반 실행해 설치 과정의 UAC 요청을 승인한 뒤 시작 메뉴의 **Knot 설정**을 여세요. 시작 메뉴와 제거 기능을 제공하며, 설치 후 도우미는 원래 사용자 권한으로 열립니다. 설치 없이 안내창만 바로 여는 quick-setup EXE도 고급 대체 경로로 릴리스에 포함합니다.

릴리스에 [SHA256SUMS](https://github.com/ictechgy/Knot/releases/download/v0.2.0-preview.16/SHA256SUMS), 대응 소스와 라이선스 고지를 함께 제공합니다. Mac은 ad-hoc 서명·미공증, Windows는 미서명인 개발 패키지입니다. CI 검사는 통과했지만 실제 기기 설치·원격 세션 검증은 남아 있습니다. 이 배포 프리뷰의 가상 화면 자동 설치는 드라이버 안전성 검토로 비활성화되어 있어 무모니터 동작을 전제로 사용하면 안 됩니다. 빌드와 서명은 [패키징 안내](docs/RELEASING.md)를 확인하세요.

다음 순서로 연결합니다. **화면 연결에는 SSH 설정이 필요 없습니다.**

### Mac에서 Windows 열기

**최신 소스 빌드:** Windows에서 **Knot**을 열면 연결 준비가 시작됩니다. 필요한 Sunshine 구성요소 설치·실행, 첫 계정 생성과 보안 설정은 Knot이 진행합니다. 기존 Sunshine 계정만 처음 한 번 로그인하며 Windows DPAPI와 관리자 전용 권한으로 기억합니다. 요청 목록은 자동 갱신되므로 Mac 요청을 선택하고 PIN을 승인하세요. 실행 중 업데이트는 Knot을 정상 종료하고 새 버전으로 이어지며, 기존 페어링·공유 파일은 유지합니다. 화면 연결은 자동 종료하고 설정 작업은 완료를 기다립니다. 제한 시간 안에 끝나지 않으면 설치를 중단합니다. 아래 공개 preview.16 패키지는 이전 수동 흐름입니다.

1. Windows 설치 EXE로 설치하고 시작 메뉴의 **Knot 설정**을 열어 **이 Windows 공유**를 선택합니다. 안내에 따라 Sunshine을 설치합니다.
2. **Windows 브라우저**에서 `https://localhost:47990`을 열어 Sunshine 관리자 계정을 만듭니다. **Configuration → Network**의 LAN/WAN 암호화 모드를 모두 **모든 사용자에게 필수**(Required for all clients)로 선택하고 **Save → Apply**를 누른 뒤 Desktop 앱이 있는지 확인합니다.
3. Mac에 Knot를 설치하고 **Windows 화면**에서 PC를 선택합니다. 목록에 없으면 Windows 도우미의 QR·연결 링크를 가져옵니다.
4. Windows에서 `https://localhost:47990/pin`을 열어 Mac에 표시된 PIN을 승인한 뒤 **Windows 열기**를 누릅니다. Sunshine은 일반 앱 창 없이 백그라운드에서 실행될 수 있습니다.

[자세한 설치 순서](INSTALLATION.md#mac에서-windows-열기) · [Windows 호스트·파일 설정](host/windows/README.md)

### Windows에서 Mac 열기

Mac의 **이 Mac 공유**에서 공식 Sunshine을 준비하고, 최초 웹 관리자 계정을 입력한 뒤 공유를 시작합니다. 실제 macOS 권한 요청에 표시된 앱의 화면 및 시스템 오디오 기록·손쉬운 사용 권한을 승인합니다. Windows EXE에서는 **Mac 열기**를 선택해 QR·링크·검색으로 주소를 고릅니다. Windows Moonlight 창에 표시된 PIN을 Mac의 Sunshine PIN 페이지에서 승인합니다.

[Mac 공유 안내](host/macos/README.md) · [Windows 클라이언트 안내](client/windows/README.ko.md)

### Linux 화면 열기

Ubuntu에서 Linux용 `.deb`를 설치하고 **Knot Linux Host**를 엽니다. 공식 Sunshine 설치 → 최초 웹 관리자 계정 입력 → 공유 시작 순서로 준비합니다. Mac의 **Linux 화면** 또는 Windows의 **Linux 열기**에서 주소를 선택하고 PIN 연결을 시작하세요. 클라이언트에 표시된 PIN을 Linux의 Sunshine PIN 페이지에서 승인합니다.

[Ubuntu 설치·권한·방화벽 안내](host/linux/README.md)

## 파일 전송은 별도로 설정합니다

파일 클라이언트는 Mac에만 있습니다. Mac에서 Windows 공유 폴더에 접근하는 OpenSSH/SFTP 연결은 Sunshine 화면 연결과 별개입니다. Windows의 전용 일반 사용자·공유 폴더와 Mac의 SSH 키를 준비하고, Windows에서 확인한 SSH 호스트 키를 Mac에 등록합니다. 화면 페어링만으로 파일 접근 권한이 생기지 않습니다.

소스 빌드는 일회용 설정 링크·QR로 공개 설정 정보를 자동 교환합니다. Windows의 사용자 승인·UAC 후 제한된 계정과 공유 폴더를 준비하며, Mac에서 Windows 화면의 SSH 지문과 비교한 뒤 저장합니다. 개인 키는 전송하지 않고, JSON 내보내기·가져오기는 복구 경로로 유지합니다. 교환용 수신기는 완료·취소·시간 초과 시 닫힙니다.

폴더 재귀 전송, 이어받기, 자동 동기화, 원격 삭제는 지원하지 않습니다. 새로 생성하는 Mac 전용 개인 키는 암호 없는 사용자 전용 파일이므로 해당 Mac 계정과 디스크를 보호해야 합니다. [상세 설정과 제한](host/windows/README.md)을 먼저 확인하세요.

**최신 소스 빌드 업데이트:** Mac DMG 안에서 **Install Knot.app → 설치 및 다시 시작**, Windows에서는 새 설치 EXE를 일반 실행하세요. 직접 앱을 종료하지 않아도 정상 종료·교체·재실행을 진행합니다. 화면 연결은 잠시 끊기고 새 앱은 파일 전송·설정 완료를 기다립니다. preview.22 이하에서 처음 올릴 때는 파일·설정 작업을 먼저 마쳐 주세요. Mac의 설치 위치를 변경할 권한이 없으면 종료 전에 중단하며 관리자가 교체해야 합니다.

온라인 자동 업데이트는 서명된 배포 파일과 배포자 구성을 요구하며, 현재 배포 피드는 구성되지 않았습니다. 페어링과 SSH 설정을 보존하며 인증서가 바뀌면 직접 확인해야 합니다. 새 버전 실행 후 짧은 유효기간의 일회용 기록으로 기존 PC를 다시 확인할 수 있지만, PIN 재페어링이나 파일 전송 이어받기는 자동으로 하지 않습니다. Windows quick-setup은 설치 버전으로 전환해야 자동 업데이트를 사용할 수 있습니다. [업데이트 구성과 제한](docs/UPDATES.md)을 확인하세요.

## 보안과 네트워크

- 선택한 사설 IPv4 주소를 사용합니다. 공개 IP·DNS 호스트 이름·IPv6 연결은 지원하지 않습니다.
- 화면 전송 암호화는 필수입니다. Mac 클라이언트는 호스트 인증서를 고정하며, Windows 클라이언트는 별도 Moonlight 프로필에서 페어링과 인증서를 관리합니다. 두 클라이언트의 보안 강화 범위는 같지 않습니다.
- Mac·Linux 공유는 포트를 열기 전에 전용 웹 관리자 계정을 준비합니다. 기존 유효한 계정·인증서를 자동으로 초기화하지 않습니다.
- 화면 공유는 로그인한 계정의 원격 제어 권한을 줍니다. SFTP 공유 폴더의 제한은 화면 공유에 적용되지 않습니다.
- 방화벽·라우터를 자동 설정하지 않습니다. 신뢰하는 LAN/Tailscale에서 사용하고 인터넷 포트 포워딩을 설정하지 마세요.

Sunshine과 Windows용 Moonlight는 최초 사용자 요청 시 공식 배포처에서 별도로 받으며, 고정 크기·해시를 확인합니다. 최초 다운로드에는 인터넷 연결이 필요합니다. 수정하지 않은 Moonlight가 호환성·게임패드 목록·업데이트 정보를 조회할 수도 있습니다. 자동 클립보드 동기화는 추가하지 않습니다. 프로토콜의 한계와 기기별 검증 범위는 [SECURITY.md](SECURITY.md)에 정리합니다.

## 소스에서 빌드하기

### Mac

검증한 빌드 환경은 Apple Silicon Mac, macOS 26 이상, Xcode 27 / Swift 6.4와 Python 3입니다. 엔진 소스는 저장소의 `Vendor`에 포함됩니다.

```sh
python3 scripts/build.py
```

최적화 빌드와 오프라인 합성 검사를 수행하고 `dist/Knot.app`을 만듭니다. 실제 원격 화면이나 앱 GUI를 자동으로 열지 않습니다.

### Linux 호스트

```sh
python3 scripts/build_linux_host.py --output build/linux/Knot-Linux.deb
```

패키지는 Ubuntu 24.04 LTS amd64용입니다. 설치 의존성과 Linux 전용 검사 방법은 [Linux 안내](host/linux/README.md), [워크플로](.github/workflows/packages.yml)를 확인하세요.

Windows 빌드에는 별도 네이티브 컴파일러와 .NET 도구가 필요합니다. [빌드·서명·대응 소스 안내](docs/RELEASING.md)에 로컬 빌드와 CI 경로를 정리합니다.

Knot은 기존 DeskBridge의 새 이름입니다. 저장된 페어링과 설정 식별자는 유지하며, [업데이트·호환성 안내](docs/BRAND_COMPATIBILITY.md)를 확인하세요.

## 참여와 라이선스

버그 제보에는 OS·앱 버전·연결 방향·재현 순서를 적어 주세요. PIN, 비밀번호, 개인 키, 실제 파일·화면, 원본 서비스 로그는 공개 이슈에 올리지 마세요. 민감한 보안 문제는 [보안 안내](SECURITY.md)를 먼저 확인하세요.

Knot는 **GPL-3.0-only**입니다. 실행 파일을 배포할 때는 GPL 조건과 원본 고지를 유지하고 대응 소스를 제공해야 합니다.

Mac 엔진은 [Glimmer](https://github.com/Se7enbrc/glimmer)를 기반으로 하며, Sunshine과 Windows용 Moonlight는 별도 공식 패키지를 사용합니다. [라이선스](LICENSE) · [Glimmer 기여자](Vendor/Glimmer/CREDITS.md) · [upstream 변경](docs/UPSTREAM_CHANGES.md) · [QR 디코더·고지](Vendor/ZXingNet/README.md)
