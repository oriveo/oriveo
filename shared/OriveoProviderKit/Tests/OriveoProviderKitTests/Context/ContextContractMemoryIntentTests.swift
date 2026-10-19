import Foundation
@testable import OriveoProviderKit
import Testing

// Runs cases / fingerprintCases / candidateCases / transitionCases / sweepCases of `shared/context-contracts/memory-intent.v1.json`
// case by case, calling only production functions and expecting whole-object equality; it also checks that the generated MemoryIntentLexicon equals the fixture
// lexicon, constants and secretPatterns item by item. Strings are additionally compared as unicodeScalars arrays (String == is canonical equivalence).

private struct MemoryIntentFixture: Decodable {
    struct Case: Decodable {
        let id: String
        let text: String
        let expected: MemoryIntent.Classification
    }

    struct FingerprintCase: Decodable {
        struct Expected: Decodable {
            let canonical: String
            let fingerprint: String
        }

        let id: String
        let content: String
        let expected: Expected
    }

    struct CandidateCase: Decodable {
        let id: String
        let text: String
        let context: MemoryCandidateContext
        let expected: MemoryCandidateDecision
    }

    struct TransitionCase: Decodable {
        let id: String
        let op: String
        let record: MemoryCandidate
        let edit: MemoryCandidateEdit?
        let nowMs: Int64
        let expected: MemoryCandidateTransition
    }

    struct SweepCase: Decodable {
        let id: String
        let records: [MemoryCandidate]
        let activeContents: [String]
        let nowMs: Int64
        let expected: MemoryCandidateSweep
    }

    let cases: [Case]
    let fingerprintCases: [FingerprintCase]
    let candidateCases: [CandidateCase]
    let transitionCases: [TransitionCase]
    let sweepCases: [SweepCase]
}

private let fixtureName = "memory-intent.v1.json"

private func scalars(_ value: String?) -> [Unicode.Scalar]? {
    value.map { Array($0.unicodeScalars) }
}

private func scalarLists(_ values: [String]?) -> [[Unicode.Scalar]]? {
    values.map { $0.map { Array($0.unicodeScalars) } }
}

/// The output is encoded back into a whole JSON tree and compared with the fixture expected as is: missing keys, extra keys, null and values must all match.
private func encodedTree<T: Encodable>(_ value: T) throws -> NSObject {
    let data = try JSONEncoder().encode(value)
    return try #require(JSONSerialization.jsonObject(with: data) as? NSObject)
}

private func sameTree<T: Encodable>(_ value: T, _ expected: Any?) throws -> Bool {
    guard let expected = expected as? NSObject else { return false }
    return try encodedTree(value).isEqual(expected)
}

private func describe(_ value: MemoryIntent.Classification) -> String {
    [
        value.intent.rawValue, value.rule?.rawValue ?? "-", value.span ?? "-", value.proposition ?? "-",
        value.kind?.rawValue ?? "-", value.scope?.rawValue ?? "-", value.sensitive.rawValue,
        value.blocked?.rawValue ?? "-", value.suggestion.rawValue,
    ].joined(separator: " | ")
}

@Suite("ContextContractMemoryIntent")
struct ContextContractMemoryIntentTests {
    private let fixture: MemoryIntentFixture
    private let root: [String: Any]

