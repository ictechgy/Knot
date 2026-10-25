# Signed application updates

Knot uses the official Sparkle 2.10.0 framework on macOS and WinSparkle 0.9.4 on Windows. The updater replaces Knot application binaries only. It does not upgrade Sunshine, Moonlight, OpenSSH, virtual-display drivers or other system services.

## Current preview

The public publisher configuration in `packaging/updates/publisher.json` is intentionally unconfigured. This preview shows that state in its update UI, performs no update networking, and continues to work normally. Adding a feed URL without its public signing key and Windows publisher certificate pin is rejected at build time. Publication, production signing keys, operating-system certificates and signed upgrade acceptance are separate release work; a compiled adapter is not evidence of a completed public update service.

Unsigned Mac preview builds keep automatic updating disabled even if a future publisher configuration exists. They do not disable hardened-runtime Library Validation to load an updater. The configured updater is linked only by a Developer ID build. On Windows, a portable quick-setup EXE directs users to the installed version instead of installing somewhere else and reopening an obsolete portable copy.

## Local installer updates in preview.23

The all-null publisher does not prevent a user-initiated local upgrade. Open **Install Knot.app** beside Knot.app in the downloaded Mac DMG, or run the new Windows setup EXE normally. The installer requests a graceful close, replaces the application and reopens it automatically. It does not force-kill processes or change pairing, keys, certificates, Sunshine accounts or file sharing.

The Mac helper embeds its payload under Contents/Helpers/Knot.app so Gatekeeper translocation cannot break external sibling discovery. It validates the payload and destination, stages a verified newer app before requesting quit, locks the destination directory, and uses an atomic bundle exchange. A signed app requires the same Apple signing team; an ad-hoc preview checks local integrity only, not publisher authenticity. It selects the exact running copy, or a single known installed copy, and refuses ambiguous copies or redirected paths. A protected existing location is refused before quit; administrator replacement is required. It never silently creates a second user-local copy beside a protected installation. A launch failure rolls back an existing installation; rollback or reopen failure displays the exact recovery location and retains the backup. It waits up to 140 seconds; preview.23 apps allow protected transfers/enrollment/setup to drain for up to 110 seconds before normal bounded teardown, leaving margin within macOS's system-termination deadline. Finish transfers/setup yourself once when upgrading preview.22 or older; an older binary cannot acquire the new drain barrier from the installer.

Windows uses an owner-scoped close request: new forms block new actions and drain setup work; the remote client closes its own contained engine. The bridge retains process identities and observes unsupported descendants without signaling them. Legacy owners get a 15-second budget; an acknowledged new owner gets at most 180 seconds. Failure cancels only that request and leaves the installation unchanged. The manual Inno installer owns relaunch; `/KNOTUPDATERHANDOFF=1` suppresses that relaunch for the verified online handoff, which already owns a single non-elevated restart. UAC is still required for Windows installation; launch the installer normally so Inno retains the original user token.

The synthetic tests exercise real ad-hoc bundle validation, staging, replacement/rollback and protected-work drain on macOS; fresh owned WinForms fixtures test delayed closure, observer-only descendants, per-owner deadlines and request cancellation on Windows. They do not execute the production installer or establish signed online-upgrade acceptance.

## Online update behavior

- Mac: **Knot → 업데이트 확인** invokes Sparkle's native UI. Configured releases check automatically; installation is explicit. Screen sessions, file transfers, Mac sharing, enrollment and setup work must finish before an update relaunch. A pending installation blocks new work while allowing disconnect and cleanup.
- Windows: the role chooser shows update status and an **업데이트 확인** action. Checks run while the installed helper is open and idle; there is no background update service when Knot is closed. Choosing a sharing/client operation atomically makes the helper busy. A pending installer atomically prevents a new operation. Online installation still requires idle admission; active host/client UI must close first. The local EXE installer above can request owned UI closure while it is open.
- Windows installation admission binds the actual bootstrap image to the stable Inno registration under HKLM's 64-bit view. A custom previously registered installation directory remains supported. No auto-update is started by an elevated setup broker.
- Windows uses a dedicated, non-elevated handoff. It inherits an allowlisted handle to the exact native parent process, waits for that process to exit and release its image/path locks, then requests the ordinary installer authorization. It never uninstalls first. The stable Inno AppId is retained.

