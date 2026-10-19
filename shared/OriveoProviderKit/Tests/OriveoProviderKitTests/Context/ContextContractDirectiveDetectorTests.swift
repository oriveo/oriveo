import Foundation
@testable import OriveoProviderKit
import Testing

// Runs cases / stylePrefixCases of `shared/context-contracts/directive-detector.v2.json` case by case, calling only production functions;
// it also checks that the generated DirectiveLexicon equals the fixture lexicon and constants item by item. Strings are always compared as unicodeScalars arrays.

private struct DirectiveContract {
    var root: [String: Any]

    init() throws {
        let data = try ContextContractFixture.data("directive-detector.v2.json")
        root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func cases(_ group: String) throws -> [[String: Any]] {
        try #require(root[group] as? [[String: Any]], "\(group)")
    }
}

private func scalars(_ value: String?) -> [Unicode.Scalar]? {
    value.map { Array($0.unicodeScalars) }
}

private func scalarLists(_ values: [String]?) -> [[Unicode.Scalar]]? {
    values.map { $0.map { Array($0.unicodeScalars) } }
}

@Suite("ContextContractDirectiveDetector")
struct ContextContractDirectiveDetectorTests {
    private let contract: DirectiveContract

    init() throws {
        contract = try DirectiveContract()
    }

    @Test("cases")
    func cases() throws {
        let list = try contract.cases("cases")
        #expect(!list.isEmpty)
        var failures: [String] = []
        for item in list {
            let id = try #require(item["id"] as? String)
            let text = try #require(item["text"] as? String, "\(id)")
            let expected = try #require(item["expected"] as? [String: Any], "\(id)")
            let actual = DirectiveDetector.detect(text)
            let matches = actual.isDirective == (expected["isDirective"] as? Bool)
                && scalars(actual.span) == scalars(expected["span"] as? String)
                && actual.kind?.rawValue == expected["kind"] as? String
                && actual.scope?.rawValue == expected["scope"] as? String
            if !matches {
                failures.append("\(id): got \(actual.isDirective) \(actual.span ?? "-") \(actual.kind?.rawValue ?? "-") \(actual.scope?.rawValue ?? "-")")
            }
        }
        #expect(failures.isEmpty, "\(failures.count) failed: \(failures.prefix(40).joined(separator: "\n"))")
    }

    @Test("stylePrefixCases")
    func stylePrefixCases() throws {
        let list = try contract.cases("stylePrefixCases")
        #expect(!list.isEmpty)
        for item in list {
            let id = try #require(item["id"] as? String)
            let instructions = try #require(item["instructions"] as? String, "\(id)")
            let expected = try #require(item["expected"] as? String, "\(id)")
            let actual = DirectiveDetector.imageStylePrefix(instructions)
            #expect(scalars(actual) == scalars(expected), "\(id): \(actual)")
        }
    }

    @Test("lexicon_matches_fixture")
    func lexiconMatchesFixture() throws {
        let raw = try #require(contract.root["lexicon"] as? [String: Any])
        // Language order follows the key order of the fixture text (JSONSerialization dictionaries do not preserve order).
        let data = try ContextContractFixture.data("directive-detector.v2.json")
        let source = try #require(String(data: data, encoding: .utf8))
        let codes = DirectiveLexicon.languages.map(\.code)
        #expect(Set(codes) == Set(raw.keys))
        let lexiconStart = try #require(source.range(of: "\"lexicon\": {")).upperBound
        let positions = codes.compactMap { code in
            source.range(of: "\"\(code)\": {", range: lexiconStart..<source.endIndex)?.lowerBound
        }
        #expect(positions.count == codes.count)
        #expect(positions == positions.sorted(), "language order")
        for language in DirectiveLexicon.languages {
            let entry = try #require(raw[language.code] as? [String: Any], "\(language.code)")
            #expect(language.mode.rawValue == entry["mode"] as? String, "\(language.code) mode")
            let tables: [(String, [String])] = [
                ("markers", language.markers), ("verbs", language.verbs), ("starts", language.starts),
                ("vetoes", language.vetoes), ("fillers", language.fillers),
                ("questionParticlesAtEnd", language.questionParticlesAtEnd),
                ("languageWords", language.languageWords), ("formatWords", language.formatWords),
                ("styleWords", language.styleWords), ("imageStyleWords", language.imageStyleWords),
                ("globalMarkers", language.globalMarkers),
            ]
            for (name, table) in tables {
                #expect(scalarLists(table) == scalarLists(entry[name] as? [String]), "\(language.code).\(name)")
            }
        }
    }

    @Test("constants_match_fixture")
    func constantsMatchFixture() {
        let root = contract.root
        #expect(DirectiveLexicon.maxScanCodePoints == root["maxScanCodePoints"] as? Int)
        #expect(DirectiveLexicon.imageStylePrefixMax == root["imageStylePrefixMax"] as? Int)
        #expect(scalarLists(DirectiveLexicon.sentenceEnders) == scalarLists(root["sentenceEnders"] as? [String]))
        #expect(scalarLists(DirectiveLexicon.questionEnders) == scalarLists(root["questionEnders"] as? [String]))
        #expect(scalarLists(DirectiveLexicon.questionStarters) == scalarLists(root["questionStarters"] as? [String]))
        let pairs = (root["quotePairs"] as? [[String]])?.map { scalarLists($0) }
        #expect(DirectiveLexicon.quotePairs.map { scalarLists($0) } == pairs)
        // The whitespace set used by trim: the production constant ContextSanitizer.unicodeWhiteSpace equals the fixture whitespace code point by code point.
        let fixtureWhiteSpace = whiteSpaceCodePoints(root["whitespace"] as? [String])
        #expect(fixtureWhiteSpace?.isEmpty == false)
        let productionWhiteSpace = Set((UInt32(0)...0x10FFFF).filter { value in
            Unicode.Scalar(value).map { ContextSanitizer.unicodeWhiteSpace.contains($0) } ?? false
        })
        #expect(productionWhiteSpace == fixtureWhiteSpace)
    }
}

/// Expands a fixture whitespace entry ("U+XXXX" or "U+XXXX..U+YYYY") into a code point set; nil if any entry cannot be parsed.
private func whiteSpaceCodePoints(_ entries: [String]?) -> Set<UInt32>? {
    guard let entries else { return nil }
    var result = Set<UInt32>()
    for entry in entries {
        let bounds = entry.components(separatedBy: "..").map { bound -> UInt32? in
            guard bound.hasPrefix("U+") else { return nil }
            return UInt32(bound.dropFirst(2), radix: 16)
        }
        guard (1...2).contains(bounds.count), let low = bounds.first ?? nil, let high = bounds.last ?? nil,
              low <= high else { return nil }
        result.formUnion(low...high)
    }
    return result
}
