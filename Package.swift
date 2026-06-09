// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentPulse",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "AgentPulseCore"),
        .executableTarget(
            name: "agentpulse-cli",
            dependencies: ["AgentPulseCore"]
        ),
        .executableTarget(
            name: "AgentPulse",
            dependencies: ["AgentPulseCore"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
