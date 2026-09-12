import SwiftUI
import Testing
import UIKit
@testable import Oriveo

/// Visual snapshots of the Home screen: the production `AppRootView` is attached to the test host's
/// window scene (status bar and home indicator safe areas are the real values of that simulator
/// model) and exported as PNGs per scenario.
///
/// Only runs when `ORIVEO_HOME_SNAPSHOT_DIR` is set (xcodebuild passes it through as
/// `TEST_RUNNER_ORIVEO_HOME_SNAPSHOT_DIR`); the regular full run skips it. These are simulator host
/// renders, not device screenshots: font rendering, ProMotion and the keyboard are device matters.
///
/// Waiting always uses `Task.sleep` to yield the MainActor: spinning the RunLoop from inside a
/// MainActor task does not drain the main queue, the views' `.task`s (search, provider top-up, …)
/// never run, and the capture would show a stale state.
@Suite(
    "Home visual snapshots",
    .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["ORIVEO_HOME_SNAPSHOT_DIR"] != nil)
)
@MainActor
struct HomeVisualSnapshotTests {
    private var outputDirectory: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["ORIVEO_HOME_SNAPSHOT_DIR"] ?? NSTemporaryDirectory())
    }

    // MARK: - Scenarios

    // Everything except the CJK scenario is pinned to English so the captures do not follow the simulator language.

    @Test("full-page and screen captures in dark and light")
    func fullPageBothSchemes() async throws {
        try await withLanguage(.english) {
            for (style, suffix) in Self.schemes {
                try await capture(makeDesignState(), name: "home-\(suffix)-full", style: style, fullPage: true)
                try await capture(makeDesignState(), name: "home-\(suffix)-screen", style: style)
            }
        }
    }

    @Test("focused hero")
    func heroFocused() async throws {
        try await withLanguage(.english) {
            for (style, suffix) in Self.schemes {
                try await capture(makeDesignState(), name: "hero-focused-\(suffix)", style: style, focusHero: true)
            }
        }
    }

    @Test("the three tab bar selection states")
    func tabSelections() async throws {
        try await withLanguage(.english) {
            for (style, suffix) in Self.schemes {
                for tab in AppTab.allCases {
                    let appState = makeDesignState()
                    appState.selectedTab = tab
                    try await capture(appState, name: "tab-\(tab.rawValue)-\(suffix)", style: style)
                }
            }
        }
    }

    @Test("edge states: no notes / no conversations / long model name and title / editing / search / largest Dynamic Type")
    func edgeStates() async throws {
        try await withLanguage(.english) {
            for (style, suffix) in Self.schemes {
                try await captureEdgeStates(style: style, suffix: suffix)
            }
        }
    }

    @Test("CJK date and greeting (zh-Hans)")
    func chineseLocale() async throws {
        try await withLanguage(.chineseSimplified) {
            for (style, suffix) in Self.schemes {
                try await capture(makeDesignState(), name: "cjk-zh-hans-\(suffix)", style: style)
            }
        }
    }

    private func captureEdgeStates(style: UIUserInterfaceStyle, suffix: String) async throws {
        try await capture(makeDesignState(), name: "edge-no-notes-\(suffix)", style: style, notes: [])

        let empty = makeDesignState()
        empty.conversations = []
        empty.conversationManager.handleConversationsDidChange(now: Date())
        try await capture(empty, name: "edge-no-conversations-\(suffix)", style: style)

        try await capture(makeDesignState(longText: true), name: "edge-long-text-\(suffix)", style: style, fullPage: true)

        try await capture(
            makeDesignState(),
            name: "edge-editing-\(suffix)",
            style: style,
            seed: HomeDebugSnapshotSeed(isEditing: true)
        )

        // Folders: the expanded folder uses the same group card with no separators inside, and the editing
        // checkmark must not hug the card's leading edge
        try await capture(makeDesignState(withFolder: true), name: "edge-folder-\(suffix)", style: style)
        try await capture(
            makeDesignState(withFolder: true),
            name: "edge-folder-editing-\(suffix)",
            style: style,
            seed: HomeDebugSnapshotSeed(isEditing: true)
        )

        // Fixture precondition: the query must actually match, otherwise the capture shows the empty result
        // state instead of the search results group
        let searching = makeDesignState()
        let hits = await searching.searchConversations(matching: "SwiftUI")
        #expect(!hits.isEmpty, "the fixture should contain a conversation whose title includes SwiftUI")
        try await capture(
            searching,
            name: "edge-search-\(suffix)",
            style: style,
            settleSeconds: 2,
            seed: HomeDebugSnapshotSeed(searchText: "SwiftUI")
        )

        try await capture(
            makeDesignState(),
            name: "edge-dynamic-type-max-\(suffix)",
            style: style,
            contentSize: .accessibilityExtraExtraExtraLarge,
            fullPage: true
        )
    }

    // MARK: - Fixture

    private static let schemes: [(UIUserInterfaceStyle, String)] = [(.dark, "dark"), (.light, "light")]

    /// Fixture data: five providers, three time groups, with costs and message counts (notes come from fixtureNotes).
    private func makeDesignState(longText: Bool = false, withFolder: Bool = false) -> AppState {
        let appState = AppState(seedDemoData: true)
        let now = Date()

        func provider(_ kind: ProviderKind, _ models: [(String, String)]) -> Provider {
            TestFactories.makeProvider(
                kind: kind,
                models: models.map { TestFactories.makeModel(id: $0.0, name: $0.1) }
            )
        }
        let anthropic = provider(.anthropic, [
            ("claude-sonnet-4-5", longText ? "Claude Sonnet 4.5 Extended Thinking Preview (2026-09-11)" : "Claude Sonnet 4.5"),
            ("claude-opus-4-1", "Claude Opus 4.1"),
        ])
        let gemini = provider(.gemini, [("gemini-2.5-flash", "Gemini 2.5 Flash"), ("gemini-2.5-pro", "Gemini 2.5 Pro")])
        let openAI = provider(.openAI, [("gpt-5", "GPT-5")])
        let deepseek = provider(.deepseek, [("deepseek-v3.2", "DeepSeek V3.2")])
        let qwen = provider(.qwen, [("qwen3-235b", "Qwen3 235B")])
        appState.providers = [anthropic, gemini, openAI, deepseek, qwen]

        func conversation(
            _ title: String,
            _ preview: String,
            _ provider: Provider,
            _ modelID: String,
            cost: Double,
            count: Int,
            minutesAgo: Double
        ) -> Conversation {
            var conversation = TestFactories.makeConversation(
                title: title,
                providerID: provider.id,
                providerKind: provider.kind,
                modelID: modelID,
                previewText: preview,
                estimatedCost: cost,
                updatedAt: now.addingTimeInterval(-minutesAgo * 60)
            )
            conversation.messageCountOverride = count
            return conversation
        }

        let longTitle = "How to write key achievements in a quarterly report so every reviewer reads them"
        appState.conversations = [
            conversation(
                longText ? longTitle : "How to write key achievements in a report",
                "Lead with outcomes, quantify where you can, then tie each one back to the team goal…",
                gemini, "gemini-2.5-flash", cost: 0.02, count: 6, minutesAgo: 14
            ),
            conversation(
                "Explain how trigonometry works",
                "Trigonometry studies the relationship between angles and side lengths in triangles…",
                anthropic, "claude-sonnet-4-5", cost: 0.01, count: 4, minutesAgo: 60
            ),
            conversation(
                "Email to Lisa: calling in sick today",
                "Subject: Sick day today. Hi Lisa, I woke up with a fever and will be offline…",
                openAI, "gpt-5", cost: 0, count: 2, minutesAgo: 180
            ),
            conversation(
                "Competitor UI benchmark analysis",
                "Comparison of latency, context window and pricing across the four apps…",
                deepseek, "deepseek-v3.2", cost: 0.07, count: 12, minutesAgo: 60 * 24
            ),
            conversation(
                "Translate onboarding copy to Japanese",
                "Natural phrasing for the onboarding copy, starting from the first greeting…",
                qwen, "qwen3-235b", cost: 0, count: 8, minutesAgo: 60 * 25
            ),
            conversation(
                "SwiftUI Metal shader prototyping",
                "Implementing MSL volumetric refraction for the hero card background…",
                anthropic, "claude-opus-4-1", cost: 0.31, count: 21, minutesAgo: 60 * 24 * 4
            ),
            conversation(
                "Weekend hike route near Shenzhen",
                "Wutong Mountain via the north trail: about 4 hours round trip with two water stops…",
                gemini, "gemini-2.5-pro", cost: 0.03, count: 5, minutesAgo: 60 * 24 * 6
            ),
        ]
        if withFolder {
            let folder = TestFactories.makeFolder(name: "Work")
            appState.folders = [folder]
            appState.expandedFolderIDs.insert(folder.id)
            var quarterly = conversation(
                "Quarterly roadmap review",
                "Three bets for Q4: onboarding, relay setup, and the notes recall pipeline…",
                openAI, "gpt-5", cost: 0.12, count: 9, minutesAgo: 35
            )
            quarterly.folderID = folder.id
            var hiring = conversation(
                "Hiring plan for the iOS team",
                "Two senior engineers first, then a designer who can own the Aurora system…",
                anthropic, "claude-opus-4-1", cost: 0.04, count: 3, minutesAgo: 60 * 30
            )
            hiring.folderID = folder.id
            appState.conversations.append(contentsOf: [quarterly, hiring])
        }
        appState.conversationManager.handleConversationsDidChange(now: now)
        appState.setActiveModel(providerID: anthropic.id, modelID: "claude-sonnet-4-5")

        return appState
    }

    /// Twelve notes; the most recent one carries a real title. NoteManager reloads the mirror from the
    /// (empty) store asynchronously once the view appears and overwrites this, so `capture` sets the notes
    /// again after the view has settled.
    private nonisolated static func fixtureNotes() -> [NoteSummary] {
        let now = Date()
        return (0..<12).map { index in
            NoteSummary(
                id: UUID(),
                title: index == 0 ? "SwiftUI Metal shader prototyping" : "Note \(index)",
                titleSource: .manual,
                body: "",
                tags: [],
                noteFolderID: nil,
                sourceModelName: nil,
                sourceProviderKind: nil,
                sourceProviderName: nil,
                captureKind: .blank,
                isPinned: false,
                createdAt: now,
                updatedAt: now.addingTimeInterval(-Double(index) * 3600),
                deletedAt: nil
            )
        }
    }

    // MARK: - Capture

    private func capture(
        _ appState: AppState,
        name: String,
        style: UIUserInterfaceStyle,
        contentSize: UIContentSizeCategory = .large,
        fullPage: Bool = false,
        focusHero: Bool = false,
        settleSeconds: Double = 1.2,
        seed: HomeDebugSnapshotSeed? = nil,
        notes: [NoteSummary] = HomeVisualSnapshotTests.fixtureNotes()
    ) async throws {
        let scene = try #require(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first,
            "the test host has no window scene, so there is no real safe area"
        )
        let screenSize = scene.screen.bounds.size

        let root = AppRootView(appState: appState)
            .environment(\.homeDebugSnapshotSeed, seed)
            .environment(\.dynamicTypeSize, DynamicTypeSize(contentSize) ?? .large)
        let host = UIHostingController(rootView: root)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: screenSize)
        window.windowLevel = .alert + 1
        window.overrideUserInterfaceStyle = style
        window.traitOverrides.preferredContentSizeCategory = contentSize
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.endEditing(true)
            window.isHidden = true
            window.rootViewController = nil
        }

        try await Task.sleep(for: .seconds(settleSeconds))
        appState.noteSummaries = notes
        try await Task.sleep(for: .seconds(0.4))

        if fullPage, let scrollView = mainScrollView(in: host.view) {
            let inset = scrollView.adjustedContentInset
            let pageHeight = scrollView.contentSize.height + inset.top + inset.bottom
            if pageHeight > screenSize.height {
                window.frame = CGRect(origin: .zero, size: CGSize(width: screenSize.width, height: ceil(pageHeight)))
                host.view.frame = window.bounds
                try await Task.sleep(for: .seconds(0.8))
            }
        }

        if focusHero {
            let textView = try #require(firstDescendant(of: host.view, as: UITextView.self), "hero text field not found")
            #expect(textView.becomeFirstResponder(), "the hero text field could not become first responder")
            try await Task.sleep(for: .seconds(1.0))
        }

        let format = UIGraphicsImageRendererFormat()
        format.scale = scene.screen.scale
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        #expect(image.size.width > 0 && image.size.height > 0)

        let data = try #require(image.pngData())
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        try data.write(to: outputDirectory.appendingPathComponent("\(name).png"))
    }

    /// The main Home list: the tallest vertical UIScrollView (the hero's own UITextView is also a UIScrollView and is excluded)
    private func mainScrollView(in view: UIView) -> UIScrollView? {
        var candidates: [UIScrollView] = []
        collect(view, into: &candidates)
        return candidates
            .filter { !($0 is UITextView) && $0.window != nil && !$0.isHidden }
            .max { $0.contentSize.height < $1.contentSize.height }
    }

    private func collect(_ view: UIView, into scrollViews: inout [UIScrollView]) {
        if let scrollView = view as? UIScrollView { scrollViews.append(scrollView) }
        for subview in view.subviews { collect(subview, into: &scrollViews) }
    }

    private func firstDescendant<T: UIView>(of view: UIView, as type: T.Type) -> T? {
        if let hit = view as? T { return hit }
        for subview in view.subviews {
            if let hit = firstDescendant(of: subview, as: type) { return hit }
        }
        return nil
    }

    private func withLanguage(_ language: LanguageOption, _ body: () async throws -> Void) async throws {
        var preference = AppPreferencesStore.load()
        let original = preference.language
        preference.language = language
        AppPreferencesStore.save(preference)
        L10n.invalidateCache()
        defer {
            var restore = AppPreferencesStore.load()
            restore.language = original
            AppPreferencesStore.save(restore)
            L10n.invalidateCache()
        }
        try await body()
    }
}
