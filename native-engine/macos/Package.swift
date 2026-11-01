// swift-tools-version: 6.0
import PackageDescription
import Foundation

let repositoryRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
let pairingLibraryDirectory = ProcessInfo.processInfo.environment["KNOT_NATIVE_PAIRING_LIBDIR"] ??
    repositoryRoot.appendingPathComponent("build/native-engine/macos/pairing/lib").path

let package = Package(
    name: "KnotNativePreview",
    platforms: [.macOS("26.0")],
    products: [.executable(name: "KnotNativePreview", targets: ["KnotNativePreview"])],
    targets: [
        .systemLibrary(name: "CKnotPairing", path: "Sources/CKnotPairing"),
        .target(name: "KnotNativeCore", dependencies: ["CKnotPairing"], linkerSettings: [
            .unsafeFlags([pairingLibraryDirectory + "/libKnotNativePairing.a",
                          pairingLibraryDirectory + "/libcrypto.a"], .when(platforms: [.macOS])),
            .linkedLibrary("c++", .when(platforms: [.macOS]))
        ]),
        .executableTarget(name: "KnotNativePreview", dependencies: ["KnotNativeCore"]),
        .testTarget(name: "KnotNativeCoreTests", dependencies: ["KnotNativeCore", "KnotNativePreview"])
    ],
    swiftLanguageModes: [.v6]
)
