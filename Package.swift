// swift-tools-version: 5.10
import PackageDescription

// Maintained by hand. Add one target per feature module as it is written.
let package = Package(
    name: "ArchBrowser",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "ARCHEngine", targets: ["ARCHEngine"]),
        .library(name: "ARCHEngineWebKit", targets: ["ARCHEngineWebKit"]),
        .library(name: "Browsing", targets: ["Browsing"]),
        .executable(name: "Arch", targets: ["Arch"]),
    ],
    targets: [
        .target(name: "ARCHEngine", path: "Packages/ARCHKit/Sources/ARCHEngine"),
        .target(name: "ARCHEngineWebKit", dependencies: ["ARCHEngine"], path: "Packages/ARCHKit/Sources/ARCHEngineWebKit"),
        .target(name: "Browsing", dependencies: ["ARCHEngine"], path: "Packages/ARCH/Sources/Browsing"),
        .executableTarget(name: "Arch", dependencies: ["Browsing", "ARCHEngineWebKit"], path: "Packages/ARCHApp/Sources/Arch"),
    ]
)
