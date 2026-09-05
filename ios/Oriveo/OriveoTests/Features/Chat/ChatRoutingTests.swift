import Foundation
import Testing
@testable import Oriveo

@Suite("Chat routing")
@MainActor
struct ChatRoutingTests {
    @Test("Open Chat Pushes Conversation Route")
    func openChatPushesConversationRoute() {
        let appState = AppState(seedDemoData: true)
        let conversationID = UUID()

        appState.openChat(conversationID: conversationID)

        #expect(appState.navigation.path.last == .chat(conversationID: conversationID))
    }
}
