import Foundation
import GRDB
import Testing
@testable import Oriveo

/// Slice corpus of the production `/api/metadata` `modelFacts`. The decision side (`ModelFactsSubscriptionTests`) and
/// the outbound side (`GrokSubscriptionResponsesTests` / `OpenAIServiceCodexUserAgentTests`) read the same copy;
/// each building its own would be writing the same thing twice, which is not verification.
enum ModelFactsFixture {
    // MARK: - Corpus

    struct ProductionSlice: Decodable {
        let modelFactsRevision: String
        let productionEntryCount: Int
        /// Kept verbatim (including the `artifactHash` that must never be persisted):
        /// the slice is a production response, so "the client does not decode it" has to be proven by the client, not faked by deleting it from the corpus first.
        let modelFacts: [String: JSONValueBox]
    }

    /// Only carries the corpus `modelFacts` into the request body as-is, without interpreting the content.
    struct JSONValueBox: Decodable {
        let raw: Any
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let dict = try? container.decode([String: JSONValueBox].self) {
                raw = dict.mapValues(\.raw)
            } else if let array = try? container.decode([JSONValueBox].self) {
                raw = array.map(\.raw)
            } else if let bool = try? container.decode(Bool.self) {
                raw = bool
            } else if let string = try? container.decode(String.self) {
                raw = string
            } else if let number = try? container.decode(Double.self) {
                raw = number
            } else {
                raw = NSNull()
            }
        }
    }

    static func productionSlice() throws -> ProductionSlice {
        let url = try sharedFixtureURL("model-facts/production-slice.v1.json")
        return try JSONDecoder().decode(ProductionSlice.self, from: Data(contentsOf: url))
    }

    /// Production slice -> minimal `/api/metadata` payload. Leaving `providers` empty is deliberate:
    /// subscription models are not in the catalog to begin with, so the dictionary must be able to answer on its own with **no catalog entry at all**.
    static func metadataPayload(includeFacts: Bool = true) throws -> String {
        let slice = try productionSlice()
        var payload: [String: Any] = [
            "version": 83,
            // Production only ships the lean view since lean; the persistent cache only accepts lean as well (an old full cache is always discarded)
            "view": "lean",
            "contractVersion": 1,
            "capabilityContractVersion": 2,
            "providers": [String: Any](),
        ]
        if includeFacts {
            payload["modelFacts"] = slice.modelFacts.mapValues(\.raw)
            payload["modelFactsRevision"] = slice.modelFactsRevision
        }
        let data = try JSONSerialization.data(withJSONObject: payload)
        return String(decoding: data, as: UTF8.self)
    }

    static func loadFacts(includeFacts: Bool = true) async throws {
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(json: metadataPayload(includeFacts: includeFacts))
    }
}

/// The iOS consumer of the out-of-catalog model facts dictionary (`data.modelFacts`).
///
/// These cases pin the root-cause chain of a real-device symptom:
/// subscription models **never enter the catalog** -> the reasoning levels can only come from the **non-persisted** field of the subscription proxy `/models`
/// (`AIModel.upstreamReasoningLevels` is deliberately left out of `CodingKeys`) -> it is empty after an app cold start ->
/// "subscription grok-4.6 does not support thinking mode". The fix is not to persist that field (that would carry stale levels into the future),
/// but to let the **persisted** models.dev facts stand in during the window when first-party data is absent.
///
/// The corpus is an unmodified slice of the production `/api/metadata` (`shared/test-fixtures/model-facts/production-slice.v1.json`),
/// not hand-made fake data: the `["low","medium","high","xhigh"]` of `grok-4.6` matches the subscription proxy `/models` declaration verbatim,
/// and `grok-build-0.1` is a real boundary: `reasoning: true` without `reasoningEfforts`.
@Suite("modelFacts · subscription path facts share one source", .serialized, .sharedProcessState)
struct ModelFactsSubscriptionTests {

    // MARK: - Shapes under test

    /// The shape the subscription catalog writes out. `declaredLevels: []` is the **cold-start state**:
    /// the catalog has not been refetched yet, so the first-party level table is empty.
    private static func subscriptionProvider(kind: ProviderKind) -> Provider {
        var provider = TestFactories.makeProvider(kind: kind, models: [])
        provider.authMode = .subscription
        return provider
    }

