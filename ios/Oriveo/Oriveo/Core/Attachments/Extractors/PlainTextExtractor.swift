import Foundation

enum PlainTextExtractor {
    static func extract(data: Data) throws -> String {
        if data.starts(with: [0xEF, 0xBB, 0xBF]),
           let s = String(data: data.dropFirst(3), encoding: .utf8) {
            return s
        }

        if data.starts(with: [0xFF, 0xFE]), let s = String(data: data, encoding: .utf16LittleEndian) {
            return s
        }
        if data.starts(with: [0xFE, 0xFF]), let s = String(data: data, encoding: .utf16BigEndian) {
            return s
        }

        if let s = String(data: data, encoding: .utf8) {
            return s
        }
        if let s = String(data: data, encoding: .utf16) {
            return s
        }

        let gb18030 = CFStringConvertEncodingToNSStringEncoding(0x80000632)
        if let s = String(data: data, encoding: String.Encoding(rawValue: gb18030)) {
            return s
        }

        let sjis = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.shiftJIS.rawValue))
        if let s = String(data: data, encoding: String.Encoding(rawValue: sjis)) {
            return s
        }

        let lossy = String(data: data, encoding: .ascii) ?? ""
        return lossy + "\n[encoding detection failed, content may be garbled]"
    }
}
