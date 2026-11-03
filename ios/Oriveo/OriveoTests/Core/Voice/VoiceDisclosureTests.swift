import Foundation
import Testing
@testable import Oriveo

/// Cloud voice disclosure consent storage and the engine sheet's selection flow.
@Suite("Voice disclosure")
struct VoiceDisclosureTests {

    private static func makeDefaults() -> (UserDefaults, String) {
        let suiteName = "VoiceDisclosureTests-\(UUID().uuidString)"
        return (UserDefaults(suiteName: suiteName)!, suiteName)
    }

    private static let catalog = VoiceCatalogDecoder.decode([
        "providers": [
            "openAI": [
                "stt": [[
                    "model": "gpt-4o-transcribe",
                    "transport": "openai_transcriptions",
                    "path": "/v1/audio/transcriptions",
                    "maxBytes": 25_000_000,
                    "maxDurationSec": 600,
                ]],
                "tts": [[
                    "model": "gpt-4o-mini-tts",
                    "transport": "openai_speech",
                    "path": "/v1/audio/speech",
                    "outputFormat": "mp3",
                    "maxChars": 4096,
                    "voices": [["id": "alloy"], ["id": "nova", "isDefault": true]],
                ]],
            ],
        ],
    ] as [String: Any])

    private static let sttOption = VoiceEngineOption.cloud(
        providerKind: .openAI, connectionID: "o1", model: "gpt-4o-transcribe", isDefault: true
    )
    private static let ttsOption = VoiceEngineOption.cloud(
        providerKind: .openAI, connectionID: "o1", model: "gpt-4o-mini-tts", isDefault: true
    )
    private static let sttEngine = VoiceCloudEngine(providerKind: .openAI, connectionID: "o1", model: "gpt-4o-transcribe")
    private static let ttsEngine = VoiceCloudEngine(
        providerKind: .openAI, connectionID: "o1", model: "gpt-4o-mini-tts", voice: "nova"
    )

    private struct Harness {
        let defaults: UserDefaults
        let suiteName: String
        let settings: VoiceEngineSettings
        let store: VoiceDisclosureStore
        let chooser: VoiceEngineChooser

        init() {
            let made = VoiceDisclosureTests.makeDefaults()
            defaults = made.0
            suiteName = made.1
            settings = VoiceEngineSettings(defaults: defaults)
            store = VoiceDisclosureStore(defaults: defaults)
            chooser = VoiceEngineChooser(settings: settings, disclosures: store)
        }

        func tearDown() {
            defaults.removePersistentDomain(forName: suiteName)
        }
    }

    @Test("Consent is recorded per (providerKind, direction) independently, and stored separately from the send-message disclosure")
    func consentIsPerKindAndDirection() {
        let h = Harness()
        defer { h.tearDown() }

        #expect(!h.store.hasAccepted(.openAI, direction: .stt))
        h.store.markAccepted(.openAI, direction: .stt)
        #expect(h.store.hasAccepted(.openAI, direction: .stt))
        #expect(!h.store.hasAccepted(.openAI, direction: .tts))
        #expect(!h.store.hasAccepted(.grok, direction: .stt))

        h.store.markAccepted(.grok, direction: .tts)
        #expect(h.store.hasAccepted(.grok, direction: .tts))
        #expect(!h.store.hasAccepted(.grok, direction: .stt))
        #expect(h.store.hasAccepted(.openAI, direction: .stt))

        // Reconstructing over the same defaults still reads it (persisted)
        #expect(VoiceDisclosureStore(defaults: h.defaults).hasAccepted(.openAI, direction: .stt))
        // Does not write the send-message disclosure key
        #expect(h.defaults.object(forKey: "provider.disclosure.accepted.list") == nil)

        h.store.reset()
        #expect(!h.store.hasAccepted(.openAI, direction: .stt))
        #expect(!h.store.hasAccepted(.grok, direction: .tts))
    }

    @Test("Choosing system writes the setting directly, without a disclosure")
    func choosingSystemAppliesDirectly() {
        let h = Harness()
        defer { h.tearDown() }
        h.settings.setSelection(.cloud(Self.sttEngine), for: .stt)

        let outcome = h.chooser.choose(.system, direction: .stt, catalog: Self.catalog)

        #expect(outcome == .applied(.system))
        #expect(h.settings.selection(for: .stt) == .system)
    }

