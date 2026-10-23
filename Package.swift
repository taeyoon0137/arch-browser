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
        .library(name: "ARCHEngineWebKit", targets: ["ARCHEngineWebKit"]),
        .library(name: "ARCHEngineChromium", targets: ["ARCHEngineChromium"]),
        .library(name: "Browsing", targets: ["Browsing"]),
        .library(name: "Preferences", targets: ["Preferences"]),
        .executable(name: "Arch", targets: ["Arch"]),
        .executable(name: "ArchHelper", targets: ["ArchHelper"]),
    ],
    targets: [
        .target(name: "ARCHEngine", path: "Packages/ARCHKit/Sources/ARCHEngine"),
        .target(name: "ARCHEngineWebKit", dependencies: ["ARCHEngine"], path: "Packages/ARCHKit/Sources/ARCHEngineWebKit"),
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
        .target(name: "ARCHEngineChromium", dependencies: ["ARCHEngine", "CEFBridge"], path: "Packages/ARCHKit/Sources/ARCHEngineChromium"),
        .target(name: "Browsing", dependencies: ["ARCHEngine"], path: "Packages/ARCH/Sources/Browsing"),
        .target(name: "Preferences", dependencies: ["ARCHEngine"], path: "Packages/ARCH/Sources/Preferences"),
        .executableTarget(name: "Arch", dependencies: ["Browsing", "Preferences", "ARCHEngineWebKit", "ARCHEngineChromium", "CEFBridge"], path: "Packages/ARCHApp/Sources/Arch"),
        .executableTarget(name: "ArchHelper", dependencies: ["CEFBridge"], path: "Packages/ARCHApp/Sources/ArchHelper"),
    ],
    cxxLanguageStandard: .cxx20
)
