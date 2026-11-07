# Knot Native Engine — independent vertical slice

This experimental host/viewer uses **no Sunshine, Moonlight, Glimmer, browser, OpenSSH, relay service or external media executable**. It is a separate `Knot Native Preview` app so the existing Knot product remains available for comparison.

Windows uses DXGI Desktop Duplication, D3D11 SDR/NV12 processing and a **hardware-only Media Foundation H.264 encoder**. Mac owns its OS TLS transport, strict parser, VideoToolbox decoder and native AppKit/SwiftUI desktop. A pinned, vendored BoringSSL crypto library provides short-code enrollment; it is compiled into the app, never downloaded at startup. Windows currently reads back GPU pixels before hardware encoding; this is not a zero-copy claim.

## Scope

- Windows11 x64/Home, logged-in unlocked primary SDR landscape display; supported hardware H.264 MFT required.
- AppleSilicon macOS26+ viewer; one peer, one display, one window and bounded H.264/TLS-TCP.
- Windows Share authorizes one holder of the current short code. Advanced legacy invitation mode retains its separate approval step.
- Native fullscreen, pointer/keyboard input and committed Mac input-method text. Source aspect ratio is preserved.
- Optional Windows playback sound on Mac, enabled explicitly before the current Windows share. Microphones are never captured. Both apps must use Native.13 for this feature; see [AUDIO.md](AUDIO.md).
- While the screen session is active, copy regular files and folders through one explicitly shared Windows folder, with Finder drop-to-send, file-panel drag-to-Finder, and current Explorer selections dragged out of the viewer. Files use a separate pinned TLS connection, incremental hashes and bounded transfer work; original files are retained.

**Microphone forwarding, ambient clipboard synchronization, headless/virtual displays, secure desktop/UAC/lock screen, HDR, rotation and multiple displays remain unsupported.** Native.11 adds explicit text copy/paste, opt-in trusted devices and reconnect, adaptive quality and signed-update infrastructure. Public update publishing remains unconfigured; see [UPDATES.md](UPDATES.md). Existing production desktop/files/reverse/Linux apps remain separate. The host cursor's separate DXGI overlay is not composited. Real GPU/Home, input/IME, fullscreen and network quality require device acceptance; codec or TLS failure does not select a weaker backend.

## Daily use (native.13)

### Playback sound and receiver fixes (native.13)

Update **both Windows and Mac apps**. Before starting a Windows share, select **Windows 재생 소리 포함 · 마이크 제외** to include the default Windows playback output. The checkbox starts **off on every app launch, including after an update**. Its permission belongs to the current manually started share; an old resume grant never enables it. On Mac, use the connected speaker button to mute or restore sound. Mute affects this Mac's playback and keeps draining the audio connection. Stop/disconnect ends audio with the screen session.

Audio uses fixed stereo48kHz PCM16, about1.536Mbps before transport overhead, on independent pinned TLS TCP48636. It is bound to the current media-authorized peer and a derived session key; the media-v1 Hello/Ready schemas remain unchanged. An older host, declined option, unavailable device or audio error leaves video running. There is no precise audiovisual synchronization or measured performance guarantee. [Audio scope and protocol](AUDIO.md).

Native.13 also corrects ambiguous H.264 sample-framing detection, reports repeated short-window receiver pressure to the existing quality policy with hysteresis, and repaints the solid parent background around Windows rounded buttons. The pressure path preserves compressed-frame order and does not add frame skipping. These changes address source/fixture findings; they do not establish the cause of a particular GPU's4K stutter or prove a hardware performance improvement.

### Certificate compatibility correction (native.12)

Native.11 accidentally issued persistent server leaves with a five-year lifetime, and its default Framework RSA factory did not guarantee the requested2048-bit key. macOS SSL policy rejects incompatible certificates even with the correct explicit pin. Native.12 explicitly creates a2048-bit RSA key and issues a365-day total lifetime, including backdating, without weakening hostname, server-purpose, date or exact-pin verification.

For a Native.11 identity, update Windows, open the app and explicitly click **호환 인증서로 전환하고 공유**. The button discloses identity replacement and removal of registered Windows-side credentials before it runs. Connect from Mac using the new eight-digit number; previously registered Macs require explicit pairing again. Missing, corrupt or expired identities never trigger this compatibility conversion automatically, and automatic update/reconnect cannot authorize it. Conversion failure stops sharing; credentials may already have been revoked, so use a fresh pairing after a successful conversion.

If another app process already converted the identity, the same direct button verifies that it is compatible and proceeds without a second replacement or credential revocation. Actual conversion failures still stop sharing.

