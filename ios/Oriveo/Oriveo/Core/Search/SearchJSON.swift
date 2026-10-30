import Foundation

// MARK: - JSON values for external search
//
// Why not JSONSerialization / JSONDecoder:
// - Canonical JSON (signature-verification input) must tell integers from non-integers and reject numbers beyond the safe-integer range, and NSNumber cannot tell `true` from `1`;
// - The validation-error order of custom mappings depends on the original key order of objects, which dictionary decoding loses;
// - On output only `"` `\` and C0 are escaped (same as JSON.stringify), whereas JSONSerialization also escapes `/`.
// So this file carries a minimal JSON parser: objects keep key order, and numbers are split by literal into integers (Int64) and others (Double).

nonisolated enum SearchJSONError: Error, Equatable {
    case invalidJSON(offset: Int)
}

/// Order-preserving JSON object. Equality follows JSON semantics (same key set and equal values, order ignored).
nonisolated struct SearchJSONObject: Sendable, Equatable {
    private(set) var keys: [String] = []
    private var storage: [String: SearchJSON] = [:]

    init() {}

    init(_ entries: [(String, SearchJSON)]) {
        for (key, value) in entries { self[key] = value }
    }

    /// Assigning nil = delete the key; reassigning keeps the position of the first occurrence (same as a JS object).
    subscript(key: String) -> SearchJSON? {
        get { storage[key] }
        set {
            if let newValue {
                if storage.updateValue(newValue, forKey: key) == nil { keys.append(key) }
            } else if storage.removeValue(forKey: key) != nil {
                keys.removeAll { $0 == key }
            }
        }
    }

    var entries: [(key: String, value: SearchJSON)] {
        keys.map { ($0, storage[$0]!) }
    }

    var count: Int { keys.count }
    var isEmpty: Bool { keys.isEmpty }

    static func == (lhs: SearchJSONObject, rhs: SearchJSONObject) -> Bool {
        lhs.storage == rhs.storage
    }
}

