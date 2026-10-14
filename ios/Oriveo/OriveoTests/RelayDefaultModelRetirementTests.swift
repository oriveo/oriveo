import Foundation
import Testing
@testable import Oriveo

/// Only counts requests: when the conversation model has been removed, send / retry / continue / regenerate must make zero requests.
private final class RelayRetirementRequestCounter: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var count = 0

    static func reset() { lock.withLock { count = 0 } }
    static var requestCount: Int { lock.withLock { count } }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RelayRetirementRequestCounter.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.withLock { Self.count += 1 }
        let response = HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data())
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// RD-1: relay default model retirement. Each case in the fixture `shared/test-fixtures/relay/model-selection.v1.json`
/// is one RD1-SELECT entry that runs the production fallback function and the production conversation-model state resolution.
@Suite("RD-1 relay default model retirement", .serialized)
@MainActor
struct RelayDefaultModelRetirementTests {

    // MARK: - Fixtures

    nonisolated static func fixture() throws -> [String: Any] {
        var cursor = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while cursor.path != "/" {
            let candidate = cursor.appendingPathComponent("shared/test-fixtures/relay/model-selection.v1.json")
            if FileManager.default.fileExists(atPath: candidate.path) {
                let object = try JSONSerialization.jsonObject(with: Data(contentsOf: candidate))
                return try #require(object as? [String: Any])
            }
            cursor.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }

    nonisolated static let caseIDs: [String] = {
        let cases = (try? fixture()["cases"] as? [[String: Any]]) ?? []
        return cases.compactMap { $0["id"] as? String }
    }()

    private static func makeState() -> AppState {
        AppState(
            seedDemoData: false,
            sessionUID: "rd1-\(UUID().uuidString)",
            providerSession: RelayRetirementRequestCounter.session()
        )
    }

    private static func relayModel(_ id: String, isDefault: Bool = false) -> AIModel {
        TestFactories.makeModel(id: id, name: id, capabilities: [.text], isDefault: isDefault)
    }

    private static func relayProvider(
        name: String = "My Relay",
        models: [AIModel],
        catalogModels: [AIModel] = [],
        requested: RelayRequestedConfig = RelayRequestedConfig(transport: .openaiChatCompletions, authMode: .bearer)
    ) -> Provider {
        var provider = TestFactories.makeProvider(
            kind: .relay,
            models: models,
            catalogModels: catalogModels,
            apiKey: "sk-relay",
            apiKeyPreview: "sk-...relay",
            baseURLText: "https://relay.example.com/v1",
            customName: name
        )
        provider.relayRequested = requested
        return provider
    }

    // MARK: - RD1-SELECT-<id>

    @Test("RD1-SELECT-<id>: fallback model / verification sample / removed conversation model (fixture)", arguments: Self.caseIDs)
    func RD1_SELECT_fixture(_ caseID: String) throws {
        let cases = try #require(try Self.fixture()["cases"] as? [[String: Any]])
        let entry = try #require(cases.first { $0["id"] as? String == caseID })
        let raw = try #require(entry["provider"] as? [String: Any])
        let expect = try #require(entry["expect"] as? [String: Any])
        let label = "RD1-SELECT-\(caseID)"

        let rawKind = try #require(raw["kind"] as? String)
        let kind = try #require(ProviderKind(rawValue: rawKind) ?? (rawKind == "relay" ? .relay : nil), "\(label) kind")
        let fixtureProviderID = try #require(raw["id"] as? String)
        let providerID = UUID()
        let models = try #require(raw["models"] as? [[String: Any]]).map { model in
            Self.relayModel(model["id"] as? String ?? "", isDefault: model["isDefault"] as? Bool ?? false)
        }
        let catalog = (raw["catalogModels"] as? [String] ?? []).map { Self.relayModel($0) }
        var provider = TestFactories.makeProvider(
            id: providerID,
            kind: kind,
            models: models,
            catalogModels: catalog,
            customName: raw["name"] as? String
        )
        if kind == .relay {
            provider.relayRequested = RelayRequestedConfig(
                transport: .openaiChatCompletions,
                engineProfile: raw["engineProfile"] as? String
            )
        }

        let lastUsed = (entry["lastUsedModelRef"] as? [String: Any]).map { ref in
            LastUsedModelRef(
                providerID: ref["providerId"] as? String == fixtureProviderID ? providerID : UUID(),
                modelID: ref["modelId"] as? String ?? ""
            )
        }

        if kind == .relay {
            let fallback = ProviderSelectionSnapshot.relayFallbackModel(in: provider, lastUsedModelRef: lastUsed)
            #expect(fallback?.id == expect["fallbackModelId"] as? String, "\(label) fallback")
            let sample = ProviderSelectionSnapshot.relayVerificationSampleModelID(in: provider, lastUsedModelRef: lastUsed)
            #expect(sample == expect["verificationSampleModelId"] as? String, "\(label) sample")
        }

        // Production conversation state resolution: after the conversation is saved, run one more Provider write (which triggers conversation normalization); the conversation model must not be rewritten.
        let state = Self.makeState()
        state.providers = [provider]
        state.lastUsedModelRef = lastUsed
        let storedModelID = entry["conversationModelId"] as? String ?? ""
        let conversation = TestFactories.makeConversation(
            providerID: providerID,
            providerKind: kind,
            modelID: storedModelID
        )
        state.upsertConversationProjection(conversation)
        state.providerManager.updateProvider(provider)

        let current = try #require(state.conversation(for: conversation.id))
        let resolvedState = state.conversationModelState(for: current)
        let expectedRemoved = expect["removed"] as? Bool ?? false
        if expectedRemoved {
            #expect(resolvedState == .removed(connectionName: expect["connectionName"] as? String ?? ""), "\(label) state")
            #expect(state.sendableModel(for: current, provider: provider) == nil, "\(label) is not silently replaced")
        } else {
            #expect(resolvedState == .resolved, "\(label) state")
        }
        if let expectedConversationModel = expect["conversationModelId"] as? String {
            #expect(current.modelID == expectedConversationModel, "\(label) conversation model unchanged")
        }
        if kind == .relay, storedModelID.isEmpty, let fallbackID = expect["fallbackModelId"] as? String {
            // An empty conversation model uses the fallback.
            #expect(state.currentModel(for: current)?.id == fallbackID, "\(label) an empty conversation model uses the fallback")
        }
    }

