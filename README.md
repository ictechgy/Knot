<p align="center">
  <img src="Assets/Brand/knot.png" alt="Knot logo" width="88">
</p>

# Knot

**Your computers, tied together.**

A free, open-source remote desktop app for work: open Windows in a full-screen Space on your Mac, control a Mac from Windows, or connect to a Linux desktop from Mac or Windows. Use your LAN/Wi-Fi or an existing Tailscale connection.

English · [한국어](README.ko.md)

> **Development preview**
>
> Real-device installation, video, input, audio and connection performance still need validation. Mac packages are ad-hoc signed and not notarized; Windows executables are unsigned previews. No performance or security advantage over other remote desktop products has been established.

[Installation](INSTALLATION.md) · [Security scope](SECURITY.md) · [Build and packaging](docs/RELEASING.md) · [Validation checklist](docs/VALIDATION.md)

The app UI and most setup guides are currently in Korean.

The source tree is **0.2.0-preview.19**. Its first-run enrollment, higher-quality streaming and signed updater changes are not included in the published preview.16 packages below. Automatic updates remain unavailable until the release publisher's keys, feed and platform signing are configured; see [updates](docs/UPDATES.md).

## Supported connections

In each row, the computer on the left controls the computer on the right.

| Connection | Video, keyboard, mouse and audio | File upload and download |
| --- | --- | --- |
| Mac → Windows 11 x64, including Home edition | Preview | Preview; separate SFTP setup |
| Windows 11 x64 → Mac | Preview; experimental Mac host support | Not supported |
| Mac or Windows 11 x64 → Ubuntu 24.04 LTS amd64 | Preview; logged-in X11 session | Not supported |

- **Mac app:** Apple Silicon, macOS 26 or later.
- **Linux:** host only. No Linux client, Wayland, headless or pre-login desktop support.
- Signing in, unlocking, waking from sleep and using virtual monitors are not guaranteed. The user must be logged in on the shared computer.

Windows has an optional **모니터 없이 사용** (use without a monitor) setup panel. Automatic virtual-display installation is currently blocked pending the third-party driver security review; it is not a ready-to-use headless feature. See [Windows headless status and setup](docs/HEADLESS_WINDOWS.md).

## Features

- **Full-screen Mac Spaces:** open a remote desktop and switch between macOS workspaces. Control+↑/←/→ stays local by default.
- **Discovery, QR and links:** choose a PC through Bonjour on your LAN or import an address QR/link. The Mac app supports QR images, camera scanning and links; the Windows client supports QR images and links.
- **Explicit pairing:** discovery results and QR codes are only address hints. PIN approval and saved certificate checks establish the connection.
- **Screen quality:** source builds offer up to 4K (3840×2160), 60 fps and 100 Mbps. Mac automatic bitrate uses 20/30/60 Mbps at 1080p/1440p/4K. Select quality before opening a stream; higher bitrate needs more bandwidth, and 4K requires host display/capture/encoder support. Knot does not automatically change the host display resolution.
- **Optional file transfer:** from the Mac client, browse the Windows share and upload or download individual files with progress and cancellation. Existing files are never overwritten.
- **Native apps:** SwiftUI/AppKit on Mac, WinForms on Windows and GTK for the Linux host. The Windows screen engine runs in a separate Moonlight window.

