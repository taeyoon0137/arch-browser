import AppKit
import Foundation
import Testing
@testable import Browsing

@Suite struct SiteIconStoreTests {
    private let persona = UUID()

    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("SiteIconStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func icon(_ color: NSColor, size: CGFloat = 16) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            color.setFill()
            rect.fill()
            return true
        }
    }

    private func color(of image: NSImage) -> NSColor? {
        guard let data = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: data) else { return nil }
        return bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.deviceRGB)
    }

    @Test func aRememberedIconLoadsForEveryPageOfItsHostAfterRelaunch() throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SiteIconStore(directory: directory)
        store.remember(icon(.red), for: URL(string: "https://Example.com/a?b=1")!, in: persona)
        store.finishWrites()

        let relaunched = SiteIconStore(directory: directory)
        let loaded = try #require(relaunched.icon(for: URL(string: "http://example.com/other")!, in: persona))
        #expect(loaded.size == NSSize(width: 32, height: 32))
        let color = try #require(color(of: loaded))
        #expect(color.redComponent > 0.9 && color.greenComponent < 0.3 && color.blueComponent < 0.3)
        #expect(relaunched.icon(for: URL(string: "https://example.com/")!, in: UUID()) == nil)
        #expect(relaunched.icon(for: URL(string: "https://other.example/")!, in: persona) == nil)
        // The file name does not show the host.
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("SiteIcons/\(persona.uuidString)").path)
        #expect(files == [SiteIconStore.fileName("example.com")])
        #expect(!files[0].contains("example"))
    }

    @Test func nonWebPagesStoreNothing() throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SiteIconStore(directory: directory)
        store.remember(icon(.red), for: URL(fileURLWithPath: "/tmp/page.html"), in: persona)
        store.remember(icon(.red), for: URL(string: "about:blank")!, in: persona)
        store.finishWrites()
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("SiteIcons").path))
    }

    @Test func aNewIconReplacesItsHostsEntry() throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SiteIconStore(directory: directory)
        let page = URL(string: "https://example.com/")!
        store.remember(icon(.red), for: page, in: persona)
        store.remember(icon(.blue), for: page, in: persona)
        store.finishWrites()
        let loaded = try #require(SiteIconStore(directory: directory).icon(for: page, in: persona))
        #expect(try #require(color(of: loaded)).blueComponent > 0.9)
    }

    @Test func pruningKeepsOnlyTheNamedHostsAndRemovingAPersonaKeepsOthers() throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SiteIconStore(directory: directory)
        let other = UUID()
        let kept = URL(string: "https://kept.example/")!, dropped = URL(string: "https://dropped.example/")!
        store.remember(icon(.red), for: kept, in: persona)
        store.remember(icon(.red), for: dropped, in: persona)
        store.remember(icon(.red), for: dropped, in: other)
        store.prune(persona: persona, keeping: ["kept.example"])
        store.finishWrites()
        #expect(store.icon(for: kept, in: persona) != nil)
        #expect(store.icon(for: dropped, in: persona) == nil)
        let relaunched = SiteIconStore(directory: directory)
        #expect(relaunched.icon(for: kept, in: persona) != nil)
        #expect(relaunched.icon(for: dropped, in: persona) == nil)
        #expect(relaunched.icon(for: dropped, in: other) != nil)

        store.removeAll(ofPersona: other)
        store.finishWrites()
        #expect(SiteIconStore(directory: directory).icon(for: dropped, in: other) == nil)
        #expect(SiteIconStore(directory: directory).icon(for: kept, in: persona) != nil)
    }
}
