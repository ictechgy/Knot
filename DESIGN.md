# Design

## Source of truth
- Status: Active
- Last refreshed: 2026-10-25
- Primary product surfaces: native macOS host connection, fullscreen desktop, SFTP file browser, Mac sharing setup, Windows sharing/client role chooser, drag-to-Applications Mac package.
- Evidence reviewed: conversation requirements; pinned GlimmerEngine source; .omx/plans/deskbridge-v0.1.md; user-approved Concept A (Quiet Sidebar), selected 2026-10-19.
- Approved visual references: ../design-concepts/previews/a-{desktop,files,setup}-window.png in the local deliverable; immutable copies under .omx/artifacts/visual-ralph/quiet-sidebar. Reproduce native synthetic snapshots with scripts/render_visual_fixture.py. No Local Media UI or existing user settings inspected.

## Brand
- Product name: **Knot**, selected by the user on 2026-10-22. Use this English spelling in both language interfaces.
- Tagline: **Your computers, tied together.** / **컴퓨터를 잇다. 작업을 이어가다.**
- Personality: calm, practical work tool.
- Trust signals: explicit pairing, independent SSH host key, truthful connection/error status.
- Avoid: gaming jargon, fake performance/security badges, gradients/decorative dashboards.

## Product goals
- Goals: Windows as one normal fullscreen Mac Space; Windows opening a logged-in Mac desktop; keyboard-first work; direct encrypted connection; explicit both-way files in the existing Mac-to-Windows file workflow.
- Non-goals: cloud broker, account signup, games/controllers, automatic clipboard sync, telemetry.
- First-run goals: explicit Windows installation/readiness/PIN stages; automatic public file-setup exchange after local approval; signed application updates that preserve pairing and file credentials.
- Success signals: connect → pair → select Desktop → fullscreen; connect files → browse → send/receive with progress.

## Personas and jobs
- Primary persona: Korean-speaking developer using Mac + Windows11 Home on one monitor.
- Jobs: switch OS context with Mission Control; use editor/terminal; transfer chosen files.
- Context: private Wi-Fi or existing Tailscale, first host setup required.

## Information architecture
- Primary navigation: Mac sidebar Windows desktop / Linux desktop / Files / Share this Mac / Setup. Windows explicitly chooses sharing Windows, opening Mac, or opening Linux.
- Core screens: host address and PIN pairing; paired application list; file credentials/browser/transfers; honest setup instructions.
- Hierarchy: branded sidebar and saved-PC footer; page heading; host card with Windows 열기; grouped screen settings; collapsed connection details. Files use a path/action toolbar, full-width remote list and a separate SSH disclosure. Setup uses three numbered panels.

## Design principles
- Native macOS behavior: real fullscreen Space and native controls.
- Explicit trust: never silently accept changed certificates or SSH host keys.
- Low friction after setup: office defaults, no global shortcut hijacking.
- Tradeoff: Windows setup helper wraps maintained OpenSSH with explicit UAC consent; existing SSH deployments still require manual integration.

## Visual language
- Color: macOS semantic system backgrounds/text, accent blue.
- Typography: system font, monospaced PIN/path/fingerprint only.
- Spacing: 8/12/16/24pt rhythm with 24–30pt page insets; sidebar min180/ideal220/max260pt, min window 880x620, default1200x760.
- Shape/elevation: 10pt grouped-panel corners, thin semantic separator, native controls and confirmation sheets. No decorative shadows.
- Motion: system transitions, respect reduced motion.
- Iconography: SF Symbols for controls; the repo-owned Knot mark in Assets/Brand for app identity. No remote icon service.