CI now generates and PFX-reimports the same certificate used by production, asserts its actual public-key size, completes fresh Windows TLS handshakes, exports its public DER and checks that exact Windows-produced365-day certificate and key size against the Mac SSL policy. Fresh five-year and1024-bit negative fixtures prove both rejections remain enforced. Existing valid overlong or weak-RSA identities require the same explicit conversion action. This closes the earlier coverage gap where synthetic hosts only exercised the legacy48-hour certificate.

- Choose **내 PC로 등록** before the authenticated eight-digit connection to store a device credential in Mac Keychain; Windows protects its persistent host identity and registered credentials with CurrentUser DPAPI. Subsequent connections use a pinned TLS challenge service on TCP48635 and fresh session grants. IP/name changes never silently replace a certificate. Either device can revoke registration; local Mac removal works offline, but remote revocation requires the host to be reachable. Windows **연결 안내 → 등록한 Mac 관리** independently revokes credentials and stops sharing.
- Transient failures of a registered session retry at most six times. Manual disconnect/stop cancels retries. Windows must remain logged in/unlocked and sharing. This does not provide unattended login, a Windows service or UAC control.
- **Command+C/V** explicitly copies Windows text or pastes Mac text; no background clipboard monitoring occurs. Text is bounded to1MiB and the session lifetime. The optional Mac shortcut profile maps ordinary Command shortcuts to Control; physical mode and Mac IME remain available.
- The menu-bar item and **Control+Option+Command+B** bring the owning Windows window forward. The app remembers its viewer name, Mac shortcut choice, reconnect preference, quality preference and fullscreen choice. Mission Control shortcuts remain owned by macOS.
- Connected **작업 도구** offers Auto / Text clarity / Responsiveness. Auto responds to slow socket writes and receiver pressure within the Windows-selected limits; dimensions stay fixed. Hardware rejecting live bitrate changes retains the last applied settings and reports the limitation. This is an adaptive policy, not a measured latency guarantee.
- The file panel counts completed items, reveals the most recently received item in Finder on request and retries only unacknowledged upload items. Received content never opens automatically. Byte-offset resume is not implemented; a lost acknowledgement can require a new collision-safe copy.
- Signed-update infrastructure downloads in the background, verifies a publisher-pinned signature and artifact identity/hash/size, installs after the update action and relaunches. Registered-session resume intent lasts five minutes and is consumed once. Feed/key setup and actual installer/device acceptance remain separate prerequisites.

## Connect

Native.6 targets the reported delay between an immediate local Mac pointer and a following Windows window at4K60: serial video parsing/AVCC preparation runs away from the UI actor, input TCP uses `noDelay`, input selection follows pacing, and Windows uses a session-owned high-resolution poll timer. Actual timer measurements and a separate4K60 software-codec interoperability fixture are recorded by CI. Update both apps. These changes do not claim measured two-device latency, remove GPU readback or guarantee every GPU can sustain4K60.

Use a private network or an already configured Tailscale connection. The Korean interface follows the Quiet Sidebar design, with advanced settings and help secondary.

Native.9 adds connected file transfer to the guided connection flow. Update **both apps**. The Mac first explains how to start sharing on Windows, then searches for PCs. **Explicitly choose a result before entering its eight-digit number**, even when only one PC is found. The number screen shows the selected PC and address; **다른 PC 선택** returns to the list and clears the number. Connection guidance is always available in the sidebar, without saving onboarding state or starting discovery automatically. Windows shows the matching steps and identifies the PC to select on Mac.

1. Open `Knot Native Preview` on Windows and start sharing. The eight-digit number lasts120seconds and authorizes one matching Mac for screen/input. Quality is frozen for that run: maximum4K/30fps/40Mbps by default, optional maximum4K/60fps/40Mbps or1080p/60fps/20Mbps compatibility mode.
2. On Mac, find nearby PCs, select the candidate, enter the number and connect. Discovery names/addresses are unverified context. PAKE and directional authenticated encryption transfer the complete secret invitation; the Mac then opens a **new** existing TLS connection with its exact full DER pin and OS certificate checks. The provisioning socket never becomes media.
3. This explicitly preauthorized code-holder path requires no second Windows approval. Capture/input still starts only after the valid, unused T2 claim on pinned TLS, and Mac reports streaming only after a decoded image is presented.
4. Stop, disconnect, window close or timeout revokes this session permission and requests release of owned injected input. Windows can refuse release during desktop transitions; retries are bounded. Unregistered devices need a new number. Registered devices authenticate afresh with their stored credential; there is no silent certificate repair.

LAN broadcast does not discover devices across Tailscale. Under **다른 연결 방법**, an explicit private/Tailscale IPv4 entry can send a bounded unicast discovery query; choose its result before entering the number. Advanced legacy mode starts a distinct new Windows run: copy its full invitation, review address/pin on Mac, then explicitly approve on Windows. Changing modes cancels the prior slot/grant; old legacy tokens are never preapproved.

