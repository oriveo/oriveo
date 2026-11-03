import Foundation
import Testing
@testable import Oriveo

@Suite("Provider + AppState flow helpers", .serialized, .sharedProcessState)
@MainActor
struct ProviderAppStateFlowTests {
    private func waitUntil(
        timeoutNanoseconds: UInt64 = 1_000_000_000,
        intervalNanoseconds: UInt64 = 10_000_000,
        condition: @MainActor @escaping () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + .nanoseconds(Int64(timeoutNanoseconds))
        while condition() == false {
            if ContinuousClock.now >= deadline {
                Issue.record("Timed out waiting for condition")
                return
            }
            try await Task.sleep(nanoseconds: intervalNanoseconds)
        }
    }

    private func withOpenAIMetadata<Result>(
        _ operation: () async throws -> Result
    ) async throws -> Result {
        await MetadataClient.shared.resetForTesting()

        do {
            try await MetadataClient.shared.loadForTesting(json: """
            {
              "version": 1,
              "updatedAt": "2026-04-10T00:00:00Z",
              "providers": {
                "openAI": {
                  "displayName": "OpenAI",
                  "defaultModelId": "gpt-4o",
                  "resolveMap": {
                    "gpt-4o": "gpt-4o",
                    "o4-mini-2026-04-10": "o4-mini",
                    "o4-mini": "o4-mini"
                  },
                  "models": {
                    "gpt-4o": {
                      "canonicalModelId": "gpt-4o",
                      "displayName": "GPT-4o"
                    },
                    "o4-mini": {
                      "canonicalModelId": "o4-mini",
                      "displayName": "o4-mini",
                      "capabilities": ["text", "reasoning"]
                    }
                  }
                }
              }
            }
            """)

            let result = try await operation()
            await MetadataClient.shared.resetForTesting()
            return result
        } catch {
            await MetadataClient.shared.resetForTesting()
            throw error
        }
    }

    private func makeState() -> AppState {
        AppState(seedDemoData: true)
    }

    @Test("registerRelay writes a relay provider to AppState")
    func registerRelayPersistsProvider() {
        let state = makeState()
        state.providers = []

        let relay = state.registerRelay(
            name: "Relay",
            endpoint: "https://relay.example.com",
            apiKey: "sk-relay-test"
        )

        #expect(state.providers.contains(where: { $0.id == relay.id }))
        #expect(relay.kind == .relay)
        #expect(state.providers.count == 1)
    }

    @Test("saveManualModel (onboarding) navigates to chat and completes setup")
    func saveManualModelOnboardingNavigatesToChat() async throws {
        let state = makeState()
        let provider = TestFactories.makeProvider()
        state.providers = [provider]
        state.navigation.path = [
            .providerDetail(providerID: provider.id),
            .manualModelEntry(providerID: provider.id, context: .onboarding)
        ]

        state.saveManualModel(providerID: provider.id, modelID: "manual", context: .onboarding)

        #expect(state.selectedTab == .home)
        #expect(
            state.navigation.path == [
                .providerDetail(providerID: provider.id),
                .manualModelEntry(providerID: provider.id, context: .onboarding)
            ]
        )

