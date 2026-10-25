import Foundation
import SwiftUI
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

    @Test(
        "Two Columns Need Regular Width And A Window Of At Least 780pt",
        arguments: [
            (UserInterfaceSizeClass?.some(.regular), CGFloat(951), true),
            (.regular, 834, true),
            (.regular, 780, true),
            (.regular, 779, false),
            (.regular, 669, false),
            (.compact, 1032, false),
            (nil, 951, false),
            (.regular, 0, false),
        ] as [(UserInterfaceSizeClass?, CGFloat, Bool)]
    )
    func splitLayoutRequiresRegularAndMinimumWidth(
        sizeClass: UserInterfaceSizeClass?,
        width: CGFloat,
        expected: Bool
    ) {
        #expect(NavigationManager.usesSplitLayout(horizontalSizeClass: sizeClass, windowWidth: width) == expected)
    }

    @Test(
        "Half-folded sidebar follows the fold only with an active fold and room on both sides; otherwise 360–440",
        arguments: [
            // Half-folded Duo: fold centre line at 475.5 in a 951pt window
            (CGFloat?.some(475.5), CGFloat(951), CGFloat?.some(475.5)),
            (nil, 951, nil),
            (359, 951, nil),
            (360, 780, 360),
            (531, 951, 531),
            (532, 951, nil),
        ] as [(CGFloat?, CGFloat, CGFloat?)]
    )
    func foldAlignedSidebarWidth(divisionMidX: CGFloat?, containerWidth: CGFloat, expected: CGFloat?) {
        #expect(NavigationManager.foldAlignedSidebarWidth(divisionMidX: divisionMidX, containerWidth: containerWidth) == expected)
    }

    @Test("Resizing A Regular Window Across 780pt Moves The Conversation Between Carriers")
    func regularWindowResizeAcrossThresholdMovesChat() {
        let nav = NavigationManager()
        let id = UUID()
        func apply(_ width: CGFloat) {
            nav.updateLayoutWidth(
                isRegular: NavigationManager.usesSplitLayout(horizontalSizeClass: .regular, windowWidth: width)
            )
        }

        apply(951)
        nav.presentChat(conversationID: id)
        #expect(nav.chatDetail == .conversation(id))
        #expect(nav.path.isEmpty)

        apply(669)
        #expect(nav.isRegularWidth == false)
        #expect(nav.chatDetail == .empty)
        #expect(nav.path == [.chat(conversationID: id)])

        apply(951)
        #expect(nav.isRegularWidth)
        #expect(nav.chatDetail == .conversation(id))
        #expect(nav.path.isEmpty)
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

    // MARK: - Wide-screen column details

    private func regularNav(tab: AppTab) -> NavigationManager {
        let nav = NavigationManager()
        nav.updateLayoutWidth(isRegular: true)
        nav.selectedTab = tab
        return nav
    }

    @Test("columnTab maps a tab root's one-level details to their tab; everything else is nil")
    func columnTabMapping() {
        #expect(NavigationManager.columnTab(for: .providerDetail(providerID: UUID())) == .providers)
        for route: AppRoute in [.memory, .contextSettings, .voiceSettings, .skillsList, .mcpServers, .backup] {
            #expect(NavigationManager.columnTab(for: route) == .settings)
        }
        for route: AppRoute in [.notesList, .chat(conversationID: nil), .relayKeys(providerID: UUID())] {
            #expect(NavigationManager.columnTab(for: route) == nil)
        }
    }

    @Test("At a wide tab root, opening that tab's detail writes the right column instead of pushing")
    func regularAttemptNavigateWritesColumnDetail() {
        let id = UUID()
        let providers = regularNav(tab: .providers)
        providers.openProviderDetail(providerID: id)
        #expect(providers.path.isEmpty)
        #expect(providers.providersDetail == .providerDetail(providerID: id))

        let settings = regularNav(tab: .settings)
        settings.openBackup()
        #expect(settings.path.isEmpty)
        #expect(settings.settingsDetail == .backup)
        settings.openMemory()
        #expect(settings.path.isEmpty)
        #expect(settings.settingsDetail == .memory)
    }

    @Test("On wide screens other tabs' routes and a non-empty stack still push")
    func regularAttemptNavigatePushesOtherwise() {
        let id = UUID()
        let home = regularNav(tab: .home)
        home.openProviderDetail(providerID: id)
        #expect(home.path == [.providerDetail(providerID: id)])
        #expect(home.providersDetail == nil)

        let homeSettingsPage = regularNav(tab: .home)
        homeSettingsPage.openBackup()
        #expect(homeSettingsPage.path == [.backup])
        #expect(homeSettingsPage.settingsDetail == nil)

        let settings = regularNav(tab: .settings)
        settings.attemptNavigate(to: .notesList)
        settings.openBackup()
        #expect(settings.path == [.notesList, .backup])
        #expect(settings.settingsDetail == nil)

        let providers = regularNav(tab: .providers)
        providers.attemptNavigate(to: .notesList)
        providers.openProviderDetail(providerID: id)
        #expect(providers.path == [.notesList, .providerDetail(providerID: id)])
        #expect(providers.providersDetail == nil)
    }

    @Test("On a wide notes list, tapping a note writes notesDetail instead of pushing")
    func regularNoteDetailWritesNotesDetail() {
        let id = UUID()
        let nav = regularNav(tab: .settings)
        nav.openNotesList()
        nav.openNoteDetail(noteID: id)
        #expect(nav.path == [.notesList])
        #expect(nav.notesDetail == id)
    }

    @Test("At compact width attemptNavigate and pop are unchanged")
    func compactNavigateAndPopUnchanged() {
        let id = UUID()
        let nav = NavigationManager()
        nav.selectedTab = .settings
        nav.openBackup()
        nav.openNotesList()
        nav.openNoteDetail(noteID: id)
        #expect(nav.path == [.backup, .notesList, .noteDetail(noteID: id)])
        #expect(nav.settingsDetail == nil)
        #expect(nav.notesDetail == nil)
        nav.pop()
        #expect(nav.path == [.backup, .notesList])
        nav.popToRoot()
        nav.pop()
        #expect(nav.path.isEmpty)

        let providers = NavigationManager()
        providers.selectedTab = .providers
        providers.openProviderDetail(providerID: id)
        #expect(providers.path == [.providerDetail(providerID: id)])
        #expect(providers.providersDetail == nil)
    }

    @Test("pop at a wide tab root clears that tab's right column only")
    func regularPopClearsSelectedTabDetail() {
        let id = UUID()
        let nav = regularNav(tab: .providers)
        nav.openProviderDetail(providerID: id)
        nav.pop()
        #expect(nav.providersDetail == nil)
        #expect(nav.path.isEmpty)

        nav.openProviderDetail(providerID: id)
        nav.selectedTab = .settings
        nav.pop()
        #expect(nav.providersDetail == .providerDetail(providerID: id))
    }

    @Test("pop on wide screens with a non-empty stack still pops the stack")
    func regularPopWithPathPopsStack() {
        let id = UUID()
        let nav = regularNav(tab: .providers)
        nav.openProviderDetail(providerID: id)
        nav.attemptNavigate(to: .relayKeys(providerID: id))
        nav.pop()
        #expect(nav.path.isEmpty)
        #expect(nav.providersDetail == .providerDetail(providerID: id))
    }

    @Test("notesDetail clears when the notes list leaves the stack")
    func notesDetailClearedWhenNotesListLeavesPath() {
        let nav = regularNav(tab: .settings)
        nav.openNotesList()
        nav.openNoteDetail(noteID: UUID())
        nav.pop()
        #expect(nav.path.isEmpty)
        #expect(nav.notesDetail == nil)

        nav.openNotesList()
        nav.openNoteDetail(noteID: UUID())
        nav.attemptNavigate(to: .memory)
        #expect(nav.notesDetail != nil)
        nav.reset(to: [.memory])
        #expect(nav.notesDetail == nil)
    }

    @Test("Widening moves a single-level route of the current tab into the right column; the conversation still moves")
    func expandMovesSingleRouteIntoDetail() {
        let id = UUID()
        let providers = NavigationManager()
        providers.selectedTab = .providers
        providers.openProviderDetail(providerID: id)
        providers.updateLayoutWidth(isRegular: true)
        #expect(providers.path.isEmpty)
        #expect(providers.providersDetail == .providerDetail(providerID: id))

        // The chat move runs first: once the conversation leaves [route, chat] one level remains and moves over
        let chatID = UUID()
        let both = NavigationManager()
        both.selectedTab = .providers
        both.openProviderDetail(providerID: id)
        both.attemptNavigate(to: .chat(conversationID: chatID))
        both.updateLayoutWidth(isRegular: true)
        #expect(both.chatDetail == .conversation(chatID))
        #expect(both.path.isEmpty)
        #expect(both.providersDetail == .providerDetail(providerID: id))
    }

    @Test("Widening leaves deeper stacks and other tabs' routes alone")
    func expandKeepsDeepOrForeignRoutes() {
        let id = UUID()
        let deep = NavigationManager()
        deep.selectedTab = .providers
        deep.openProviderDetail(providerID: id)
        deep.openRelayKeys(providerID: id)
        deep.updateLayoutWidth(isRegular: true)
        #expect(deep.path == [.providerDetail(providerID: id), .relayKeys(providerID: id)])
        #expect(deep.providersDetail == nil)

        let foreign = NavigationManager()
        foreign.selectedTab = .home
        foreign.openProviderDetail(providerID: id)
        foreign.updateLayoutWidth(isRegular: true)
        #expect(foreign.path == [.providerDetail(providerID: id)])
        #expect(foreign.providersDetail == nil)
    }

    @Test("Widening with [notes list, note] at the top moves the note into notesDetail")
    func expandMovesNoteDetail() {
        let id = UUID()
        let nav = NavigationManager()
        nav.selectedTab = .settings
        nav.attemptNavigate(to: .memory)
        nav.openNotesList()
        nav.openNoteDetail(noteID: id)
        nav.updateLayoutWidth(isRegular: true)
        #expect(nav.path == [.memory, .notesList])
        #expect(nav.notesDetail == id)
    }

    @Test("Narrowing puts the current tab's detail at the bottom of the stack and the note after its list, then clears both")
    func collapseMovesDetailsBackToPath() {
        let noteID = UUID()
        let providerID = UUID()
        let nav = regularNav(tab: .settings)
        nav.openMemory()
        nav.openNotesList()
        nav.openNoteDetail(noteID: noteID)
        nav.attemptNavigate(to: .skillsList)
        nav.updateLayoutWidth(isRegular: false)
        #expect(nav.path == [.memory, .notesList, .noteDetail(noteID: noteID), .skillsList])
        #expect(nav.notesDetail == nil)

        // The conversation moves last, so it ends up on top
        let chatID = UUID()
        let withChat = regularNav(tab: .providers)
        withChat.openProviderDetail(providerID: providerID)
        withChat.presentChat(conversationID: chatID)
        withChat.updateLayoutWidth(isRegular: false)
        #expect(withChat.path == [.providerDetail(providerID: providerID), .chat(conversationID: chatID)])
        #expect(withChat.providersDetail == nil)
        #expect(withChat.chatDetail == .empty)
    }

    @Test("Narrowing drops other tabs' details")
    func collapseDropsOtherTabDetails() {
        let providerID = UUID()
        let nav = regularNav(tab: .providers)
        nav.openProviderDetail(providerID: providerID)
        nav.selectedTab = .home
        nav.updateLayoutWidth(isRegular: false)
        #expect(nav.path.isEmpty)
        #expect(nav.providersDetail == nil)
    }

    @Test("clearColumnDetails clears every detail")
    func clearColumnDetailsClearsAll() {
        let nav = regularNav(tab: .providers)
        nav.openProviderDetail(providerID: UUID())
        nav.selectedTab = .settings
        nav.openNotesList()
        nav.openNoteDetail(noteID: UUID())
        nav.clearColumnDetails()
        #expect(nav.providersDetail == nil)
        #expect(nav.notesDetail == nil)
    }
}
