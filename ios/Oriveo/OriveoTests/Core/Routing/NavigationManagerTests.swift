import Foundation
import Testing
@testable import Oriveo

@Suite("NavigationManager")
@MainActor
struct NavigationManagerTests {

    @Test("Attempt Navigate Pushes Route")
    func attemptNavigatePushesRoute() {
        let nav = NavigationManager()
        nav.attemptNavigate(to: .chat(conversationID: UUID()))
        #expect(nav.path.count == 1)
    }

    @Test("Multiple Attempts Accumulate")
    func multipleAttemptsAccumulate() {
        let nav = NavigationManager()
        nav.attemptNavigate(to: .chat(conversationID: UUID()))
        nav.attemptNavigate(to: .skillEdit(nil))
        nav.attemptNavigate(to: .backup)
        #expect(nav.path.count == 3)
    }

    @Test("Pop Removes Top")
    func popRemovesTop() {
        let nav = NavigationManager()
        nav.attemptNavigate(to: .memory)
        nav.attemptNavigate(to: .backup)
        nav.pop()
        #expect(nav.path.count == 1)
    }

    @Test("Pop To Root Clears Stack")
    func popToRootClearsStack() {
        let nav = NavigationManager()
        nav.attemptNavigate(to: .memory)
        nav.attemptNavigate(to: .backup)
        nav.attemptNavigate(to: .skillsList)
        nav.popToRoot()
        #expect(nav.path.isEmpty)
    }

    @Test("Replace Last Swaps Top")
    func replaceLastSwapsTop() {
        let nav = NavigationManager()
        nav.attemptNavigate(to: .memory)
        nav.replaceLast(with: .backup)
        #expect(nav.path.count == 1)
        if case .backup = nav.path.first {
            // ok
        } else {
            #expect(Bool(false))
        }
    }

    @Test("Replace Last On Empty Appends")
    func replaceLastOnEmptyAppends() {
        let nav = NavigationManager()
        nav.replaceLast(with: .backup)
        #expect(nav.path.count == 1)
    }

    // MARK: - ChatDetailState

    @Test("Chat Detail Starts Empty")
    func chatDetailStartsEmpty() {
        let nav = NavigationManager()
        #expect(nav.chatDetail == .empty)
        #expect(nav.chatDetail.isEmpty)
        #expect(nav.chatDetail.conversationID == nil)
    }

    @Test("Draft Is Not Empty")
    func draftIsNotEmpty() {
        #expect(ChatDetailState.draft != ChatDetailState.empty)
        #expect(ChatDetailState.draft.isEmpty == false)
        // A draft is new and unsaved, so it has no conversation id either — which is exactly
        // why these two states cannot be expressed as one `UUID?`.
        #expect(ChatDetailState.draft.conversationID == nil)
    }

    @Test("Conversation Carries ID")
    func conversationCarriesID() {
        let first = UUID()
        let second = UUID()
        #expect(ChatDetailState.conversation(first).conversationID == first)
        #expect(ChatDetailState.conversation(first) != ChatDetailState.conversation(second))
        #expect(ChatDetailState.conversation(first).isEmpty == false)
    }

    // MARK: - One carrier at a time: compact uses the path, regular uses chatDetail

    @Test("Present Chat Uses Path When Compact")
    func presentChatUsesPathWhenCompact() {
        let nav = NavigationManager()
        let id = UUID()
        nav.presentChat(conversationID: id)
        #expect(nav.path == [.chat(conversationID: id)])
        #expect(nav.chatDetail == .empty)
        #expect(nav.isShowingChat)
    }

    @Test("Present Chat Replaces Top When Already In Chat")
    func presentChatReplacesTopWhenAlreadyInChat() {
        let nav = NavigationManager()
        nav.presentChat(conversationID: UUID())
        let second = UUID()
        nav.presentChat(conversationID: second)
        #expect(nav.path == [.chat(conversationID: second)])
    }

    @Test("Present Chat Uses Detail When Regular")
    func presentChatUsesDetailWhenRegular() {
        let nav = NavigationManager()
        nav.updateLayoutWidth(isRegular: true)
        let id = UUID()
        nav.presentChat(conversationID: id)
        #expect(nav.chatDetail == .conversation(id))
        #expect(nav.path.isEmpty)
        #expect(nav.isShowingChat)
    }

