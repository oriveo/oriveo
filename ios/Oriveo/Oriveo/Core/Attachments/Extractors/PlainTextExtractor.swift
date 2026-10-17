import Foundation

/// Candidates for plain-text encoding detection (attachment extraction spec section 4); declaration order is the candidate order (the second tiebreaker on equal scores).
nonisolated enum TextCharsetCandidate: String, CaseIterable, Sendable {
    case gb18030
    case shiftJIS = "shift_jis"
    case big5
    case eucKR = "euc-kr"
    case windows1252 = "windows-1252"
    case windows1251 = "windows-1251"

    var isMultiByte: Bool {
        switch self {
        case .gb18030, .shiftJIS, .big5, .eucKR: return true
        case .windows1252, .windows1251: return false
        }
    }

    /// CF decoders (iOS column of the decoder table in spec section 4): GB_18030_2000, DOSJapanese (cp932), Big5_HKSCS_1999, DOSKorean (cp949).
    fileprivate var cfEncoding: CFStringEncoding? {
        switch self {
        case .gb18030: return 0x0632
        case .shiftJIS: return 0x0420
        case .big5: return 0x0A06
        case .eucKR: return 0x0422
        case .windows1252, .windows1251: return nil
        }
    }
}

/// Plain-text decoding (attachment extraction spec section 4): BOM -> NUL bytes decide UTF-16 / binary -> strict UTF-8 -> score the six candidates.
/// The same deterministic algorithm on all three platforms; the score tables match the fixture `charset-tables.v1.json` entry by entry (verified by a contract test).
nonisolated enum PlainTextExtractor {
    static let sampleLimit = 65_536
    static let nulScanLimit = 4_096

    /// UI language -> candidate used to break ties (fixture `localeTieBreak`). The UI language only breaks ties and adds no score.
    static let localeTieBreak: [ExtractionUILanguage: TextCharsetCandidate] = [
        .zhHans: .gb18030,
        .zhHant: .big5,
        .ja: .shiftJIS,
        .ko: .eucKR,
        .ru: .windows1251,
    ]

    static func extract(data: Data, uiLanguage: ExtractionUILanguage) throws -> String {
        let bytes = [UInt8](data)
        return normalizeNewlines(try decode(bytes, uiLanguage: uiLanguage))
    }

    // MARK: - Decoding

    static func decode(_ bytes: [UInt8], uiLanguage: ExtractionUILanguage) throws -> String {
        // 1. BOM: strip it and decode the whole input in that encoding; failure means corrupted.
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
            guard let text = decodeUTF8(bytes[3...]) else { throw ExtractionError(code: .corruptedFile, underlying: "invalid UTF-8 after BOM") }
            return text
        }
        if bytes.starts(with: [0xFF, 0xFE]) {
            guard let text = decodeUTF16(bytes[2...], bigEndian: false) else { throw ExtractionError(code: .corruptedFile, underlying: "invalid UTF-16LE after BOM") }
            return text
        }
        if bytes.starts(with: [0xFE, 0xFF]) {
            guard let text = decodeUTF16(bytes[2...], bigEndian: true) else { throw ExtractionError(code: .corruptedFile, underlying: "invalid UTF-16BE after BOM") }
            return text
        }

        // 2. NUL bytes: look only at the first 4096 bytes; odd index -> UTF-16LE, even index -> UTF-16BE, both present -> binary.
        var nulAtOdd = false
        var nulAtEven = false
        for index in 0..<min(bytes.count, nulScanLimit) where bytes[index] == 0 {
            if index % 2 == 1 { nulAtOdd = true } else { nulAtEven = true }
        }
        if nulAtOdd || nulAtEven {
            guard nulAtOdd != nulAtEven, let text = decodeUTF16(bytes[...], bigEndian: nulAtEven) else {
                throw ExtractionError(code: .unsupportedFormat, underlying: "binary content")
            }
            return text
        }

        // 3. Strict UTF-8 (pure ASCII counts too).
        if let text = decodeUTF8(bytes[...]) { return text }

        // 4. Candidate scoring -> 5. strictly decode the whole input in rank order; the first success is the result.
        for candidate in rankedCandidates(bytes, uiLanguage: uiLanguage) {
            if let text = decode(bytes[...], as: candidate) { return text }
        }
        // windows-1252 / 1251 can always decode, so execution never reaches here.
        throw ExtractionError(code: .extractionError, underlying: "no charset candidate decoded")
    }

    /// Surviving candidates sorted by score, high to low; on equal scores the candidate matching the UI language comes first, then candidate order.
    static func rankedCandidates(_ bytes: [UInt8], uiLanguage: ExtractionUILanguage) -> [TextCharsetCandidate] {
        let sample = Array(bytes.prefix(sampleLimit))
        let truncated = sample.count < bytes.count
        let preferred = localeTieBreak[uiLanguage]
        var scored: [(candidate: TextCharsetCandidate, score: Double, order: Int)] = []
        for (order, candidate) in TextCharsetCandidate.allCases.enumerated() {
            if candidate.isMultiByte, !survivesSample(sample, as: candidate, truncated: truncated) { continue }
            scored.append((candidate, score(sample, as: candidate), order))
        }
        scored.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            let lhsPreferred = lhs.candidate == preferred
            let rhsPreferred = rhs.candidate == preferred
            if lhsPreferred != rhsPreferred { return lhsPreferred }
            return lhs.order < rhs.order
        }
        return scored.map(\.candidate)
    }

    /// Multibyte candidates first strictly decode the sample; on failure, if the sample is shorter than the whole input, retry after dropping 1, 2, 3 trailing bytes in turn.
    private static func survivesSample(_ sample: [UInt8], as candidate: TextCharsetCandidate, truncated: Bool) -> Bool {
        if decode(sample[...], as: candidate) != nil { return true }
        guard truncated else { return false }
        for drop in 1...3 where sample.count > drop {
            if decode(sample.dropLast(drop), as: candidate) != nil { return true }
        }
        return false
    }

    static func decode(_ bytes: ArraySlice<UInt8>, as candidate: TextCharsetCandidate) -> String? {
        switch candidate {
        case .windows1252: return decodeSingleByte(bytes, high: windows1252High)
        case .windows1251: return decodeSingleByte(bytes, high: windows1251High)
        case .gb18030, .shiftJIS, .big5, .eucKR:
            guard let cf = candidate.cfEncoding else { return nil }
            let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
            return String(data: Data(bytes), encoding: encoding)
        }
    }

    private static func decodeUTF8(_ bytes: ArraySlice<UInt8>) -> String? {
        String(validating: bytes, as: UTF8.self)
    }

    private static func decodeUTF16(_ bytes: ArraySlice<UInt8>, bigEndian: Bool) -> String? {
        guard bytes.count % 2 == 0 else { return nil }
        var units: [UInt16] = []
        units.reserveCapacity(bytes.count / 2)
        var index = bytes.startIndex
        while index < bytes.endIndex {
            let first = UInt16(bytes[index])
            let second = UInt16(bytes[index + 1])
            units.append(bigEndian ? (first << 8 | second) : (second << 8 | first))
            index += 2
        }
        return String(validating: units, as: UTF16.self)
    }

    private static func decodeSingleByte(_ bytes: ArraySlice<UInt8>, high: [UInt32]) -> String {
        var scalars = String.UnicodeScalarView()
        scalars.reserveCapacity(bytes.count)
        for byte in bytes {
            let value = byte < 0x80 ? UInt32(byte) : high[Int(byte) - 0x80]
            if let scalar = Unicode.Scalar(value) { scalars.append(scalar) }
        }
        return String(scalars)
    }

    /// Plain text only does `\r\n` / `\r` -> `\n` (spec section 3.1), with no trim and no blank-line compression.
    static func normalizeNewlines(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        var pendingCR = false
        for scalar in text.unicodeScalars {
            if pendingCR {
                pendingCR = false
                scalars.append("\n")
                if scalar == "\n" { continue }
            }
            if scalar == "\r" { pendingCR = true } else { scalars.append(scalar) }
        }
        if pendingCR { scalars.append("\n") }
        return String(scalars)
    }

    // MARK: - Scoring (spec section 4)

    static func score(_ sample: [UInt8], as candidate: TextCharsetCandidate) -> Double {
        switch candidate {
        case .gb18030, .shiftJIS, .big5, .eucKR: return multiByteScore(sample, as: candidate)
        case .windows1252: return windows1252Score(sample)
        case .windows1251: return windows1251Score(sample)
        }
    }

    private static func multiByteScore(_ sample: [UInt8], as candidate: TextCharsetCandidate) -> Double {
        let common = commonCharSets[candidate] ?? []
        var total = 0.0
        var index = 0
        let count = sample.count
        while index < count {
            let lead = sample[index]
            if lead < 0x80 {
                index += 1
                continue
            }
            if candidate == .shiftJIS, (0xA1...0xDF).contains(lead) {
                // Single-byte half-width katakana.
                total -= 1
                index += 1
                continue
            }
            // After the lead byte, always take the next byte as the trail byte; an incomplete character at the end of the sample is not counted.
            guard index + 1 < count else { break }
            let trail = sample[index + 1]
            if candidate == .gb18030, (0x30...0x39).contains(trail) {
                guard index + 3 < count else { break }
                total -= 2
                index += 4
                continue
            }
            let code = UInt16(lead) << 8 | UInt16(trail)
            total += rangeScore(lead: lead, trail: trail, code: code, candidate: candidate)
            if common.contains(code) { total += 3 }
            index += 2
        }
        return total
    }

    private static func rangeScore(lead: UInt8, trail: UInt8, code: UInt16, candidate: TextCharsetCandidate) -> Double {
        let trailInA1FE = (0xA1...0xFE).contains(trail)
        switch candidate {
        case .gb18030:
            if (0xB0...0xD7).contains(lead), trailInA1FE { return 1 }
            if (0xA1...0xA9).contains(lead) || (0xD8...0xF7).contains(lead), trailInA1FE { return 0 }
            return -1
        case .big5:
            if (0xA4...0xC6).contains(lead) { return 1 }
            if (0xA1...0xA3).contains(lead) || (0xC9...0xF9).contains(lead) { return 0 }
            if (0xC7...0xC8).contains(lead) { return -1 }
            return -2
        case .shiftJIS:
            if (0xF0...0xF9).contains(lead) { return -2 }
            if (0x829F...0x82F1).contains(code) || (0x8340...0x8396).contains(code) || (0x889F...0x9872).contains(code) { return 1 }
            if (0x989F...0xEAA4).contains(code) || (0x81...0x84).contains(lead) { return 0 }
            return -1
        case .eucKR:
            if (0xB0...0xC8).contains(lead), trailInA1FE { return 1 }
            if (0xA1...0xAC).contains(lead) || (0xCA...0xFD).contains(lead), trailInA1FE { return 0 }
            return -1
        case .windows1252, .windows1251:
            return 0
        }
    }

    private static func isASCIILetter(_ byte: UInt8?) -> Bool {
        guard let byte else { return false }
        return (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte)
    }

    private static func isHigh(_ byte: UInt8?) -> Bool {
        guard let byte else { return false }
        return byte >= 0x80
    }

    private static let letters1252: Set<UInt8> = {
        var set = Set<UInt8>((0xC0...0xFF).filter { $0 != 0xD7 && $0 != 0xF7 })
        set.formUnion([0x8A, 0x8C, 0x8E, 0x9A, 0x9C, 0x9E, 0x9F])
        return set
    }()

    private static func windows1252Score(_ sample: [UInt8]) -> Double {
        let punct = Set(punct1252)
        var total = 0.0
        for (index, byte) in sample.enumerated() where byte >= 0x80 {
            let previous: UInt8? = index > 0 ? sample[index - 1] : nil
            let next: UInt8? = index + 1 < sample.count ? sample[index + 1] : nil
            if letters1252.contains(byte) {
                if isHigh(previous), isHigh(next) {
                    total -= 1
                } else if isASCIILetter(previous) || isASCIILetter(next) || (!isHigh(previous) && !isHigh(next)) {
                    total += 1
                }
            } else if byte == 0xBF || byte == 0xA1 {
                if let next, next < 0x80, previous.map({ $0 < 0x80 }) ?? true { total += 2 }
            } else if punct.contains(byte) {
                if !isHigh(previous), !isHigh(next) { total += 1 }
            }
        }
        return total
    }

    private static func windows1251Score(_ sample: [UInt8]) -> Double {
        let ok = Set(ok1251)
        var total = 0.0
        for (index, byte) in sample.enumerated() where byte >= 0x80 {
            let previous: UInt8? = index > 0 ? sample[index - 1] : nil
            let next: UInt8? = index + 1 < sample.count ? sample[index + 1] : nil
            if isASCIILetter(previous) || isASCIILetter(next) {
                total -= 1
            } else if byte >= 0xE0 {
                total += 1
            } else if byte >= 0xC0 {
                let previousLower = previous.map { $0 >= 0xE0 } ?? false
                let previousUpper = previous.map { (0xC0...0xDF).contains($0) } ?? false
                let nextLower = next.map { $0 >= 0xE0 } ?? false
                if previousLower || (previousUpper && nextLower) {
                    total -= 1
                } else {
                    total += 0.5
                }
            } else if !ok.contains(byte) {
                total -= 2
            }
        }
        return total
    }

    // MARK: - Embedded tables (contract tests compare them to the fixture entry by entry)

    private static let commonCharSets: [TextCharsetCandidate: Set<UInt16>] = commonChars.mapValues { Set($0) }

    /// Common-character table (fixture charset-tables.v1.json `commonChars`, code point = lead byte << 8 | trail byte, same order as the fixture).
    static let commonChars: [TextCharsetCandidate: [UInt16]] = [
        .gb18030: [
            0xA1A1, 0xA1A2, 0xA1A3, 0xA1A4, 0xA1B0, 0xA1B1, 0xA1F1, 0xA1F3, 0xA3A1, 0xA3AC,
            0xA3BA, 0xB1A8, 0xB1B8, 0xB1BE, 0xB2BB, 0xB3C9, 0xB3F6, 0xB4F3, 0xB5BD, 0xB5C4,
            0xB5E3, 0xB6AF, 0xB6D4, 0xB6E0, 0xB7A2, 0xB7A8, 0xB7BD, 0xB7D6, 0xB7DD, 0xB8B4,
            0xB8DF, 0xB8F6, 0xB9AB, 0xB9C9, 0xB9D8, 0xB9FA, 0xB9FD, 0xBACD, 0xBBA7, 0xBBD6,
            0xBBE1, 0xBBFA, 0xBCBC, 0xBCDB, 0xBCFE, 0xBDCC, 0xBECD, 0xBEDD, 0xBFB4, 0xBFC6,
            0xBFC9, 0xC0B4, 0xC0ED, 0xC1CB, 0xC2DB, 0xC3C7, 0xC4DC, 0xC4EA, 0xC5CC, 0xC6F7,
            0xC7F8, 0xC8AB, 0xC8CB, 0xC8D5, 0xC8E7, 0xC9CF, 0xC9FA, 0xCAB1, 0xCAB5, 0xCAC7,
            0xCAD0, 0xCAD6, 0xCAF5, 0xCAFD, 0xCCEC, 0xCDF8, 0xCEAA, 0xCEC4, 0xCED2, 0xCEE5,
            0xCFB5, 0xCFC2, 0xCFD6, 0xD0C2, 0xD0C5, 0xD0D0, 0xD0D4, 0xD1A7, 0xD2AA, 0xD2B2,
            0xD2B5, 0xD2BB, 0xD2D4, 0xD3C3, 0xD3D0, 0xD3FD, 0xD4C2, 0xD4DA, 0xD5E2, 0xD6D0,
        ],
        .shiftJIS: [
            0x8140, 0x8141, 0x8142, 0x8145, 0x815B, 0x8169, 0x816A, 0x8175, 0x8176, 0x82A0,
            0x82A2, 0x82A4, 0x82A9, 0x82AA, 0x82AB, 0x82AD, 0x82AF, 0x82B1, 0x82B3, 0x82B5,
            0x82B7, 0x82BD, 0x82BE, 0x82C1, 0x82C4, 0x82C5, 0x82C6, 0x82C8, 0x82C9, 0x82CC,
            0x82CD, 0x82DC, 0x82E0, 0x82E7, 0x82E8, 0x82E9, 0x82EA, 0x82F0, 0x82F1, 0x8341,
            0x8343, 0x834E, 0x834F, 0x8358, 0x835E, 0x8362, 0x8367, 0x8375, 0x8376, 0x8389,
            0x838A, 0x838B, 0x838D, 0x8393, 0x8E96, 0x93FA, 0x95AA,
        ],
        .big5: [
            0xA140, 0xA141, 0xA142, 0xA143, 0xA147, 0xA149, 0xA175, 0xA176, 0xA440, 0xA446,
            0xA447, 0xA448, 0xA451, 0xA454, 0xA457, 0xA464, 0xA46A, 0xA46C, 0xA477, 0xA4A3,
            0xA4A4, 0xA4A7, 0xA4C1, 0xA4CE, 0xA4D1, 0xA4DF, 0xA4E8, 0xA4FD, 0xA540, 0xA548,
            0xA558, 0xA569, 0xA5CD, 0xA5E7, 0xA657, 0xA661, 0xA662, 0xA668, 0xA670, 0xA6A8,
            0xA6B3, 0xA6B9, 0xA6D3, 0xA6DB, 0xA6E6, 0xA6F2, 0xA740, 0xA751, 0xA759, 0xA7DA,
            0xA8A3, 0xA8A5, 0xA8AD, 0xA8D1, 0xA8D3, 0xA8E4, 0xA8FC, 0xA9C0, 0xA9D2, 0xA9F3,
            0xAA6B, 0xAABA, 0xAABE, 0xAACC, 0xAAFC, 0xAC47, 0xAC4F, 0xACB0, 0xACD2, 0xAD59,
            0xAEC9, 0xAFE0, 0xB0EA, 0xB16F, 0xB2B3, 0xB2C4, 0xB36F, 0xB44C, 0xB44E, 0xB54C,
            0xB5A5, 0xB5BD, 0xB5D0, 0xB5D8, 0xB671, 0xB7ED, 0xB867, 0xB944, 0xBAD8, 0xBB44,
            0xBBA1, 0xBDD1, 0xC2C4, 0xC3B9, 0xC440, 0xC45F,
        ],
        .eucKR: [
            0xB0A1, 0xB0B3, 0xB0C5, 0xB0CD, 0xB0D4, 0xB0E6, 0xB0ED, 0xB0F8, 0xB0FA, 0xB0FC,
            0xB1B8, 0xB1B9, 0xB1C7, 0xB1D7, 0xB1E2, 0xB3AA, 0xB3BB, 0xB4C2, 0xB4CF, 0xB4D9,
            0xB4EB, 0xB5A5, 0xB5B5, 0xB5BF, 0xB5C7, 0xB5E9, 0xB6F3, 0xB7AF, 0xB7C2, 0xB7CE,
            0xB8A6, 0xB8AE, 0xB8B6, 0xB8B8, 0xB8BB, 0xB8E9, 0xB9AB, 0xB9AE, 0xB9CC, 0xB9CE,
            0xB9FD, 0xBAB8, 0xBACE, 0xBAD0, 0xBAF1, 0xBBE7, 0xBBF3, 0xBBFD, 0xBCAD, 0xBCBA,
            0xBCD2, 0xBCF6, 0xBDBA, 0xBDC0, 0xBDC3, 0xBDC5, 0xBEC6, 0xBEC8, 0xBEDF, 0xBEEE,
            0xBEF8, 0xBEFA, 0xBFA1, 0xBFA9, 0xBFC0, 0xBFE4, 0xBFEB, 0xBFEC, 0xBFF8, 0xC0A7,
            0xC0AF, 0xC0B8, 0xC0BA, 0xC0BB, 0xC0BD, 0xC0C7, 0xC0CC, 0xC0CE, 0xC0CF, 0xC0D6,
            0xC0DA, 0xC0E5, 0xC0FB, 0xC0FC, 0xC1A4, 0xC1A6, 0xC1B6, 0xC1D6, 0xC1DF, 0xC1F6,
            0xC1F8, 0xC4A1, 0xC5CD, 0xC6AE, 0xC7CF, 0xC7D1, 0xC7D2, 0xC7D8, 0xC7E5, 0xC8AD,
        ],
    ]

    static let punct1252: [UInt8] = [0x80, 0x85, 0x91, 0x92, 0x93, 0x94, 0x96, 0x97, 0xA0, 0xA9, 0xAB, 0xAE, 0xB0, 0xBB]
    static let ok1251: [UInt8] = [0x85, 0x93, 0x94, 0x96, 0x97, 0xA0, 0xA8, 0xAB, 0xB8, 0xB9, 0xBB]

    /// WHATWG index-windows-1252, code points for 0x80-0xFF (81 8D 8F 90 9D map to the same-valued C1 control characters).
    static let windows1252High: [UInt32] = [
        0x20AC, 0x0081, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021,
        0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0x008D, 0x017D, 0x008F,
        0x0090, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014,
        0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0x009D, 0x017E, 0x0178,
        0x00A0, 0x00A1, 0x00A2, 0x00A3, 0x00A4, 0x00A5, 0x00A6, 0x00A7,
        0x00A8, 0x00A9, 0x00AA, 0x00AB, 0x00AC, 0x00AD, 0x00AE, 0x00AF,
        0x00B0, 0x00B1, 0x00B2, 0x00B3, 0x00B4, 0x00B5, 0x00B6, 0x00B7,
        0x00B8, 0x00B9, 0x00BA, 0x00BB, 0x00BC, 0x00BD, 0x00BE, 0x00BF,
        0x00C0, 0x00C1, 0x00C2, 0x00C3, 0x00C4, 0x00C5, 0x00C6, 0x00C7,
        0x00C8, 0x00C9, 0x00CA, 0x00CB, 0x00CC, 0x00CD, 0x00CE, 0x00CF,
        0x00D0, 0x00D1, 0x00D2, 0x00D3, 0x00D4, 0x00D5, 0x00D6, 0x00D7,
        0x00D8, 0x00D9, 0x00DA, 0x00DB, 0x00DC, 0x00DD, 0x00DE, 0x00DF,
        0x00E0, 0x00E1, 0x00E2, 0x00E3, 0x00E4, 0x00E5, 0x00E6, 0x00E7,
        0x00E8, 0x00E9, 0x00EA, 0x00EB, 0x00EC, 0x00ED, 0x00EE, 0x00EF,
        0x00F0, 0x00F1, 0x00F2, 0x00F3, 0x00F4, 0x00F5, 0x00F6, 0x00F7,
        0x00F8, 0x00F9, 0x00FA, 0x00FB, 0x00FC, 0x00FD, 0x00FE, 0x00FF,
    ]
    /// WHATWG index-windows-1251, code points for 0x80-0xFF (98 maps to U+0098).
    static let windows1251High: [UInt32] = [
        0x0402, 0x0403, 0x201A, 0x0453, 0x201E, 0x2026, 0x2020, 0x2021,
        0x20AC, 0x2030, 0x0409, 0x2039, 0x040A, 0x040C, 0x040B, 0x040F,
        0x0452, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014,
        0x0098, 0x2122, 0x0459, 0x203A, 0x045A, 0x045C, 0x045B, 0x045F,
        0x00A0, 0x040E, 0x045E, 0x0408, 0x00A4, 0x0490, 0x00A6, 0x00A7,
        0x0401, 0x00A9, 0x0404, 0x00AB, 0x00AC, 0x00AD, 0x00AE, 0x0407,
        0x00B0, 0x00B1, 0x0406, 0x0456, 0x0491, 0x00B5, 0x00B6, 0x00B7,
        0x0451, 0x2116, 0x0454, 0x00BB, 0x0458, 0x0405, 0x0455, 0x0457,
        0x0410, 0x0411, 0x0412, 0x0413, 0x0414, 0x0415, 0x0416, 0x0417,
        0x0418, 0x0419, 0x041A, 0x041B, 0x041C, 0x041D, 0x041E, 0x041F,
        0x0420, 0x0421, 0x0422, 0x0423, 0x0424, 0x0425, 0x0426, 0x0427,
        0x0428, 0x0429, 0x042A, 0x042B, 0x042C, 0x042D, 0x042E, 0x042F,
        0x0430, 0x0431, 0x0432, 0x0433, 0x0434, 0x0435, 0x0436, 0x0437,
        0x0438, 0x0439, 0x043A, 0x043B, 0x043C, 0x043D, 0x043E, 0x043F,
        0x0440, 0x0441, 0x0442, 0x0443, 0x0444, 0x0445, 0x0446, 0x0447,
        0x0448, 0x0449, 0x044A, 0x044B, 0x044C, 0x044D, 0x044E, 0x044F,
    ]
}
