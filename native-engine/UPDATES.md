# Native Preview updates

Native Preview has its own update channel. It never consumes the production Knot/Sparkle appcast. Background checks/downloads do not interrupt a screen session. The application can install a prepared update when idle or expose an explicit restart action while a session is active. The helper waits for the old process, installs the verified package, and opens the application automatically.

**The public native publisher is currently unconfigured.** `packaging/updates/native-publisher.json` contains no feed or key. Both apps display that state and make no update requests. Configuring a real public publisher and publishing signed packages is a release operation; this implementation does not invent a trusted key, discover private keys, upload releases, disable OS security, or claim that an unsigned preview has a trusted installer identity.

## Verification contract

The build embeds the current preview version and reviewed public configuration into the Windows executable and Mac bundle. There is no environment-variable, preference or URL override. A complete publisher requires two HTTPS feed URLs and a canonical RSA-2048 public modulus/exponent (65537). The signing key is never bundled.

A feed is at most 16 KiB, containing exactly two canonical base64 lines followed by a newline: the payload and RSA PKCS#1 v1.5 SHA-256 signature. The signed ASCII payload has exactly eight newline-terminated lines:

```
KNOT-NATIVE-UPDATE-1
0.1.0-native.11
4294967307
macos-arm64
https://example.com/Knot-Native-0.1.0-native.11-macos-arm64.zip
12345
0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
1800000000
```

The numerical build packs four unsigned 16-bit version components; the example build above is illustrative and the publishing tool computes the actual value. The Windows platform is `windows-x64`, with a matching `-windows-x64-setup.exe` artifact. Clients verify signature before acting on payload fields, exact platform/version/filename, a strictly newer build, expiry (within 30 days), bounded size (512 MiB maximum), and the complete artifact's SHA-256. HTTPS URLs reject credentials, query/fragment and nonstandard ports. Redirects are refused. A feed with an older/equal version does not install anything.

