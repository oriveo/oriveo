import Foundation
import Testing
@testable import Oriveo

@Suite("ChatExport")
struct ChatExportTests {

    @Test("Markdown Layout Aligns Across Platforms")
    func markdownLayoutAlignsAcrossPlatforms() {
        let summary = makeSummary(title: "Hello World", updatedAt: Date(timeIntervalSince1970: 1_700_000_100))
        let messages = [
            TestFactories.makeMessage(role: .user, text: "Hi"),
            TestFactories.makeMessage(role: .assistant, text: "Hello back", providerName: "OpenAI", modelName: "GPT-4o")
        ]

        let md = ChatExport.markdown(summary: summary, messages: messages, timestampFormatter: fixedFormatter())

        let expected = [
            "# Hello World",
            "",
            "*2023-11-14 22:15*",
            "",
            "## User",
            "",
            "Hi",
            "",
            "## Assistant",
            "",
            "Hello back",
            "",
            "*Model: GPT-4o (OpenAI)*",
            ""
        ].joined(separator: "\n")

        #expect(md == expected)
    }

    @Test("Empty Title Falls Back To Untitled")
    func emptyTitleFallsBackToUntitled() {
        let summary = makeSummary(title: "   ")
        let messages = [TestFactories.makeMessage(role: .user, text: "hi")]

        let md = ChatExport.markdown(summary: summary, messages: messages, timestampFormatter: fixedFormatter())

        #expect(md.hasPrefix("# Untitled"))
    }

    @Test("Skips Model Line When Model Name Empty")
    func skipsModelLineWhenModelNameEmpty() {
        let summary = makeSummary(title: "Test")
        let messages = [
            TestFactories.makeMessage(role: .assistant, text: "ok", providerName: "OpenAI", modelName: "")
        ]

        let md = ChatExport.markdown(summary: summary, messages: messages, timestampFormatter: fixedFormatter())

        #expect(!md.contains("*Model:"))
    }

    @Test("Sanitize Filename Strips Invalid Chars And Trims")
    func sanitizeFilenameStripsInvalidCharsAndTrims() {
        let raw = String(repeating: "a", count: 120) + "/?<>:"
        let sanitized = ChatExport.sanitizeFilename(raw)

        let invalid: Set<Character> = ["/", "\\", "?", "%", "*", ":", "|", "\"", "<", ">"]
        #expect(sanitized.count <= 100)
        #expect(sanitized.allSatisfy { !invalid.contains($0) })
    }

    @Test("Sanitize Filename Falls Back When Empty")
    func sanitizeFilenameFallsBackWhenEmpty() {
        #expect(ChatExport.sanitizeFilename("") == "conversation")
        #expect(ChatExport.sanitizeFilename("   ") == "conversation")
    }

    private func fixedFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }

    private func makeSummary(
        title: String,
        updatedAt: Date = Date(timeIntervalSince1970: 1_700_000_100)
    ) -> ConversationSummary {
        ConversationSummary(
            id: UUID(),
            title: title,
            hasCustomTitle: !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            providerID: UUID(),
            providerKind: .openAI,
            modelID: "gpt-4o",
            previewText: "preview",
            messageCount: 0,
            estimatedCost: 0,
            isDraft: false,
            draftText: "",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: updatedAt,
            folderID: nil,
            useMemory: true,
            skillId: nil,
            messagesHydratedAt: nil,
            messagesStale: false
        )
    }
}