## Components
- Reuse: NavigationSplitView, Form, List, TextField, secure file pickers, buttons, progress indicators.
- Native components: QuietStyle semantic colors/radius, QuietPageHeader, QuietBadge (text plus symbol), QuietHelp, StatusPanel. DesktopPage, FilesPage and SetupPage own their screen-specific layouts; navigation and entrypoint are separate files.
- Desktop: one primary Windows 열기 action when a verified Desktop exists. Other Sunshine apps remain selectable; multiple apps without Desktop require an explicit choice. First run accepts an address and checks the PC before PIN pairing; a stored certificate alone is not a live connection or readiness claim.
- Connection entry: first-run production launch searches Bonjour `_nvstream._tcp` / `_nvstream-tcp._tcp` on the local network for 10 seconds. Show discovered PC names/addresses as unverified candidates with explicit PC 확인. DNS-SD resolves metadata only, with at most16 service objects,32 rows and8 IPv4 hints per service; it never scans subnets or opens host TCP probes. New model/visual fixtures never start discovery. Saved-PC address changes remain behind connection details and preserve its certificate pin.
- QR/link entry: Windows creates an offline, address-only connection QR and copyable `deskbridge://connect` link. Mac offers a QR image picker, explicit camera scan, link input and a registered deep link. A preview names the PC and lets the user choose LAN/Tailscale address before the existing verification/PIN flow. Screen/files busy states reject target changes at model level. No QR credential, auto-pairing, SSH setup, trust reset or external QR service is added. Manual address entry stays in a disclosure.
- Camera starts only after the user opens the scan sheet and grants permission. It adds video input only, retains no pictures, and stops when the sheet closes. One physical monitor can use the QR-image or link route. Imported images are capped at8MB/16 megapixels and ambiguous/malformed codes are rejected.
- Files: native selectable remote list with name/size (no invented dates), explicit individual-file send/receive, native OS pickers and progress. SSH credentials and setup exchange stay behind disclosures; edits lock during file connections/operations.
- Installation: Mac DMG with Applications shortcut; non-elevated Windows setup window. Explicit installation, native Sunshine quick setup and SFTP changes may request UAC. Sunshine downloads require pinned size/SHA256 validation. Keep shared files during uninstall.
- Windows onboarding: one primary **연결 준비 · 자동 설정** action checks for the standard installation, downloads/installs only when absent, and opens native account/security/PIN setup. Files and advanced/manual settings are collapsed. Account creation/login and selecting the pending Mac request remain explicit. A completed installer, file-presence hint or TCP response never establishes identity, secure readiness or a working stream. Existing/custom installations are never silently upgraded or adopted; unsupported layouts/versions retain the manual browser path.
- Keep Windows progress and the SSH host fingerprint in a fixed footer outside the scrolling instructions, including when optional files are expanded. Manual script files stay behind the advanced Mac disclosure and are labeled as manual setup.
- Quick setup extracts an explicit hashed payload into a fresh protected user-only temporary directory and keeps it until the GUI exits; no persistent launcher install or automatic login is added. The separate Inno installer handles shortcuts/removal. Both preserve original non-elevated user identity and existing SSH policies.
- The distributed Windows EXE begins with a native bootstrap before CLR startup. It validates its embedded managed helper, uses a restricted environment and fixed stage, and preserves the original EXE as the sole primary UAC broker. Administrator work uses a protected Program Files stage; source-folder manual scripts remain explicitly labeled. Do not imply EXE signing individually signs the unchanged PowerShell scripts; AllSigned needs an approved separately signed workflow.
- Automatic Mac address suggestions omit link-local APIPA, deduplicate and cap at eight; manual link-local entry remains an advanced exception. Explain omitted addresses rather than exporting an invalid oversized setup file. Bonjour/QR confirmation actions say PC 확인 because they immediately start normal certificate/PIN verification.
- Verifying the current PC may coexist with an idle file connection bound to that same canonical address. Changing the target remains blocked while files are connected. Manual desktop address edits use a draft and commit on explicit verification, preserving focus while typing.
- Screen quality: offer 1080p, 1440p and 4K (3840×2160), 30/60 fps, and explicit 10–100 Mbps options. Preserve existing defaults: Mac automatic bitrate uses 20 Mbps at 1080p, 30 Mbps at 1440p and 60 Mbps at 4K; Windows remains 1080p/60 fps/20 Mbps and retains 720p. Mac uses two rows of native settings (resolution/frame rate, bitrate/keyboard) within the existing grouped panel. Explain that 4K requires host display/capture/encoder support and higher bitrate requires more bandwidth; do not promise a measured improvement or change the host display topology. Quality is selected before connecting and applies on the next stream.
- Keyboard mode may change during a stream through the existing input-release path; resolution/frame-rate/bitrate changes require disconnecting. Mac input mode preserves Option-generated Mac symbols. Use physical mode for Windows Alt shortcuts and configure the Windows language/IME switch there. No untested Hangul/Windows-key mapping is implied.
- SSH failures show fixed guidance for host-key verification, client-key authentication, refused ports or unreachable networks. Keep raw stderr and private endpoint/path details out of the diagnostic UI. A failed local file operation must not unnecessarily discard an otherwise valid file connection.
- Brand icon: two interwoven rounded loops, ivory and muted teal on a deep ink tile, representing computers tied together. Source geometry is scripts/render_brand_mark.swift; Assets/Brand/knot.svg and knot.png plus AppIcon.icns/ico are generated by scripts/build_brand_icons.py. See docs/branding/LOGO.md. The name is selected in docs/branding/NAMING.md. Preserve existing bundle IDs, protocol scheme, trust stores, owner markers and installer upgrade identity during the rebrand; see docs/BRAND_COMPATIBILITY.md.
- Setup exchange: the normal path uses a short-lived Mac TLS listener and a separate one-use enrollment link/QR. Windows connects outbound, pins the ephemeral certificate, approves the displayed Mac key and allowed addresses locally, and returns only public connection data. Confirm the Windows SSH fingerprint before saving. Keep public JSON export/import as a recovery path. Never export a private key or treat screen PIN pairing as SSH authorization.
- Windows advanced/manual onboarding: installation success, local configuration-port response and working screen connection are separate states. Explicitly open `https://localhost:47990/pin` in the Windows browser. Use the pinned Sunshine labels “Required for all clients” / “모든 사용자에게 필수” and Save → Apply; never instruct users to find an absent “Mandatory” option. A loopback port check does not verify TLS identity, login or capture readiness.
- Updates: expose native Check for Updates. Wait while screen, files, enrollment, sharing or setup is active; reject new work once installation is admitted, while cancellation and disconnect remain available. Preserve install identity, screen certificate, Mac identity and SSH trust. A one-use receipt may reverify an already paired PC only on a strictly newer build within ten minutes; ordinary restarts do not connect automatically. Do not resume file transfers or silently re-pair a changed certificate. Unconfigured publisher/signing keys must show that automatic updates are unavailable and make no updater network request.
- States: disconnected, working, paired, streaming, failed/cancelled; never label unverified connection secure.
- Host-provided display names are bounded to 256 UTF-8 bytes before display/storage, without control/format characters; an empty label uses the selected address. Oversized settings fail before replacing the previous readable settings and show fixed recovery guidance.
- Ownership: app SwiftUI views use this contract; streaming lane owns native window/input.
- Keyboard mode belongs to the persistent desktop model, not a page-local picker.
- In Mac input mode, Option-Left/Right and Option-Backspace/Forward Delete send Windows Control word-editing commands; Command-arrows send Home/End or Control-Home/End, preserving Shift selection. IME marked text is never remapped. Control-Up/Down/Left/Right stay with macOS Mission Control/Spaces. Other Option symbols remain text input.
- Invitation/QR/draft input errors appear separately from verified-host status. Downloads choose a folder, preserve the original filename and reject collisions without a Replace prompt; transferred files receive macOS quarantine metadata before their final name is published. Failure to apply this metadata aborts the download and removes its partial file. A transfer committed before a refresh failure remains reported complete.
- Saved-host trust reset stays reachable in connection information after a failed connection, names the saved host and requires explicit confirmation; a new error expands the details, while streaming/busy reset remains disabled. Reset does not alter SSH keys.
- Windows shared-file access is limited to the selected original local desktop user plus the dedicated transfer account. UAC's alternate administrator identity does not silently become the selected user.

