import Foundation

/// A read-only ZIP reader that leaves the archive on disk.
///
/// The sibling of `ZipArchive`, and the difference is the one thing that reader
/// cannot do. An EPUB is a few megabytes, so holding it as bytes and indexing into
/// it is the simplest way to parse a format built entirely out of offsets. A comic
/// archive is a few gigabytes: the same approach is a few gigabytes of allocation
/// before the first page is written. This one keeps a file handle and reads the
/// three things a ZIP is made of — the trailer, the central directory, one entry's
/// payload — as it needs them, so an import costs one page of a comic at a time.
///
/// The other difference is the shape of the answer. `ZipArchive` hands back a
/// dictionary because an EPUB is looked up by path; a comic archive is *walked*,
/// its structure being whatever folders the person who made it used, so entries
/// come back as an ordered list carrying their names.
///
/// Deliberately unsupported, each throwing rather than guessing, exactly as in
/// `ZipArchive`: ZIP64, encryption, and every method but `stored` and `deflate`.
final class ZipFileReader {
    /// One file in the archive. Directory records are dropped while reading the
    /// central directory — a comic's structure is in the paths of its files, and a
    /// zip made by a phone or a cloud drive may carry no directory records at all.
    struct Entry {
        let name: String
        let uncompressedSize: Int
        fileprivate let method: UInt16
        fileprivate let crc: UInt32
        fileprivate let compressedSize: Int
        fileprivate let localHeaderOffset: UInt64
    }

    let entries: [Entry]
    private let handle: FileHandle

    init(reading url: URL) throws {
        let handle = try FileHandle(forReadingFrom: url)
        self.handle = handle
        let size = try handle.seekToEnd()
        entries = try Self.readCentralDirectory(handle, size: size)
    }

    deinit {
        // The importer can leave by throwing from anywhere, and an open descriptor
        // per abandoned import is a leak with a hard ceiling behind it.
        try? handle.close()
    }

    /// One entry's contents.
    ///
    /// Whole, not streamed: the caller is a comic importer and its unit of work is
    /// a page — a few hundred kilobytes, which the chapter it belongs to is going to
    /// hold anyway. Streaming *entries* is what keeps the archive off the heap; a
    /// page is not the thing that made it big.
    func data(of entry: Entry) throws -> Data {
        let header = try read(at: entry.localHeaderOffset, count: 30)
        guard Self.u32(header, 0) == 0x0403_4b50 else { throw ZipArchive.ZipError.truncated }
        // Name and extra lengths come from the *local* header, not from the central
        // directory: producers are free to write a different extra field in each,
        // and the payload starts after whatever is really here.
        let nameLength = UInt64(Self.u16(header, 26))
        let extraLength = UInt64(Self.u16(header, 28))
        let payload = try read(
            at: entry.localHeaderOffset + 30 + nameLength + extraLength,
            count: entry.compressedSize
        )
        let content: Data
        switch entry.method {
        case 0: content = payload
        case 8:
            content = try ZipArchive.inflate(
                payload, expecting: entry.uncompressedSize, name: entry.name
            )
        default:
            throw ZipArchive.ZipError.unsupportedCompression(entry.method, entry.name)
        }
        // Checked for the same reason `ZipArchive` checks it: a stored entry that
        // lost bytes to a bad copy comes back the right length and still decodes to
        // *something*, and a comic page that is subtly wrong has no other symptom.
        guard Crc32.compute(content) == entry.crc else {
            throw ZipArchive.ZipError.checksumMismatch(entry.name)
        }
        return content
    }

    // MARK: - Central directory

