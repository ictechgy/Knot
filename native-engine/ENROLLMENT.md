# Native short-code enrollment v2

Status: implementation contract for native.5. Enrollment provisions one existing
v1 invitation; it never becomes the media connection. The legacy pinned TLS
protocol in PROTOCOL.md remains the screen/input transport.

## User authorization and lifetime

Windows explicitly starts sharing with the explanation that one Mac which knows
the displayed eight-digit number may connect during the next two minutes. This
is the local authorization for that one connection. The Mac selects an unverified
LAN candidate, enters the number, and connects. The authenticated enrollment path
does not require a second Windows approval. A legacy long-invitation run continues
to require its existing explicit Windows approval.

- Eight ASCII decimal digits, leading zeros allowed, generated without bias using
  the OS CSPRNG. Never log, advertise, persist or silently read/copy the number.
- A fresh public 16-byte slot ID, 120-second monotonic lifetime, at most five
  failed or aborted attempts and one active enrollment worker. Each attempt has
  at most ten seconds total, bounded by the slot's remaining lifetime.
- A successful authenticated ClientConfirm consumes the slot and atomically
  creates a new 32-byte T2 token with a 30-second monotonic media-claim deadline,
  bound to the exact RunIdentity and slot. Only the later valid pinned-TLS T2
  claim applies the local preauthorization and may initialize capture/input.
- T2 must be distinct from the original legacy T1. Never flip a global approval
  flag on an old invitation. Changing to legacy mode stops/cancels enrollment and
  creates a distinct fresh legacy run. Stop cancels the slot, outstanding sockets,
  temporary keys and any unclaimed grant, and retains existing input revocation.
- Saved pairing, automatic reconnect and persistent credentials remain outside
  this iteration. Display temporary authorization honestly.

## Crypto dependency and ABI

Use the same pinned BoringSSL implementation on both platforms:

```
commit ed9209cff8b5a2fbc6c10050f29b3355048bda85
tree   81d696d1f8cbc5a4b635bac55105a6f97b7a538c
```

The executor must record the SHA256 of the actual downloaded archive and the
vendored file manifest. Preserve LICENSE and all applicable upstream support-code
notices in source and distribution. This revision's root license is Apache-2.0;
support-code notices include BSD licenses. No claim of an audit or FIPS validation
of Knot's integration is implied.

Build the crypto-only static target with C++17 and OPENSSL_NO_ASM, behind an owned
small C ABI. Mac links it statically via CKnotPairing; Windows exposes that same
implementation through an owned DLL resolved by absolute application path with
dependency lookup restricted to the application directory and System32. Never
load an ambient OpenSSL library, invoke an external remote-desktop engine or fetch
crypto code during application startup. No provider/model or user state is a
cryptographic input.

## Enrollment TCP wire

The default enrollment port is 48632, separate from media TLS on 48631.

```
preamble = 8 bytes: "KNOTP2\0\0"
frame    = u8 type | u32BE length | payload
maximum payload = 4096 bytes
```

| Type | Payload |
| --- | --- |
| 0x01 ClientHello | slot ID16 followed by SPAKE2 pA32; exactly48 bytes |
| 0x02 ServerHello | slot ID16 followed by SPAKE2 pB32; exactly48 bytes |
| 0x03 ClientConfirm | nonce12, AES-GCM ciphertext, tag16; max512 bytes |
| 0x04 ServerOffer | nonce12, AES-GCM ciphertext, tag16; max4096 bytes |
| 0x7f Error | fixed small error enum; no exception, number, token or key |

Unknown kinds, wrong lengths/order/slot, malformed UTF8/JSON, extra/duplicate keys,
timeout, bad confirmation or reused crypto context terminate the attempt.

Mac is SPAKE2 Alice; Windows is Bob. Exact identities are the following ASCII
strings, followed by a zero byte and the raw slot ID:

```
KnotNative/Enrollment/v2/client
KnotNative/Enrollment/v2/server
```

The public messages are exactly32 bytes; key material is at most64 bytes.
SPAKE2_process_msg success alone does NOT authenticate the number. Derive:

```
context = SHA256("KnotNative/Enrollment/v2" || slotID || pA || pB)
PRK     = HKDF-Extract-SHA256(salt=context, IKM=SPAKE2-key)
Kclient = HKDF-Expand(PRK, "KnotNative/Enrollment/v2/client-confirm", 32)
Kserver = HKDF-Expand(PRK, "KnotNative/Enrollment/v2/server-offer", 32)
AAD     = context || frame-type
```