Knot operates no cloud account or relay service. Set up Tailscale separately on both devices; traffic may pass through [Tailscale DERP relays](https://tailscale.com/docs/reference/connection-types), depending on the connection path. Bonjour does not enumerate peers across Tailscale, so use a QR code, link or address there.

## Packages and getting started

Download **0.2.0-preview.16** from [GitHub Releases](https://github.com/ictechgy/Knot/releases/tag/v0.2.0-preview.16):

| Computer | Download | Requirements |
| --- | --- | --- |
| Mac | [DMG](https://github.com/ictechgy/Knot/releases/download/v0.2.0-preview.16/Knot-0.2.0-preview.16-macos-arm64-preview.dmg) | Apple Silicon, macOS 26 or later |
| Windows | [Setup EXE](https://github.com/ictechgy/Knot/releases/download/v0.2.0-preview.16/Knot-0.2.0-preview.16-windows-x64-setup.exe) | Windows 11 x64, including Home |
| Linux host | [DEB](https://github.com/ictechgy/Knot/releases/download/v0.2.0-preview.16/Knot-0.2.0-preview.16-ubuntu24.04-amd64-preview.deb) | Ubuntu 24.04 LTS amd64, logged-in X11 desktop |

Open the Mac DMG and drag **Knot.app** to **Applications**. On Windows, run the setup EXE normally, approve the installer's UAC request, then open **Knot 설정** from the Start menu. It includes an uninstaller and opens the helper as the original user after installation. The release also offers a quick-setup EXE for advanced users who prefer to open the helper without installing it.

The release includes [SHA256SUMS](https://github.com/ictechgy/Knot/releases/download/v0.2.0-preview.16/SHA256SUMS), matching source and license notices. These are development packages: Mac is ad-hoc signed and not notarized; Windows is unsigned. CI checks passed, but real-device installation and remote sessions still need validation. In this packaged preview, automatic virtual-display installation is disabled pending driver safety review; do not rely on monitorless operation. See the [packaging guide](docs/RELEASING.md) for builds and signing.

Follow the steps below to connect. **Screen access does not require SSH setup.**

### Open Windows from Mac

**New source-build Windows setup:** choose **연결 준비 · 자동 설정** (prepare connection). It chains the pinned Sunshine installation when needed with a native account/security/PIN dialog, so you do not have to find encryption settings in a browser. Initial UAC and account entry, then selecting the Mac request and entering its PIN, remain explicit. Existing pairing is retained; unsupported versions/layouts use **고급·수동 설정** (advanced/manual setup). This flow is not in the published preview.16 packages.

1. Install the Windows setup EXE, open **Knot 설정** from the Start menu and choose **이 Windows 공유** (share this Windows PC). Follow the Sunshine installation steps.
2. In a **Windows browser**, open `https://localhost:47990` and create the Sunshine administrator account. Open **Configuration → Network** and set both LAN and WAN encryption modes to **Required for all clients** (**모든 사용자에게 필수** in Korean), then **Save → Apply**. Check that a Desktop app is available.
3. Install Knot on your Mac. Choose the PC under **Windows 화면** (Windows desktop), or import the Windows helper's QR/link if discovery finds nothing.
4. On Windows, open `https://localhost:47990/pin` and approve the PIN shown on the Mac, then choose **Windows 열기** (open Windows). Sunshine can run in the background without a normal app window.

[Detailed installation](INSTALLATION.md#mac에서-windows-열기) · [Windows host and file setup](host/windows/README.md)

### Open Mac from Windows

Use **이 Mac 공유** (share this Mac) to prepare the official Sunshine app, enter the initial web administrator credentials, and start sharing. Grant Screen & System Audio Recording and Accessibility to the application named in the actual macOS permission request. On Windows, choose **Mac 열기** (open Mac) and select an address through QR/link/discovery. Approve the PIN shown in the Windows Moonlight window on the Mac Sunshine PIN page.

[Mac sharing guide](host/macos/README.md) · [Windows client guide](client/windows/README.ko.md)

### Open Linux from Mac or Windows

Install the Linux `.deb` on Ubuntu and open **Knot Linux Host**. Install official Sunshine, enter the initial web administrator credentials and start sharing. Select an address and start PIN pairing through **Linux 화면** (Linux desktop) on Mac or **Linux 열기** (open Linux) on Windows. Approve the client's PIN on the Linux Sunshine PIN page.

[Ubuntu installation, permissions and firewall](host/linux/README.md)

## File transfer uses a separate connection

The file client is available only on Mac. It accesses the Windows share over OpenSSH/SFTP independently of Sunshine. Set up the dedicated standard Windows user and shared folder, select an SSH key on the Mac, and register the Windows SSH host key. Screen pairing grants no file-transfer access.

Source builds offer a guided one-use setup link/QR to transfer public setup data automatically. Windows asks for local approval and UAC before provisioning its restricted account and share. Compare the SSH fingerprint on both computers before saving the result on Mac. No private key is transferred; JSON export/import remains available for recovery. The listener closes on completion, cancellation or timeout.

Recursive folders, resume, automatic synchronization and remote deletion are not supported. Newly generated dedicated Mac keys are unencrypted owner-only files; protect the Mac account and disk. Read the [file setup and limitations](host/windows/README.md) first.

## Security and networking

- Connections use selected private IPv4 addresses. Public IPs, DNS hostnames and IPv6 are not supported.
- Screen encryption is mandatory. The Mac client pins the host certificate; the Windows client manages pairing and certificates in a dedicated Moonlight profile. The two clients are hardened differently.
- Mac and Linux set up the Sunshine web administrator credentials you enter before opening the host service. Valid existing accounts and certificates are not automatically reset.
- Screen sharing grants remote control of the logged-in account. SFTP folder restrictions do not constrain desktop access.
- Knot does not automatically configure your firewall or router. Use a trusted LAN/Tailscale network and do not forward these ports to the internet.

Official Sunshine and Windows Moonlight packages are downloaded separately on explicit user action, with pinned size/hash checks. The initial download requires internet access. Unmodified Moonlight may also request compatibility, controller and update information. Knot adds no automatic clipboard synchronization. See [SECURITY.md](SECURITY.md) for protocol limits and validation scope.

The native application updater uses pinned Sparkle/WinSparkle runtimes and requires signed update artifacts. It waits for screen, files, enrollment and sharing work to finish. Updates preserve pairing and SSH settings; changed host certificates still require explicit recovery. A short-lived, one-use receipt can reverify an existing PC after a newer build starts, without automatic PIN pairing or transfer resume. Portable Windows quick-setup builds require an installed version for automatic updates. See [publisher setup and limitations](docs/UPDATES.md).

## Build from source

### Mac

The validated toolchain is an Apple Silicon Mac with macOS 26 or later, Xcode 27 / Swift 6.4 and Python 3. Engine sources are vendored in this repository.

```sh
python3 scripts/build.py
```

This performs an optimized build and offline synthetic checks, producing `dist/Knot.app`. It does not automatically open the app GUI or a real remote desktop.

### Linux host

```sh
python3 scripts/build_linux_host.py --output build/linux/Knot-Linux.deb
```

The package targets Ubuntu 24.04 LTS amd64. See the [Linux guide](host/linux/README.md) and [workflow](.github/workflows/packages.yml) for dependencies and Linux-only checks.

Windows builds require a separate native compiler and .NET tools. The [packaging guide](docs/RELEASING.md) covers local builds, CI, signing and corresponding source.

Knot was previously named DeskBridge. Existing pairing and setup identifiers are retained; see [upgrade and compatibility notes](docs/BRAND_COMPATIBILITY.md).

## Contribute and license

For bugs, include your OS, app version, connection direction and reproduction steps. Do not post PINs, passwords, private keys, real files/desktops or raw service logs in public issues. Read the [security guidance](SECURITY.md) before reporting sensitive issues.

Knot is **GPL-3.0-only**. Modifications and redistribution must preserve the applicable GPL terms and upstream notices and provide corresponding source for distributed executables.

The Mac engine builds on [Glimmer](https://github.com/Se7enbrc/glimmer); Sunshine and Windows Moonlight are separate official packages. [License](LICENSE) · [Glimmer credits](Vendor/Glimmer/CREDITS.md) · [Upstream changes](docs/UPSTREAM_CHANGES.md) · [QR decoder and notices](Vendor/ZXingNet/README.md)
