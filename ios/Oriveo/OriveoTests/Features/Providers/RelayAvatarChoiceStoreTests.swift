import Foundation
import Testing
@testable import Oriveo

/// On-device relay avatar choices (`RelayAvatarChoiceStore`) and the "Change icon" sheet on the detail page.
@Suite("Relay avatar · on-device choice and detail page sheet")
@MainActor
struct RelayAvatarChoiceStoreTests {
    /// Releasing AppState touches async tasks that are still in flight, so keep it alive for the duration of the tests (same approach as the negative cache tests).
    private static var retainedStates: [AppState] = []

    private static func makeStore() -> (RelayAvatarChoiceStore, UserDefaults) {
        let suite = "relay-avatar-choice-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (RelayAvatarChoiceStore(defaults: defaults), defaults)
    }

    private static func relay(url: String = "https://r1.example.com", name: String = "Relay one") -> Provider {
        var provider = TestFactories.makeProvider(kind: .relay, baseURLText: url, customName: name)
        provider.relayRequested = RelayRequestedConfig(transport: .openaiChatCompletions, authMode: .bearer)
        return provider
    }

    private static func content(_ provider: Provider, _ store: RelayAvatarChoiceStore) -> ConnectionAvatarIcon.Content {
        ConnectionAvatarIcon.content(provider: provider, kind: .relay, relayKind: provider.relayKind, choices: store)
    }

    // MARK: - RELAY-AVATAR-STORE

    @Test("RELAY-AVATAR-STORE-01 after picking an icon, the same connection resolves to it in the unified avatar entry and the message header, and it survives a relaunch")
    func store01PickIcon() throws {
        let (store, defaults) = Self.makeStore()
        let provider = Self.relay()
        let defaultIcon = RelayAvatarResolver.defaultIcon(providerID: provider.id.uuidString)
        #expect(Self.content(provider, store) == .relay(.icon(defaultIcon)))

        let picked: RelayAvatarIcon = defaultIcon == .kite ? .hotAirBalloon : .kite
        let revision = store.revision
        store.select(.icon(picked), for: provider.id)
        #expect(store.choice(for: provider.id) == picked.id)
        #expect(store.revision != revision)
        #expect(Self.content(provider, store) == .relay(.icon(picked)))
        // Message header: the production lookup carries the on-device choice.
        let lookup = ModelDisplayLookup(providers: [provider], relayAvatarChoices: store.choices)
        #expect(lookup.relayAvatar(providerID: provider.id, providerKind: .relay) == .icon(picked))
        // A changed choice changes the lookup fingerprint, which is what makes the chat page rebuild.
        #expect(
            ModelDisplayLookup.fingerprint(providers: [provider], relayAvatarChoices: store.choices)
                != ModelDisplayLookup.fingerprint(providers: [provider], relayAvatarChoices: [:])
        )
        // Stored only in the local key-value store, keyed by connection id.
        #expect(RelayAvatarChoiceStore(defaults: defaults).choice(for: provider.id) == picked.id)

