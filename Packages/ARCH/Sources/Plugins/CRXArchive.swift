// A `.crx` file, the form in which Chromium packs an extension: a header with the package's signatures (format version 3), then a `.zip` archive of the package. Arch checks the file as Chromium's verifier does (`components/crx_file/crx_verifier.cc`): the header must not hold the signature of a `.zip` archive's end record, every proof in it must hold, and one must be by the developer's key, whose digest begins with the identifier in the header's signed part. A proof by the Web Store's publisher key as well shows that the store published the package (`docs/web-store.md`, Package proof). Arch installs the package in the archive and writes the developer's key into its manifest, over a `key` the manifest has, as Chromium does, so that the extension keeps the identifier that its developer's key gives it on both engines.
import CryptoKit
import Foundation
import Security
import UniformTypeIdentifiers

/// Checks a `.crx` file's header and proofs and gives the package's `.zip` archive.
struct CRXArchive {
    /// The SHA-256 digest of the Web Store's publisher key as DER `SubjectPublicKeyInfo`: `kPublisherKeyHash` in `components/crx_file/crx_verifier.cc` of Chromium 156.0.8078.48, the Chromium of the pinned CEF branch. A store package in that source's test data carries a proof by this key (`docs/web-store.md`, Facts).
    static let webStorePublisherKeyDigest = Data([
        0x61, 0xF7, 0xF2, 0xA6, 0xBF, 0xCF, 0x74, 0xCD, 0x0B, 0xC1, 0xFE, 0x24, 0x97, 0xCC, 0x9B, 0x04,
        0x25, 0x4C, 0x65, 0x8F, 0x79, 0xF2, 0x14, 0x53, 0x92, 0x86, 0x7E, 0xA8, 0x36, 0x63, 0x67, 0xCF,
    ])
    /// What each proof signs first: `CRX3 SignedData` and a zero byte.
    static let signatureContext = Data("CRX3 SignedData\0".utf8)
    /// The signatures, `PK` and two bytes, of a `.zip` archive's end of central directory record, ZIP64 end of central directory locator, and ZIP64 end of central directory record, which Chromium's verifier refuses in a header (`kEocd`, `kEocd64`, and `kEocd64Record`), since an unzipper could take the header for the archive's end.
    static let zipEndSignatures: [[UInt8]] = [[0x50, 0x4B, 0x05, 0x06], [0x50, 0x4B, 0x06, 0x07], [0x50, 0x4B, 0x06, 0x06]]

    /// The file's name, which the messages about its package use.
    let name: String
    /// The developer's public key, as DER `SubjectPublicKeyInfo`, whose SHA-256 digest begins with the extension's identifier.
    let publicKey: Data
    /// The extension's identifier: the first 16 bytes of the developer key's digest, each hexadecimal digit written as a letter from `a` to `p`.
    let extensionID: String
    /// `webStore` when the publisher key signed the package too, else `developer`.
    let proof: PluginProof
    /// The `.zip` archive after the header.
    let archive: Data

    /// Throws `PluginError.invalidPackage` naming `name`, the file's name, for data that is not a `.crx` file of format version 3, for a header that does not read or holds one of `zipEndSignatures`, for a file without a proof by the key of its identifier, and for one with a proof that does not hold, as Chromium refuses them. A proof by the key whose SHA-256 digest is `publisherKeyDigest` gives `webStore`; tests pass the digest of a key of their own.
    init(_ data: Data, name: String, publisherKeyDigest: Data = webStorePublisherKeyDigest) throws {
        let start = data.startIndex
        // "Cr24", the format version, and the header's length, each a 32-bit little-endian number.
        guard data.count >= 12, data.prefix(4) == Data("Cr24".utf8) else { throw PluginError.invalidPackage(localized("\(name) is not a .crx file.")) }
        let version = Self.uint32(data, at: start + 4)
        guard version == 3 else { throw PluginError.invalidPackage(localized("\(name) is a .crx file of format version \(version), which Chromium no longer installs.")) }
        let headerEnd = start + 12 + Int(Self.uint32(data, at: start + 8))
        guard headerEnd <= data.endIndex else { throw PluginError.invalidPackage(localized("\(name) is not a complete .crx file.")) }
        // The header is a `CrxFileHeader` message: RSA proofs (field 2) and ECDSA proofs on P-256 (field 3), each with a public key (field 1) and a signature (field 2), and the signed header (field 10000), a `SignedData` message whose field 1 is the identifier as the first 16 bytes of the developer key's digest. Of a field that repeats where the message has one, the last counts, as protocol buffers read it.
        let unreadable = PluginError.invalidPackage(localized("The header of \(name) could not be read."))
        let headerBytes = [UInt8](data[start + 12..<headerEnd])
        guard !Self.zipEndSignatures.contains(where: { headerBytes.firstRange(of: $0) != nil }),
              let header = Self.fields(headerBytes) else { throw unreadable }
        let signedHeader = header.last { $0.number == 10000 }?.value ?? []
        guard let signedFields = Self.fields(signedHeader) else { throw unreadable }
        var proofs: [Proof] = []
        for field in header where field.number == 2 || field.number == 3 {
            guard let proofFields = Self.fields(field.value) else { throw unreadable }
            proofs.append(Proof(isRSA: field.number == 2, key: Data(proofFields.last { $0.number == 1 }?.value ?? []),
                                signature: Data(proofFields.last { $0.number == 2 }?.value ?? [])))
        }
        guard let crxID = signedFields.last(where: { $0.number == 1 })?.value, crxID.count == 16,
              let developer = proofs.first(where: { Array(SHA256.hash(data: $0.key).prefix(16)) == crxID }) else {
            throw PluginError.invalidPackage(localized("\(name) has no key for its extension\u{2019}s identifier."))
        }
        // Every proof signs the context, the signed header's length as a 32-bit little-endian number, the signed header, and the archive, so one digest serves them all.
        var hasher = SHA256()
        hasher.update(data: Self.signatureContext)
        hasher.update(data: Self.littleEndian(UInt32(signedHeader.count)))
        hasher.update(data: signedHeader)
        hasher.update(data: data[headerEnd...])
        let digest = hasher.finalize()
        guard proofs.allSatisfy({ $0.holds(for: digest) }) else {
            throw PluginError.invalidPackage(localized("The signature of \u{201C}\(name)\u{201D} does not match its contents."))
        }
        let letters = Array("abcdefghijklmnop")
        self.name = name
        publicKey = developer.key
        extensionID = crxID.map { "\(letters[Int($0 >> 4)])\(letters[Int($0 & 0xF)])" }.joined()
        proof = proofs.contains { Data(SHA256.hash(data: $0.key)) == publisherKeyDigest } ? .webStore : .developer
        archive = data[headerEnd...]
    }

