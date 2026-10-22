// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "resh",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "resh", targets: ["Resh"])],
    targets: [
        .target(name: "ReshCore"),
        .executableTarget(name: "Resh", dependencies: ["ReshCore"]),
        .testTarget(name: "ReshCoreTests", dependencies: ["ReshCore"]),
        .testTarget(name: "ReshTests", dependencies: ["Resh", "ReshCore"]),
    ],
    swiftLanguageModes: [.v5]
)