RSA verification uses the operating system security APIs: [Apple SecKeyVerifySignature](https://developer.apple.com/documentation/security/seckeyverifysignature(_:_:_:_:_:)) and [Microsoft RSACryptoServiceProvider.VerifyData](https://learn.microsoft.com/en-us/dotnet/api/system.security.cryptography.rsacryptoserviceprovider.verifydata).

## Publish a feed

1. Supply a separately managed RSA-2048 release key outside the repository, with owner-only filesystem permissions. Commit only its reviewed public modulus/exponent and the two public feed URLs to `packaging/updates/native-publisher.json`.
2. Build both platforms from reviewed source. The native Mac ZIP already contains the app; Windows uses its native Inno installer. Sign/notarize the application/installer as appropriate before calculating the feed.
3. Prepare the feed using the explicit artifact and private key. The command never creates keys, searches Keychain, overwrites an existing feed, or uploads anything:

```sh
python3 scripts/native_updates.py \
  --platform macos-arm64 --version 0.1.0-native.11 \
  --artifact /absolute/path/Knot-Native-0.1.0-native.11-macos-arm64.zip \
  --url https://downloads.example.com/Knot-Native-0.1.0-native.11-macos-arm64.zip \
  --key-file /private/release/native-rsa.pem \
  --expires 1800000000 --output /absolute/fresh/native-mac.feed
```

Use a fresh real expiry no more than 30 days ahead. Publish artifacts before the feed, then test the configured signed channel on owned installations.

## Install and retain state

The apps stage each download under a fresh per-user private temporary directory. Mac validates archive member paths, duplicate names and expanded size, refuses link/special members, verifies the replacement bundle identity/version and code signature, and copies the complete candidate beside the installed app. It verifies the copy again and probes atomic exchange support before sending an exact nonce-bound READY message on an inherited, owned pipe. The parent waits asynchronously for at most 45 seconds; EOF, malformed/wrong-nonce replies, cancellation or timeout leave its existing window and app usable. The parent sends an explicit nonce-bound COMMIT only after READY. The helper then requires EOF on a separate inherited parent-lifetime pipe. This lifetime binding avoids waiting on a recycled numeric PID. EOF without a complete COMMIT never permits publication. Failed preparation writes a nonce cancellation marker and requests cooperative shutdown of only that owned helper. Cancellation waiting runs on a dedicated blocking dispatch queue through an async continuation, so an already-cancelled caller cannot skip its grace period or park a Swift cooperative-pool thread for that wait. The helper observes cancellation between preparation steps and while supervising each exact command child; it terminates and confirms that child and drains its output before acknowledging cleanup. The parent removes a started helper's stage only after both helper exit and an exact nonce-bound cleanup acknowledgement. Heavy hashing, copying and helper preparation run off the UI actor.

Mac publication uses one `renameatx_np(RENAME_SWAP)` operation. The canonical app path always names a complete old or new app; no old-to-backup rename gap exists. Filesystems without atomic exchange support fail before READY, with the existing app kept open. Directory identities are rechecked before publication. The old complete app remains at the prepared sibling path until the new app is launched; an uninterruptible filesystem operation, forced SIGKILL or abrupt interruption can retain an owned staging/partial-sibling/old-app directory, while leaving the canonical app present. Such files are deliberately retained when command/copy completion is uncertain; the app does not claim to reclaim every abrupt-termination artifact. This is atomic namespace publication, not a claim that every abrupt disk/power failure is recoverable.

Windows validates a CurrentUser-only staging DACL and uses a fresh helper filename and nonce-bound READY, COMMIT and CANCEL records for every attempt. A timeout or local failure revokes the nonce and terminates the exact launched child; stage deletion requires confirmed child exit. A late READY cannot grant permission to install. If child exit cannot be confirmed, its stage is retained and further installs are blocked in that app instance. The helper checks COMMIT and cancellation again after the exact original process ID/start time/path exits, holds a read-only package lease, invokes Inno with fixed arguments, and relaunches the fixed per-user installation after success. Hashing, copying, READY waiting and retained-child exit confirmation run outside the WinForms UI thread. Cancellation-record failure requests termination immediately without synchronously waiting on the UI thread. No shell command interpolation or security-policy changes occur.

After a terminal Windows installer failure, recovery only reopens when the fixed shipped runtime set (`Knot-Native-Preview.exe`, `KnotNativeMedia.dll`, `KnotNativePairing.dll`) still matches its pre-READY hashes. Read/no-write/delete leases cover all three during verification and the recovery launch; it does not assume rollback. A timed-out installer may still be modifying the installation, so the helper never relaunches the app in that state. Both recovery gates check cancellation again after canonical verification, so a cancelled handoff or Mac TERM request cannot reopen the app as an error-recovery side effect. Mac post-publication failure revalidates the complete canonical bundle and signature before a best-effort reopen. Real installer failure recovery still requires release acceptance.

Expired prepared manifests are discarded so fresh checks can proceed. Ordinary shutdown removes only the current model's inactive prepared stage; committed stages belong to the helper. No process scans or prefix-based temporary-directory sweeps are used. Cancellation or failure keeps a stage while helper/installer completion remains uncertain.

An update requires a writable installed Mac app (copy the DMG app to Applications first) or the standard per-user Windows installation. It does not update a running disk-image app, portable Windows executable, lock screen or another user's installation. Trust credentials and preferences live in their separate per-user stores; the updater and installer never erase them. Reconnection after relaunch remains subject to host sharing, registered-device permission, exact host identity and ordinary network availability.

The synthetic suite verifies fresh signatures, tampering, wrong key/platform/version, downgrade, expiry, limits and artifact hashes. Fresh synthetic app-bundle directories exercise actual atomic exchange, preserved canonical paths after pre-publication interruption/failure, replaced-directory identity rejection, unsupported-swap admission failure and candidate-validation failure. Owned pipes exercise exact READY, wrong nonce, EOF and timeout, plus COMMIT-before-EOF lifetime gating. Fresh explicitly owned `/bin/cat` fixtures verify Foundation child pipe EOF and shutdown from an already-cancelled caller; an owned `/bin/sleep` fixture exercises cancellation and drain of a helper command. These fixtures are isolated system processes, not installed Knot applications or installers. Injected download/clock fixtures verify expired-pending rechecks, late cancellation fencing and deletion limited to the owned stage. Windows fake child adapters verify cancellation-before-kill and confirmed-exit-before-cleanup; nonce fixtures verify cancellation wins over a late READY/COMMIT. Injected install adapters exercise committed shutdown ownership and unconfirmed-helper state, while the recovery gate used by the helper itself covers cancellation before/during verification, installer timeout and terminal failure. Fresh runtime fixtures mutate each executable/DLL independently, reject missing DLLs and verify the read leases prevent mutation. Archive inventory negatives cover traversal, links, duplicate paths and expanded-size limits. These tests never launch an existing app, read its preferences, or inspect user files. Real installer handoff, OS prompts, public feed availability and two-device update/reconnection need release/device acceptance; source tests alone do not prove them.
