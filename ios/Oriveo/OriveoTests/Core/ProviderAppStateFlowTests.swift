import Foundation
import Testing
@testable import Oriveo

@Suite("Provider + AppState flow helpers", .serialized)
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