    @Test("Choosing cloud without consent requires a disclosure and writes no setting")
    func choosingCloudWithoutConsentNeedsDisclosure() {
        let h = Harness()
        defer { h.tearDown() }

        let outcome = h.chooser.choose(Self.sttOption, direction: .stt, catalog: Self.catalog)

        #expect(outcome == .needsDisclosure(Self.sttEngine))
        #expect(h.settings.selection(for: .stt) == .system)
    }

    @Test("Accepting records consent and writes the setting")
    func acceptingRecordsConsentAndApplies() {
        let h = Harness()
        defer { h.tearDown() }
        guard case .needsDisclosure(let engine) = h.chooser.choose(Self.sttOption, direction: .stt, catalog: Self.catalog) else {
            Issue.record("Should require a disclosure first")
            return
        }

        let applied = h.chooser.resolveDisclosure(engine, direction: .stt, accepted: true)

        #expect(applied)
        #expect(h.store.hasAccepted(.openAI, direction: .stt))
        #expect(!h.store.hasAccepted(.openAI, direction: .tts))
        #expect(h.settings.selection(for: .stt) == .cloud(Self.sttEngine))
    }

    @Test("Declining (including swiping the sheet down) writes no setting and records no consent")
    func decliningLeavesSettings() {
        let h = Harness()
        defer { h.tearDown() }
        guard case .needsDisclosure(let engine) = h.chooser.choose(Self.ttsOption, direction: .tts, catalog: Self.catalog) else {
            Issue.record("Should require a disclosure first")
            return
        }

        let applied = h.chooser.resolveDisclosure(engine, direction: .tts, accepted: false)

        #expect(!applied)
        #expect(!h.store.hasAccepted(.openAI, direction: .tts))
        #expect(h.settings.selection(for: .tts) == .system)

        // Choosing again still requires a disclosure
        #expect(h.chooser.choose(Self.ttsOption, direction: .tts, catalog: Self.catalog) == .needsDisclosure(Self.ttsEngine))
    }

    @Test("Already accepted: writes the setting directly without showing the disclosure again")
    func alreadyAcceptedAppliesDirectly() {
        let h = Harness()
        defer { h.tearDown() }
        h.store.markAccepted(.openAI, direction: .stt)

        let outcome = h.chooser.choose(Self.sttOption, direction: .stt, catalog: Self.catalog)

        #expect(outcome == .applied(.cloud(Self.sttEngine)))
        #expect(h.settings.selection(for: .stt) == .cloud(Self.sttEngine))
    }

    /// Goes through the production fallback path to leave one pending notice at each of the two sites for the direction: the chosen connection does not exist, so it reverts to system and leaves a notice for the other site.
    private static func leavePendingNotices(_ settings: VoiceEngineSettings, direction: VoiceDirection) {
        let engine = direction == .stt ? sttEngine : ttsEngine
        for site in [VoiceNoticeSite.use, .settings] {
            settings.setSelection(.cloud(engine), for: direction)
            settings.resolve(direction: direction, catalog: catalog, connections: [], site: site)
        }
    }

    private static func pendingKey(_ site: VoiceNoticeSite, _ direction: VoiceDirection) -> String {
        "voice.engine.pendingNotice.\(site.rawValue).\(direction.rawValue)"
    }

    @Test("Choosing system through the chooser clears the pending notices at both the settings and use sites for that direction, leaving the other direction alone")
    func choosingSystemClearsPendingNotices() {
        let h = Harness()
        defer { h.tearDown() }
        Self.leavePendingNotices(h.settings, direction: .stt)
        Self.leavePendingNotices(h.settings, direction: .tts)
        #expect(h.defaults.string(forKey: Self.pendingKey(.settings, .stt)) != nil)
        #expect(h.defaults.string(forKey: Self.pendingKey(.use, .stt)) != nil)

        #expect(h.chooser.choose(.system, direction: .stt, catalog: Self.catalog) == .applied(.system))

        #expect(h.settings.takePendingNotice(site: .settings, direction: .stt) == nil)
        #expect(h.settings.takePendingNotice(site: .use, direction: .stt) == nil)
        #expect(h.settings.takePendingNotice(site: .settings, direction: .tts) == .connectionMissing)
        #expect(h.settings.takePendingNotice(site: .use, direction: .tts) == .connectionMissing)
    }