The number and invitation are secret capabilities. Neither is advertised or logged; clipboard copy is explicit and neither app automatically reads the clipboard. Copy requests Windows clipboard-history/cloud exclusions, which cannot prevent other software reading the current clipboard. [Media contract](PROTOCOL.md), [enrollment contract](ENROLLMENT.md).

A received frame may reach3840×2160 without upscaling a lower-resolution source. True4K therefore requires a4K Windows desktop; the app does not change display modes or create a virtual monitor. Actual GPU4K/60 support is device-dependent and unsupported hardware fails honestly.

Fullscreen removes reserved toolbar/footer height. Floating controls provide disconnect, native fullscreen exit and actual received dimensions. One desktop/presenter remains mounted; genuine source/viewer ratio differences still letterbox. Ordinary typing uses the Mac input method by default, preserving local Caps Lock language/capitalization behavior. Physical-keyboard fallback is secondary. Focus loss/revocation cancels composition and rejects late commits; physical shortcuts and owned key-ups remain separate from Unicode text.

Normal Windows execution needs no elevation. OS private-network/application-control prompts may apply; the app changes no firewall, forwarding or system-security setting. Media TCP48631, enrollment TCP48632, discovery UDP48633 and optional playback-audio TCP48636 remain private-network services. Packages are development previews: Windows unsigned, Mac ad-hoc/unnotarized.

## Files while connected

Windows shows the shared folder before sharing; the default is `Downloads/Knot Files`. Start sharing authorizes the displayed screen/input, enabled shared-folder scope, and explicitly dragged Explorer items. You can choose another folder or disable files before starting. The folder must support persistent Windows file permissions and Mark of the Web; failed security checks make files unavailable while screen sharing remains active. The panel lists files and folders directly inside this root; receiving a folder includes its bounded descendants. Explorer drag export can select an item elsewhere without exposing its parent folder.

On Mac, open **파일** in the connected controls. Send files or folders using the picker, or drop Finder items onto the remote viewer/file panel: the destination is the displayed Windows shared folder, regardless of the Explorer folder under the pointer. Receive with the destination picker, or drag a file row from this panel into Finder. These are file copies; sources are never removed. To receive directly from Windows Explorer, hold a file/folder selection and drag it beyond the remote image into Mac Finder. Knot captures only that active native OLE drag, then continues it as native Mac file promises. Keep holding until the local drag icon appears; releasing or cancelling early aborts the handoff. Multi-selection is supported up to32 items.

The panel shows progress, cancel and authored errors. Existing destination files are never overwritten; Windows uploads choose a collision-safe name, while an explicit Mac/Finder destination must be unused. Received files receive platform quarantine/Mark of the Web and are never opened automatically. Ordinary folders, including empty subfolders, are supported. Application packages, links, hardlinks and special files are rejected. Limits are256 listed files,32 queued uploads,8GiB per top-level item and per active run,64KiB chunks and2MiB/s pacing. Each tree allows4096 descendants, depth16 and1MiB node metadata; each run reserves at most8192 nodes. Cancelled attempts still count toward the run's byte/node reservations.

File bytes use TCP48634 on a separate same-certificate pinned TLS channel, with a fresh session capability and observed media-source binding. Cancel or a file error leaves the desktop session active; disconnect/stop revokes file access and removes owned partial files. Separate queues and pacing do not guarantee uncongested Wi-Fi. No SSH account, extra server or global clipboard access is required. Exact admission, framing, filesystem and test contracts: [FILES.md](FILES.md) and [TREES.md](TREES.md).

## Build

Use a committed clean checkout. The builder checks source/archive parity and confines output to its owned `build/native-engine/<platform>` directory.

```sh
python3 scripts/build_native_engine.py --platform macos
```

Mac needs Xcode/Swift6, macOS26SDK+ and CMake3.22+. `KNOT_NATIVE_CMAKE` selects a trusted CMake executable if it is not on PATH. The builder compiles pinned vendored crypto first and supplies its owned static-library directory; no external Swift packages are fetched. The production GUI is packaged, never launched by the builder.

Windows needs VisualStudio C++x64 tools/WindowsSDK, CMake3.22+, .NET Framework4.8 compiler/reference assemblies and InnoSetup (`INNO_COMPILER` may select ISCC):

```powershell
python scripts/build_native_engine.py --platform windows
```

Both native DLLs, the C#5 host and fresh test executables are built from source. Setup PE resources are inspected without execution: full preview version and numeric revision must match. `--media-only` is diagnostic, never complete app acceptance.