    // MARK: - RD1-BANNER

    private func makeRemovedConversation(
        in state: AppState
    ) -> (provider: Provider, conversation: Conversation, assistantID: UUID) {
        let provider = Self.relayProvider(
            models: [Self.relayModel("gpt-5.4", isDefault: true)],
            catalogModels: [Self.relayModel("gpt-5.4"), Self.relayModel("claude-4-haiku")]
        )
        let assistantID = UUID()
        let conversation = TestFactories.makeConversation(
            providerID: provider.id,
            providerKind: .relay,
            modelID: "claude-4-haiku",
            messages: [
                TestFactories.makeMessage(role: .user, text: "Hi", providerID: provider.id, providerKind: .relay, modelID: "claude-4-haiku"),
                TestFactories.makeMessage(
                    id: assistantID,
                    role: .assistant,
                    text: "partial",
                    providerID: provider.id,
                    providerKind: .relay,
                    modelID: "claude-4-haiku",
                    state: .failed
                ),
            ]
        )
        state.providers = [provider]
        state.upsertConversationProjection(conversation)
        return (provider, conversation, assistantID)
    }

    @Test("RD1-BANNER-01 conversation model removed: the banner is visible and sending is unavailable; send / retry / continue / regenerate make zero requests")
    func RD1_BANNER_01_removedConversationBlocksSending() async throws {
        RelayRetirementRequestCounter.reset()
        let state = Self.makeState()
        let (provider, conversation, assistantID) = makeRemovedConversation(in: state)

        let context = try #require(resolveChatScreenContext(
            requestedProviderID: provider.id,
            requestedModelID: conversation.modelID,
            providers: state.providers,
            activeModel: state.activeModel,
            primaryProvider: state.primaryProvider,
            lastUsedModelRef: state.lastUsedModelRef
        ))
        #expect(context.model == nil)
        #expect(context.needsConversationRepair == false)
        let banner = try #require(ChatModelRemovedBanner.resolve(context))
        #expect(banner.connectionName == "My Relay")
        #expect(banner.message.contains("My Relay"))
        #expect(ChatModelRemovedBanner.messageKey == "This chat’s model is no longer in %@.")
        #expect(ChatModelRemovedBanner.actionKey == "Choose model")
        #expect(banner.actionTitle == L10n.tr("Choose model", table: .chat))
        #expect(ChatModelRemovedBanner.isSendEnabled(hasComposerContent: true, controlsDisabled: false, banner: banner) == false)
        #expect(ChatModelRemovedBanner.isSendEnabled(hasComposerContent: true, controlsDisabled: false, banner: nil))

        let returned = await state.sendMessage("Hello again", in: conversation.id)
        await state.retryMessage(messageID: assistantID, in: conversation.id)
        await state.continueMessage(messageID: assistantID, in: conversation.id)
        await state.regenerateMessage(messageID: assistantID, in: conversation.id)
        try? await Task.sleep(nanoseconds: 200_000_000)

        #expect(returned == nil)
        #expect(RelayRetirementRequestCounter.requestCount == 0)
        let after = try #require(state.conversation(for: conversation.id))
        #expect(after.modelID == "claude-4-haiku")
        #expect(after.messages.count == 2)
    }

    @Test("RD1-BANNER-02 picking a new model through the production selection path in a removed conversation: the conversation model updates and the banner disappears")
    func RD1_BANNER_02_choosingModelClearsBanner() async throws {
        RelayRetirementRequestCounter.reset()
        let state = Self.makeState()
        let (provider, conversation, _) = makeRemovedConversation(in: state)

        state.selectModel(modelID: "gpt-5.4", providerID: provider.id, for: conversation.id)

        let updated = try #require(state.conversation(for: conversation.id))
        #expect(updated.modelID == "gpt-5.4")
        #expect(state.conversationModelState(for: updated) == .resolved)
        let context = try #require(resolveChatScreenContext(
            requestedProviderID: provider.id,
            requestedModelID: updated.modelID,
            providers: state.providers,
            activeModel: state.activeModel,
            primaryProvider: state.primaryProvider,
            lastUsedModelRef: state.lastUsedModelRef
        ))
        #expect(ChatModelRemovedBanner.resolve(context) == nil)
        #expect(context.model?.id == "gpt-5.4")

        // Control: after switching back to an available model, sending really goes out (proves BANNER-01's zero requests come from the removal check, not some other gate).
        _ = await state.sendMessage("Hello again", in: conversation.id)
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(RelayRetirementRequestCounter.requestCount > 0)
    }

    // MARK: - RD1-NEWCHAT-01

    @Test("RD1-NEWCHAT-01 when lastUsedModelRef points elsewhere, starting a new chat from a relay selects the first enabled model (the old isDefault is ignored)")
    func RD1_NEWCHAT_01_newChatUsesFirstEnabledModel() {
        let state = Self.makeState()
        let relay = Self.relayProvider(models: [
            Self.relayModel("first-model"),
            Self.relayModel("legacy-default", isDefault: true),
        ])
        let official = TestFactories.makeProvider(
            kind: .openAI,
            models: [TestFactories.makeModel(id: "gpt-4o", name: "GPT-4o", isDefault: true)]
        )
        state.providers = [relay, official]
        state.lastUsedModelRef = LastUsedModelRef(providerID: official.id, modelID: "gpt-4o")

        state.startNewChat(preferredProviderID: relay.id)

        #expect(state.lastUsedModelRef == LastUsedModelRef(providerID: relay.id, modelID: "first-model"))
        #expect(ProviderSelectionSnapshot.defaultModel(in: relay)?.id == "first-model")
        #expect(relay.defaultModel?.id == "first-model")
    }

    // MARK: - RD1-WRITE-01

    @Test("RD1-WRITE-01 after the production register / add-save path: no model isDefault, relayRequested.modelID is empty, and the selected model is enabled")
    func RD1_WRITE_01_registerAndSaveWriteNoDefault() throws {
        let state = Self.makeState()
        let requested = RelayRequestedConfig(transport: .openaiChatCompletions, authMode: .bearer, modelID: "model-b")
        var provider = state.providerManager.registerRelay(
            name: "Write Relay",
            endpoint: "https://relay.example.com/v1",
            apiKey: "sk-relay",
            relayRequested: requested,
            catalogModelIDs: ["model-a", "model-b", "model-c"],
            preferredModelID: "model-b"
        )
        // Add page save: write back the connection config and make sure the sample is enabled (the same calls as RelayQuickSetupFlow.save / manual submit).
        provider.relayRequested = requested.withoutModelID
        state.providerManager.updateProvider(provider)
        #expect(state.providerManager.ensureModelEnabledAsDefault(providerID: provider.id, modelID: "model-b"))
        #expect(state.providerManager.ensureModelEnabledAsDefault(providerID: provider.id, modelID: "manual-z"))
        state.completeProviderSetup(providerID: provider.id, entryPoint: .providers, verifiedModelID: "model-b")

        let stored = try #require(state.provider(for: provider.id))
        #expect(stored.models.allSatisfy { !$0.isDefault })
        #expect(stored.catalogModels.allSatisfy { !$0.isDefault })
        #expect(stored.relayRequested?.modelID == nil)
        #expect(stored.models.contains { $0.id == "model-b" })
        #expect(stored.models.contains { $0.id == "manual-z" })
        // After setup completes, select the model that was just verified.
        #expect(state.lastUsedModelRef == LastUsedModelRef(providerID: provider.id, modelID: "model-b"))

        // The verification sample is not in the catalog (typed manually / empty catalog) -> enable the sample itself as a manual model and do not mark it as default.
        let manualSample = state.providerManager.registerRelay(
            name: "Manual Relay",
            endpoint: "https://relay2.example.com/v1",
            apiKey: "sk-relay",
            relayRequested: requested,
            catalogModelIDs: ["model-a"],
            preferredModelID: "typed-model"
        )
        let storedManual = try #require(state.provider(for: manualSample.id))
        #expect(storedManual.models.map(\.id) == ["typed-model"])
        #expect(storedManual.models.allSatisfy { !$0.isDefault && $0.isManual })
        #expect(storedManual.catalogModels.contains { $0.id == "typed-model" })
        let emptyCatalog = state.providerManager.registerRelay(
            name: "Empty Relay",
            endpoint: "https://relay3.example.com/v1",
            apiKey: "sk-relay",
            relayRequested: requested,
            preferredModelID: "typed-model"
        )
        #expect(try #require(state.provider(for: emptyCatalog.id)).models.map(\.id) == ["typed-model"])

        // Setting a default has no effect on a relay.
        state.setDefaultModel(modelID: "manual-z", for: provider.id)
        let afterSetDefault = try #require(state.provider(for: provider.id))
        #expect(afterSetDefault.models.allSatisfy { !$0.isDefault })
        #expect(afterSetDefault.relayRequested?.modelID == nil)
    }

    // MARK: - RD1-MEMORY-01

    @Test("RD1-MEMORY-01 memory draft candidates: last used first; official takes the default model (even if isDefault is not the first entry); relay takes the first enabled model that is not excluded by key")
    func RD1_MEMORY_01_draftCandidates() {
        let official = TestFactories.makeProvider(
            kind: .openAI,
            models: [
                TestFactories.makeModel(id: "gpt-first", name: "gpt-first"),
                TestFactories.makeModel(id: "gpt-default", name: "gpt-default", isDefault: true),
            ]
        )
        let relay = Self.relayProvider(models: [
            Self.relayModel("relay-first"),
            Self.relayModel("relay-legacy-default", isDefault: true),
        ])
        var keylessRelay = Self.relayProvider(name: "Local", models: [Self.relayModel("local-first")])
        keylessRelay.apiKey = ""
        let keylessOfficial = TestFactories.makeProvider(
            kind: .anthropic,
            models: [TestFactories.makeModel(id: "claude", name: "claude", isDefault: true)],
            apiKey: ""
        )
        let providers = [official, relay, keylessRelay, keylessOfficial]

        let noLastUsed = MemoryView.draftCandidateModels(providers: providers, lastUsedModelRef: nil)
        #expect(noLastUsed.map(\.model.id) == ["gpt-default", "relay-first", "local-first"])

        let withLastUsed = MemoryView.draftCandidateModels(
            providers: providers,
            lastUsedModelRef: LastUsedModelRef(providerID: relay.id, modelID: "relay-legacy-default")
        )
        #expect(withLastUsed.map(\.model.id) == ["relay-legacy-default", "gpt-default", "local-first"])
    }
}
