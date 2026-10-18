// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Dropwheel",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Dropwheel", targets: ["Dropwheel"]),
    ],
    targets: [
        // Pure logic with no AppKit dependency, so it can be unit tested.
        .target(name: "DropwheelCore"),
        // The menu-bar app: drag detection, the wheel panel, and file actions.
        .executableTarget(
            name: "Dropwheel",
            dependencies: ["DropwheelCore"]
        ),
        .testTarget(
            name: "DropwheelCoreTests",
            dependencies: ["DropwheelCore"]
        ),
    ]
)
