// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "KnotNativePreview",
    platforms: [.macOS("26.0")],
    products: [.executable(name: "KnotNativePreview", targets: ["KnotNativePreview"])],
    targets: [
        .target(name: "KnotNativeCore"),
        .executableTarget(name: "KnotNativePreview", dependencies: ["KnotNativeCore"]),
        .testTarget(name: "KnotNativeCoreTests", dependencies: ["KnotNativeCore", "KnotNativePreview"])
    ],
    swiftLanguageModes: [.v6]
)