    @Test("Present Chat Nil Becomes Draft When Regular")
    func presentChatNilBecomesDraftWhenRegular() {
        let nav = NavigationManager()
        nav.updateLayoutWidth(isRegular: true)
        nav.presentChat(conversationID: nil)
        #expect(nav.chatDetail == .draft)
        #expect(nav.isShowingChat)
    }

    @Test("Expanding Moves Chat From Path To Detail")
    func expandingMovesChatFromPathToDetail() {
        let nav = NavigationManager()
        let id = UUID()
        nav.attemptNavigate(to: .notesList)
        nav.presentChat(conversationID: id)

        nav.updateLayoutWidth(isRegular: true)

        #expect(nav.path == [.notesList])
        #expect(nav.chatDetail == .conversation(id))
    }

    @Test("Collapsing Moves Chat From Detail To Path")
    func collapsingMovesChatFromDetailToPath() {
        let nav = NavigationManager()
        nav.updateLayoutWidth(isRegular: true)
        let id = UUID()
        nav.presentChat(conversationID: id)

        nav.updateLayoutWidth(isRegular: false)

        #expect(nav.chatDetail == .empty)
        #expect(nav.path == [.chat(conversationID: id)])
    }

    @Test("Draft Survives A Fold Round Trip")
    func draftSurvivesFoldRoundTrip() {
        let nav = NavigationManager()
        nav.updateLayoutWidth(isRegular: true)
        nav.presentChat(conversationID: nil)

        nav.updateLayoutWidth(isRegular: false)
        #expect(nav.path == [.chat(conversationID: nil)])

        nav.updateLayoutWidth(isRegular: true)
        #expect(nav.chatDetail == .draft)
        #expect(nav.path.isEmpty)
    }

    @Test("Layout Change Is A No-op Without A Conversation")
    func layoutChangeIsNoOpWithoutChat() {
        let nav = NavigationManager()
        nav.attemptNavigate(to: .backup)

        nav.updateLayoutWidth(isRegular: true)
        #expect(nav.path == [.backup])
        #expect(nav.chatDetail == .empty)

        nav.updateLayoutWidth(isRegular: false)
        #expect(nav.path == [.backup])
        #expect(nav.chatDetail == .empty)
    }

    @Test("Repeated Same Width Does Not Migrate")
    func repeatedSameWidthDoesNotMigrate() {
        let nav = NavigationManager()
        let id = UUID()
        nav.presentChat(conversationID: id)

        nav.updateLayoutWidth(isRegular: false)

        #expect(nav.path == [.chat(conversationID: id)])
        #expect(nav.chatDetail == .empty)
    }

    @Test("Dismiss Chat Clears The Active Carrier")
    func dismissChatClearsActiveCarrier() {
        let compact = NavigationManager()
        let id = UUID()
        compact.presentChat(conversationID: id)
        compact.dismissChat()
        #expect(compact.path.isEmpty)
        #expect(compact.isShowingChat == false)

        let regular = NavigationManager()
        regular.updateLayoutWidth(isRegular: true)
        regular.presentChat(conversationID: id)
        regular.dismissChat()
        #expect(regular.chatDetail == .empty)
        #expect(regular.isShowingChat == false)
    }

    @Test("Dismiss Chat With An ID Only Applies To That Conversation")
    func dismissChatIgnoresOtherConversations() {
        let nav = NavigationManager()
        nav.updateLayoutWidth(isRegular: true)
        let shown = UUID()
        nav.presentChat(conversationID: shown)

        nav.dismissChat(conversationID: UUID())
        #expect(nav.chatDetail == .conversation(shown))

        nav.dismissChat(conversationID: shown)
        #expect(nav.chatDetail == .empty)
    }

    @Test("Reset To New Chat Lands On The Carrier In Use")
    func resetToNewChatLandsOnDraft() {
        let compact = NavigationManager()
        compact.attemptNavigate(to: .backup)
        compact.resetToNewChat()
        #expect(compact.path == [.chat(conversationID: nil)])

        let regular = NavigationManager()
        regular.updateLayoutWidth(isRegular: true)
        regular.attemptNavigate(to: .backup)
        regular.resetToNewChat()
        #expect(regular.path.isEmpty)
        #expect(regular.chatDetail == .draft)
    }
}
