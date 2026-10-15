import Foundation
import Testing
import UIKit
@testable import Oriveo

/// Menu bar commands land only in the active window: two windows each have their own navigation, and a command changes only the one that is active.
@Suite("AppCommandDispatch", .serialized)
@MainActor
struct AppCommandDispatchTests {

    private struct Fixture {
        let state: AppState
        let tokenA: UUID
        let tokenB: UUID
        let navA: NavigationManager
        let navB: NavigationManager
    }

    private func makeFixture() -> Fixture {
        let state = AppState(seedDemoData: true, sessionUID: "app-command-tests-\(UUID().uuidString)")
        state.hasCompletedOnboarding = true
        let a = UUID(), b = UUID()
        let navA = state.windowNavigation(for: a)
        let navB = state.windowNavigation(for: b)
        return Fixture(state: state, tokenA: a, tokenB: b, navA: navA, navB: navB)
    }

    private func makePasteboard() throws -> UIPasteboard {
        try #require(UIPasteboard(name: UIPasteboard.Name("app-command-\(UUID().uuidString)"), create: true))
    }

    private func target(text: String?, conversationID: UUID? = UUID()) -> ChatCommandTarget {
        let messages = text.map { [
            TestFactories.makeMessage(role: .user, text: "Q"),
            TestFactories.makeMessage(role: .assistant, text: $0),
        ] } ?? []
        return ChatCommandTarget(
            owner: UUID(),
            conversationID: conversationID,
            lastResponseText: ChatCommandTarget.lastCopyableResponse(in: messages)
        )
    }

    @Test("The window count follows registration and release, and ⌘W availability follows it")
    func windowCountTracksRegistration() {
        let f = makeFixture()
        #expect(f.state.registeredWindowCount == 2)
        #expect(f.state.commandState.canCloseWindow)
        f.state.releaseWindowNavigation(f.tokenB)
        #expect(f.state.registeredWindowCount == 1)
        #expect(!f.state.commandState.canCloseWindow)
    }

    @Test("Availability comes from the active window: A on a chat page, B on Home, switching the active window changes ⌘K")
    func stateFollowsActiveWindow() {
        let f = makeFixture()
        f.navA.presentChat(conversationID: nil)
        f.navA.registerChatCommandTarget(target(text: "Answer A"))
        f.state.activateWindowNavigation(f.tokenA)
        #expect(f.state.commandState.isEnabled(.chooseModel))
        #expect(f.state.commandState.isEnabled(.copyLastResponse))
        #expect(!f.state.commandState.isEnabled(.stopGenerating))

        f.state.activateWindowNavigation(f.tokenB)
        #expect(!f.state.commandState.isEnabled(.chooseModel))
        #expect(!f.state.commandState.isEnabled(.copyLastResponse))
    }

    @Test("⌘K sends the model picker request only to the active window")
    func chooseModelTargetsActiveWindow() {
        let f = makeFixture()
        f.navA.presentChat(conversationID: nil)
        f.navB.presentChat(conversationID: nil)
        f.state.activateWindowNavigation(f.tokenB)
        #expect(f.state.perform(.chooseModel))
        #expect(f.navB.modelPickerRequest == 1)
        #expect(f.navA.modelPickerRequest == 0)
    }

    @Test("⌘F makes only the active window switch to Home, go back to the root and queue search")
    func searchTargetsActiveWindow() {
        let f = makeFixture()
        for nav in [f.navA, f.navB] {
            nav.selectedTab = .settings
            nav.presentChat(conversationID: nil)
        }
        f.state.activateWindowNavigation(f.tokenA)
        #expect(f.state.perform(.searchConversations))
        #expect(f.navA.selectedTab == .home)
        #expect(f.navA.path.isEmpty)
        #expect(f.navA.pendingSearchReveal)
        #expect(f.navB.selectedTab == .settings)
        #expect(f.navB.path == [.chat(conversationID: nil)])
        #expect(!f.navB.pendingSearchReveal)
    }

    @Test("⌘⇧C copies the last reply of the active window's conversation, not another window's")
    func copyTargetsActiveWindow() throws {
        let f = makeFixture()
        f.navA.presentChat(conversationID: nil)
        f.navB.presentChat(conversationID: nil)
        f.navA.registerChatCommandTarget(target(text: "Answer A"))
        f.navB.registerChatCommandTarget(target(text: "Answer B"))
        f.state.activateWindowNavigation(f.tokenB)
        let pasteboard = try makePasteboard()
        #expect(f.state.perform(.copyLastResponse, pasteboard: pasteboard))
        #expect(pasteboard.string == "Answer B")
    }

    @Test("No copyable reply / not generating: ⌘⇧C and ⌘. do nothing")
    func unavailableCommandsDoNothing() throws {
        let f = makeFixture()
        f.navA.presentChat(conversationID: nil)
        f.navA.registerChatCommandTarget(target(text: nil))
        f.state.activateWindowNavigation(f.tokenA)
        let pasteboard = try makePasteboard()
        #expect(!f.state.perform(.copyLastResponse, pasteboard: pasteboard))
        #expect(pasteboard.string == nil)
        #expect(!f.state.perform(.stopGenerating))
    }

    @Test("⌘1/2/3 switch only the active window's tab and go back to the tab root")
    func showTabTargetsActiveWindow() {
        let f = makeFixture()
        f.navA.presentChat(conversationID: nil)
        f.state.activateWindowNavigation(f.tokenA)
        #expect(f.state.perform(.showTab(.providers)))
        #expect(f.navA.selectedTab == .providers)
        #expect(f.navA.path.isEmpty)
        #expect(f.navB.selectedTab == .home)

        f.state.activateWindowNavigation(f.tokenB)
        #expect(f.state.perform(.showTab(.settings)))
        #expect(f.navB.selectedTab == .settings)
        #expect(f.navA.selectedTab == .providers)
    }

    @Test("⌘N switches to Home and starts a new chat only in the active window")
    func newChatTargetsActiveWindow() {
        let f = makeFixture()
        f.navA.selectedTab = .settings
        f.navB.selectedTab = .settings
        f.state.activateWindowNavigation(f.tokenB)
        #expect(f.state.perform(.newChat))
        // With a usable model it lands in a new chat; without one it leads to provider setup — either way only B changes
        #expect(f.navB.isShowingChat || f.navB.selectedTab == .providers)
        #expect(f.navA.selectedTab == .settings)
        #expect(f.navA.path.isEmpty)
        #expect(!f.navA.isShowingChat)
    }

    @Test("Commands do nothing before onboarding is finished")
    func onboardingIncompleteBlocksCommands() {
        let f = makeFixture()
        f.state.hasCompletedOnboarding = false
        f.state.activateWindowNavigation(f.tokenA)
        #expect(!f.state.perform(.showTab(.settings)))
        #expect(f.navA.selectedTab == .home)
    }

    @Test("Chat page carrier change: the old page unregistering after the new one keeps the new registration")
    func staleOwnerDoesNotClearNewTarget() {
        let f = makeFixture()
        let old = target(text: "Old")
        let new = target(text: "New")
        f.navA.registerChatCommandTarget(old)
        f.navA.registerChatCommandTarget(new)
        f.navA.unregisterChatCommandTarget(owner: old.owner)
        #expect(f.navA.chatCommandTarget == new)
        f.navA.unregisterChatCommandTarget(owner: new.owner)
        #expect(f.navA.chatCommandTarget == nil)
    }
}
