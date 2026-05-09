// swift-tools-version: 5.9
// VRM 1.0 Swift Library with Metal Rendering
// Updated: Animation support added

import PackageDescription

let package = Package(
    name: "VRM1Metal",
    platforms: [
        .iOS(.v15),
        .macOS(.v12)
    ],
    products: [
        .library(
            name: "VRM1Metal",
            targets: ["VRM1Metal"]
        )
    ],
    dependencies: [],
    targets: [
        .target(
            name: "VRM1Metal",
            dependencies: [],
            path: "Sources/VRM1Metal",
            resources: [
                .process("Rendering/Shaders")
            ]
        ),
        .testTarget(
            name: "VRM1MetalTests",
            dependencies: ["VRM1Metal"]
        )
    ]
)
