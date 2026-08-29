import Compression
import Foundation

/// A read-only ZIP reader, only as wide as EPUB needs it to be.
///
/// Hand-written rather than pulled in as a package: an EPUB only ever uses two
/// of the format's storage methods, and all we need is the central directory
/// plus a raw-inflate call the system already provides. A third-party archiver
/// would add a dependency, a signing surface and a changelog to follow in
/// exchange for a couple of hundred lines we can read in full.
///
/// Deliberately unsupported, each throwing rather than guessing: ZIP64, entry
/// encryption, and every compression method other than `stored` and `deflate`.
/// A guess here would not fail at import — it would hand back the wrong bytes
/// and surface much later as an unreadable chapter.
struct ZipArchive {
    /// Failures carry a technical detail instead of a localised message: every
    /// one of them means "this file is not something we can read", and the
    /// importer is the layer that says so in the user's language.
    enum ZipError: Error, CustomStringConvertible {
        case notAZip
        case zip64Unsupported
        case encrypted(String)
        case unsupportedCompression(UInt16, String)
        case truncated
        case inflateFailed(String)
        case checksumMismatch(String)

        var description: String {
            switch self {
            case .notAZip:
                return "not a ZIP archive (no end-of-central-directory record)"
            case .zip64Unsupported:
                return "ZIP64 archives are not supported"
            case .encrypted(let name):
                return "encrypted entry: \(name)"
            case let .unsupportedCompression(method, name):
                return "unsupported compression method \(method) for \(name)"
            case .truncated:
                return "truncated or corrupt archive"
            case .inflateFailed(let name):
                return "could not inflate \(name)"
            case .checksumMismatch(let name):
                return "checksum mismatch for \(name)"
            }
        }
    }

    private struct Entry {
        let method: UInt16
        let crc: UInt32
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int
    }

    /// Held as bytes rather than as `Data`: every read below is an offset into
    /// the whole archive, and a `Data` slice keeps its parent's indices — which
    /// makes plain offset arithmetic on one quietly wrong.
    private let bytes: [UInt8]
    private let entries: [String: Entry]

    init(data: Data) throws {
        bytes = [UInt8](data)
        entries = try Self.readCentralDirectory(bytes)
    }

    // MARK: - Reading

    /// The uncompressed contents of one entry, or nil when the archive has no
    /// such path. Absent and unreadable are different answers: an EPUB that is
    /// merely missing an optional document is still worth importing.
    func data(named name: String) throws -> Data? {
        guard let entry = entries[name] else { return nil }
        let header = entry.localHeaderOffset
        guard header + 30 <= bytes.count, Self.u32(bytes, header) == 0x0403_4b50 else {
            throw ZipError.truncated
        }
        // Name and extra lengths come from the *local* header, not from the
        // central directory: producers are free to write a different extra
        // field in each, and the payload starts after whatever is really here.
        let nameLength = Int(Self.u16(bytes, header + 26))
        let extraLength = Int(Self.u16(bytes, header + 28))
        let start = header + 30 + nameLength + extraLength
        guard start >= 0, start + entry.compressedSize <= bytes.count else {
            throw ZipError.truncated
        }
        let payload = Data(bytes[start ..< start + entry.compressedSize])
        let content: Data
        switch entry.method {
        case 0: content = payload
        case 8: content = try Self.inflate(payload, expecting: entry.uncompressedSize, name: name)
        default: throw ZipError.unsupportedCompression(entry.method, name)
        }
        // Checked rather than trusted, because the failure this catches has no
        // other symptom: a stored entry that lost a byte to a truncated download
        // or a bad copy comes back the right length and reads as text, and the
        // damage only ever surfaces as one chapter that is subtly wrong. The
        // checksum is what turns that into a refused import instead.
        //
        // Both storage methods, not just `stored`: inflate already rejects a
        // stream whose length disagrees with the directory, but a corrupted
        // stream can still inflate to the right number of wrong bytes.
        guard Crc32.compute(content) == entry.crc else {
            throw ZipError.checksumMismatch(name)
        }
        return content
    }

    // MARK: - Central directory

