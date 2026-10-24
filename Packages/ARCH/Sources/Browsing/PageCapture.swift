// Writes page captures as PNG files to the captures folder, named after the page and the time, and crops viewport captures to a region.
import AppKit

enum PageCapture {
    /// `~/Pictures/Arch Captures`. Captures are pictures, and keeping them out of the downloads folder keeps them apart from the files the library lists.
    static var folder: URL {
        FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0].appendingPathComponent("Arch Captures", isDirectory: true)
    }

    enum CaptureError: LocalizedError {
        case encodingFailed

        var errorDescription: String? { "The image could not be encoded as PNG." }
    }

    /// Writes `image` as a PNG file named after the page and `date`, adding a number when that name is taken, and returns the file. The file's resolution records the image's pixels per point, as the system's screenshots do.
    static func save(_ image: NSImage, title: String, date: Date = Date(), in folder: URL = folder) throws -> URL {
        guard let pixels = pixelImage(of: image) else { throw CaptureError.encodingFailed }
        let bitmap = NSBitmapImageRep(cgImage: pixels)
        bitmap.size = image.size
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw CaptureError.encodingFailed }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = "\(fileTitle(title)) \(timestamp.string(from: date))"
        var file = folder.appendingPathComponent(name + ".png")
        var number = 2
        while FileManager.default.fileExists(atPath: file.path) {
            file = folder.appendingPathComponent("\(name) \(number).png")
            number += 1
        }
        try data.write(to: file, options: .withoutOverwriting)
        return file
    }

    /// Crops a viewport capture to `rect`, given in the coordinates of the page view whose `bounds` the capture shows. The result keeps the capture's pixels per point.
    static func crop(_ image: NSImage, to rect: CGRect, of bounds: CGRect, isFlipped: Bool) -> NSImage? {
        guard let pixels = pixelImage(of: image), bounds.width > 0, bounds.height > 0 else { return nil }
        let scaleX = CGFloat(pixels.width) / bounds.width
        let scaleY = CGFloat(pixels.height) / bounds.height
        // Image rows start at the top edge.
        let top = isFlipped ? rect.minY - bounds.minY : bounds.maxY - rect.maxY
        let region = CGRect(x: (rect.minX - bounds.minX) * scaleX, y: top * scaleY, width: rect.width * scaleX, height: rect.height * scaleY).integral
        guard let cropped = pixels.cropping(to: region) else { return nil }
        return NSImage(cgImage: cropped, size: NSSize(width: CGFloat(cropped.width) / scaleX, height: CGFloat(cropped.height) / scaleY))
    }

    /// The image's largest representation at its own pixel size.
    private static func pixelImage(of image: NSImage) -> CGImage? {
        guard let representation = image.representations.max(by: { $0.pixelsWide < $1.pixelsWide }) else { return nil }
        var rect = CGRect(x: 0, y: 0, width: representation.pixelsWide, height: representation.pixelsHigh)
        return representation.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    /// The page's title as a file name: slashes and colons become hyphens, line breaks become spaces, and leading dots that would hide the file go. The file system receives names decomposed, which can triple the bytes of a Korean title, so the title stops at 200 decomposed bytes and the whole name stays within 255.
    private static func fileTitle(_ title: String) -> String {
        let trimmed = CharacterSet.whitespaces.union(CharacterSet(charactersIn: "."))
        var name = title.components(separatedBy: .newlines).joined(separator: " ")
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: trimmed)
            .prefix(200)
        while name.decomposedStringWithCanonicalMapping.utf8.count > 200 { name = name.dropLast() }
        let short = name.trimmingCharacters(in: trimmed)
        return short.isEmpty ? "Capture" : short
    }

    /// The date and time as the system's screenshots write them, with dots in the time because a colon shows as a slash in the Finder.
    private static let timestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return formatter
    }()
}
