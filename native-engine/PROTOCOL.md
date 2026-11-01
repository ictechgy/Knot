# Knot Native Engine v1 research contract

Status: experimental vertical slice; independent of Sunshine, Moonlight and Glimmer. Windows11 x64/Home logged-in SDR primary desktop host -> AppleSilicon macOS26+ viewer. No prelogin, lock/UAC secure desktop, audio, files, virtual monitor, updater, saved pairing or automatic reconnect in this first slice. Existing product remains unchanged for comparison.

## Transport and trust

One full-duplex TLS/TCP connection, port48631 by default; TLS1.2 minimum, OS cryptographic libraries only. TCP is a deliberately simple proof transport, not a claim of Wi-Fi media optimization. Separate directions allow server video writes concurrently with client input writes. One sender and one reader per TLSstream. Strict bounded messages; stalled handshake/read/write ends the connection.

Host creates a fresh self-signed server-auth certificate for each sharing run (subject/SAN DNS `knot-native`, SHA256 over exact DER). No existing certificates, services, accounts, settings or preferences are adopted. Any OS key-container resources created by this run have random names and owned cleanup. No permanent peer state in v1.

Host explicitly clicks Share, creates 32random invite-token bytes with CSPRNG, valid120seconds. Invitation is `knot-native:v1:` followed by unpadded base64url UTF8 JSON with EXACT keys `v`, `address`, `port`, `certificateSHA256`, `token`. v=1; address canonical private IPv4 RFC1918 or Tailscale100.64/10 only; port1..65535; certificateSHA256=64lowercasehex; token=43base64url chars decoding to32bytes. Invitation max2048UTF8bytes, no URL lookups or implicit connection. It is a secret, shown/copied only on user action, never logged. Native invitation is separate from legacy address-only links. Viewer reviews target/pin and explicitly connects using exact DER pin; TLS proves possession. Verify certificate validity/server purpose with the pinned certificate as the sole anchor; expected DNSname `knot-native`. No accept-all callback, TOFU reset or silent fallback.

Client sends hello over authenticatedTLS, containing EXACT JSON keys v=1, token (same32bytebase64url), name (1..64UTF8bytes, no controlcharacters). Host rejects untrusted/public source IPv4, wrong/expired/reused token before any approval UI, capture or input. Constant-time comparison for equal-length decodedtoken. At most one pending invitation claim; atomic one-use claim before approval, userexplicitApprove within60seconds, reject/timeout consumes invitation. Sharing/capture begins only after approval and media initialization. Stop, close or disconnect releases all injected keys/buttons and destroys only owned resources. New connection requires a new invitation; no hidden saved trust or automatic reconnect. This temporary trust model is explicitly displayed by both apps.

## Binary frame envelope

Every message: u8kind + u32BEpayloadLength + exactly payloadLength bytes. Header5bytes. Unknown kinds, zero/oversize forbidden payloads, invalidUTF8/JSON, duplicate or extraJSON keys, out-of-order handshake and trailing data in typed packets fail closed. Never allocate from unchecked network lengths.

Client->host:
- 0x01 Hello: UTF8 JSON above, 1..4096bytes, first only; ten-second handshake/hello budget.
- 0x20 PhysicalKey: 4bytes = u8action(0up,1down), u16BEscanCode(1..255), u8extended(0/1). Max128retained pressed keys; no global hooks. ScanCodes are Windows set1.
- 0x21 Text: strict UTF8 1..1024bytes; committed text only, max512UTF16units; rejectNUL/invalidsurrogates. No arbitrary commands.
- 0x22 Pointer: 5bytes = u8action(0move,1leftdown,2leftup,3rightdown,4rightup,5middledown,6middleup), u16BEx,u16BEy. Coordinates normalized0..65535 over full captured rectangle; host maps to physical capturedmonitor then desktopvirtualscreen for SendInput.
- 0x23 Wheel: 8bytes = i32BEvertical,i32BEhorizontal, each -1200..1200.
- 0x24 ReleaseAll: empty, releases this session's accepted injected input only.
- 0x25 Heartbeat: empty, clientevery2s; ten-second inactivity timeout.

