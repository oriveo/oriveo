import Foundation

/// Order-preserving JSON object. The argument summary depends on the **property order** of `inputSchema.properties`,
/// and Swift's `Dictionary` is unordered, so an object is represented as "key array + dictionary": the key array
/// keeps the source document order and the dictionary provides O(1) lookup.
nonisolated struct JSONObject: Sendable, Equatable {
    private(set) var orderedKeys: [String]
    private var storage: [String: JSONValue]

    init() {
        self.orderedKeys = []
        self.storage = [:]
    }

    init(_ pairs: [(String, JSONValue)]) {
        var keys: [String] = []
        var values: [String: JSONValue] = [:]
        for (key, value) in pairs {
            if values[key] == nil { keys.append(key) }
            values[key] = value
        }
        self.orderedKeys = keys
        self.storage = values
    }

    var keys: [String] { orderedKeys }

    subscript(key: String) -> JSONValue? {
        storage[key]
    }

    var isEmpty: Bool { orderedKeys.isEmpty }

    func mapValues(_ transform: (JSONValue) -> JSONValue) -> JSONObject {
        JSONObject(orderedKeys.map { ($0, transform(storage[$0]!)) })
    }
}

/// Value type equivalent to JSON. Using it instead of `[String: Any]` makes schema / annotations / arguments
/// `Sendable` and `Equatable`, and allows both the **canonical JSON** used for content hashing (keys recursively
/// sorted ascending, arrays kept in order, only `"`, `\` and control characters escaped) and the **property order**
/// the argument summary depends on.
nonisolated enum JSONValue: Sendable, Equatable {
    case object(JSONObject)
    case array([JSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    /// Builds from `[String: Any]` (key order is unreliable; only for payloads that do not need order, such as
    /// annotations / arguments).
    init(any value: Any) {
        switch value {
        case let dict as [String: Any]:
            // Sorting is only for determinism; it does not reflect source order.
            let pairs = dict.keys.sorted().map { ($0, JSONValue(any: dict[$0]!)) }
            self = .object(JSONObject(pairs))
        case let array as [Any]:
            self = .array(array.map { JSONValue(any: $0) })
        case let string as String:
            self = .string(string)
        case let bool as Bool:
            self = .bool(bool)
        case let number as NSNumber:
            // JSONSerialization also wraps true/false in NSNumber; check bool before number.
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else {
                self = .number(number.doubleValue)
            }
        case let number as Double:
            self = .number(number)
        case let number as Int:
            self = .number(Double(number))
        case is NSNull:
            self = .null
        default:
            self = .null
        }
    }

    /// Nesting depth limit. Real tool schemas / results come nowhere near it; anything deeper is treated as a parse
    /// failure.
    static let maxNestingDepth = 64

    /// Order-preserving parse (own recursive-descent parser instead of JSONSerialization, which does not guarantee
    /// object key order).
    init(parsing string: String) throws {
        var parser = JSONParser(scalars: Array(string.unicodeScalars))
        let value = try parser.parseValue()
        try parser.skipWhitespace()
        guard parser.isAtEnd else { throw JSONValueError.trailingContent }
        self = value
    }

    init(data: Data) throws {
        guard let string = String(data: data, encoding: .utf8) else { throw JSONValueError.notUTF8 }
        try self.init(parsing: string)
    }

    var objectValue: JSONObject? {
        if case .object(let object) = self { return object }
        return nil
    }

    var arrayValue: [JSONValue]? {
        if case .array(let array) = self { return array }
        return nil
    }

    var stringValue: String? {
        if case .string(let string) = self { return string }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let bool) = self { return bool }
        return nil
    }

    var doubleValue: Double? {
        if case .number(let number) = self { return number }
        return nil
    }

    /// Accepts only finite, integral numbers within `Int` range. `Int(_: Double)` traps on out-of-range / non-finite
    /// values, and these numbers come from third-party servers (`"id":1e30`, `"error":{"code":1e30}`), so a single
    /// message from the peer must not be able to crash the app.
    var intValue: Int? {
        guard case .number(let number) = self else { return nil }
        return Int(exactly: number)
    }

    subscript(key: String) -> JSONValue? {
        objectValue?[key]
    }

    /// Canonical JSON string: objects recursively reordered by ascending key, arrays kept in order.
    var canonicalJSONString: String {
        switch self {
        case .object(let object):
            let body = object.keys.sorted().map { key in
                "\(JSONValue.encodeString(key)):\(object[key]!.canonicalJSONString)"
            }.joined(separator: ",")
            return "{\(body)}"
        case .array(let array):
            return "[\(array.map(\.canonicalJSONString).joined(separator: ","))]"
        case .string(let string):
            return JSONValue.encodeString(string)
        case .number(let number):
            return JSONValue.encodeNumber(number)
        case .bool(let bool):
            return bool ? "true" : "false"
        case .null:
            return "null"
        }
    }

    /// Serializes in current storage order (objects are not sorted). Used to persist `inputSchema`: the argument
    /// summary depends on the **source order** of `properties`, which storing as canonical JSON (ascending keys)
    /// would lose.
    var orderedJSONString: String {
        switch self {
        case .object(let object):
            let body = object.keys.map { key in
                "\(JSONValue.encodeString(key)):\(object[key]!.orderedJSONString)"
            }.joined(separator: ",")
            return "{\(body)}"
        case .array(let array):
            return "[\(array.map(\.orderedJSONString).joined(separator: ","))]"
        case .string(let string):
            return JSONValue.encodeString(string)
        case .number(let number):
            return JSONValue.encodeNumber(number)
        case .bool(let bool):
            return bool ? "true" : "false"
        case .null:
            return "null"
        }
    }

    /// Converts the value back to `Any` (for APIs that take untyped values).
    var anyValue: Any {
        switch self {
        case .object(let object):
            var dict: [String: Any] = [:]
            for key in object.keys { dict[key] = object[key]!.anyValue }
            return dict
        case .array(let array): return array.map { $0.anyValue }
        case .string(let string): return string
        case .number(let number):
            if number.rounded() == number, abs(number) < 9.007199254740992e15 {
                return Int(number)
            }
            return number
        case .bool(let bool): return bool
        case .null: return NSNull()
        }
    }

    /// Escaping rules of the canonical form: escape only `"`, `\` and control characters (< 0x20 become `\u00XX`);
    /// all other Unicode characters are emitted as is.
    static func encodeString(_ string: String) -> String {
        var result = "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            default:
                if scalar.value < 0x20 {
                    result += String(format: "\\u%04x", scalar.value)
                } else {
                    result.unicodeScalars.append(scalar)
                }
            }
        }
        result += "\""
        return result
    }

    static func encodeNumber(_ number: Double) -> String {
        if number.rounded() == number, abs(number) < 9.007199254740992e15 {
            return String(Int(number))
        }
        return String(number)
    }
}

