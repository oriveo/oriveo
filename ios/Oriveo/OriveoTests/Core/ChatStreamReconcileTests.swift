import Testing
@testable import Oriveo

/// Continuation completion reconcile: Grok drops the leading whitespace from result.text on completion, so the continuation must not be glued onto the existing text.
@Suite("Chat stream reconcile")
struct ChatStreamReconcileTests {

    @Test func continuation_keeps_streamed_leading_space_when_final_text_trimmed() {
        let text = ChatManager.reconciledStreamingText(
            baseline: "The quick brown",
            current: "The quick brown fox jumps",
            fullText: "fox jumps"
        )
        #expect(text == "The quick brown fox jumps")
    }

    @Test func final_text_with_own_leading_space_is_used_as_is() {
        let text = ChatManager.reconciledStreamingText(
            baseline: "Hello",
            current: "Hello world",
            fullText: " world"
        )
        #expect(text == "Hello world")
    }

    @Test func diverging_final_text_replaces_streamed_text() {
        let text = ChatManager.reconciledStreamingText(
            baseline: "",
            current: " partial",
            fullText: "Different answer"
        )
        #expect(text == "Different answer")
    }
}