The bundle identifier (`org.deskbridge.app`), settings namespaces, Sunshine client identity, existing host-certificate pins, SSH keys, SFTP restrictions and Windows deployment records stay outside binary replacement. A normal update does not require PIN pairing again. A changed certificate or lost identity requires explicit recovery; Knot never silently deletes a pin or approves a different host.

Update continuity is a short-lived, one-use intent bound to the exact endpoint, host unique ID and existing certificate SHA256. It is consumed before validation, has a ten-minute wall-clock expiry, and only applies after a strictly newer build is observed. Dates before issuance are rejected; moving the clock backward within that window can extend elapsed expiry. The current application integration verifies the saved PC identity after relaunch; it does not automatically start a screen session, grant takeover, or resume an interrupted file transfer.

## Authenticity and ordering

`Vendor/UpdateRuntime/UPSTREAM.json` records the official release URLs, exact archive sizes, digests and complete inventories (Sparkle 253 entries; WinSparkle 47). The archives are checked offline before staging. Builds never download updater executables dynamically. Upstream license notices are distributed with each native runtime.

Mac releases require all of:

1. A pinned Ed25519 public key and HTTPS appcast.
2. `SURequireSignedFeed = true`, `SUVerifyUpdateBeforeExtraction = true`, and no expiry into an unsigned-feed fallback.
3. Developer ID signing of Sparkle's nested XPC bundles, Autoupdate, Updater.app, the framework and Knot in that order, plus normal package notarization.
4. The expected bundle identity, supported architecture and minimum macOS version.

Windows requires the pinned Ed25519 key in WinSparkle. The custom handoff additionally validates the downloaded installer's SHA256, WinVerifyTrust's selected Authenticode signer against the pinned certificate SHA256, the signed `ProductName=Knot` and `FileDescription=Knot Windows x64 Setup`, and a signed product version strictly newer than the running version. It retains a no-write/no-delete file handle through installer execution. An unsigned installer, changed publisher, wrong platform marker or downgrade is refused.

