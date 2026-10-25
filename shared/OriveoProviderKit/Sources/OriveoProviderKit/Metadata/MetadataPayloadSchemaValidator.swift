import CoreFoundation
import Foundation

/// A JSON Schema validator for metadata v2 (`shared/model-contracts/metadata_payload.v2.schema.json`).
///
/// Implements only the keywords the contract schema actually uses, listed in `supportedKeywords` ($ref resolves only `#/$defs/...` within the same file,
/// format accepts only date-time from `supportedFormats`, per RFC 3339). Annotation keywords are listed in `annotationKeywords` and ignored;
/// any other keyword makes construction throw: if the schema ever uses a keyword that is not implemented here, failing at startup is better than silently letting payloads through.
/// These three sets must stay in step with the shared schema: whenever the schema starts using a new keyword,
/// this validator has to implement it first. Keep the sets as `[...]` literals.
///
/// The input is the `Any` produced by `JSONSerialization`. JSONSerialization returns NSNumber for both numbers and booleans,
/// and only a CFBoolean counts as a boolean; an integer is a number without a fractional part (1.0 counts).
///
/// Internal state is read-only after construction, so the class is marked `@unchecked Sendable` (NSRegularExpression itself is thread-safe).
public final class MetadataPayloadSchemaValidator: @unchecked Sendable {
    /// One violation. It carries only the location and keyword, never the instance value: violations end up in logs and the value may hold user data.
    public struct Violation: Equatable, Hashable, Sendable, CustomStringConvertible {
        /// JSON Pointer (RFC 6901); the root is the empty string.
        public let instancePath: String
        public let keyword: String

        public init(instancePath: String, keyword: String) {
            self.instancePath = instancePath
            self.keyword = keyword
        }

        public var description: String { "\(instancePath.isEmpty ? "/" : instancePath): \(keyword)" }
    }

    public enum SchemaError: Error, Equatable, Sendable {
        /// The schema text is not a JSON object.
        case notAnObject
        /// A keyword that is not implemented was used. schemaPath is a JSON Pointer within the schema.
        case unsupportedKeyword(String, schemaPath: String)
        /// A keyword value has the wrong shape (for example required is not an array of strings, or the pattern does not compile).
        case invalidKeywordValue(String, schemaPath: String)
        /// $ref is not of the form `#/$defs/<name>`, or points to a def that does not exist.
        case unresolvedReference(String, schemaPath: String)
    }

    static let supportedKeywords: Set<String> = [
        "type", "required", "oneOf", "allOf", "$ref", "$defs", "const", "minimum", "format",
        "additionalProperties", "minLength", "minItems", "pattern", "items", "enum", "properties",
    ]
    static let supportedFormats: Set<String> = ["date-time"]
    static let annotationKeywords: Set<String> = ["$schema", "$id", "$comment", "title", "description"]
    private static let knownTypes: Set<String> = ["null", "boolean", "object", "array", "number", "string", "integer"]
    private static let refPrefix = "#/$defs/"

    private let root: Schema
    private let defs: [String: Schema]

    public init(schemaData: Data) throws {
        guard let object = try JSONSerialization.jsonObject(with: schemaData) as? [String: Any] else {
            throw SchemaError.notAnObject
        }
        var refs: [(name: String, schemaPath: String)] = []
        var compiledDefs: [String: Schema] = [:]
        if let rawDefs = object["$defs"] {
            guard let defsObject = rawDefs as? [String: Any] else {
                throw SchemaError.invalidKeywordValue("$defs", schemaPath: "/$defs")
            }
            for (name, rawDef) in defsObject {
                compiledDefs[name] = try Self.compile(rawDef, path: "/$defs/" + Self.escape(name), isRoot: false, refs: &refs)
            }
        }
        root = try Self.compile(object, path: "", isRoot: true, refs: &refs)
        defs = compiledDefs
        for ref in refs where compiledDefs[ref.name] == nil {
            throw SchemaError.unresolvedReference(Self.refPrefix + ref.name, schemaPath: ref.schemaPath)
        }
    }

    /// Validates `value`. With `def` nil it validates against the root schema, otherwise against the sub-schema of that name in `$defs`;
    /// an unknown name returns a single `$defs` violation at the root (a caller who mistypes the name is never reported as passing).
    public func validate(_ value: Any, def: String? = nil) -> [Violation] {
        let schema: Schema
        if let def {
            guard let found = defs[def] else { return [Violation(instancePath: "", keyword: "$defs")] }
            schema = found
        } else {
            schema = root
        }
        var violations: [Violation] = []
        evaluate(schema, value: JSONValue(value), path: "", inPlaceRefs: [], into: &violations)
        return violations
    }

    // MARK: - Compilation

