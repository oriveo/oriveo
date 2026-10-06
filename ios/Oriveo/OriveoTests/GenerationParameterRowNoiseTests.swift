import Foundation
import Testing
@testable import Oriveo

@Suite("Generation Parameter Row Noise Tests")
struct GenerationParameterRowNoiseTests {
    @Test("Only The Normal State Is Silent")
    func onlyTheNormalStateIsSilent() throws {
        let source = try Self.source(named: "AdvancedParameterRowView.swift")
        let catalog = try Self.source(named: "AdvancedSettingsCatalog.swift")

        // Rendering has to go through the optional statusNote and must not spread the full status over every row;
        // a collapsed editable row carries not even the non-regular note, which waits for the expanded state.
        #expect(catalog.contains("statusNote: GenerationParameterRowStatus.note("))
        #expect(source.contains("if let statusNote, !isEditable {"))
        #expect(source.contains("if let statusNote {"))
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
        // The row model's title has a single source (the vocabulary); the on-screen title and the accessibility label both take it.
        let model = try Self.source(named: "AdvancedSettingsModel.swift")
        #expect(model.contains("title: GenerationParameterVocabulary.title(id),"))
        let source = try Self.source(named: "AdvancedParameterRowView.swift")
        #expect(source.contains("Text(row.model.title)"))
        #expect(source.contains(".accessibilityLabel(Text(row.model.title))"))
        #expect(
            !source.contains("replacingOccurrences(of: \"_\", with: \" \")"),
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

    /// Rendering and assembly of parameter rows live in these files, shared by the chat page and the provider detail page.
    private static func source(named name: String) throws -> String {
        var current = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let components = [
            "ios", "Oriveo", "Oriveo", "Features", "Chat", "ModelControls", name,
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
