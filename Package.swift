// swift-tools-version: 5.10
import PackageDescription

// Maintained by hand. Add one target per feature module as it is written.
let package = Package(
    name: "ArchBrowser",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "ARCHEngine", targets: ["ARCHEngine"]),
        .library(name: "ARCHEngineWebKit", targets: ["ARCHEngineWebKit"]),
    ],
    targets: [
        .target(name: "ARCHEngine", path: "Packages/ARCHKit/Sources/ARCHEngine"),
        .target(name: "ARCHEngineWebKit", dependencies: ["ARCHEngine"], path: "Packages/ARCHKit/Sources/ARCHEngineWebKit"),
    ]
)