The pinned Inno compiler writes these installer strings into fixed, space-filled resource slots ([official writer](https://github.com/jrsoftware/issrc/blob/is-7_1_0/Projects/Src/Compiler.ExeUpdateFunc.pas), [loader resource](https://github.com/jrsoftware/issrc/blob/is-7_1_0/Projects/Res/SetupLdr.version.rc)). The installer-only boundary accepts at most 60/60/50 characters for product/description/version and removes trailing ASCII spaces only. Exact case-sensitive identity and strict version ordering still apply; leading whitespace, other whitespace/control characters and embedded NUL are not normalized. Installed broker metadata keeps its existing exact checks.

WinSparkle authenticates update archives, **not the appcast's presentation metadata**. The publishing tool signs both platform feeds, but WinSparkle does not validate Sparkle's signed-feed XML format. HTTPS protects delivery; the installer signature, publisher pin and signed resource/version checks remain mandatory execution gates. Do not describe Windows feed titles/release notes as independently authenticated.

`scripts/update_version.py` derives a strictly ordered integer from `VERSION`, including preview, beta, release-candidate and stable phases. Both native frameworks receive the same build number. Repackaging identical VERSION bytes is not a new update; increment VERSION for every distributable upgrade.

## Publisher setup and release preparation

1. Choose stable, platform-specific HTTPS feed URLs and an update Ed25519 key held outside the repository. Do not put a private key in a source file, artifact, command argument or uploaded CI log. Register only its 32-byte base64 public key and the Windows Authenticode leaf-certificate SHA256 in `publisher.json`.
2. Review that public configuration as source. A partial configuration fails closed. Keep signing access and feed hosting separate.
3. Build macOS with `MACOS_SIGNING_IDENTITY='Developer ID Application: …' python3 scripts/build.py --configuration release`, then use the existing notarized release packaging path. The protected `mac_signed` job imports its ephemeral certificate **before** the build; PR jobs receive no signing secrets.
4. On the approved Windows signing machine, run the documented `Build-Installer.ps1 -SigningCertificate …` path. The preview CI installer is unsigned and cannot pass the configured updater's Authenticode gate.
5. Prepare each platform feed on the approved Mac signing machine using a 0600 key file outside the repository:

   ```sh
   python3 scripts/sign_update_feed.py --platform macos-arm64 \
     --artifact /approved-release/Knot-VERSION-macos-arm64.dmg \
     --download-url https://updates.example.org/Knot-VERSION-macos-arm64.dmg \
     --key-file /secure-outside-repository/update-key \
     --output /fresh-staging/macos.xml
   ```

   For Windows use `--platform windows-x64`, the `Knot-VERSION-windows-x64-setup.exe` artifact and its HTTPS download URL. Replace VERSION with the exact source VERSION. The tool uses the pinned official Sparkle signer with an explicit key-file argument, independently verifies the archive signature against the configured public key, signs and verifies the feed, and refuses to overwrite an existing output. It never searches a user Keychain or uploads anything. The signing operator must provide already verified, appropriately OS-signed release artifacts; do not substitute preview files.
6. Review the source revision, both OS signatures/notarization, exact artifact hashes and generated signed feeds. Only then publish the artifacts and feeds atomically. No publication is performed by the implementation or ordinary package CI.

Keep the same update key across normal upgrades. Key rotation requires a separately reviewed transition and an installed-version acceptance test. Windows's certificate pin also needs an explicit old-to-new publisher transition; changing both trust anchors without a bridge strands old installations.

## Offline verification and device acceptance

`python3 scripts/tests/test_update_policy.py` exercises real Swift continuity/admission, the actual Mac relaunch latch, strict publisher configuration and version ordering, the complete upstream inventories, narrowly allowed framework links/linkage, and the official signer against fresh inert artifacts. Tampered archives and signed XML feeds fail verification. Synthetic private keys are created only in a fresh temporary directory, never printed, and deleted afterwards.

Windows update checks compile the actual helper/adapter policy and exercise version, downgrade, platform marker, digest, locked-file tamper, quoting and idle-admission cases without running the UI, native updater, registry, installer or network. These are not signed-application upgrade acceptance.

Before enabling a public publisher, test a real older-to-newer Developer ID/Authenticode-signed upgrade on both operating systems: installed and custom Windows locations, UAC cancellation, busy sessions, file-transfer drain, update failure, parent exit and image-lock release, reboot-required installer outcomes, offline restart, same-host identity retention and changed-certificate refusal. The Windows handoff deletes only its exact generated installer; its own small running helper EXE and private holding directory may remain because Windows prevents deleting a running image. There is no shell-based self-deletion or recursive cleanup of unknown content.

Mac publisher activation also requires an installation-admission mechanism that covers Sparkle paths where `shouldPostponeRelaunchForUpdate` is omitted. The pinned Sparkle delegate contract permits omission after a previous update without relaunch and for termination without relaunch. The current adapter's latch and synthetic checks cover that callback, not those other paths. Before activation, implement and verify admission for manual installation, an already-installing or resumed update, and installation without relaunch while a transfer or enrollment is active: refuse new work, allow existing work to drain, and keep installation waiting. A `willInstallUpdate` notification alone does not provide postponement. The all-null publisher configuration keeps these paths disabled in current previews.

Official integration references: [Sparkle setup](https://sparkle-project.org/documentation/), [Sparkle security settings](https://sparkle-project.github.io/documentation/customization/), [WinSparkle integration](https://winsparkle.org/guides/integrating-winsparkle/), [WinSparkle API](https://github.com/vslavik/winsparkle/blob/v0.9.4/include/winsparkle.h).

Windows online publisher activation must retain the idle-admission gate until a separately tested shutdown seam reaches the elevated QuickSetup broker while its direct PowerShell owner is hidden. A request to the hidden owner alone cannot drain or close that broker. This prerequisite does not prevent the user-initiated elevated EXE installer from using its existing exact-descendant close bridge.