nonisolated enum JSONValueError: Error, Equatable {
    case notUTF8
    case unexpectedEnd
    case unexpectedCharacter
    case invalidLiteral
    case trailingContent
    case invalidNumber
    /// Nesting exceeds `JSONValue.maxNestingDepth`: the parser is recursive descent, so without a limit the peer
    /// could blow the stack with a run of `[`.
    case tooDeep
}

/// Minimal order-preserving JSON parser. Serves only this module (tool schemas / annotations / arguments).
private struct JSONParser {
    let scalars: [Unicode.Scalar]
    var index = 0
    private var depth = 0

    var isAtEnd: Bool { index >= scalars.count }

    mutating func skipWhitespace() throws {
        while index < scalars.count {
            switch scalars[index] {
            case " ", "\t", "\n", "\r":
                index += 1
            default:
                return
            }
        }
    }

    mutating func parseValue() throws -> JSONValue {
        try skipWhitespace()
        guard index < scalars.count else { throw JSONValueError.unexpectedEnd }
        switch scalars[index] {
        case "{", "[":
            // Recursion only happens on containers, so depth is counted here in one place.
            guard depth < JSONValue.maxNestingDepth else { throw JSONValueError.tooDeep }
            depth += 1
            defer { depth -= 1 }
            return scalars[index] == "{" ? try parseObject() : try parseArray()
        case "\"": return .string(try parseString())
        case "t", "f": return .bool(try parseBool())
        case "n": try parseNull(); return .null
        default: return .number(try parseNumber())
        }
    }

    mutating func parseObject() throws -> JSONValue {
        index += 1 // {
        var pairs: [(String, JSONValue)] = []
        try skipWhitespace()
        if peek() == "}" { index += 1; return .object(JSONObject(pairs)) }
        while true {
            try skipWhitespace()
            guard peek() == "\"" else { throw JSONValueError.unexpectedCharacter }
            let key = try parseString()
            try skipWhitespace()
            guard peek() == ":" else { throw JSONValueError.unexpectedCharacter }
            index += 1
            let value = try parseValue()
            pairs.append((key, value))
            try skipWhitespace()
            switch peek() {
            case ",": index += 1
            case "}": index += 1; return .object(JSONObject(pairs))
            default: throw JSONValueError.unexpectedCharacter
            }
        }
    }

