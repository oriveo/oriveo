import Foundation
import Testing
@testable import Oriveo

/// Relay detail sub-pages are real navigation levels: the model library / keys page / model advanced page are all
/// `AppRoute`s pushed onto the existing `NavigationStack`, and going back (button or left-edge swipe) pops exactly one level at a time.
@Suite("Relay 2.0 · detail sub-page navigation levels")
@MainActor
struct RelayDetailNavigationTests {

    private static func detailState() -> (AppState, UUID) {
        let state = AppState(seedDemoData: false, sessionUID: "relay-nav-\(UUID().uuidString)")
        let id = UUID()
        state.navigation.reset(to: [.providerDetail(providerID: id)])
        return (state, id)
    }

    @Test("NAV-RELAY-01 detail -> model library -> advanced, two pops return to detail")
    func navRelay01LibraryThenAdvanced() {
        let (state, id) = Self.detailState()
        state.openRelayModelLibrary(providerID: id)
        #expect(state.navigation.path.last == .relayModelLibrary(providerID: id))
        state.openRelayModelAdvanced(providerID: id, modelID: "gpt-4o", readOnly: false)
        #expect(state.navigation.path == [
            .providerDetail(providerID: id),
            .relayModelLibrary(providerID: id),
            .relayModelAdvanced(providerID: id, modelID: "gpt-4o", readOnly: false),
        ])

        state.pop()
        #expect(state.navigation.path.last == .relayModelLibrary(providerID: id))
        state.pop()
        #expect(state.navigation.path == [.providerDetail(providerID: id)])
    }

    @Test("NAV-RELAY-02 detail -> keys, one pop returns to detail")
    func navRelay02Keys() {
        let (state, id) = Self.detailState()
        state.openRelayKeys(providerID: id)
        #expect(state.navigation.path == [.providerDetail(providerID: id), .relayKeys(providerID: id)])
        state.pop()
        #expect(state.navigation.path == [.providerDetail(providerID: id)])
    }

    @Test("NAV-RELAY-03 tapping a catalog row in the model library enters read-only advanced, one pop returns to the model library")
    func navRelay03ReadOnlyAdvanced() {
        let (state, id) = Self.detailState()
        state.openRelayModelLibrary(providerID: id)
        state.openRelayModelAdvanced(providerID: id, modelID: "claude-sonnet-4-5", readOnly: true)
        #expect(state.navigation.path.last == .relayModelAdvanced(providerID: id, modelID: "claude-sonnet-4-5", readOnly: true))
        state.pop()
        #expect(state.navigation.path == [.providerDetail(providerID: id), .relayModelLibrary(providerID: id)])
    }

    @Test("NAV-RELAY back affordances on sub-pages only call pop and no longer toggle @State inside the detail page")
    func subpagesPopTheStack() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Features/Providers
            .deletingLastPathComponent()   // Features
            .deletingLastPathComponent()   // OriveoTests
            .deletingLastPathComponent()   // Oriveo
            .appendingPathComponent("Oriveo/Features/Providers")
        let detail = try String(contentsOf: root.appendingPathComponent("ProviderDetailView.swift"), encoding: .utf8)
        #expect(!detail.contains("showsModelLibrary = "), "The model library must no longer be an @State toggle inside the detail page")
        #expect(!detail.contains("advancedModelID = "), "Model advanced must no longer be an @State toggle inside the detail page")
        #expect(detail.contains("openRelayModelLibrary(providerID:"))
        #expect(detail.contains("openRelayModelAdvanced(providerID:"))
        #expect(detail.contains("openRelayKeys(providerID:"))
    }

    @Test("NAV-RELAY-04 connection recovery card: the key action enters the keys page and edit-connection opens the edit page, no longer opening the single-key sheet")
    func navRelay04RecoveryCardRoutes() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Oriveo/Features/Providers")
        let detail = try String(contentsOf: root.appendingPathComponent("ProviderDetailView.swift"), encoding: .utf8)
        let start = try #require(detail.range(of: "RelayDetailRecoveryCard("))
        let end = try #require(detail.range(of: "ProviderConnectionIssueRecoveryCard(", range: start.upperBound..<detail.endIndex))
        let card = String(detail[start.lowerBound..<end.lowerBound])
        #expect(card.contains("apiKeys: { appState.openRelayKeys(providerID: provider.id) }"))
        #expect(card.contains("editConnection: { showEditRelay = true }"))
        // Re-verification goes through an in-flight latch, and the real verification request lives inside the latch; nothing else may sit between the label and the closure.
        let reverify = try #require(card.range(of: "reverify: {"))
        let tail = card[reverify.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(tail.hasPrefix("reverifyRunner.tap {"))
        #expect(tail.contains("await runResync(providerID: provider.id)"))
        #expect(!card.contains("showEditAPIKey"), "With several keys the single-key sheet would only change the primary key")

        // Whether the card shows and which actions it has depends only on the board row model; the keys page itself is one page in the navigation hierarchy.
        let (state, id) = Self.detailState()
        state.openRelayKeys(providerID: id)
        #expect(state.navigation.path == [.providerDetail(providerID: id), .relayKeys(providerID: id)])
    }
}
