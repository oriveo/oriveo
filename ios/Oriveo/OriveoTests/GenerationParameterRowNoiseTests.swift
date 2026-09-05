import Foundation
import Testing
@testable import Oriveo

@Suite("Generation Parameter Row Noise Tests")
struct GenerationParameterRowNoiseTests {
    @Test("Only The Normal State Is Silent")
    func onlyTheNormalStateIsSilent() throws {
        let source = try Self.sheetSource()

        #expect(source.contains("if let status = statusNote(parameter) {"))
        #expect(!source.contains("Text(statusText(parameter))"))

        for silent in ["supported", "accepted"] {
            #expect(
                GenerationParameterRowStatus.note(support: silent, source: "authoritative_metadata") == nil,
                "\(silent) started speaking on every row again"
            )
        }

        var seen = Set<String>()
        for support in [
            "accepted_unverified", "fixed", "unsupported",
            "mode_dependent", "unknown", "future_supported",
        ] {
            let note = try #require(
                GenerationParameterRowStatus.note(support: support, source: nil),
                "non-normal \(support) went silent"
            )
            #expect(seen.insert(note).inserted)
        }

        let withSource = try #require(
            GenerationParameterRowStatus.note(support: "unknown", source: "relay_declared")
        )
        #expect(
            withSource.contains(GenerationParameterVocabulary.source("relay_declared")),
            "Source attribution chain was removed"
        )
    }

    @Test("Title And Accessibility Label Share One Source")
    func titleAndAccessibilityLabelShareOneSource() throws {
        let source = try Self.sheetSource()
        #expect(source.contains("Text(parameterTitle(id))"))
        #expect(
            !source.contains("Text(id.replacingOccurrences(of: \"_\", with: \" \"))"),
            "The row title inlined its own formatting and diverged from the accessibility label"
        )
    }

    @Test("Wire Identifiers Use Localized Vocabulary")
    func wireIdentifiersUseLocalizedVocabulary() {
        let cases: [(String, String)] = [
            ("max_output_tokens", "Max Tokens"),
            ("reasoning_effort", "Reasoning effort"),
            ("top_p", "Top P"),
            ("frequency_penalty", "Frequency penalty"),
            ("json_schema", "JSON Schema"),
        ]
        for (id, expected) in cases {
            let title = GenerationParameterVocabulary.title(id)
            #expect(title == L10n.tr(expected, table: .chat))
            #expect(title != id)
            #expect(!title.contains("_"))
        }
        #expect(
            GenerationParameterVocabulary.title("future_wire_id")
                == L10n.tr("Advanced parameter", table: .chat)
        )
        #expect(
            GenerationParameterVocabulary.source("authoritative_metadata")
                == L10n.tr("Official configuration", table: .chat)
        )
        #expect(
            GenerationParameterVocabulary.source("future_source")
                == L10n.tr("Other source", table: .chat)
        )
    }

    private static func sheetSource() throws -> String {
        var current = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let components = [
            "ios", "Oriveo", "Oriveo", "Features", "Providers",
            "GenerationParameterDefaultsSheet.swift",
        ]
        while current.path != current.deletingLastPathComponent().path {
            let candidate = components.reduce(current) { $0.appendingPathComponent($1) }
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try String(contentsOf: candidate, encoding: .utf8)
            }
            current = current.deletingLastPathComponent()
        }
        fatalError("source not found")
    }
}