The native CI workflow builds Windows first, then Mac. It transfers fresh software-MFT fixtures and a public test DER certificate, never a private key. Actual VideoToolbox tests decode the120-frame burst, six-frame3840×2160/30fps fixture and twelve-frame3840×2160/60fps fixture within their slot bounds. Software encoding exists only in the separate synthetic executable, not as a runtime fallback. Both platforms run native crypto known-answer/state/authentication checks and upstream SPAKE2 tests. Portable H.264 parser/pacing/resolution/activation checks use ASan/UBSan on Mac; native Windows release media is optimized.

## Evidence and limits
The encoder retains at most two in-flight samples and the decoder three outstanding images. MFT output scratch is distinct from compressed size: the chosen resource budget is two validated NV12 frames (at most24,883,200bytes at4K), while allocation is only max(AUlimit, reported minimum). This supports the actual15,552,000byte software-MFT minimum observed in the4K fixture; it is not a guarantee for every encoder. The compressed wire envelope remains4MiB and existing NAL limits still apply. This is not permission for larger wire frames or unbounded queues.


`NATIVE-INPUTS.json` records inputs only. A completed successful build writes `NATIVE-BUILD.json`, per-command stdout/stderr/argv, source manifest, product hashes and `SHA256SUMS`. Exact compiler and synthetic checks are distinguished from device acceptance. A green compile/codec/TLS fixture does not establish real hardware capture, input injection, Home runtime or end-to-end quality.

Runtime packet sizes, input actions and decoder work are capped. A single media writer applies socket backpressure before acquiring the next frame; input travels in the opposite TLS direction. Codec/device operations have application polling budgets but an in-process app cannot preempt a wedged OS/GPU call; hard isolation is future work. TCP is a deliberate first-slice transport with head-of-line/recovery tradeoffs, not a claimed replacement for a tuned real-time media stack.

Full builds also render fresh synthetic UI states from the actual view sources. `native-ui-visual-checks.json` binds the renderer, assets, image hashes and layout checks; the separate `native-macos-ui` and `native-windows-ui` CI artifacts contain those images. These fixtures never enter the production app entry point, connect a host, create certificates, read the clipboard or capture an existing screen. Audio checks use fake capture/output sinks and newly generated PCM/packet fixtures; they never capture or play existing audio. A successful render is not a visual approval: human inspection is recorded separately, and real display/input/DPI/audio behavior still needs device acceptance.

Windows monitor decoration uses one fitted canvas for its screen, centered mark and stand. Six fresh bitmap sizes at six DPIs verify containment, square panes and identical drawing for identical pixel bounds; Windows scenes include initial onboarding, number/help views and150%/200% short-number idle views. The builder requires these checks and rejects linked/reparse/shared output destinations before publishing assets or completion records.

Pending GPU readback is polled without submitting stale pixels or consuming the next capture period. After the encoder produces its first output, an unchanged desktop is repeated at most once per second, with the periodic IDR deadline preserved. Capture timestamps remain the original pixels' capture time; separate stream presentation time drives encoder timestamps and the two-second IDR target. Sample duration is the nominal frame interval, never the preceding idle gap. Windows reuses a bounded video payload buffer; the Mac parser avoids an extra full-access-unit copy. These are source/fixture-verified policies, not a measured hardware performance claim. [Preview changes](CHANGES.md).

The Windows media timer waits until the next capture deadline when no readback or encoder work is pending; pending work retains the short poll interval. A fresh five-second policy simulation reduces wait requests from5001 to306 while retaining301 capture checks. Those counts do not measure actual CPU use, power or two-device latency.

The viewer waits up to65seconds of silence for approval/encoder startup and125seconds overall before Ready, then uses a10second silence budget and15second first-image deadline. The certificate's ±24hour validity window tolerates clock skew; the secret invitation still expires after120seconds and is one-use. Preclaim handshakes remain serial and bounded to10seconds/remaining invitation life, so a hostile private-network peer can still consume availability. Physical-device acceptance is required for startup time, high-DPI layout, scroll/IME feel and hardware codec behavior. Fixed input/codec queue limits do not measure end-to-end latency or OS socket buffering.

The protocol does not compare host/client monotonic timestamps as latency; independent clocks would need synchronization. Measure input-to-display/frame age, CPU/GPU, text/color and recovery on the same hardware/settings as the existing product before choosing the default engine.

## License

The app follows the repository GPL-3.0-only license. Corresponding source includes the exact pinned BoringSSL source and its Apache-2.0/support-code notices. It does not link the existing vendored streaming engine. OS codec capabilities and capture/input permissions remain required.

When distributing the preview installers, publish the generated corresponding-source archive and its SHA256SUMS alongside them. Individual check JSON files describe only their substeps; a successful complete build also requires the matching NATIVE-BUILD.json and product hashes.
