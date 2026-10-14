import Foundation
import Testing
@testable import Oriveo

/// Chat "switch key" (contract card B7): derived from the persisted `relayDeniedKeyID` and the alternates,
/// with no new field on messages; the selection is written back through the production `rebind` and never resends automatically.
@Suite("Relay 2.0 · chat switch key", .serialized)
@MainActor
struct RelaySwitchKeyTests {
    nonisolated(unsafe) private static var retainedStates: [AppState] = []

    /// Both keys list claude-opus-4; it is bound to the primary key, which has been judged unauthorized.
    private static func provider(deniedKeyID: String?, alternates: Bool) -> Provider {
        var enabled = TestFactories.makeModel(id: "claude-opus-4", name: "Claude Opus 4")
        enabled.relayTransport = .openaiChatCompletions
        enabled.relayTransportSource = .user
        enabled.relayDeniedKeyID = deniedKeyID
        var catalog = TestFactories.makeModel(id: "claude-opus-4", name: "Claude Opus 4")
        catalog.relayListedByKeyIDs = alternates ? ["initial", "k-claude"] : ["initial"]
        var provider = TestFactories.makeProvider(
            kind: .relay,
            models: [enabled],
            catalogModels: [catalog],
            apiKey: "sk-primary-0000-1111",
            apiKeyPreview: "sk-p…1111",
            baseURLText: "https://relay.example.com/v1"
        )
        provider.relayRequested = RelayRequestedConfig(
            transport: .openaiChatCompletions, authMode: .bearer, securityMode: .remoteHTTPS
        )
        provider.relayKeys = [
            RelayKey(id: "initial", name: "Main"),
            RelayKey(id: "k-claude", apiKey: "sk-claude-2222-3333"),
        ]
        return provider
    }

    private static func failedMessage(providerID: UUID, modelID: String = "claude-opus-4") -> ChatMessage {
        var message = ChatMessage(
            id: UUID(),
            role: .assistant,
            text: "",
            providerKind: .relay,
            providerName: "Relay",
            modelName: "Claude Opus 4",
            state: .failed
        )
        message.providerID = providerID
        message.modelID = modelID
        return message
    }

    @Test("CHAT-SWITCHKEY-01 unauthorized with an alternate -> the error area shows \"Switch key\" and the panel lists the alternate; selecting writes back through production rebind without resending; with no alternate it is absent")
    func chatSwitchKey01() async throws {
        let provider = Self.provider(deniedKeyID: "initial", alternates: true)
        let message = Self.failedMessage(providerID: provider.id)

        let offer = try #require(RelaySwitchKey.offer(for: message, providers: [provider]))
        #expect(offer.providerID == provider.id)
        #expect(offer.modelID == "claude-opus-4")
        #expect(offer.modelName == "Claude Opus 4")
        let keyRows = RelayKeysBoardModel.make(provider).rows
        #expect(offer.options.map(\.id) == ["k-claude"])
        #expect(offer.options.map(\.title) == [keyRows[1].title])
        #expect(offer.options.map(\.maskedSecret) == [keyRows[1].maskedSecret])
        #expect(RelaySwitchKey.titleKey == "Use another key for %@")
        #expect(RelaySwitchKey.hintKey == "These keys list this model. Send again after switching.")
        #expect(RelaySwitchKey.buttonKey == "Switch key")

        // Error area: the failure card's actions include "Switch key", and retry is still there (the user taps retry themselves).
        let layout = resolveMessageRecoveryCardActionLayout(for: .failed, shouldOfferModelSwitch: true, offersSwitchKey: true)
        #expect(layout.primary == .retry)
        #expect([layout.secondary, layout.tertiary].contains(.switchKey))
        #expect(localizedMessageRecoveryActionTitle(.switchKey) == L10n.tr("Switch key", table: .providers))
        // Takes the "edit message" slot.
        #expect(layout == .init(primary: .retry, secondary: .switchKey, tertiary: .switchModel))
        // No edit slot (a relay image rejection is a local action -> only switch model): fill the first free slot.
        let noEdit = resolveMessageRecoveryCardActionLayout(
            for: .failed, shouldOfferModelSwitch: true, offersSwitchKey: true,
            recoveryPrimaryAction: relayImageUnsupportedRecoveryAction
        )
        #expect(noEdit == .init(primary: .switchModel, secondary: .switchKey, tertiary: nil))
        let plainLayout = resolveMessageRecoveryCardActionLayout(for: .failed, shouldOfferModelSwitch: true)
        #expect(![plainLayout.primary, plainLayout.secondary, plainLayout.tertiary].contains(.switchKey))

        // Selection: production rebind writes back, the unauthorized marker is cleared with the rebinding and the button goes away; no request is sent and the message is untouched.
        let state = AppState(seedDemoData: false, sessionUID: "relay-switch-key-\(UUID().uuidString)")
        state.providers = [provider]
        Self.retainedStates.append(state)
        #expect(await RelaySwitchKey.select(offer, keyID: "k-claude", manager: state.providerManager))
        let current = try #require(state.provider(for: provider.id))
        let stored = try JSONDecoder().decode(Provider.self, from: JSONEncoder().encode(current))
        #expect(stored.models.first?.relayKeyID == "k-claude")
        #expect(stored.models.first?.relayDeniedKeyID == nil)
        #expect(RelaySwitchKey.offer(for: message, providers: [stored]) == nil)
        #expect(message.state == .failed)

        // No alternate, not judged unauthorized, not a failed message, model no longer among the enabled ones: none of these show it.
        #expect(RelaySwitchKey.offer(for: message, providers: [Self.provider(deniedKeyID: "initial", alternates: false)]) == nil)
        #expect(RelaySwitchKey.offer(for: message, providers: [Self.provider(deniedKeyID: nil, alternates: true)]) == nil)
        var delivered = message
        delivered.state = .delivered
        #expect(RelaySwitchKey.offer(for: delivered, providers: [provider]) == nil)
        #expect(RelaySwitchKey.offer(for: Self.failedMessage(providerID: provider.id, modelID: "gone"), providers: [provider]) == nil)
    }
}
