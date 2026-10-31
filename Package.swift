// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "resh",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "resh", targets: ["Resh"])],
    dependencies: [.package(url: "https://github.com/dduan/TOMLDecoder", from: "0.4.5")],
    targets: [
        .target(name: "ReshCore", dependencies: [.product(name: "TOMLDecoder", package: "TOMLDecoder")]),
        .target(name: "RexFocusTracking"),
        .executableTarget(name: "Resh", dependencies: ["ReshCore", "RexFocusTracking"], resources: [.process("Resources")]),
        .testTarget(name: "ReshCoreTests", dependencies: ["ReshCore"]),
        .testTarget(name: "ReshTests", dependencies: ["Resh", "ReshCore"]),
    ],
    swiftLanguageModes: [.v5]
)
