import Foundation
import Testing
@testable import Oriveo

@Suite("Chat Outline Tests")
struct ChatOutlineTests {

    private func message(_ role: ChatRole, _ text: String, attachments: [Oriveo.Attachment]? = nil) -> ChatMessage {
        ChatMessage(
            id: UUID(),
            role: role,
            text: text,
            providerKind: .relay,
            providerName: "Relay",
            modelName: "gpt-5.4",
            state: .delivered,
            attachments: attachments
        )
    }

    @Test("Preview First Line Collapsed")
    func previewFirstLineCollapsed() {
        let m = message(.user, "  hello   world  \nsecond line")
        #expect(ChatOutline.preview(of: m, attachmentLabel: "(att)") == "hello world")
        #expect(ChatOutline.preview(of: message(.user, "a\t\tb"), attachmentLabel: "(att)") == "a b")
    }

    @Test("Preview Empty Falls Back")
    func previewEmptyFallsBack() {
        #expect(ChatOutline.preview(of: message(.user, "   "), attachmentLabel: "(att)") == "(att)")
        let att = Oriveo.Attachment(id: UUID(), kind: .image, fileName: "x.png", mimeType: "image/png")
        #expect(ChatOutline.preview(of: message(.user, "", attachments: [att]), attachmentLabel: "(att)") == "(att)")
    }

    @Test("Ticks User Only")
    func ticksUserOnly() {
        let u1 = message(.user, "first")
        let a1 = message(.assistant, "answer")
        let u2 = message(.user, "second")
        let ticks = ChatOutline.ticks(from: [u1, a1, u2], attachmentLabel: "(att)")
        #expect(ticks.map(\.id) == [u1.id, u2.id])
        #expect(ticks.map(\.preview) == ["first", "second"])
    }

    @Test("Active Tick Clamps To Conversation Edges")
    func activeTickClampsToConversationEdges() {
        let first = UUID()
        let middle = UUID()
        let last = UUID()

        #expect(ChatOutline.resolvedActiveID(
            firstID: first, lastID: last, focusID: middle,
            atConversationStart: false, atConversationEnd: true
        ) == last)
        #expect(ChatOutline.resolvedActiveID(
            firstID: first, lastID: last, focusID: middle,
            atConversationStart: true, atConversationEnd: false
        ) == first)
        #expect(ChatOutline.resolvedActiveID(
            firstID: first, lastID: last, focusID: middle,
            atConversationStart: true, atConversationEnd: true
        ) == last)
        #expect(ChatOutline.resolvedActiveID(
            firstID: first, lastID: last, focusID: middle,
            atConversationStart: false, atConversationEnd: false
        ) == middle)
    }

    @Test("Clamp Truncates")
    func clampTruncates() {
        #expect(ChatOutline.clampPreview("short", maxChars: 10) == "short")
        #expect(ChatOutline.clampPreview("abcdefghij", maxChars: 4) == "abcd…")
        #expect(ChatOutline.clampPreview("あいうえおか", maxChars: 4) == "あいうえ…")
    }

    @Test("Visible Range Matrix")
    func visibleRangeMatrix() {
        #expect(ChatOutline.visibleRange(totalCount: 10, currentIndex: 3, capacity: 54) == 0..<10)
        #expect(ChatOutline.visibleRange(totalCount: 54, currentIndex: 0, capacity: 54) == 0..<54)
        #expect(ChatOutline.visibleRange(totalCount: 100, currentIndex: 99, capacity: 54) == 46..<100)
        #expect(ChatOutline.visibleRange(totalCount: 100, currentIndex: 46, capacity: 54) == 46..<100)
        #expect(ChatOutline.visibleRange(totalCount: 100, currentIndex: 45, capacity: 54) == 0..<46)
        #expect(ChatOutline.visibleRange(totalCount: 100, currentIndex: 5, capacity: 54) == 0..<46)
        #expect(ChatOutline.visibleRange(totalCount: 57, currentIndex: 56, capacity: 54) == 3..<57)
        #expect(ChatOutline.visibleRange(totalCount: 57, currentIndex: 2, capacity: 54) == 0..<3)
        #expect(ChatOutline.visibleRange(totalCount: 100, currentIndex: -1, capacity: 54) == 46..<100)
        #expect(ChatOutline.visibleRange(totalCount: 100, currentIndex: 200, capacity: 54) == 46..<100)
        #expect(ChatOutline.visibleRange(totalCount: 108, currentIndex: 107, capacity: 54) == 54..<108)
        #expect(ChatOutline.visibleRange(totalCount: 108, currentIndex: 53, capacity: 54) == 0..<54)
        #expect(ChatOutline.visibleRange(totalCount: 10, currentIndex: 3, capacity: 0) == 0..<10)
        #expect(ChatOutline.visibleRange(totalCount: 0, currentIndex: -1, capacity: 54) == 0..<0)
    }
}
