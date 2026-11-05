# Native file transfer v1

Status: implementation contract for native.9; separate from media framing. Files are copies of regular files in one explicitly shared Windows directory. No remote paths, recursion, deletion, shell, file execution or clipboard synchronization.

## Session admission

Media Hello accepts exactly `{v,token,name}` or `{v,token,name,filesVersion}`; the optional integer must be1. New clients opt in with `filesVersion:1`. Old clients receive the original seven-key Ready. Enrollment confirmation accepts exactly the existing schema, with permissions either `screen,input` or `screen,input,files`; requested file scope is carried through the run's issued grant and checked at media claim. Legacy approval may authorize the locally displayed file folder when the Hello opts in. A capability is offered only when local folder consent, the authenticated claim's scope, and Hello opt-in all permit files.

Ready accepts exactly its original seven scalar keys or that complete set plus `filesVersion`, `filePort`, `fileToken`, `fileRootName`. No partial group/unknown/duplicate keys. Version1, port48634, token canonical base64url32randombytes (43characters), root name1..64UTF-8bytes with the existing safe display-name policy. The offer supplies no address or certificate: clients retain the authenticated media invitation's private address and exact DER pin. An old Windows host may reject the new opt-in/confirmation; update both apps for files. Do not silently retry broader permissions against a different host or repair trust.

The file listener binds the selected Windows address on48634 and reuses the current run's TLS1.2+ server certificate. It starts only after media authorization and successful media initialization. Publish activation under the same host gate before Ready delivery; any Ready/write/session failure revokes it. Check active run, constant-time token comparison and exact observed media source IPv4 before file authorization. Never advertise/log/save the capability or reuse an invitation/T2 as the file token.

The capability exists only for the active media session; each explicit file operation can establish a new pinned TLS connection. At most one file connection/operation is admitted, with a bounded10second TLS/auth budget and30second absolute per-packet/progress budget. Reject other peers before expensive work. Stop closes listener/current socket and revokes the token. A file-only cancel/error closes that file connection, cleans its owned partial and leaves media running. No persistent file trust or automatic replay.

## File envelope and exact schemas

Every file packet is `u8 kind + u32BE payloadLength + payload`. These types and limits are independent of the media packet enum and4096-byte media send limit. Metadata JSON is strict UTF-8, scalar values, exact keys; sizes are signed64-bit integers bounded0..8,589,934,592. Controls1..4096bytes except the empty ListRequest; Error1..128. Reject invalid lengths before allocation.

| Kind | Name | Payload |
| --- | --- | --- |
| 0x40 | Hello | `{v:1,token:string}` |
| 0x41 | Authorized | `{v:1}` |
| 0x42 | ListRequest | empty |
| 0x43 | Entry | `{entry:string,name:string,size:integer}` |
| 0x44 | ListEnd | `{count:integer,truncated:boolean}` |
| 0x45 | PutRequest | `{name:string,size:integer}` |
| 0x46 | GetRequest | `{entry:string}` |
| 0x47 | Accepted | `{name:string,size:integer}` |
| 0x48 | Chunk | `u64BE offset` +1..65,536filebytes (payload9..65,544) |
| 0x49 | Finish | `u64BE totalBytes` +32raw SHA-256bytes (payload40) |
| 0x4A | Complete | `{name:string,size:integer,sha256:string}` |
| 0x7F | Error | `{code:string}` |

Closed error codes: `auth,busy,protocol,timeout,denied,missing,changed,quota,io`. Entry IDs are32lowercasehex random opaque identifiers, not paths. Hash strings are64lowercasehex. Basenames are1..255UTF-8bytes, no slash/backslash/colon/NUL/control/format/line separators, Windows-invalid characters (`< > " | ? *`), dot/dotdot, trailing dot/space, reserved `.knot-` partial prefix or Windows device basename. Device checks include CON/PRN/AUX/NUL/CLOCK$/CONIN$/CONOUT$, COM/LPT0..9 and superscript1/2/3, including extensions and trailing stem spaces. Reject links, directories and nonregular sources. A listing scans a bounded number of entries and returns at most256; IDs refer to the active run's bounded snapshot and expire on replacement/revocation. Verify source handle identity and size/timestamp against the snapshot before reading; never resolve client-supplied paths.

