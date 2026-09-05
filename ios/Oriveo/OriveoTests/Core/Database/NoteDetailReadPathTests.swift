import Foundation
import GRDB
import Testing
@testable import Oriveo

@Suite("NoteDetailReadPath", .serialized)
struct NoteDetailReadPathTests {

    @Test("Async Detail Matches Sync Detail")
    func asyncDetailMatchesSyncDetail() async throws {
        let harness = try NoteStoreHarness()
        defer { harness.cleanup() }

        let note = NoteTestFactories.makeNote(
            title: "Detail",
            body: String(repeating: "x", count: 50_000),
            bodySnapshot: "snapshot"
        )
        try harness.store.upsertNote(note)

        let fetchedSync = try harness.store.fetchNote(id: note.id)
        let fetchedAsync = try await harness.store.fetchNoteAsync(id: note.id)
        let synchronous = try #require(fetchedSync)
        let asynchronous = try #require(fetchedAsync)
        #expect(asynchronous.id == synchronous.id)
        #expect(asynchronous.body == synchronous.body)
        #expect(asynchronous.bodySnapshot == synchronous.bodySnapshot)
        #expect(asynchronous.title == synchronous.title)

        let missing = try await harness.store.fetchNoteAsync(id: UUID())
        #expect(missing == nil)
    }
}

@Suite("NoteReadingMarkdownCollapse")
struct NoteReadingMarkdownCollapseTests {

    @Test("Collapses Blank Lines Identically")
    func collapsesBlankLinesIdentically() {
        let cases = [
            "a\n\n\nb",
            "a\n\n\n\n\n\nb",
            "a\n\nb",
            "a\nb",
            "\n\n\n\na\n\n\n\nb\n\n\n\n",
            "a\n\n\nb\n\n\n\nc\n\nd"
        ]
        for input in cases {
            #expect(NoteText.readingMarkdown(input) == Self.legacyReadingMarkdown(input), "input: \(input.debugDescription)")
        }
    }

    @Test("Strips Standalone Rules")
    func stripsStandaloneRules() {
        let input = "one\n\n---\n\ntwo\n***\nthree"
        let output = NoteText.readingMarkdown(input)
        #expect(output.contains("---") == false)
        #expect(output.contains("***") == false)
        #expect(output.contains("one"))
        #expect(output.contains("two"))
        #expect(output.contains("three"))
        #expect(output == Self.legacyReadingMarkdown(input))
    }

    private static func legacyReadingMarkdown(_ text: String) -> String {
        let kept = text.components(separatedBy: "\n").filter { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.count >= 3, let first = t.first else { return true }
            return !(t.allSatisfy { $0 == first } && (first == "-" || first == "*" || first == "_"))
        }
        var result = kept.joined(separator: "\n")
        while result.contains("\n\n\n") {
            result = result.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