    private static func subscriptionModel(
        id: String, declaredLevels: [String] = [], defaultLevel: String? = nil
    ) -> AIModel {
        var model = TestFactories.makeModel(id: id, capabilities: [.text, .reasoning])
        model.reasoningModeAvailable = true
        model.upstreamReasoningLevels = declaredLevels
        model.upstreamDefaultReasoningLevel = defaultLevel
        model.upstreamAPIBackend = "responses"
        return model
    }

    // MARK: - Normalization: the same rule as the Server, nothing invented here

    @Test("Key normalization replays the Server's normalizeModelsDevJoinID step by step (the order must not change)")
    func normalizationMatchesServerJoinRule() {
        let normalize = MetadataClient.normalizeModelFactsID
        #expect(normalize("Grok-4.6") == "grok-4.6")
        #expect(normalize("  grok-4.6  ") == "grok-4.6")
        // Two date suffix shapes
        #expect(normalize("gpt-5.6-sol-20260401") == "gpt-5.6-sol")
        #expect(normalize("claude-sonnet-5-2026-04-01") == "claude-sonnet-5")
        // A 4-digit suffix is not a date and must not be stripped by mistake (production really has a standalone fireworksAI/deepseek-v4-flash-0731 entry)
        #expect(normalize("deepseek-v4-flash-0731") == "deepseek-v4-flash-0731")
        // Fireworks path prefix + 3p1 -> 3.1
        #expect(normalize("accounts/fireworks/models/llama-v3p1-8b") == "llama-v3.1-8b")
        #expect(normalize("accounts/fireworks/routers/deepseek-v4-pro") == "deepseek-v4-pro")
        // SiliconFlow's Pro/ billing-tier prefix (lowercase first, strip the prefix after, so an uppercase Pro/ matches too)
        #expect(normalize("Pro/zai-org/GLM-5.1") == "zai-org/glm-5.1")
        #expect(normalize("") == "")
    }

    @Test("Dictionary keys use the Server-side providerKind (together -> togetherAI); the vendor mapping is not redone on the client")
    func keyUsesServerProviderKind() {
        #expect(MetadataClient.modelFactsKey(providerKind: .grok, modelID: "grok-4.6") == "grok/grok-4.6")
        #expect(MetadataClient.modelFactsKey(providerKind: .openAI, modelID: "GPT-5.6-Sol") == "openAI/gpt-5.6-sol")
        #expect(MetadataClient.modelFactsKey(providerKind: .together, modelID: "m") == "togetherAI/m")
        #expect(MetadataClient.modelFactsKey(providerKind: .fireworks, modelID: "m") == "fireworksAI/m")
        // A kind outside the 15 models.dev providers has no dictionary entry, so the key must not even be built.
        #expect(MetadataClient.modelFactsKey(providerKind: .relay, modelID: "m") == nil)
        #expect(MetadataClient.modelFactsKey(providerKind: .grok, modelID: "   ") == nil)
    }

    // MARK: - Decoding and persistence (the core value of this change: nothing is lost on cold start)

    @Test("The production slice yields levels and is persisted with the metadata cache: a new client still finds them after initialize()")
    func productionSliceSurvivesPersistenceRoundTrip() async throws {
        let slice = try ModelFactsFixture.productionSlice()
        #expect(slice.productionEntryCount == 394, "The corpus records the entry count of the whole production dictionary; recapture it when this changes")

        let writer = MetadataClient()
        await writer.resetForTesting()
        let persisted = try await writer.persistSanitizedCacheForTesting(
            json: ModelFactsFixture.metadataPayload(), etag: "etag-model-facts"
        )
        #expect(persisted.userDefaultsPayload == nil, "The new format writes the whole payload to GRDB only")
        // JSONEncoder escapes `/` in keys as `\/`; restore it before comparing the keys themselves.
        let value = try #require(persisted.grdbPayload)
            .replacingOccurrences(of: "\\/", with: "/")
        // Persisting is the whole point of this change: a dictionary that is not persisted is empty on cold start, just like upstreamReasoningLevels.
        #expect(value.contains("grok/grok-4.6"))
        #expect(value.contains("reasoningEfforts"))
        #expect(value.contains("modelFactsRevision"))
        // artifactHash must never enter GRDB. The corpus has it, so the client must not decode it.
        #expect(!value.contains("artifactHash"))

        // Cold start: a different client hydrates from the persisted cache only, with no network.
        let reader = MetadataClient()
        await reader.initialize()
        let fact = try #require(MetadataClient.shared.syncModelFacts(providerKind: .grok, modelID: "grok-4.6"))
        #expect(fact.reasoningEfforts == ["low", "medium", "high", "xhigh"])
        #expect(fact.toolCall == true)
        #expect(fact.reasoning == true)
        #expect(MetadataClient.shared.syncModelFactsRevision() == slice.modelFactsRevision)
        await reader.resetForTesting()
    }

