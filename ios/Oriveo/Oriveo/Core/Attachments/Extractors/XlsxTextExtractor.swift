import Foundation

/// XLSX extraction (attachment extraction spec section 6): find the workbook by root relationship -> find shared strings and styles by workbook relationship ->
/// for each sheet in `<sheets>` order output `## Sheet: name` and a table of the used range -> section 3.1 normalization.
/// Worksheets and shared strings can be large, so they are parsed as a stream; the deadline is checked every 1000 rows of a worksheet (section 14).
nonisolated enum XlsxTextExtractor {
    static func extract(_ package: OfficePackage) throws -> String {
        let workbookPath = try package.mainPart(fallback: "xl/workbook.xml")
        guard let workbook = try package.xml(workbookPath) else {
            throw ExtractionError(code: .corruptedFile, underlying: "xlsx workbook missing")
        }
        let relationships = try package.relationships(of: workbookPath)
        func partPath(_ type: String, fallback: String) -> String {
            relationships.first { $0.hasType(type) }?.target ?? fallback
        }

        let sharedStrings = try package.xmlData(partPath("/sharedStrings", fallback: "xl/sharedStrings.xml"))
            .map { try SharedStringsParser.parse($0) } ?? []
        try package.deadline.check()
        let formats = try package.xml(partPath("/styles", fallback: "xl/styles.xml")).map(NumberFormats.init) ?? NumberFormats()
        let date1904 = ["1", "true"].contains(workbook.childByLocal("workbookPr")?.attr("date1904") ?? "")

        var relationshipsById: [String: OfficeRelationship] = [:]
        for relationship in relationships where relationshipsById[relationship.id] == nil {
            relationshipsById[relationship.id] = relationship
        }

        var writer = StructuredBlockWriter()
        for sheet in workbook.childByLocal("sheets")?.elements ?? [] where sheet.local == "sheet" {
            try package.deadline.check()
            let state = sheet.attr("state")
            guard state != "veryHidden",
                  let id = sheet.attr("r:id"),
                  let relationship = relationshipsById[id],
                  relationship.hasType("/worksheet") else { continue }
            writer.section("## Sheet: \(sheet.attr("name") ?? "")" + (state == "hidden" ? " (hidden)" : ""))
            guard let data = try package.xmlData(relationship.target) else { continue }
            let grid = try SheetParser.parse(
                data,
                sharedStrings: sharedStrings,
                formats: formats,
                date1904: date1904,
                deadline: package.deadline
            )
            grid.write(into: &writer)
        }
        return writer.render()
    }

    static func localName(_ name: String) -> String {
        guard let colon = name.lastIndex(of: ":") else { return name }
        return String(name[name.index(after: colon)...])
    }

    // MARK: - Shared strings

    /// Left to right, decode `_xHHHH_` into the corresponding character; decoded characters do not take part in later matches.
    static func decodeEscapes(_ text: String) -> String {
        guard text.contains("_x") else { return text }
        let units = Array(text.utf16)
        var output: [UInt16] = []
        output.reserveCapacity(units.count)
        var index = 0
        while index < units.count {
            if index + 6 < units.count, units[index] == 0x5F, units[index + 1] == 0x78, units[index + 6] == 0x5F,
               let value = UInt16(String(decoding: units[(index + 2)..<(index + 6)], as: UTF16.self), radix: 16),
               units[(index + 2)..<(index + 6)].allSatisfy(isHexDigit) {
                output.append(value)
                index += 7
            } else {
                output.append(units[index])
                index += 1
            }
        }
        return String(decoding: output, as: UTF16.self)
    }

    private static func isHexDigit(_ unit: UInt16) -> Bool {
        (0x30...0x39).contains(unit) || (0x41...0x46).contains(unit) || (0x61...0x66).contains(unit)
    }

    /// For each `<si>`: concatenate the text of all `t` descendants in order, skip the whole `rPh` (phonetic) and `phoneticPr` subtrees, then decode `_xHHHH_`.
    private final class SharedStringsParser: NSObject, XMLParserDelegate {
        private var strings: [String] = []
        private var current = ""
        private var inItem = false
        private var inText = false
        private var phoneticDepth = 0
        private var depth = 0
        private var closed = false

        static func parse(_ data: Data) throws -> [String] {
            let handler = SharedStringsParser()
            let parser = XMLParser(data: data)
            parser.shouldResolveExternalEntities = false
            parser.delegate = handler
            guard parser.parse() || handler.closed else {
                throw ExtractionError(code: .corruptedFile, underlying: "xlsx sharedStrings parse failed")
            }
            return handler.strings
        }

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            depth += 1
            switch XlsxTextExtractor.localName(elementName) {
            case "si":
                inItem = true
                current = ""
            case "rPh", "phoneticPr":
                if inItem { phoneticDepth += 1 }
            case "t":
                inText = inItem && phoneticDepth == 0
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if inText { current += string }
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?) {
            depth -= 1
            if depth == 0 { closed = true }
            switch XlsxTextExtractor.localName(elementName) {
            case "si":
                strings.append(XlsxTextExtractor.decodeEscapes(current))
                inItem = false
            case "rPh", "phoneticPr":
                if inItem, phoneticDepth > 0 { phoneticDepth -= 1 }
            case "t":
                inText = false
            default:
                break
            }
        }
    }

    // MARK: - Worksheets

    private final class SheetParser: NSObject, XMLParserDelegate {
        private let sharedStrings: [String]
        private let formats: NumberFormats
        private let date1904: Bool
        private let deadline: ExtractionDeadline
        private(set) var grid = SpreadsheetGrid()
        private var failure: Error?
        private var depth = 0
        private var closed = false

        private var inSheetData = false
        private var rowsSeen = 0
        private var rowNumber = 0
        private var column = 0
        private var cellType = ""
        private var cellStyle = 0
        private var value: String?
        private var inlineText = ""
        private var inValue = false
        private var inInline = false
        private var inText = false
        private var phoneticDepth = 0

        init(sharedStrings: [String], formats: NumberFormats, date1904: Bool, deadline: ExtractionDeadline) {
            self.sharedStrings = sharedStrings
            self.formats = formats
            self.date1904 = date1904
            self.deadline = deadline
        }

        static func parse(
            _ data: Data,
            sharedStrings: [String],
            formats: NumberFormats,
            date1904: Bool,
            deadline: ExtractionDeadline
        ) throws -> SpreadsheetGrid {
            let handler = SheetParser(sharedStrings: sharedStrings, formats: formats, date1904: date1904, deadline: deadline)
            let parser = XMLParser(data: data)
            parser.shouldResolveExternalEntities = false
            parser.delegate = handler
            let succeeded = parser.parse()
            if let failure = handler.failure { throw failure }
            guard succeeded || handler.closed else {
                throw ExtractionError(code: .corruptedFile, underlying: "xlsx worksheet parse failed")
            }
            return handler.grid
        }

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            depth += 1
            let name = XlsxTextExtractor.localName(elementName)
            if name == "sheetData" {
                inSheetData = true
                return
            }
            guard inSheetData else { return }
            switch name {
            case "row":
                if rowsSeen % 1_000 == 0 {
                    do {
                        try deadline.check()
                    } catch {
                        failure = error
                        parser.abortParsing()
                        return
                    }
                }
                rowsSeen += 1
                rowNumber = attributeDict["r"].flatMap { Int($0) } ?? rowNumber + 1
                column = 0
            case "c":
                column = attributeDict["r"].flatMap(Self.columnNumber) ?? column + 1
                cellType = attributeDict["t"] ?? ""
                cellStyle = attributeDict["s"].flatMap { Int($0) } ?? 0
                value = nil
                inlineText = ""
            case "v":
                inValue = true
                if value == nil { value = "" }
            case "is":
                inInline = true
            case "rPh", "phoneticPr":
                if inInline { phoneticDepth += 1 }
            case "t":
                inText = inInline && phoneticDepth == 0
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if inValue {
                value = (value ?? "") + string
            } else if inText {
                inlineText += string
            }
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?) {
            depth -= 1
            if depth == 0 { closed = true }
            let name = XlsxTextExtractor.localName(elementName)
            guard inSheetData else { return }
            switch name {
            case "sheetData":
                inSheetData = false
            case "v":
                inValue = false
            case "t":
                inText = false
            case "rPh", "phoneticPr":
                if inInline, phoneticDepth > 0 { phoneticDepth -= 1 }
            case "is":
                inInline = false
            case "c":
                let text = StructuredTextFormat.cellText(paragraphs: [cellValue()])
                grid.set(row: rowNumber, column: column, text: text)
            default:
                break
            }
        }

        private func cellValue() -> String {
            if cellType == "inlineStr" { return XlsxTextExtractor.decodeEscapes(inlineText) }
            guard let raw = value else { return "" }
            switch cellType {
            case "s":
                guard let index = Int(raw.trimmingCharacters(in: .whitespaces)), sharedStrings.indices.contains(index) else { return "" }
                return sharedStrings[index]
            case "str", "e", "d":
                return raw
            case "b":
                return raw == "1" ? "TRUE" : "FALSE"
            default:
                if let kind = formats.dateKind(styleIndex: cellStyle),
                   let date = XlsxTextExtractor.formatDate(raw, kind: kind, date1904: date1904) {
                    return date
                }
                return XlsxTextExtractor.normalizeNumber(raw)
            }
        }

        /// The letter part of `C5` is treated as base 26 for the column number (A = 1); returns nil if there are no letters.
        static func columnNumber(_ reference: String) -> Int? {
            var result = 0
            var sawLetter = false
            for scalar in reference.unicodeScalars {
                let value = scalar.value
                let letter: UInt32
                if (65...90).contains(value) {
                    letter = value - 64
                } else if (97...122).contains(value) {
                    letter = value - 96
                } else {
                    break
                }
                sawLetter = true
                result = result * 26 + Int(letter)
                if result > 1_000_000 { return nil }
            }
            return sawLetter ? result : nil
        }
    }

    // MARK: - Number normalization

    /// When it matches `^-?\d+(\.\d+)?([eE][+-]?\d+)?$` and has more than 15 significant digits, round in decimal (.5 away from zero) to 15 significant digits,
    /// strip trailing 0s of the fraction and a dangling `.`, and keep the exponent part as is. Pure string arithmetic, no floating point.
    static func normalizeNumber(_ raw: String) -> String {
        let bytes = Array(raw.utf8)
        var index = 0
        let negative = bytes.first == UInt8(ascii: "-")
        if negative { index += 1 }
        func digitRun() -> [UInt8] {
            var run: [UInt8] = []
            while index < bytes.count, (48...57).contains(bytes[index]) {
                run.append(bytes[index] - 48)
                index += 1
            }
            return run
        }
        let integer = digitRun()
        guard !integer.isEmpty else { return raw }
        var fraction: [UInt8] = []
        if index < bytes.count, bytes[index] == UInt8(ascii: ".") {
            index += 1
            fraction = digitRun()
            guard !fraction.isEmpty else { return raw }
        }
        let exponentStart = index
        if index < bytes.count, bytes[index] == UInt8(ascii: "e") || bytes[index] == UInt8(ascii: "E") {
            index += 1
            if index < bytes.count, bytes[index] == UInt8(ascii: "+") || bytes[index] == UInt8(ascii: "-") { index += 1 }
            guard !digitRun().isEmpty else { return raw }
        }
        guard index == bytes.count else { return raw }

        let digits = integer + fraction
        let leadingZeros = digits.prefix { $0 == 0 }.count
        guard digits.count - leadingZeros > 15 else { return raw }

        let cut = leadingZeros + 15
        var kept = Array(digits[..<cut])
        var carry = digits[cut] >= 5
        var position = cut - 1
        while carry, position >= 0 {
            if kept[position] == 9 {
                kept[position] = 0
                position -= 1
            } else {
                kept[position] += 1
                carry = false
            }
        }
        var full = kept + Array(repeating: 0, count: digits.count - cut)
        var integerCount = integer.count
        if carry {
            full.insert(1, at: 0)
            integerCount += 1
        }
        var fractionDigits = Array(full[integerCount...])
        while fractionDigits.last == 0 { fractionDigits.removeLast() }

        var result = negative ? "-" : ""
        result += full[..<integerCount].map { String($0) }.joined()
        if !fractionDigits.isEmpty { result += "." + fractionDigits.map { String($0) }.joined() }
        result += String(decoding: bytes[exponentStart...], as: UTF8.self)
        return result
    }

    // MARK: - Dates

    enum DateKind {
        case date
        case time
        case dateTime
    }

    /// Style index -> whether the number format is a date / time.
    struct NumberFormats {
        private var formatIds: [Int] = []
        private var customCodes: [Int: String] = [:]

        private static let builtinDates: Set<Int> = [14, 15, 16, 17, 27, 28, 29, 30, 31, 34, 35, 36, 50, 51, 52, 53, 54, 57, 58]
        private static let builtinTimes: Set<Int> = [18, 19, 20, 21, 32, 33, 45, 46, 47, 55, 56]

        init() {}

        init(_ root: OfficeXmlNode) {
            for format in root.childByLocal("numFmts")?.elements ?? [] where format.local == "numFmt" {
                if let id = format.attr("numFmtId").flatMap({ Int($0) }), let code = format.attr("formatCode"), customCodes[id] == nil {
                    customCodes[id] = code
                }
            }
            formatIds = (root.childByLocal("cellXfs")?.elements ?? [])
                .filter { $0.local == "xf" }
                .map { $0.attr("numFmtId").flatMap { Int($0) } ?? 0 }
        }

        func dateKind(styleIndex: Int) -> DateKind? {
            guard formatIds.indices.contains(styleIndex) else { return nil }
            let id = formatIds[styleIndex]
            if Self.builtinDates.contains(id) { return .date }
            if Self.builtinTimes.contains(id) { return .time }
            if id == 22 { return .dateTime }
            guard let code = customCodes[id] else { return nil }
            return Self.classify(code)
        }

        /// Custom format: look only before the first `;`, strip quoted runs, `\x` `_x` `*x`, and bracketed runs (`[h]` `[hh]` `[m]` `[mm]` `[s]` `[ss]` only lose the brackets), then decide.
        static func classify(_ code: String) -> DateKind? {
            let section = code.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
            let characters = Array(section)
            var cleaned = ""
            var index = 0
            while index < characters.count {
                let character = characters[index]
                switch character {
                case "\"":
                    index += 1
                    while index < characters.count, characters[index] != "\"" { index += 1 }
                    index += 1
                case "\\", "_", "*":
                    index += 2
                case "[":
                    var end = index + 1
                    while end < characters.count, characters[end] != "]" { end += 1 }
                    let inner = String(characters[min(index + 1, characters.count)..<min(end, characters.count)]).lowercased()
                    if ["h", "hh", "m", "mm", "s", "ss"].contains(inner) { cleaned += inner }
                    index = end + 1
                default:
                    cleaned.append(character)
                    index += 1
                }
            }
            let lowered = cleaned.lowercased()
            let hasDate = lowered.contains { "yd年月日".contains($0) }
            let hasTime = lowered.contains { "hs时時分秒".contains($0) }
            switch (hasDate, hasTime) {
            case (true, true): return .dateTime
            case (true, false): return .date
            case (false, true): return .time
            case (false, false): return lowered.contains("m") ? .date : nil
            }
        }
    }

    /// Serial number -> `yyyy-MM-dd` / `HH:mm:ss` / `yyyy-MM-dd HH:mm:ss` (UTC). Returns nil on parse failure, negative, or out of representable range (output as a number).
    static func formatDate(_ raw: String, kind: DateKind, date1904: Bool) -> String? {
        guard let serial = Double(raw.trimmingCharacters(in: .whitespaces)), serial.isFinite, serial >= 0, serial < 10_000_000 else {
            return nil
        }
        var days = Int(serial.rounded(.down))
        var seconds = Int(((serial - Double(days)) * 86_400).rounded())
        if seconds >= 86_400 {
            days += 1
            seconds = 0
        }

        let datePart: String
        if date1904 {
            datePart = civilString(daysFromCivil(1904, 1, 1) + days)
        } else if days == 60 {
            datePart = "1900-02-29"
        } else if days < 60 {
            datePart = civilString(daysFromCivil(1899, 12, 31) + days)
        } else {
            datePart = civilString(daysFromCivil(1899, 12, 30) + days)
        }
        let timePart = String(format: "%02ld:%02ld:%02ld", seconds / 3_600, seconds % 3_600 / 60, seconds % 60)
        switch kind {
        case .date: return datePart
        case .time: return timePart
        case .dateTime: return "\(datePart) \(timePart)"
        }
    }

    /// Gregorian date -> days since 1970-01-01.
    private static func daysFromCivil(_ year: Int, _ month: Int, _ day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yearOfEra = y - era * 400
        let shiftedMonth = month > 2 ? month - 3 : month + 9
        let dayOfYear = (153 * shiftedMonth + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    private static func civilString(_ daysSinceEpoch: Int) -> String {
        let z = daysSinceEpoch + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let dayOfEra = z - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1_460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let shiftedMonth = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * shiftedMonth + 2) / 5 + 1
        let month = shiftedMonth < 10 ? shiftedMonth + 3 : shiftedMonth - 9
        let year = yearOfEra + era * 400 + (month <= 2 ? 1 : 0)
        return String(format: "%04ld-%02ld-%02ld", year, month, day)
    }
}
