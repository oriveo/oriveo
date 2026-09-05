import Testing
import Foundation
@testable import Oriveo

// MARK: - RelayFamilyHeuristics Contract Test

@Suite("RelayFamilyHeuristics Contract")
struct RelayFamilyHeuristicsTests {

    private struct Fixture {
        let modelID: String
        let expected: RelayModelFamily?
    }

    private static let fixtures: [Fixture] = [
        Fixture(modelID: "gpt-5.4",                expected: .openai),
        Fixture(modelID: "gpt-image-2",            expected: .openai),
        Fixture(modelID: "gpt-4o-mini",            expected: .openai),
        Fixture(modelID: "o3-mini",                expected: .openai),
        Fixture(modelID: "o4",                     expected: .openai),
        Fixture(modelID: "chatgpt-4o-latest",      expected: .openai),
        Fixture(modelID: "dall-e-3",               expected: .openai),
        Fixture(modelID: "whisper-1",              expected: .openai),
        Fixture(modelID: "tts-1-hd",               expected: .openai),
        Fixture(modelID: "text-embedding-3-large", expected: .openai),
        Fixture(modelID: "claude-opus-4",          expected: .anthropic),
        Fixture(modelID: "claude-sonnet-4-5",      expected: .anthropic),
        Fixture(modelID: "claude-haiku-4-5",       expected: .anthropic),
        Fixture(modelID: "gemini-2.5-pro",         expected: .google),
        Fixture(modelID: "gemini-2.0-flash",       expected: .google),
        Fixture(modelID: "imagen-3",               expected: .google),
        Fixture(modelID: "deepseek-v3",            expected: .deepseek),
        Fixture(modelID: "deepseek-r1",            expected: .deepseek),
        Fixture(modelID: "ds-coder-v2",            expected: .deepseek),
        Fixture(modelID: "qwen2.5-72b",            expected: .qwen),
        Fixture(modelID: "qwen3-32b",              expected: .qwen),
        Fixture(modelID: "qwq-32b",                expected: .qwen),
        Fixture(modelID: "grok-3",                 expected: .xai),
        Fixture(modelID: "grok-vision-beta",       expected: .xai),
        Fixture(modelID: "llama-3.3-70b",          expected: .meta),
        Fixture(modelID: "codellama-34b",          expected: .meta),
        Fixture(modelID: "mistral-large",          expected: .mistral),
        Fixture(modelID: "mixtral-8x22b",          expected: .mistral),
        Fixture(modelID: "codestral-22b",          expected: .mistral),
        Fixture(modelID: "my-custom-model",        expected: nil),
        Fixture(modelID: "unknown-xyz-2026",       expected: nil),
        Fixture(modelID: "",                       expected: nil),
    ]

    @Test("Fixtures Match Shared Contract")
    func fixturesMatchSharedContract() {
        for fixture in Self.fixtures {
            let actual = RelayFamilyHeuristics.infer(modelID: fixture.modelID)
            #expect(
                actual == fixture.expected,
                "modelID=\(fixture.modelID.isEmpty ? "<empty>" : fixture.modelID) expected=\(String(describing: fixture.expected)) actual=\(String(describing: actual))"
            )
        }
    }

    @Test("Case And Whitespace Insensitive")
    func caseAndWhitespaceInsensitive() {
        #expect(RelayFamilyHeuristics.infer(modelID: "  GPT-4o  ") == .openai)
        #expect(RelayFamilyHeuristics.infer(modelID: "CLAUDE-OPUS-4") == .anthropic)
    }

    @Test("Nil Input Returns Nil")
    func nilInputReturnsNil() {
        #expect(RelayFamilyHeuristics.infer(modelID: nil) == nil)
    }

    @Test("O5 Not Matched")
    func o5NotMatched() {
        #expect(RelayFamilyHeuristics.infer(modelID: "o5-mini") == nil)
    }
}
