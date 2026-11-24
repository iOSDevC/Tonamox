// swift-tools-version: 6.0
import PackageDescription

// Standalone on purpose: the SDK's root Package.swift never sees this package,
// and it has no dependencies so it resolves offline.
let package = Package(
    name: "TerminalBridge",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
    ],
    products: [
        .library(name: "TerminalBridgeKit", targets: ["TerminalBridgeKit"]),
        .executable(name: "tonamox-bridge", targets: ["tonamox-bridge"]),
    ],
    dependencies: [],
    targets: [
        .target(name: "TerminalBridgeKit"),
        .target(
            name: "TerminalBridgeHelper",
            dependencies: ["TerminalBridgeKit"]
        ),
        .executableTarget(
            name: "tonamox-bridge",
            dependencies: ["TerminalBridgeHelper", "TerminalBridgeKit"]
        ),
        .testTarget(
            name: "TerminalBridgeKitTests",
            dependencies: ["TerminalBridgeKit"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "TerminalBridgeHelperTests",
            dependencies: ["TerminalBridgeHelper", "TerminalBridgeKit"]
        ),
    ]
)
