// swift-tools-version:5.9
//
// HCG Animation Center for Mac — the studio (editor, library, catalog) and the desktop player with its menu bar
// control. SwiftUI for the interface; AppKit + AVFoundation for playback (HCGPackPlayer). The pack format itself is
// HCGAnimationPack, which has no UI dependencies.
//
// Build the .app with scripts/build-app.sh (repository root).
import PackageDescription

let package = Package(
    name: "HCGAnimationCenter",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "HCGAnimationCenter", targets: ["HCGAnimationCenter"]),
    ],
    dependencies: [
        .package(path: "../../Packages/HCGAnimationKit"),
    ],
    targets: [
        .executableTarget(
            name: "HCGAnimationCenter",
            dependencies: [
                .product(name: "HCGAnimationPack", package: "HCGAnimationKit"),
                .product(name: "HCGPackPlayer", package: "HCGAnimationKit"),
            ],
            path: "Sources/HCGAnimationCenter"
        ),
    ]
)