    private indirect enum Schema {
        case always(Bool)
        case node(Node)
    }

    private enum AdditionalProperties {
        case allowed
        case forbidden
        case schema(Schema)
    }

    private struct Node {
        var types: Set<String>?
        var required: [String] = []
        var properties: [String: Schema] = [:]
        var additionalProperties: AdditionalProperties = .allowed
        var oneOf: [Schema]?
        var allOf: [Schema]?
        var ref: String?
        var constValue: JSONValue?
        var enumValues: [JSONValue]?
        var minimum: Decimal?
        var dateTimeFormat = false
        var minLength: Int?
        var minItems: Int?
        var pattern: NSRegularExpression?
        var items: Schema?
    }

    private static func compile(
        _ raw: Any, path: String, isRoot: Bool, refs: inout [(name: String, schemaPath: String)]
    ) throws -> Schema {
        if let flag = raw as? NSNumber, JSONValue.isBoolean(flag) { return .always(flag.boolValue) }
        guard let object = raw as? [String: Any] else {
            throw SchemaError.invalidKeywordValue("schema", schemaPath: path)
        }
        var node = Node()
        for (keyword, value) in object {
            let here = path + "/" + escape(keyword)
            if annotationKeywords.contains(keyword) { continue }
            guard supportedKeywords.contains(keyword) else { throw SchemaError.unsupportedKeyword(keyword, schemaPath: here) }
            switch keyword {
            case "$defs":
                // The root $defs are compiled separately by init; nested $defs are not supported ($ref resolves only against the root).
                guard isRoot else { throw SchemaError.unsupportedKeyword(keyword, schemaPath: here) }
            case "type":
                let names: [String]
                if let single = value as? String {
                    names = [single]
                } else if let list = value as? [String], !list.isEmpty {
                    names = list
                } else {
                    throw SchemaError.invalidKeywordValue(keyword, schemaPath: here)
                }
                guard names.allSatisfy(knownTypes.contains) else {
                    throw SchemaError.invalidKeywordValue(keyword, schemaPath: here)
                }
                node.types = Set(names)
            case "required":
                guard let list = value as? [String] else { throw SchemaError.invalidKeywordValue(keyword, schemaPath: here) }
                node.required = list
            case "properties":
                guard let map = value as? [String: Any] else { throw SchemaError.invalidKeywordValue(keyword, schemaPath: here) }
                for (name, sub) in map {
                    node.properties[name] = try compile(sub, path: here + "/" + escape(name), isRoot: false, refs: &refs)
                }
            case "additionalProperties":
                if let flag = value as? NSNumber, JSONValue.isBoolean(flag) {
                    node.additionalProperties = flag.boolValue ? .allowed : .forbidden
                } else {
                    node.additionalProperties = .schema(try compile(value, path: here, isRoot: false, refs: &refs))
                }
            case "oneOf", "allOf":
                guard let list = value as? [Any], !list.isEmpty else {
                    throw SchemaError.invalidKeywordValue(keyword, schemaPath: here)
                }
                let compiled = try list.enumerated().map { index, sub in
                    try compile(sub, path: here + "/\(index)", isRoot: false, refs: &refs)
                }
                if keyword == "oneOf" { node.oneOf = compiled } else { node.allOf = compiled }
            case "$ref":
                guard let text = value as? String else { throw SchemaError.invalidKeywordValue(keyword, schemaPath: here) }
                guard text.hasPrefix(refPrefix), text.count > refPrefix.count else {
                    throw SchemaError.unresolvedReference(text, schemaPath: here)
                }
                let name = unescape(String(text.dropFirst(refPrefix.count)))
                node.ref = name
                refs.append((name, here))
            case "const":
                node.constValue = JSONValue(value)
            case "enum":
                guard let list = value as? [Any] else { throw SchemaError.invalidKeywordValue(keyword, schemaPath: here) }
                node.enumValues = list.map(JSONValue.init)
            case "minimum":
                guard case .number(let bound) = JSONValue(value) else {
                    throw SchemaError.invalidKeywordValue(keyword, schemaPath: here)
                }
                node.minimum = bound
            case "format":
                guard let name = value as? String else { throw SchemaError.invalidKeywordValue(keyword, schemaPath: here) }
                guard supportedFormats.contains(name) else { throw SchemaError.unsupportedKeyword("format:\(name)", schemaPath: here) }
                node.dateTimeFormat = true
            case "minLength":
                guard case .number(let bound) = JSONValue(value), bound >= 0, JSONValue.isIntegral(bound) else {
                    throw SchemaError.invalidKeywordValue(keyword, schemaPath: here)
                }
                node.minLength = NSDecimalNumber(decimal: bound).intValue
            case "minItems":
                // The contract's regionPricing uses it; if it were not recognised, constructing the whole validator would fail and every schema 2 payload would be rejected.
                guard case .number(let bound) = JSONValue(value), bound >= 0, JSONValue.isIntegral(bound) else {
                    throw SchemaError.invalidKeywordValue(keyword, schemaPath: here)
                }
                node.minItems = NSDecimalNumber(decimal: bound).intValue
            case "pattern":
                guard let text = value as? String, let regex = try? NSRegularExpression(pattern: text) else {
                    throw SchemaError.invalidKeywordValue(keyword, schemaPath: here)
                }
                node.pattern = regex
            case "items":
                node.items = try compile(value, path: here, isRoot: false, refs: &refs)
            default:
                throw SchemaError.unsupportedKeyword(keyword, schemaPath: here)
            }
        }
        return .node(node)
    }

