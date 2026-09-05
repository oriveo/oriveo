import Foundation
import Testing
@testable import Oriveo

@Suite("NoteCaptureBuilder", .serialized)
struct NoteCaptureBuilderTests {

    private func msg(role: ChatRole = .assistant, text: String = "answer text") -> ChatMessage {
        ChatMessage(id: UUID(), role: role, text: text,
                    providerKind: .openAI, providerName: "OpenAI",
                    modelID: "gpt-4", modelName: "GPT-4",
                    estimatedCost: 0, state: .delivered)
    }

    private let convID = UUID()

    @Test("Full Answer")
    func fullAnswer() {
        let m = msg(text: "the full answer")
        let draft = NoteCaptureBuilder.fullAnswer(message: m, conversationID: convID, prompt: "Q?")
        #expect(draft.captureKind == .fullAnswer)
        #expect(draft.body == "the full answer")
        #expect(draft.bodySnapshot == "the full answer")
        #expect(draft.sourcePrompt == "Q?")
        #expect(draft.sourceModelName == "GPT-4")
        #expect(draft.sourceProviderKind == .openAI)
        #expect(draft.sourceMessageId == m.id)
        #expect(draft.sourceConversationId == convID)
    }

    @Test("Selection")
    func selection() {
        let m = msg(text: "full original answer with more")
        let draft = NoteCaptureBuilder.selection(text: "a passage", message: m, conversationID: convID, prompt: "Q?")
        #expect(draft.captureKind == .selection)
        #expect(draft.body == "a passage")
        #expect(draft.bodySnapshot == "full original answer with more")
    }

    @Test("Selection Block Math Structure")
    func selectionBlockMathStructure() {
        let source = "Intro paragraph here.\n\n$$\ntan(30) = \\frac{height}{100}\n$$\n\nOutro paragraph."
        let m = msg(text: source)
        let draft = NoteCaptureBuilder.selection(
            text: "$$tan(30) = \\frac{height}{100}$$",
            message: m, conversationID: convID, prompt: nil
        )
        #expect(draft.body.contains("$$"))
        #expect(draft.body.contains("\\frac{height}{100}"))
    }

    @Test("Selection Inline Math Structure")
    func selectionInlineMathStructure() {
        let source = "The value $x_1$ matters in physics today.\n\nAnother paragraph."
        let m = msg(text: source)
        let draft = NoteCaptureBuilder.selection(
            text: "value $x_1$ matters in physics",
            message: m, conversationID: convID, prompt: nil
        )
        #expect(draft.body == "The value $x_1$ matters in physics today.")
    }

    @Test("Code Block")
    func codeBlock() {
        let m = msg(text: "here is code")
        let draft = NoteCaptureBuilder.codeBlock(code: "let x = 1", language: "swift", message: m, conversationID: convID, prompt: nil)
        #expect(draft.captureKind == .selection)
        #expect(draft.body == "```swift\nlet x = 1\n```")
        #expect(draft.bodySnapshot == "here is code")
    }

    @Test("User Message")
    func userMessage() {
        let m = msg(role: .user, text: "my question text")
        let draft = NoteCaptureBuilder.userMessage(message: m, conversationID: convID)
        #expect(draft.captureKind == .userMessage)
        #expect(draft.body == "my question text")
        #expect(draft.sourcePrompt == "my question text")
    }

    @Test("Blank")
    func blank() {
        let draft = NoteCaptureBuilder.blank()
        #expect(draft.captureKind == .blank)
        #expect(draft.body == "")
        #expect(draft.sourceMessageId == nil)
        #expect(draft.sourceModelName == nil)
        #expect(draft.bodySnapshot == nil)
    }
}

@Suite("NoteSourceResolver", .serialized)
struct NoteSourceResolverTests {

    private func m(_ role: ChatRole, _ text: String) -> ChatMessage {
        ChatMessage(id: UUID(), role: role, text: text, providerKind: .openAI, providerName: "OpenAI",
                    modelName: "GPT-4", estimatedCost: 0, state: .delivered)
    }

    @Test("Previous User Prompt")
    func previousUserPrompt() {
        let u1 = m(.user, "first question")
        let a1 = m(.assistant, "first answer")
        let u2 = m(.user, "second question")
        let a2 = m(.assistant, "second answer")
        let messages = [u1, a1, u2, a2]
        #expect(NoteSourceResolver.previousUserPrompt(before: a2.id, in: messages) == "second question")
        #expect(NoteSourceResolver.previousUserPrompt(before: a1.id, in: messages) == "first question")
    }

    @Test("Skips Empty User")
    func skipsEmptyUser() {
        let u1 = m(.user, "real question")
        let uEmpty = m(.user, "   ")
        let a1 = m(.assistant, "answer")
        let messages = [u1, uEmpty, a1]
        #expect(NoteSourceResolver.previousUserPrompt(before: a1.id, in: messages) == "real question")
    }

    @Test("No Prompt")
    func noPrompt() {
        let a1 = m(.assistant, "answer with no question")
        #expect(NoteSourceResolver.previousUserPrompt(before: a1.id, in: [a1]) == nil)
    }
}
