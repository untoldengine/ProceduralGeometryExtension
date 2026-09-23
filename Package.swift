// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ProceduralGeometryExtension",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
        .visionOS(.v2),
    ],
    products: [
        .library(name: "ProceduralGeometryExtension", targets: ["ProceduralGeometryExtension"]),
    ],
    dependencies: [
        // Pinned to develop, not a tagged release: this package needs Mesh.makeMesh(positions:...)
        // /boundingBox/markEntityPickingDirty, added by UntoldEngine PR #1214 (merged into develop
        // 2026-09-19), which hasn't shipped in a tagged release yet. Switch to a version
        // requirement (`from: "x.y.z"`) once one that includes it is cut.
        .package(url: "https://github.com/untoldengine/UntoldEngine.git", branch: "develop"),
    ],
    targets: [
        .target(
            name: "ProceduralGeometryExtension",
            dependencies: [
                .product(name: "UntoldEngine", package: "UntoldEngine"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "ProceduralGeometryExtensionTests",
            dependencies: [
                "ProceduralGeometryExtension",
                .product(name: "UntoldEngine", package: "UntoldEngine"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