    mutating func parseArray() throws -> JSONValue {
        index += 1 // [
        var values: [JSONValue] = []
        try skipWhitespace()
        if peek() == "]" { index += 1; return .array(values) }
        while true {
            values.append(try parseValue())
            try skipWhitespace()
            switch peek() {
            case ",": index += 1
            case "]": index += 1; return .array(values)
            default: throw JSONValueError.unexpectedCharacter
            }
        }
    }

    mutating func parseString() throws -> String {
        index += 1 // opening quote
        var result = String.UnicodeScalarView()
        while index < scalars.count {
            let scalar = scalars[index]
            index += 1
            switch scalar {
            case "\"":
                return String(result)
            case "\\":
                guard index < scalars.count else { throw JSONValueError.unexpectedEnd }
                let escape = scalars[index]
                index += 1
                switch escape {
                case "\"": result.append("\"")
                case "\\": result.append("\\")
                case "/": result.append("/")
                case "b": result.append("\u{08}")
                case "f": result.append("\u{0C}")
                case "n": result.append("\n")
                case "r": result.append("\r")
                case "t": result.append("\t")
                case "u":
                    result.append(try parseEscapedScalar())
                default: throw JSONValueError.invalidLiteral
                }
            default:
                result.append(scalar)
            }
        }
        throw JSONValueError.unexpectedEnd
    }

    /// `\uXXXX`. Characters outside the BMP are written in JSON as a UTF-16 surrogate pair (`\ud83d\ude00`), and the
    /// two halves must be combined into one scalar; otherwise emoji from servers that escape non-ASCII output
    /// (Python's `json.dumps` default) turn into two U+FFFD and the tool content hash differs from the one the other
    /// clients compute. Only a lone surrogate is replaced with U+FFFD.
    mutating func parseEscapedScalar() throws -> Unicode.Scalar {
        let code = try parseHex4()
        if (0xD800...0xDBFF).contains(code) {
            let checkpoint = index
            if index + 1 < scalars.count, scalars[index] == "\\", scalars[index + 1] == "u" {
                index += 2
                let low = try parseHex4()
                if (0xDC00...0xDFFF).contains(low),
                   let combined = Unicode.Scalar(0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)) {
                    return combined
                }
            }
            // Not followed by a low surrogate: rewind and let it be parsed again as an ordinary escape.
            index = checkpoint
            return "\u{FFFD}"
        }
        return Unicode.Scalar(code) ?? "\u{FFFD}"
    }

    mutating func parseHex4() throws -> UInt32 {
        var value: UInt32 = 0
        for _ in 0..<4 {
            guard index < scalars.count else { throw JSONValueError.unexpectedEnd }
            let scalar = scalars[index]
            index += 1
            let digit: UInt32
            switch scalar {
            case "0"..."9": digit = scalar.value - 0x30
            case "a"..."f": digit = scalar.value - 0x61 + 10
            case "A"..."F": digit = scalar.value - 0x41 + 10
            default: throw JSONValueError.invalidLiteral
            }
            value = value * 16 + digit
        }
        return value
    }

    mutating func parseBool() throws -> Bool {
        if match("true") { return true }
        if match("false") { return false }
        throw JSONValueError.invalidLiteral
    }

    mutating func parseNull() throws {
        guard match("null") else { throw JSONValueError.invalidLiteral }
    }

    mutating func parseNumber() throws -> Double {
        let start = index
        while index < scalars.count, isNumberScalar(scalars[index]) { index += 1 }
        let text = String(String.UnicodeScalarView(scalars[start..<index]))
        // `Double("1e999")` yields infinity: JSON cannot express non-finite numbers and serializing it later would no
        // longer be valid JSON, so reject it as a bad number.
        guard let value = Double(text), value.isFinite else { throw JSONValueError.invalidNumber }
        return value
    }

    func isNumberScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "0"..."9", "-", "+", ".", "e", "E": return true
        default: return false
        }
    }

    mutating func match(_ literal: String) -> Bool {
        let literalScalars = Array(literal.unicodeScalars)
        guard index + literalScalars.count <= scalars.count else { return false }
        for (offset, scalar) in literalScalars.enumerated() where scalars[index + offset] != scalar {
            return false
        }
        index += literalScalars.count
        return true
    }

    func peek() -> Unicode.Scalar? {
        index < scalars.count ? scalars[index] : nil
    }
}
