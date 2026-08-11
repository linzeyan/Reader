import Compression
import Foundation

/// Builds ZIP archives for the import tests.
///
/// Written by hand rather than checked in as a binary fixture: an EPUB is the
/// only archive this app reads, and a test that *constructs* one can say exactly
/// which part of the format it is exercising — a stored entry, a deflated one, an
/// encrypted flag — where an opaque `.epub` in the repo could only say "this file
/// works".
enum ZipWriter {
    struct Entry {
        let name: String
        let data: Data
        /// Both storage methods an EPUB uses, and the only two `ZipArchive`
        /// supports. `mimetype` is required by the spec to be stored.
        let deflated: Bool
        /// Sets the general-purpose "encrypted" flag without actually encrypting
        /// anything, which is enough to check that the reader refuses.
        let encrypted: Bool
        /// Overrides the compression method field, for the "we do not support
        /// that" path.
        let methodOverride: UInt16?

        init(
            name: String,
            data: Data,
            deflated: Bool = false,
            encrypted: Bool = false,
            methodOverride: UInt16? = nil
        ) {
            self.name = name
            self.data = data
            self.deflated = deflated
            self.encrypted = encrypted
            self.methodOverride = methodOverride
        }

        init(name: String, text: String, deflated: Bool = false) {
            self.init(name: name, data: Data(text.utf8), deflated: deflated)
        }
    }

    static func archive(_ entries: [Entry]) -> Data {
        var output = Data()
        var directory = Data()
        var count: UInt16 = 0

        for entry in entries {
            let payload = entry.deflated ? deflate(entry.data) : entry.data
            let method = entry.methodOverride ?? (entry.deflated ? 8 : 0)
            let flags: UInt16 = entry.encrypted ? 1 : 0
            let name = Data(entry.name.utf8)
            let offset = UInt32(output.count)
            let crc = crc32(entry.data)

            output.append(u32(0x0403_4b50))
            output.append(u16(20))                      // version needed
            output.append(u16(flags))
            output.append(u16(method))
            output.append(u16(0))                       // time
            output.append(u16(0))                       // date
            output.append(u32(crc))
            output.append(u32(UInt32(payload.count)))
            output.append(u32(UInt32(entry.data.count)))
            output.append(u16(UInt16(name.count)))
            output.append(u16(0))                       // extra length
            output.append(name)
            output.append(payload)

            directory.append(u32(0x0201_4b50))
            directory.append(u16(20))                   // version made by
            directory.append(u16(20))                   // version needed
            directory.append(u16(flags))
            directory.append(u16(method))
            directory.append(u16(0))
            directory.append(u16(0))
            directory.append(u32(crc))
            directory.append(u32(UInt32(payload.count)))
            directory.append(u32(UInt32(entry.data.count)))
            directory.append(u16(UInt16(name.count)))
            directory.append(u16(0))                    // extra length
            directory.append(u16(0))                    // comment length
            directory.append(u16(0))                    // disk number
            directory.append(u16(0))                    // internal attributes
            directory.append(u32(0))                    // external attributes
            directory.append(u32(offset))
            directory.append(name)
            count += 1
        }

        let directoryOffset = UInt32(output.count)
        output.append(directory)
        output.append(u32(0x0605_4b50))
        output.append(u16(0))                           // this disk
        output.append(u16(0))                           // disk with directory
        output.append(u16(count))
        output.append(u16(count))
        output.append(u32(UInt32(directory.count)))
        output.append(u32(directoryOffset))
        output.append(u16(0))                           // comment length
        return output
    }

    /// Raw DEFLATE, which is what ZIP stores — `COMPRESSION_ZLIB` in this API
    /// carries no zlib wrapper despite the name.
    private static func deflate(_ data: Data) -> Data {
        // Generously sized: a tiny input can compress to slightly more than
        // itself, and this is a fixture builder, not a library.
        let capacity = data.count + 1_024
        var output = Data(count: capacity)
        let written = output.withUnsafeMutableBytes { destination -> Int in
            data.withUnsafeBytes { source -> Int in
                compression_encode_buffer(
                    destination.bindMemory(to: UInt8.self).baseAddress!, capacity,
                    source.bindMemory(to: UInt8.self).baseAddress!, data.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        return output.prefix(written)
    }

    /// Computed here rather than through the app's own `Crc32`, deliberately: the
    /// reader verifies this field, and a fixture that borrowed the very code under
    /// test would agree with it even if both were wrong.
    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffff_ffff
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0 ..< 8 {
                crc = (crc & 1) == 1 ? (crc >> 1) ^ 0xedb8_8320 : crc >> 1
            }
        }
        return crc ^ 0xffff_ffff
    }

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
