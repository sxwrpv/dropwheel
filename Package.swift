// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Dropwheel",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Dropwheel", targets: ["Dropwheel"]),
        .executable(name: "dropwheel-cli", targets: ["dropwheel-cli"]),
    ],
    targets: [
        // Pure logic with no AppKit dependency, so it can be unit tested.
        .target(name: "DropwheelCore"),
        // Conversion engines: ImageIO, ffmpeg, archives and subtitles.
        .target(
            name: "DropwheelEngines",
            dependencies: ["DropwheelCore"]
        ),
        // The menu-bar app: drag detection, the wheel panel, and file actions.
        .executableTarget(
            name: "Dropwheel",
            dependencies: ["DropwheelCore", "DropwheelEngines"]
        ),
        // Headless access to the engines, for scripting and verification.
        .executableTarget(
            name: "dropwheel-cli",
            dependencies: ["DropwheelCore", "DropwheelEngines"]
        ),
        .testTarget(
            name: "DropwheelCoreTests",
            dependencies: ["DropwheelCore"]
        ),
        .testTarget(
            name: "DropwheelEnginesTests",
            dependencies: ["DropwheelCore", "DropwheelEngines"]
        ),
    ]
)
