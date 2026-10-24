# Packaging and public releases

The repository builds a Mac app/DMG/ZIP, a single-file Windows quick-setup EXE, a separate Inno installer, a developer portable ZIP, exact corresponding source and SHA256 checksums. Packaging does not publish anything. The helper is GPL-3.0-only; Sunshine is downloaded separately from its official release after a user action, not redistributed inside Knot.

## Local preview

Each Mac/source packaging invocation writes a fresh version/mode/time/commit directory under `dist/release`. Use the `output` field in `evidence/latest-package.json` and that directory's `SHA256SUMS` to select the complete matching artifact set. Retained earlier directories are separate builds; do not combine them into a release.

On Apple Silicon/macOS26+ with Xcode27:

```sh
git add Sources host packaging scripts VERSION README.md DESIGN.md INSTALLATION.md docs .github
git commit -m "Prepare installation packages"
python3 scripts/build.py --configuration release
python3 scripts/package_release.py --mode preview
```

The working tree must be committed and the complete build/check source manifest must still match, including added and removed files. Packaging also checks the entire built app's content and executable modes against the successful build record, then verifies the staged copy before signing. Replacing the binary or building without either check suite invalidates packaging. The source archive uses that exact HEAD. Packaging only reads this project and the new build artifacts; no app preferences, keychain or UI is read. If a restricted runner cannot create a disk image, preserve the failure and use `--mac-format zip` for the local preview; the CI job still requires a DMG.

The Mac lifetime checks execute the tested build helper before Developer ID re-signing. The package manifest records its tested SHA256 and the packaged helper SHA256 separately, along with the release signing transformation. Preview helpers must remain byte-identical. Release packaging verifies the re-signed helper and nested app signatures, entitlements and dependencies; recording both digests does not claim that post-sign bytes ran the lifetime tests or independently prove that only signature bytes changed.

The default build configuration is `release`: Swift `-O` for the engine, core, app and offline checker, without DEBUG or enable-testing. Preview/release packaging selects the signing policy independently. A local `--configuration debug` build uses separate caches and may be packaged as a preview, but signed release mode refuses it. Configuration is recorded in the completion and package manifests. Keep performance comparisons on the optimized configuration.

Packaging compares the source manifest to the contents of the actual `git archive HEAD`, before creating packages and again before checksums. Ignored, untracked or staged-only compiler/resource inputs are refused even if present before the build. Archive attributes that omit or substitute checked inputs also cause refusal. Commit the exact inputs, remove unintended ignored sources, and rebuild; a clean porcelain status alone is insufficient.

Required root inputs LICENSE, INSTALLATION.md and VERSION are always included even if locally ignored. Finder .DS_Store files under scanned compiler/resource roots also block packaging; remove unintended metadata and rebuild. Fixture Git processes isolate inherited routing/global configuration and default user/system ignore/attribute files, using plumbing commits in new temporary repositories; production Git configuration, HOME and project privacy hooks are not changed. After preflight passes, packaging invalidates its previous SHA256SUMS and latest-package.json before writing new payloads; later failures require discarding incomplete outputs.

