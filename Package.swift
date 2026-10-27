// swift-tools-version: 5.9
import PackageDescription

// Runs the same configuration/API code as the app without booting a simulator.
let package = Package(
    name: "EzBossCore",
    platforms: [.macOS(.v13), .iOS(.v17)],
    products: [.library(name: "EzBossCore", targets: ["EzBossCore"])],
    targets: [
        .target(name: "EzBossCore", path: "EzBoss/Core"),
        .testTarget(name: "EzBossCoreTests", dependencies: ["EzBossCore"], path: "Tests/EzBossCoreTests")
    ]
)