    @Test("Writing cloud after accepting the disclosure through the chooser, or directly when already accepted, clears both pending notices for that direction; declining does not")
    func choosingCloudClearsPendingNotices() {
        let h = Harness()
        defer { h.tearDown() }
        Self.leavePendingNotices(h.settings, direction: .tts)
        guard case .needsDisclosure(let engine) = h.chooser.choose(Self.ttsOption, direction: .tts, catalog: Self.catalog) else {
            Issue.record("Should require a disclosure first")
            return
        }
        h.chooser.resolveDisclosure(engine, direction: .tts, accepted: false)
        #expect(h.defaults.string(forKey: Self.pendingKey(.settings, .tts)) != nil)
        #expect(h.defaults.string(forKey: Self.pendingKey(.use, .tts)) != nil)

        #expect(h.chooser.resolveDisclosure(engine, direction: .tts, accepted: true))
        #expect(h.settings.selection(for: .tts) == .cloud(Self.ttsEngine))
        #expect(h.settings.takePendingNotice(site: .settings, direction: .tts) == nil)
        #expect(h.settings.takePendingNotice(site: .use, direction: .tts) == nil)

        Self.leavePendingNotices(h.settings, direction: .tts)
        #expect(h.chooser.choose(Self.ttsOption, direction: .tts, catalog: Self.catalog) == .applied(.cloud(Self.ttsEngine)))
        #expect(h.settings.takePendingNotice(site: .settings, direction: .tts) == nil)
        #expect(h.settings.takePendingNotice(site: .use, direction: .tts) == nil)
    }

    @Test("Choosing a read-aloud entry stores the entry's default voice")
    func ttsChoiceUsesEntryDefaultVoice() {
        let h = Harness()
        defer { h.tearDown() }
        h.store.markAccepted(.openAI, direction: .tts)
        h.settings.setSelection(.cloud(VoiceCloudEngine(
            providerKind: .openAI, connectionID: "o1", model: "gpt-4o-mini-tts", voice: "alloy"
        )), for: .tts)

        let outcome = h.chooser.choose(Self.ttsOption, direction: .tts, catalog: Self.catalog)

        #expect(outcome == .applied(.cloud(Self.ttsEngine)))
        guard case .cloud(let stored) = h.settings.selection(for: .tts) else {
            Issue.record("Should store a cloud selection")
            return
        }
        #expect(stored.voice == "nova")
    }

    private static let realtimeCatalog = VoiceCatalogDecoder.decode([
        "providers": [
            "openAI": [
                "realtime": [[
                    "model": "gpt-realtime",
                    "transport": "openai_realtime",
                    "path": "/v1/realtime",
                    "contextWindow": 128_000,
                    "voices": [["id": "alloy"], ["id": "marin", "isDefault": true]],
                    "inputTranscriptionModel": "gpt-4o-mini-transcribe",
                ]],
            ],
        ],
    ] as [String: Any])

    @Test("Conversation engine: the disclosure token is realtime.<kind>, independent of dictation / read-aloud")
    func realtimeConsentUsesOwnToken() {
        let h = Harness()
        defer { h.tearDown() }
        h.store.markAccepted(.openAI, direction: .realtime)

        #expect(h.store.hasAccepted(.openAI, direction: .realtime))
        #expect(!h.store.hasAccepted(.openAI, direction: .stt))
        #expect(!h.store.hasAccepted(.openAI, direction: .tts))
        #expect(h.defaults.stringArray(forKey: "voice.disclosure.accepted.list") == ["realtime.openAI"])
    }

    @Test("Conversation engine: after consent, the entry's default voice is stored")
    func realtimeChoiceAppliesDefaultVoice() {
        let h = Harness()
        defer { h.tearDown() }
        let option = VoiceEngineOption.cloud(providerKind: .openAI, connectionID: "o1", model: "gpt-realtime", isDefault: false)
        let expectedEngine = VoiceCloudEngine(providerKind: .openAI, connectionID: "o1", model: "gpt-realtime", voice: "marin")

        let outcome = h.chooser.choose(option, direction: .realtime, catalog: Self.realtimeCatalog)
        #expect(outcome == .needsDisclosure(expectedEngine))
        #expect(h.chooser.resolveDisclosure(expectedEngine, direction: .realtime, accepted: true))

        #expect(h.settings.selection(for: .realtime) == .cloud(expectedEngine))
        #expect(h.settings.selection(for: .stt) == .system)
    }