    private static func readCentralDirectory(_ bytes: [UInt8]) throws -> [String: Entry] {
        guard let eocd = endOfCentralDirectory(bytes) else { throw ZipError.notAZip }
        let count = Int(u16(bytes, eocd + 10))
        let size = u32(bytes, eocd + 12)
        let offset = u32(bytes, eocd + 16)
        // 0xffff / 0xffffffff are the escape values that mean "the real number
        // is in the ZIP64 records". Refusing is the whole point: reading them
        // as literals would send the cursor to an arbitrary place in the file.
        guard count != 0xffff, size != 0xffff_ffff, offset != 0xffff_ffff else {
            throw ZipError.zip64Unsupported
        }

        var cursor = Int(offset)
        var result: [String: Entry] = [:]
        for _ in 0 ..< count {
            guard cursor >= 0, cursor + 46 <= bytes.count, u32(bytes, cursor) == 0x0201_4b50 else {
                throw ZipError.truncated
            }
            let flags = u16(bytes, cursor + 8)
            let method = u16(bytes, cursor + 10)
            let nameLength = Int(u16(bytes, cursor + 28))
            let extraLength = Int(u16(bytes, cursor + 30))
            let commentLength = Int(u16(bytes, cursor + 32))
            guard cursor + 46 + nameLength <= bytes.count else { throw ZipError.truncated }
            // EPUB mandates UTF-8 entry names; Latin-1 is the fallback because
            // it cannot fail, and a mangled name is better than no archive.
            let nameBytes = bytes[cursor + 46 ..< cursor + 46 + nameLength]
            let name = String(bytes: nameBytes, encoding: .utf8)
                ?? String(bytes: nameBytes, encoding: .isoLatin1)
                ?? ""

            // Bit 0 of the general-purpose flags is "this entry is encrypted".
            guard flags & 1 == 0 else { throw ZipError.encrypted(name) }
            guard method == 0 || method == 8 else {
                throw ZipError.unsupportedCompression(method, name)
            }
            // Directory entries carry no payload and would only shadow a real
            // path lookup.
            if !name.hasSuffix("/") {
                result[name] = Entry(
                    method: method,
                    crc: u32(bytes, cursor + 16),
                    compressedSize: Int(u32(bytes, cursor + 20)),
                    uncompressedSize: Int(u32(bytes, cursor + 24)),
                    localHeaderOffset: Int(u32(bytes, cursor + 42))
                )
            }
            cursor += 46 + nameLength + extraLength + commentLength
        }
        return result
    }

    /// The end-of-central-directory record sits at the very end of the file
    /// unless the archive carries a trailing comment, so the search walks back
    /// over the largest comment the format allows rather than the whole file.
    private static func endOfCentralDirectory(_ bytes: [UInt8]) -> Int? {
        guard bytes.count >= 22 else { return nil }
        let lowest = max(0, bytes.count - 22 - 0xffff)
        var index = bytes.count - 22
        while index >= lowest {
            if u32(bytes, index) == 0x0605_4b50 { return index }
            index -= 1
        }
        return nil
    }

    // MARK: - Inflate

    /// `COMPRESSION_ZLIB` in Compression's buffer API is a *raw* DEFLATE stream
    /// (RFC 1951) with no zlib wrapper, despite the name — which is exactly
    /// what ZIP stores.
    ///
    /// The output buffer is sized from the directory's uncompressed length, so
    /// a short result means the stream and the directory disagree. That is a
    /// corrupt archive, not a chapter with a few bytes missing, so it throws.
    ///
    /// Shared with `ZipFileReader`, which reads the same streams out of a file
    /// rather than out of memory: where the payload came from changes nothing
    /// about how it is inflated, and one of these is enough to get wrong.
    static func inflate(_ payload: Data, expecting size: Int, name: String) throws -> Data {
        guard size > 0 else { return Data() }
        guard !payload.isEmpty else { throw ZipError.truncated }
        var output = Data(count: size)
        let written = output.withUnsafeMutableBytes { destination -> Int in
            guard let target = destination.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return payload.withUnsafeBytes { source -> Int in
                guard let origin = source.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(
                    target, size, origin, source.count, nil, COMPRESSION_ZLIB
                )
            }
        }
        guard written == size else { throw ZipError.inflateFailed(name) }
        return output
    }

    // MARK: - Little-endian reads
    //
    // Every call site bounds-checks the header it is about to read, so these
    // stay free of their own guards and of an optional return that would make
    // the parsers above unreadable.

    private static func u16(_ bytes: [UInt8], _ at: Int) -> UInt16 {
        UInt16(bytes[at]) | UInt16(bytes[at + 1]) << 8
    }

    private static func u32(_ bytes: [UInt8], _ at: Int) -> UInt32 {
        UInt32(bytes[at])
            | UInt32(bytes[at + 1]) << 8
            | UInt32(bytes[at + 2]) << 16
            | UInt32(bytes[at + 3]) << 24
    }
}
