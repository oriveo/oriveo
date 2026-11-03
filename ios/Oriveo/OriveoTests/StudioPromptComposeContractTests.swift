import Foundation
import Testing
@testable import Oriveo

/// Prompt composition cases shared by all three clients: reads
/// `shared/studio-contracts/studio_prompt_compose.v1.json` and compares every case's
/// composed prompt, error and adjustments with expect.
@Suite("StudioPromptComposeContractTests")
struct StudioPromptComposeContractTests {
    private struct BadFixture: Error {
        let detail: String
    }

    private static func repoFile(_ components: [String]) throws -> URL {
        var current = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while true {
            let candidate = components.reduce(current) { $0.appendingPathComponent($1) }
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { break }
            current = parent
        }
        throw CocoaError(.fileNoSuchFile)
    }

    private static func fixture() throws -> JSONValue {
        let url = try repoFile(["\u{5171}\u{4EAB}", "studio-contracts", "studio_prompt_compose.v1.json"])
        return try JSONValue(data: Data(contentsOf: url))
    }

    private static func input(_ raw: JSONValue?, _ caseId: String) throws -> StudioPromptComposer.Input {
        guard let userPrompt = raw?["userPrompt"]?.stringValue,
              let rawReferences = raw?["references"]?.arrayValue,
              let maxPromptChars = raw?["maxPromptChars"]?.intValue
        else { throw BadFixture(detail: "\(caseId): input") }
        let references = try rawReferences.map { ref -> StudioPromptComposer.Reference in
            guard let n = ref["n"]?.intValue,
                  let role = ref["role"]?.stringValue.flatMap(StudioPromptComposer.Role.init(rawValue:))
            else { throw BadFixture(detail: "\(caseId): reference") }
            return StudioPromptComposer.Reference(n: n, role: role)
        }
        let styleFragment: String?
        switch raw?["styleFragment"] {
        case .none, .some(.null): styleFragment = nil
        case .some(.string(let text)): styleFragment = text
        default: throw BadFixture(detail: "\(caseId): styleFragment")
        }
        let effectFragments = try (raw?["effectFragments"]?.arrayValue ?? []).map { value -> String in
            guard let text = value.stringValue else { throw BadFixture(detail: "\(caseId): effectFragments") }
            return text
        }
        return StudioPromptComposer.Input(
            userPrompt: userPrompt,
            references: references,
            styleFragment: styleFragment,
            effectFragments: effectFragments,
            maxPromptChars: maxPromptChars
        )
    }

    private static func json(_ result: StudioPromptComposer.Composition) -> JSONValue {
        .object(JSONObject([
            ("composed", result.composed.map(JSONValue.string) ?? .null),
            ("error", result.error.map { JSONValue.string($0.rawValue) } ?? .null),
            ("adjustments", .array(result.adjustments.map { adjustment in
                .object(JSONObject([
                    ("field", .string(adjustment.field.rawValue)),
                    ("dropped", .string(adjustment.dropped)),
                ]))
            })),
        ]))
    }

    @Test("Every compose case yields the expected prompt, error and adjustments")
    func composeCases() throws {
        let fixture = try Self.fixture()
        #expect(fixture["contractId"]?.stringValue == "studio_prompt_compose.v1")
        let specValue = try #require(fixture["spec"])
        let spec = try JSONDecoder().decode(StudioPromptComposer.Spec.self, from: Data(specValue.orderedJSONString.utf8))
        #expect(spec == StudioPromptComposer.Spec.v1, "built-in spec matches the fixture spec")
        let cases = try #require(fixture["cases"]?.arrayValue)
        #expect(!cases.isEmpty)
        for testCase in cases {
            let caseId = testCase["caseId"]?.stringValue ?? "?"
            let input = try Self.input(testCase["input"], caseId)
            let actual = Self.json(StudioPromptComposer.compose(spec, input)).canonicalJSONString
            let expected = (testCase["expect"] ?? .null).canonicalJSONString
            // Scalar-wise comparison: String == would treat canonically equivalent text as equal.
            #expect(actual.unicodeScalars.elementsEqual(expected.unicodeScalars), "\(caseId): got \(actual)")
        }
    }
}
