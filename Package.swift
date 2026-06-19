// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "RAMWatcher",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "RAMWatcherCore",
            path: "Sources/RAMWatcherCore"
        ),
        .executableTarget(
            name: "RAMWatcherDaemon",
            dependencies: ["RAMWatcherCore"],
            path: "Sources/RAMWatcherDaemon"
        ),
        .executableTarget(
            name: "RAMWatcherApp",
            dependencies: ["RAMWatcherCore"],
            path: "Sources/RAMWatcherApp"
        ),
        .testTarget(
            name: "RAMWatcherCoreTests",
            dependencies: ["RAMWatcherCore"],
            path: "Tests/RAMWatcherCoreTests"
        ),
    ]
)
