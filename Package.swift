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
        // This path works only while UntoldEngine remains checked out as a sibling of this
        // package, at ../../UntoldEngine (see /Users/haroldserrano/Desktop/UntoldEngineStudio).
        //
        // If you copy this package elsewhere, replace it with the absolute or relative path to
        // your UntoldEngine checkout:
        // .package(path: "/path/to/UntoldEngine")
        //
        // A distributed package should use the canonical repository URL and a compatible
        // release requirement instead:
        // .package(url: "https://example.com/UntoldEngine.git", from: "0.19.1")
        .package(path: "../../UntoldEngine"),
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