Server->client:
- 0x02 Ready: strict JSON exactkeys v=1, codec="h264-annexb", width,height (even,16..1920/1080), fps(1..60), bitrate(1_000_000..40_000_000), hardwareEncoder=true. No ready before approved authenticated session + successful native media initialization.
- 0x03 Video: u64BEsequence(start1, strictlyincreasing), u64BEcaptureMonotonicMicroseconds(hostclock; NOT comparable to clientclock withoutsync), u8flags(bit0clean/IDR, otherbits0), then nonempty AnnexB H264 accessunit. Total17..4_194_304bytes, data startsafter17. Every keyframe must provide parameter sets when available; decoder waits for validSPS/PPS+IDR. Reject malformed NAL structure/length; shared v1 limits are128NALs peraccessunit, atmost8SPS and8PPS, eachparameter NAL atmost65_536bytes. Enforce these onproducer/cacheprepend andbothconsumers, and validate decoded dimensions. No game/app launch, filesystem or shell messages.
- 0x04 Heartbeat: empty, hostevery2s evenifno desktop updates.
- 0x7f Error: strict JSON exactkey code, authored enum `auth`,`expired`,`declined`,`busy`,`capture`,`encoder`,`input`,`protocol`,`timeout`,`closed`; max128bytes. No rawexceptions, endpoints, credentials or OS strings.

All clientposthello packet sizes asabove and max1024. Serverready4096/error128/video4MiB caps. Input rate bounded (max500frames/s) and pendingclientinput <=256actions/16KiB, mousemove latest-only. On saturation, revoke unsent work, ReleaseAll or disconnect, require focus recovery; no stale input replay. Stop/read/write/decoder failure and focusloss trigger release; host tracks only successfully injected input. Video uses backpressure: capture/encode the next frame after previouswrite, no unbounded raw/encoded frame queue. Codec lowlatency and periodic IDR, bounded operation waits; hardware encoder required in normal host. Software encoding is permitted only in clearly named fresh synthetic CI tests, never an implicit runtime fallback. SDR only; unsupportedHDR/rotation/device state fails with fixedguidance.

## Native Windows media ABI

Owned C++ DLL `KnotNativeMedia.dll`, C cdecl exports, fixedwidth types/pack4; create/read/close called on one dedicated MTA thread. Config uint32 width,height,fps,bitrate. Info uint32 width,height,fps,bitrate; int32 left,top,desktopWidth,desktopHeight; uint32 hardwareEncoder. `void* kn_media_create(const KnMediaConfig*,KnMediaInfo*,int32_t*error)`. `int32_t kn_media_read(void*,uint8_t*buffer,uint32_tcapacity,uint32_t*written,uint32_t*flags,uint64_t*timestampMicros)`. `void kn_media_close(void*)`. status0=sample,1=tryagain;-1generic,-2unsupporteddisplay,-3nohardwareencoder,-4devicefailure,-5invalidargument. Readbounded <=500ms and never writesbeyondcapacity. Native media headers are authoritative for actual struct names; coordinate/ABI edits require notifying otherworker. Syntheticmedia tests use a separate test entry, not any remoteflag.

## Acceptance evidence

Compile host+DLL with WindowsSDK/MSVC and native Macviewer using only system frameworks. Cross-language framing/strictparser tests, actual freshTLS pin/mismatchedpin/expiredtoken/oneuse/approval/stop tests, input validation with injected fake sink (NO actual SendInput inCI), and H264 codec fixtures generated from synthetic pixels (NO realdesktop capture inagent tests). VM/softwarecodec evidence is distinct from realhardware DesktopDuplication/MF acceptance. No actual private state, service, capture, installer or LocalMedia history is an input. Record exactsource/commands/results and explicitly state untested GPU/Home/Wi-Fi/IME/securedesktop and unsignedpreview limitations.
