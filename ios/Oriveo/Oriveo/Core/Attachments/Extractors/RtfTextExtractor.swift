import CoreFoundation
import Foundation

/// RTF extraction (attachment extraction spec section 11): the same hand-written tokenizer on all three platforms (modeled on python striprtf), not `NSAttributedString`,
/// to guarantee byte-for-byte identical output. Finally apply section 3.1 normalization.
nonisolated enum RtfTextExtractor {
    static let deadlineCheckInterval = 65_536

    static func extract(data: Data, deadline: ExtractionDeadline = ExtractionDeadline()) throws -> String {
        var parser = Parser(bytes: [UInt8](data), deadline: deadline)
        return StructuredTextFormat.normalize(try parser.run())
    }

    // MARK: - Rule tables

    /// Destinations ignored as a whole group (`fonttbl` is parsed for fonts first, then ignored).
    private static let ignoredDestinations: Set<String> = [
        "fonttbl", "colortbl", "stylesheet", "listtable", "listoverridetable", "revtbl", "rsidtbl", "info", "pict",
        "shppict", "nonshppict", "object", "themedata", "datastore", "latentstyles", "xmlnstbl", "generator",
        "fldinst", "header", "headerl", "headerr", "headerf", "footer", "footerl", "footerr", "footerf",
    ]

    private static let wordOutput: [String: String] = [
        "par": "\n", "line": "\n", "sect": "\n\n", "page": "\n\n",
        "tab": "\t", "cell": "\t", "nestcell": "\t", "row": "\n", "nestrow": "\n",
        "emdash": "\u{2014}", "endash": "\u{2013}", "bullet": "\u{2022}",
        "lquote": "\u{2018}", "rquote": "\u{2019}", "ldblquote": "\u{201C}", "rdblquote": "\u{201D}",
    ]

    /// `\fcharset` -> code page; nil means use `\ansicpg`.
    private static func codePage(forCharset charset: Int) -> Int? {
        switch charset {
        case 0, 1: return nil
        case 77: return 10000
        case 128: return 932
        case 129: return 949
        case 134: return 936
        case 136: return 950
        case 161: return 1253
        case 162: return 1254
        case 163: return 1258
        case 177: return 1255
        case 178: return 1256
        case 186: return 1257
        case 204: return 1251
        case 222: return 874
        case 238: return 1250
        default: return 1252
        }
    }

    private static func isDoubleByte(_ codePage: Int) -> Bool {
        [932, 936, 949, 950].contains(codePage)
    }

    private static func isLeadByte(_ byte: UInt8, codePage: Int) -> Bool {
        switch codePage {
        case 932: return (0x81...0x9F).contains(byte) || (0xE0...0xFC).contains(byte)
        case 936, 949, 950: return (0x81...0xFE).contains(byte)
        default: return false
        }
    }

    /// Decode a run of bytes by code page; units that fail to decode output U+FFFD.
    static func decode(_ bytes: [UInt8], codePage: Int) -> String {
        switch codePage {
        case 1252, 10000, 437, 850:
            return PlainTextExtractor.decode(bytes[...], as: .windows1252) ?? ""
        case 1251:
            return PlainTextExtractor.decode(bytes[...], as: .windows1251) ?? ""
        case 936, 950, 932, 949:
            let candidate: TextCharsetCandidate = codePage == 936 ? .gb18030 : codePage == 950 ? .big5 : codePage == 932 ? .shiftJIS : .eucKR
            if let text = PlainTextExtractor.decode(bytes[...], as: candidate) { return text }
            // Whole run failed: decode unit by unit (lead byte + trail byte, or a single byte).
            var result = ""
            var index = 0
            while index < bytes.count {
                let length = isLeadByte(bytes[index], codePage: codePage) && index + 1 < bytes.count ? 2 : 1
                result += PlainTextExtractor.decode(bytes[index..<(index + length)], as: candidate) ?? "\u{FFFD}"
                index += length
            }
            return result
        default:
            let encoding = CFStringConvertWindowsCodepageToEncoding(UInt32(codePage))
            guard encoding != kCFStringEncodingInvalidId else {
                return PlainTextExtractor.decode(bytes[...], as: .windows1252) ?? ""
            }
            let nsEncoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(encoding))
            return bytes.map { String(data: Data([$0]), encoding: nsEncoding) ?? "\u{FFFD}" }.joined()
        }
    }

    // MARK: - tokenizer

    private struct FontInfo {
        var charset: Int?
        var codePage: Int?
    }

    private struct GroupState {
        var ucSkip = 1
        var ignorable = false
        var hidden = false
        var font: Int?
        var inFontTable = false
        var isUpr = false
        /// This group just read `\*`; look at the next control word to decide (`\*\ud` inside `\upr` is read as usual).
        var starPending = false
    }

    private struct Parser {
        let bytes: [UInt8]
        let deadline: ExtractionDeadline
        var index = 0
        var nextDeadlineCheck = 0

        var stack: [GroupState] = []
        var state = GroupState()
        var depth = 0
        var ansiCodePage = 1252
        var defaultFont: Int?
        var fonts: [Int: FontInfo] = [:]
        var fontTableCurrent: Int?

        var out = ""
        var pendingBytes: [UInt8] = []
        var pendingBytesCodePage = 1252
        var awaitingTrailByte = false
        var pendingHighSurrogate: UInt16?
        var skipRemaining = 0

        init(bytes: [UInt8], deadline: ExtractionDeadline) {
            self.bytes = bytes
            self.deadline = deadline
        }

        var suppressed: Bool { state.ignorable || state.hidden }

        var currentCodePage: Int {
            if let font = state.font ?? defaultFont, let info = fonts[font] {
                if let cpg = info.codePage { return cpg }
                if let charset = info.charset { return RtfTextExtractor.codePage(forCharset: charset) ?? ansiCodePage }
            }
            return ansiCodePage
        }

        mutating func run() throws -> String {
            while index < bytes.count {
                if index >= nextDeadlineCheck {
                    try deadline.check()
                    nextDeadlineCheck = index + RtfTextExtractor.deadlineCheckInterval
                }
                let byte = bytes[index]
                // Content before the outermost group is ignored (an escaped symbol is skipped together with the following byte).
                if depth == 0, byte != UInt8(ascii: "{") {
                    index += byte == UInt8(ascii: "\\") ? 2 : 1
                    continue
                }
                switch byte {
                case UInt8(ascii: "{"):
                    index += 1
                    skipRemaining = 0
                    flushBytes()
                    stack.append(state)
                    state.starPending = false
                    state.isUpr = false
                    depth += 1
                case UInt8(ascii: "}"):
                    index += 1
                    skipRemaining = 0
                    flushBytes()
                    guard depth > 0 else { continue }
                    state = stack.removeLast()
                    depth -= 1
                    // Content after the outermost group ends is ignored.
                    if depth == 0 { return finish() }
                case UInt8(ascii: "\\"):
                    try readControl()
                case 0x0D, 0x0A:
                    index += 1
                default:
                    index += 1
                    if skipRemaining > 0 {
                        skipRemaining -= 1
                        continue
                    }
                    if byte >= 0x80 {
                        appendByte(byte)
                    } else {
                        appendLiteral(byte)
                    }
                }
            }
            return finish()
        }

        mutating func finish() -> String {
            flushBytes()
            flushSurrogate()
            return out
        }

        // MARK: Control tokens

        mutating func readControl() throws {
            index += 1
            guard index < bytes.count else { return }
            let next = bytes[index]
            if isLetter(next) {
                let start = index
                while index < bytes.count, isLetter(bytes[index]) { index += 1 }
                let word = String(decoding: bytes[start..<index], as: UTF8.self)
                var parameter: Int?
                let paramStart = index
                if index < bytes.count, bytes[index] == UInt8(ascii: "-") { index += 1 }
                let digitsStart = index
                while index < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[index]) { index += 1 }
                if index > digitsStart {
                    parameter = Int(String(decoding: bytes[paramStart..<index], as: UTF8.self))
                } else {
                    index = paramStart
                }
                if index < bytes.count, bytes[index] == UInt8(ascii: " ") { index += 1 }
                handleWord(word, parameter: parameter)
                return
            }

            index += 1
            if next == UInt8(ascii: "'") {
                guard index + 1 < bytes.count, let value = UInt8(String(decoding: bytes[index...(index + 1)], as: UTF8.self), radix: 16) else {
                    return
                }
                index += 2
                if consumeSkipUnit() { return }
                appendByte(value)
                return
            }
            if consumeSkipUnit() { return }
            switch next {
            case UInt8(ascii: "\\"), UInt8(ascii: "{"), UInt8(ascii: "}"):
                appendLiteral(next)
            case UInt8(ascii: "~"):
                emit(" ")
            case UInt8(ascii: "_"):
                emit("-")
            case UInt8(ascii: "*"):
                flushBytes()
                state.ignorable = true
                state.starPending = true
            case 0x0D, 0x0A:
                emit("\n")
            default:
                // `\-` and other control symbols produce no output.
                flushBytes()
            }
        }

        /// ucSkip fallback skip: consume one unit and return true.
        mutating func consumeSkipUnit() -> Bool {
            guard skipRemaining > 0 else { return false }
            skipRemaining -= 1
            return true
        }

        mutating func handleWord(_ word: String, parameter: Int?) {
            let starWasPending = state.starPending
            state.starPending = false

            if word == "bin" {
                // Skip the following N raw bytes; during fallback skipping this also counts as one unit.
                index = min(bytes.count, index + max(0, parameter ?? 0))
                _ = consumeSkipUnit()
                return
            }
            if word == "u" {
                if consumeSkipUnit() { return }
                flushBytes()
                var value = parameter ?? 0
                if value < 0 { value += 65_536 }
                if !suppressed { emitUnicode(UInt16(truncatingIfNeeded: value)) }
                skipRemaining = state.ucSkip
                return
            }
            if consumeSkipUnit() { return }
            flushBytes()

            if starWasPending, word == "ud", stack.last?.isUpr == true {
                state.ignorable = stack.count >= 2 ? stack[stack.count - 2].ignorable : false
                return
            }
            if state.inFontTable {
                switch word {
                case "f": fontTableCurrent = parameter
                case "fcharset": if let id = fontTableCurrent, let parameter { fonts[id, default: FontInfo()].charset = parameter }
                case "cpg": if let id = fontTableCurrent, let parameter { fonts[id, default: FontInfo()].codePage = parameter }
                default: break
                }
                return
            }
            if word == "fonttbl" {
                state.ignorable = true
                state.inFontTable = true
                return
            }
            if RtfTextExtractor.ignoredDestinations.contains(word) {
                state.ignorable = true
                return
            }
            switch word {
            case "upr":
                state.ignorable = true
                state.isUpr = true
            case "uc":
                state.ucSkip = max(0, parameter ?? 1)
            case "f":
                state.font = parameter
            case "deff":
                defaultFont = parameter
            case "ansicpg":
                if let parameter { ansiCodePage = parameter }
            case "mac":
                ansiCodePage = 10000
            case "pc":
                ansiCodePage = 437
            case "pca":
                ansiCodePage = 850
            case "v":
                state.hidden = parameter != 0
            case "plain":
                state.hidden = false
            default:
                if let text = RtfTextExtractor.wordOutput[word] { emit(text) }
            }
        }

        // MARK: Output

        mutating func appendByte(_ byte: UInt8) {
            guard !suppressed else { return }
            let codePage = currentCodePage
            if !pendingBytes.isEmpty, codePage != pendingBytesCodePage { flushBytes() }
            if pendingBytes.isEmpty {
                pendingBytesCodePage = codePage
                awaitingTrailByte = false
            }
            pendingBytes.append(byte)
            if awaitingTrailByte {
                awaitingTrailByte = false
            } else if RtfTextExtractor.isDoubleByte(codePage) {
                awaitingTrailByte = RtfTextExtractor.isLeadByte(byte, codePage: codePage)
            }
        }

        /// Ordinary character; under a double-byte code page, a literal 0x40-0x7E character right after a lead byte counts as the trail byte.
        mutating func appendLiteral(_ byte: UInt8) {
            guard !suppressed else { return }
            if awaitingTrailByte, !pendingBytes.isEmpty, (0x40...0x7E).contains(byte) {
                pendingBytes.append(byte)
                awaitingTrailByte = false
                return
            }
            emit(String(UnicodeScalar(byte)))
        }

        mutating func emit(_ text: String) {
            flushBytes()
            guard !suppressed else { return }
            flushSurrogate()
            out += text
        }

        mutating func emitUnicode(_ unit: UInt16) {
            switch unit {
            case 0xD800...0xDBFF:
                flushSurrogate()
                pendingHighSurrogate = unit
            case 0xDC00...0xDFFF:
                if let high = pendingHighSurrogate {
                    pendingHighSurrogate = nil
                    let scalar = 0x10000 + ((UInt32(high) - 0xD800) << 10) + (UInt32(unit) - 0xDC00)
                    out.unicodeScalars.append(Unicode.Scalar(scalar) ?? "\u{FFFD}")
                } else {
                    out += "\u{FFFD}"
                }
            default:
                flushSurrogate()
                out.unicodeScalars.append(Unicode.Scalar(unit) ?? "\u{FFFD}")
            }
        }

        mutating func flushSurrogate() {
            if pendingHighSurrogate != nil {
                pendingHighSurrogate = nil
                out += "\u{FFFD}"
            }
        }

        mutating func flushBytes() {
            guard !pendingBytes.isEmpty else { return }
            let chunk = pendingBytes
            pendingBytes.removeAll()
            awaitingTrailByte = false
            flushSurrogate()
            out += RtfTextExtractor.decode(chunk, codePage: pendingBytesCodePage)
        }

        func isLetter(_ byte: UInt8) -> Bool {
            (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte) || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
        }
    }
}