nonisolated indirect enum SearchJSON: Sendable, Equatable {
    case null
    case bool(Bool)
    /// A number literal with no decimal point or exponent that fits in Int64.
    case int(Int64)
    case double(Double)
    case string(String)
    case array([SearchJSON])
    case object(SearchJSONObject)

    static func == (lhs: SearchJSON, rhs: SearchJSON) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null): return true
        case let (.bool(a), .bool(b)): return a == b
        case let (.string(a), .string(b)): return a == b
        case let (.array(a), .array(b)): return a == b
        case let (.object(a), .object(b)): return a == b
        case let (.int(a), .int(b)): return a == b
        default:
            // Numbers compare by value (5 and 5.0 are the same under JSON semantics)
            if let a = lhs.numberValue, let b = rhs.numberValue { return a == b }
            return false
        }
    }

    // MARK: Accessors

    subscript(key: String) -> SearchJSON? {
        if case .object(let object) = self { return object[key] }
        return nil
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    var arrayValue: [SearchJSON]? {
        if case .array(let value) = self { return value }
        return nil
    }

    var objectValue: SearchJSONObject? {
        if case .object(let value) = self { return value }
        return nil
    }

    var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    var numberValue: Double? {
        switch self {
        case .int(let value): return Double(value)
        case .double(let value): return value
        default: return nil
        }
    }

    /// `Number.isInteger`: any finite integral number (including 1.0, 1e3).
    var isIntegral: Bool {
        switch self {
        case .int: return true
        case .double(let value): return value.isFinite && value.rounded(.towardZero) == value
        default: return false
        }
    }

    /// The integer value when `Number.isInteger` holds and it fits in Int64.
    var integerValue: Int64? {
        switch self {
        case .int(let value): return value
        case .double(let value):
            guard isIntegral, abs(value) < 9.2e18 else { return nil }
            return Int64(value)
        default: return nil
        }
    }

    /// Number truncated to Int (upper limits in the catalog / mappings; extreme values are clamped, no trap).
    var clampedIntValue: Int? {
        guard let value = numberValue, !value.isNaN else { return nil }
        return Int(max(-1e15, min(1e15, value)))
    }

    static let maxSafeInteger: Int64 = 9_007_199_254_740_991

    /// `Number.isSafeInteger`.
    var safeIntegerValue: Int? {
        guard let value = integerValue, abs(value) <= Self.maxSafeInteger else { return nil }
        return Int(value)
    }

    /// JS truthiness: null, false, 0, NaN, "" are falsy, everything else (including empty arrays / empty objects) is truthy.
    var isTruthy: Bool {
        switch self {
        case .null: return false
        case .bool(let value): return value
        case .int(let value): return value != 0
        case .double(let value): return value != 0 && !value.isNaN
        case .string(let value): return !value.isEmpty
        case .array, .object: return true
        }
    }

    /// `getPath`: walk dotted path level by level; hitting a non-object midway (arrays included) gives nil (JS undefined).
    static func value(in root: SearchJSON?, atPath dotted: String) -> SearchJSON? {
        var current = root
        for part in dotted.split(separator: ".", omittingEmptySubsequences: false) {
            guard case .object(let object)? = current else { return nil }
            current = object[String(part)]
        }
        return current
    }

    /// `String(v)`: JS stringification (for query-string values and header-name validation).
    var jsString: String {
        switch self {
        case .null: return "null"
        case .bool(let value): return value ? "true" : "false"
        case .int(let value): return String(value)
        case .double(let value): return SearchJSON.formatNumber(value)
        case .string(let value): return value
        case .array(let items): return items.map { $0.isNull ? "" : $0.jsString }.joined(separator: ",")
        case .object: return "[object Object]"
        }
    }

    // MARK: Serialization

    /// Write in insertion order (for request bodies and storage); escaping rules same as JSON.stringify.
    func encodedString() -> String {
        var out = ""
        write(into: &out)
        return out
    }

    func encodedData() -> Data { Data(encodedString().utf8) }

    private func write(into out: inout String) {
        switch self {
        case .null: out += "null"
        case .bool(let value): out += value ? "true" : "false"
        case .int(let value): out += String(value)
        case .double(let value): out += value.isFinite ? SearchJSON.formatNumber(value) : "null"
        case .string(let value): out += SearchJSON.quoted(value)
        case .array(let items):
            out += "["
            for (index, item) in items.enumerated() {
                if index > 0 { out += "," }
                item.write(into: &out)
            }
            out += "]"
        case .object(let object):
            out += "{"
            for (index, entry) in object.entries.enumerated() {
                if index > 0 { out += "," }
                out += SearchJSON.quoted(entry.key)
                out += ":"
                entry.value.write(into: &out)
            }
            out += "}"
        }
    }

    static func formatNumber(_ value: Double) -> String {
        if value.isFinite, value.rounded(.towardZero) == value, abs(value) < 1e21 {
            return String(Int64(exactly: value) ?? Int64(value))
        }
        return String(value)
    }

    /// String escaping of JSON.stringify: escapes only `"` `\` and U+0000–U+001F (\b \f \n \r \t in short form, the rest as lowercase \u00xx).
    static func quoted(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    let hex = String(scalar.value, radix: 16)
                    out += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
        return out
    }

    // MARK: Parsing

    static func parse(_ data: Data) throws -> SearchJSON {
        var parser = SearchJSONParser(bytes: [UInt8](data))
        let value = try parser.parseValue()
        parser.skipWhitespace()
        guard parser.index == parser.bytes.count else { throw SearchJSONError.invalidJSON(offset: parser.index) }
        return value
    }

    static func parse(_ text: String) throws -> SearchJSON {
        try parse(Data(text.utf8))
    }
}