    // MARK: - Evaluation

    /// `inPlaceRefs` records the defs already expanded at the same instance location, so that an A -> B -> A cycle in the schema that never descends into the instance
    /// cannot turn evaluation into an infinite loop; it is cleared as soon as evaluation descends into a child instance.
    private func evaluate(
        _ schema: Schema, value: JSONValue, path: String, inPlaceRefs: Set<String>, into violations: inout [Violation]
    ) {
        let node: Node
        switch schema {
        case .always(true): return
        case .always(false):
            violations.append(Violation(instancePath: path, keyword: "false"))
            return
        case .node(let found): node = found
        }

        if let ref = node.ref, !inPlaceRefs.contains(ref), let target = defs[ref] {
            evaluate(target, value: value, path: path, inPlaceRefs: inPlaceRefs.union([ref]), into: &violations)
        }
        if let types = node.types, !types.contains(where: { value.matches(type: $0) }) {
            violations.append(Violation(instancePath: path, keyword: "type"))
        }
        if let expected = node.constValue, expected != value {
            violations.append(Violation(instancePath: path, keyword: "const"))
        }
        if let options = node.enumValues, !options.contains(value) {
            violations.append(Violation(instancePath: path, keyword: "enum"))
        }
        if let allOf = node.allOf {
            for sub in allOf {
                evaluate(sub, value: value, path: path, inPlaceRefs: inPlaceRefs, into: &violations)
            }
        }
        if let oneOf = node.oneOf {
            var passing = 0
            for sub in oneOf {
                var scratch: [Violation] = []
                evaluate(sub, value: value, path: path, inPlaceRefs: inPlaceRefs, into: &scratch)
                if scratch.isEmpty { passing += 1 }
            }
            if passing != 1 { violations.append(Violation(instancePath: path, keyword: "oneOf")) }
        }

        switch value {
        case .number(let number):
            if let minimum = node.minimum, number < minimum {
                violations.append(Violation(instancePath: path, keyword: "minimum"))
            }
        case .string(let text):
            if let minLength = node.minLength, text.unicodeScalars.count < minLength {
                violations.append(Violation(instancePath: path, keyword: "minLength"))
            }
            if let regex = node.pattern,
               regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) == nil {
                violations.append(Violation(instancePath: path, keyword: "pattern"))
            }
            if node.dateTimeFormat, !Self.isRFC3339DateTime(text) {
                violations.append(Violation(instancePath: path, keyword: "format"))
            }
        case .array(let elements):
            if let minItems = node.minItems, elements.count < minItems {
                violations.append(Violation(instancePath: path, keyword: "minItems"))
            }
            if let items = node.items {
                for (index, element) in elements.enumerated() {
                    evaluate(items, value: element, path: path + "/\(index)", inPlaceRefs: [], into: &violations)
                }
            }
        case .object(let fields):
            for name in node.required where fields[name] == nil {
                violations.append(Violation(instancePath: path, keyword: "required"))
            }
            for (name, fieldValue) in fields.sorted(by: { $0.key < $1.key }) {
                let childPath = path + "/" + Self.escape(name)
                if let sub = node.properties[name] {
                    evaluate(sub, value: fieldValue, path: childPath, inPlaceRefs: [], into: &violations)
                    continue
                }
                switch node.additionalProperties {
                case .allowed: break
                case .forbidden: violations.append(Violation(instancePath: childPath, keyword: "additionalProperties"))
                case .schema(let sub): evaluate(sub, value: fieldValue, path: childPath, inPlaceRefs: [], into: &violations)
                }
            }
        case .null, .bool:
            break
        }
    }

    // MARK: - RFC 3339 date-time

    /// Copied from the DATE and TIME regexes of ajv-formats 3.0.1 (`getDateTime(true)`), so every platform uses the same definition.
    private static let dateRegex = try! NSRegularExpression(pattern: #"^(\d\d\d\d)-(\d\d)-(\d\d)$"#)
    private static let timeRegex = try! NSRegularExpression(
        pattern: #"^(\d\d):(\d\d):(\d\d(?:\.\d+)?)(z|([+-])(\d\d)(?::?(\d\d))?)?$"#,
        options: [.caseInsensitive]
    )
    private static let dateTimeSeparator = try! NSRegularExpression(pattern: #"t|\s"#, options: [.caseInsensitive])

    /// RFC 3339 section 5.6 date-time, aligned line by line with ajv-formats 3.0.1 `getDateTime(true)`:
    /// the date and time are separated by `T`, `t` or one whitespace character, the time zone is required (the offset may be +hh:mm or +hhmm),
    /// the calendar date must exist, and second 60 is valid only when it converts to 23:59 UTC (leap second).
    static func isRFC3339DateTime(_ text: String) -> Bool {
        let whole = NSRange(text.startIndex..., in: text)
        let separators = dateTimeSeparator.matches(in: text, range: whole)
        guard separators.count == 1, let separator = Range(separators[0].range, in: text) else { return false }
        return isDate(String(text[..<separator.lowerBound])) && isStrictTime(String(text[separator.upperBound...]))
    }

    private static func groups(_ regex: NSRegularExpression, _ text: String) -> [String?]? {
        guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (0 ..< match.numberOfRanges).map { index in
            Range(match.range(at: index), in: text).map { String(text[$0]) }
        }
    }

    private static func isDate(_ text: String) -> Bool {
        guard let parts = groups(dateRegex, text),
              let year = parts[1].flatMap({ Int($0) }), let month = parts[2].flatMap({ Int($0) }),
              let day = parts[3].flatMap({ Int($0) }) else { return false }
        guard (1 ... 12).contains(month) else { return false }
        let isLeap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
        let daysInMonth = month == 2 && isLeap ? 29 : [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][month - 1]
        return day >= 1 && day <= daysInMonth
    }

    private static func isStrictTime(_ text: String) -> Bool {
        guard let parts = groups(timeRegex, text),
              let hour = parts[1].flatMap({ Int($0) }), let minute = parts[2].flatMap({ Int($0) }),
              let second = parts[3].flatMap({ Double($0) }) else { return false }
        guard parts[4] != nil else { return false }
        let sign = parts[5] == "-" ? -1 : 1
        let offsetHour = parts[6].flatMap { Int($0) } ?? 0
        let offsetMinute = parts[7].flatMap { Int($0) } ?? 0
        guard offsetHour <= 23, offsetMinute <= 59 else { return false }
        if hour <= 23, minute <= 59, second < 60 { return true }
        // Leap second: it must convert to 23:59 UTC (after borrowing, -1 means 23:00 of the previous day or minute 59 of the previous hour).
        let utcMinute = minute - offsetMinute * sign
        let utcHour = hour - offsetHour * sign - (utcMinute < 0 ? 1 : 0)
        return (utcHour == 23 || utcHour == -1) && (utcMinute == 59 || utcMinute == -1) && second < 61
    }

    // MARK: - JSON Pointer

    private static func escape(_ token: String) -> String {
        token.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(of: "/", with: "~1")
    }

    private static func unescape(_ token: String) -> String {
        token.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
    }
}

/// The validator's internal JSON value. It is used only for type checks and const / enum equality comparison.
private enum JSONValue: Equatable {
    case null
    case bool(Bool)
    case number(Decimal)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(_ raw: Any) {
        if raw is NSNull {
            self = .null
        } else if let text = raw as? String {
            self = .string(text)
        } else if let number = raw as? NSNumber {
            self = Self.isBoolean(number) ? .bool(number.boolValue) : .number(number.decimalValue)
        } else if let list = raw as? [Any] {
            self = .array(list.map(JSONValue.init))
        } else if let map = raw as? [String: Any] {
            self = .object(map.mapValues(JSONValue.init))
        } else {
            // JSONSerialization never produces other types; anything that gets here is treated as null, and the type check rejects it.
            self = .null
        }
    }

    /// JSONSerialization's true / false are CFBoolean singletons; a plain 0 / 1 is a different CFNumber.
    static func isBoolean(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    static func isIntegral(_ value: Decimal) -> Bool {
        var source = value
        var rounded = Decimal()
        NSDecimalRound(&rounded, &source, 0, .plain)
        return rounded == value
    }

    func matches(type name: String) -> Bool {
        switch (name, self) {
        case ("null", .null), ("boolean", .bool), ("string", .string), ("array", .array), ("object", .object),
             ("number", .number):
            return true
        case ("integer", .number(let value)):
            return Self.isIntegral(value)
        default:
            return false
        }
    }
}
