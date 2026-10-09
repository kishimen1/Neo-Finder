// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NeoFinder",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "NeoFinderCore", targets: ["NeoFinderCore"]),
        .executable(name: "NeoFinder", targets: ["NeoFinder"])
    ],
    targets: [
        .target(name: "NeoFinderCore"),
        .executableTarget(name: "NeoFinder", dependencies: ["NeoFinderCore"]),
        .testTarget(name: "NeoFinderCoreTests", dependencies: ["NeoFinderCore"])
    ],
    swiftLanguageModes: [.v5]
)