extension SearchJSON: ExpressibleByStringLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral {
    nonisolated init(stringLiteral value: String) { self = .string(value) }
    nonisolated init(booleanLiteral value: Bool) { self = .bool(value) }
    nonisolated init(integerLiteral value: Int64) { self = .int(value) }
    nonisolated init(arrayLiteral elements: SearchJSON...) { self = .array(elements) }
    nonisolated init(dictionaryLiteral elements: (String, SearchJSON)...) { self = .object(SearchJSONObject(elements)) }
    nonisolated init(nilLiteral: ()) { self = .null }
}

nonisolated private struct SearchJSONParser {
    let bytes: [UInt8]
    var index = 0

    init(bytes: [UInt8]) {
        self.bytes = bytes
        // Skip the UTF-8 BOM
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { index = 3 }
    }

    private func fail() -> SearchJSONError { .invalidJSON(offset: index) }

    mutating func skipWhitespace() {
        while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
    }

    mutating func parseValue() throws -> SearchJSON {
        skipWhitespace()
        guard index < bytes.count else { throw fail() }
        switch bytes[index] {
        case UInt8(ascii: "{"): return try parseObject()
        case UInt8(ascii: "["): return try parseArray()
        case UInt8(ascii: "\""): return .string(try parseString())
        case UInt8(ascii: "t"): try expect("true"); return .bool(true)
        case UInt8(ascii: "f"): try expect("false"); return .bool(false)
        case UInt8(ascii: "n"): try expect("null"); return .null
        default: return try parseNumber()
        }
    }

    private mutating func expect(_ literal: String) throws {
        let utf8 = Array(literal.utf8)
        guard index + utf8.count <= bytes.count, Array(bytes[index..<index + utf8.count]) == utf8 else { throw fail() }
        index += utf8.count
    }

    private mutating func parseObject() throws -> SearchJSON {
        index += 1
        var object = SearchJSONObject()
        skipWhitespace()
        if index < bytes.count, bytes[index] == UInt8(ascii: "}") {
            index += 1
            return .object(object)
        }
        while true {
            skipWhitespace()
            guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { throw fail() }
            let key = try parseString()
            skipWhitespace()
            guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { throw fail() }
            index += 1
            object[key] = try parseValue()
            skipWhitespace()
            guard index < bytes.count else { throw fail() }
            if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
            if bytes[index] == UInt8(ascii: "}") { index += 1; return .object(object) }
            throw fail()
        }
    }

    private mutating func parseArray() throws -> SearchJSON {
        index += 1
        var items: [SearchJSON] = []
        skipWhitespace()
        if index < bytes.count, bytes[index] == UInt8(ascii: "]") {
            index += 1
            return .array(items)
        }
        while true {
            items.append(try parseValue())
            skipWhitespace()
            guard index < bytes.count else { throw fail() }
            if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
            if bytes[index] == UInt8(ascii: "]") { index += 1; return .array(items) }
            throw fail()
        }
    }

    private mutating func parseHex4() throws -> UInt32 {
        guard index + 4 <= bytes.count else { throw fail() }
        var value: UInt32 = 0
        for _ in 0..<4 {
            let byte = bytes[index]
            let digit: UInt32
            switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): digit = UInt32(byte - UInt8(ascii: "0"))
            case UInt8(ascii: "a")...UInt8(ascii: "f"): digit = UInt32(byte - UInt8(ascii: "a") + 10)
            case UInt8(ascii: "A")...UInt8(ascii: "F"): digit = UInt32(byte - UInt8(ascii: "A") + 10)
            default: throw fail()
            }
            value = value * 16 + digit
            index += 1
        }
        return value
    }

    private mutating func parseString() throws -> String {
        index += 1
        var buffer: [UInt8] = []
        while true {
            guard index < bytes.count else { throw fail() }
            let byte = bytes[index]
            if byte == UInt8(ascii: "\"") {
                index += 1
                return String(decoding: buffer, as: UTF8.self)
            }
            if byte < 0x20 { throw fail() }
            if byte != UInt8(ascii: "\\") {
                buffer.append(byte)
                index += 1
                continue
            }
            index += 1
            guard index < bytes.count else { throw fail() }
            let escape = bytes[index]
            index += 1
            switch escape {
            case UInt8(ascii: "\""): buffer.append(UInt8(ascii: "\""))
            case UInt8(ascii: "\\"): buffer.append(UInt8(ascii: "\\"))
            case UInt8(ascii: "/"): buffer.append(UInt8(ascii: "/"))
            case UInt8(ascii: "b"): buffer.append(0x08)
            case UInt8(ascii: "f"): buffer.append(0x0C)
            case UInt8(ascii: "n"): buffer.append(0x0A)
            case UInt8(ascii: "r"): buffer.append(0x0D)
            case UInt8(ascii: "t"): buffer.append(0x09)
            case UInt8(ascii: "u"):
                var code = try parseHex4()
                if (0xD800...0xDBFF).contains(code),
                   index + 6 <= bytes.count, bytes[index] == UInt8(ascii: "\\"), bytes[index + 1] == UInt8(ascii: "u") {
                    let saved = index
                    index += 2
                    let low = try parseHex4()
                    if (0xDC00...0xDFFF).contains(low) {
                        code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                    } else {
                        index = saved
                    }
                }
                // A lone surrogate cannot live in a Swift string, so it is handled as U+FFFD
                let scalar = Unicode.Scalar(code) ?? "\u{FFFD}"
                buffer.append(contentsOf: Array(String(Character(scalar)).utf8))
            default:
                throw fail()
            }
        }
    }

    private mutating func parseNumber() throws -> SearchJSON {
        let start = index
        var isInteger = true
        if index < bytes.count, bytes[index] == UInt8(ascii: "-") { index += 1 }
        let digitsStart = index
        while index < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[index]) { index += 1 }
        guard index > digitsStart else { throw fail() }
        if index < bytes.count, bytes[index] == UInt8(ascii: ".") {
            isInteger = false
            index += 1
            let fractionStart = index
            while index < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[index]) { index += 1 }
            guard index > fractionStart else { throw fail() }
        }
        if index < bytes.count, bytes[index] == UInt8(ascii: "e") || bytes[index] == UInt8(ascii: "E") {
            isInteger = false
            index += 1
            if index < bytes.count, bytes[index] == UInt8(ascii: "+") || bytes[index] == UInt8(ascii: "-") { index += 1 }
            let exponentStart = index
            while index < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[index]) { index += 1 }
            guard index > exponentStart else { throw fail() }
        }
        let literal = String(decoding: bytes[start..<index], as: UTF8.self)
        if isInteger, let value = Int64(literal) { return .int(value) }
        guard let value = Double(literal) else { throw fail() }
        return .double(value)
    }
}

// MARK: - JS text semantics (trim, \s, code points)

nonisolated enum SearchJSText {
    /// Whitespace recognized by JS `\s` and `String.prototype.trim` (WhiteSpace + LineTerminator).
    static func isWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x09...0x0D, 0x20, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF:
            return true
        default:
            return false
        }
    }

    static func trim(_ value: String) -> String {
        let scalars = Array(value.unicodeScalars)
        guard let first = scalars.firstIndex(where: { !isWhitespace($0) }),
              let last = scalars.lastIndex(where: { !isWhitespace($0) }) else { return "" }
        var out = String.UnicodeScalarView()
        out.append(contentsOf: scalars[first...last])
        return String(out)
    }

    /// Code point count (`Array.from(s).length`).
    static func codePointCount(_ value: String) -> Int {
        value.unicodeScalars.count
    }

    static func prefix(_ value: String, codePoints count: Int) -> String {
        var out = String.UnicodeScalarView()
        out.append(contentsOf: value.unicodeScalars.prefix(max(0, count)))
        return String(out)
    }

    /// Compare by UTF-16 code units (the order of JS's default `sort()`).
    static func utf16Precedes(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf16.lexicographicallyPrecedes(rhs.utf16)
    }
}
