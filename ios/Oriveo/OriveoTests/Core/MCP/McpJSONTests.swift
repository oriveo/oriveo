import Foundation
import Testing
@testable import Oriveo

// MARK: - Resource limits and edge cases of the order-preserving JSON parser
//
// Everything parsed here is bytes returned by third-party servers: numbers can be arbitrarily large and
// nesting arbitrarily deep. The parser must not crash or overflow the stack; it may only report a parse failure.

@Suite("MCP JSON parser")
struct McpJSONTests {

    // MARK: Out-of-range numbers do not crash

    @Test("intValue: out of Int range, fractional or non-numeric values return nil instead of trapping", arguments: [
        ("1e30", nil as Int?),
        ("-1e30", nil),
        ("9223372036854775808", nil),
        ("1.5", nil),
        ("-0.25", nil),
        ("\"7\"", nil),
        ("null", nil),
        ("0", 0),
        ("-32022", -32022),
        ("3", 3),
        ("3.0", 3),
        ("1e3", 1000),
    ])
    func intValueIsTotal(text: String, expected: Int?) throws {
        let value = try JSONValue(parsing: text)
        #expect(value.intValue == expected)
    }

    @Test("A non-finite number (1e999) is rejected as invalid rather than yielding a value that cannot be re-serialized")
    func nonFiniteNumberIsRejected() {
        #expect(throws: JSONValueError.invalidNumber) { try JSONValue(parsing: #"{"id":1e999}"#) }
        #expect(throws: JSONValueError.invalidNumber) { try JSONValue(parsing: "-1e999") }
    }

    @Test("Out-of-range numbers in the runtime config do not crash: quantities are clamped, the version falls back")
    func runtimeConfigSurvivesHugeNumbers() throws {
        let json = try JSONValue(parsing: #"{"version":1e30,"maxServers":1e30,"maxResultChars":2.5,"maxSteps":4}"#)
        let config = McpRuntimeConfig(json: json)
        #expect(config.version == McpRuntimeConfig.fallback.version)
        // Out-of-range quantities are clamped to `McpRuntimeConfig.Bounds` (per-field cases live in `McpRuntimeConfigTests`).
        #expect(config.maxServers == McpRuntimeConfig.Bounds.maxServers.upperBound)
        #expect(config.maxResultChars == McpRuntimeConfig.Bounds.maxResultChars.lowerBound)
        #expect(config.maxSteps == 4)
    }

    // MARK: Nesting depth limit

    @Test("Nesting exactly at the limit parses")
    func nestingAtLimitParses() throws {
        let depth = JSONValue.maxNestingDepth
        let text = String(repeating: "[", count: depth) + String(repeating: "]", count: depth)
        var value = try JSONValue(parsing: text)
        var seen = 0
        while let inner = value.arrayValue {
            seen += 1
            guard let next = inner.first else { break }
            value = next
        }
        #expect(seen == depth)
    }

    @Test("Nesting beyond the limit is a parse failure (array / object / mixed)")
    func nestingBeyondLimitFails() {
        let depth = JSONValue.maxNestingDepth + 1
        let arrays = String(repeating: "[", count: depth) + String(repeating: "]", count: depth)
        #expect(throws: JSONValueError.tooDeep) { try JSONValue(parsing: arrays) }

        let objects = String(repeating: #"{"a":"#, count: depth) + "1" + String(repeating: "}", count: depth)
        #expect(throws: JSONValueError.tooDeep) { try JSONValue(parsing: objects) }

        let mixed = String(repeating: #"[{"a":"#, count: depth) + "1" + String(repeating: "}]", count: depth)
        #expect(throws: JSONValueError.tooDeep) { try JSONValue(parsing: mixed) }
    }

    @Test("A hundred thousand unclosed [ do not overflow the stack")
    func pathologicalNestingDoesNotOverflowStack() {
        let text = String(repeating: "[", count: 100_000)
        #expect(throws: JSONValueError.tooDeep) { try JSONValue(parsing: text) }
    }

    @Test("Sibling containers on the same level do not consume depth")
    func siblingsDoNotAccumulateDepth() throws {
        let item = String(repeating: "[", count: 10) + String(repeating: "]", count: 10)
        let text = "[" + Array(repeating: item, count: 200).joined(separator: ",") + "]"
        #expect(try JSONValue(parsing: text).arrayValue?.count == 200)
    }

    // MARK: Escapes

    @Test("A \\u surrogate pair combines into one scalar; a lone surrogate becomes U+FFFD")
    func surrogatePairs() throws {
        #expect(try JSONValue(parsing: #""😀""#).stringValue == "😀")
        #expect(try JSONValue(parsing: #""a😀b""#).stringValue == "a😀b")
        #expect(try JSONValue(parsing: #""\ud83dx""#).stringValue == "\u{FFFD}x")
        #expect(try JSONValue(parsing: #""\ud83d\n""#).stringValue == "\u{FFFD}\n")
        #expect(try JSONValue(parsing: #""\ud83dA""#).stringValue == "\u{FFFD}A")
        #expect(try JSONValue(parsing: #""\ude00""#).stringValue == "\u{FFFD}")
        #expect(try JSONValue(parsing: #""é""#).stringValue == "é")
    }

    @Test("An escaped surrogate pair and the literal character produce the same canonical JSON")
    func surrogatePairMatchesLiteral() throws {
        let escaped = try JSONValue(parsing: #"{"text":"😀"}"#)
        let literal = try JSONValue(parsing: #"{"text":"😀"}"#)
        #expect(escaped.canonicalJSONString == literal.canonicalJSONString)
    }
}
