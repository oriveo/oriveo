import Foundation
import OriveoProviderKit
import SwiftUI
import Testing
import UIKit
@testable import Oriveo

/// The context page-family screenshots read the shared manifest `shared/test-fixtures/shots/context.v1.json`: the page-name set matches this platform's page-name table,
/// the three ring pages produce 38 / 76 / ! via production `ContextUsageSummary`, the empty-conversation page shows no ring; the two confirm-dialog pages produce
/// overCap / priceLine via production `prompt`, the two picker pages produce sliderIndex via production picker state, and the unknown-window panel takes the dashed branch.
@Suite("Screenshot manifest - context page family")
@MainActor
struct ContextShotsManifestTests {
    typealias Shots = ContextShots

    private static func stage(_ shot: Shots.Shot) throws -> Shots.Staged {
        try Shots.stage(shot, manifestData: Shots.manifestData())
    }

    /// Ring: the ledger row + the current B are derived from the fixture's model entries through production metadata decoding and the production window formula (the ledger's B is not used).
    private static func ring(_ shot: Shots.Shot) throws -> ContextUsageSummary {
        let staged = try stage(shot)
        let chat = try #require(staged.chat)
        let resolved = try #require(try MetadataClient.resolveShotsCatalogModel(
            staged.catalogPayload, modelID: chat.modelID, providerKind: chat.providerKind
        ))
        let model = AIModel(
            id: chat.modelID,
            name: chat.modelName,
            capabilities: [.text],
            reasoningModeAvailable: false,
            isAvailable: true,
            isDefault: false,
            priceTier: "",
            contextLength: resolved.contextLength,
            maxOutputTokens: resolved.maxOutputTokens
        )
        let window = ChatRequestBuilder.contextWindowInput(
            providerKind: chat.providerKind,
            model: model,
            budgetCap: chat.conversation.contextCap ?? staged.defaultCap
        )
        let currentB = ContextBudget.window(window).B
        #expect(currentB == staged.manifests.last?.B, "\(shot.rawValue)")
        return ContextUsageSummary.make(manifests: staged.manifests, checkpoint: nil, currentB: currentB)
    }

    @Test("shotsManifestPagesMatchImplemented: manifest page-name set == this platform's page-name table")
    func shotsManifestPagesMatchImplemented() throws {
        let manifest = try Shots.Manifest.load(from: Shots.manifestData())
        #expect(Set(manifest.pages.map(\.name)) == Set(Shots.Shot.allCases.map(\.rawValue)))
        #expect(manifest.pages.count == Shots.Shot.allCases.count)
    }

    @Test("shotsManifestEveryPageStages: every page can be built from the manifest; only contextSettings does not open a chat page")
    func shotsManifestEveryPageStages() throws {
        for shot in Shots.Shot.allCases {
            let staged = try Self.stage(shot)
            #expect((staged.chat == nil) == (shot == .contextSettings), "\(shot.rawValue)")
        }
    }

    @Test("shotsManifestModelsDecodedByProductionMetadata: the display name is the displayName delivered by the server")
    func shotsManifestModelsDecodedByProductionMetadata() throws {
        #expect(try Self.stage(.contextRingNormal).chat?.modelName == "Mistral Medium 3")
        #expect(try Self.stage(.contextCapPicker).chat?.modelName == "Grok 4.7")
    }

    @Test("shotsManifestLedgerBudgetsMatchProduction: for every page with a ledger, the production-derived B == the fixture ledger B")
    func shotsManifestLedgerBudgetsMatchProduction() throws {
        let data = try Shots.manifestData()
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let rawManifests = try #require(root["manifests"] as? [String: Any])
        let manifest = try Shots.Manifest.load(from: data)
        var checked = 0
        for page in manifest.pages {
            guard let name = page.manifest else { continue }
            let shot = try #require(Shots.Shot(rawValue: page.name))
            let chat = try #require(try Self.stage(shot).chat, "\(page.name)")
            let raw = try #require(rawManifests[name] as? [String: Any], "\(name)")
            #expect(chat.currentB == raw["B"] as? Int, "\(page.name)")
            checked += 1
        }
        #expect(checked > 0)
        // contextPanelPriceLine: 1M window, unlimited for this conversation, B = 900000; contextCapPicker: 2M window, automatic, stops at the price line 200000
        #expect(try Self.stage(.contextPanelPriceLine).chat?.currentB == 900_000)
        #expect(try Self.stage(.contextCapPicker).chat?.currentB == 200_000)
    }

    @Test("shotsManifestRingLabelsFromProductionUsage: the production summary's label = 38 / 76 / !")
    func shotsManifestRingLabelsFromProductionUsage() throws {
        #expect(try Self.ring(.contextRingNormal).ring?.label == "38")
        #expect(try Self.ring(.contextRingHigh).ring?.label == "76")
        let over = try Self.ring(.contextRingOver)
        #expect(over.ring?.label == ContextUsageSummary.Ring.overLabel)
        #expect(over.ring?.label == "!")
    }

    @Test("shotsManifestRingHiddenWithoutLedger: a new empty conversation has no ledger row, and the production summary shows no ring")
    func shotsManifestRingHiddenWithoutLedger() throws {
        let staged = try Self.stage(.contextRingHidden)
        let chat = try #require(staged.chat)
        #expect(chat.conversation.messages.isEmpty)
        #expect(staged.manifests.isEmpty)
        let summary = ContextUsageSummary.make(manifests: staged.manifests, checkpoint: nil)
        #expect(summary.display == ContextUsageSummary.Display.none)
        #expect(summary.ring == nil)
    }

    @Test("shotsManifestCheckpointsAndHintThroughProduction: checkpoints cover up to a4; the 3rd-compaction hint is decided by production noteCompactionLanded")
    func shotsManifestCheckpointsAndHintThroughProduction() throws {
        defer {
            ContextLedgerStore.shotsPool = nil
            ContextCompactionStore.shotsPool = nil
        }
        for (shot, count) in [(Shots.Shot.contextDividerSummary, 1), (.contextDividerVerbatim, 1), (.contextCompactHint, 3)] {
            let staged = try Self.stage(shot)
            let chat = try #require(staged.chat)
            #expect(staged.checkpoints.count == count, "\(shot.rawValue)")
            let latest = try #require(staged.checkpoints.last)
            // Covers up to a4; the summary page carries a summary, the verbatim page does not
            #expect(latest.coversTo == chat.conversation.messages[7].id.uuidString, "\(shot.rawValue)")
            #expect((latest.summary != nil) == (shot != .contextDividerVerbatim), "\(shot.rawValue)")

            try Shots.writeIsolatedPartition(staged)
            let appState = AppState(seedDemoData: true)
            appState.chatManager.noteCompactionLanded(
                conversationID: chat.conversation.id, uid: appState.sessionPartitionUID
            )
            #expect((appState.pendingCompactionHint == chat.conversation.id) == (count == 3), "\(shot.rawValue)")
        }
    }

    @Test("shotsManifestSuggestionsThroughProduction: suggestion-bar messages are appended after a6, and production classification / decoding gives the suggestion")
    func shotsManifestSuggestionsThroughProduction() throws {
        let directiveChat = try #require(try Self.stage(.contextDirectiveSuggestion).chat)
        let directive = try #require(directiveChat.directive)
        #expect(directiveChat.conversation.messages.count == 14)
        #expect(directiveChat.conversation.messages[12].id == directive.messageID)
        #expect(MemoryIntent.classify(directive.text).suggestion != nil)

        let memoryChat = try #require(try Self.stage(.contextMemorySuggestion).chat)
        let memory = try #require(memoryChat.memory)
        #expect(memoryChat.conversation.messages[13].id == memory.messageID)
        #expect(memory.candidate.content == "Is vegetarian.")
    }

    @Test("shotsManifestStopReasonOnA6: lastAssistantStopReason hangs on a6")
    func shotsManifestStopReasonOnA6() throws {
        let chat = try #require(try Self.stage(.contextIncompleteFooter).chat)
        let a6 = Shots.uuid("message-a6")
        for message in chat.conversation.messages {
            #expect((message.stopReason == .length) == (message.id == a6))
        }
    }

    /// Installs this page into the in-memory AppState (the same `install` as the screenshot entry point) and unpins the fixture directory when done.
    private static func installed(_ shot: Shots.Shot) async throws -> (AppState, Shots.Staged.Chat) {
        let staged = try stage(shot)
        let appState = AppState(seedDemoData: true)
        let chat = try #require(try await Shots.install(staged, into: appState))
        return (appState, chat)
    }

    @Test("shotsManifestUpperLayersThroughProduction: upper-layer pages map open; confirm dialogs overCap / priceLine; picker sliderIndex 3 / 3; the unknown-window panel takes the dashed branch")
    func shotsManifestUpperLayersThroughProduction() async throws {
        defer { try? MetadataClient.pinCatalogForShots(nil) }
        let manifest = try Shots.Manifest.load(from: Shots.manifestData())
        for page in manifest.pages {
            let shot = try #require(Shots.Shot(rawValue: page.name))
            let staged = try Self.stage(shot)
            if page.open == "settings" {
                #expect(staged.chat == nil, "\(page.name)")
            } else {
                #expect(staged.chat?.overlay?.rawValue == page.open, "\(page.name)")
            }
        }

        for (shot, kind) in [
            (Shots.Shot.contextConfirmOverCap, ContextCapConfirmPresentation.Kind.overCap),
            (.contextConfirmPriceLine, .priceLine)
        ] {
            let (appState, chat) = try await Self.installed(shot)
            let prompt = try #require(try Shots.confirmPrompt(chat, in: appState), "\(shot.rawValue)")
            #expect(prompt.decision.kind == kind, "\(shot.rawValue)")
            #expect(prompt.input.estimatedInput == chat.confirm?.estimatedInput, "\(shot.rawValue)")
        }

        for shot in [Shots.Shot.contextCapPicker, .contextCapPickerLarge] {
            let (appState, chat) = try await Self.installed(shot)
            let source = try #require(
                ContextCapPresentation.panelSource(in: appState, conversationID: chat.conversation.id),
                "\(shot.rawValue)"
            )
            let state = ContextCapPickerState(source: source)
            #expect(state.model.sliderIndex == 3, "\(shot.rawValue)")
            #expect(state.sliderIndex == 3, "\(shot.rawValue)")
        }

        // Custom cap page: the conversation cap takes the fixture's 128000, and the picker lands on "Custom" via production state and shows 128000
        let (customAppState, customChat) = try await Self.installed(.contextCapPickerCustom)
        #expect(customChat.overlay == .picker)
        #expect(customChat.conversation.contextCap == .custom(128_000))
        let customSource = try #require(
            ContextCapPresentation.panelSource(in: customAppState, conversationID: customChat.conversation.id)
        )
        let customState = ContextCapPickerState(source: customSource)
        #expect(customState.conversationCap == .custom(128_000))
        #expect(customState.customValue == 128_000)

        let unknown = try Self.ring(.contextPanelUnknown)
        #expect(unknown.ring == nil)
        #expect(ContextUsagePanel.mode(for: unknown) == .dashed(hintKey: "context_usage_hint_window_unknown"))
    }

    @Test("shotsManifestMessageTimesFromFixture: message times come from the manifest createdAt; the extra checkpoint shares the latest message's createdAt")
    func shotsManifestMessageTimesFromFixture() throws {
        let manifest = try Shots.Manifest.load(from: Shots.manifestData())
        let chat = try #require(try Self.stage(.contextRingNormal).chat)
        let expected = manifest.conversation.messages.compactMap { MemoryEpisodicTime.parse($0.createdAt) }
        #expect(expected.count == manifest.conversation.messages.count)
        #expect(chat.conversation.messages.map(\.createdAt) == expected)
        let checkpoints = try Self.stage(.contextCompactHint).checkpoints
        #expect(Set(checkpoints.map(\.createdAt)).count == 1)
    }

    /// Installs one page and then another, and reads the second page's conversation back through production persistence (the same conversation id; the screenshots reuse the same partition's database on every launch).
    private static func persistedAfter(
        _ previous: Shots.Shot, then shot: Shots.Shot
    ) async throws -> (Shots.Staged.Chat, Conversation) {
        defer { try? MetadataClient.pinCatalogForShots(nil) }
        let appState = AppState(seedDemoData: true)
        _ = try #require(try await Shots.install(try stage(previous), into: appState))
        appState.flushConversationPersistQueue()
        let chat = try #require(try await Shots.install(try stage(shot), into: appState))
        appState.flushConversationPersistQueue()
        let stored = try #require(try appState.conversationRuntimeBridge.fetchConversationProjection(
            id: chat.conversation.id, uid: appState.sessionPartitionUID
        ), "\(shot.rawValue): the conversation could not be read back from the database")
        return (chat, stored)
    }

    @Test("shotsRingHiddenOpensEmptyConversation: messages left in the database by the previous page are not carried into the empty-conversation page")
    func shotsRingHiddenOpensEmptyConversation() async throws {
        let (_, normal) = try await Self.persistedAfter(.contextRingHidden, then: .contextRingNormal)
        #expect(!normal.messages.isEmpty)
        let (chat, stored) = try await Self.persistedAfter(.contextRingNormal, then: .contextRingHidden)
        #expect(chat.conversation.messages.isEmpty)
        #expect(stored.messages.isEmpty, "the database still has \(stored.messages.count) messages from the previous page")
    }

    @Test("shotsAnswerAttributionMatchesPageModel: on non-Mistral pages the answer attribution = this page's model")
    func shotsAnswerAttributionMatchesPageModel() async throws {
        let manifest = try Shots.Manifest.load(from: Shots.manifestData())
        var checked = 0
        for page in manifest.pages where page.messages == nil && page.open != "settings" {
            let shot = try #require(Shots.Shot(rawValue: page.name))
            let (chat, stored) = try await Self.persistedAfter(.contextRingNormal, then: shot)
            guard chat.modelName != "Mistral Medium 3" else { continue }
            let answers = stored.messages.filter { $0.role == .assistant }
            #expect(!answers.isEmpty, "\(page.name)")
            for answer in answers {
                #expect(answer.modelID == chat.modelID, "\(page.name)")
                #expect(answer.modelName == chat.modelName, "\(page.name)")
                #expect(answer.providerID == chat.providerID, "\(page.name)")
            }
            checked += 1
        }
        #expect(checked >= 3)
    }

    @Test("shotsContextSettingsHasNavigationTitle: Settings > Context has a title and a back button")
    func shotsContextSettingsHasNavigationTitle() async throws {
        try await Self.expectSettingsPageTopBar(
            route: .contextSettings, title: L10n.tr("settings_context_title", table: .settings)
        )
    }

    /// Goes through the production root view, navigates the Settings tab to the route, and finds the header title and back button in the accessibility tree.
    private static func expectSettingsPageTopBar(route: AppRoute, title: String) async throws {
        try #require(ApplicationAccessibility.enable(), "cannot enable application accessibility")
        let scene = try #require(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first,
            "test host has no window scene"
        )
        let appState = AppState(seedDemoData: true)
        appState.hasCompletedOnboarding = true
        let host = UIHostingController(rootView: AppRootView(appState: appState))
        let window = UIWindow(windowScene: scene)
        window.frame = scene.screen.bounds
        window.windowLevel = .alert + 1
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        try await Task.sleep(for: .seconds(1))
        appState.selectedTab = .settings
        appState.navigation.reset(to: [route])
        try await Task.sleep(for: .seconds(1))

        #expect(Self.accessibilityElement(labeled: title, traits: .header, in: host.view) != nil, "no title \"\(title)\"")
        if !appState.navigation.isRegularWidth {
            #expect(Self.accessibilityElement(labeled: L10n.tr("Back"), traits: .button, in: host.view) != nil, "no back button")
        }
    }

    @Test("shotsPanelRelativeTimeUsesFixtureClock: the panel's \"Compacted N times ...\" now = the fixture clock (checkpoint 10 minutes earlier)")
    func shotsPanelRelativeTimeUsesFixtureClock() throws {
        let manifest = try Shots.Manifest.load(from: Shots.manifestData())
        let clock = try #require(MemoryEpisodicTime.parse(manifest.clock))
        let staged = try Self.stage(.contextPanel)
        #expect(staged.clock == clock)

        Shots.pinClock(staged)
        defer { Shots.pinClock(nil) }
        #expect(ContextUsagePanelSheet.now == clock)

        let latest = try #require(staged.checkpoints.last)
        let summary = ContextUsageSummary.make(
            manifests: staged.manifests,
            checkpoint: ContextUsageCheckpoint(
                count: staged.checkpoints.count, latestCreatedAt: latest.createdAt, latestSummaryTokens: 0
            ),
            currentB: staged.chat?.currentB
        )
        let locale = Locale(identifier: "en")
        let text = try #require(ContextUsagePanel.compactedCountText(
            for: summary, now: ContextUsagePanelSheet.now, locale: locale
        ))
        let relative = RelativeDateTimeFormatter()
        relative.locale = L10n.formattingLocale(locale)
        relative.unitsStyle = .full
        relative.dateTimeStyle = .named
        let tenMinutesAgo = relative.localizedString(for: clock.addingTimeInterval(-600), relativeTo: clock)
        #expect(text.contains(tenMinutesAgo), "\(text)")
    }

    @Test("shotsDividerPagesScrollToDivider: the two divider-row pages initially scroll to the row holding the divider (the one after the last covered message), the rest land at the bottom")
    func shotsDividerPagesScrollToDivider() throws {
        let manifest = try Shots.Manifest.load(from: Shots.manifestData())
        for shot in Shots.Shot.allCases {
            guard let chat = try Self.stage(shot).chat else { continue }
            guard shot == .contextDividerSummary || shot == .contextDividerVerbatim else {
                #expect(chat.initialScrollQuery == nil, "\(shot.rawValue)")
                continue
            }
            let query = try #require(chat.initialScrollQuery, "\(shot.rawValue)")
            let messages = chat.conversation.messages
            // Production search jump locates the first message containing the query
            let hit = try #require(messages.firstIndex { $0.text.localizedCaseInsensitiveContains(query) })
            // Production divider is attached to the top of the row "previous message = last covered message"
            let page = try #require(manifest.pages.first { $0.name == shot.rawValue })
            let fixture = try #require(page.checkpoint.flatMap { manifest.checkpoints[$0] })
            let anchor = try #require(manifest.conversation.messages.first { $0.id == fixture.coversTo })
            #expect(hit > 0, "\(shot.rawValue)")
            #expect(hit > 0 && messages[hit - 1].text == anchor.content, "\(shot.rawValue)")
        }
    }

    private static func accessibilityElement(labeled label: String, traits: UIAccessibilityTraits, in root: NSObject) -> NSObject? {
        var visited = Set<ObjectIdentifier>()
        func search(_ node: NSObject) -> NSObject? {
            guard visited.insert(ObjectIdentifier(node)).inserted else { return nil }
            if node.isAccessibilityElement, node.accessibilityLabel == label, node.accessibilityTraits.contains(traits) {
                return node
            }
            var children: [NSObject] = []
            if let elements = node.accessibilityElements as? [NSObject] {
                children.append(contentsOf: elements)
            } else {
                let count = node.accessibilityElementCount()
                if count != NSNotFound, count > 0 {
                    for index in 0..<count {
                        if let child = node.accessibilityElement(at: index) as? NSObject { children.append(child) }
                    }
                }
            }
            if let view = node as? UIView { children.append(contentsOf: view.subviews) }
            for child in children {
                if let hit = search(child) { return hit }
            }
            return nil
        }
        return search(root)
    }
}
