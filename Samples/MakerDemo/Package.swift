// swift-tools-version:5.9
//
// HCG Pack Demo — a tiny Mac app that shows a bundled HCG animation pack as its background, behind working controls.
// Built through HCG Executable Maker (New Build wizard → this package). The integration is opt-in per project:
//   AppPackaging.json         copies the pack's files to Contents/Resources/OrbitalCommand.hcgpack/
//   Resources/Info.plist      HCGAnimationPack / HCGAnimationPlacement say which pack and placement to use
// Without those, the app shows its plain background.
import PackageDescription

let package = Package(
    name: "HCGPackDemo",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "HCGPackDemo", targets: ["HCGPackDemo"]),
    ],
    dependencies: [
        .package(path: "../../Packages/HCGAnimationKit"),
    ],
    targets: [
        .executableTarget(
            name: "HCGPackDemo",
            dependencies: [.product(name: "HCGPackPlayer", package: "HCGAnimationKit")],
            path: "Sources/HCGPackDemo"
        ),
    ]
)
