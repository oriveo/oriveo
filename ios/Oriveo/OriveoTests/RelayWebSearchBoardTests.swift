import Foundation
import Testing
@testable import Oriveo

/// Structure tests for the web search settings page (the WebSearch board).
/// The assertions target what the production row model `RelayWebSearchBoardModel` actually produces for a real draft (`RelayWebSearchDraft`); no image snapshots are taken.
@Suite("Relay 2.0 · web search settings page board structure", .serialized)
@MainActor
struct RelayWebSearchBoardTests {
    typealias Board = RelayWebSearchBoardModel

    private static let chat = RelayTransport.openaiChatCompletions
    private static let responses = RelayTransport.openaiResponses
    private static let messages = RelayTransport.anthropicMessages
    private static let gemini = RelayTransport.geminiGenerateContent

    private static func relayProvider(
        transport: RelayTransport = .auto,
        roots: [RelayTransport: String] = [:],
        engineProfile: String? = nil
    ) -> Provider {
        var requested = RelayRequestedConfig(transport: transport, engineProfile: engineProfile)
        if !roots.isEmpty {
            requested.resolvedAPIBaseURLs = Dictionary(uniqueKeysWithValues: roots.map { ($0.key.rawValue, $0.value) })
        }
        return Provider(
            id: UUID(), kind: .relay, status: .connected, models: [], catalogModels: [],
            apiKey: "sk", apiKeyPreview: "", baseURLText: "https://api.myrelay.dev", relayRequested: requested
        )
    }

    private static func isolatedStore() -> RelayWebFragmentStore {
        RelayWebFragmentStore(defaults: UserDefaults(suiteName: "relay-web-search-board-tests-\(UUID().uuidString)")!)
    }

    /// The draft when the page opens (the one the production function reads from storage).
    private static func initialDraft(_ provider: Provider, store: RelayWebFragmentStore? = nil) -> RelayWebSearchDraft {
        RelayWebSearchDraft.initial(provider: provider, store: store ?? isolatedStore())
    }

    private static func board(
        _ provider: Provider,
        saved: RelayWebSearchDraft? = nil,
        _ mutate: (inout RelayWebSearchDraft) -> Void = { _ in }
    ) throws -> Board {
        let baseline = saved ?? initialDraft(provider)
        var draft = baseline
        mutate(&draft)
        return try #require(Board.make(provider: provider, draft: draft, saved: baseline))
    }

    private static func group(_ board: Board, _ id: Board.GroupID) throws -> Board.Group {
        try #require(board.groups.first { $0.id == id }, "missing group \(id.rawValue)")
    }

