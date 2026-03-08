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
        )
    ],
    targets: [
        .target(
            name: "ObjCExceptionCatcher",
            path: "Sources/ObjCExceptionCatcher",
            publicHeadersPath: "include"
        ),
        .target(
            name: "VoiceKit",
            dependencies: ["ObjCExceptionCatcher"],
            path: "Sources/VoiceKit"
        ),
        .testTarget(
            name: "VoiceKitTests",
            dependencies: ["VoiceKit"],
            path: "Tests/VoiceKitTests"
        ),
    ]
)
