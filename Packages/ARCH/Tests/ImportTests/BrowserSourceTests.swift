// Detection and the permission check on sources defined over temporary folders, so that no browser's own data is read.
import Foundation
import Testing
@testable import Import

@Suite struct BrowserSourceTests {
    private static func source(userData: URL) -> BrowserSource {
        BrowserSource(name: "Test Browser", bundleIdentifier: "test.browser", layout: .chromium(userData: userData, sidebarFile: nil), privacySetting: .fullDiskAccess)
    }

    @Test func aDataFolderWithoutItsKeyFileIsNotListed() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let userData = folder.url.appendingPathComponent("User Data")
        try FileManager.default.createDirectory(at: userData, withIntermediateDirectories: true)
        let webKit = BrowserSource(name: "Test Browser", bundleIdentifier: "test.webkit",
                                   layout: .webKit(bookmarks: folder.url.appendingPathComponent("Bookmarks.plist"), history: folder.url.appendingPathComponent("History.db")),
                                   privacySetting: .fullDiskAccess)
        #expect(BrowserSource.detected(among: [Self.source(userData: userData), webKit, Self.source(userData: folder.url.appendingPathComponent("Missing"))]).isEmpty)

        try folder.writeJSON(["profile": [String: Any]()], to: "User Data/Local State")
        let detected = BrowserSource.detected(among: [Self.source(userData: userData), webKit])
        #expect(detected.map(\.source.bundleIdentifier) == ["test.browser"])
        #expect(detected.map(\.access) == [.readable])
    }

    @Test func aKeyFileWithoutReadPermissionIsNotAPrivacyDenial() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let localState = try folder.writeJSON(["profile": [String: Any]()], to: "User Data/Local State")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: localState.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: localState.path) }
        let userData = localState.deletingLastPathComponent()
        #expect(BrowserSource.detected(among: [Self.source(userData: userData)]).map(\.access) == [.notPermitted])
        #expect(throws: ImportError.notPermitted(localState)) { try ChromiumProfile.profiles(in: userData) }
    }
}
