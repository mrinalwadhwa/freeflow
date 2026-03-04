// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "VoiceKit",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "VoiceKit",
            targets: ["VoiceKit"]
        ),
    ],
    targets: [
        .target(
            name: "VoiceKit",
            path: "Sources/VoiceKit"
        ),
        .testTarget(
            name: "VoiceKitTests",
            dependencies: ["VoiceKit"],
            path: "Tests/VoiceKitTests"
        ),
    ]
)
