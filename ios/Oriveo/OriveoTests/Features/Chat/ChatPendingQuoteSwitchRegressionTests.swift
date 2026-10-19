import Foundation
import Testing
@testable import Oriveo

/// Regression: when switching conversation A -> B on a wide screen, the ChatDetailColumn branch is unchanged and ChatView has no .id, so @State is kept,
/// and the previous conversation's pending quote would carry into the new one. It is cleared when the conversation id changes; a draft that is sent and promoted to a conversation (nil -> id) is the same draft and is not cleared.
@Suite("Pending quote cleared on conversation switch")
struct ChatPendingQuoteSwitchRegressionTests {

    @Test func pending_quote_cleared_on_conversation_switch() {
        let a = UUID()
        let b = UUID()

        // Conversation A -> conversation B: clear.
        #expect(ChatPendingQuoteReset.shouldClear(from: a, to: b))
        // Conversation -> draft: clear.
        #expect(ChatPendingQuoteReset.shouldClear(from: a, to: nil))
        // Draft sent and promoted to a conversation: the same draft, do not clear.
        #expect(!ChatPendingQuoteReset.shouldClear(from: nil, to: a))
        // Id unchanged: do not clear.
        #expect(!ChatPendingQuoteReset.shouldClear(from: a, to: a))
        #expect(!ChatPendingQuoteReset.shouldClear(from: nil, to: nil))
    }
}
