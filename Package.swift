// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WranglerBar",
    platforms: [.macOS("13.5")],
    products: [.executable(name: "WranglerBar", targets: ["WranglerBar"])],
    targets: [
        .target(name: "WranglerBarCore"),
        .executableTarget(name: "WranglerBar", dependencies: ["WranglerBarCore"]),
        .testTarget(name: "WranglerBarCoreTests", dependencies: ["WranglerBarCore"])
    ]
)