    private static func readCentralDirectory(_ handle: FileHandle, size: UInt64) throws -> [Entry] {
        // The trailer sits at the very end unless the archive carries a comment, so
        // the search covers the largest comment the format allows and no more.
        let tailLength = Int(min(size, UInt64(22 + 0xffff)))
        guard tailLength >= 22 else { throw ZipArchive.ZipError.notAZip }
        let tail = [UInt8](try read(handle, at: size - UInt64(tailLength), count: tailLength))
        guard let eocd = endOfCentralDirectory(tail) else { throw ZipArchive.ZipError.notAZip }

        let count = Int(u16(tail, eocd + 10))
        let directorySize = u32(tail, eocd + 12)
        let directoryOffset = u32(tail, eocd + 16)
        // 0xffff / 0xffffffff are the escape values meaning "the real number is in
        // the ZIP64 records". Refusing is the point: reading them as literals would
        // send the cursor to an arbitrary place in the file.
        guard count != 0xffff, directorySize != 0xffff_ffff, directoryOffset != 0xffff_ffff else {
            throw ZipArchive.ZipError.zip64Unsupported
        }
        let directory = [UInt8](
            try read(handle, at: UInt64(directoryOffset), count: Int(directorySize))
        )

        var cursor = 0
        var result: [Entry] = []
        for _ in 0 ..< count {
            guard cursor + 46 <= directory.count, u32(directory, cursor) == 0x0201_4b50 else {
                throw ZipArchive.ZipError.truncated
            }
            let flags = u16(directory, cursor + 8)
            let method = u16(directory, cursor + 10)
            let nameLength = Int(u16(directory, cursor + 28))
            let extraLength = Int(u16(directory, cursor + 30))
            let commentLength = Int(u16(directory, cursor + 32))
            guard cursor + 46 + nameLength <= directory.count else {
                throw ZipArchive.ZipError.truncated
            }
            let nameBytes = directory[cursor + 46 ..< cursor + 46 + nameLength]
            // Latin-1 as the fallback because it cannot fail. These archives are
            // routinely made by desktop tools that never set the UTF-8 flag, and a
            // mangled chapter name is a better import than a refused one.
            let name = String(bytes: nameBytes, encoding: .utf8)
                ?? String(bytes: nameBytes, encoding: .isoLatin1)
                ?? ""

            guard flags & 1 == 0 else { throw ZipArchive.ZipError.encrypted(name) }
            guard method == 0 || method == 8 else {
                throw ZipArchive.ZipError.unsupportedCompression(method, name)
            }
            if !name.hasSuffix("/") {
                result.append(
                    Entry(
                        name: name,
                        uncompressedSize: Int(u32(directory, cursor + 24)),
                        method: method,
                        crc: u32(directory, cursor + 16),
                        compressedSize: Int(u32(directory, cursor + 20)),
                        localHeaderOffset: UInt64(u32(directory, cursor + 42))
                    )
                )
            }
            cursor += 46 + nameLength + extraLength + commentLength
        }
        return result
    }

    private static func endOfCentralDirectory(_ tail: [UInt8]) -> Int? {
        var index = tail.count - 22
        while index >= 0 {
            if u32(tail, index) == 0x0605_4b50 { return index }
            index -= 1
        }
        return nil
    }

    // MARK: - Reading

    private func read(at offset: UInt64, count: Int) throws -> Data {
        try Self.read(handle, at: offset, count: count)
    }

    /// Exactly `count` bytes, or `truncated`. A short read is the shape a cut-off
    /// download has, and the only place it can be told apart from a valid archive
    /// is here — every parser above this reads fixed-width fields.
    private static func read(_ handle: FileHandle, at offset: UInt64, count: Int) throws -> Data {
        guard count >= 0 else { throw ZipArchive.ZipError.truncated }
        guard count > 0 else { return Data() }
        try handle.seek(toOffset: offset)
        guard let data = try handle.read(upToCount: count), data.count == count else {
            throw ZipArchive.ZipError.truncated
        }
        return data
    }

    // MARK: - Little-endian reads
    //
    // Every call site bounds-checks the record it is about to read, the same way
    // `ZipArchive` does, so these stay free of their own guards.

    private static func u16(_ bytes: [UInt8], _ at: Int) -> UInt16 {
        UInt16(bytes[at]) | UInt16(bytes[at + 1]) << 8
    }

    private static func u32(_ bytes: [UInt8], _ at: Int) -> UInt32 {
        UInt32(bytes[at])
            | UInt32(bytes[at + 1]) << 8
            | UInt32(bytes[at + 2]) << 16
            | UInt32(bytes[at + 3]) << 24
    }

    private static func u16(_ data: Data, _ at: Int) -> UInt16 {
        UInt16(data[data.startIndex + at]) | UInt16(data[data.startIndex + at + 1]) << 8
    }

    private static func u32(_ data: Data, _ at: Int) -> UInt32 {
        UInt32(data[data.startIndex + at])
            | UInt32(data[data.startIndex + at + 1]) << 8
            | UInt32(data[data.startIndex + at + 2]) << 16
            | UInt32(data[data.startIndex + at + 3]) << 24
    }
}