    /// A key and its signature from the header.
    private struct Proof {
        /// Whether it is an RSA proof, from field 2, rather than an ECDSA proof on P-256, from field 3.
        let isRSA: Bool
        /// DER `SubjectPublicKeyInfo`.
        let key: Data
        /// PKCS #1 v1.5 for RSA, DER for ECDSA.
        let signature: Data

        /// Whether the signature holds for the SHA-256 digest of what proofs sign: through Security for RSA, which reads the PKCS #1 key inside the `SubjectPublicKeyInfo`, and through CryptoKit for P-256. A key of another type or one that does not read fails.
        func holds(for digest: SHA256.Digest) -> Bool {
            if isRSA {
                let attributes = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeyClass as String: kSecAttrKeyClassPublic] as CFDictionary
                guard let pkcs1 = CRXArchive.rsaPublicKey(inSubjectPublicKeyInfo: key),
                      let publicKey = SecKeyCreateWithData(pkcs1 as CFData, attributes, nil) else { return false }
                return SecKeyVerifySignature(publicKey, .rsaSignatureDigestPKCS1v15SHA256, Data(digest) as CFData, signature as CFData, nil)
            }
            guard let publicKey = try? P256.Signing.PublicKey(derRepresentation: key),
                  let signature = try? P256.Signing.ECDSASignature(derRepresentation: signature) else { return false }
            return publicKey.isValidSignature(signature, for: digest)
        }
    }

    /// The object identifier `rsaEncryption`, 1.2.840.113549.1.1.1, as DER writes it.
    private static let rsaEncryption: [UInt8] = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01]

    /// The PKCS #1 `RSAPublicKey` in an RSA key's DER `SubjectPublicKeyInfo`, `SEQUENCE { SEQUENCE { rsaEncryption, NULL }, BIT STRING { 0 unused bits, RSAPublicKey } }`, which Security reads; nil for another key and for bytes that are not one.
    static func rsaPublicKey(inSubjectPublicKeyInfo info: Data) -> Data? {
        let bytes = [UInt8](info)
        guard let outer = derElement(bytes, at: 0), outer.tag == 0x30, outer.end == bytes.count,
              let algorithm = derElement(bytes, at: outer.start), algorithm.tag == 0x30,
              let oid = derElement(bytes, at: algorithm.start), oid.tag == 0x06, bytes[oid.start..<oid.end].elementsEqual(rsaEncryption),
              let key = derElement(bytes, at: algorithm.end), key.tag == 0x03, key.end == outer.end,
              key.end - key.start > 1, bytes[key.start] == 0 else { return nil }
        return Data(bytes[key.start + 1..<key.end])
    }

    /// The DER element at `offset`: its tag and where its contents start and end. Nil for a length of more than four bytes and for contents that run past the end.
    private static func derElement(_ bytes: [UInt8], at offset: Int) -> (tag: UInt8, start: Int, end: Int)? {
        guard offset >= 0, offset + 2 <= bytes.count else { return nil }
        var start = offset + 2
        var length = Int(bytes[offset + 1])
        if length >= 0x80 {
            let count = length & 0x7F
            guard (1...4).contains(count), start + count <= bytes.count else { return nil }
            length = bytes[start..<start + count].reduce(0) { $0 << 8 | Int($1) }
            start += count
        }
        guard length <= bytes.count - start else { return nil }
        return (bytes[offset], start, start + length)
    }

    private static func uint32(_ data: Data, at offset: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 | UInt32(data[offset + $1]) << (8 * UInt32($1)) }
    }

    private static func littleEndian(_ value: UInt32) -> Data {
        Data((0..<4).map { UInt8((value >> (8 * $0)) & 0xFF) })
    }

    /// The length-delimited fields of a protocol buffer message, in order, with their numbers; fields of other wire types are skipped. Nil for bytes that do not read as a message, which Chromium refuses too.
    static func fields(_ bytes: [UInt8]) -> [(number: Int, value: [UInt8])]? {
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
        while offset < bytes.count {
            guard let tag = varint(), tag >> 3 > 0 else { return nil }
            switch tag & 7 {
            case 0:
                guard varint() != nil else { return nil }
            case 1:
                guard bytes.count - offset >= 8 else { return nil }
                offset += 8
            case 2:
                guard let length = varint(), length <= UInt64(bytes.count - offset) else { return nil }
                fields.append((Int(tag >> 3), Array(bytes[offset..<offset + Int(length)])))
                offset += Int(length)
            case 5:
                guard bytes.count - offset >= 4 else { return nil }
                offset += 4
            default:
                return nil
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