## Accessibility
- Native VoiceOver labels for icon controls; explicit button text.
- Keyboard focus follows standard controls; Escape dismisses sheets; Control-Up/Left/Right remain OS-owned.
- Semantic text colors; do not communicate status by color alone.
- No forced motion or tiny monospace body text.

## Responsive behavior
- Minimum 880x620, split sidebar/detail; streaming window fits selected remote resolution with letterboxing.
- Native fullscreen Primary only, no all-Spaces borderless window.
- The fullscreen window shows a small top-center, semantic-color text card while connecting, waiting for video or reconnecting. Reconnecting identifies the frozen picture as the last frame; a recovered transport still waits for a fresh frame. The card exposes readable accessibility text, uses no animation and never takes keyboard or pointer focus. First frame/finished recovery clears it; termination and teardown remove it.
- A nonfatal audio failure keeps the persistent connected-status warning and shows one fullscreen notice per connection attempt, for up to eight elapsed seconds from its first display. Video recovery guidance takes priority during that interval. Stalls do not pause the deadline or replay a consumed notice; expiration never hides connecting, waiting or reconnecting guidance.
- Pointer default free/absolute, native scroll.

## Interaction states
- Loading: progress and descriptive phase, prevent duplicate operation.
- Empty: one actionable instruction.
- Error: readable error; no raw keys/tokens/protocol dumps.
- Malformed connection links show how to obtain a new QR/link before any network troubleshooting; parsing failure never changes saved target or trust.
- Success: confirmed operation and destination.
- Disabled: show setup prerequisite.
- Offline: explicit retry, no silent authentication downgrade.

