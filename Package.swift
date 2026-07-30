// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentBell",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(name: "AgentBellCore", targets: ["AgentBellCore"]),
        .executable(name: "AgentBell", targets: ["AgentBell"]),
        .executable(name: "AgentBellHook", targets: ["AgentBellHook"]),
    ],
    targets: [
        .target(
            name: "AgentBellCore",
            path: "Sources/AgentBellCore"
        ),
        .executableTarget(
            name: "AgentBell",
            dependencies: ["AgentBellCore"],
            path: "Sources/AgentBell"
        ),
        .executableTarget(
            name: "AgentBellHook",
            dependencies: ["AgentBellCore"],
            path: "Sources/AgentBellHook"
        ),
        .testTarget(
            name: "AgentBellCoreTests",
            dependencies: ["AgentBellCore"],
            path: "Tests/AgentBellCoreTests"
        ),
    ]
)
