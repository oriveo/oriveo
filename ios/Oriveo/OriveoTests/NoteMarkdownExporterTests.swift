import Foundation
import Testing
@testable import Oriveo

@Suite("NoteMarkdownExporter", .serialized)
struct NoteMarkdownExporterTests {

    @Test("Full Template")
    func fullTemplate() {
        let note = NoteTestFactories.makeNote(
            title: "My Title", body: "Body content",
            userNote: "remark", tags: ["a", "b"],
            sourceModelName: "GPT-4", sourceProviderName: "OpenAI", sourcePrompt: "What is X?",
            captureKind: .fullAnswer,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        let md = NoteMarkdownExporter.markdown(for: note)
        #expect(md.contains("# My Title"))
        #expect(md.contains("> remark"))
        #expect(md.contains("Tags: a, b"))
        #expect(md.contains("Body content"))
        #expect(md.contains("Source: GPT-4 • OpenAI • 2023-11-14"))
        #expect(md.contains("Prompt: What is X?"))
        #expect(md.hasSuffix("\n"))
    }

    @Test("Blank No Source")
    func blankNoSource() {
        let note = NoteTestFactories.makeNote(title: "Blank", body: "x", captureKind: .blank)
        let md = NoteMarkdownExporter.markdown(for: note)
        #expect(!md.contains("Source:"))
        #expect(!md.contains("Prompt:"))
    }

    @Test("Optional Omit")
    func optionalOmit() {
        let note = NoteTestFactories.makeNote(title: "T", body: "B", userNote: nil, tags: [], captureKind: .blank)
        let md = NoteMarkdownExporter.markdown(for: note)
        #expect(!md.contains(">"))
        #expect(!md.contains("Tags:"))
    }

    @Test("Multiline User Note")
    func multilineUserNote() {
        let note = NoteTestFactories.makeNote(body: "B", userNote: "line1\nline2", captureKind: .blank)
        let md = NoteMarkdownExporter.markdown(for: note)
        #expect(md.contains("> line1\n> line2"))
    }

    @Test("Filename Sanitize")
    func filenameSanitize() {
        let note = NoteTestFactories.makeNote(title: "a/b:c*?\"<>|d", body: "x", captureKind: .blank,
                                              createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        let name = NoteMarkdownExporter.filename(for: note)
        #expect(name.hasSuffix(".md"))
        #expect(!name.contains("/"))
        #expect(!name.contains(":"))
        #expect(name.contains("2023-11-14"))
    }

    @Test("Sanitize Truncate")
    func sanitizeTruncate() {
        let long = String(repeating: "x", count: 200)
        #expect(NoteMarkdownExporter.sanitize(long).count == 80)
    }
}