        store.select(.letter("R"), for: provider.id)
        #expect(store.choice(for: provider.id) == "letter")
        #expect(Self.content(provider, store) == .relay(.initial("R")))
    }

    @Test("RELAY-AVATAR-STORE-02 picking the brand cell deletes the stored choice and returns to the brand image")
    func store02PickBrandDeletesChoice() throws {
        let (store, defaults) = Self.makeStore()
        let provider = Self.relay(url: "https://openrouter.ai/api/v1", name: "My backup")
        store.select(.icon(.kite), for: provider.id)
        #expect(Self.content(provider, store) == .relay(.icon(.kite)))

        let brandCell = try #require(RelayAvatarPicker.cells(for: provider).first)
        #expect(brandCell == .brand(try #require(RelayAvatarResolver.brands.first { $0.id == "openrouter" })))
        store.select(brandCell, for: provider.id)
        #expect(store.choice(for: provider.id) == nil)
        #expect(store.choices[provider.id.uuidString] == nil)
        #expect(defaults.dictionary(forKey: RelayAvatarChoiceStore.storageKey)?[provider.id.uuidString] == nil)
        #expect(Self.content(provider, store) == .relay(.brand("ProviderOpenRouter")))
    }

    @Test("RELAY-AVATAR-STORE-03 deleting a connection clears its choice and leaves other connections alone")
    func store03DeleteConnectionClearsChoice() throws {
        let provider = Self.relay()
        let other = Self.relay(name: "Other")
        let store = RelayAvatarChoiceStore.shared
        defer {
            store.deleteConnection(provider.id)
            store.deleteConnection(other.id)
        }
        let state = AppState(seedDemoData: false, sessionUID: "relay-avatar-choice-\(UUID().uuidString)")
        Self.retainedStates.append(state)
        state.providers = [provider, other]
        store.select(.icon(.paperPlane), for: provider.id)
        store.select(.icon(.signalTower), for: other.id)

        #expect(state.providerManager.removeProvider(provider.id))
        #expect(store.choice(for: provider.id) == nil)
        #expect(store.choice(for: other.id) == "signal-tower")
    }

    // MARK: - BOARD-AVATAR-PICKER

    @Test("BOARD-AVATAR-PICKER-01 the detail header avatar is a button that opens the Change icon sheet; local connections have none")
    func boardPicker01AvatarOpensPicker() throws {
        let relayBoard = try #require(RelayDetailBoardModel.make(Self.relay()))
        #expect(relayBoard.canChangeAvatar)
        var local = TestFactories.makeProvider(kind: .relay, baseURLText: "http://192.168.1.20:8080", customName: "Box")
        local.relayRequested = RelayRequestedConfig(
            transport: .openaiChatCompletions,
            authMode: .none,
            securityMode: .localHTTP,
            engineProfile: "ollama"
        )
        #expect(try #require(RelayDetailBoardModel.make(local)).canChangeAvatar == false)
        #expect(RelayDetailBoardModel.changeIconKey == "Change icon")
        #expect(RelayAvatarPicker.letterKey == "Letter")

        // The avatar button's accessibility label uses the same key as the sheet title, and tapping it presents the sheet.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Features/Providers
            .deletingLastPathComponent()   // Features
            .deletingLastPathComponent()   // OriveoTests
            .deletingLastPathComponent()   // Oriveo
            .appendingPathComponent("Oriveo")
        let view = try String(
            contentsOf: root.appendingPathComponent("Features/Providers/RelayDetailBoardView.swift"),
            encoding: .utf8
        ).filter { !$0.isWhitespace }
        #expect(view.contains("Button(action:{showAvatarPicker=true})"))
        #expect(view.contains(".accessibilityLabel(L10n.tr(RelayDetailBoardModel.changeIconKey,table:.providers))"))
        #expect(view.contains("RelayAvatarPickerSheet(provider:provider)"))
    }

    @Test("BOARD-AVATAR-PICKER-02 tapping a cell immediately changes the selected cell and the detail header")
    func boardPicker02PickUpdatesHeader() throws {
        let (store, _) = Self.makeStore()
        let provider = Self.relay(url: "https://openrouter.ai/api/v1", name: "My backup")
        let cells = RelayAvatarPicker.cells(for: provider)
        #expect(RelayAvatarPicker.selectedCell(in: cells, provider: provider, choices: store) == cells.first)

        let balloon = RelayAvatarPickerCell.icon(.hotAirBalloon)
        RelayAvatarPicker.select(balloon, provider: provider, choices: store)
        #expect(RelayAvatarPicker.selectedCell(in: cells, provider: provider, choices: store) == balloon)
        // The detail header draws what the unified entry resolves from the on-device choice; the board model follows the same rule.
        #expect(Self.content(provider, store) == .relay(.icon(.hotAirBalloon)))
        let board = try #require(RelayDetailBoardModel.make(provider, avatarChoice: store.choice(for: provider.id)))
        #expect(board.avatar == .icon(.hotAirBalloon))

        let letter = try #require(cells.last)
        #expect(letter == .letter("M"))
        RelayAvatarPicker.select(letter, provider: provider, choices: store)
        #expect(RelayAvatarPicker.selectedCell(in: cells, provider: provider, choices: store) == letter)
        #expect(Self.content(provider, store) == .relay(.initial("M")))
    }
}