    private static func source(_ relativePath: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Oriveo")
            .appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - BOARD-WEBSEARCH-01

    @Test("BOARD-WEBSEARCH-01 header = back + title 'Web Search' + connection name as subtitle; Save sits in the bottom action bar and is disabled when nothing changed")
    func BOARD_WEBSEARCH_01_header_and_action_bar() throws {
        var provider = Self.relayProvider(transport: Self.messages)
        provider.customName = "My Relay"
        let clean = try Self.board(provider)

        #expect(clean.header.leading == .back)
        #expect(clean.header.titleKey == "Web Search")
        #expect(clean.header.titleTable == .chat)
        #expect(clean.header.subtitle == "My Relay")
        #expect(clean.introKey == RelayWebSearchDraft.introKey)
        #expect(clean.footerKey == "Saved only on this device")

        #expect(clean.actionBar.primaryKey == "Save")
        #expect(!clean.isDirty)
        #expect(!clean.actionBar.isPrimaryEnabled, "Save is disabled when nothing changed")

        let dirty = try Self.board(provider) { $0.useTemplate(Self.messages) }
        #expect(dirty.isDirty)
        #expect(dirty.actionBar.isPrimaryEnabled)

        let invalid = try Self.board(provider) { $0.setText(#"{"model":"x"}"#, for: Self.messages) }
        #expect(invalid.isDirty)
        #expect(!invalid.actionBar.isPrimaryEnabled, "Save is disabled while a section has invalid input")

        let reverted = try Self.board(provider) {
            $0.useTemplate(Self.messages)
            $0.clear(Self.messages)
        }
        #expect(!reverted.isDirty, "reverting to the original is not a change")
        #expect(!reverted.actionBar.isPrimaryEnabled)
    }

    // MARK: - BOARD-WEBSEARCH-02

    @Test("BOARD-WEBSEARCH-02 expanded protocols = the set of the detail page's 'Base paths' rows, and when a connection protocol is selected it is always included; the rest are folded into 'Other protocols'")
    func BOARD_WEBSEARCH_02_groups_follow_connection_protocols() throws {
        // auto with two verified protocols: the same set as the detail page's root-address rows.
        let multi = Self.relayProvider(roots: [
            Self.messages: "https://api.myrelay.dev/v1",
            Self.chat: "https://api.myrelay.dev/v1",
        ])
        let detailRow = try #require(
            RelayDetailBoardModel.make(multi)?.connectionRows.first { $0.id == .basePaths }
        )
        #expect(Board.usedTransports(multi) == detailRow.basePaths.map(\.transport))
        let multiBoard = try Self.board(multi)
        #expect(multiBoard.groups.map(\.id) == [.primary, .other])
        let multiPrimary = try Self.group(multiBoard, .primary)
        let multiOther = try Self.group(multiBoard, .other)
        #expect(multiPrimary.sections.map(\.transport) == [Self.chat, Self.messages])
        #expect(multiOther.sections.map(\.transport) == [Self.responses, Self.gemini])

        // A single protocol is selected and has no root address yet: at least the selected one is included.
        let fixed = Self.relayProvider(transport: Self.messages)
        #expect(Board.usedTransports(fixed) == [Self.messages])
        let fixedBoard = try Self.board(fixed)
        let primary = try Self.group(fixedBoard, .primary)
        #expect(primary.sections.map(\.transport) == [Self.messages])
        #expect(primary.titleKey == nil)
        #expect(!primary.isCollapsible)
        let other = try Self.group(fixedBoard, .other)
        #expect(other.sections.map(\.transport) == [Self.chat, Self.responses, Self.gemini])
        #expect(other.titleKey == "Other protocols")
        #expect(other.isCollapsible)

        // A selected protocol plus another protocol whose root address was also verified: both are expanded.
        let fixedWithRoots = Self.relayProvider(transport: Self.responses, roots: [Self.gemini: "https://api.myrelay.dev/v1beta"])
        #expect(Board.usedTransports(fixedWithRoots) == [Self.responses, Self.gemini])

        // auto with no verified protocol: there is nothing to go on, so all four sections are expanded and no folded group appears.
        let unknown = Self.relayProvider()
        #expect(Board.usedTransports(unknown) == [])
        let unknownBoard = try Self.board(unknown)
        #expect(unknownBoard.groups.map(\.id) == [.primary])
        #expect(unknownBoard.groups[0].sections.map(\.transport) == RelayWebFragments.transports)

        // Only the Chat Completions section carries a note.
        let notes = unknownBoard.groups[0].sections.filter { $0.noteKey != nil }
        #expect(notes.map(\.transport) == [Self.chat])
        #expect(notes.first?.noteKey == RelayWebSearchDraft.chatNoteKey)

        // A local-engine connection has no such page.
        var local = Self.relayProvider(transport: Self.chat, engineProfile: "ollama")
        local.baseURLText = "http://127.0.0.1:11434"
        #expect(Board.usedTransports(local) == nil)
        #expect(Board.make(provider: local, draft: Self.initialDraft(local), saved: Self.initialDraft(local)) == nil)
    }

    // MARK: - BOARD-WEBSEARCH-03

    @Test("BOARD-WEBSEARCH-03 'Other protocols' is collapsed by default and shows the filled count; it stays expanded while a section inside has invalid input")
    func BOARD_WEBSEARCH_03_other_group_expansion() throws {
        let provider = Self.relayProvider(transport: Self.messages)
        let store = Self.isolatedStore()
        #expect(store.save(connectionID: provider.id, transport: Self.responses, raw: #"{"tools":[{"type":"web_search"}]}"#) == nil)
        let saved = Self.initialDraft(provider, store: store)

        let other = try Self.group(try Self.board(provider, saved: saved), .other)
        #expect(!other.startsExpanded)
        #expect(!other.isExpanded(userChoice: nil))
        #expect(other.isExpanded(userChoice: true))
        #expect(other.filledCount == 1, "the stored Responses section counts toward the total")
        #expect(!other.hasError)

        let primary = try Self.group(try Self.board(provider, saved: saved), .primary)
        #expect(primary.isExpanded(userChoice: false), "a protocol in use cannot be collapsed")
        #expect(primary.filledCount == 0)

        let broken = try Self.group(
            try Self.board(provider, saved: saved) { $0.setText("not json", for: Self.gemini) },
            .other
        )
        #expect(broken.hasError)
        #expect(broken.sections.first { $0.transport == Self.gemini }?.error == .notJSON)
        #expect(broken.isExpanded(userChoice: false), "collapsing would hide the error")
        #expect(broken.filledCount == 2)

        // While pinned open, tapping the group header is not recorded as "collapse"; once the error goes away the group stays expanded.
        #expect(broken.isPinnedOpen)
        #expect(broken.userChoiceAfterTap(nil))
        #expect(broken.userChoiceAfterTap(true))
        let brokenBoard = try Self.board(provider, saved: saved) { $0.setText("not json", for: Self.gemini) }
        #expect(brokenBoard.groupsPinnedOpen == [.other])
        let unpinnedBoard = try Self.board(provider, saved: saved)
        #expect(unpinnedBoard.groupsPinnedOpen.isEmpty)
        let pinnedChoice = broken.userChoiceAfterTap(nil)
        #expect(other.isExpanded(userChoice: pinnedChoice), "after the JSON is fixed the group does not collapse under the user's finger")
        // When not pinned, tapping the group header toggles as usual.
        #expect(!other.isPinnedOpen)
        #expect(other.userChoiceAfterTap(nil))
        #expect(!other.userChoiceAfterTap(true))
        let page = try Self.source("Features/Providers/RelayWebSearchPage.swift")
        #expect(page.contains("group.userChoiceAfterTap(expansion[group.id])"))
        #expect(page.contains(".onChange(of: board.groupsPinnedOpen, initial: true)"))
    }

    // MARK: - BOARD-WEBSEARCH-04

    @Test("BOARD-WEBSEARCH-04 'Use template': other content in the box needs confirmation first, while an empty box or one already holding the template is filled directly")
    func BOARD_WEBSEARCH_04_template_overwrite_needs_confirmation() throws {
        let provider = Self.relayProvider(transport: Self.messages)
        var draft = Self.initialDraft(provider)
        #expect(Board.templateAction(for: Self.messages, draft: draft) == .fill)

        draft.setText("  \n", for: Self.messages)
        #expect(Board.templateAction(for: Self.messages, draft: draft) == .fill, "whitespace only counts as empty")

        draft.setText(#"{"tools":[{"type":"web_search_20260209","name":"web_search"}]}"#, for: Self.messages)
        #expect(Board.templateAction(for: Self.messages, draft: draft) == .confirmReplace)
        #expect(Board.templateAction(for: Self.chat, draft: draft) == .fill, "each protocol is judged separately")

        draft.useTemplate(Self.messages)
        #expect(Board.templateAction(for: Self.messages, draft: draft) == .fill, "already the template, so overwriting loses nothing")

        // The overwrite confirmation reuses the title and buttons of the chat page's "extra request body" dialog; its message is a new sentence for this page.
        #expect(Board.replaceTitleKey == "Replace what’s here?")
        #expect(Board.replaceKey == "Replace")
        #expect(Board.replaceMessageKey == "The template replaces what you’ve entered for this protocol.")
    }

    // MARK: - BOARD-WEBSEARCH-05

    @Test("BOARD-WEBSEARCH-05 with unsaved changes both the back button and the swipe show the unsaved-changes prompt, and without changes they go back directly; the prompt copy is reused from editing a connection")
    func BOARD_WEBSEARCH_05_unsaved_changes_guard_leaving() throws {
        let provider = Self.relayProvider(transport: Self.messages)

        let clean = try Self.board(provider)
        #expect(clean.backAction == .pop)
        #expect(clean.allowsBackSwipe)

        let dirty = try Self.board(provider) { $0.useTemplate(Self.messages) }
        #expect(dirty.backAction == .confirmDiscard)
        #expect(!dirty.allowsBackSwipe, "with changes the swipe must not dismiss the page directly")

        // An edit inside a collapsed group counts too.
        let dirtyInOther = try Self.board(provider) { $0.useTemplate(Self.gemini) }
        #expect(dirtyInOther.backAction == .confirmDiscard)

        // Typing only whitespace is not a change (a blank section is deleted on save anyway).
        let blank = try Self.board(provider) { $0.setText("  ", for: Self.chat) }
        #expect(blank.backAction == .pop)

        // The read-time mapping of legacy stored fields is the content on page entry, not a change.
        let legacy = try JSONDecoder().decode(
            RelayRequestedConfig.self, from: Data(#"{"transport":"openai_responses","hasWebSearch":true}"#.utf8)
        )
        var legacyProvider = Self.relayProvider()
        legacyProvider.relayRequested = legacy
        let legacyBoard = try Self.board(legacyProvider)
        let legacyPrimary = try Self.group(legacyBoard, .primary)
        #expect(legacyPrimary.filledCount == 1)
        #expect(legacyBoard.backAction == .pop)

        // Swipe: only a gesture that starts at the left edge, moves right and is mostly horizontal counts (dragging the cursor in the editor does not).
        #expect(Board.isBackSwipe(startX: 8, dx: 120, dy: 10))
        #expect(!Board.isBackSwipe(startX: 120, dx: 120, dy: 10), "does not start at the edge")
        #expect(!Board.isBackSwipe(startX: 8, dx: 30, dy: 0), "distance too short")
        #expect(!Board.isBackSwipe(startX: 8, dx: 80, dy: 90), "mostly vertical")
        #expect(!Board.isBackSwipe(startX: 8, dx: -120, dy: 0), "leftward")

        #expect(Board.discardTitleKey == "Discard unsaved changes?")
        #expect(Board.discardMessageKey == "Your changes to this connection have not been saved.")
        #expect(Board.discardMessageKey == RelayEditBoardModel.discardMessageKey)
        #expect(Board.keepEditingKey == "Keep editing")
        #expect(Board.discardKey == "Discard")
    }

    // MARK: - BOARD-WEBSEARCH-06

    @Test("BOARD-WEBSEARCH-06 the route hides the system navigation bar, so the page no longer hangs its title and Save on it: a custom header plus a bottom action bar")
    func BOARD_WEBSEARCH_06_page_does_not_depend_on_system_navigation_bar() throws {
        // Premise: this page's route is wrapped in `oriveoNavigationChrome()`, which hides the back button and the whole navigation bar.
        let root = try Self.source("Features/App/AppRootView.swift")
        let route = try #require(root.range(of: "RelayWebSearchPage(providerID: providerID)"))
        let afterRoute = root[route.upperBound...].drop { $0.isWhitespace }
        #expect(afterRoute.hasPrefix(".oriveoNavigationChrome()"))
        let chrome = try #require(root.range(of: "func oriveoNavigationChrome() -> some View {"))
        let chromeBody = root[chrome.upperBound...].prefix(160)
        #expect(chromeBody.contains("navigationBarBackButtonHidden(true)"))
        #expect(chromeBody.contains(".toolbar(.hidden, for: .navigationBar)"))

        // So the page must not use anything that attaches to the system navigation bar.
        let page = try Self.source("Features/Providers/RelayWebSearchPage.swift")
        for banned in [".navigationTitle", "navigationBarTitleDisplayMode", "ToolbarItem", ".toolbar"] {
            #expect(!page.contains(banned), "the page still uses the system navigation bar: \(banned)")
        }

        // Back, Save and the unsaved-changes prompt all live inside the page.
        #expect(page.contains(#"OriveoBackButton(action: onBack)"#))
        #expect(page.contains(".safeAreaInset(edge: .bottom)"))
        let saveButton = try #require(page.range(of: #"Button(L10n.tr(bar.primaryKey), action: onSave)"#))
        #expect(page[saveButton.upperBound...].prefix(200).contains(".disabled(!bar.isPrimaryEnabled)"))
        #expect(page.contains("L10n.tr(Board.discardMessageKey, table: .providers)"))
        // Swipe: with changes the app-level back gesture is disabled, and restored when the page is left.
        #expect(page.contains("SwipeBackCoordinator.shared.isBackSwipeEnabled = board.allowsBackSwipe"))
        #expect(page.contains(
            ".onDisappear { SwipeBackCoordinator.shared.isBackSwipeEnabled = Board.allowsBackSwipeAfterLeaving }"
        ))
        #expect(Board.allowsBackSwipeAfterLeaving)
        // Saving goes only through the row model's `commit`; the page supplies the persistence action.
        #expect(page.contains("Board.commit(current, provider: provider, persist: {"))
        #expect(page.contains("appState.providerManager.updateProvider($0)"))
        #expect(!page.contains("current.save("))
    }

    @Test("the fixed bottom bar does not show text through it: surfaceChrome has alpha, so an opaque page background sits underneath and a disabled Save button does not reveal text scrolled under the bar (consistent with Android / Web)")
    func fixed_bottom_bars_are_opaque_under_dimmed_buttons() throws {
        let files = [
            "Features/Providers/RelayWebSearchPage.swift",
            "Features/Providers/RelayEditView.swift",
            "Features/Providers/ProviderSettingsSection.swift",
            "Features/Providers/ProviderSetupView.swift",
        ]
        for file in files {
            let source = try Self.source(file)
            let chrome = try #require(source.range(of: ".background(OriveoTheme.Palette.surfaceChrome)"), "\(file) bottom bar no longer uses surfaceChrome")
            let next = source[chrome.upperBound...].drop { $0.isWhitespace }
            #expect(next.hasPrefix(".background(OriveoTheme.Palette.background)"), "\(file) the bottom bar is translucent, so a disabled button would show text beneath it")
        }
    }

    // MARK: - BOARD-WEBSEARCH-08

    @Test("BOARD-WEBSEARCH-08 save: the snippets are written to storage and the connection with its legacy web-search fields cleared is handed to persistence; nothing is written while a section has invalid input")
    func BOARD_WEBSEARCH_08_commit_writes_store_and_persists_provider() throws {
        let legacy = try JSONDecoder().decode(
            RelayRequestedConfig.self, from: Data(#"{"transport":"anthropic_messages","hasWebSearch":true}"#.utf8)
        )
        var provider = Self.relayProvider()
        provider.relayRequested = legacy
        let store = Self.isolatedStore()
        var draft = Self.initialDraft(provider, store: store)
        draft.clear(Self.gemini)
        draft.useTemplate(Self.messages)

        // A section with invalid input: nothing is written to storage or persisted.
        var invalid = draft
        invalid.setText("not json", for: Self.chat)
        var persisted: [Provider] = []
        let rejected = Board.commit(invalid, provider: provider, store: store, persist: { persisted.append($0) })
        #expect(rejected == nil)
        #expect(persisted.isEmpty)
        #expect(store.stored(connectionID: provider.id).isEmpty)

        let committed = Board.commit(draft, provider: provider, store: store, persist: { persisted.append($0) })
        let baseline = try #require(committed)
        #expect(baseline == draft)
        #expect(persisted.count == 1, "the updated connection is persisted once")
        let updated = try #require(persisted.first)
        #expect(updated.id == provider.id)
        #expect(updated.relayRequested?.hasWebSearch == nil)
        #expect(updated.relayRequested?.transport == Self.messages)

        // Read back the effective snippets: exactly the saved sections, with the cleared section gone.
        let effective = store.effective(provider: updated)
        #expect(Set(effective.raw.keys) == [Self.responses.rawValue, Self.messages.rawValue])
        #expect(effective.raw[Self.messages.rawValue] == RelayWebFragments.template(for: Self.messages))
        #expect(effective.object(for: Self.gemini) == nil)

        // The saved content becomes the new baseline.
        let board = try #require(Board.make(provider: updated, draft: baseline, saved: baseline))
        #expect(!board.isDirty)
        #expect(board.allowsBackSwipe)
    }

    // MARK: - BOARD-WEBSEARCH-09

    @Test("BOARD-WEBSEARCH-09 the JSON editor is forced left-to-right and does not flip with an RTL interface")
    func BOARD_WEBSEARCH_09_editor_is_left_to_right() throws {
        #expect(Board.forcesLeftToRightEditor)
        let page = try Self.source("Features/Providers/RelayWebSearchPage.swift")
        let editor = try #require(page.range(of: "TextEditor(text: Binding("))
        let chainEnd = try #require(page.range(of: ".accessibilityLabel(", range: editor.upperBound..<page.endIndex))
        #expect(page[editor.upperBound..<chainEnd.lowerBound].contains(".environment(\\.layoutDirection, .leftToRight)"))
    }

    // MARK: - BOARD-WEBSEARCH-07

    @Test("BOARD-WEBSEARCH-07 saved content becomes the new baseline: reopening the page shows no unsaved changes, and the web-search section sits in the group it belongs to")
    func BOARD_WEBSEARCH_07_saved_draft_becomes_the_baseline() throws {
        let provider = Self.relayProvider(transport: Self.messages)
        let store = Self.isolatedStore()
        var draft = Self.initialDraft(provider, store: store)
        draft.useTemplate(Self.messages)
        draft.useTemplate(Self.gemini)
        let saved = try #require(draft.save(provider: provider, store: store))

        let reopened = Self.initialDraft(saved, store: store)
        let board = try #require(Board.make(provider: saved, draft: reopened, saved: reopened))
        #expect(!board.isDirty)
        #expect(!board.actionBar.isPrimaryEnabled)
        let primary = try Self.group(board, .primary)
        let other = try Self.group(board, .other)
        #expect(primary.filledCount == 1)
        #expect(other.filledCount == 1)
        #expect(!other.isExpanded(userChoice: nil), "content under other protocols only shows a count and does not auto-expand")
    }

    // MARK: - RL2-WEBPROBE-RETEST

    private static var retainedStates: [AppState] = []

    private static func isolatedRecords() -> RelayWebProbeStore {
        RelayWebProbeStore(defaults: UserDefaults(suiteName: "relay-web-search-board-records-\(UUID().uuidString)")!)
    }

    nonisolated private static func sse(_ lines: [String]) -> RelayCapabilityTest.Response {
        RelayCapabilityTest.Response(
            status: 200, contentType: "text/event-stream",
            body: Data((lines.joined(separator: "\n") + "\n").utf8)
        )
    }

    /// SSE from the web-probe.v1.json fixture evidenceCases chat_url_citation_searched / chat_text_only_silent.
    nonisolated private static let searchedReply = sse([
        #"data: {"choices":[{"index":0,"delta":{"role":"assistant","content":"Today's top story"}}]}"#, "",
        #"data: {"choices":[{"index":0,"delta":{"annotations":[{"type":"url_citation","url_citation":{"url":"https://news.example.com/top","title":"Top story","start_index":0,"end_index":17}}]}}]}"#, "",
        #"data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}"#, "",
        "data: [DONE]", "",
    ])
    nonisolated private static let silentReply = sse([
        #"data: {"choices":[{"index":0,"delta":{"role":"assistant","content":"I can't browse, but here is a guess."}}]}"#, "",
        #"data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}"#, "",
        "data: [DONE]", "",
    ])

    /// The connection protocol is fixed to Chat Completions, so it is every model's first-send protocol.
    private static func probeProvider(enabled: [String], catalogOnly: [String]) -> Provider {
        let models = enabled.map { TestFactories.makeModel(id: $0, name: "Name \($0)", capabilities: [.text]) }
        let catalog = models + catalogOnly.map { TestFactories.makeModel(id: $0, capabilities: [.text]) }
        return Provider(
            id: UUID(), kind: .relay, status: .connected, models: models, catalogModels: catalog,
            apiKey: "sk-test", apiKeyPreview: "...test", baseURLText: "https://relay.example.com",
            relayRequested: RelayRequestedConfig(transport: chat, authMode: .auto, securityMode: .remoteHTTPS)
        )
    }

    @Test("RL2-WEBPROBE-RETEST the rejected section lists only enabled models currently recorded as rejected (in enable order, by stored snippet); retest = a manual probe that stays out of the auto history, and the row disappears after searched / silent")
    func RL2_WEBPROBE_RETEST() async throws {
        let provider = Self.probeProvider(enabled: ["zeta", "alpha", "beta", "gamma"], catalogOnly: ["off"])
        let fragments = Self.isolatedStore()
        let raw = #"{"web_search_options":{}}"#
        #expect(fragments.save(connectionID: provider.id, transport: Self.chat, raw: raw) == nil)
        let hash = RelayWebProbe.fragmentHash(try #require(fragments.chatFragments(for: provider)?.object(for: Self.chat)))
        let records = Self.isolatedRecords()
        let connection = provider.id.uuidString
        for (model, result, fragmentHash) in [
            ("zeta", RelayWebProbeRecord.Result.rejected, hash),
            ("alpha", .rejected, hash),
            ("beta", .searched, hash),
            ("gamma", .rejected, "stale-hash"),
            ("off", .rejected, hash),
        ] {
            records.record(
                connectionID: connection, modelID: model, transport: Self.chat.rawValue,
                result: result, source: .tested, fragmentHash: fragmentHash
            )
        }
        // A rejected on another protocol does not count: the first-send protocol is Chat Completions.
        records.record(
            connectionID: connection, modelID: "beta", transport: Self.messages.rawValue,
            result: .rejected, source: .tested, fragmentHash: hash
        )

        func listed() -> [String] {
            Board.rejectedModels(provider: provider, fragments: fragments, records: records).map(\.modelID)
        }
        #expect(listed() == ["zeta", "alpha"], "only enabled models rejected under the current snippet, in enable order")
        #expect(Board.rejectedModels(provider: provider, fragments: fragments, records: records).map(\.name) == ["Name zeta", "Name alpha"])

        // Use the stored snippet, not the draft: even if the draft clears this section the row is still listed by the stored snippet.
        let saved = RelayWebSearchDraft.initial(provider: provider, store: fragments)
        var draft = saved
        draft.clear(Self.chat)
        let board = try #require(Board.make(provider: provider, draft: draft, saved: saved, fragments: fragments, records: records))
        #expect(board.rejected.map(\.modelID) == ["zeta", "alpha"])
        #expect(Board.rejectedTitleKey == "Models that reject these settings")
        #expect(Board.retestKey == "Test again")

        // No stored snippet: no rows are listed.
        #expect(Board.rejectedModels(provider: provider, fragments: Self.isolatedStore(), records: records).isEmpty)

        // Retest: the production manual probe (runRelayWebProbe), which writes no auto history and takes no quota.
        let state = AppState(
            seedDemoData: false, sessionUID: "relay-web-search-retest-\(UUID().uuidString)",
            providerSession: URLSession(configuration: .ephemeral)
        )
        Self.retainedStates.append(state)
        state.providers = [provider]
        let replies = ReplyQueue([Self.searchedReply, Self.silentReply])
        state.providerManager.relayWebProbeAutoContext = RelayWebProbeAutoContext(
            send: { _ in replies.next() }, fragments: fragments, records: records
        )

        let first = await state.providerManager.retestRelayWebProbe(providerID: provider.id, modelID: "zeta")
        guard case let .probed(searched) = try #require(first) else { Issue.record("expected a probed result: \(String(describing: first))"); return }
        #expect(searched.result == .searched)
        #expect(listed() == ["alpha"], "the row disappears after searched")

        let second = await state.providerManager.retestRelayWebProbe(providerID: provider.id, modelID: "alpha")
        guard case let .probed(silent) = try #require(second) else { Issue.record("expected a probed result: \(String(describing: second))"); return }
        #expect(silent.result == .silent)
        #expect(listed().isEmpty, "the row disappears after silent")

        #expect(replies.count == 2, "each retest sends one request")
        #expect(records.autoHistory().isEmpty, "a manual retest stays out of the auto history and takes no auto-probe quota")
    }

    @Test("RL2-WEBPROBE-RETEST the disclosure row = copy 5, drawn at the end of the scroll content (after the footer, not in the save bar); the rejected section sits below the groups; the retest button shows a spinner")
    func RL2_WEBPROBE_RETEST_layout() throws {
        let provider = Self.relayProvider(transport: Self.messages)
        let board = try Self.board(provider)
        #expect(board.actionBar.disclosureKey == "After you save, up to 5 enabled models each get one web search request with your key, to check that search works. Searches may be billed.")
        #expect(board.actionBar.disclosureKey == Board.disclosureKey)

        let page = try Self.source("Features/Providers/RelayWebSearchPage.swift")
        // The disclosure row is the last item of the scroll content (below the footer, above the save bar); the fixed save bar holds only buttons.
        let pageFn = try #require(page.range(of: "private func page("))
        let inset = try #require(page.range(of: ".safeAreaInset(edge: .bottom)", range: pageFn.upperBound..<page.endIndex))
        let scrollBody = page[pageFn.upperBound..<inset.lowerBound]
        let footer = try #require(scrollBody.range(of: "board.footerKey"), "the scroll content draws the footer")
        let disclosure = try #require(scrollBody.range(of: "board.actionBar.disclosureKey"), "the scroll content must draw the disclosure row")
        #expect(footer.lowerBound < disclosure.lowerBound, "the disclosure row comes after the footer")
        let rejected = try #require(scrollBody.range(of: "rejectedSection(board"))
        #expect(rejected.lowerBound < disclosure.lowerBound, "the disclosure row comes after the rejected section")
        let bar = try #require(page.range(of: "private func actionBar("))
        let barBody = page[bar.upperBound...]
        let barEnd = barBody.range(of: "\n    }\n")?.lowerBound ?? barBody.endIndex
        #expect(!barBody[..<barEnd].contains("disclosureKey"), "the fixed save bar holds only buttons and draws no disclosure row")
        #expect(barBody.contains("Button(L10n.tr(bar.primaryKey), action: onSave)"))

        let groups = try #require(page.range(of: "ForEach(board.groups, id: \\.id)"))
        let rejectedInPage = try #require(page.range(of: "rejectedSection(board"), "the rejected section is drawn below the groups")
        #expect(groups.lowerBound < rejectedInPage.lowerBound)
        #expect(page.contains("ProgressView()"), "the button turns into a spinner while running")
        #expect(page.contains("retestRelayWebProbe(providerID:"))
    }
}

/// A fake upstream that replays replies in order and counts requests.
private final class ReplyQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [RelayCapabilityTest.Response]
    private var sent = 0

    init(_ replies: [RelayCapabilityTest.Response]) { self.replies = replies }

    func next() -> RelayCapabilityTest.Response {
        lock.withLock {
            sent += 1
            return replies.removeFirst()
        }
    }

    var count: Int { lock.withLock { sent } }
}
