// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Turnring",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(name: "TurnringCore", targets: ["TurnringCore"]),
        .executable(name: "Turnring", targets: ["Turnring"]),
        .executable(name: "TurnringHook", targets: ["TurnringHook"]),
    ],
    targets: [
        .target(
            name: "TurnringCore",
            path: "Sources/TurnringCore"
        ),
        .executableTarget(
            name: "Turnring",
            dependencies: ["TurnringCore"],
            path: "Sources/Turnring"
        ),
        .executableTarget(
            name: "TurnringHook",
            dependencies: ["TurnringCore"],
            path: "Sources/TurnringHook"
        ),
        .testTarget(
            name: "TurnringCoreTests",
            dependencies: ["TurnringCore"],
            path: "Tests/TurnringCoreTests"
        ),
    ]
)
