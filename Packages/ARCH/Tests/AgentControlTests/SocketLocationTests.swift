// The socket location rule: the home folder's `Library/Application Support/Arch/Agent/control.sock` while it fits `sun_path` with its terminating NUL, the per-user temporary folder's `xyz.taeyoon.arch/control.sock` for a longer home, and no location when neither fits; and the bundle layout both ends read their expected code from.
import AgentControl
import Darwin
import Foundation
import Testing

@Suite struct SocketLocationTests {
    private let temporary = "/var/folders/w3/abcdefghijklmnop_qrstuvwx0000gp/T/"

    @Test func anOrdinaryHomeKeepsTheSocketInApplicationSupport() {
        let location = AgentSocketLocation.resolve(homeFolder: "/Users/someone", temporaryFolder: temporary)
        #expect(location == AgentSocketLocation(path: "/Users/someone/Library/Application Support/Arch/Agent/control.sock", isInTemporaryFolder: false))
        #expect(location?.folder == "/Users/someone/Library/Application Support/Arch/Agent")
    }

    @Test func aLongHomeMovesTheSocketToTheTemporaryFolder() throws {
        #expect(AgentSocketLocation.addressCapacity == 104)
        let suffix = "/Library/Application Support/Arch/Agent/control.sock"
        // 103 bytes and the NUL fill `sun_path` exactly; 104 bytes do not fit.
        let fitting = "/Users/" + String(repeating: "a", count: 103 - suffix.utf8.count - "/Users/".utf8.count)
        let fits = try #require(AgentSocketLocation.resolve(homeFolder: fitting, temporaryFolder: temporary))
        #expect(fits.path.utf8.count == 103)
        #expect(!fits.isInTemporaryFolder)

        let tooLong = fitting + "a"
        let moved = try #require(AgentSocketLocation.resolve(homeFolder: tooLong, temporaryFolder: temporary))
        #expect(moved == AgentSocketLocation(path: temporary + "xyz.taeyoon.arch/control.sock", isInTemporaryFolder: true))
        #expect(AgentSocketLocation.resolve(homeFolder: tooLong, temporaryFolder: String(temporary.dropLast()))?.path == moved.path)
    }

    @Test func noLocationWhenNeitherPathFits() {
        let long = "/" + String(repeating: "x", count: 120)
        #expect(AgentSocketLocation.resolve(homeFolder: long, temporaryFolder: long) == nil)
    }

    @Test func theCurrentLocationComesFromTheAccountsHomeFolder() throws {
        let location = try #require(AgentSocketLocation.current())
        let home = String(cString: getpwuid(getuid())!.pointee.pw_dir!)
        #expect(location.path.hasPrefix(home) || location.isInTemporaryFolder)
        #expect(location.path.hasSuffix("/control.sock"))
    }

    @Test func theAddressCarriesThePathAndItsNUL() {
        let location = AgentSocketLocation(path: "/tmp/a.sock", isInTemporaryFolder: false)
        var address = location.address()
        #expect(Int32(address.sun_family) == AF_UNIX)
        let path = withUnsafeBytes(of: &address.sun_path) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        #expect(path == "/tmp/a.sock")
    }

    @Test func theBundleLayoutFindsTheAppAroundItsHelpers() {
        let layout = AgentBundleLayout.containing(helper: URL(fileURLWithPath: "/Applications/Arch.app/Contents/Helpers/arch-cli"))
        #expect(layout?.bundleURL.path == "/Applications/Arch.app")
        #expect(layout?.archExecutableURL.path == "/Applications/Arch.app/Contents/MacOS/Arch")
        #expect(layout?.cliExecutableURL.path == "/Applications/Arch.app/Contents/Helpers/arch-cli")
        #expect(AgentBundleLayout.containing(helper: URL(fileURLWithPath: "/usr/local/bin/arch-cli")) == nil)
        #expect(AgentBundleLayout.containing(helper: URL(fileURLWithPath: "/Applications/Arch.app/Contents/MacOS/Arch")) == nil)
        #expect(AgentBundleLayout.containing(helper: URL(fileURLWithPath: "/tmp/Arch/Contents/Helpers/arch-cli")) == nil)
    }
}
