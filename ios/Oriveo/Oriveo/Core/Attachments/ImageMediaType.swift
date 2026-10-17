import Foundation

/// The MIME sent upstream for an image follows its actual bytes; the attachment's declared MIME is only a fallback.
///
/// Anthropic rejects images whose media_type doesn't match the bytes (400 "Image does not match the provided
/// media type"), and so does a relay that forwards a data URL to Claude. Attachments created by older builds of
/// other clients can carry the picker's MIME on compressed JPEG bytes. Only the first 12 bytes are decoded.
enum ImageMediaType {
    static func resolve(base64: String, declared: String) -> String {
        sniff(base64: base64) ?? declared
    }

    static func sniff(base64: String) -> String? {
        // Drop line breaks and other non-base64 characters first, or wrapped base64 won't form a multiple of 4 and fails to decode
        let head = String(base64.prefix(headScanChars).filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "+" || $0 == "/") }
            .prefix(headBase64Chars))
        guard head.count == headBase64Chars, let data = Data(base64Encoded: head) else { return nil }
        let bytes = [UInt8](data)
        func ascii(_ from: Int, _ text: String) -> Bool {
            let expected = Array(text.utf8)
            return bytes.count >= from + expected.count && Array(bytes[from..<from + expected.count]) == expected
        }
        if bytes[0] == 0xFF, bytes[1] == 0xD8, bytes[2] == 0xFF { return "image/jpeg" }
        if bytes[0] == 0x89, ascii(1, "PNG") { return "image/png" }
        if ascii(0, "GIF8") { return "image/gif" }
        if ascii(0, "RIFF"), ascii(8, "WEBP") { return "image/webp" }
        return nil
    }

    /// 16 base64 characters decode to exactly 12 bytes, enough to see WebP (bytes 8-11)
    private static let headBase64Chars = 16
    private static let headScanChars = 64
}