Use AES-256-GCM with a fresh random96-bit nonce, separate directional keys and at
most one seal/open per direction/context. A failed authentication invalidates
the context. Zeroize owned temporary key buffers when the context is destroyed.

ClientConfirm strict JSON has exactly `v`, `slot`, `name`, `permissions`:
v=2; slot is canonical unpadded base64url16 bytes; name uses existing1..64 UTF8
byte limits and rejects Unicode control/format characters and line/paragraph
separators; permissions is exactly `screen,input` or `screen,input,files`.
Native.9 requests the latter and carries that scope through the issued grant;
file access also requires the Windows folder's local consent and media Hello
file opt-in. A screen-only grant cannot mint a file capability. This name-only
display policy does not restrict ordinary RTL letters or remote text input.
Only after its tag and semantic fields validate may Windows mint T2.

ServerOffer strict JSON has exactly `v`, `slot`, `grant`, `invitation`, `ttlMs`:
v=2; slot matches; grant is a fresh canonical base64url16-byte ID; invitation is
the full existing v1 invitation carrying T2 and the exact server DER fingerprint;
ttlMs is an integer1..30000. Plaintext is bounded to3072 UTF8 bytes. The Mac must
require the authenticated invitation's address to match the selected enrollment
IPv4 target, parse it with the existing strict parser, then create a NEW media
TLS connection using the full exact pin and existing OS certificate checks.

Valid ServerOffer authentication is reciprocal key confirmation. An attacker
which transparently relays PAKE messages can neither read the invitation nor
terminate the later pinned media TLS. Do not promote the provisioning socket to
media or transfer an invite outside authenticated encryption.

## Private LAN discovery

Discovery is public candidate information, never authentication. An owned bounded
UDP query/reply on48633 may be used instead of installing a Bonjour service.
A query is exactly24 bytes: ASCII `KNOTD2\0\0` followed by a fresh16-byte nonce.
A reply is at most1024 UTF8 bytes with exact JSON keys `v`, `nonce`, `slot`, `name`,
`port`: v=2, matching canonical base64url nonce16, slot16, a1..64 UTF8-byte
control-free claimed name and port48632. Replies contain no secret.
The client uses the observed reply IPv4 as the target, validates private RFC1918
or Tailscale100.64/10 ranges, rejects stale/oversize/unsolicited/duplicate malformed
data and caps the candidate count. The server rate-limits responses and rejects
public sources. No number, token, invitation, certificate private key or saved
credential is advertised. Neither a name nor IP is a verified peer identity.

LAN broadcast is not Tailscale discovery. A secondary explicit private/Tailscale
IPv4 entry may issue the same bounded unicast discovery query. Do not claim
automatic cross-tailnet discovery or resolve arbitrary public hostnames.

Visual fixtures use inert discovery/enrollment adapters; rendering must not open
UDP/TCP, create certificates, inspect current input settings or read clipboard.

## Required validation

- Matching/wrong number, role reflection, changed slot/message, corrupt tag,
  repeated process/seal/open, malformed bounds and all deadline/attempt limits.
- Failures create zero invitations/grants/media/input instances.
- Valid enrollment -> new T2 -> existing fresh pinned TLS; expired/reused/wrong
  T2, bad pin, Stop races, legacy T1 cross-claim and stale run callbacks fail.
- Same pinned crypto source and ABI on both platforms; upstream SPAKE2 checks,
  HKDF/AEAD known answers, source/license/package binding and actual wrapper tests.
- No production secret/code is logged or placed in discovery. Existing one-reader,
  one-sender and media/input resource limits remain unchanged.

References: pinned upstream
[LICENSE](https://boringssl.googlesource.com/boringssl/+/ed9209cff8b5a2fbc6c10050f29b3355048bda85/LICENSE),
[SPAKE2 API](https://boringssl.googlesource.com/boringssl/+/ed9209cff8b5a2fbc6c10050f29b3355048bda85/include/openssl/curve25519.h),
[build](https://boringssl.googlesource.com/boringssl/+/ed9209cff8b5a2fbc6c10050f29b3355048bda85/BUILDING.md).
