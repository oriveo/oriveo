import Foundation
import Testing
@testable import Oriveo

/// Relay keys page (contract card A4): the rows, status words, action sheet, explanation card and input sheets of the board model `RelayKeysBoardModel`;
/// every operation goes through the production `ProviderManager.applyRelayKeyOperation`, and assertions read the provider after write-back.
@Suite("Relay 2.0 · keys page", .serialized)
@MainActor
struct RelayKeysBoardTests {
    typealias Board = RelayKeysBoardModel

    // MARK: - Construction

    nonisolated(unsafe) private static var retainedStates: [AppState] = []

    private static func makeState() -> AppState {
        let state = AppState(
            seedDemoData: false,
            sessionUID: "relay-keys-board-\(UUID().uuidString)",
            providerSession: RelayKeysFakeServer.session()
        )
        retainedStates.append(state)
        return state
    }

    private static func model(_ id: String, name: String? = nil, keyID: String? = nil, listedBy: [String]? = nil) -> AIModel {
        var model = TestFactories.makeModel(id: id, name: name)
        model.relayKeyID = keyID
        model.relayListedByKeyIDs = listedBy
        return model
    }

    private static func relayProvider(models: [AIModel], catalog: [AIModel], keys: [RelayKey]? = nil) -> Provider {
        var provider = Provider(
            id: UUID(),
            kind: .relay,
            status: .connected,
            models: models,
            catalogModels: catalog,
            lastCheckedAt: Date(timeIntervalSince1970: 1),
            apiKey: "sk-primary-0000-1111",
            apiKeyPreview: "sk-p…1111",
            baseURLText: "https://relay.example.com/v1",
            relayRequested: RelayRequestedConfig(transport: .openaiChatCompletions, authMode: .bearer, securityMode: .remoteHTTPS)
        )
        provider.relayKeys = keys
        return provider
    }

    /// Three keys: the primary is healthy, the second returns 401 invalid (named), and the third is unchecked (unnamed).
    private static func threeKeys() -> Provider {
        let checked = Date(timeIntervalSince1970: 1_700_000_000)
        return relayProvider(
            models: [
                model("gpt-4o", keyID: "initial"),
                model("claude-opus-4", name: "Claude Opus 4", keyID: "k-claude"),
                model("claude-sonnet-4-5", name: "Claude Sonnet 4.5", keyID: "k-claude"),
            ],
            catalog: [
                model("gpt-4o", listedBy: ["initial"]),
                model("gpt-4.1", listedBy: ["initial"]),
                model("claude-opus-4", listedBy: ["k-claude"]),
            ],
            keys: [
                RelayKey(id: "initial", name: "Main", status: .init(state: .ok, httpStatus: 200, checkedAt: checked)),
                RelayKey(id: "k-claude", name: "Claude only", apiKey: "sk-claude-2222-3333",
                         status: .init(state: .invalid, httpStatus: 401, checkedAt: checked)),
                RelayKey(id: "k-spare", apiKey: "sk-spare-4444-5555"),
            ]
        )
    }

    private static func catalogBody(_ ids: [String]) -> String {
        let items = ids.map { #"{"id":"\#($0)","object":"model"}"# }.joined(separator: ",")
        return #"{"object":"list","data":[\#(items)]}"#
    }

    private static func modelsRequests() -> [URLRequest] {
        RelayKeysFakeServer.captured().filter { $0.url?.path == "/v1/models" }
    }

    // MARK: - BOARD-KEYS-01

    @Test("BOARD-KEYS-01 per key: name or mask, primary badge, mask, six status words, catalog count, in-use model count, and last status code when not healthy")
    func boardKeys01Rows() throws {
        let board = Board.make(Self.threeKeys())

        #expect(Board.titleKey == "API Keys")
        #expect(board.host == "relay.example.com")
        #expect(board.keyCount == 3)
        #expect(!board.isSingle)
        #expect(board.rows.map(\.id) == ["initial", "k-claude", "k-spare"])
        #expect(board.rows.map(\.title) == ["Main", "Claude only", APIKeyMask.masked("sk-spare-4444-5555")])
        #expect(board.rows.map(\.maskedSecret) == [
            APIKeyMask.masked("sk-primary-0000-1111"),
            APIKeyMask.masked("sk-claude-2222-3333"),
            APIKeyMask.masked("sk-spare-4444-5555"),
        ])
        #expect(board.rows.map(\.showsPrimaryBadge) == [true, false, false])
        #expect(board.rows.map { $0.statusKey as String? } == ["Active", "Invalid", nil], "A key never checked shows no status word")
        #expect(board.rows.map(\.catalogCount) == [2, 1, nil])
        #expect(board.rows.map(\.enabledCount) == [1, 2, 0])
        #expect(board.rows[0].lastStatus == nil, "Healthy writes no last status")
        #expect(board.rows[1].lastStatus == .init(httpStatus: 401, statusKey: "Invalid", checkedAt: Date(timeIntervalSince1970: 1_700_000_000)))
        #expect(board.rows[2].lastStatus == nil, "Unchecked has no status code")

