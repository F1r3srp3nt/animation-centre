// swift-tools-version:5.9
//
// HCGAnimationKit — Hakmi Capital Group
//
//   HCGBackgroundCore  the C rules shared with the iOS project (vendored unmodified; see Vendor/VENDORED.md)
//   HCGAnimationPack   the portable animation pack + background preset v1 + catalog. Foundation only:
//                      no SwiftUI, no AppKit, no UIKit, no AVFoundation. Builds and tests on Linux.
//   HCGPackPlayer      the macOS renderer (AppKit + AVFoundation) used by the studio, the desktop player
//                      and any HCG Mac app that bundles a pack. Compiles to an empty module elsewhere.
import PackageDescription

let package = Package(
    name: "HCGAnimationKit",
    platforms: [.macOS(.v14), .iOS(.v15)],
    products: [
        .library(name: "HCGBackgroundCore", targets: ["HCGBackgroundCore"]),
        .library(name: "HCGAnimationPack", targets: ["HCGAnimationPack"]),
        .library(name: "HCGPackPlayer", targets: ["HCGPackPlayer"]),
        .executable(name: "hcgpack", targets: ["hcgpack"]),
    ],
    targets: [
        .target(name: "HCGBackgroundCore", path: "Sources/HCGBackgroundCore", publicHeadersPath: "include",
                linkerSettings: [.linkedLibrary("m", .when(platforms: [.linux]))]),
        .target(name: "HCGAnimationPack", dependencies: ["HCGBackgroundCore"], path: "Sources/HCGAnimationPack"),
        .target(
            name: "HCGPackPlayer",
            dependencies: ["HCGAnimationPack", "HCGBackgroundCore"],
            path: "Sources/HCGPackPlayer",
            linkerSettings: [
                .linkedFramework("AppKit", .when(platforms: [.macOS])),
                .linkedFramework("AVFoundation", .when(platforms: [.macOS])),
                .linkedFramework("QuartzCore", .when(platforms: [.macOS])),
            ]
        ),
        .executableTarget(name: "hcgpack", dependencies: ["HCGAnimationPack"], path: "Sources/hcgpack"),
        .testTarget(
            name: "HCGAnimationPackTests",
            dependencies: ["HCGAnimationPack", "HCGBackgroundCore"],
            path: "Tests/HCGAnimationPackTests",
            resources: [.copy("Fixtures")]
        ),
    ]
)
