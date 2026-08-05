// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MiniClockify",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "MiniClockify",
            path: "Sources/MiniClockify"
        ),
        .testTarget(
            name: "MiniClockifyTests",
            dependencies: ["MiniClockify"],
            path: "Tests/MiniClockifyTests"
        )
    ]
)