    init() throws {
        fixture = try ContextContractFixture.load(fixtureName)
        let data = try ContextContractFixture.data(fixtureName)
        root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// The raw expected of each case in a fixture group (in the same order as the typed decoding).
    private func rawExpected(_ group: String) throws -> [Any?] {
        let list = try #require(root[group] as? [[String: Any]], "\(group)")
        return list.map { $0["expected"] }
    }

    @Test("cases")
    func cases() throws {
        #expect(!fixture.cases.isEmpty)
        let raw = try rawExpected("cases")
        #expect(raw.count == fixture.cases.count)
        var failures: [String] = []
        for (item, expectedTree) in zip(fixture.cases, raw) {
            let actual = MemoryIntent.classify(item.text)
            let matches = try actual == item.expected
                && sameTree(actual, expectedTree)
                && scalars(actual.span) == scalars(item.expected.span)
                && scalars(actual.proposition) == scalars(item.expected.proposition)
            if !matches {
                failures.append("\(item.id): got \(describe(actual)) want \(describe(item.expected))")
            }
        }
        #expect(failures.isEmpty, "\(failures.count) failed:\n\(failures.prefix(60).joined(separator: "\n"))")
    }

    @Test("fingerprintCases")
    func fingerprintCases() {
        #expect(!fixture.fingerprintCases.isEmpty)
        for item in fixture.fingerprintCases {
            #expect(scalars(MemoryIntent.canonical(item.content)) == scalars(item.expected.canonical), "\(item.id) canonical")
            #expect(MemoryIntent.fingerprint(item.content) == item.expected.fingerprint, "\(item.id) fingerprint")
        }
    }

    @Test("candidateCases")
    func candidateCases() throws {
        #expect(!fixture.candidateCases.isEmpty)
        let raw = try rawExpected("candidateCases")
        #expect(raw.count == fixture.candidateCases.count)
        for (item, expectedTree) in zip(fixture.candidateCases, raw) {
            let classification = MemoryIntent.classify(item.text)
            let actual = MemoryIntent.makeCandidate(classification, context: item.context)
            #expect(actual == item.expected, "\(item.id): \(actual)")
            let tree = try encodedTree(actual)
            #expect(tree.isEqual(expectedTree as? NSObject), "\(item.id) json: \(tree)")
            #expect(scalars(actual.candidate?.content) == scalars(item.expected.candidate?.content), "\(item.id) content")
        }
    }

    @Test("transitionCases")
    func transitionCases() throws {
        #expect(!fixture.transitionCases.isEmpty)
        let raw = try rawExpected("transitionCases")
        #expect(raw.count == fixture.transitionCases.count)
        for (item, expectedTree) in zip(fixture.transitionCases, raw) {
            let actual: MemoryCandidateTransition
            switch item.op {
            case "accept":
                actual = MemoryIntent.accept(item.record, edit: item.edit, nowMs: item.nowMs)
            case "reject":
                actual = MemoryIntent.reject(item.record, nowMs: item.nowMs)
            default:
                Issue.record("\(item.id): unknown op \(item.op)")
                continue
            }
            #expect(actual == item.expected, "\(item.id): \(actual)")
            let tree = try encodedTree(actual)
            #expect(tree.isEqual(expectedTree as? NSObject), "\(item.id) json: \(tree)")
            #expect(scalars(actual.item?.content) == scalars(item.expected.item?.content), "\(item.id) item content")
        }
    }

    @Test("sweepCases")
    func sweepCases() {
        #expect(!fixture.sweepCases.isEmpty)
        for item in fixture.sweepCases {
            let actual = MemoryIntent.sweep(item.records, activeContents: item.activeContents, nowMs: item.nowMs)
            #expect(actual == item.expected, "\(item.id): \(actual)")
        }
    }

    @Test("lexicon_matches_fixture")
    func lexiconMatchesFixture() throws {
        let raw = try #require(root["lexicon"] as? [String: Any])
        let modes = try #require(root["lexiconModes"] as? [String: String])
        #expect(MemoryIntentLexicon.version == root["version"] as? Int)
        // Language order follows the key order of the fixture text (JSONSerialization dictionaries do not preserve order).
        let data = try ContextContractFixture.data(fixtureName)
        let source = try #require(String(data: data, encoding: .utf8))
        let codes = MemoryIntentLexicon.languages.map(\.code)
        #expect(Set(codes) == Set(raw.keys))
        let lexiconStart = try #require(source.range(of: "\"lexicon\": {")).upperBound
        let positions = codes.compactMap { code in
            source.range(of: "\"\(code)\": {", range: lexiconStart..<source.endIndex)?.lowerBound
        }
        #expect(positions.count == codes.count)
        #expect(positions == positions.sorted(), "language order")
        for language in MemoryIntentLexicon.languages {
            let entry = try #require(raw[language.code] as? [String: Any], "\(language.code)")
            #expect(language.mode.rawValue == modes[language.code], "\(language.code) mode")
            let kindStarts = try #require(entry["kindStarts"] as? [String: Any], "\(language.code).kindStarts")
            let tables: [(String, [String], [String]?)] = [
                ("memoryWords", language.memoryWords, entry["memoryWords"] as? [String]),
                ("metaTerms", language.metaTerms, entry["metaTerms"] as? [String]),
                ("recallAddressees", language.recallAddressees, entry["recallAddressees"] as? [String]),
                ("recallTerms", language.recallTerms, entry["recallTerms"] as? [String]),
                ("deleteTerms", language.deleteTerms, entry["deleteTerms"] as? [String]),
                ("deleteExceptions", language.deleteExceptions, entry["deleteExceptions"] as? [String]),
                ("supersedeTerms", language.supersedeTerms, entry["supersedeTerms"] as? [String]),
                ("transientTerms", language.transientTerms, entry["transientTerms"] as? [String]),
                ("transientExceptions", language.transientExceptions, entry["transientExceptions"] as? [String]),
                ("persistStarts", language.persistStarts, entry["persistStarts"] as? [String]),
                ("reminderStarts", language.reminderStarts, entry["reminderStarts"] as? [String]),
                ("ackTerms", language.ackTerms, entry["ackTerms"] as? [String]),
                ("reminisceStarts", language.reminisceStarts, entry["reminisceStarts"] as? [String]),
                ("politePrefixes", language.politePrefixes, entry["politePrefixes"] as? [String]),
                ("linkers", language.linkers, entry["linkers"] as? [String]),
                ("anaphorOnly", language.anaphorOnly, entry["anaphorOnly"] as? [String]),
                ("anaphorDirective", language.anaphorDirective, entry["anaphorDirective"] as? [String]),
                ("uncertainMarkers", language.uncertainMarkers, entry["uncertainMarkers"] as? [String]),
                ("implicitMarkers", language.implicitMarkers, entry["implicitMarkers"] as? [String]),
                ("folderMarkers", language.folderMarkers, entry["folderMarkers"] as? [String]),
                ("conversationMarkers", language.conversationMarkers, entry["conversationMarkers"] as? [String]),
                ("secretTerms", language.secretTerms, entry["secretTerms"] as? [String]),
                ("specialTerms", language.specialTerms, entry["specialTerms"] as? [String]),
                ("kindStarts.project", language.kindProject, kindStarts["project"] as? [String]),
                ("kindStarts.goal", language.kindGoal, kindStarts["goal"] as? [String]),
                ("kindStarts.preference", language.kindPreference, kindStarts["preference"] as? [String]),
                ("kindStarts.identity", language.kindIdentity, kindStarts["identity"] as? [String]),
            ]
            #expect(tables.count == entry.count - 1 + kindStarts.count, "\(language.code) table count")
            #expect(Set(kindStarts.keys) == ["project", "goal", "preference", "identity"], "\(language.code) kindStarts keys")
            for (name, table, expected) in tables {
                #expect(expected != nil, "\(language.code).\(name) missing")
                #expect(scalarLists(table) == scalarLists(expected), "\(language.code).\(name)")
            }
        }
    }

    @Test("constants_match_fixture")
    func constantsMatchFixture() throws {
        let constants = try #require(root["constants"] as? [String: Any])
        let confidence = try #require(constants["confidence"] as? [String: Any])
        #expect(MemoryIntentLexicon.candidateTtlMs == (constants["candidateTtlMs"] as? NSNumber)?.int64Value)
        #expect(MemoryIntentLexicon.contentMaxCodePoints == constants["contentMaxCodePoints"] as? Int)
        #expect(MemoryIntentLexicon.uuidNamespace == constants["uuidNamespace"] as? String)
        #expect(MemoryIntentLexicon.uuidNamespace == MemoryItems.uuidNamespace)
        #expect(MemoryIntentLexicon.confidenceExplicit == confidence["explicit_persist"] as? Double)
        #expect(MemoryIntentLexicon.confidenceImplicit == confidence["implicit_persist"] as? Double)
        #expect(scalars(MemoryIntentLexicon.codeTokenChars) == scalars(constants["codeTokenChars"] as? String))
        #expect(scalars(MemoryIntentLexicon.separators) == scalars(constants["separators"] as? String))
        let patterns = try #require(root["secretPatterns"] as? [[String: Any]])
        #expect(MemoryIntentLexicon.secretPatterns.count == patterns.count)
        for (actual, expected) in zip(MemoryIntentLexicon.secretPatterns, patterns) {
            #expect(actual.id == expected["id"] as? String)
            #expect(scalars(actual.regex) == scalars(expected["regex"] as? String), "\(actual.id) regex")
            #expect(actual.luhn == expected["luhn"] as? Bool, "\(actual.id) luhn")
        }
    }

    @Test("no_classification_writes_active")
    func noClassificationWritesActive() throws {
        let context = MemoryCandidateContext(
            conversationId: "3f1c9a52-7d4e-4b8a-9c21-5e6f7a8b9c0d",
            folderId: nil,
            messageId: "0b1c2d3e-4f50-4617-8899-aabbccddeeff",
            nowMs: 1_792_137_600_000,
            activeContents: [],
            records: []
        )
        var created = 0
        for item in fixture.cases {
            let decision = MemoryIntent.makeCandidate(MemoryIntent.classify(item.text), context: context)
            guard decision.action == .create else {
                #expect(decision.candidate == nil, "\(item.id) skip carries no candidate")
                continue
            }
            created += 1
            let candidate = try #require(decision.candidate, "\(item.id)")
            #expect(candidate.status == .pending, "\(item.id) create is pending")
            let accepted = MemoryIntent.accept(candidate, edit: nil, nowMs: context.nowMs + 1)
            #expect(accepted.error == nil, "\(item.id)")
            #expect(accepted.record?.status == .accepted, "\(item.id) record")
            #expect(accepted.item?.status == .active, "\(item.id) only accept yields an active draft")
        }
        #expect(created > 0)
    }
}
