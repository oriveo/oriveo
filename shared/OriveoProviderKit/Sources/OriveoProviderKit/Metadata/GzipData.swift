import Foundation

/// gzip (RFC 1952) decompression. Foundation's `.zlib` algorithm takes raw DEFLATE (RFC 1951),
/// so this strips the gzip header (including the optional FEXTRA / FNAME / FCOMMENT / FHCRC sections) and
/// the 8-byte trailer (CRC32 + ISIZE) itself, and hands only the DEFLATE stream in between to Foundation.
/// Only single-member gzip is supported: the bundled metadata snapshot is compressed in one pass and is never a multi-member concatenation.
public enum GzipData {
    public enum GzipError: Error, Equatable, Sendable {
        /// The magic number is not 1f 8b, or a flag bit that RFC 1952 requires to be 0 is set.
        case notGzip
        /// The compression method is not 8 (deflate).
        case unsupportedMethod(UInt8)
        /// The optional header sections or the trailer are too short.
        case truncated
        /// The DEFLATE stream itself cannot be decompressed.
        case decompressionFailed
    }

    private static let flagHeaderCRC: UInt8 = 0x02
    private static let flagExtra: UInt8 = 0x04
    private static let flagName: UInt8 = 0x08
    private static let flagComment: UInt8 = 0x10
    private static let flagReserved: UInt8 = 0xE0
    private static let fixedHeaderLength = 10
    private static let trailerLength = 8

    public static func gunzip(_ data: Data) throws -> Data {
        let bytes = [UInt8](data)
        guard bytes.count >= 2, bytes[0] == 0x1F, bytes[1] == 0x8B else { throw GzipError.notGzip }
        guard bytes.count >= fixedHeaderLength else { throw GzipError.truncated }
        guard bytes[2] == 8 else { throw GzipError.unsupportedMethod(bytes[2]) }
        let flags = bytes[3]
        guard flags & flagReserved == 0 else { throw GzipError.notGzip }

        var cursor = fixedHeaderLength
        if flags & flagExtra != 0 {
            guard cursor + 2 <= bytes.count else { throw GzipError.truncated }
            let extraLength = Int(bytes[cursor]) | (Int(bytes[cursor + 1]) << 8)
            cursor += 2 + extraLength
        }
        if flags & flagName != 0 { cursor = try skipZeroTerminated(bytes, from: cursor) }
        if flags & flagComment != 0 { cursor = try skipZeroTerminated(bytes, from: cursor) }
        if flags & flagHeaderCRC != 0 { cursor += 2 }

        let bodyEnd = bytes.count - trailerLength
        guard cursor <= bodyEnd else { throw GzipError.truncated }
        let raw = Data(bytes[cursor ..< bodyEnd])
        do {
            return try (raw as NSData).decompressed(using: .zlib) as Data
        } catch {
            throw GzipError.decompressionFailed
        }
    }

    /// Skips a zero-terminated ISO 8859-1 string (FNAME / FCOMMENT) and returns the position after the 0.
    private static func skipZeroTerminated(_ bytes: [UInt8], from start: Int) throws -> Int {
        var cursor = start
        while cursor < bytes.count {
            if bytes[cursor] == 0 { return cursor + 1 }
            cursor += 1
        }
        throw GzipError.truncated
    }
}
