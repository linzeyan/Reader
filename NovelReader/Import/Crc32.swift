import Foundation

/// CRC-32 as ZIP records it: the IEEE 802.3 polynomial, reflected.
///
/// Written out rather than reached for in a framework — the only CRC-32 the
/// system ships is zlib's, which is not exposed to Swift, and the table below is
/// the entire algorithm. It lives on its own rather than inside either half of
/// the ZIP support because both need it: the reader to check what it just
/// decompressed, the writer to record what it stored.
enum Crc32 {
    /// The reflected table, built once. Deriving it per call would add 2048
    /// shifts on top of every entry, which is invisible on a `container.xml` and
    /// very visible on a thousand-chapter export.
    private static let table: [UInt32] = (0 ..< 256).map { index in
        var value = UInt32(index)
        for _ in 0 ..< 8 {
            value = value & 1 == 1 ? (value >> 1) ^ 0xedb8_8320 : value >> 1
        }
        return value
    }

    /// Generic over the byte sequence so the reader can hand in the slice it
    /// already has without copying it into a `Data` first.
    static func compute<Bytes: Sequence>(_ bytes: Bytes) -> UInt32 where Bytes.Element == UInt8 {
        var crc: UInt32 = 0xffff_ffff
        for byte in bytes {
            crc = (crc >> 8) ^ table[Int((crc ^ UInt32(byte)) & 0xff)]
        }
        return crc ^ 0xffff_ffff
    }
}