        try await waitUntil {
            state.navigation.path == [.chat(conversationID: nil)]
        }
    }

    @Test("saveManualModel (providers) stays on providers tab")
    func saveManualModelProvidersContextResetsNavigation() {
        let state = makeState()
        let provider = TestFactories.makeProvider()
        state.providers = [provider]
        state.navigation.path = [
            .manualModelEntry(providerID: provider.id, context: .providers)
        ]

        state.saveManualModel(providerID: provider.id, modelID: "manual", context: .providers)

        #expect(state.navigation.path.isEmpty)
        #expect(state.selectedTab == .providers)
    }

    @Test("saveManualModel (providerDetail) pops manual entry view")
    func saveManualModelProviderDetailPops() {
        let state = makeState()
        let provider = TestFactories.makeProvider()
        state.providers = [provider]
        state.navigation.path = [
            .providerDetail(providerID: provider.id),
            .manualModelEntry(providerID: provider.id, context: .providerDetail)
        ]

        state.saveManualModel(providerID: provider.id, modelID: "manual", context: .providerDetail)

        #expect(state.navigation.path == [.providerDetail(providerID: provider.id)])
    }

    @Test("saveManualModel (modelPicker) pops manual entry view")
    func saveManualModelModelPickerPops() {
        let state = makeState()
        let provider = TestFactories.makeProvider()
        state.providers = [provider]
        state.navigation.path = [
            .manualModelEntry(providerID: provider.id, context: .modelPicker)
        ]

        state.saveManualModel(providerID: provider.id, modelID: "manual", context: .modelPicker)

        #expect(state.navigation.path.isEmpty)
    }

    @Test("completeProviderSetup (welcome) pushes chat and returns home tab")
    func completeProviderSetupWelcomePushesChat() {
        let state = makeState()
        let provider = TestFactories.makeProvider()
        state.providers = [provider]

        state.completeProviderSetup(providerID: provider.id, entryPoint: .welcome)

        #expect(state.selectedTab == .home)
        #expect(state.navigation.path.last == .chat(conversationID: nil))
    }

    @Test("completeProviderSetup (welcome) defers route mutation until next main-actor turn")
    func completeProviderSetupWelcomeDefersRouteMutation() async throws {
        let state = makeState()
        let provider = TestFactories.makeProvider()
        state.providers = [provider]
        state.hasCompletedOnboarding = false
        state.navigation.path = [
            .providerSetup(entryPoint: .welcome, preselectedKind: .deepseek)
        ]

        state.completeProviderSetup(providerID: provider.id, entryPoint: .welcome)

        #expect(state.selectedTab == .home)
        #expect(state.hasCompletedOnboarding)
        #expect(
            state.navigation.path == [
                .providerSetup(entryPoint: .welcome, preselectedKind: .deepseek)
            ]
        )

        try await waitUntil {
            state.navigation.path == [.chat(conversationID: nil)]
        }
    }

    @Test("completeProviderSetup (providers) selects the verified model and enters chat")
    func completeProviderSetupProvidersEntersChat() async {
        let state = makeState()
        let provider = TestFactories.makeProvider()
        state.providers = [provider]
        state.navigation.path = [.providerDetail(providerID: provider.id)]

        state.completeProviderSetup(providerID: provider.id, entryPoint: .providers)

        #expect(state.selectedTab == .home)
        #expect(state.navigation.path == [.providerDetail(providerID: provider.id)])
        try? await Task.sleep(for: .milliseconds(20))
        #expect(state.navigation.path == [.chat(conversationID: nil)])
        #expect(state.activeModel?.provider.id == provider.id)
        #expect(state.activeModel?.model.id == provider.defaultModel?.id)
    }

    @Test("completeRelaySetup (providers) writes only the verified model, and without one it does not write the fallback as last used")
    func completeRelaySetupWritesOnlyVerifiedModel() {
        let first = TestFactories.makeModel(id: "relay-a", name: "Relay A")
        let second = TestFactories.makeModel(id: "relay-b", name: "Relay B")
        let provider = TestFactories.makeProvider(kind: .relay, models: [first, second], catalogModels: [first, second])

        let unverified = makeState()
        unverified.providers = [provider]
        unverified.lastUsedModelRef = nil
        unverified.completeRelaySetup(providerID: provider.id, entryPoint: .providers, verifiedModelID: nil, addedModelCount: 2)
        #expect(unverified.lastUsedModelRef == nil)
        #expect(unverified.selectedTab == .providers)
        #expect(unverified.navigation.path == [.providerDetail(providerID: provider.id)])
        #expect(unverified.consumeProviderDetailNotice(for: provider.id) == .addedModels(2))

        let verified = makeState()
        verified.providers = [provider]
        verified.lastUsedModelRef = nil
        verified.completeRelaySetup(providerID: provider.id, entryPoint: .providers, verifiedModelID: "relay-b", addedModelCount: 2)
        #expect(verified.lastUsedModelRef == LastUsedModelRef(providerID: provider.id, modelID: "relay-b"))
    }

    @Test("completeProviderSetup (modelPicker) selects the model and returns its caller stack")
    func completeProviderSetupModelPickerReturnsCaller() {
        let state = makeState()
        let provider = TestFactories.makeProvider()
        state.providers = [provider]
        state.navigation.path = [
            .chat(conversationID: nil),
            .providerSetup(entryPoint: .modelPicker),
            .localComputeSetup(entryPoint: .modelPicker),
        ]

        state.completeProviderSetup(providerID: provider.id, entryPoint: .modelPicker)

        #expect(state.navigation.path == [.chat(conversationID: nil)])
        #expect(state.activeModel?.provider.id == provider.id)
        #expect(state.activeModel?.model.id == provider.defaultModel?.id)
    }

    @Test("completeProviderSetup (skillEdit) preserves the skill route and binds the model")
    func completeProviderSetupSkillEditReturnsToSkill() {
        let state = makeState()
        let provider = TestFactories.makeProvider()
        let skillID = UUID()
        state.providers = [provider]
        state.navigation.path = [
            .skillsList,
            .skillEdit(skillID),
            .providerSetup(entryPoint: .skillEdit),
            .relaySetup(entryPoint: .skillEdit),
        ]

        state.completeProviderSetup(providerID: provider.id, entryPoint: .skillEdit)

        #expect(state.navigation.path == [.skillsList, .skillEdit(skillID)])
        #expect(state.activeModel?.provider.id == provider.id)
        #expect(state.activeModel?.model.id == provider.defaultModel?.id)
    }

    @Test("completion policy handles a legacy direct Local route without discarding its caller")
    func completionPolicyHandlesLegacyDirectLocalRoute() {
        let caller: [AppRoute] = [.skillsList, .skillEdit(nil)]
        let path = caller + [.localComputeSetup(entryPoint: .skillEdit)]

        #expect(ProviderSetupCompletionPolicy.returnedCallerPath(from: path) == caller)
    }

    @Test("deleteProvider keeps providers tab active and clears navigation")
    func deleteProviderResetsNavigation() {
        let state = makeState()
        let provider = TestFactories.makeProvider()
        state.providers = [provider]
        state.navigation.path = [.chat(conversationID: nil)]

        state.deleteProvider(providerID: provider.id)

        #expect(state.selectedTab == .providers)
        #expect(state.navigation.path.isEmpty)
        #expect(state.providers.isEmpty)
    }

    @Test("deleteProvider clears a wide-screen right-column selection pointing at it and leaves others alone")
    func deleteProviderClearsSplitColumnSelection() {
        let state = makeState()
        let deleted = TestFactories.makeProvider()
        let kept = TestFactories.makeProvider()
        state.providers = [deleted, kept]
        state.navigation.updateLayoutWidth(isRegular: true)
        state.navigation.providersDetail = .providerDetail(providerID: deleted.id)

        state.deleteProvider(providerID: deleted.id)
        #expect(state.navigation.providersDetail == nil)

        state.navigation.providersDetail = .providerDetail(providerID: kept.id)
        state.providers.append(deleted)
        state.deleteProvider(providerID: deleted.id)
        #expect(state.navigation.providersDetail == .providerDetail(providerID: kept.id))
    }

    @Test("startNewChat with provider pushes chat route")
    func startNewChatWithProviderNavigatesChat() {
        let state = makeState()
        let provider = TestFactories.makeProvider()
        state.providers = [provider]
        state.navigation.path = []

        state.startNewChat()

        #expect(state.navigation.path.last == .chat(conversationID: nil))
    }

    @Test("Start New Chat With Preferred Model Switches Active Model")
    func startNewChatWithPreferredModelSwitchesActiveModel() {
        let state = makeState()
        let providerA = TestFactories.makeProvider(
            kind: .openAI,
            models: [TestFactories.makeModel(id: "gpt-4o", isDefault: true)]
        )
        let providerB = TestFactories.makeProvider(
            kind: .anthropic,
            models: [
                TestFactories.makeModel(id: "claude-haiku", isDefault: true),
                TestFactories.makeModel(id: "claude-opus")
            ]
        )
        state.providers = [providerA, providerB]
        state.navigation.path = []

        state.setActiveModel(providerID: providerA.id, modelID: "gpt-4o")
        #expect(state.activeModel?.model.id == "gpt-4o")

        state.startNewChat(preferredProviderID: providerB.id, preferredModelID: "claude-opus")

        #expect(state.navigation.path.last == .chat(conversationID: nil))
        #expect(state.activeModel?.provider.id == providerB.id)
        #expect(state.activeModel?.model.id == "claude-opus")
    }

    @Test("Start New Chat With Preferred Model Keeps Non Default Model")
    func startNewChatWithPreferredModelKeepsNonDefaultModel() {
        let state = makeState()
        let provider = TestFactories.makeProvider(
            kind: .openAI,
            models: [
                TestFactories.makeModel(id: "gpt-4o", isDefault: true),
                TestFactories.makeModel(id: "gpt-4o-mini")
            ]
        )
        state.providers = [provider]
        state.navigation.path = []
        state.setActiveModel(providerID: provider.id, modelID: "gpt-4o")

        state.startNewChat(preferredProviderID: provider.id, preferredModelID: "gpt-4o-mini")

        #expect(state.activeModel?.model.id == "gpt-4o-mini")
    }

    /// Both the toolbar new chat and the detail-page start chat go through `startNewChat(preferredProviderID:)`: the connection isDefault is not read,
    /// and with no last-used pointing at this connection the catalog defaultModelId is taken.
    @Test("New chat for a connection: ignores the connection isDefault and takes the catalog default")
    func startNewChatForProviderIgnoresConnectionDefault() async throws {
        try await withOpenAIMetadata {
            let state = makeState()
            let provider = TestFactories.makeProvider(
                kind: .openAI,
                models: [
                    TestFactories.makeModel(id: "gpt-4o-mini", isDefault: true),
                    TestFactories.makeModel(id: "o4-mini", canonicalModelId: "o4-mini"),
                    TestFactories.makeModel(id: "gpt-4o", canonicalModelId: "gpt-4o")
                ]
            )
            state.providers = [provider]
            state.navigation.path = []
            state.lastUsedModelRef = nil

            state.startNewChat(preferredProviderID: provider.id)

            #expect(state.navigation.path.last == .chat(conversationID: nil))
            #expect(state.activeModel?.model.id == "gpt-4o")
            #expect(state.lastUsedModelRef?.modelID == "gpt-4o")
        }
    }

    @Test("New chat for a connection: the last-used model of that connection wins and is not rewritten by the connection default")
    func startNewChatForProviderKeepsLastUsedOfThatProvider() async throws {
        try await withOpenAIMetadata {
            let state = makeState()
            let provider = TestFactories.makeProvider(
                kind: .openAI,
                models: [
                    TestFactories.makeModel(id: "gpt-4o-mini", isDefault: true),
                    TestFactories.makeModel(id: "o4-mini", canonicalModelId: "o4-mini"),
                    TestFactories.makeModel(id: "gpt-4o", canonicalModelId: "gpt-4o")
                ]
            )
            state.providers = [provider]
            state.navigation.path = []
            state.lastUsedModelRef = LastUsedModelRef(providerID: provider.id, modelID: "o4-mini")

            state.startNewChat(preferredProviderID: provider.id)

            #expect(state.activeModel?.model.id == "o4-mini")
            #expect(state.lastUsedModelRef?.modelID == "o4-mini")
        }
    }

    @Test("A conversation with an empty modelID resolves its model through the new-chat chain and does not read the connection isDefault")
    func currentModelForEmptyModelIDUsesNewChatChain() {
        let state = makeState()
        let provider = TestFactories.makeProvider(
            kind: .openAI,
            models: [
                TestFactories.makeModel(id: "gpt-4o", isDefault: true),
                TestFactories.makeModel(id: "gpt-4o-mini")
            ]
        )
        state.providers = [provider]
        state.lastUsedModelRef = LastUsedModelRef(providerID: provider.id, modelID: "gpt-4o-mini")
        let conversation = TestFactories.makeConversation(providerID: provider.id, modelID: "")

        #expect(state.currentModel(for: conversation)?.id == "gpt-4o-mini")
    }

    @Test("Detail-page start chat: a connection without credentials cannot start, opens no chat and writes no last-used")
    func scopedStartChatWithMissingCredentialDoesNotStart() {
        let state = makeState()
        let provider = TestFactories.makeProvider(kind: .openAI, apiKey: "", apiKeyPreview: "")
        state.providers = [provider]
        state.lastUsedModelRef = nil
        state.navigation.path = []

        state.startNewChat(preferredProviderID: provider.id)

        #expect(state.navigation.path.last != .chat(conversationID: nil))
        #expect(state.lastUsedModelRef == nil)
    }

    @Test("Detail-page model row start chat: a connection without credentials cannot start, returns false and writes no last-used")
    func modelRowStartChatWithMissingCredentialDoesNotStart() {
        let state = makeState()
        let provider = TestFactories.makeProvider(
            kind: .openAI,
            models: [TestFactories.makeModel(id: "gpt-4o-mini")],
            apiKey: "",
            apiKeyPreview: ""
        )
        state.providers = [provider]
        state.lastUsedModelRef = nil
        state.navigation.path = []

        let opened = state.startNewChat(preferredProviderID: provider.id, preferredModelID: "gpt-4o-mini")

        #expect(!opened)
        #expect(state.navigation.path.last != .chat(conversationID: nil))
        #expect(state.lastUsedModelRef == nil)
    }

    @Test("Adding a connection without a verified model: the fallback result only navigates and writes no last-used")
    func completeProviderSetupWithoutVerifiedModelDoesNotWriteLastUsed() async {
        let state = makeState()
        let provider = TestFactories.makeProvider()
        state.providers = [provider]
        state.lastUsedModelRef = nil
        state.navigation.path = []

        state.completeProviderSetup(providerID: provider.id, entryPoint: .providers)

        #expect(state.selectedTab == .home)
        #expect(state.lastUsedModelRef == nil)
        try? await Task.sleep(for: .milliseconds(20))
        #expect(state.navigation.path == [.chat(conversationID: nil)])
    }

    @Test("Start realtime voice: an existing conversation writes its sendable model as last-used")
    func realtimeVoiceStartWritesConversationSendableModel() {
        let state = makeState()
        let provider = TestFactories.makeProvider(
            kind: .relay,
            models: [
                TestFactories.makeModel(id: "relay-default", isDefault: true),
                TestFactories.makeModel(id: "relay-chat")
            ]
        )
        state.providers = [provider]
        let conversation = TestFactories.makeConversation(providerID: provider.id, providerKind: .relay, modelID: "relay-chat")
        state.upsertConversationProjection(conversation)
        state.lastUsedModelRef = nil

        state.recordLastUsedForRealtimeVoice(conversationID: conversation.id)

        #expect(state.lastUsedModelRef?.providerID == provider.id)
        #expect(state.lastUsedModelRef?.modelID == "relay-chat")
    }

    @Test("Start realtime voice: an unsendable conversation model writes no last-used")
    func realtimeVoiceStartSkipsUnsendableConversationModel() {
        let state = makeState()
        let provider = TestFactories.makeProvider(
            kind: .relay,
            models: [TestFactories.makeModel(id: "relay-default", isDefault: true)]
        )
        state.providers = [provider]
        let conversation = TestFactories.makeConversation(providerID: provider.id, providerKind: .relay, modelID: "relay-removed")
        state.upsertConversationProjection(conversation)
        let previous = LastUsedModelRef(providerID: UUID(), modelID: "elsewhere")
        state.lastUsedModelRef = previous

        state.recordLastUsedForRealtimeVoice(conversationID: conversation.id)

        #expect(state.lastUsedModelRef == previous)
    }

    @Test("Start realtime voice from home without a realtime selection (selection reverted to text while enabling) writes the active pill model")
    func realtimeVoiceStartFromHomeWithoutRealtimeSelectionWritesActiveModel() throws {
        let state = makeState()
        let provider = TestFactories.makeProvider(
            kind: .relay,
            models: [TestFactories.makeModel(id: "relay-default", isDefault: true)]
        )
        state.providers = [provider]
        state.setActiveModel(providerID: provider.id, modelID: "relay-default")
        try #require(state.realtimeModelSelection(for: nil) == nil)
        state.lastUsedModelRef = nil

        state.recordLastUsedForRealtimeVoice(conversationID: nil)

        #expect(state.lastUsedModelRef?.providerID == provider.id)
        #expect(state.lastUsedModelRef?.modelID == "relay-default")
    }

    @Test("Start realtime voice from home with a realtime model selected does not write last-used")
    func realtimeVoiceStartFromHomeRealtimeSelectionSkipsLastUsed() throws {
        let state = makeState()
        let provider = TestFactories.makeProvider(
            kind: .openAI,
            models: [TestFactories.makeModel(id: "gpt-4o", isDefault: true)]
        )
        state.providers = [provider]
        state.realtimeVoiceCatalog = { Self.realtimeCatalog() }
        let (store, defaults, suiteName) = acceptedRealtimeDisclosures()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        state.selectRealtimeModel(providerID: provider.id, model: "gpt-realtime", for: nil, disclosures: store)
        try #require(state.realtimeModelSelection(for: nil) != nil)
        state.lastUsedModelRef = nil

        state.recordLastUsedForRealtimeVoice(conversationID: nil)
        state.recordLastUsedForRealtimeVoice(conversationID: nil)

        #expect(state.lastUsedModelRef == nil)
    }

    @Test("Start or restart realtime voice in a conversation with a realtime model selected does not write last-used")
    func realtimeVoiceStartInRealtimeConversationSkipsLastUsed() throws {
        let state = makeState()
        let provider = TestFactories.makeProvider(
            kind: .openAI,
            models: [
                TestFactories.makeModel(id: "gpt-4o", isDefault: true),
                TestFactories.makeModel(id: "gpt-realtime")
            ]
        )
        state.providers = [provider]
        state.realtimeVoiceCatalog = { Self.realtimeCatalog() }
        let conversation = TestFactories.makeConversation(providerID: provider.id, providerKind: .openAI, modelID: "gpt-realtime")
        state.upsertConversationProjection(conversation)
        try #require(state.realtimeModelSelection(for: conversation.id) != nil)
        let previous = LastUsedModelRef(providerID: provider.id, modelID: "gpt-4o")
        state.lastUsedModelRef = previous

        state.recordLastUsedForRealtimeVoice(conversationID: conversation.id)
        state.recordLastUsedForRealtimeVoice(conversationID: conversation.id)

        #expect(state.lastUsedModelRef == previous)
    }

    @Test("Realtime voice from home creates a conversation: the home realtime selection moves to the new conversation and the home key is cleared")
    func realtimeVoiceConversationCreationMovesHomeSelection() throws {
        let state = makeState()
        let provider = TestFactories.makeProvider(
            kind: .openAI,
            models: [TestFactories.makeModel(id: "gpt-4o", isDefault: true)]
        )
        state.providers = [provider]
        state.realtimeVoiceCatalog = { Self.realtimeCatalog() }
        let (store, defaults, suiteName) = acceptedRealtimeDisclosures()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        state.selectRealtimeModel(providerID: provider.id, model: "gpt-realtime", for: nil, disclosures: store)
        let homeSelection = try #require(state.realtimeModelSelection(for: nil))

        let created = try #require(state.createConversationForRealtimeVoice())

        #expect(state.realtimeModelSelection(for: created) == homeSelection)
        #expect(state.realtimeModelSelection(for: nil) == nil)
        let stored = try #require(state.conversation(for: created))
        #expect(stored.providerID == provider.id)
        #expect(stored.providerKind == .openAI)
        #expect(stored.modelID == "gpt-realtime")
    }

    /// Catalog: openAI and relay both list gpt-realtime and gpt-realtime-mini. Listing does not make a relay model realtime; the connection shape does.
    private static func realtimeCatalog() -> VoiceCatalog {
        func entry(_ model: String) -> VoiceRealtimeEntry {
            VoiceRealtimeEntry(
                model: model,
                transport: .openaiRealtime,
                path: "/v1/realtime",
                contextWindow: 128_000,
                voices: [VoiceCatalogVoice(id: "marin", isDefault: true)],
                maxSessionSec: nil,
                inputTranscriptionModel: "gpt-4o-mini-transcribe",
                isDefault: model == "gpt-realtime"
            )
        }
        let entries = [entry("gpt-realtime"), entry("gpt-realtime-mini")]
        return VoiceCatalog(schemaVersion: 2, revision: "flow", providers: [
            .openAI: VoiceProviderEntries(realtime: entries),
            .relay: VoiceProviderEntries(realtime: entries),
        ])
    }

    /// Isolated defaults for the openAI realtime notice consent (does not touch .standard).
    private func acceptedRealtimeDisclosures() -> (VoiceDisclosureStore, UserDefaults, String) {
        let suiteName = "ProviderAppStateFlowTests-realtime-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let store = VoiceDisclosureStore(defaults: defaults)
        store.markAccepted(.openAI, direction: .realtime)
        return (store, defaults, suiteName)
    }

    @Test("A realtime model selected in a conversation writes providerID / providerKind / modelID into the conversation and selection is derived from those fields; not rewritten while the catalog is not ready")
    func realtimeSelectionPersistsInConversationFields() throws {
        let state = makeState()
        let provider = TestFactories.makeProvider(
            kind: .openAI,
            models: [TestFactories.makeModel(id: "gpt-4o", isDefault: true)]
        )
        state.providers = [provider]
        let conversation = TestFactories.makeConversation(providerID: provider.id, providerKind: .openAI, modelID: "gpt-4o")
        state.upsertConversationProjection(conversation)
        let (store, defaults, suiteName) = acceptedRealtimeDisclosures()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        state.realtimeVoiceCatalog = { nil }
        #expect(state.selectRealtimeModel(
            providerID: provider.id, model: "gpt-realtime", for: conversation.id, disclosures: store
        ) == .pending(RealtimeModelSelection(providerID: provider.id, providerKind: .openAI, model: "gpt-realtime")))
        #expect(state.conversation(for: conversation.id)?.modelID == "gpt-4o")
        #expect(state.realtimeModelSelection(for: conversation.id) == nil)

        state.realtimeVoiceCatalog = { Self.realtimeCatalog() }
        let outcome = state.selectRealtimeModel(
            providerID: provider.id, model: "gpt-realtime", for: conversation.id, disclosures: store
        )

        let expected = RealtimeModelSelection(providerID: provider.id, providerKind: .openAI, model: "gpt-realtime")
        #expect(outcome == .applied(expected))
        let stored = try #require(state.conversation(for: conversation.id))
        #expect(stored.providerID == provider.id)
        #expect(stored.providerKind == .openAI)
        #expect(stored.modelID == "gpt-realtime")
        #expect(state.realtimeModelSelection(for: conversation.id) == expected)
        #expect(state.realtimeModelSelections[conversation.id] == nil)
        #expect(state.realtimeModelSelection(for: nil) == nil)
    }

    @Test("Selecting a realtime model does not write last-used: neither the conversation nor home changes lastUsedModelRef")
    func realtimeSelectionDoesNotWriteLastUsed() {
        let state = makeState()
        let provider = TestFactories.makeProvider(
            kind: .openAI,
            models: [TestFactories.makeModel(id: "gpt-4o", isDefault: true)]
        )
        state.providers = [provider]
        state.realtimeVoiceCatalog = { Self.realtimeCatalog() }
        let conversation = TestFactories.makeConversation(providerID: provider.id, providerKind: .openAI, modelID: "gpt-4o")
        state.upsertConversationProjection(conversation)
        let previous = LastUsedModelRef(providerID: provider.id, modelID: "gpt-4o")
        state.lastUsedModelRef = previous
        let (store, defaults, suiteName) = acceptedRealtimeDisclosures()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        state.selectRealtimeModel(providerID: provider.id, model: "gpt-realtime", for: conversation.id, disclosures: store)
        let homeOutcome = state.selectRealtimeModel(
            providerID: provider.id, model: "gpt-realtime-mini", for: nil, disclosures: store
        )

        #expect(homeOutcome == .applied(
            RealtimeModelSelection(providerID: provider.id, providerKind: .openAI, model: "gpt-realtime-mini")
        ))
        #expect(state.lastUsedModelRef == previous)
        #expect(state.activeModel?.model.id == "gpt-4o")
    }

    @Test("A synced conversation model that is a realtime model in the catalog is selected as realtime; without the catalog it counts as non-realtime")
    func syncedConversationWithRealtimeModelIsRealtimeSelected() {
        let state = makeState()
        let provider = TestFactories.makeProvider(
            kind: .openAI,
            models: [TestFactories.makeModel(id: "gpt-4o", isDefault: true)]
        )
        state.providers = [provider]
        let synced = TestFactories.makeConversation(providerID: provider.id, providerKind: .openAI, modelID: "gpt-realtime-mini")
        state.upsertConversationProjection(synced)

        state.realtimeVoiceCatalog = { nil }
        #expect(state.realtimeModelSelection(for: synced.id) == nil)

        state.realtimeVoiceCatalog = { Self.realtimeCatalog() }
        #expect(state.realtimeModelSelection(for: synced.id) == RealtimeModelSelection(
            providerID: provider.id, providerKind: .openAI, model: "gpt-realtime-mini"
        ))
        #expect(state.realtimeModelSelections.isEmpty)
    }

    /// Observes the @Observable read set: any write during the window sets the flag.
    private final class ObservedChange: @unchecked Sendable {
        var fired = false
    }

    private func observeChange(_ read: @escaping () -> Void) -> ObservedChange {
        let flag = ObservedChange()
        withObservationTracking(read) { flag.fired = true }
        return flag
    }

    @Test("Late catalog: a realtime model on a conversation is not judged realtime while the catalog is not ready and its fields are not rewritten; once the catalog is injected and a change is observed it is judged realtime (matches Android ChatRealtimeCatalogLateTest)")
    func conversation_keeps_realtime_selection_until_catalog_ready() throws {
        let state = makeState()
        let provider = TestFactories.makeProvider(
            kind: .openAI,
            models: [TestFactories.makeModel(id: "gpt-4o", isDefault: true)]
        )
        state.providers = [provider]
        let conversation = TestFactories.makeConversation(providerID: provider.id, providerKind: .openAI, modelID: "gpt-realtime")
        state.upsertConversationProjection(conversation)

        state.realtimeVoiceCatalog = { nil }
        let observed = observeChange { _ = state.realtimeModelSelection(for: conversation.id) }
        #expect(state.realtimeModelSelection(for: conversation.id) == nil)
        let early = try #require(state.conversation(for: conversation.id))
        #expect(early.providerID == provider.id)
        #expect(early.modelID == "gpt-realtime")

        state.realtimeVoiceCatalog = { Self.realtimeCatalog() }

        #expect(observed.fired)
        #expect(state.realtimeModelSelection(for: conversation.id) == RealtimeModelSelection(
            providerID: provider.id, providerKind: .openAI, model: "gpt-realtime"
        ))
        let ready = try #require(state.conversation(for: conversation.id))
        #expect(ready.providerID == provider.id)
        #expect(ready.providerKind == .openAI)
        #expect(ready.modelID == "gpt-realtime")
        #expect(state.realtimeModelSelections.isEmpty)
    }

    /// Conversation fixture for selecting a realtime row while the catalog is not ready: openAI realtime notice consented, catalog nil, conversation stays on gpt-4o.
    private func pendingRealtimeFixture() -> (AppState, Provider, Conversation, VoiceDisclosureStore, () -> Void) {
        let state = makeState()
        let provider = TestFactories.makeProvider(
            kind: .openAI,
            models: [TestFactories.makeModel(id: "gpt-4o", isDefault: true)]
        )
        state.providers = [provider]
        let conversation = TestFactories.makeConversation(providerID: provider.id, providerKind: .openAI, modelID: "gpt-4o")
        state.upsertConversationProjection(conversation)
        state.realtimeVoiceCatalog = { nil }
        let (store, defaults, suiteName) = acceptedRealtimeDisclosures()
        return (state, provider, conversation, store, { defaults.removePersistentDomain(forName: suiteName) })
    }

    @Test("Selecting a realtime row while the catalog is not ready stages it and leaves conversation fields untouched; when the catalog arrives and accepts the model it takes effect and no rejection signal is raised")
    func realtime_pick_before_catalog_applies_when_catalog_arrives() throws {
        let (state, provider, conversation, store, cleanup) = pendingRealtimeFixture()
        defer { cleanup() }
        let expected = RealtimeModelSelection(providerID: provider.id, providerKind: .openAI, model: "gpt-realtime")

        #expect(state.selectRealtimeModel(
            providerID: provider.id, model: "gpt-realtime", for: conversation.id, disclosures: store
        ) == .pending(expected))
        #expect(state.conversation(for: conversation.id)?.modelID == "gpt-4o")
        #expect(state.realtimeModelSelection(for: conversation.id) == nil)

        state.realtimeVoiceCatalog = { Self.realtimeCatalog() }

        let stored = try #require(state.conversation(for: conversation.id))
        #expect(stored.modelID == "gpt-realtime")
        #expect(state.realtimeModelSelection(for: conversation.id) == expected)
        #expect(state.realtimeSelectionGoneNotice == nil)
    }

    @Test("Selecting a realtime row while the catalog is not ready: the catalog arrives but rejects the model, so the conversation is not rewritten and a one-shot rejection signal is set and cleared once taken")
    func realtime_pick_catalog_lacks_model_reports_gone() throws {
        let (state, provider, conversation, store, cleanup) = pendingRealtimeFixture()
        defer { cleanup() }

        #expect(state.selectRealtimeModel(
            providerID: provider.id, model: "gpt-realtime-retired", for: conversation.id, disclosures: store
        ) == .pending(RealtimeModelSelection(providerID: provider.id, providerKind: .openAI, model: "gpt-realtime-retired")))

        state.realtimeVoiceCatalog = { Self.realtimeCatalog() }

        #expect(state.conversation(for: conversation.id)?.modelID == "gpt-4o")
        #expect(state.realtimeModelSelection(for: conversation.id) == nil)
        let notice = try #require(state.realtimeSelectionGoneNotice)
        #expect(notice.conversationID == conversation.id)
        #expect(notice.model == "gpt-realtime-retired")
        state.consumeRealtimeSelectionGoneNotice(notice)
        #expect(state.realtimeSelectionGoneNotice == nil)
    }

    @Test("First realtime selection after consenting to the notice while the catalog is still not ready stages the selection and leaves conversation fields untouched; the catalog arrival then judges it")
    func disclosure_accept_keeps_pending_selection_until_catalog_ready() throws {
        let (state, provider, conversation, _, cleanup) = pendingRealtimeFixture()
        defer { cleanup() }
        let suiteName = "ProviderAppStateFlowTests-disclosure-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let fresh = VoiceDisclosureStore(defaults: defaults)
        let expected = RealtimeModelSelection(providerID: provider.id, providerKind: .openAI, model: "gpt-realtime")

        #expect(state.selectRealtimeModel(
            providerID: provider.id, model: "gpt-realtime", for: conversation.id, disclosures: fresh
        ) == .needsDisclosure(expected))
        #expect(!state.resolveRealtimeModelDisclosure(
            expected, for: conversation.id, accepted: true, disclosures: fresh
        ))
        #expect(fresh.hasAccepted(.openAI, direction: .realtime))
        #expect(state.conversation(for: conversation.id)?.modelID == "gpt-4o")
        #expect(state.realtimeModelSelection(for: conversation.id) == nil)

        state.realtimeVoiceCatalog = { Self.realtimeCatalog() }

        #expect(state.conversation(for: conversation.id)?.modelID == "gpt-realtime")
        #expect(state.realtimeModelSelection(for: conversation.id) == expected)
        #expect(state.realtimeSelectionGoneNotice == nil)
    }

    @Test("Staging keeps only the most recent selection: a new realtime row overrides the old staging, and selecting a text model clears it; catalog arrival judges only the most recent one")
    func newer_pick_replaces_pending_realtime() throws {
        let (state, provider, conversation, store, cleanup) = pendingRealtimeFixture()
        defer { cleanup() }

        state.selectRealtimeModel(providerID: provider.id, model: "gpt-realtime-retired", for: conversation.id, disclosures: store)
        state.selectRealtimeModel(providerID: provider.id, model: "gpt-realtime-mini", for: conversation.id, disclosures: store)
        state.realtimeVoiceCatalog = { Self.realtimeCatalog() }

        #expect(state.conversation(for: conversation.id)?.modelID == "gpt-realtime-mini")
        #expect(state.realtimeSelectionGoneNotice == nil)

        // Selecting a text model clears staging: a later catalog arrival (content change) does not judge it.
        state.realtimeVoiceCatalog = { nil }
        state.selectRealtimeModel(providerID: provider.id, model: "gpt-realtime", for: conversation.id, disclosures: store)
        state.selectModel(modelID: "gpt-4o", providerID: provider.id, for: conversation.id)
        state.realtimeVoiceCatalog = { Self.realtimeCatalog() }

        #expect(state.conversation(for: conversation.id)?.modelID == "gpt-4o")
        #expect(state.realtimeModelSelection(for: conversation.id) == nil)
        #expect(state.realtimeSelectionGoneNotice == nil)
    }

    @Test("Late catalog: the home realtime selection reads nil while the catalog is not ready, the stored value is kept and last-used is not rewritten; once the catalog is injected and a change is observed it is judged realtime")
    func draft_keeps_realtime_selection_until_catalog_ready() {
        let state = makeState()
        let provider = TestFactories.makeProvider(
            kind: .openAI,
            models: [TestFactories.makeModel(id: "gpt-4o", isDefault: true)]
        )
        state.providers = [provider]
        let previous = LastUsedModelRef(providerID: provider.id, modelID: "gpt-4o")
        state.lastUsedModelRef = previous
        let (store, defaults, suiteName) = acceptedRealtimeDisclosures()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        state.realtimeVoiceCatalog = { nil }
        let expected = RealtimeModelSelection(providerID: provider.id, providerKind: .openAI, model: "gpt-realtime")
        #expect(state.selectRealtimeModel(
            providerID: provider.id, model: "gpt-realtime", for: nil, disclosures: store
        ) == .pending(expected))
        let observed = observeChange { _ = state.realtimeModelSelection(for: nil) }
        #expect(state.realtimeModelSelection(for: nil) == nil)
        #expect(state.realtimeModelSelections[nil] == nil)

        state.realtimeVoiceCatalog = { Self.realtimeCatalog() }

        #expect(observed.fired)
        #expect(state.realtimeModelSelection(for: nil) == expected)
        #expect(state.realtimeModelSelections[nil] == expected)
        #expect(state.realtimeSelectionGoneNotice == nil)
        #expect(state.lastUsedModelRef == previous)
        #expect(state.activeModel?.model.id == "gpt-4o")
    }

    @Test("Home realtime row selected while the catalog is not ready: the catalog arrives and rejects it, the home selection is untouched, and a one-shot signal (conversation nil) makes home show a toast")
    func draft_pick_catalog_lacks_model_reports_gone() throws {
        let state = makeState()
        let provider = TestFactories.makeProvider(
            kind: .openAI,
            models: [TestFactories.makeModel(id: "gpt-4o", isDefault: true)]
        )
        state.providers = [provider]
        let (store, defaults, suiteName) = acceptedRealtimeDisclosures()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        state.realtimeVoiceCatalog = { nil }
        let retired = RealtimeModelSelection(providerID: provider.id, providerKind: .openAI, model: "gpt-realtime-retired")
        #expect(state.selectRealtimeModel(
            providerID: provider.id, model: "gpt-realtime-retired", for: nil, disclosures: store
        ) == .pending(retired))

        state.realtimeVoiceCatalog = { Self.realtimeCatalog() }

        #expect(state.realtimeModelSelections[nil] == nil)
        #expect(state.realtimeModelSelection(for: nil) == nil)
        let notice = try #require(state.realtimeSelectionGoneNotice)
        #expect(notice.conversationID == nil)
        #expect(notice.model == "gpt-realtime-retired")

        // With the catalog ready, a home selection of a row the catalog rejects is .unavailable at once (home shows a toast) and is not kept in memory.
        #expect(state.selectRealtimeModel(
            providerID: provider.id, model: "gpt-realtime-retired", for: nil, disclosures: store
        ) == .unavailable)
        #expect(state.realtimeModelSelections[nil] == nil)
    }

    @Test("Home realtime selection is re-checked on read: a connection changed to subscription login or deleted reads nil and the stored value is kept; switching back to API Key and reading again judges it realtime")
    func draft_realtime_selection_rechecked_on_read() {
        let state = makeState()
        var provider = TestFactories.makeProvider(
            kind: .openAI,
            models: [TestFactories.makeModel(id: "gpt-4o", isDefault: true)]
        )
        state.providers = [provider]
        state.realtimeVoiceCatalog = { Self.realtimeCatalog() }
        let (store, defaults, suiteName) = acceptedRealtimeDisclosures()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let expected = RealtimeModelSelection(providerID: provider.id, providerKind: .openAI, model: "gpt-realtime")
        state.selectRealtimeModel(providerID: provider.id, model: "gpt-realtime", for: nil, disclosures: store)
        #expect(state.realtimeModelSelection(for: nil) == expected)

        provider.authMode = .subscription
        state.providers = [provider]
        #expect(state.realtimeModelSelection(for: nil) == nil)
        #expect(state.realtimeModelSelections[nil] == expected)

        state.providers = []
        #expect(state.realtimeModelSelection(for: nil) == nil)
        #expect(state.realtimeModelSelections[nil] == expected)

        provider.authMode = .apiKey
        state.providers = [provider]
        #expect(state.realtimeModelSelection(for: nil) == expected)
    }

    @Test("The same catalog arriving again does not change the revision and does not re-judge; the revision increments only when content changes")
    func same_catalog_push_keeps_revision() {
        let state = makeState()
        state.realtimeVoiceCatalog = { Self.realtimeCatalog() }
        let revision = state.realtimeVoiceCatalogRevision
        let observed = observeChange { _ = state.realtimeVoiceCatalogRevision }

        state.realtimeVoiceCatalog = { Self.realtimeCatalog() }

        #expect(state.realtimeVoiceCatalogRevision == revision)
        #expect(!observed.fired)

        state.realtimeVoiceCatalog = { nil }

        #expect(state.realtimeVoiceCatalogRevision == revision &+ 1)
        #expect(observed.fired)
    }

    @Test("Catalog not ready does not affect text models: the conversation stays on the enabled text model, is not judged realtime, and its fields are not rewritten; after catalog injection it is still a text model")
    func catalog_not_ready_still_converges_enabled_text_model() throws {
        let state = makeState()
        let provider = TestFactories.makeProvider(
            kind: .openAI,
            models: [TestFactories.makeModel(id: "gpt-4o", isDefault: true)]
        )
        state.providers = [provider]
        let conversation = TestFactories.makeConversation(providerID: provider.id, providerKind: .openAI, modelID: "gpt-4o")
        state.upsertConversationProjection(conversation)

        state.realtimeVoiceCatalog = { nil }
        #expect(state.realtimeModelSelection(for: conversation.id) == nil)
        #expect(state.conversation(for: conversation.id)?.modelID == "gpt-4o")

        state.realtimeVoiceCatalog = { Self.realtimeCatalog() }

        #expect(state.realtimeModelSelection(for: conversation.id) == nil)
        let stored = try #require(state.conversation(for: conversation.id))
        #expect(stored.providerID == provider.id)
        #expect(stored.modelID == "gpt-4o")
    }

    @Test("A conversation model on a relay connection is not realtime even if the catalog marks it realtime (only the official apiKey counts)")
    func relayConnectionWithRealtimeModelIdIsNotRealtime() {
        let state = makeState()
        let relay = TestFactories.makeProvider(
            kind: .relay,
            models: [TestFactories.makeModel(id: "gpt-realtime", isDefault: true)]
        )
        var subscription = TestFactories.makeProvider(
            kind: .openAI,
            models: [TestFactories.makeModel(id: "gpt-4o", isDefault: true)]
        )
        subscription.authMode = .subscription
        state.providers = [relay, subscription]
        state.realtimeVoiceCatalog = { Self.realtimeCatalog() }
        let onRelay = TestFactories.makeConversation(providerID: relay.id, providerKind: .relay, modelID: "gpt-realtime")
        let onSubscription = TestFactories.makeConversation(
            providerID: subscription.id, providerKind: .openAI, modelID: "gpt-realtime"
        )
        state.upsertConversationProjection(onRelay)
        state.upsertConversationProjection(onSubscription)

        #expect(state.realtimeModelSelection(for: onRelay.id) == nil)
        #expect(state.realtimeModelSelection(for: onSubscription.id) == nil)
    }

    @Test("Cancelling realtime switches the conversation back to the last-used text model without writing last-used")
    func clearRealtimeSelectionRestoresLastUsedTextModel() throws {
        let state = makeState()
        let provider = TestFactories.makeProvider(
            kind: .openAI,
            models: [
                TestFactories.makeModel(id: "gpt-4o", isDefault: true),
                TestFactories.makeModel(id: "gpt-4o-mini")
            ]
        )
        state.providers = [provider]
        state.realtimeVoiceCatalog = { Self.realtimeCatalog() }
        let previous = LastUsedModelRef(providerID: provider.id, modelID: "gpt-4o-mini")
        state.lastUsedModelRef = previous
        let conversation = TestFactories.makeConversation(providerID: provider.id, providerKind: .openAI, modelID: "gpt-4o")
        state.upsertConversationProjection(conversation)
        let (store, defaults, suiteName) = acceptedRealtimeDisclosures()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        state.selectRealtimeModel(providerID: provider.id, model: "gpt-realtime", for: conversation.id, disclosures: store)
        #expect(state.realtimeModelSelection(for: conversation.id) != nil)

        state.clearRealtimeModelSelection(for: conversation.id)

        let stored = try #require(state.conversation(for: conversation.id))
        #expect(stored.providerID == provider.id)
        #expect(stored.modelID == "gpt-4o-mini")
        #expect(state.realtimeModelSelection(for: conversation.id) == nil)
        #expect(state.lastUsedModelRef == previous)
    }

    @Test("Selecting a text model clears this conversation's realtime selection; other conversations are untouched")
    func selectTextModelClearsRealtimeSelection() {
        let state = makeState()
        let provider = TestFactories.makeProvider(
            kind: .openAI,
            models: [
                TestFactories.makeModel(id: "gpt-4o", isDefault: true),
                TestFactories.makeModel(id: "gpt-4o-mini")
            ]
        )
        state.providers = [provider]
        state.realtimeVoiceCatalog = { Self.realtimeCatalog() }
        let conversation = TestFactories.makeConversation(providerID: provider.id, providerKind: .openAI, modelID: "gpt-4o")
        state.upsertConversationProjection(conversation)
        let (store, defaults, suiteName) = acceptedRealtimeDisclosures()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        state.selectRealtimeModel(providerID: provider.id, model: "gpt-realtime", for: conversation.id, disclosures: store)
        #expect(state.realtimeModelSelection(for: conversation.id) != nil)
        state.selectRealtimeModel(providerID: provider.id, model: "gpt-realtime", for: nil, disclosures: store)

        state.selectModel(modelID: "gpt-4o-mini", providerID: provider.id, for: conversation.id)

        #expect(state.realtimeModelSelection(for: conversation.id) == nil)
        #expect(state.conversation(for: conversation.id)?.modelID == "gpt-4o-mini")
        #expect(state.realtimeModelSelection(for: nil) != nil)

        state.clearRealtimeModelSelection(for: nil)
        #expect(state.realtimeModelSelection(for: nil) == nil)
    }

    @Test("Cold start: home has no realtime selection (home keeps it in memory only)")
    func coldStartHasNoRealtimeSelection() {
        let state = makeState()
        #expect(state.realtimeModelSelections.isEmpty)
        #expect(state.realtimeModelSelection(for: nil) == nil)
    }

    @Test("The first realtime voice turn on home creates the conversation: it takes the current pill model and writes no last-used")
    func createConversationForRealtimeVoiceUsesActiveModel() throws {
        let state = makeState()
        let provider = TestFactories.makeProvider(
            kind: .relay,
            models: [
                TestFactories.makeModel(id: "relay-default", isDefault: true),
                TestFactories.makeModel(id: "relay-chat")
            ]
        )
        state.providers = [provider]
        state.setActiveModel(providerID: provider.id, modelID: "relay-chat")
        let active = try #require(state.activeModel)
        #expect(active.model.id == "relay-chat")
        let lastUsed = state.lastUsedModelRef

        let id = try #require(state.createConversationForRealtimeVoice())

        let conversation = try #require(state.conversation(for: id))
        #expect(conversation.providerID == provider.id)
        #expect(conversation.modelID == "relay-chat")
        #expect(state.lastUsedModelRef == lastUsed)
    }

    @Test("Adding a connection with a verified model: writes that model as last-used")
    func completeProviderSetupWithVerifiedModelWritesLastUsed() {
        let state = makeState()
        let provider = TestFactories.makeProvider(
            kind: .openAI,
            models: [
                TestFactories.makeModel(id: "gpt-4o", isDefault: true),
                TestFactories.makeModel(id: "gpt-4o-mini")
            ]
        )
        state.providers = [provider]
        state.lastUsedModelRef = nil

        state.completeProviderSetup(providerID: provider.id, entryPoint: .modelPicker, verifiedModelID: "gpt-4o-mini")

        #expect(state.lastUsedModelRef?.providerID == provider.id)
        #expect(state.lastUsedModelRef?.modelID == "gpt-4o-mini")
    }

    @Test("A conversation with an empty modelID on a connection without credentials still resolves through the new-chat chain and does not end up with no model")
    func currentModelForEmptyModelIDIgnoresMissingCredential() {
        let state = makeState()
        let provider = TestFactories.makeProvider(
            kind: .openAI,
            models: [TestFactories.makeModel(id: "gpt-4o-mini")],
            apiKey: "",
            apiKeyPreview: ""
        )
        state.providers = [provider]
        state.lastUsedModelRef = nil
        let conversation = TestFactories.makeConversation(providerID: provider.id, modelID: "")

        #expect(state.fallbackModel(in: provider)?.id == "gpt-4o-mini")
        #expect(state.currentModel(for: conversation)?.id == "gpt-4o-mini")
    }

    @Test("Undoing a removal restores the default model: only the connection default is restored and no last-used is written")
    func undoRemovalRestoresDefaultWithoutWritingLastUsed() {
        let state = makeState()
        let provider = TestFactories.makeProvider(
            kind: .openAI,
            models: [
                TestFactories.makeModel(id: "gpt-4o", isDefault: true),
                TestFactories.makeModel(id: "gpt-4o-mini")
            ]
        )
        state.providers = [provider]
        let ref = LastUsedModelRef(providerID: provider.id, modelID: "gpt-4o")
        state.lastUsedModelRef = ref

        state.restoreDefaultModel(modelID: "gpt-4o-mini", for: provider.id)

        #expect(state.provider(for: provider.id)?.models.first(where: { $0.isDefault })?.id == "gpt-4o-mini")
        #expect(state.lastUsedModelRef == ref)
    }

    /// An unscoped new chat does not rewrite last-used with the fallback result; the chat page shows the retired hint from the unrewritten last-used.
    @Test("Unscoped new chat: a retired last-used model is not rewritten, and the chat page shows a one-time retired hint")
    func unscopedNewChatKeepsRetiredLastUsedForHint() async throws {
        let retired = TestFactories.makeModel(id: "gpt-4-legacy", name: "GPT-4 Legacy", canonicalModelId: "gpt-4-legacy")
        let fallback = TestFactories.makeModel(id: "gpt-5.4", name: "GPT-5.4", canonicalModelId: "gpt-5.4")
        let provider = TestFactories.makeProvider(kind: .openAI, models: [retired, fallback], catalogModels: [retired, fallback])
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(json: ChatScreenProjectionTests.retiredMetadataJSON)

        let state = makeState()
        state.providers = [provider]
        state.navigation.path = []
        let ref = LastUsedModelRef(providerID: provider.id, modelID: "gpt-4-legacy")
        state.lastUsedModelRef = ref

        state.startNewChat()

        #expect(state.navigation.path.last == .chat(conversationID: nil))
        #expect(state.lastUsedModelRef == ref)
        #expect(state.activeModel?.model.id == "gpt-5.4")
        #expect(!state.pendingNewChatModelPicker)
        // The new-chat page of ChatView (requestedProviderID is nil) judges the hint from the current appState.
        let hint = NewChatRetiredFallbackHint.resolve(
            requestedProviderID: nil,
            providers: state.providers,
            lastUsedModelRef: state.lastUsedModelRef
        )
        #expect(hint == NewChatRetiredFallbackHint(providerID: provider.id, retiredModelID: "gpt-4-legacy", fallbackModelName: "GPT-5.4"))
        await MetadataClient.shared.resetForTesting()
    }

    @Test("Unscoped new chat with an empty chain but with connections: opens the new-chat page and requests the model picker, without going to add-connection")
    func unscopedNewChatWithEmptyChainOpensModelPicker() async {
        let state = makeState()
        let provider = TestFactories.makeProvider(kind: .openAI, models: [], catalogModels: [])
        state.providers = [provider]
        state.lastUsedModelRef = nil
        state.navigation.path = []
        state.startNewChat()

        #expect(state.navigation.path.last == .chat(conversationID: nil))
        #expect(state.pendingNewChatModelPicker)
        #expect(state.lastUsedModelRef == nil)

        state.pendingNewChatModelPicker = false
        state.navigation.path = []
        let ready = await state.ensureActiveModelWithProviderFallback(prefillOnModelPicker: "draft from home")
        #expect(!ready)
        #expect(state.pendingNewChatModelPicker)
        #expect(state.navigation.path.last == .chat(conversationID: nil))
        // The draft in the home input box is carried into the new-chat composer (consumed when ChatView appears); it is neither lost nor sent automatically.
        #expect(state.pendingComposerPrefill == "draft from home")
    }

    @Test("startNewChat without provider opens provider setup")
    func startNewChatWithoutProviderOpensProviders() {
        let state = makeState()
        state.providers = []
        state.navigation.path = []

        state.startNewChat()

        #expect(state.navigation.path.last == .providerSetup(entryPoint: .providers))
        #expect(state.selectedTab == .providers)
    }

    @Test("unresolvedProviderIssue returns last-used issue provider")
    func unresolvedIssuePrefersLastUsed() {
        let state = makeState()
        let provider = TestFactories.makeProvider(status: .issue("oops"), models: [], catalogModels: [])
        state.providers = [provider]
        state.lastUsedModelRef = LastUsedModelRef(providerID: provider.id, modelID: "unused")

        let issue = state.unresolvedProviderIssue

        #expect(issue?.providerID == provider.id)
        #expect(issue?.message == "oops")
    }

    @Test("unresolvedProviderIssue falls back to first issue provider when active model missing")
    func unresolvedIssueFallsBack() {
        let state = makeState()
        let issueProvider = TestFactories.makeProvider(status: .issue("down"), models: [], catalogModels: [], apiKey: "key-2")
        state.providers = [issueProvider]
        state.lastUsedModelRef = nil

        let issue = state.unresolvedProviderIssue

        #expect(issue?.providerID == issueProvider.id)
        #expect(issue?.message == "down")
    }

    @Test("activeModel and currentModel resolve from enabled models without full catalog projection")
    func activeModelAndCurrentModelAvoidCatalogProjection() {
        let state = makeState()
        let provider = TestFactories.makeProvider(
            kind: .openAI,
            models: [
                TestFactories.makeModel(id: "gpt-4o", name: "GPT-4o", isDefault: true, canonicalModelId: "gpt-4o"),
                TestFactories.makeModel(id: "gpt-4o-mini", name: "GPT-4o Mini", canonicalModelId: "gpt-4o-mini")
            ]
        )
        let conversation = TestFactories.makeConversation(
            providerID: provider.id,
            modelID: "gpt-4o-2024-08-06"
        )
        state.providers = [provider]
        state.lastUsedModelRef = LastUsedModelRef(
            providerID: provider.id,
            modelID: "gpt-4o-2024-08-06"
        )

        ProviderCatalogResolver.debugResolveCallCount = 0
        let active = state.activeModel
        let current = state.currentModel(for: conversation)

        #expect(active?.model.id == "gpt-4o")
        #expect(current?.id == "gpt-4o")
        #expect(ProviderCatalogResolver.debugResolveCallCount == 0)
    }

    @Test("Persisted Conversation Model IDAvoids Catalog Projection")
    func persistedConversationModelIDAvoidsCatalogProjection() async throws {
        try await withOpenAIMetadata {
            let provider = TestFactories.makeProvider(
                kind: .openAI,
                models: [
                    TestFactories.makeModel(
                        id: "gpt-4o",
                        name: "GPT-4o",
                        isDefault: true,
                        canonicalModelId: "gpt-4o"
                    )
                ]
            )

            ProviderCatalogResolver.debugResolveCallCount = 0
            let storedModelID = AppState.persistedConversationModelID(
                requestedModelID: "o4-mini-2026-04-10",
                in: provider,
                metadata: MetadataClient.shared
            )

            #expect(storedModelID == "o4-mini")
            #expect(ProviderCatalogResolver.debugResolveCallCount == 0)
        }
    }
}
