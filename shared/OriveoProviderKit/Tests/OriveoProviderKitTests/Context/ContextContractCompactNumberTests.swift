import Foundation
import OriveoProviderKit
import Testing

// Runs `shared/context-contracts/compact-number.v1.json` case by case: format / resolveLocale whole-string equality,
// and the 16-language table in production code equals the fixture locales item by item (key set and order too). Failure messages carry the fixture case id.

private struct CompactNumberContract: Decodable {
    struct CaseInput: Decodable {
        var value: Int
        var locale: String
    }

    struct FormatCase: Decodable {
        var id: String
        var input: CaseInput
        var expected: String
    }

    struct LocaleCase: Decodable {
        var id: String
        var input: String
        var expected: String
    }

    struct Tier: Decodable {
        var min: Int
        var pattern: String
        var few: String?
    }

    struct Table: Decodable {
        var decimal: String
        var group: String
        var tiers: [Tier]
    }

    var cases: [FormatCase]
    var localeCases: [LocaleCase]
    var locales: [String: Table]
}

@Suite("ContextContractCompactNumber")
struct ContextContractCompactNumberTests {
    private let contract: CompactNumberContract

    init() throws {
        contract = try ContextContractFixture.load("compact-number.v1.json")
    }

    @Test("cases")
    func cases() {
        #expect(!contract.cases.isEmpty)
        for item in contract.cases {
            let actual = ContextCompactNumber.format(item.input.value, locale: item.input.locale)
            #expect(actual == item.expected, "\(item.id)")
        }
    }

    @Test("locale_cases")
    func localeCases() {
        #expect(!contract.localeCases.isEmpty)
        for item in contract.localeCases {
            #expect(ContextCompactNumber.resolveLocale(item.input) == item.expected, "\(item.id)")
        }
    }

    @Test("table_equals_fixture")
    func tableEqualsFixture() throws {
        let codes = ContextCompactNumber.tables.map(\.code)
        #expect(codes == ContextCompactNumber.localeCodes)
        #expect(try Self.fixtureLocaleOrder() == codes)
        #expect(Set(contract.locales.keys) == Set(codes))

        // Each tier allows only the keys min / pattern / few, so that a field newly added to the fixture is not silently ignored by Decodable.
        let root = try #require(
            JSONSerialization.jsonObject(with: ContextContractFixture.data("compact-number.v1.json")) as? [String: Any]
        )
        let rawLocales = try #require(root["locales"] as? [String: [String: Any]])

        for entry in ContextCompactNumber.tables {
            let expected = try #require(contract.locales[entry.code], "\(entry.code)")
            #expect(Self.scalars(entry.table.decimal) == Self.scalars(expected.decimal), "\(entry.code) decimal")
            #expect(Self.scalars(entry.table.group) == Self.scalars(expected.group), "\(entry.code) group")
            #expect(entry.table.tiers.count == expected.tiers.count, "\(entry.code) tiers")
            let rawLocale = try #require(rawLocales[entry.code], "\(entry.code)")
            #expect(Set(rawLocale.keys) == ["decimal", "group", "tiers"], "\(entry.code) keys")
            let rawTiers = try #require(rawLocale["tiers"] as? [[String: Any]], "\(entry.code) tiers")
            for (index, pair) in zip(entry.table.tiers, expected.tiers).enumerated() {
                let (actual, want) = pair
                #expect(actual.min == want.min, "\(entry.code) tier \(index) min")
                #expect(Self.scalars(actual.pattern) == Self.scalars(want.pattern), "\(entry.code) tier \(index) pattern")
                #expect(actual.few.map(Self.scalars) == want.few.map(Self.scalars), "\(entry.code) tier \(index) few")
                #expect(Set(rawTiers[index].keys).isSubset(of: ["min", "pattern", "few"]), "\(entry.code) tier \(index) keys")
            }
        }
    }

    /// String == compares by canonical equivalence (NFC / NFD count as equal), but the table must match code point by code point.
    private static func scalars(_ text: String) -> [Unicode.Scalar] {
        Array(text.unicodeScalars)
    }

    /// JSONDecoder / JSONSerialization both lose object key order; sort by the position where `"<code>": {` appears in the fixture text within the locales section.
    private static func fixtureLocaleOrder() throws -> [String] {
        let text = try #require(String(data: ContextContractFixture.data("compact-number.v1.json"), encoding: .utf8))
        let localesStart = try #require(text.range(of: "\"locales\": {")).upperBound
        let localesEnd = try #require(text.range(of: "\"localeCases\"", range: localesStart..<text.endIndex)).lowerBound
        let section = String(text[localesStart..<localesEnd])
        let root = try #require(
            JSONSerialization.jsonObject(with: ContextContractFixture.data("compact-number.v1.json")) as? [String: Any]
        )
        let keys = try #require(root["locales"] as? [String: Any]).keys
        let positions = try keys.map { key -> (String, String.Index) in
            (key, try #require(section.range(of: "\"\(key)\": {")).lowerBound)
        }
        return positions.sorted { $0.1 < $1.1 }.map(\.0)
    }
}
