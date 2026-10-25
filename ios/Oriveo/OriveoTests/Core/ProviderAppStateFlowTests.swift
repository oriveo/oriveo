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

    @Test("Start realtime voice from home: writes the model currently shown in the pill as last-used")
    func realtimeVoiceStartFromHomeWritesPillModel() throws {
        let state = makeState()
        let provider = TestFactories.makeProvider(
            kind: .relay,
            models: [TestFactories.makeModel(id: "relay-default", isDefault: true)]
        )
        state.providers = [provider]
        state.lastUsedModelRef = nil
        let active = try #require(state.activeModel)

        state.recordLastUsedForRealtimeVoice(conversationID: nil)

        #expect(state.lastUsedModelRef?.providerID == active.provider.id)
        #expect(state.lastUsedModelRef?.modelID == active.model.id)
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