Every connection: client Hello → server Authorized → exactly one operation:

- List: client ListRequest → server Entry ×0..256 → server ListEnd → close.
- Upload: client PutRequest → server Accepted → client Chunk* → client Finish → server Complete → close.
- Download: client GetRequest → server Accepted → server Chunk* → server Finish → client Complete → close.

One reusable64KiB sender chunk, one bounded receiver write before reading the next packet, incremental SHA-256, and2MiB/s pacing. Offset must equal the receiver's exact current count; Finish must equal declared and received lengths and hash. Zero-byte files use Accepted→Finish with the empty digest. Reject unexpected kinds/order/trailing typed payload data. Complete reports the actual collision-resolved destination basename, exact size and matching hash; the sender validates it before reporting remote completion. No ACK/cancel/heartbeat packets are needed: TLS write backpressure bounds application work and cancellation closes this operation's socket. OS buffering is not claimed as a measured latency bound.

Reserve declared bytes against an8GiB aggregate run quota across both directions; cancelled/retried transfers do not refund that reservation. At most32 queued Mac upload files. Check destination free-space where supported, and fail safely on disk-full rather than publishing an incomplete file.

## Filesystem and revocation boundary

Open and validate the selected root once; child access must be handle-bound/no-follow and prove containment. Windows checks persistent-ACL support through the pinned root's volume handle, then verifies the earliest created partial handle's effective owner and protected receiver-only DACL before any payload bytes. A failed capability/security query or unsupported filesystem disables that file root rather than assuming that successful creation applied its permissions. The shared folder also needs alternate data streams for Mark of the Web. These are separate prerequisites: [Microsoft documents](https://learn.microsoft.com/en-us/windows/desktop/FileIO/creating-and-opening-files) that a supplied creation descriptor depends on filesystem security support. Reject reparse/symlink/nonregular child handles, not just lexical `..`. Source reads use one regular handle and recheck identity/size/timestamps before Finish. Upload names select only a child basename; Get selects only a run-owned opaque ID.

Receive into fresh exclusive private staging. Mac uses a random0700 directory with inherited ACLs cleared, a pinned directory descriptor and0600 payload; publication renames from that descriptor into the selected destination. Windows pins its root/child handles and restricts partial ACLs to the receiver. Apply Mac quarantine or Windows Mark of the Web before publication; no automatic opening. Flush, verify exact bytes/hash, and publish exclusively under a collision-safe name without replacing any existing file. Final publication synchronizes with the owning session's revocation gate, with no await gap after its last authorization check. Cancel/failure removes only the receiver's owned partial. A Mac staging directory in a destination writable by another user may be left empty when safe path-based directory removal cannot be established. Hostile same-user or privileged local code is outside this in-process protection. Late UI callbacks and Finder promises must fail after session disconnect.

A file already exclusively published is not rolled back because a final receipt is lost. A Mac receiver can report locally verified success if sending Complete fails while its operation is still authorized. A sender missing the receiver's Complete after Finish reports unconfirmed completion and asks the user to inspect the destination; it never retries automatically or claims the receiver removed a possibly committed file. Session revocation still suppresses stale UI callbacks and any later publication.

## Acceptance

Use fresh synthetic files, owned temporary directories and loopback TLS. Never inspect existing user folders, global clipboard, production UI or Local Media data while testing. Cross-platform checks must bind actual Windows-produced file protocol vectors/transfer fixtures to Mac parsing and compare exact bytes/hash, including empty/Unicode/collision cases. Distinguish compiler/parser/loopback/file-promise fixture evidence from live OS drag behavior, physical network performance and publisher signing.

The separate managed-file probe compiles the same C#5/.NET4.8 sources and runs owned filesystem/TLS fixtures without the native pairing library or codecs. It is a fast diagnostic subset, not complete native-build acceptance. The normal workflow still rebuilds native dependencies and requires all PAKE, media, file and cross-platform checks.
