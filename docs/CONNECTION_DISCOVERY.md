# Address discovery and QR entry

Version: preview.9. These are address-entry conveniences; PIN pairing, exact saved certificate checks and independent SSH trust remain authoritative.

## Production flow

An unpaired production Mac launch starts a ten-second Bonjour search for `_nvstream._tcp` and `_nvstream-tcp._tcp` in `local.`. Users select a PC from its name/address row. Foundation NetService resolves metadata without opening TCP connections to unvalidated hosts; no subnet/port scanner is added. At most16 service objects,32 rows and8 private IPv4 hints per service are retained. Default Sunshine HTTP port47989 is required; public/DNS/IPv6/APIPA/incompatible-port candidates do not become rows. Search can be stopped/refreshed. Model creation, offline checks and synthetic visual fixtures do not start discovery. Tailscale multicast enumeration is not implemented.

Windows generates a QR or link containing a name and up to8 private IPv4 addresses, selected address first. Its pinned MIT generator runs locally. The Mac supports image import, explicit video-camera scan, link entry and `deskbridge://connect` deep links. A preview lets the user choose an address before normal PC verification/PIN pairing. Import never supplies certificates/SSH keys, resets saved trust, auto-pairs or configures files. Model guards re-check active screen/file work at import and selection. Stored single-PC certificate pins remain authoritative on a new address.

Automatic Mac setup-address suggestions also exclude169.254/16 APIPA, deduplicate and return at most8 addresses; the UI reports omitted suggestions. Selection reserves one address for each present range (10/8, 172.16/12, 192.168/16, 100.64/10) before filling remaining slots, then displays numeric IPv4 order. DNS-SD applies the same selection to its full bounded callback. Previously shown addresses take priority within a range; a new range may replace an excess address from another range. A directly entered link-local address remains an advanced exception in the endpoint/setup/QR contract for deliberately configured local links. QR/link address order never proves reachability. DNS-SD candidates still exclude APIPA even if manually entered endpoints allow it. A service's later IPv4 DNS-SD callback is merged into its earlier metadata instead of dropping the service because IPv6 arrived first.

## Link contract

```text
deskbridge://connect?v=1&name=Synthetic%20PC&address=192.168.1.20&address=100.80.10.20
```

- Version 1 has exactly one `v=1`, one `name`, and 1–8 distinct canonical private IPv4 `address` fields. Version 2 additionally requires exactly one `platform=windows`, `platform=macos` or `platform=linux`. No other fields, credentials, port, fragment or non-root path are accepted.
- New Windows, Mac and Linux host invitations use version 2 with their explicit OS. Each client rejects invitations for another role before staging an address. Legacy version 1 remains supported in the existing Windows-on-Mac and Mac-on-Windows flows; it does not establish the host OS or identity.
- Name: at most64 UTF-16 units /128 UTF-8 bytes, without leading/trailing whitespace, controls or Unicode format characters. Query values are percent encoded.
- Whole link: at most1536 UTF-8 bytes; only outer pasted whitespace is trimmed. Hints are not identity proofs or expiring invitation credentials.
- QR image: at most8MB, one frame,8192px maximum edge /16 megapixels before full decode. The Mac picker and decoder share an explicit PNG/JPEG/HEIC/TIFF/BMP content-type allowlist; renaming another format does not permit decoding it. Only bounded ordinary files are read; links, directories and FIFOs are refused without waiting for a writer. Image reading/decoding runs away from the main actor and duplicate image requests are disabled while it runs. Exactly one decoded QR is required. No imported image is stored.
- Camera is video only, starts after the scan sheet and permission grant, and stops/detaches on dismissal. Old output objects are rejected after sessions change. No frames are stored or sent.
- Hardened-runtime app signing includes only the camera entitlement. Both the local build and staged release inspect the actual signed entitlement payload and reject a missing or additional entitlement; runtime camera access still requires user permission.

## Packaging and provenance

`Vendor/QRCodegen` pins eight unchanged C# sources of Net.Codecrete.QrCodeGenerator v2.0.7 at `f414417201fa7c639463730fe41099528f8026cb`, an MIT port of Project Nayuki's generator. `UPSTREAM.json` records hashes; `NOTICE` retains both copyright notices and full MIT terms. The offline builder verifies the exact source set, compiles Framework4.8 and embeds the DLL/notice. No NuGet package or external QR service is needed at runtime. Inno installs the notice; Mac bundles it in the license menu. A raw developer folder without the DLL explicitly offers links only; a present-but-failing DLL is an error.

## Verification boundary

Offline checks cover malformed links, endpoint/query policy, active-work guards and saved trust retention; actual sockaddr parsing, real Core Image decoding, and the Windows C# generator's BMP decoded by the actual Mac importer. No checker calls production App.main, scans LANs, opens cameras/clipboard or reads existing user preferences/files.

Real Mac permission/advertisement reachability, Windows dialog/PNG save, camera hardware/permission changes, deep-link association and DPI remain device acceptance. Guest-network isolation/mDNS filters can prevent discovery; QR/link/manual entry remain available. The current format assumes default Sunshine ports.

References: [Apple Bonjour](https://developer.apple.com/documentation/Foundation/bonjour), [local network privacy](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy), [camera metadata](https://developer.apple.com/documentation/avfoundation/avcapturemetadataoutput), [pinned generator](https://github.com/manuelbl/QrCodeGenerator/tree/f414417201fa7c639463730fe41099528f8026cb).
