import Foundation
import Testing
@testable import Oriveo

@Suite("NoteModels", .serialized)
struct NoteModelsTests {

    @Test("Title Source Closed Set")
    func titleSourceClosedSet() {
        #expect(NoteTitleSource(rawValue: "placeholder") == .placeholder)
        #expect(NoteTitleSource(rawValue: "manual") == .manual)
        #expect(NoteTitleSource(rawValue: "ai") == nil)
    }

    @Test("Capture Kind Unknown Degrades")
    func captureKindUnknownDegrades() {
        #expect(NoteCaptureKind.decoded("fullAnswer") == .fullAnswer)
        #expect(NoteCaptureKind.decoded("selection") == .selection)
        #expect(NoteCaptureKind.decoded("userMessage") == .userMessage)
        #expect(NoteCaptureKind.decoded("blank") == .blank)
        #expect(NoteCaptureKind.decoded("brandNewKind") == .blank)
        #expect(NoteCaptureKind.decoded(nil) == .blank)
    }

    @Test("Provenance Kind Raw Values")
    func provenanceKindRawValues() {
        #expect(ProvenanceKind.origin.rawValue == "origin")
        #expect(ProvenanceKind.crosscheck.rawValue == "crosscheck")
        #expect(ProvenanceKind.digest.rawValue == "digest")
        #expect(ProvenanceKind.transform.rawValue == "transform")
    }

    @Test("Uuid Uppercase")
    func uuidUppercase() {
        let id = UUID()
        #expect(id.uuidString == id.uuidString.uppercased())
        let lower = id.uuidString.lowercased()
        #expect(UUID(uuidString: lower) == id)
    }

    @Test("Empty Tags Stay Array")
    func emptyTagsStayArray() {
        #expect(RecordMappers.decodeTags("[]") == [])
        #expect(RecordMappers.decodeTags(nil) == [])
        #expect(RecordMappers.encodeTags([]) == "[]")
        #expect(RecordMappers.decodeTags(RecordMappers.encodeTags(["a", "b"])) == ["a", "b"])
    }

    @Test("Provenance Codec")
    func provenanceCodec() {
        #expect(RecordMappers.encodeProvenance(nil) == nil)
        #expect(RecordMappers.encodeProvenance([]) == nil)
        let entries = [
            ProvenanceEntry(kind: .origin, modelID: "gpt-4", modelName: "GPT-4",
                            providerKind: .openAI, providerName: "OpenAI",
                            conversationId: UUID(), messageId: UUID(),
                            at: Date(timeIntervalSince1970: 1_700_000_000)),
            ProvenanceEntry(kind: .crosscheck, modelID: "claude", modelName: "Claude",
                            providerKind: .anthropic, providerName: "Anthropic",
                            conversationId: nil, messageId: nil,
                            at: Date(timeIntervalSince1970: 1_700_000_100))
        ]
        let json = RecordMappers.encodeProvenance(entries)
        #expect(json != nil)
        let decoded = RecordMappers.decodeProvenance(json)
        #expect(decoded?.count == 2)
        #expect(decoded?.first?.kind == .origin)
        #expect(decoded?.last?.kind == .crosscheck)
        #expect(decoded?.first?.providerKind == .openAI)
    }

    @Test("Placeholder Title Prefers Prompt")
    func placeholderTitlePrefersPrompt() {
        let t = NoteManager.placeholderTitle(fromPrompt: "How do I deploy?\nmore", body: "The answer is...")
        #expect(t == "How do I deploy?")
        let fromBody = NoteManager.placeholderTitle(fromPrompt: nil, body: "First body line\nsecond")
        #expect(fromBody == "First body line")
    }

    @Test("Placeholder Title Strips Structure")
    func placeholderTitleStripsStructure() {
        #expect(NoteManager.placeholderTitle(fromPrompt: nil, body: "# Heading title") == "Heading title")
        #expect(NoteManager.placeholderTitle(fromPrompt: nil, body: "> quoted line") == "quoted line")
        #expect(NoteManager.placeholderTitle(fromPrompt: nil, body: "- bullet item") == "bullet item")
        #expect(NoteManager.placeholderTitle(fromPrompt: nil, body: "1. ordered item") == "ordered item")
        #expect(NoteManager.placeholderTitle(fromPrompt: nil, body: "```swift\nlet x = 1") == "let x = 1")
        #expect(NoteManager.placeholderTitle(fromPrompt: nil, body: "| --- | --- |\nReal title") == "Real title")
        #expect(NoteManager.placeholderTitle(fromPrompt: nil, body: "**bold** word") == "bold word")
    }

    @Test("Placeholder Title Empty And Truncation")
    func placeholderTitleEmptyAndTruncation() {
        #expect(NoteManager.placeholderTitle(fromPrompt: nil, body: "") == "")
        #expect(NoteManager.placeholderTitle(fromPrompt: "   ", body: "\n\n") == "")
        let long = String(repeating: "a", count: 500)
        #expect(NoteManager.placeholderTitle(fromPrompt: nil, body: long).count == 200)
    }

    @Test("Summary Badge Gating")
    func summaryBadgeGating() {
        let blank = NoteSummary(NoteTestFactories.makeNote(captureKind: .blank))
        #expect(blank.showsSourceBadge == false)
        let sourced = NoteSummary(NoteTestFactories.makeNote(
            sourceModelName: "GPT-4", sourceProviderKind: .openAI, captureKind: .fullAnswer))
        #expect(sourced.showsSourceBadge == true)
    }
}