The quick-setup helper has a native x64 Win32 outer executable and an embedded Framework4.8 managed helper. Cross-builds use an explicit Zig0.17.0 native compiler, .NET SDK Roslyn compiler and official Microsoft.NETFramework.ReferenceAssemblies.net48 1.0.3 package. Zig's official archive URL, size and SHA256 are pinned per platform in `packaging/windows/ZigDependency.json`. No compiler/runtime is downloaded by the local build script. Build hosts need these inputs; Windows11 users need neither SDK nor Python. Runtime dependencies remain built-in .NET Framework4.8 and PowerShell. Follow [Microsoft's reference assembly build guidance](https://learn.microsoft.com/en-us/dotnet/framework/migration-guide/reference-assemblies).

```sh
python3 scripts/build_windows_launcher.py --dotnet /path/to/dotnet --compiler /path/to/sdk/Roslyn/bincore/csc.dll --references /path/to/references/build/.NETFramework/v4.8 --native-compiler /path/to/zig
python3 scripts/test_windows_launcher.py --dotnet /path/to/dotnet
python3 scripts/package_release.py --mode preview --windows-launcher build/windows/Knot-Windows.exe
```

Run the ordinary completed Mac build first and keep both build manifests on the same committed source snapshot. Packaging refuses a helper whose exact source manifest or executable hash changed and requires successful Windows-check evidence bound to those same inputs. The Inno builder runs the helper checks after optional helper signing and before invoking its compiler; a failed check stops packaging. Offline checks inspect the outer PE and inner managed payload, embedded hashes and argument validators; they never invoke Windows Main, extract a production runtime payload, open the UI or configure services. Native import/metadata inspection and fresh argument/QR fixtures do not prove actual Windows loader behavior. Cross-compilation and these checks are not Windows execution acceptance.

Before any CLR activation, the native bootstrap restricts DLL search, locks its original image and path ancestors against replacement, verifies the embedded managed helper's SHA256 and creates a fresh ACL-protected stage. It launches the exact staged helper with that stage as working directory. Elevated children use an OS-derived environment allowlist; the normal UI uses a token-derived user environment with CLR/profiling hooks and module/temp/system overrides removed. Elevated work stages under protected Program Files; ordinary UI work stages under the user's OS-known local temporary directory. Child TEMP/TMP use stable OS-derived temporary locations, not the disposable payload stage. Native create-new refuses an existing path. Cleanup removes only exact generated files and never recursively follows links. The managed helper then validates each embedded script/resource hash. Both layers reject unsupported architectures/OS versions. The public EXE has no CLR import; its metadata validator permits supported system KnownDLLs and pinned UCRT API-set contracts. The inner helper remains IL-only AnyCPU without Prefer32Bit and is launched only after the native gate. Actual Windows loader acceptance remains pending.

The original public EXE is also the UAC broker. It accepts only bounded known operations and validated public data, creates its own protected administrator stage and executes its own embedded backend scripts. Sunshine's downloaded MSI is copied into that stage and size/hash checked again against the embedded pin before fixed `System32` msiexec runs. Inno installs this self-contained EXE, documentation, icon and license notices; it does not install redundant loose executable scripts/DLLs. Uninstall revokes access through that same native EXE broker. Raw developer source folders retain an explicitly warned manual-script route. That GUI route reports only that its command exited; it cannot attest completion or automatically save a connection reply. Use the distributed EXE for verified completion and connection-file saving. Keep the public EXE to reopen setup; revoke dedicated SFTP access before discarding it if no longer needed.

Windows11 x64 with a .NET SDK, Python, .NET Framework4.8 developer references, the pinned Zig0.17.0 compiler and Inno Setup7.1.0:

```powershell
.\host\windows\tests\Test-SetupContract.ps1
.\host\windows\tests\Test-SetupFailureExit.ps1
.\host\windows\tests\Test-FirewallPolicy.ps1
.\host\windows\tests\Test-SetupFilesystem.ps1
.\packaging\windows\Build-Installer.ps1 -Compiler 'C:\path\to\ISCC.exe' -NativeCompiler 'C:\path\to\zig.exe'
```

No Windows service/account/firewall changes are made by those pure checks or compiler calls. Actual setup actions run only when the user presses the corresponding GUI button.

Test-SetupFilesystem requires an elevated Windows PowerShell 5.1 or PowerShell 7 session only to create administrator-owned ACLs on a new random temporary fixture. It writes and replaces a Prepared/Validated record and checks that nonempty-directory deletion refuses without a prompt. It does not configure OpenSSH or inspect existing setup state. Both Windows shells run these checks in CI; they remain unexecuted on the Mac agent.

The helper also compiles the pinned Framework-compatible MIT C# QR generator from `Vendor/QRCodegen`, verifies the exact vendored source set/hashes, and embeds its DLL plus dual-copyright notice. `--windows-launcher` packages the matching DLL into the developer portable ZIP; without it the raw developer GUI explicitly offers links only. Run `scripts/test_windows_launcher.py --dotnet /path/to/dotnet --mac-checker build/release/DeskBridgeAppChecks` on Mac to encode a fresh synthetic bitmap with the actual Windows DLL and decode it through the actual Mac importer. This neither opens a camera nor configures Windows. See [connection discovery](CONNECTION_DISCOVERY.md) for protocol and permission boundaries.

## GitHub Actions

Push this source to your own repository and enable Actions. **Build install packages** creates downloadable artifacts on a tag, pull request or manual run. It uses pinned action commit SHAs, a macOS26 arm64 runner and Windows2025 compiler runner. Tag names must match VERSION. A tag produces preview artifacts; it does not automatically publish or claim signing.

- Mac/source artifact: DMG, ZIP, optional Windows quick-setup EXE, Windows developer portable ZIP, source.tar.gz, INSTALLATION.md and SHA256SUMS.
- Windows artifact: setup.exe, quick-setup EXE, WindowsRuntime-NOTICE.txt, exact Knot-Windows.build.json/checks.json records and WINDOWS-SHA256SUMS covering all five files. The default EXEs are unsigned. The build record includes the selected managed compiler and Framework reference-assembly SHA256 values. The workflow verifies the pinned Zig Windows archive's size/SHA256 and extracts it under RUNNER_TEMP; it does not install a native compiler globally or modify PATH.
- No contents-write permission or release-creation step is included.
- The Mac can build the quick-setup EXE and run pure metadata/resource/argument checks. The separate Inno installer requires Windows compiler acceptance; successful CI compilation does not prove actual installer or remote-session behavior.

## Mac signed distribution

Create a Developer ID Application certificate and enable notarization in your own Apple Developer account. Create a protected GitHub environment named **macos-signing**, restrict its deployment branches to the repository default branch, and require a trusted reviewer. Store the following as **environment secrets**, never repository-wide secrets:

| Secret | Purpose |
| --- | --- |
| MACOS_CERTIFICATE_P12_BASE64 | Exported signing certificate plus private key |
| MACOS_CERTIFICATE_PASSWORD | P12 password |
| MACOS_SIGNING_IDENTITY | Full Developer ID Application identity |
| APPLE_ID | Apple ID used for notarization |
| APPLE_TEAM_ID | Developer team |
| APPLE_APP_PASSWORD | App-specific notarization password |

Run the workflow manually with **sign_macos=true** from the default branch. The separate mac_signed job checks that branch before any checkout/build and requires the protected environment. Preview jobs have no signing secrets. The temporary CI keychain is deleted in an always cleanup step. It signs and notarizes the app ZIP, staples the app, builds/signs/notarizes/staples the DMG, and verifies both tickets. A missing identity/profile or failed notarization fails the job; it never falls back to a preview while retaining a signed-release label.

For a local authorized release with a separately configured notarytool profile:

```sh
python3 scripts/package_release.py --mode release --identity 'Developer ID Application: YOUR IDENTITY' --notary-profile YOUR_PROFILE
```

The agent does not create certificates, access an existing keychain or bypass Gatekeeper.

## Windows signed distribution

Use an organization-approved Authenticode certificate/token and timestamping provider. On a trusted Windows signing machine, provide explicit compiler paths and certificate thumbprint to `Build-Installer.ps1 -NativeCompiler C:\path\to\zig.exe -Compiler C:\path\to\ISCC.exe -SigningCertificate THUMBPRINT`. It builds the exact-source helper, verifies its unsigned build hash, signs the outer helper, updates the manifest with the signed final hash and unsigned predecessor, then builds/signs the installer. It requires Valid status, the selected signer certificate and a verified timestamp certificate; a Valid signature without a timestamp fails. Tracked source scripts and embedded payload bytes remain unchanged; no signed-source mutation occurs. Hardware-backed signing providers may require adapting that explicit signing step. No certificate is bundled or automatically discovered.

A signed installer does not guarantee immediate SmartScreen reputation. The outer helper's signature covers embedded payload bytes, but does not create individual Authenticode signatures on PowerShell scripts. This build embeds unsigned exact-source scripts. Corporate AllSigned policy therefore requires separately signed scripts and an organization-approved manual distribution. Those policies are not disabled. The helper requests RemoteSigned only for its own process, never sets machine/user policy and never uses Bypass.

## Development prereleases

Development packages may be published as an explicitly marked **GitHub prerelease** before real-device validation is complete. Select the complete artifact set from one successful CI source snapshot, record its commit and workflow run, and keep the binaries, exact corresponding source, notices, installation guide and combined checksums together. Never relabel, rebuild or mix artifacts from different commits while presenting them as that validated build.

State the supported OS/architecture, actual signing and notarization status, known disabled features and pending runtime checks in the release notes. Ad-hoc-signed/unnotarized Mac and unsigned Windows packages must retain the preview label; do not describe them as signed stable releases or ask users to disable system security. Preview 0.2.0-preview.16 keeps automatic virtual-display installation disabled pending driver safety review. Its public download entry point is the [development prerelease](https://github.com/ictechgy/Knot/releases/tag/v0.2.0-preview.16).

Prefer the Mac DMG and Windows Inno setup EXE as the normal download paths. The Windows installer provides Start menu shortcuts and uninstall support, requests UAC for installation, and opens its helper as the original user. Keep the no-install quick-setup EXE and developer portable ZIP as optional alternatives. The workflow creates artifacts but does not publish a release automatically.

## Stable release gate

Before publishing a stable release, complete the real-device checklist in [VALIDATION.md](VALIDATION.md) plus installation coverage: clean Windows11 Home, existing SSH refusal, UAC cancellation, unsigned/signed policy behavior, Sunshine download corruption, install/reinstall, Mac drag installation, file exchange/fingerprint confirmation, upgrade, and uninstall with active SFTP sessions. Confirm rollback/revocation and retention of shared files. Complete the signed distribution steps above and report any remaining feature limits accurately.

For both prereleases and stable releases, keep signing credentials and local advisor evidence out of public artifacts. Do not advertise Chrome performance/security superiority without measurements.

Pinned build-tool provenance: [Inno Setup7.1.0 official release](https://github.com/jrsoftware/issrc/releases/tag/is-7_1_0), [GitHub runner labels](https://github.com/actions/runner-images), [Sunshine release](https://github.com/LizardByte/Sunshine/releases/tag/v2026.914.233613), [Apple notarization](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution), [PowerShell execution-policy scopes](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_execution_policies), [.NET SDK official release metadata](https://builds.dotnet.microsoft.com/dotnet/release-metadata/8.0/releases.json), [.NET Framework reference assemblies](https://www.nuget.org/packages/Microsoft.NETFramework.ReferenceAssemblies.net48/1.0.3). Local cross-build on 2026-10-19 used SDK8.0.426 with its published SHA512 and the reference package's SHA256 recorded in build evidence. These are build tools, not bundled app runtimes.

The native compiler pin comes from [Zig's official download index](https://ziglang.org/download/index.json). Retain the checked `ZigDependency.json`, native/managed compiler argv and output hashes with the exact source snapshot. The Windows workflow and signing paths require actual Windows runtime acceptance before a stable release; documenting them is not evidence they executed successfully.

Native Windows runtime notices from the pinned Zig distribution are retained under `Vendor/WindowsRuntime`, embedded in the quick-setup EXE, installed by Inno and copied beside local preview packages. These unmodified MIT/ZPL notices cover possible compiler/runtime objects conservatively; the compiler itself is not shipped.

The launcher build records the selected native compiler executable SHA256. Matching its version string alone does not authenticate that executable; local/signing hosts must independently verify their toolchain archive and retain that evidence. CI verifies its pinned archive. Runtime notice source hashes are checked before building, and Windows installer output includes `WindowsRuntime-NOTICE.txt` beside the quick EXE.

`WINDOWS-SHA256SUMS` covers the installer EXE, quick-setup EXE, `WindowsRuntime-NOTICE.txt`, `Knot-Windows.build.json` and `Knot-Windows.checks.json`. Windows CI uploads the entire `dist/release` directory, including those records. Vendored files disable checkout line-ending conversion to preserve upstream digest pins on Windows. Other text files can use Git's Windows checkout line endings; the build manifest hashes the actual checkout bytes, so comparisons with a source tar archive must account for that conversion.

The managed broker always requests a fixed `operation-success` receipt in its fresh protected payload stage. The backend creates it with CreateNew only after a completed operation, immediately before success exit. Zero process status without that empty ordinary receipt fails closed, including Windows PowerShell `-File` Ctrl+C exits. No caller-supplied receipt path or request field exists.

Every Inno uninstall dispatches the fixed broker `DisableFiles` operation, even when recovery metadata is missing. Removal continues only after the broker attests revoked or read-only verified-inactive access. Unknown state, leftover resources without trusted metadata, or an unrelated running OpenSSH deployment can block removal. The helper stays installed for administrator review; it never adopts, deletes or revokes foreign SSH resources.