## Content voice
- Korean practical interface text with familiar Windows/Sunshine/OpenSSH terms.
- Files and desktop pairing are separate trust relationships; explain during setup.
- No unsupported claims of Chrome superiority.

## Implementation constraints
- SwiftUI/AppKit + vendored GPLv3 GlimmerEngine, macOS26+.
- System OpenSSH SFTP transport, no shell string interpolation.
- Control/video/audio encryption mandatory.
- Reverse desktop uses an explicitly started, independently signed/pinned Sunshine Mac host and an unmodified, pinned Moonlight Windows engine. The Mac host always passes LAN/WAN encryption=2, disables UPnP, and restricts the administrative web UI to the same computer. An incompatible encryption negotiation must fail on that host; do not describe the Windows backend as inheriting Glimmer's additional client checks.
- The existing Windows EXE retains its host setup and adds a native Mac client through a role chooser. The engine is downloaded only after a user action, from an immutable official asset with exact byte count/hash. The complete runtime inventory is verified before execution. Keep executable code and private portable engine settings separate; never adopt global Moonlight settings or silently trust a QR/Bonjour hint.
- Mac sharing is off until the user starts it. Use a new app-owned configuration and terminate only the owned host process group. Never mutate an existing Sunshine deployment, grant TCC permissions, enable Remote Login, or add a broad file-sharing service. Screen Recording/Accessibility approval remains an explicit macOS step. A stopped launcher or failed host is never labelled as a running share.
- Windows client defaults to direct/absolute pointer input, a conservative office streaming profile, no remote quit command, and local system-key ownership. An explicit fullscreen option sends Windows keys as Mac Command; it warns that other Windows system shortcuts may then be captured too. Ctrl+Alt+Shift+K toggles system-key capture, Ctrl+Alt+Shift+Q closes the local stream, and local desktop switching follows release. Explain Command/Windows keyboard differences; no automatic Ctrl/Command swap. Pairing is separate from entering an address; a started client process is not proof a video session is connected.
- Reverse file transfer, login/FileVault screens, headless display creation, and automatic clipboard sync are not implemented by this reverse-screen feature. Keep the existing Mac-to-Windows files page working and label its direction clearly. Do not imply a restricted SFTP share limits full desktop control.
- Native Windows discovery performs bounded mDNS metadata queries only; Tailscale uses the same QR/link/manual-address flow, without a peer-list or subnet scan. Windows QR import is offline, explicitly user selected, bounded to 8MB/16 megapixels, and rejects ambiguous results.
- Moonlight's own compatibility/controller-maintenance requests are upstream behavior. Disclose them rather than promising zero external network traffic. Disable optional rich presence and connection-testing preferences in the dedicated portable profile. Knot's signed application updater is separate from Moonlight and never replaces its pairing profile.
- New reverse-direction checks use only newly generated inert source/packet/image/process fixtures. Agents do not launch the production capture host/client, inspect a real desktop, request permissions, or read user preferences/keys/logs. Native pixels, TCC, input, audio and LAN/Tailscale performance remain device acceptance gates.
- No clipboard reading, telemetry, user data in agent tests.
- Visual checks use a separate synthetic NSHostingController executable, isolated temporary SettingsStore and a unique identity preferences suite. It never runs production App.main or invokes network/file-picker actions. Only newly created fixture windows are captured by their exact window ID; full desktop/other applications are never captured. These snapshots do not validate real Windows, IME, audio or network behavior.
- Test/screenshot command: python3 scripts/render_visual_fixture.py --output evidence/quiet-sidebar/<iteration>. Requires an optimized module build and working OS Screen Recording access; it does not request permissions or capture unrelated windows. --interactive desktop (or files/setup/first-run/certificate-error/compact/files-compact/dark) opens only a fresh fixture window for manual inspection. Failed captures never imply visual approval.
- Current visual verification limitation: cached view rendering and PDF export failed to composite SwiftUI materials; own-window OS capture failed; native CUA startup was unavailable. Therefore the native A implementation has no final visual-verdict pass or pixel-diff acceptance yet. Keep this separate from build/check and source-review results; manual native visual acceptance remains required.
- Distribution: distinguish unsigned development packages from Developer ID/notarized Mac releases and Authenticode-signed Windows releases. CI packages artifacts; it does not publish releases automatically.
- Build: optimized release is the default, with a separate optional debug configuration. Packaging requires unchanged complete source and completed app snapshots.

