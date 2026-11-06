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

The apps stage each download under a fresh per-user private temporary directory. Mac validates archive member paths, duplicate names and expanded size, refuses link/special members, verifies the replacement bundle identity/version and code signature, and copies the complete candidate beside the installed app. It verifies the copy again and probes atomic exchange support before sending an exact nonce-bound READY message on an inherited, owned pipe. The parent waits asynchronously for at most 45 seconds; EOF, malformed/wrong-nonce replies, cancellation or timeout leave its existing window and app usable. The parent closes only after READY.

Mac publication uses one `renameatx_np(RENAME_SWAP)` operation. The canonical app path always names a complete old or new app; no old-to-backup rename gap exists. Filesystems without atomic exchange support fail before READY, with the existing app kept open. Directory identities are rechecked before publication. The old complete app remains at the prepared sibling path until the new app is launched; interruption can retain an owned staging/old-app directory, while leaving the canonical app present. This is atomic namespace publication, not a claim that every abrupt disk/power failure is recoverable.

Windows validates a CurrentUser-only staging DACL, holds a read-only package lease, waits for the exact old process ID/start time/path, invokes Inno directly with fixed arguments, waits for successful installation, and relaunches its fixed per-user install path. No shell command interpolation or security-policy changes occur.

An update requires a writable installed Mac app (copy the DMG app to Applications first) or the standard per-user Windows installation. It does not update a running disk-image app, portable Windows executable, lock screen or another user's installation. Trust credentials and preferences live in their separate per-user stores; the updater and installer never erase them. Reconnection after relaunch remains subject to host sharing, registered-device permission, exact host identity and ordinary network availability.

The synthetic suite verifies fresh signatures, tampering, wrong key/platform/version, downgrade, expiry, limits and artifact hashes. Fresh synthetic app-bundle directories exercise actual atomic exchange, preserved canonical paths after pre-publication interruption/failure, replaced-directory identity rejection, unsupported-swap admission failure and candidate-validation failure. Owned pipes exercise exact READY, wrong nonce, EOF and timeout. Archive inventory negatives cover traversal, links, duplicate paths and expanded-size limits. These tests never launch an existing app, read its preferences, or inspect user files. Real installer handoff, OS prompts, public feed availability and two-device update/reconnection need release/device acceptance; source tests alone do not prove them.
