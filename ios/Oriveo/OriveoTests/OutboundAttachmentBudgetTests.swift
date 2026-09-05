import Testing
import Foundation
@testable import Oriveo

@Suite("OutboundAttachmentBudget")
struct OutboundAttachmentBudgetTests {

    private static let oneMB = 1024 * 1024

    private static func image(_ name: String, localImageID: String = "img") -> Oriveo.Attachment {
        Oriveo.Attachment(
            id: UUID(),
            kind: .image,
            fileName: "\(name).jpg",
            mimeType: "image/jpeg",
            localImageID: localImageID
        )
    }

    private static func pdf(
        _ name: String,
        extracted: String? = "ZXh0cmFjdGVk",
        original: String? = String(repeating: "A", count: 4 * oneMB)
    ) -> Oriveo.Attachment {
        Oriveo.Attachment(
            id: UUID(),
            kind: .file,
            fileName: "\(name).pdf",
            mimeType: "application/pdf",
            base64Data: extracted,
            originalBase64Data: original
        )
    }

    private static func message(
        _ role: Oriveo.ChatRole,
        _ text: String,
        _ attachments: [Oriveo.Attachment]? = nil
    ) -> Oriveo.ChatMessage {
        var msg = ChatMessage(
            id: UUID(),
            role: role,
            text: text,
            providerKind: .openAI,
            providerName: "OpenAI",
            modelName: "gpt-test",
            state: .delivered
        )
        msg.attachments = attachments
        return msg
    }

    @Test("Passes Through Without Attachments")
    func passesThroughWithoutAttachments() {
        let messages = [Self.message(.user, "hi"), Self.message(.assistant, "hello")]

        let out = OutboundAttachmentBudget.apply(to: messages, budgetBytes: 0, imageRawSizeOf: { _ in 0 })

        #expect(out.count == 2)
        #expect(out.allSatisfy { $0.attachments == nil })
    }

    @Test("Current Turn Is Exempt")
    func currentTurnIsExempt() {
        let messages = [Self.message(.user, "look at this", [Self.image("a")])]

        let out = OutboundAttachmentBudget.apply(
            to: messages, budgetBytes: 1, imageRawSizeOf: { _ in 25 * Self.oneMB }
        )

        #expect(out[0].attachments?.count == 1)
        #expect(out[0].text == "look at this")
    }

    @Test("Old Images Become Placeholders")
    func oldImagesBecomePlaceholders() {
        let messages = [
            Self.message(.user, "first", [Self.image("old")]),
            Self.message(.assistant, "ok"),
            Self.message(.user, "second", [Self.image("recent")]),
            Self.message(.assistant, "ok"),
            Self.message(.user, "third"),
        ]

        let out = OutboundAttachmentBudget.apply(
            to: messages, budgetBytes: 5 * Self.oneMB, imageRawSizeOf: { _ in 3 * Self.oneMB }
        )

        #expect(out[2].attachments?.count == 1)
        #expect(out[0].attachments == nil)
        #expect(out[0].text.hasPrefix("first"))
        #expect(out[0].text.contains("[Image omitted: old.jpg"))
    }

    @Test("Old Files Keep Extracted Text")
    func oldFilesKeepExtractedText() {
        let messages = [
            Self.message(.user, "read this", [Self.pdf("report")]),
            Self.message(.assistant, "ok"),
            Self.message(.user, "and now?"),
        ]

        let out = OutboundAttachmentBudget.apply(to: messages, budgetBytes: 0, imageRawSizeOf: { _ in 0 })

        let kept = try! #require(out[0].attachments?.first)
        #expect(kept.base64Data == "ZXh0cmFjdGVk")
        #expect(kept.originalBase64Data == nil)
        #expect(out[0].text == "read this")
    }

    @Test("Old Files Without Text Are Dropped")
    func oldFilesWithoutTextAreDropped() {
        let messages = [
            Self.message(.user, "binary", [Self.pdf("scan", extracted: nil)]),
            Self.message(.assistant, "ok"),
            Self.message(.user, "next"),
        ]

        let out = OutboundAttachmentBudget.apply(to: messages, budgetBytes: 0, imageRawSizeOf: { _ in 0 })

        #expect(out[0].attachments == nil)
        #expect(out[0].text.contains("[File omitted: scan.pdf"))
    }

    @Test("Empty String Marker Is Not Usable Text")
    func emptyStringMarkerIsNotUsableText() {
        let messages = [
            Self.message(.user, "scanned", [Self.pdf("scanned", extracted: "")]),
            Self.message(.assistant, "ok"),
            Self.message(.user, "next"),
        ]

        let out = OutboundAttachmentBudget.apply(to: messages, budgetBytes: 0, imageRawSizeOf: { _ in 0 })

        #expect(out[0].attachments == nil)
        #expect(out[0].text.contains("[File omitted: scanned.pdf"))
    }

    @Test("Image Only Message Keeps Placeholder As Text")
    func imageOnlyMessageKeepsPlaceholderAsText() {
        let messages = [
            Self.message(.user, "", [Self.image("lonely")]),
            Self.message(.assistant, "ok"),
            Self.message(.user, "follow up"),
        ]

        let out = OutboundAttachmentBudget.apply(
            to: messages, budgetBytes: 0, imageRawSizeOf: { _ in Self.oneMB }
        )

        #expect(out[0].attachments == nil)
        #expect(out[0].text.contains("[Image omitted: lonely.jpg"))
    }

    @Test("Inlined Image Does Not Probe Disk")
    func inlinedImageDoesNotProbeDisk() {
        var inlined = Self.image("cached")
        inlined.base64Data = "AAAA"
        let messages = [
            Self.message(.user, "older", [inlined]),
            Self.message(.assistant, "ok"),
            Self.message(.user, "newer"),
        ]

        let out = OutboundAttachmentBudget.apply(to: messages, budgetBytes: 1024) { _ in
            Issue.record("An already-inlined base64 image should not be measured on disk again")
            return 25 * Self.oneMB
        }

        #expect(out[0].attachments?.count == 1)
    }

    @Test("Budget Matches Android")
    func budgetMatchesAndroid() {
        #expect(OutboundAttachmentBudget.defaultBudgetBytes == 10 * 1024 * 1024)
    }
}
