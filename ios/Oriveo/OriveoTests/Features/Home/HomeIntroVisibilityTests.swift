import Foundation
import Testing
@testable import Oriveo

/// The home conversation section's entrance animation is driven by `HomeView`'s
/// `@State contentAppeared`, and `@State` resets whenever the view is rebuilt. The two-column
/// layout makes rebuilds a frequent path: folding and unfolding swaps between
/// `NavigationSplitView { HomeView }` and a bare `HomeView()`. The observed consequence was
/// that opening a conversation, folding, then unfolding left the home sidebar with no
/// conversations at all — **not even the empty-state placeholder** — while the data was fine:
/// both branches of `conversationContent` sit under `opacity(contentAppeared ? 1 : 0)`.
///
/// Visibility therefore cannot rest on a post-rebuild onAppear. This group locks the fallback.
@Suite("HomeIntroVisibility")
@MainActor
struct HomeIntroVisibilityTests {

    @Test("The entrance flag starts false so the first visit still has a fade to play")
    func introStartsUnplayed() {
        let appState = AppState(seedDemoData: true)
        #expect(appState.hasPlayedHomeIntro == false)
    }

    @Test("Once played the flag stays set and does not regress on layout changes")
    func introStaysPlayed() {
        let appState = AppState(seedDemoData: true)
        appState.hasPlayedHomeIntro = true

        // Size class changes move the conversation between carriers; none of that should
        // erase the fact that the entrance has already played.
        appState.navigation.updateLayoutWidth(isRegular: true)
        appState.navigation.presentChat(conversationID: UUID())
        appState.navigation.updateLayoutWidth(isRegular: false)
        appState.navigation.updateLayoutWidth(isRegular: true)

        #expect(appState.hasPlayedHomeIntro, "the section must stay visible across fold/unfold")
    }

    @Test("Section visibility does not rest on a post-rebuild onAppear alone")
    func visibilityHasAFallbackBeyondOnAppear() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Features/Home
            .deletingLastPathComponent()   // Features
            .deletingLastPathComponent()   // OriveoTests
            .deletingLastPathComponent()   // Oriveo
            .appendingPathComponent("Oriveo/Features/Home/HomeView.swift")
        let source = try String(contentsOf: root, encoding: .utf8)

        // The fallback must exist and must actually fold in the AppState flag.
        #expect(source.contains("showsConversationContent"))
        #expect(source.contains("contentAppeared || appState.hasPlayedHomeIntro"))
        // Both opacity gates must use the fallback; missing one reproduces the empty home.
        #expect(source.contains("opacity(contentAppeared ? 1 : 0)") == false,
                "the section's opacity still reads contentAppeared and will stay invisible after a rebuild")
    }
}