## Open questions
- [ ] User's actual Mac minimum OS/architecture beyond this build host.
- [ ] Windows Sunshine/OpenSSH setup and actual device acceptance (user hardware).
- [x] Product name: Knot (user selection, 2026-10-22). Trademark/domain exclusivity has not been established.


Windows 설정·QR 창은 DPI에 맞춰 확대되고 현재 작업 영역 안으로 크기를 조절한다. 설명은 스크롤 본문 안에서 줄바꿈하고, 고정 하단에는 선택 가능한 상태·SSH 지문을 표시한다. Sunshine 다운로드는 바이트 기준 진행률·취소를 제공하며 60초 동안 수신이 없거나 전체 10분을 넘으면 중단한다. 고정된 파일 크기를 넘는 청크는 저장 전에 거부한다. 화면 엔진의 다운로드 후 해시·전체 파일 검증도 백그라운드에서 수행해 취소 버튼이 응답하도록 한다. 자동 주소 제안에서 vEthernet은 제외하고 Tailscale은 유지한다. 연결 파일 저장 취소·실패는 완료된 파일 설정을 되돌리지 않으며, 지문과 다시 저장하는 안내를 유지한다.

## Linux host extension (2026-10-22)
- First target: Ubuntu 24.04 LTS amd64 with a logged-in X11 desktop. Wayland, login screens, headless capture, Linux client and Linux files remain outside this release.
- Native GTK setup application distributed as a .deb. Download the pinned official Sunshine package only on user action, validate bytes/hash, then let the user open the system installer. Never provide a custom privileged broker, input-group grants or service autostart.
- Share only while the helper owns its private Sunshine child. Force X11, LAN/WAN encryption, local administrative UI, no UPnP and no controllers; suppress file-capability elevation using no_new_privs. Process liveness is not capture readiness.
- Mac Linux tab has a separate immutable target context and private identity/settings. Existing Windows pins are untouched. Linux has no file/setup exchange capability. Both screen contexts share a model-level single-stream exclusion.
- Windows Linux role keeps the existing per-address engine trust store. Mac Command mapping is unavailable in the Linux role.
- Linux emits v2 address-only invitations with platform=linux. v1 stays backward-compatible for Windows/Mac roles. Platform is an untrusted UI hint; a wrong-role invitation is rejected and every connection requires ordinary certificate/PIN checks.
- Linux installer, hardware capture/input/audio and LAN/Tailscale latency require actual Ubuntu acceptance. Synthetic process/package tests never claim those results.

## Windows virtual display extension (2026-10-23)

- Optional Windows setup modal for one persistent virtual display. Native controls, scrollable instructions, fixed selectable status text, bounded cancellable download and explicit UAC operation. No display topology mutation, automatic physical-screen disable or session hotplug.
- First setup still needs a display or another remote access method. Windows must be powered on and logged in; this does not unlock, wake or enable pre-login access. Mac/Linux headless support remains outside this change.
- Device, active display, reboot/recovery and successful stream are separate facts. Read-only inventory runs on a background task with bounded UI wait. The GDI display name is diagnostic text, never a fabricated Sunshine identifier.
- Sunshine output selection stays manual. Its pinned Windows UI uses a free-text device ID field; the user obtains the correct device_id from Sunshine's own display enumeration. Knot neither reads its logs/config nor writes it. Use ensure_active, never ensure_only_display.
- Journal the exact random device ID before creating it; device-targeted SetupAPI install/remove. Refuse foreign present/phantom VDD devices and existing/changed registry or files. Shared driver-store cache is retained. Removing the app retains the virtual display; explicit managed removal is a separate action.
- Artifact, catalog and member pins establish provenance, not driver safety. Driver availability must remain subject to upstream IPC review and stock Windows/SecureBoot device acceptance. Synthetic checks never imply hardware or remote-session success.

