// swift-tools-version: 5.10
import PackageDescription

// Maintained by hand. Add one target per feature module as it is written.
// CEFBridge compiles the CEF C++ wrapper from Frameworks/cef through symlinks; run the download step in docs/plan.md first.
let cefWrapperSources = [
    "CEFBridge.mm",
    "wrapper_src/base",
    "wrapper_src/cpptoc",
    "wrapper_src/ctocpp",
    "wrapper_src/shutdown_checker.cc",
    "wrapper_src/transfer_util.cc",
    "wrapper_src/wrapper/cef_byte_read_handler.cc",
    "wrapper_src/wrapper/cef_closure_task.cc",
    "wrapper_src/wrapper/cef_message_router.cc",
    "wrapper_src/wrapper/cef_message_router_utils.cc",
    "wrapper_src/wrapper/cef_resource_manager.cc",
    "wrapper_src/wrapper/cef_scoped_library_loader_mac.mm",
    "wrapper_src/wrapper/cef_scoped_sandbox_context_mac.mm",
    "wrapper_src/wrapper/cef_scoped_temp_dir.cc",
    "wrapper_src/wrapper/cef_stream_resource_handler.cc",
    "wrapper_src/wrapper/cef_xml_object.cc",
    "wrapper_src/wrapper/cef_zip_archive.cc",
    "wrapper_src/wrapper/libcef_dll_dylib.cc",
    "wrapper_src/wrapper/libcef_dll_wrapper.cc",
    "wrapper_src/wrapper/libcef_dll_wrapper2.cc",
]

let package = Package(
    name: "ArchBrowser",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "ARCHEngine", targets: ["ARCHEngine"]),
        .library(name: "ARCHPrivateAPI", targets: ["ARCHPrivateAPI"]),
        .library(name: "ARCHEngineWebKit", targets: ["ARCHEngineWebKit"]),
        .library(name: "ARCHEngineChromium", targets: ["ARCHEngineChromium"]),
        .library(name: "Browsing", targets: ["Browsing"]),
        .library(name: "Preferences", targets: ["Preferences"]),
        .library(name: "History", targets: ["History"]),
        .library(name: "Import", targets: ["Import"]),
        .library(name: "AI", targets: ["AI"]),
        .executable(name: "Arch", targets: ["Arch"]),
        .executable(name: "ArchHelper", targets: ["ArchHelper"]),
    ],
    targets: [
        .target(name: "ARCHEngine", path: "Packages/ARCHKit/Sources/ARCHEngine"),
        .target(name: "ARCHPrivateAPI", path: "Packages/ARCHKit/Sources/ARCHPrivateAPI"),
        .target(name: "ARCHEngineWebKit", dependencies: ["ARCHEngine", "ARCHPrivateAPI"], path: "Packages/ARCHKit/Sources/ARCHEngineWebKit"),
        .target(
            name: "CEFBridge",
            path: "Packages/ARCHKit/Sources/CEFBridge",
            sources: cefWrapperSources,
            publicHeadersPath: "include",
            cxxSettings: [
                .headerSearchPath("cefroot"),
                .define("WRAPPING_CEF_SHARED"),
                .unsafeFlags(["-fno-rtti", "-fno-exceptions", "-fno-threadsafe-statics", "-fobjc-call-cxx-cdtors", "-Wno-unused-parameter", "-Wno-narrowing"]),
            ],
            linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("IOSurface")]
        ),
        .target(name: "ARCHEngineChromium", dependencies: ["ARCHEngine", "ARCHPrivateAPI", "CEFBridge"], path: "Packages/ARCHKit/Sources/ARCHEngineChromium"),
        .target(name: "History", path: "Packages/ARCH/Sources/History", linkerSettings: [.linkedLibrary("sqlite3")]),
        .target(name: "Browsing", dependencies: ["ARCHEngine", "ARCHPrivateAPI", "History"], path: "Packages/ARCH/Sources/Browsing"),
        .target(name: "AI", path: "Packages/ARCH/Sources/AI"),
        .target(name: "Preferences", dependencies: ["ARCHEngine", "Browsing", "AI"], path: "Packages/ARCH/Sources/Preferences"),
        .target(name: "Import", dependencies: ["Browsing", "History"], path: "Packages/ARCH/Sources/Import", linkerSettings: [.linkedLibrary("sqlite3")]),
        // `scripts/bundle_app.sh` copies the scripting definition into the bundle.
        .executableTarget(name: "Arch", dependencies: ["Browsing", "Preferences", "History", "Import", "ARCHPrivateAPI", "ARCHEngineWebKit", "ARCHEngineChromium", "CEFBridge"], path: "Packages/ARCHApp/Sources/Arch", exclude: ["Arch.sdef"]),
        .executableTarget(name: "ArchHelper", dependencies: ["CEFBridge"], path: "Packages/ARCHApp/Sources/ArchHelper"),
        .testTarget(name: "AITests", dependencies: ["AI"], path: "Packages/ARCH/Tests/AITests"),
    ],
    cxxLanguageStandard: .cxx20
)
