// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AgentDeck",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "AgentDeckCore"),
        .executableTarget(name: "AgentDeckApp", dependencies: ["AgentDeckCore"]),
        .testTarget(name: "AgentDeckCoreTests", dependencies: ["AgentDeckCore"], resources: [.copy("Fixtures")]),
    ]
)