## Windows single-action onboarding (2026-10-24)

- Extend the existing native controls and fixed status footer. The initial screen presents connection preparation, a short Mac instruction, QR/link and collapsed file/manual setup. Do not start service probes merely to display the screen.
- Fresh setup uses the exact pinned MSI with fixed `/passive /norestart` arguments and the native setup companion in the same UAC operation after exit 0. Cancellation, installer contention and reboot-required outcomes stop the chain. Previously completed steps remain completed; never label cancellation as rollback.
- An existing standard installation goes directly to native setup. An existing listener/service at a different location requires manual integration, never a blind reinstall. The protected companion independently checks standard paths, ownership, version and local public certificate; a UI presence hint cannot authorize privileged work.
- Only a fixed, certificate-pinned loopback HTTPS API is used. The supported MSI service listener must run the protected Sunshine image as LocalSystem, before credentials and after restart. Validate private-key file ACL metadata for confidentiality without reading its contents; customized/untrusted key permissions require manual integration. Do not disable global TLS validation, use proxies/redirects or send credentials to an unverified endpoint. PINs live only in the dialog. A fresh account uses a CSPRNG password and is persisted before creation with machine DPAPI and an explicit SYSTEM/Administrators-only DACL under the already verified Sunshine credentials directory. Bind retained credentials to the pinned public certificate; never place secrets in arguments, logs or QR data. Existing unknown accounts require one successful login, then secure reuse; never reset an account or adopt a changed certificate automatically.
- Explain that preparation may interrupt current Sunshine sessions and require other configuration editors to close. After authenticated verification, merge the existing configuration and change only LAN/WAN encryption=2, UPnP=disabled and web administration=pc. Require the exact previous listener process handle to signal exit, verify a distinct protected LocalSystem replacement and read back with the same certificate inside one 45-second restart budget. Reject explicit restart failures; failed or ambiguous verification is not success. This proves an observed restart plus saved configuration, not arbitrary command-line overrides or a working stream; the ordinary client still requires actual encrypted channels. Upstream has no compare-and-swap configuration transaction, so concurrent external administrators remain a manual acceptance boundary.
- When authenticated saved configuration already matches the four required settings, offer PIN approval without a configuration POST or restart. This is a pairing-ready state, not proof that running settings were reapplied. Keep the Windows dialog open before starting a new Mac request. Explicit **보안 설정 다시 적용 · 재시작** remains available and warns that the old Mac request must be cancelled and recreated afterward. A fresh/insecure setup still requires the full observed-restart proof before reporting its application complete.
- Show the selected public QR address and the number of other included addresses on the main screen; cap inclusion at eight and point to the advanced address selector. Pending-request selection controls PIN button availability. Native status text is selectable; file, ACL, process and API initialization run off the UI thread with cancellation-owned resource transfer on close.
- A known incomplete security application stays distinct from saved-config pairing readiness: retry or explicit reapply must observe the required restart before clearing that state. An interrupted previous dialog must direct the user to explicit security reapplication, with a durable encrypted recovery flag and without weakening certificate checks. A pending-list refresh failure after preparation retains the completed preparation status and offers a separate refresh retry; no peer is auto-selected.
- PIN approval lists pending requests and requires explicit request selection plus the Mac's four-digit PIN. Requests, names and addresses are untrusted bounded metadata. Never auto-select an unexpected peer, clear pairing or replace saved screen/SSH certificates.
- A configured host is separate from a successful screen stream. UAC, one-time authentication for an existing unknown account, request selection and PIN confirmation are deliberate approvals. Fresh account preparation and later remembered logins require no account form. Do not promise zero-click unattended access or files without the separate existing enrollment/trust flow.
- Reuse a single UI-owned Core Image context for QR rendering with intermediate caching disabled. Retain at most one public-address invitation image; do not cache enrollment capabilities or their QR results.
- Acceptance uses actual production policy/session/dispatch/state-flow code with fresh inert API replies, streams, parser, UI-leaf and certificate-byte comparison fixtures. Native TLS handshakes, Windows handle/ACL APIs and installation are compiled but require separate Windows runtime acceptance. No actual service, account, firewall, installer, capture or user preferences are touched by agent tests. Native Windows packaging and two-device device acceptance remain separate gates.

