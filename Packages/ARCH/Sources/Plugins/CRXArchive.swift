// A `.crx` file, the form in which Chromium packs an extension: a header with the developer's public key and signatures (format version 3), then a `.zip` archive of the package. Arch installs the package in the archive and writes the header's key into its manifest, over a `key` the manifest has, as Chromium does, so that the extension keeps the identifier that its developer's key gives it on both engines. Arch does not check the signatures; the review sheet shows the files, as for any package.
import CryptoKit
import Foundation
import UniformTypeIdentifiers

struct CRXArchive {
    /// The public key whose SHA-256 digest begins with the extension's identifier.
    let publicKey: Data
    /// The `.zip` archive after the header.
    let archive: Data

    /// Throws `PluginError.invalidPackage` naming `name`, the file's name, for data that is not a `.crx` file of format version 3 with a key.
    init(_ data: Data, name: String) throws {
        let bytes = [UInt8](data)
        // "Cr24", the format version, and the header's length, each a 32-bit little-endian number.
        guard bytes.count >= 12, bytes[0..<4] == [0x43, 0x72, 0x32, 0x34] else { throw PluginError.invalidPackage("\(name) is not a .crx file.") }
        let version = Self.uint32(bytes, at: 4)
        guard version == 3 else { throw PluginError.invalidPackage("\(name) is a .crx file of format version \(version), which Chromium no longer installs.") }
        let headerEnd = 12 + Int(Self.uint32(bytes, at: 8))
        guard headerEnd <= bytes.count else { throw PluginError.invalidPackage("\(name) is not a complete .crx file.") }
        // The header is a `CrxFileHeader` message: its key proofs (fields 2 and 3) each carry a public key (field 1), and its signed data (field 10000) carries the extension's identifier as the first 16 bytes of the key's digest (field 1).
        var keys: [[UInt8]] = []
        var identifier: [UInt8]?
        for field in Self.fields(Array(bytes[12..<headerEnd])) {
            switch field.number {
            case 2, 3:
                if let key = Self.fields(field.value).first(where: { $0.number == 1 }) { keys.append(key.value) }
            case 10000:
                identifier = Self.fields(field.value).first { $0.number == 1 }?.value
            default:
                break
            }
        }
        guard let key = keys.first(where: { identifier == nil || Array(SHA256.hash(data: $0).prefix(16)) == identifier }) else {
            throw PluginError.invalidPackage("\(name) has no key for its extension's identifier.")
        }
        publicKey = Data(key)
        archive = Data(bytes[headerEnd...])
    }

    private static func uint32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[offset + $1]) << (8 * UInt32($1)) }
    }

    /// The length-delimited fields of a protocol buffer message, in order, with their numbers. Other fields are skipped; reading stops at the first malformed field.
    static func fields(_ bytes: [UInt8]) -> [(number: Int, value: [UInt8])] {
        var fields: [(number: Int, value: [UInt8])] = []
        var offset = 0
        func varint() -> UInt64? {
            var value: UInt64 = 0
            for shift in stride(from: UInt64(0), to: 64, by: 7) {
                guard offset < bytes.count else { return nil }
                let byte = bytes[offset]
                offset += 1
                value |= UInt64(byte & 0x7F) << shift
                if byte & 0x80 == 0 { return value }
            }
            return nil
        }
        while offset < bytes.count, let tag = varint() {
            let number = Int(tag >> 3)
            switch tag & 7 {
            case 0:
                guard varint() != nil else { return fields }
            case 1:
                offset += 8
            case 2:
                guard let length = varint(), length <= UInt64(bytes.count - offset) else { return fields }
                fields.append((number, Array(bytes[offset..<offset + Int(length)])))
                offset += Int(length)
            case 5:
                offset += 4
            default:
                return fields
            }
        }
        return fields
    }
}

extension PluginPackage {
    /// The type of a `.crx` file, which the open panel takes for a Chromium package.
    public static let crxType = UTType(filenameExtension: "crx") ?? .data

    /// Writes `key`, as Base64, into the web extension manifest at `file` when it is a JSON object without a `key`, as Chromium names an extension by its key's digest. The key goes in right after the opening brace, so the rest of the file stays as it was. With `replacingKey`, as for a `.crx` file's header key, which Chromium writes over the manifest's, a manifest with another `key` takes this one, and the file is written again from its fields.
    public static func writeManifestKey(_ key: Data, into file: URL, replacingKey: Bool = false) throws {
        let data = try Data(contentsOf: file)
        guard var fields = try JSONSerialization.jsonObject(with: data) as? [String: Any], !fields.isEmpty else { return }
        let encoded = key.base64EncodedString()
        if let existing = fields["key"] {
            guard replacingKey, existing as? String != encoded else { return }
            fields["key"] = encoded
            try JSONSerialization.data(withJSONObject: fields, options: [.prettyPrinted, .withoutEscapingSlashes]).write(to: file, options: .atomic)
            return
        }
        guard let brace = data.firstIndex(of: UInt8(ascii: "{")) else { return }
        var written = data
        written.insert(contentsOf: Data("\"key\": \"\(encoded)\", ".utf8), at: brace + 1)
        try written.write(to: file, options: .atomic)
    }
}
