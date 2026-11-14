// swift-tools-version: 5.10
import PackageDescription

// Maintained by hand. Add one target per feature module as it is written.
// CEFBridge compiles its own files and the CEF C++ wrapper, which scripts/setup_cef.sh copies from Frameworks/cef; run it first (docs/plan.md, Build Procedure).
let cefWrapperSources = [
    "CEFBridgeBrowser.mm",
    "CEFBridgeExtensions.mm",
    "CEFBridgeHelper.mm",
    "CEFBridgeRequestContext.mm",
    "CEFBridgeRuntime.mm",
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
    platforms: [.macOS(.v14)],
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
        .library(name: "Plugins", targets: ["Plugins"]),
        .library(name: "Extensions", targets: ["Extensions"]),
        .library(name: "Terminal", targets: ["Terminal"]),
        .library(name: "AgentControl", targets: ["AgentControl"]),
        .library(name: "Agent", targets: ["Agent"]),
        .library(name: "Events", targets: ["Events"]),
        .library(name: "Hooks", targets: ["Hooks"]),
        .executable(name: "Arch", targets: ["Arch"]),
        .executable(name: "ArchHelper", targets: ["ArchHelper"]),
        .executable(name: "arch-cli", targets: ["ArchCLI"]),
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
                // The bridge uses the experimental CEF API that Arch's engine adds, such as DevTools in a view, so the wrapper and the bridge build against that API version. CEF picks it when no version is set; this keeps the choice explicit.
                .define("CEF_API_VERSION", to: "CEF_API_VERSION_EXPERIMENTAL"),
                .unsafeFlags(["-fno-rtti", "-fno-exceptions", "-fno-threadsafe-statics", "-fobjc-call-cxx-cdtors", "-Wno-unused-parameter", "-Wno-narrowing"]),
            ],
            linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("IOSurface")]
        ),
        .target(name: "ARCHEngineChromium", dependencies: ["ARCHEngine", "ARCHPrivateAPI", "CEFBridge"], path: "Packages/ARCHKit/Sources/ARCHEngineChromium"),
        .target(name: "History", path: "Packages/ARCH/Sources/History", linkerSettings: [.linkedLibrary("sqlite3")]),
        // `Events` gives script plugins their events (`docs/hooks.md`, Plugins).
        .target(name: "Plugins", dependencies: ["ARCHEngine", "AI", "Events"], path: "Packages/ARCH/Sources/Plugins"),
        .target(name: "Extensions", dependencies: ["ARCHEngine", "Plugins"], path: "Packages/ARCH/Sources/Extensions"),
        .target(name: "Browsing", dependencies: ["ARCHEngine", "ARCHPrivateAPI", "History", "Plugins", "Extensions", "AI", "Agent", "Events", "Hooks"], path: "Packages/ARCH/Sources/Browsing"),
        .target(name: "AI", path: "Packages/ARCH/Sources/AI"),
        .target(name: "Terminal", path: "Packages/ARCH/Sources/Terminal"),
        // libbsm reads process IDs from audit tokens.
        .target(name: "AgentControl", path: "Packages/ARCH/Sources/AgentControl", linkerSettings: [.linkedFramework("Security"), .linkedLibrary("bsm")]),
        .target(name: "Agent", dependencies: ["ARCHEngine", "AI", "AgentControl"], path: "Packages/ARCH/Sources/Agent"),
        // `AI` gives site patterns and `AgentControl` the agent channel's address reduction and untrusted blocks, which the outside view uses.
        .target(name: "Events", dependencies: ["ARCHEngine", "AI", "AgentControl"], path: "Packages/ARCH/Sources/Events"),
        // `Agent` gives the agent run's values and the sealed file, `AgentControl` the JSON values that keep a later build's members of `hooks.json`, and `Plugins` the script runtime that JavaScript hooks run in.
        .target(name: "Hooks", dependencies: ["Events", "AI", "Plugins", "Agent", "AgentControl"], path: "Packages/ARCH/Sources/Hooks"),
        .target(name: "Preferences", dependencies: ["ARCHEngine", "Browsing", "AI", "Plugins", "Extensions", "Agent", "AgentControl", "Events", "Hooks"], path: "Packages/ARCH/Sources/Preferences"),
        .target(name: "Import", dependencies: ["Browsing", "History"], path: "Packages/ARCH/Sources/Import", linkerSettings: [.linkedLibrary("sqlite3")]),
        // `scripts/bundle_app.sh` copies the scripting definition into the bundle.
        .executableTarget(name: "Arch", dependencies: ["ARCHEngine", "Browsing", "Preferences", "History", "Import", "Plugins", "Terminal", "Agent", "Hooks", "ARCHEngineWebKit", "ARCHEngineChromium", "CEFBridge"], path: "Packages/ARCHApp/Sources/Arch", exclude: ["Arch.sdef"]),
        .executableTarget(name: "ArchHelper", dependencies: ["CEFBridge"], path: "Packages/ARCHApp/Sources/ArchHelper"),
        // `scripts/bundle_app.sh` copies it into Contents/Helpers as arch-cli, with arch-mcp as a link to it.
        .executableTarget(name: "ArchCLI", dependencies: ["AgentControl"], path: "Packages/ARCHApp/Sources/ArchCLI"),
        // Needs no CEF framework: the bridge loads it at run time, and these tests start no Chromium engine. The WebKit adapter is there for the context menu parity tests, which make WebKit web views without a page.
        .testTarget(name: "ARCHEngineChromiumTests", dependencies: ["ARCHEngineChromium", "ARCHEngineWebKit"], path: "Packages/ARCHKit/Tests/ARCHEngineChromiumTests"),
        // `Fixtures/Agent` holds the Claude Code and Codex streams that the agent session decoders are written against.
        .testTarget(name: "AITests", dependencies: ["AI", "Plugins"], path: "Packages/ARCH/Tests/AITests", resources: [.copy("Fixtures")]),
        .testTarget(name: "ARCHEngineTests", dependencies: ["ARCHEngine"], path: "Packages/ARCHKit/Tests/ARCHEngineTests"),
        .testTarget(name: "ARCHEngineWebKitTests", dependencies: ["ARCHEngineWebKit"], path: "Packages/ARCHKit/Tests/ARCHEngineWebKitTests"),
        .testTarget(name: "ARCHPrivateAPITests", dependencies: ["ARCHPrivateAPI"], path: "Packages/ARCHKit/Tests/ARCHPrivateAPITests"),
        .testTarget(name: "AgentControlTests", dependencies: ["AgentControl"], path: "Packages/ARCH/Tests/AgentControlTests"),
        // `Fixtures` holds the pages the snapshot and action scripts run on in WebKit.
        .testTarget(name: "AgentTests", dependencies: ["Agent", "ARCHEngineWebKit"], path: "Packages/ARCH/Tests/AgentTests", resources: [.copy("Fixtures")]),
        // Reads store pages from hosts that stand in for the Web Store's through `Extensions`.
        .testTarget(name: "BrowsingTests", dependencies: ["Browsing", "Extensions"], path: "Packages/ARCH/Tests/BrowsingTests"),
        .testTarget(name: "EventsTests", dependencies: ["Events"], path: "Packages/ARCH/Tests/EventsTests"),
        // `Fixtures` holds a sample web extension that the tests load into WebKit.
        .testTarget(name: "ExtensionsTests", dependencies: ["Extensions", "ARCHEngineWebKit"], path: "Packages/ARCH/Tests/ExtensionsTests", resources: [.copy("Fixtures")]),
        .testTarget(name: "HistoryTests", dependencies: ["History"], path: "Packages/ARCH/Tests/HistoryTests"),
        // `Fixtures` holds the hook scripts that the JavaScript runner's tests run.
        .testTarget(name: "HooksTests", dependencies: ["Hooks"], path: "Packages/ARCH/Tests/HooksTests", resources: [.copy("Fixtures")]),
        // Links SQLite to build its synthetic databases.
        .testTarget(name: "ImportTests", dependencies: ["Import", "Browsing", "History"], path: "Packages/ARCH/Tests/ImportTests", linkerSettings: [.linkedLibrary("sqlite3")]),
        // `Fixtures` holds a sample script plugin that the tests install and run.
        .testTarget(name: "PluginsTests", dependencies: ["Plugins"], path: "Packages/ARCH/Tests/PluginsTests", resources: [.copy("Fixtures")]),
        .testTarget(name: "PreferencesTests", dependencies: ["Preferences", "Browsing"], path: "Packages/ARCH/Tests/PreferencesTests"),
        .testTarget(name: "TerminalTests", dependencies: ["Terminal"], path: "Packages/ARCH/Tests/TerminalTests"),
    ],
    cxxLanguageStandard: .cxx20
)
