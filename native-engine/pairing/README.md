# Enrollment crypto component

This component implements the C ABI used by Native Preview's one-use short-code
enrollment. Read [ENROLLMENT.md](../ENROLLMENT.md) for the protocol and grant
lifetime. The provisioning connection never becomes the media connection.

BoringSSL is vendored unmodified at the revision and exact archive/Git-tree
hashes in `PROVENANCE.json`. `LICENSE-INVENTORY.json` and
`THIRD-PARTY-NOTICES.txt` preserve its source and support-code notices. The full
source is retained so the build does not download code. No audit or FIPS claim
is made for Knot's integration.

Build with CMake 3.22+, C++17, and platform SDK/compiler tools:

```sh
cmake -S native-engine/pairing -B build/native-engine/macos/pairing \
  -DCMAKE_BUILD_TYPE=Release -DOPENSSL_NO_ASM=ON -DBUILD_TESTING=OFF \
  -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=26.0
cmake --build build/native-engine/macos/pairing --config Release \
  --target KnotNativePairing KnotPairingCryptoChecks KnotPairingUpstreamSpakeChecks
```

The Mac output `lib` directory contains `libKnotNativePairing.a` and
`libcrypto.a`. Set `KNOT_NATIVE_PAIRING_LIBDIR` to its absolute path before
building the Swift package. The module map has no ambient crypto link directive;
Package.swift supplies those exact owned archives and the platform C++ runtime.

Windows uses the same project and source with MSVC x64/C++17. Omit the two Mac
options. Build Release with the static Microsoft runtime; CMake produces
`bin/KnotNativePairing.dll` and the two synthetic-check executables. The managed
bridge loads only the application-directory DLL and System32 dependencies.

`KnotPairingCryptoChecks` validates the owned ABI and state machine using fresh
in-memory contexts, wrong numbers/slots, corrupt tags, role/order/reuse/size
failures, and HKDF/AES-GCM known answers. `KnotPairingUpstreamSpakeChecks` runs the
unmodified six upstream SPAKE25519 tests. The separate managed bridge entry is
`Knot.NativePreview.NativePairingBridgeChecks` in
`tests/ManagedCryptoChecks.cs`; compile it with the Windows application sources
and run it beside the owned DLL. None of these entries starts production UI,
networking, capture, certificate stores, clipboard access or input injection.

The raw C context must be serialized and closed exactly once by its owner.
Swift and C# bridges enforce serialization and idempotent managed disposal.
Processing SPAKE2 messages only derives candidate keys; successful directional
AEAD confirmation and the strict managed JSON schema are still required before
the host issues an invitation grant. A native error invalidates the attempt.