    // MARK: - Picker selects a realtime model

    @MainActor
    private static func makeRealtimeState() -> (AppState, Provider) {
        let state = AppState(seedDemoData: true)
        let provider = TestFactories.makeProvider(
            kind: .openAI,
            models: [TestFactories.makeModel(id: "gpt-4o", isDefault: true)]
        )
        state.providers = [provider]
        let entry = VoiceRealtimeEntry(
            model: "gpt-realtime-mini",
            transport: .openaiRealtime,
            path: "/v1/realtime",
            contextWindow: 128_000,
            voices: [VoiceCatalogVoice(id: "marin", isDefault: true)],
            maxSessionSec: nil,
            inputTranscriptionModel: nil,
            isDefault: true
        )
        let catalog = VoiceCatalog(schemaVersion: 2, revision: "disclosure", providers: [
            .openAI: VoiceProviderEntries(realtime: [entry])
        ])
        state.realtimeVoiceCatalog = { catalog }
        return (state, provider)
    }

    @Test("picker selects a realtime row without consent: needs disclosure, selection unchanged", .sharedProcessState)
    @MainActor
    func realtimeModelPickWithoutConsentNeedsDisclosure() {
        let h = Harness()
        defer { h.tearDown() }
        let (state, provider) = Self.makeRealtimeState()
        let conversationID = UUID()

        let outcome = state.selectRealtimeModel(
            providerID: provider.id, model: "gpt-realtime", for: conversationID, disclosures: h.store
        )

        #expect(outcome == .needsDisclosure(
            RealtimeModelSelection(providerID: provider.id, providerKind: .openAI, model: "gpt-realtime")
        ))
        #expect(state.realtimeModelSelection(for: conversationID) == nil)
        #expect(!h.store.hasAccepted(.openAI, direction: .realtime))
    }

    @Test("picker realtime-row disclosure: accepting records (openAI, realtime) and applies; declining records nothing and does not apply", .sharedProcessState)
    @MainActor
    func realtimeModelDisclosureAnswerRecordsConsent() throws {
        let h = Harness()
        // Accepting the realtime disclosure also records the provider disclosure and writes to UserDefaults.standard, so clear it before and after to avoid polluting later tests.
        ProviderDisclosureStore.reset()
        defer {
            ProviderDisclosureStore.reset()
            h.tearDown()
        }
        let (state, provider) = Self.makeRealtimeState()
        let selection = RealtimeModelSelection(providerID: provider.id, providerKind: .openAI, model: "gpt-realtime-mini")

        #expect(!state.resolveRealtimeModelDisclosure(
            selection, for: nil, accepted: false, disclosures: h.store
        ))
        #expect(state.realtimeModelSelection(for: nil) == nil)
        #expect(!h.store.hasAccepted(.openAI, direction: .realtime))

        #expect(state.resolveRealtimeModelDisclosure(
            selection, for: nil, accepted: true, disclosures: h.store
        ))
        #expect(state.realtimeModelSelection(for: nil) == selection)
        #expect(h.defaults.stringArray(forKey: "voice.disclosure.accepted.list") == ["realtime.openAI"])
    }

    @Test("accepting the realtime disclosure also records the provider disclosure as accepted; declining records nothing", .sharedProcessState)
    @MainActor
    func realtime_accept_also_accepts_provider_disclosure() {
        let h = Harness()
        ProviderDisclosureStore.reset()
        defer {
            ProviderDisclosureStore.reset()
            h.tearDown()
        }
        let (state, provider) = Self.makeRealtimeState()
        let selection = RealtimeModelSelection(providerID: provider.id, providerKind: .openAI, model: "gpt-realtime-mini")

        _ = state.resolveRealtimeModelDisclosure(
            selection, for: nil, accepted: false, disclosures: h.store
        )
        #expect(!ProviderDisclosureStore.hasAccepted(.openAI))

        #expect(state.resolveRealtimeModelDisclosure(
            selection, for: nil, accepted: true, disclosures: h.store
        ))
        #expect(ProviderDisclosureStore.hasAccepted(.openAI))
        #expect(!ProviderDisclosureStore.hasAccepted(.anthropic))
    }

    @Test("session selecting a realtime row needs disclosure: after accepting, the realtime model applies and the session model becomes it", .sharedProcessState)
    @MainActor
    func realtimeSelectionAppliesAfterDisclosureAgree() throws {
        let h = Harness()
        ProviderDisclosureStore.reset()
        defer {
            ProviderDisclosureStore.reset()
            h.tearDown()
        }
        let (state, provider) = Self.makeRealtimeState()
        let conversation = TestFactories.makeConversation(providerID: provider.id, providerKind: .openAI, modelID: "gpt-4o")
        state.upsertConversationProjection(conversation)

        let outcome = state.selectRealtimeModel(
            providerID: provider.id, model: "gpt-realtime-mini", for: conversation.id, disclosures: h.store
        )
        guard case .needsDisclosure(let selection) = outcome else {
            Issue.record("expected needsDisclosure, got \(outcome)")
            return
        }
        #expect(state.conversation(for: conversation.id)?.modelID == "gpt-4o")

        #expect(state.resolveRealtimeModelDisclosure(
            selection, for: conversation.id, accepted: true, disclosures: h.store
        ))
        #expect(state.realtimeModelSelection(for: conversation.id) == selection)
        #expect(state.conversation(for: conversation.id)?.modelID == "gpt-realtime-mini")
    }

    @Test("after selecting a realtime row, declining the disclosure: this choice does not apply, home and session keep the model from before the tap", .sharedProcessState)
    @MainActor
    func realtimeSelectionKeepsPreviousModelWhenDisclosureDeclined() throws {
        let h = Harness()
        ProviderDisclosureStore.reset()
        defer {
            ProviderDisclosureStore.reset()
            h.tearDown()
        }
        let (state, provider) = Self.makeRealtimeState()
        let conversation = TestFactories.makeConversation(providerID: provider.id, providerKind: .openAI, modelID: "gpt-4o")
        state.upsertConversationProjection(conversation)
        let homeModelBefore = state.activeModel?.model.id

        for conversationID in [nil, conversation.id] as [UUID?] {
            let outcome = state.selectRealtimeModel(
                providerID: provider.id, model: "gpt-realtime-mini", for: conversationID, disclosures: h.store
            )
            guard case .needsDisclosure(let selection) = outcome else {
                Issue.record("expected needsDisclosure, got \(outcome)")
                return
            }
            #expect(!state.resolveRealtimeModelDisclosure(
                selection, for: conversationID, accepted: false, disclosures: h.store
            ))
            #expect(state.realtimeModelSelection(for: conversationID) == nil)
        }
        #expect(state.activeModel?.model.id == homeModelBefore)
        #expect(state.conversation(for: conversation.id)?.modelID == "gpt-4o")
        #expect(!h.store.hasAccepted(.openAI, direction: .realtime))
    }

    @Test("engine already consented to this provider's realtime: picker realtime row applies directly without asking again", .sharedProcessState)
    @MainActor
    func realtimeModelPickAfterEngineConsentAppliesDirectly() {
        let h = Harness()
        defer { h.tearDown() }
        let engine = VoiceCloudEngine(providerKind: .openAI, connectionID: "o1", model: "gpt-realtime", voice: nil)
        #expect(h.chooser.resolveDisclosure(engine, direction: .realtime, accepted: true))
        let (state, provider) = Self.makeRealtimeState()
        let conversation = TestFactories.makeConversation(providerID: provider.id, providerKind: .openAI, modelID: "gpt-4o")
        state.upsertConversationProjection(conversation)
        let conversationID = conversation.id

        let outcome = state.selectRealtimeModel(
            providerID: provider.id, model: "gpt-realtime-mini", for: conversationID, disclosures: h.store
        )

        let expected = RealtimeModelSelection(providerID: provider.id, providerKind: .openAI, model: "gpt-realtime-mini")
        #expect(outcome == .applied(expected))
        #expect(state.realtimeModelSelection(for: conversationID) == expected)
        #expect(state.realtimeModelSelection(for: nil) == nil)
    }
}
