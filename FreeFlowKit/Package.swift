// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "FreeFlowKit",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "FreeFlowKit",
            targets: ["FreeFlowKit"]
        )
    ],
    targets: [
        .target(
            name: "ObjCExceptionCatcher",
            path: "Sources/ObjCExceptionCatcher",
            publicHeadersPath: "include"
        ),
        .target(
            name: "FreeFlowKit",
            dependencies: ["ObjCExceptionCatcher"],
            path: "Sources/FreeFlowKit"
        ),
        .testTarget(
            name: "FreeFlowKitTests",
            dependencies: ["FreeFlowKit"],
            path: "Tests/FreeFlowKitTests"
        ),
    ]
)
