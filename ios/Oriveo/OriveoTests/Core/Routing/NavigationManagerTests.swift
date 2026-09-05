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
}