## Windows account and running-update continuity (2026-10-25)

- Automatically prepare a fresh Sunshine account after the user starts connection preparation. Generate 32 random password bytes; journal encrypted credentials before the first account POST so a lost response can be retried without changing the account. Serialize broker access with an exclusive protected lock. Persist the incomplete-security flag before mutation and clear it only after observed restart/readback. Existing accounts are remembered only after authenticated verification. A changed certificate, unsafe ACL or corrupt credential record fails closed with recovery guidance.
- The installer closes only the exact installed Knot process and verified descendants in the current Windows session, through normal window close messages and bounded waits. Hold process handles and bind PID/creation time across enumeration. Never kill by process name, stop Sunshine/OpenSSH, revoke file enrollment or remove configuration during upgrade. Privileged windows opt in to an idle-only safe-close protocol; legacy or busy privileged work refuses closure. Busy configuration can refuse closure; explain that it must finish, with retry rather than forced termination. The post-install action reopens the app without elevation. Upgrading old releases must work without requiring new IPC in the old app.
- Source-only protocol fixtures and fresh owned Windows process/file fixtures verify the new seams. Existing user vaults, processes, settings and services are never test inputs. A real two-device upgrade remains a separate acceptance check.

- Opening Windows Knot goes directly to this-PC preparation, with automatic managed-engine install/configuration and a single branded preparation window. Mac/Linux client actions remain in the main navigation; manual engine controls stay collapsed. A pending-pair timer removes the refresh step while retaining explicit peer/PIN approval. The engine remains the separately licensed Sunshine service managed by Knot, not a rewritten or relabeled upstream product.
- Install the public executable as `Knot.exe`; close and remove only the exact legacy `DeskBridge-Windows.exe` during upgrade, preserving stable AppId, registration directory, pairing, SSH identifiers and shared files. Native extracted helper and all visible dialogs use Knot branding. Stable user-data paths and wire identifiers remain migration-compatible.

- Keep the public QR/link reachable inside the native preparation window while the outer host window is hidden. Request polling is independent of UI busy state: preserve an explicitly selected exact ID/name/address while refreshing, back off transient failures, and stop on trust failures until explicit refresh. Never disable PIN entry merely for background polling. Serialize installers across Windows sessions with a global installer mutex.

- The installer close bridge uses the same native loader, image/payload pins, protected staging and sanitized elevated environment as the app before starting CLR. Never execute the managed close policy directly from inherited installer environment. Optional engine inputs use metadata probes that accept only actual not-found errors as absence; denied/unknown metadata prevents startup.


## Windows task-focused connection UI (2026-10-25)

- The user reports that both the everyday buttons and the expanded advanced panel are hard to understand. Retain native Windows controls and the existing trust/privilege boundaries; change information hierarchy rather than adding a new settings system.
- The preparation window starts automatically as before. Show the next relevant action: existing-account login only when required, retry only after a failure, pending Mac selection and four-digit PIN approval only while requests exist. Keep explicit peer selection; never preselect or approve a discovered Mac.
- Background request polling does not need a permanent refresh button. Show recovery refresh when polling reports a problem. Put QR/link help behind “Mac에서 이 PC가 보이지 않나요?” and the account/security explanation behind its own disclosure. Keep a selectable status footer outside the scrolling content. Closing preparation returns to other functions; it does not stop the Sunshine service or erase pairing.
- The outer window keeps one primary preparation action. Put optional tasks under “다른 기능 및 도움”: files, headless use, opening another computer, and connection troubleshooting. Explain when each is needed. Expand one sibling task at a time without clearing inputs or starting work merely on expansion.
- Within files, automatic enrollment is primary. JSON recovery and access revocation are separate collapsed tasks; access revocation explicitly retains shared files. Within troubleshooting, direct Sunshine installation/account/encryption/browser PIN controls require a further explicit manual-setup disclosure. Avoid numbered references to sections that are no longer visible.
- Disclosure actions respect update/busy admission. Cancellation, existing pairing, certificate pins, SSH identity and explicit UAC/file authorization remain unchanged. Tests use actual disclosure handlers with inert controls and existing protocol/primary-action fixtures; no live service, user preferences, screen, clipboard or history is read. Real Windows layout and two-device acceptance remain separate from CI compilation.
