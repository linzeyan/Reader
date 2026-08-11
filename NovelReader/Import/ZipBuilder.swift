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
/// Output is deterministic: modification times are written as zero rather than
/// as "now", and nothing else in an entry depends on the clock. Exporting the
/// same book twice therefore produces byte-identical files, which is what makes
/// re-importing an export land on the book it came from — `LocalBookImporter`
/// identifies an imported book by the digest of the file's bytes, so a timestamp
/// in here would quietly turn every export into a new book.
struct ZipBuilder {
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

    /// Entries are written in the order given, which is the order a reader sees
    /// them in the file.
    static func archive(_ entries: [Entry]) -> Data {
        var output = Data()
        var directory = Data()
        var count: UInt16 = 0

        for entry in entries {
            let name = Data(entry.name.utf8)
            let offset = UInt32(output.count)
            let deflated = entry.compressed ? deflate(entry.data) : nil
            let payload = deflated ?? entry.data
            let method: UInt16 = deflated == nil ? 0 : 8
            let crc = Crc32.compute(entry.data)
            // Bit 11 says the name is UTF-8. Every name this app writes is ASCII,
            // but the flag costs one comparison and its absence on a non-ASCII
            // name is how entry names come out mangled in other readers.
            let flags: UInt16 = name.allSatisfy { $0 < 0x80 } ? 0 : 1 << 11

            output.append(u32(0x0403_4b50))
            output.append(u16(20))                          // version needed: 2.0
            output.append(u16(flags))
            output.append(u16(method))
            output.append(u16(0))                           // modification time
            output.append(u16(0))                           // modification date
            output.append(u32(crc))
            output.append(u32(UInt32(payload.count)))
            output.append(u32(UInt32(entry.data.count)))
            output.append(u16(UInt16(name.count)))
            output.append(u16(0))                           // extra field length
            output.append(name)
            output.append(payload)

            directory.append(u32(0x0201_4b50))
            directory.append(u16(20))                       // version made by
            directory.append(u16(20))                       // version needed
            directory.append(u16(flags))
            directory.append(u16(method))
            directory.append(u16(0))
            directory.append(u16(0))
            directory.append(u32(crc))
            directory.append(u32(UInt32(payload.count)))
            directory.append(u32(UInt32(entry.data.count)))
            directory.append(u16(UInt16(name.count)))
            directory.append(u16(0))                        // extra field length
            directory.append(u16(0))                        // comment length
            directory.append(u16(0))                        // disk number
            directory.append(u16(0))                        // internal attributes
            directory.append(u32(0))                        // external attributes
            directory.append(u32(offset))
            directory.append(name)
            count += 1
        }

        let directoryOffset = UInt32(output.count)
        output.append(directory)
        output.append(u32(0x0605_4b50))
        output.append(u16(0))                               // this disk
        output.append(u16(0))                               // disk with directory
        output.append(u16(count))
        output.append(u16(count))
        output.append(u32(UInt32(directory.count)))
        output.append(u32(directoryOffset))
        output.append(u16(0))                               // comment length
        return output
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