        // The six status words map one to one; no probe is sent, only status is read.
        #expect(RelayKey.Status.State.allCases.map(Board.statusKey) == [
            "Active", "Invalid", "No access", "Out of credit or rate-limited", "Failed",
        ])
        #expect(Board.footnoteKey == "Key status comes from model list fetches and real requests, including capability tests.")
    }

    // MARK: - BOARD-KEYS-02

    @Test("BOARD-KEYS-02 implicit single key: one row, no name and no badge, only replace-key, going through the existing single-key replace path")
    func boardKeys02ImplicitSingle() throws {
        let provider = Self.relayProvider(models: [Self.model("gpt-4o")], catalog: [Self.model("gpt-4o")])
        let board = Board.make(provider)
        #expect(board.isSingle)
        #expect(board.keyCount == 1)
        #expect(board.rows.count == 1)
        let row = try #require(board.rows.first)
        #expect(row.title == APIKeyMask.masked("sk-primary-0000-1111"))
        #expect(!row.showsPrimaryBadge)
        #expect(row.actions == [.viewModels, .replaceSecret], "With a catalog, the first sheet item is view models")
        #expect(Board.replaceRoute(provider) == .singleKeySheet)
        #expect(Board.replaceRoute(Self.threeKeys()) == .keyOperation)
    }

    // MARK: - BOARD-KEYS-03

    @Test("BOARD-KEYS-03 add: optional name + key -> add, all keys refetch the catalog, and the primary key also gets a status and a lister")
    func boardKeys03Add() async throws {
        ProviderAPIKeyStore.useInMemoryBackendForTesting(true)
        defer { ProviderAPIKeyStore.useInMemoryBackendForTesting(false) }
        await MetadataClient.shared.resetForTesting()
        RelayKeysFakeServer.install { request in
            guard request.url?.path == "/v1/models" else { return (404, "") }
            switch request.value(forHTTPHeaderField: "Authorization") {
            case "Bearer sk-new-6666-7777": return (200, Self.catalogBody(["claude-opus-4", "gpt-4o"]))
            case "Bearer sk-primary-0000-1111": return (200, Self.catalogBody(["gpt-4o", "gpt-4.1"]))
            default: return (500, "unexpected")
            }
        }
        let state = Self.makeState()
        let provider = Self.relayProvider(
            models: [Self.model("gpt-4o")],
            catalog: [Self.model("gpt-4o"), Self.model("gpt-4.1")]
        )
        state.providers = [provider]

        let operation = try #require(Board.addOperation(id: "k-new", name: "  ", apiKey: " sk-new-6666-7777 "))
        #expect(operation == .add(id: "k-new", name: nil, apiKey: "sk-new-6666-7777"), "A blank name is stored as nil and the key is trimmed")
        #expect(Board.addOperation(id: "k-x", name: "x", apiKey: "   ") == nil, "Cannot add without a key")
        #expect(await state.providerManager.applyRelayKeyOperation(providerID: provider.id, operation))

        let requests = Self.modelsRequests()
        #expect(requests.map { $0.value(forHTTPHeaderField: "Authorization") } == [
            "Bearer sk-primary-0000-1111", "Bearer sk-new-6666-7777",
        ], "After adding a key, all keys refetch")
        let saved = try #require(state.provider(for: provider.id))
        #expect(saved.relayKeys?.map(\.id) == ["initial", "k-new"])
        #expect(saved.catalogModels.first { $0.id == "gpt-4.1" }?.relayListedByKeyIDs == ["initial"])
        #expect(saved.catalogModels.first { $0.id == "gpt-4o" }?.relayListedByKeyIDs == ["initial", "k-new"])
        #expect(saved.catalogModels.first { $0.id == "claude-opus-4" }?.relayListedByKeyIDs == ["k-new"])
        let board = Board.make(saved)
        #expect(board.rows.map(\.showsPrimaryBadge) == [true, false])
        #expect(board.rows.map { $0.statusKey as String? } == ["Active", "Active"])
    }

    // MARK: - BOARD-KEYS-04

    @Test("BOARD-KEYS-04 replace key: replaceSecret refetches only that key, and the catalog and enabled models are kept")
    func boardKeys04Replace() async throws {
        ProviderAPIKeyStore.useInMemoryBackendForTesting(true)
        defer { ProviderAPIKeyStore.useInMemoryBackendForTesting(false) }
        await MetadataClient.shared.resetForTesting()
        RelayKeysFakeServer.install { request in
            guard request.url?.path == "/v1/models" else { return (404, "") }
            return request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-claude-new-8888"
                ? (200, Self.catalogBody(["claude-opus-4"]))
                : (500, "unexpected")
        }
        let state = Self.makeState()
        let provider = Self.threeKeys()
        state.providers = [provider]

        let operation = try #require(Board.replaceOperation(id: "k-claude", apiKey: "sk-claude-new-8888"))
        #expect(await state.providerManager.applyRelayKeyOperation(providerID: provider.id, operation))

        let requests = Self.modelsRequests()
        #expect(requests.count == 1)
        #expect(requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer sk-claude-new-8888")
        let saved = try #require(state.provider(for: provider.id))
        #expect(saved.models.map(\.id) == provider.models.map(\.id), "Enabled models are kept")
        #expect(saved.models.map(\.relayKeyID) == provider.models.map(\.relayKeyID))
        #expect(saved.catalogModels.first { $0.id == "gpt-4.1" }?.relayListedByKeyIDs == ["initial"], "The other keys' catalog is kept")
        #expect(saved.catalogModels.contains { $0.id == "claude-opus-4" })
        #expect(saved.apiKey == "sk-primary-0000-1111")
        #expect(Board.make(saved).rows[1].statusKey == "Active")
        #expect(Board.make(saved).rows[1].lastStatus == nil)
    }

    // MARK: - BOARD-KEYS-05

    @Test("BOARD-KEYS-05 delete: the primary key cannot be deleted; for other keys the confirmation lists in-use models and rebinds them to the primary key, and delete happens after confirming")
    func boardKeys05Delete() async throws {
        RelayKeysFakeServer.install { _ in (404, "") }
        let state = Self.makeState()
        let provider = Self.threeKeys()
        state.providers = [provider]

        #expect(Board.deletePrompt(provider, keyID: "initial") == .primaryNotDeletable)
        #expect(Board.primaryNotDeletableKey == "To delete the primary key, move another key to the top first.")
        #expect(Board.deletePrompt(provider, keyID: "k-claude") == .confirm(
            modelNames: ["Claude Opus 4", "Claude Sonnet 4.5"],
            fallbackKeyTitle: "Main"
        ))
        #expect(Board.deletePrompt(provider, keyID: "k-spare") == .confirm(modelNames: [], fallbackKeyTitle: "Main"))
        // The list shows display names; a model without one uses its model id.
        var unnamed = provider
        unnamed.models[1].name = " "
        #expect(Board.deletePrompt(unnamed, keyID: "k-claude") == .confirm(
            modelNames: ["claude-opus-4", "Claude Sonnet 4.5"],
            fallbackKeyTitle: "Main"
        ))
        #expect(Board.make(provider).rows[0].actions.contains(.delete) == false, "The primary key's sheet has no delete")

        let operation = try #require(Board.operation(.delete, keyID: "k-claude", in: provider))
        #expect(operation == .delete(id: "k-claude"))
        #expect(await state.providerManager.applyRelayKeyOperation(providerID: provider.id, operation))
        let saved = try #require(state.provider(for: provider.id))
        #expect(saved.relayKeys?.map(\.id) == ["initial", "k-spare"])
        #expect(saved.models.filter { $0.id.hasPrefix("claude") }.map(\.relayKeyID) == ["initial", "initial"], "Models using it switch to the primary key")
        #expect(Self.modelsRequests().isEmpty, "Delete does not fetch the catalog")
    }

    // MARK: - BOARD-KEYS-06

    @Test("BOARD-KEYS-06 reorder: move up / down (the first has no move up, the last has no move down) -> move, and the first key is the primary key")
    func boardKeys06Move() async throws {
        let state = Self.makeState()
        let provider = Self.threeKeys()
        state.providers = [provider]
        let rows = Board.make(provider).rows
        #expect(rows[0].actions == [.viewModels, .rename, .replaceSecret, .moveDown])
        #expect(rows[1].actions == [.viewModels, .rename, .replaceSecret, .moveUp, .moveDown, .delete])
        #expect(rows[2].actions == [.rename, .replaceSecret, .moveUp, .delete])
        #expect(Board.operation(.moveUp, keyID: "initial", in: provider) == nil)
        #expect(Board.operation(.moveDown, keyID: "k-spare", in: provider) == nil)

        let operation = try #require(Board.operation(.moveUp, keyID: "k-claude", in: provider))
        #expect(operation == .move(id: "k-claude", toIndex: 0))
        #expect(await state.providerManager.applyRelayKeyOperation(providerID: provider.id, operation))
        let saved = try #require(state.provider(for: provider.id))
        #expect(saved.relayKeys?.map(\.id) == ["k-claude", "initial", "k-spare"])
        #expect(saved.apiKey == "sk-claude-2222-3333", "The first key is the primary key, and its value is in provider.apiKey")
        let board = Board.make(saved)
        #expect(board.rows.map(\.showsPrimaryBadge) == [true, false, false])
        #expect(board.rows[0].title == "Claude only")
        #expect(Board.deletePrompt(saved, keyID: "initial") == .confirm(modelNames: ["gpt-4o"], fallbackKeyTitle: "Claude only"))
    }

    // MARK: - BOARD-KEYS-07

    @Test("BOARD-KEYS-07 rename (2 or more keys) -> rename; clearing the name returns to the mask")
    func boardKeys07Rename() async throws {
        let state = Self.makeState()
        let provider = Self.threeKeys()
        state.providers = [provider]

        let operation = try #require(Board.renameOperation(id: "k-spare", name: "  Backup  "))
        #expect(operation == .rename(id: "k-spare", name: "Backup"))
        #expect(await state.providerManager.applyRelayKeyOperation(providerID: provider.id, operation))
        var saved = try #require(state.provider(for: provider.id))
        #expect(Board.make(saved).rows[2].title == "Backup")

        #expect(await state.providerManager.applyRelayKeyOperation(
            providerID: provider.id, try #require(Board.renameOperation(id: "k-spare", name: " "))
        ))
        saved = try #require(state.provider(for: provider.id))
        #expect(Board.make(saved).rows[2].title == APIKeyMask.masked("sk-spare-4444-5555"))
        #expect(Board.renameHintKey == "Only changes the display name. Bindings stay the same.")
    }

    // MARK: - RL2-KEYSTATUS-10

    @Test("RL2-KEYSTATUS-10 a never-checked key (status is nil): neither the keys page row nor the model library's per-key status bar draws a status word or marker; ok in a single-entry list -> healthy")
    func keyStatus10UncheckedDrawsNothing() throws {
        // Multiple keys: the third has never been checked.
        let multi = Board.make(Self.threeKeys())
        let unchecked = try #require(multi.rows.first { $0.id == "k-spare" })
        #expect(unchecked.state == nil)
        #expect(unchecked.statusKey as String? == nil, "No status word is drawn")
        #expect(unchecked.statusIcon as Board.StatusIcon? == nil, "No marker is drawn")
        #expect(unchecked.lastStatus == nil)
        let bar = try #require(RelayCatalogBoardModel.keyStatusBar(Self.threeKeys()))
        #expect(bar.first { $0.id == "k-spare" }?.state == .unchecked, "The tail of that row in the status bar is not drawn")
        #expect(bar.first { $0.id == "k-spare" }?.showsRetry == false)
        // While fetching, the spinner is unchanged.
        let fetching = Board.make(Self.threeKeys(), fetchingKeyIDs: ["k-spare"])
        #expect(fetching.rows[2].statusIcon as Board.StatusIcon? == .progress)
        #expect(fetching.rows[2].statusKey as String? == "Loading model list...")

        // Implicit single key: likewise not drawn.
        let implicit = Board.make(Self.relayProvider(models: [Self.model("gpt-4o")], catalog: [Self.model("gpt-4o")]))
        #expect(implicit.rows.map { $0.statusKey as String? } == [nil])

        // A single-entry list carrying ok: the single-key decision follows the fewer-than-2 rule (only replace-key, going through the single-key path), and the status is shown normally.
        let ok = RelayKey.Status(state: .ok, httpStatus: nil, checkedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let single = Self.relayProvider(
            models: [Self.model("gpt-4o")], catalog: [Self.model("gpt-4o")],
            keys: [RelayKey(id: "initial", status: ok)]
        )
        let board = Board.make(single)
        #expect(board.isSingle)
        #expect(board.rows.count == 1)
        #expect(board.rows[0].actions == [.viewModels, .replaceSecret])
        #expect(Board.replaceRoute(single) == .singleKeySheet)
        #expect(board.rows[0].statusKey as String? == "Active")
        #expect(board.rows[0].statusIcon as Board.StatusIcon? == .dot)
        #expect(RelayCatalogBoardModel.keyStatusBar(single) == nil, "Fewer than 2 keys has no status bar")

        // An unrecognized status value is treated as the default: decoding drops only the status, and the row draws nothing.
        let weird = try JSONDecoder().decode(
            RelayKey.self, from: Data(#"{"id":"k-x","apiKey":"sk-x","status":{"state":"weird","httpStatus":500}}"#.utf8)
        )
        #expect(weird.status == nil)
        let withWeird = Self.relayProvider(
            models: [Self.model("gpt-4o")], catalog: [Self.model("gpt-4o")],
            keys: [RelayKey(id: "initial", status: ok), weird]
        )
        let weirdRow = try #require(Board.make(withWeird).rows.first { $0.id == "k-x" })
        #expect(weirdRow.statusKey as String? == nil)
        #expect(weirdRow.statusIcon as Board.StatusIcon? == nil)
    }

    @Test("RL2-KEYSTATUS-06 keys page: while add refetches everything, every key being fetched spins; the outcome notice looks only at the newly added key")
    func keyStatus06PageAddSpinsEveryKey() throws {
        let provider = Self.relayProvider(models: [Self.model("gpt-4o")], catalog: [Self.model("gpt-4o")])
        var page = RelayKeysPageState()
        let add = try #require(Board.addOperation(id: "k-new", name: "", apiKey: "sk-new-6666-7777"))
        page.begin(add, provider: provider)
        #expect(page.fetchingKeyIDs == ["initial", "k-new"])

        var after = provider
        after.relayKeys = [
            RelayKey(id: "initial", status: .init(state: .failed, httpStatus: 500, checkedAt: nil)),
            RelayKey(id: "k-new", apiKey: "sk-new-6666-7777", status: .init(state: .ok, httpStatus: nil, checkedAt: nil)),
        ]
        let board = Board.make(after, fetchingKeyIDs: page.fetchingKeyIDs)
        #expect(board.rows.map { $0.statusIcon as Board.StatusIcon? } == [.progress, .progress])
        page.finish(add, accepted: true, provider: after)
        #expect(page.fetchingKeyIDs.isEmpty)
        #expect(page.notices.isEmpty, "The primary key failing to fetch is not this step's outcome: only the newly added key counts (healthy)")
    }

    // MARK: - BOARD-KEYS-08

    @Test("BOARD-KEYS-08 rows: a marker before the status word (healthy = dot, others = warning icon, unchecked = none), and the primary badge only on the first key")
    func boardKeys08StatusIconAndBadge() throws {
        let board = Board.make(Self.threeKeys())
        #expect(board.rows.map { $0.statusIcon as Board.StatusIcon? } == [.dot, .warning, nil])
        #expect(board.rows.map(\.showsPrimaryBadge) == [true, false, false])
        #expect(RelayKey.Status.State.allCases.map(Board.statusIcon) == [.dot, .warning, .warning, .warning, .warning])

        let single = Board.make(Self.relayProvider(models: [Self.model("gpt-4o")], catalog: [Self.model("gpt-4o")]))
        #expect(single.rows.map(\.showsPrimaryBadge) == [false], "A single key shows no badge")
        #expect(single.rows.map { $0.statusIcon as Board.StatusIcon? } == [nil], "Implicit single key never checked: no marker is drawn")
    }

    // MARK: - BOARD-KEYS-09

    @Test("BOARD-KEYS-09 \"Add key\" is the last row of the keys card; connections that need no credentials do not show it")
    func boardKeys09AddKeyIsLastRowOfTheCard() throws {
        let provider = Self.threeKeys()
        let board = Board.make(provider)
        #expect(board.showsAddKey)
        #expect(board.listItems == board.rows.map(Board.ListItem.key) + [.addKey])
        #expect(board.listItems.last == .addKey)
        #expect(Set(board.listItems.map(\.id)).count == board.listItems.count, "Row identifiers are unique")

        var noAuth = provider
        noAuth.relayRequested?.authMode = RelayAuthMode.none
        let noAuthBoard = Board.make(noAuth)
        #expect(!noAuthBoard.showsAddKey)
        #expect(noAuthBoard.listItems == noAuthBoard.rows.map(Board.ListItem.key))
    }

    // MARK: - BOARD-KEYS-10

    @Test("BOARD-KEYS-10 the primary key's sheet has no delete and its footnote says how it can be deleted; the action sets of the other keys; the explanation card lists the consequences of rename / replace key / delete")
    func boardKeys10PanelMessageAndActionNotes() throws {
        let board = Board.make(Self.threeKeys())
        let primary = board.rows[0]
        #expect(primary.actions == [.viewModels, .rename, .replaceSecret, .moveDown])
        #expect(!primary.actions.contains(.delete))
        #expect(primary.panelMessageKey == "To delete the primary key, move another key to the top first.")

        #expect(board.rows[1].actions == [.viewModels, .rename, .replaceSecret, .moveUp, .moveDown, .delete])
        #expect(board.rows[1].panelMessageKey == nil)
        #expect(board.rows[2].actions == [.rename, .replaceSecret, .moveUp, .delete])
        #expect(board.rows[2].panelMessageKey == nil)

        #expect(board.actionNotes == [
            Board.ActionNote(action: .rename, hintKey: "Only changes the display name. Bindings stay the same."),
            Board.ActionNote(action: .replaceSecret, hintKey: "Only this key’s model list is fetched again. The model library isn’t cleared."),
            Board.ActionNote(action: .delete, hintKey: "Models using it switch to the primary key. They’re listed before deleting."),
        ])

        // A single key can only be replaced, and the replace-key sheet explains itself: no explanation card is shown and the sheet has no explanation.
        let single = Board.make(Self.relayProvider(models: [Self.model("gpt-4o")], catalog: [Self.model("gpt-4o")]))
        #expect(single.actionNotes.isEmpty)
        #expect(single.rows[0].panelMessageKey == nil)
    }

    // MARK: - BOARD-KEYS-11

    @Test("BOARD-KEYS-11 after add / replace key while the catalog is still fetching: that row's status slot shows in-progress without carrying the previous failure; other rows are unchanged")
    func boardKeys11FetchingRow() throws {
        let provider = Self.threeKeys()
        let idle = Board.make(provider)
        let board = Board.make(provider, fetchingKeyIDs: ["k-claude"])
        #expect(board.rows.map { $0.statusIcon as Board.StatusIcon? } == [.dot, .progress, nil])
        #expect(board.rows[1].statusKey == "Loading model list...")
        #expect(board.rows[1].lastStatus == nil, "The previous 401 is not shown beside in-progress")
        #expect(board.rows[0] == idle.rows[0])
        #expect(board.rows[2] == idle.rows[2])

        // Only add and replace key fetch the catalog.
        #expect(Board.fetchedKeyID(.add(id: "k-new", name: nil, apiKey: "sk-x")) == "k-new")
        #expect(Board.fetchedKeyID(.replaceSecret(id: "k-claude", apiKey: "sk-x")) == "k-claude")
        #expect(Board.fetchedKeyID(.rename(id: "k-claude", name: "x")) == nil)
        #expect(Board.fetchedKeyID(.move(id: "k-claude", toIndex: 0)) == nil)
        #expect(Board.fetchedKeyID(.delete(id: "k-claude")) == nil)
    }

    // MARK: - BOARD-KEYS-12

    @Test("BOARD-KEYS-12 after replace key the catalog is rejected: the key is still saved, that row turns to a warning with the status code, the page shows one notice; a rejected operation is also accounted for")
    func boardKeys12FetchFailedAndRejectedNotice() async throws {
        ProviderAPIKeyStore.useInMemoryBackendForTesting(true)
        defer { ProviderAPIKeyStore.useInMemoryBackendForTesting(false) }
        await MetadataClient.shared.resetForTesting()
        RelayKeysFakeServer.install { request in
            guard request.url?.path == "/v1/models" else { return (404, "") }
            return request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-good-1212-3434"
                ? (200, Self.catalogBody(["gpt-4o"]))
                : (401, #"{"error":"Invalid API key"}"#)
        }
        let state = Self.makeState()
        let provider = Self.threeKeys()
        state.providers = [provider]

        let bad = try #require(Board.replaceOperation(id: "k-spare", apiKey: "sk-bad-9999-0000"))
        let badAccepted = await state.providerManager.applyRelayKeyOperation(providerID: provider.id, bad)
        #expect(badAccepted, "A rejected fetch does not roll back: the key is still saved")
        var saved = try #require(state.provider(for: provider.id))
        var row = try #require(Board.make(saved).rows.first { $0.id == "k-spare" })
        #expect(row.maskedSecret == APIKeyMask.masked("sk-bad-9999-0000"))
        #expect(row.state == .invalid)
        #expect(row.statusIcon == .warning)
        #expect(row.statusKey == "Invalid")
        #expect(row.lastStatus?.httpStatus == 401)
        #expect(Board.notice(accepted: badAccepted, operation: bad, provider: saved) == .fetchFailed)
        #expect(Board.Notice.fetchFailed.messageKey
            == "Key saved, but its model list couldn’t be fetched. See its status in the list.")

        // Then replace it with a working one: the row returns to healthy and the notice is gone.
        let good = try #require(Board.replaceOperation(id: "k-spare", apiKey: "sk-good-1212-3434"))
        let goodAccepted = await state.providerManager.applyRelayKeyOperation(providerID: provider.id, good)
        saved = try #require(state.provider(for: provider.id))
        row = try #require(Board.make(saved).rows.first { $0.id == "k-spare" })
        #expect(row.statusIcon == .dot)
        #expect(row.statusKey == "Active")
        #expect(Board.notice(accepted: goodAccepted, operation: good, provider: saved) == nil)

        // After an operation that does not fetch the catalog succeeds, there is no notice.
        #expect(Board.notice(accepted: true, operation: .rename(id: "k-spare", name: "x"), provider: saved) == nil)

        // The operation was not accepted (a nonexistent id here reaches that defensive branch): the page must not say nothing.
        let refused = RelayKeyBinding.Operation.replaceSecret(id: "k-missing", apiKey: "sk-x")
        let refusedAccepted = await state.providerManager.applyRelayKeyOperation(providerID: provider.id, refused)
        #expect(!refusedAccepted)
        #expect(Board.notice(accepted: refusedAccepted, operation: refused, provider: state.provider(for: provider.id)) == .rejected)
        #expect(Board.Notice.rejected.messageKey == "Couldn’t apply this change. Please try again.")
    }

    @Test("BOARD-KEYS-12 explicit list down to one key, replace with a good key: back to Active with no notice; replace with a bad key: Invalid + 401 + fetchFailed")
    func boardKeys12SingleExplicitKeyWritesStatus() async throws {
        ProviderAPIKeyStore.useInMemoryBackendForTesting(true)
        defer { ProviderAPIKeyStore.useInMemoryBackendForTesting(false) }
        await MetadataClient.shared.resetForTesting()
        RelayKeysFakeServer.install { request in
            guard request.url?.path == "/v1/models" else { return (404, "") }
            return request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-good-1212-3434"
                ? (200, Self.catalogBody(["gpt-4o"]))
                : (401, #"{"error":"Invalid API key"}"#)
        }
        let state = Self.makeState()
        // An explicit list deleted down to only the primary key: it takes the single-key refresh path but must still write that key's status.
        let provider = Self.relayProvider(
            models: [Self.model("gpt-4o", keyID: "initial")],
            catalog: [Self.model("gpt-4o", listedBy: ["initial"])],
            keys: [RelayKey(id: "initial", name: "Main",
                            status: .init(state: .ok, httpStatus: 200, checkedAt: Date(timeIntervalSince1970: 1_700_000_000)))]
        )
        state.providers = [provider]

        let bad = try #require(Board.replaceOperation(id: "initial", apiKey: "sk-bad-9999-0000"))
        let badAccepted = await state.providerManager.applyRelayKeyOperation(providerID: provider.id, bad)
        #expect(badAccepted)
        var saved = try #require(state.provider(for: provider.id))
        var row = try #require(Board.make(saved).rows.first { $0.id == "initial" })
        #expect(row.state == .invalid)
        #expect(row.statusKey == "Invalid")
        #expect(row.lastStatus?.httpStatus == 401)
        #expect(Board.notice(accepted: badAccepted, operation: bad, provider: saved) == .fetchFailed)

        let good = try #require(Board.replaceOperation(id: "initial", apiKey: "sk-good-1212-3434"))
        let goodAccepted = await state.providerManager.applyRelayKeyOperation(providerID: provider.id, good)
        saved = try #require(state.provider(for: provider.id))
        row = try #require(Board.make(saved).rows.first { $0.id == "initial" })
        #expect(row.statusKey == "Active")
        #expect(row.statusIcon == .dot)
        #expect(Board.notice(accepted: goodAccepted, operation: good, provider: saved) == nil)
    }

    // MARK: - BOARD-KEYS-14 / 15 in-flight page state

    @Test("BOARD-KEYS-14 page state: a single success says nothing, a single rejection is accounted for, two in-flight runs of the same key are counted by number, and only the last completion clears \"fetching\"")
    func boardKeys14PageStateSingleAndSameKeyTwice() async throws {
        ProviderAPIKeyStore.useInMemoryBackendForTesting(true)
        defer { ProviderAPIKeyStore.useInMemoryBackendForTesting(false) }
        await MetadataClient.shared.resetForTesting()
        RelayKeysFakeServer.install { request in
            guard request.url?.path == "/v1/models" else { return (404, "") }
            return request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-good-1212-3434"
                ? (200, Self.catalogBody(["gpt-4o"]))
                : (401, #"{"error":"Invalid API key"}"#)
        }
        let state = Self.makeState()
        let provider = Self.threeKeys()
        state.providers = [provider]
        var page = RelayKeysPageState()

        // Single success: fetching shows only while in flight, and after completion there is no notice.
        let good = try #require(Board.replaceOperation(id: "k-spare", apiKey: "sk-good-1212-3434"))
        page.begin(good)
        #expect(page.fetchingKeyIDs == ["k-spare"])
        let goodAccepted = await state.providerManager.applyRelayKeyOperation(providerID: provider.id, good)
        page.finish(good, accepted: goodAccepted, provider: state.provider(for: provider.id))
        #expect(page.fetchingKeyIDs.isEmpty)
        #expect(page.notices.isEmpty)

        // Single rejection: the production path returns false and the page says it did not take effect.
        let refused = RelayKeyBinding.Operation.replaceSecret(id: "k-missing", apiKey: "sk-x")
        page.begin(refused)
        let refusedAccepted = await state.providerManager.applyRelayKeyOperation(providerID: provider.id, refused)
        page.finish(refused, accepted: refusedAccepted, provider: state.provider(for: provider.id))
        #expect(page.fetchingKeyIDs.isEmpty, "The nonexistent key leaves no residual fetching")
        #expect(page.notices == [.rejected])

        // Two in-flight runs of the same key: the one that finishes first neither clears fetching nor reports early; the last one reports against the connection at completion time.
        let bad = try #require(Board.replaceOperation(id: "k-spare", apiKey: "sk-bad-9999-0000"))
        page.begin(good)
        page.begin(bad)
        #expect(page.notices.isEmpty, "When a new operation starts, the previous step's notice is withdrawn")
        #expect(page.fetchingKeyIDs == ["k-spare"])
        page.finish(good, accepted: true, provider: state.provider(for: provider.id))
        #expect(page.fetchingKeyIDs == ["k-spare"], "One run is still in flight")
        #expect(page.notices.isEmpty)
        let badAccepted = await state.providerManager.applyRelayKeyOperation(providerID: provider.id, bad)
        page.finish(bad, accepted: badAccepted, provider: state.provider(for: provider.id))
        #expect(page.fetchingKeyIDs.isEmpty)
        #expect(page.notices == [.fetchFailed])
        #expect(Board.make(try #require(state.provider(for: provider.id)), fetchingKeyIDs: page.fetchingKeyIDs)
            .rows.first { $0.id == "k-spare" }?.statusKey == "Invalid")
    }

    @Test("BOARD-KEYS-15 two interleaved keys: the fetch of the key replaced first gives up when the key replaced later takes the refresh ownership; both outcomes are reported without overwriting each other")
    func boardKeys15InterleavedKeysBothOutcomesKept() async throws {
        ProviderAPIKeyStore.useInMemoryBackendForTesting(true)
        defer { ProviderAPIKeyStore.useInMemoryBackendForTesting(false) }
        await MetadataClient.shared.resetForTesting()
        RelayKeysFakeServer.install { request in
            guard request.url?.path == "/v1/models" else { return (404, "") }
            return request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-good-1212-3434"
                ? (200, Self.catalogBody(["gpt-4o"]))
                : (401, #"{"error":"Invalid API key"}"#)
        }
        let state = Self.makeState()
        let provider = Self.threeKeys()
        state.providers = [provider]
        var page = RelayKeysPageState()

        let first = try #require(Board.replaceOperation(id: "k-spare", apiKey: "sk-good-1212-3434"))
        page.begin(first)
        let manager = state.providerManager
        let firstTask = Task { @MainActor in
            await manager.applyRelayKeyOperation(providerID: provider.id, first)
        }
        // Wait for the first key's refresh to take hold of the connection; then, in the same MainActor segment, issue the second key directly with no suspension point in between, so the interleaving is deterministic.
        let deadline = Date().addingTimeInterval(5)
        while !state.relayCatalogRefreshingProviderIDs.contains(provider.id) {
            try #require(Date() < deadline, "The first key's fetch did not start")
            await Task.yield()
        }
        // The later step uses replace (refetch only that key): add refetches everything, so the key replaced first would be fetched by it too and nothing would be "given up".
        let second = try #require(Board.replaceOperation(id: "k-claude", apiKey: "sk-bad-9999-0000"))
        page.begin(second)
        #expect(page.fetchingKeyIDs == ["k-spare", "k-claude"])
        let secondAccepted = await manager.applyRelayKeyOperation(providerID: provider.id, second)
        page.finish(second, accepted: secondAccepted, provider: state.provider(for: provider.id))
        let firstAccepted = await firstTask.value
        page.finish(first, accepted: firstAccepted, provider: state.provider(for: provider.id))

        let saved = try #require(state.provider(for: provider.id))
        #expect(firstAccepted, "The key is still saved; only the fetch was given up")
        #expect(saved.relayKeys?.first { $0.id == "k-spare" }?.status == nil, "The given-up run wrote no status back")
        #expect(saved.relayKeys?.first { $0.id == "k-claude" }?.status?.state == .invalid)
        #expect(page.fetchingKeyIDs.isEmpty)
        #expect(page.notices == [.fetchFailed, .fetchInterrupted])
        #expect(Board.Notice.fetchInterrupted.messageKey
            == "Key saved, but fetching its model list was interrupted by another change. Use Detect again to fetch it.")
    }

    // MARK: - BOARD-KEYS-16 / 17 / 18 view models by key

    @Test("BOARD-KEYS-16 the sheet puts viewModels first with the number being that key's catalog count; a key with an empty catalog omits it; an implicit single key has it too")
    func boardKeys16ViewModelsAction() throws {
        let board = Board.make(Self.threeKeys())
        #expect(board.rows[0].actions == [.viewModels, .rename, .replaceSecret, .moveDown])
        #expect(board.rows[1].actions == [.viewModels, .rename, .replaceSecret, .moveUp, .moveDown, .delete])
        #expect(board.rows[2].catalogCount == nil)
        #expect(board.rows[2].actions == [.rename, .replaceSecret, .moveUp, .delete], "A key with an empty catalog omits it")
        #expect(board.rows.map(\.catalogCount) == [2, 1, nil])
        #expect(Board.viewModelsActionKey == "View models (%lld)")

        let single = Board.make(Self.relayProvider(models: [Self.model("gpt-4o")], catalog: [Self.model("gpt-4o")]))
        #expect(single.isSingle)
        #expect(single.rows[0].actions == [.viewModels, .replaceSecret], "An implicit single key has it too")
        let emptySingle = Board.make(Self.relayProvider(models: [], catalog: []))
        #expect(emptySingle.rows[0].actions == [.replaceSecret])
        // The explanation card does not gain a row because of it.
        #expect(!board.actionNotes.map(\.action).contains(.viewModels))
    }

    @Test("BOARD-KEYS-17 add-success notice added(N,M): N = this key's catalog count, M = listed only by it; M of 0 gets no \"new\"; replace / N of 0 say nothing; mutually exclusive with the three warnings")
    func boardKeys17AddedNotice() async throws {
        ProviderAPIKeyStore.useInMemoryBackendForTesting(true)
        defer { ProviderAPIKeyStore.useInMemoryBackendForTesting(false) }
        await MetadataClient.shared.resetForTesting()
        RelayKeysFakeServer.install { request in
            guard request.url?.path == "/v1/models" else { return (404, "") }
            switch request.value(forHTTPHeaderField: "Authorization") {
            case "Bearer sk-primary-0000-1111": return (200, Self.catalogBody(["gpt-4o", "gpt-4.1"]))
            case "Bearer sk-claude-2222-3333": return (200, Self.catalogBody(["claude-opus-4"]))
            case "Bearer sk-spare-4444-5555": return (200, Self.catalogBody(["gpt-4.1"]))
            case "Bearer sk-new-6666-7777": return (200, Self.catalogBody(["gpt-4o", "claude-opus-4", "new-a", "new-b"]))
            case "Bearer sk-dup-8888-9999": return (200, Self.catalogBody(["gpt-4o"]))
            default: return (401, #"{"error":"Invalid API key"}"#)
            }
        }
        let state = Self.makeState()
        let provider = Self.threeKeys()
        state.providers = [provider]
        var page = RelayKeysPageState()

        func run(_ operation: RelayKeyBinding.Operation) async {
            page.begin(operation, provider: state.provider(for: provider.id))
            let accepted = await state.providerManager.applyRelayKeyOperation(providerID: provider.id, operation)
            page.finish(operation, accepted: accepted, provider: state.provider(for: provider.id))
        }

        // It lists 4, of which new-a / new-b are listed only by it.
        await run(try #require(Board.addOperation(id: "k-new", name: "", apiKey: "sk-new-6666-7777")))
        #expect(page.notices == [.added(keyID: "k-new", listed: 4, new: 2)])
        let added = try #require(page.notices.first)
        #expect(added.isSuccess)
        #expect(added.modelsKeyID == "k-new")
        #expect(Board.noticeText(added) == "Key added · Lists 4 models · 2 new")

        // Only entries that other keys also list: M = 0, no "new".
        await run(try #require(Board.addOperation(id: "k-dup", name: "", apiKey: "sk-dup-8888-9999")))
        #expect(page.notices == [.added(keyID: "k-dup", listed: 1, new: 0)])
        #expect(Board.noticeText(try #require(page.notices.first)) == "Key added · Lists 1 model")

        // Add but the catalog is rejected: only fetchFailed, no added.
        await run(try #require(Board.addOperation(id: "k-bad", name: "", apiKey: "sk-bad-9999-0000")))
        #expect(page.notices == [.fetchFailed])
        #expect(!Board.Notice.fetchFailed.isSuccess)
        #expect(Board.Notice.fetchFailed.modelsKeyID == nil)

        // Replace key succeeds: nothing is said.
        await run(try #require(Board.replaceOperation(id: "k-spare", apiKey: "sk-spare-4444-5555")))
        #expect(page.notices.isEmpty)

        // N == 0: the fetch writes back ok but this key lists no entries, so nothing is said.
        var empty = try #require(state.provider(for: provider.id))
        empty.relayKeys = (empty.relayKeys ?? []) + [RelayKey(id: "k-zero", apiKey: "sk-zero", status: .init(state: .ok, httpStatus: 200, checkedAt: Date()))]
        #expect(Board.notice(accepted: true, operation: .add(id: "k-zero", name: nil, apiKey: "sk-zero"), provider: empty) == nil)
        // A rejection is still rejected.
        #expect(Board.notice(accepted: false, operation: .add(id: "k-zero", name: nil, apiKey: "sk-zero"), provider: empty) == .rejected)
    }

    @Test("BOARD-KEYS-18 sheet items and notice links both open the model library with key(id) (pushed on top of the keys page, and going back returns to the keys page)")
    func boardKeys18BothEntriesOpenLibraryByKey() throws {
        let provider = Self.threeKeys()
        let state = Self.makeState()
        state.providers = [provider]
        let keysPath: [AppRoute] = [.providerDetail(providerID: provider.id), .relayKeys(providerID: provider.id)]

        // Sheet item: that row's id.
        state.navigation.reset(to: keysPath)
        let row = Board.make(provider).rows[1]
        #expect(row.actions.first == .viewModels)
        Board.openModels(keyID: row.id, providerID: provider.id, in: state)
        #expect(state.navigation.path == keysPath + [.relayModelLibrary(providerID: provider.id, keyID: "k-claude")])
        state.pop()
        #expect(state.navigation.path == keysPath, "Going back returns to the keys page")

        // Notice link: the key carried in the notice.
        let notice = Board.Notice.added(keyID: "k-claude", listed: 1, new: 1)
        Board.openModels(keyID: try #require(notice.modelsKeyID), providerID: provider.id, in: state)
        #expect(state.navigation.path == keysPath + [.relayModelLibrary(providerID: provider.id, keyID: "k-claude")])

        // Both entry points in the view go through the same jump.
        let source = try Self.productionSource("Features/Providers/RelayKeysPage.swift")
        #expect(source.components(separatedBy: "Board.openModels(").count - 1 == 2)
        #expect(source.contains("case .viewModels:"))
    }

    private static func productionSource(_ relative: String) throws -> String {
        try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Oriveo/\(relative)"),
            encoding: .utf8
        )
    }

    // MARK: - BOARD-KEYS-13

    @Test("BOARD-KEYS-13 the three input-sheet modes: header title, fields and explanation; a field's title and its placeholder are not the same sentence")
    func boardKeys13InputSheets() throws {
        let add = Board.inputSheet(.add)
        #expect(add.titleKey == "Add key")
        #expect(add.titleTable == .providers)
        #expect(add.fields.map(\.kind) == [.name, .secret])
        #expect(add.fields.map(\.titleKey) == ["Name (optional)", "API Key"])
        #expect(add.hintKey == nil)

        let replace = Board.inputSheet(.replace)
        #expect(replace.titleKey == "Replace key")
        #expect(replace.fields.map(\.kind) == [.secret])
        #expect(replace.hintKey == Board.replaceHintKey)

        // Rename: the placeholder of the name slot is this key's mask, which that row shows once the name is cleared.
        let masked = try #require(Board.make(Self.threeKeys()).rows.first { $0.id == "k-claude" }?.maskedSecret)
        let rename = Board.inputSheet(.rename, maskedSecret: masked)
        #expect(rename.titleKey == "Rename")
        #expect(rename.titleTable == .localizable)
        #expect(rename.fields.map(\.kind) == [.name])
        #expect(rename.fields.first?.placeholder == APIKeyMask.masked("sk-claude-2222-3333"))
        #expect(rename.hintKey == Board.renameHintKey)

        for sheet in [add, replace, rename] {
            for field in sheet.fields {
                #expect(field.placeholder != field.titleKey, "The placeholder of \"\(field.titleKey)\" in \(sheet.titleKey) is the same sentence as its title")
                #expect(field.titleKey != sheet.titleKey, "A field title does not repeat the header")
            }
        }
    }
}

/// Fake upstream: answers per request and records all requests.
private final class RelayKeysFakeServer: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: ((URLRequest) -> (Int, String))?
    nonisolated(unsafe) private static var requests: [URLRequest] = []

    static func install(_ value: @escaping (URLRequest) -> (Int, String)) {
        lock.withLock {
            handler = value
            requests = []
        }
    }

    static func captured() -> [URLRequest] {
        lock.withLock { requests }
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RelayKeysFakeServer.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let (code, body): (Int, String) = Self.lock.withLock {
            Self.requests.append(request)
            return Self.handler?(request) ?? (404, "")
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: code,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
