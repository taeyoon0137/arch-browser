// The icons that pages showed, kept on disk for each Persona by host, so that tabs without their page, favorites, and history rows show them after relaunch.
import AppKit
import CryptoKit
import Foundation

/// One icon per web host and Persona in `SiteIcons/<persona id>/<SHA-256 of the host>.png` under the app's data folder. A loaded page's icon replaces its host's entry; private windows store none.
/// Hosts leave with the history that named them (`prune(persona:keeping:)`) and with their Persona. Call on the main thread; files are written and removed on a background queue.
public final class SiteIconStore {
    private let directory: URL
    private var icons: [UUID: [String: NSImage]] = [:]
    /// Hosts with no file, so that a row redrawing does not read the disk again.
    private var missing: [UUID: Set<String>] = [:]
    /// The stored image data by host, so that a page reporting the same icon again writes nothing.
    private var written: [UUID: [String: Data]] = [:]
    private let queue = DispatchQueue(label: "local.arch.site-icons", qos: .utility)
    /// The stored size in pixels, twice the largest place an icon shows, a favorite tile.
    static let pixelSize = 64

    init(directory: URL) {
        self.directory = directory.appendingPathComponent("SiteIcons", isDirectory: true)
    }

    /// The host an icon is stored under: web pages only, lowercased.
    static func host(of url: URL) -> String? {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""), let host = url.host?.lowercased(), !host.isEmpty else { return nil }
        return host
    }

    /// The stored icon of `url`'s host in the Persona, if a page of it showed one.
    public func icon(for url: URL, in persona: UUID) -> NSImage? {
        guard let host = Self.host(of: url) else { return nil }
        if let icon = icons[persona]?[host] { return icon }
        guard missing[persona]?.contains(host) != true else { return nil }
        guard let data = try? Data(contentsOf: file(host, persona)), let icon = NSImage(data: data), icon.isValid else {
            missing[persona, default: []].insert(host)
            return nil
        }
        icons[persona, default: [:]][host] = icon
        written[persona, default: [:]][host] = data
        return icon
    }

    /// Stores `icon` as the icon of `url`'s host in the Persona, scaled to fit `pixelSize`.
    func remember(_ icon: NSImage, for url: URL, in persona: UUID) {
        guard let host = Self.host(of: url), let data = Self.png(of: icon) else { return }
        missing[persona]?.remove(host)
        guard written[persona]?[host] != data else { return }
        icons[persona, default: [:]][host] = NSImage(data: data) ?? icon
        written[persona, default: [:]][host] = data
        let folder = folder(persona), file = file(host, persona)
        queue.async {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
        }
    }

    /// Removes the Persona's icons of every host outside `hosts`, as after history is cleared.
    func prune(persona: UUID, keeping hosts: Set<String>) {
        icons[persona] = icons[persona]?.filter { hosts.contains($0.key) }
        written[persona] = written[persona]?.filter { hosts.contains($0.key) }
        missing[persona] = nil
        let folder = folder(persona)
        let kept = Set(hosts.map(Self.fileName))
        queue.async {
            let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            for file in files where !kept.contains(file.lastPathComponent) { try? FileManager.default.removeItem(at: file) }
        }
    }

    /// Removes the Persona's icons, as the removal of a deleted Persona's data does.
    func removeAll(ofPersona persona: UUID) {
        icons[persona] = nil
        written[persona] = nil
        missing[persona] = nil
        let folder = folder(persona)
        queue.async { try? FileManager.default.removeItem(at: folder) }
    }

    /// Waits for the queued writes and removals, as tests and quitting need.
    func finishWrites() {
        queue.sync {}
    }

    private func folder(_ persona: UUID) -> URL {
        directory.appendingPathComponent(persona.uuidString, isDirectory: true)
    }

    private func file(_ host: String, _ persona: UUID) -> URL {
        folder(persona).appendingPathComponent(Self.fileName(host))
    }

    /// The file name hides the host, as history is the record of which sites were visited.
    static func fileName(_ host: String) -> String {
        SHA256.hash(data: Data(host.utf8)).map { String(format: "%02x", $0) }.joined() + ".png"
    }

    /// The icon drawn centered into a square of `pixelSize` pixels with its proportions, as a PNG whose point size is half that.
    static func png(of icon: NSImage) -> Data? {
        let side = pixelSize
        guard icon.size.width > 0, icon.size.height > 0,
              let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4,
                                            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        let scale = CGFloat(side) / max(icon.size.width, icon.size.height)
        let size = NSSize(width: icon.size.width * scale, height: icon.size.height * scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        icon.draw(in: NSRect(x: (CGFloat(side) - size.width) / 2, y: (CGFloat(side) - size.height) / 2, width: size.width, height: size.height))
        NSGraphicsContext.restoreGraphicsState()
        bitmap.size = NSSize(width: side / 2, height: side / 2)
        return bitmap.representation(using: .png, properties: [:])
    }
}
