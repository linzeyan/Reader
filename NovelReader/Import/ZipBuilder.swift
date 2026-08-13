import Compression
import Foundation

/// A write-only ZIP writer, the mirror image of `ZipArchive` and exactly as
/// narrow: `stored` and `deflate`, no ZIP64, no encryption, no data descriptors.
///
/// Hand-written for the same reason the reader is. The one archive this app
/// produces is an EPUB, both of the storage methods it needs are in the system's
/// `Compression` framework already, and a package would add a dependency and a
/// signing surface in exchange for the hundred lines below.
///
/// Entries land in a file as they arrive rather than in a buffer that is handed
/// back at the end. A ZIP is written front to back anyway — a local header, its
/// payload, then the next one — and each entry is deflated on its own, so the
/// only thing that changes by streaming is where the finished bytes accumulate.
/// A thirteen-hundred-chapter novel is therefore one chapter of memory at a time
/// instead of the whole book twice over (once as text, once as an archive).
///
/// Output is deterministic: modification times are written as zero rather than
/// as "now", and nothing else in an entry depends on the clock. Exporting the
/// same book twice therefore produces byte-identical files, which is what makes
/// re-importing an export land on the book it came from — `LocalBookImporter`
/// identifies an imported book by the digest of the file's bytes, so a timestamp
/// in here would quietly turn every export into a new book.
final class ZipBuilder {
    struct Entry {
        let name: String
        let data: Data
        /// Whether to deflate this entry. Not a blanket "compress everything":
        /// OCF requires `mimetype` to be stored *and* to be the first entry, so
        /// that a reader can identify an EPUB by seeking to a fixed offset.
        let compressed: Bool

        init(name: String, data: Data, compressed: Bool = true) {
            self.name = name
            self.data = data
            self.compressed = compressed
        }

        init(name: String, text: String, compressed: Bool = true) {
            self.init(name: name, data: Data(text.utf8), compressed: compressed)
        }
    }

    private let handle: FileHandle
    /// The central directory, which can only be written once the last entry's
    /// offset is known. Held in memory because that is what the format demands,
    /// and it is affordable: one record is the entry's name plus 46 bytes, so a
    /// novel's worth of chapters comes to some tens of kilobytes.
    private var directory = Data()
    private var count: UInt16 = 0
    /// Bytes written so far, which is the next entry's offset. Tracked rather
    /// than asked of the file handle: `offset()` is a syscall per entry and this
    /// is the same number.
    private var written: UInt32 = 0

    /// - Parameter url: the file to write. Truncated if it already exists.
    init(creating url: URL) throws {
        // An empty file first: `FileHandle(forWritingTo:)` opens, it does not
        // create, and `Data.write(to:)` reports why it could not (no directory,
        // no space) where `FileManager.createFile` returns a bare `false`.
        try Data().write(to: url)
        handle = try FileHandle(forWritingTo: url)
    }

    /// Appends one entry. Entries appear in the file in the order they are
    /// added, which is the order a reader sees them in.
    func append(_ entry: Entry) throws {
        let name = Data(entry.name.utf8)
        let offset = written
        let deflated = entry.compressed ? Self.deflate(entry.data) : nil
        let payload = deflated ?? entry.data
        let method: UInt16 = deflated == nil ? 0 : 8
        let crc = Crc32.compute(entry.data)
        // Bit 11 says the name is UTF-8. Every name this app writes is ASCII,
        // but the flag costs one comparison and its absence on a non-ASCII
        // name is how entry names come out mangled in other readers.
        let flags: UInt16 = name.allSatisfy { $0 < 0x80 } ? 0 : 1 << 11

        var header = Data()
        header.append(Self.u32(0x0403_4b50))
        header.append(Self.u16(20))                     // version needed: 2.0
        header.append(Self.u16(flags))
        header.append(Self.u16(method))
        header.append(Self.u16(0))                      // modification time
        header.append(Self.u16(0))                      // modification date
        header.append(Self.u32(crc))
        header.append(Self.u32(UInt32(payload.count)))
        header.append(Self.u32(UInt32(entry.data.count)))
        header.append(Self.u16(UInt16(name.count)))
        header.append(Self.u16(0))                      // extra field length
        header.append(name)
        try handle.write(contentsOf: header)
        try handle.write(contentsOf: payload)
        written += UInt32(header.count + payload.count)

        directory.append(Self.u32(0x0201_4b50))
        directory.append(Self.u16(20))                  // version made by
        directory.append(Self.u16(20))                  // version needed
        directory.append(Self.u16(flags))
        directory.append(Self.u16(method))
        directory.append(Self.u16(0))
        directory.append(Self.u16(0))
        directory.append(Self.u32(crc))
        directory.append(Self.u32(UInt32(payload.count)))
        directory.append(Self.u32(UInt32(entry.data.count)))
        directory.append(Self.u16(UInt16(name.count)))
        directory.append(Self.u16(0))                   // extra field length
        directory.append(Self.u16(0))                   // comment length
        directory.append(Self.u16(0))                   // disk number
        directory.append(Self.u16(0))                   // internal attributes
        directory.append(Self.u32(0))                   // external attributes
        directory.append(Self.u32(offset))
        directory.append(name)
        count += 1
    }

    /// Writes the central directory and closes the file. Nothing may be appended
    /// afterwards, and a file left unfinished is not a readable archive — which
    /// is what makes an abandoned export easy to recognise as one.
    func finish() throws {
        var trailer = directory
        trailer.append(Self.u32(0x0605_4b50))
        trailer.append(Self.u16(0))                     // this disk
        trailer.append(Self.u16(0))                     // disk with directory
        trailer.append(Self.u16(count))
        trailer.append(Self.u16(count))
        trailer.append(Self.u32(UInt32(directory.count)))
        trailer.append(Self.u32(written))
        trailer.append(Self.u16(0))                     // comment length
        try handle.write(contentsOf: trailer)
        try handle.close()
    }

    /// Raw DEFLATE, which is what ZIP stores — `COMPRESSION_ZLIB` in this API
    /// carries no zlib wrapper despite the name.
    ///
    /// Returns nil when the entry is better off stored, and the destination
    /// buffer is deliberately the size of the input to make that the same
    /// answer: `compression_encode_buffer` reports 0 both when it fails and when
    /// the result would not fit, and an entry that does not compress is one we
    /// have no reason to compress.
    private static func deflate(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        var output = Data(count: data.count)
        let written = output.withUnsafeMutableBytes { destination -> Int in
            guard let target = destination.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return data.withUnsafeBytes { source -> Int in
                guard let origin = source.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_encode_buffer(
                    target, data.count, origin, data.count, nil, COMPRESSION_ZLIB
                )
            }
        }
        guard written > 0 else { return nil }
        return output.prefix(written)
    }

    // MARK: - Little-endian writes

    private static func u16(_ value: UInt16) -> Data {
        Data([UInt8(value & 0xff), UInt8(value >> 8 & 0xff)])
    }

    private static func u32(_ value: UInt32) -> Data {
        Data([
            UInt8(value & 0xff),
            UInt8(value >> 8 & 0xff),
            UInt8(value >> 16 & 0xff),
            UInt8(value >> 24 & 0xff),
        ])
    }
}