    @Test("An old Server snapshot lacks these two keys: the lookup returns nil, neither crashing nor being treated as \"unsupported\"")
    func absentDictionaryIsUnknownNotUnsupported() async throws {
        try await ModelFactsFixture.loadFacts(includeFacts: false)
        #expect(MetadataClient.shared.syncModelFacts(providerKind: .grok, modelID: "grok-4.6") == nil)
        #expect(MetadataClient.shared.syncModelFactsRevision() == nil)
        // No first-party data either -> an empty level table, keeping today's honest unavailability (not a crash, and not an invented default).
        #expect(CapabilityControlResolution.subscriptionDeclaredReasoningLevels(
            providerKind: .grok, model: Self.subscriptionModel(id: "grok-4.6")
        ).isEmpty)
        await MetadataClient.shared.resetForTesting()
    }

    @Test("A model missing from the dictionary -> nil (unknown), never used as false")
    func unknownModelIsNil() async throws {
        try await ModelFactsFixture.loadFacts()
        #expect(MetadataClient.shared.syncModelFacts(providerKind: .grok, modelID: "grok-never-shipped") == nil)
        #expect(MetadataClient.shared.syncModelFacts(providerKind: .mistral, modelID: "grok-4.6") == nil)
        await MetadataClient.shared.resetForTesting()
    }

    // MARK: - Cold-start regression (the direct test of the real-device symptom)

    @Test("Cold-start regression: empty first-party level table + dictionary levels -> reasoning is auto_available and intents are non-empty")
    func coldStartReasoningStaysAvailableFromModelFacts() async throws {
        try await ModelFactsFixture.loadFacts()
        // App restart state: `upstreamReasoningLevels` is a non-persisted field and is always empty on cold start.
        let provider = Self.subscriptionProvider(kind: .grok)
        let model = Self.subscriptionModel(id: "grok-4.6", declaredLevels: [])
        #expect(model.upstreamReasoningLevels.isEmpty, "This is exactly the shape of \"the app just restarted\"")

        let verdict = CapabilityControlResolution.subscriptionVerdict(
            provider: provider, model: model, capability: "reasoning"
        )
        #expect(verdict.state == .autoAvailable)
        #expect(verdict.intents == ["low", "balanced", "deep", "max"])
        #expect(verdict.reasonCode == "subscription_upstream_declared")

        // The Codex path is isomorphic: the dictionary levels of gpt-5.6-sol include xhigh, so all four levels are present.
        let codexVerdict = CapabilityControlResolution.subscriptionVerdict(
            provider: Self.subscriptionProvider(kind: .openAI),
            model: Self.subscriptionModel(id: "gpt-5.6-sol", declaredLevels: []),
            capability: "reasoning"
        )
        #expect(codexVerdict.state == .autoAvailable)
        #expect(codexVerdict.intents == ["low", "balanced", "deep", "max"])
        await MetadataClient.shared.resetForTesting()
    }

    @Test("When the verdict says xhigh, the outbound mapping must be able to land on xhigh: the UI and the outbound path use the same function")
    func coldStartLevelsReachTheOutboundMapper() async throws {
        try await ModelFactsFixture.loadFacts()
        for (kind, id) in [(ProviderKind.grok, "grok-4.6"), (ProviderKind.openAI, "gpt-5.6-sol")] {
            let levels = CapabilityControlResolution.subscriptionDeclaredReasoningLevels(
                providerKind: kind, model: Self.subscriptionModel(id: id)
            )
            #expect(levels.contains("xhigh"), "the dictionary levels of \(id) should include xhigh")
            #expect(OpenAIService.codexReasoningEffort(for: .max, declaredLevels: levels) == "xhigh")
            #expect(OpenAIService.codexReasoningEffort(for: .deep, declaredLevels: levels) == "high")
            #expect(OpenAIService.codexReasoningEffort(for: .fast, declaredLevels: levels) == "low")
        }
        await MetadataClient.shared.resetForTesting()
    }

    @Test("First-party always wins over the dictionary: when the proxy /models declares only low, the dictionary's four levels must not lift it")
    func firstPartyDeclarationWinsOverModelFacts() async throws {
        try await ModelFactsFixture.loadFacts()
        let model = Self.subscriptionModel(id: "grok-4.6", declaredLevels: ["low"])
        let levels = CapabilityControlResolution.subscriptionDeclaredReasoningLevels(
            providerKind: .grok, model: model
        )
        #expect(levels == ["low"])
        // fast -> low, and balanced degrades to low; deep/max cannot land anywhere, so they must not appear in the UI.
        let verdict = CapabilityControlResolution.subscriptionVerdict(
            provider: Self.subscriptionProvider(kind: .grok), model: model, capability: "reasoning"
        )
        #expect(verdict.intents == ["low", "balanced"])
        await MetadataClient.shared.resetForTesting()
    }

    @Test("A wholly omitted reasoningEfforts key (reasoning without levels) is still unavailable: a missing key must never be read as anything other than an empty level table")
    func reasoningWithoutEffortsStaysUnavailable() async throws {
        try await ModelFactsFixture.loadFacts()
        let fact = try #require(MetadataClient.shared.syncModelFacts(providerKind: .grok, modelID: "grok-build-0.1"))
        #expect(fact.reasoning == true)
        #expect(fact.reasoningEfforts == nil, "The contract says a missing value omits the whole key and never sends an empty array")

        let verdict = CapabilityControlResolution.subscriptionVerdict(
            provider: Self.subscriptionProvider(kind: .grok),
            model: Self.subscriptionModel(id: "grok-build-0.1"),
            capability: "reasoning"
        )
        #expect(verdict.state == .unavailable)
        #expect(verdict.reasonCode == "upstream_parameter_not_declared")
        await MetadataClient.shared.resetForTesting()
    }

    @Test("The default level only comes from first-party: the dictionary fallback never invents a default, and a first-party default outside the effective set is not sent either")
    func defaultLevelIsNeverFabricated() async throws {
        try await ModelFactsFixture.loadFacts()
        // Cold start: the first-party default level is lost too -> nil (no effort is sent; the upstream's own default applies).
        #expect(CapabilityControlResolution.subscriptionDefaultReasoningLevel(
            providerKind: .grok, model: Self.subscriptionModel(id: "grok-4.6")
        ) == nil)
        // First-party declares a default level that is inside the dictionary / first-party effective set -> use it.
        #expect(CapabilityControlResolution.subscriptionDefaultReasoningLevel(
            providerKind: .grok,
            model: Self.subscriptionModel(id: "grok-4.6", declaredLevels: [], defaultLevel: "high")
        ) == "high")
        // Upstream renamed the levels, so the default is outside the effective set -> not sent (exactly the shape the grok reasoning_effort incident guards against).
        #expect(CapabilityControlResolution.subscriptionDefaultReasoningLevel(
            providerKind: .grok,
            model: Self.subscriptionModel(id: "grok-4.6", declaredLevels: ["low"], defaultLevel: "high")
        ) == nil)
        await MetadataClient.shared.resetForTesting()
    }

    // MARK: - tool_call tri-state: the dictionary is models.dev-level secondary evidence, ranked before the memory layer

    @Test("Subscription path toolCall goes from always unknown to consuming dictionary facts, with source marked modelFacts")
    func subscriptionToolCallConsumesModelFacts() async throws {
        try await ModelFactsFixture.loadFacts()
        let provider = Self.subscriptionProvider(kind: .grok)
        let model = Self.subscriptionModel(id: "grok-4.6")

        let catalog = ToolCallCapabilityPolicy.catalogVerdict(provider: provider, model: model)
        #expect(catalog.verdict == true)
        #expect(catalog.source == .modelFacts)

        // Full verdict: the subscription path supplies the transport itself (Responses), and the local adapter exists -> tools can be sent.
        let decision = ToolCallCapabilityPolicy.decide(provider: provider, model: model)
        #expect(decision.verdict == true)
        #expect(decision.source == .modelFacts)
        #expect(decision.transport == TransportKind.openaiResponses.rawValue)
        #expect(decision.allowed)
        #expect(decision.decided)

        // A fact saying false means false (gemini-2.5-flash-image is a real toolCall:false entry in production).
        let falseFact = ToolCallCapabilityPolicy.catalogVerdict(
            provider: Self.subscriptionProvider(kind: .gemini),
            model: Self.subscriptionModel(id: "gemini-2.5-flash-image")
        )
        #expect(falseFact.verdict == false)
        #expect(falseFact.source == .modelFacts)
        await MetadataClient.shared.resetForTesting()
    }

    @Test("Subscription has no first-party tool field: the dictionary applies; a dictionary miss falls back to unknown, and the memory layer's scope is untouched")
    func firstPartyAndMemorySemanticsUnchanged() async throws {
        try await ModelFactsFixture.loadFacts()
        let provider = Self.subscriptionProvider(kind: .grok)

        // The subscription /models carries no tool field, so the first-party layer does not exist; a stale toolCall on the model does not count, and the dictionary's true applies.
        var stale = Self.subscriptionModel(id: "grok-4.6")
        stale.toolCall = false
        let fromFacts = ToolCallCapabilityPolicy.catalogVerdict(provider: provider, model: stale)
        #expect(fromFacts.verdict == true)
        #expect(fromFacts.source == .modelFacts)

        // A subscription model the dictionary does not cover stays unknown and is left to the memory layer.
        let uncovered = Self.subscriptionModel(id: "grok-never-shipped")
        let verdict = ToolCallCapabilityPolicy.catalogVerdict(provider: provider, model: uncovered)
        #expect(verdict.verdict == nil)
        #expect(verdict.source == .unknown)
        // The memory layer's scope is unchanged: the subscription path can still write memory.
        #expect(ToolCallCapabilityPolicy.memoryEligible(provider: provider, model: uncovered))
        #expect(ToolCallCapabilityPolicy.memoryEligible(
            provider: provider, model: Self.subscriptionModel(id: "grok-4.6")
        ))
        await MetadataClient.shared.resetForTesting()
    }

    @Test("Official manual catalog miss: modelFacts overrides the stale local value and drives the Tool badge")
    func manualOfficialModelFactsDrivePolicyAndBadge() async throws {
        try await ModelFactsFixture.loadFacts()

        var claude = TestFactories.makeModel(
            id: "claude-sonnet-5", capabilities: [.text], isManual: true
        )
        claude.toolCall = false // A persisted stale value must not override the current facts=true.
        let anthropic = TestFactories.makeProvider(kind: .anthropic, models: [claude])
        #expect(MetadataClient.shared.syncResolveCatalogModel(modelID: claude.id, providerKind: .anthropic) == nil)

        let verdict = ToolCallCapabilityPolicy.catalogVerdict(provider: anthropic, model: claude)
        #expect(verdict.verdict == true)
        #expect(verdict.source == .modelFacts)
        let decision = ToolCallCapabilityPolicy.decide(provider: anthropic, model: claude)
        #expect(decision.transport == TransportKind.anthropicMessages.rawValue)
        #expect(decision.allowed)
        #expect(ModelCapabilityEvidencePresentation(provider: anthropic, model: claude).permitsToolCallDisplay())
        #expect(claude.visibleMetadataCapabilities(provider: anthropic).contains(.toolCall))

        var geminiImage = TestFactories.makeModel(
            id: "gemini-2.5-flash-image", capabilities: [.text], isManual: true
        )
        geminiImage.toolCall = true // facts=false must override the stale local true just as well.
        let gemini = TestFactories.makeProvider(kind: .gemini, models: [geminiImage])
        let denied = ToolCallCapabilityPolicy.catalogVerdict(provider: gemini, model: geminiImage)
        #expect(denied.verdict == false)
        #expect(denied.source == .modelFacts)
        #expect(ToolCallCapabilityPolicy.finalTransportKindName(provider: gemini, model: geminiImage) == TransportKind.geminiGenerate.rawValue)
        #expect(!ModelCapabilityEvidencePresentation(provider: gemini, model: geminiImage).permitsToolCallDisplay())

        await MetadataClient.shared.resetForTesting()
    }

    @Test("Catalog-miss transport is isomorphic with the real dispatcher")
    func manualTransportFallbackMatchesDispatcher() async throws {
        try await ModelFactsFixture.loadFacts()
        let model = TestFactories.makeModel(id: "manual-transport-only", isManual: true)

        #expect(ToolCallCapabilityPolicy.finalTransportKindName(
            provider: TestFactories.makeProvider(kind: .anthropic), model: model
        ) == TransportKind.anthropicMessages.rawValue)
        #expect(ToolCallCapabilityPolicy.finalTransportKindName(
            provider: TestFactories.makeProvider(kind: .gemini), model: model
        ) == TransportKind.geminiGenerate.rawValue)

        let openAICompatible: [ProviderKind] = [
            .openAI, .openRouter, .deepseek, .grok, .groq, .together, .fireworks,
            .miniMax, .zhipu, .qwen, .moonshot, .mistral, .siliconFlow,
        ]
        for kind in openAICompatible {
            #expect(
                ToolCallCapabilityPolicy.finalTransportKindName(
                    provider: TestFactories.makeProvider(kind: kind), model: model
                ) == TransportKind.openaiChat.rawValue,
                Comment(rawValue: kind.rawValue)
            )
        }

        await MetadataClient.shared.resetForTesting()
    }

    @Test("Relay never borrows the official facts; the Tool badge only accepts affirmative fact/local/memory sources")
    func relayIsolationAndAffirmativeBadgeSources() async throws {
        try await ModelFactsFixture.loadFacts()
        let store = try makeModelFactsMemoryStore()

        var relayModel = TestFactories.makeModel(
            id: "claude-sonnet-5", capabilities: [.text], isManual: true
        )
        var relay = TestFactories.makeProvider(kind: .relay, models: [relayModel])
        relay.relayRequested = RelayRequestedConfig(transport: .openaiChatCompletions)
        let isolated = ToolCallCapabilityPolicy.catalogVerdict(provider: relay, model: relayModel)
        #expect(isolated.verdict == nil)
        #expect(isolated.source == .unknown)
        #expect(!ModelCapabilityEvidencePresentation(
            provider: relay, model: relayModel, toolCallMemory: store
        ).permitsToolCallDisplay())

        relayModel.toolCall = true
        #expect(ToolCallCapabilityPolicy.catalogVerdict(provider: relay, model: relayModel).source == .relayDeclaration)
        #expect(ModelCapabilityEvidencePresentation(
            provider: relay, model: relayModel, toolCallMemory: store
        ).permitsToolCallDisplay())

        var local = TestFactories.makeModel(
            id: "manual-local-only", capabilities: [.text], isManual: true
        )
        local.toolCall = true
        let official = TestFactories.makeProvider(kind: .openRouter, models: [local])
        #expect(ToolCallCapabilityPolicy.catalogVerdict(provider: official, model: local).source == .localDeclaration)
        #expect(ModelCapabilityEvidencePresentation(
            provider: official, model: local, toolCallMemory: store
        ).permitsToolCallDisplay())

        let remembered = TestFactories.makeModel(
            id: "manual-memory-only", capabilities: [.text], isManual: true
        )
        #expect(store.record(
            connectionID: official.id, modelID: remembered.id, toolCall: true,
            reason: .structuredToolCalls
        ))
        #expect(ModelCapabilityEvidencePresentation(
            provider: official, model: remembered, toolCallMemory: store
        ).permitsToolCallDisplay())
        #expect(store.record(
            connectionID: official.id, modelID: remembered.id, toolCall: false,
            reason: .toolsRejected4xx
        ))
        #expect(!ModelCapabilityEvidencePresentation(
            provider: official, model: remembered, toolCallMemory: store
        ).permitsToolCallDisplay())

        await MetadataClient.shared.resetForTesting()
    }
}

/// A standalone GRDB database (running the full migrator) that does not touch DatabaseManager's current user pool.
private func makeModelFactsMemoryStore() throws -> ToolCallMemoryStore {
    let uid = "model-facts-memory-\(UUID().uuidString)"
    try FileManager.default.createDirectory(at: AppSessionStore.userDir(for: uid), withIntermediateDirectories: true)
    let pool = try DatabasePool(
        path: AppSessionStore.databasePath(for: uid).path,
        configuration: DatabaseSchema.makeConfiguration()
    )
    let files = AttachmentFileStore(rootDirectory: AppSessionStore.filesDir(for: uid))
    try DatabaseSchema.makeMigrator(attachmentFileStore: files).migrate(pool)
    return ToolCallMemoryStore(poolProvider: { pool })
}
