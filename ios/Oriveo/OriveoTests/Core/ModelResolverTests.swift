import Testing
@testable import Oriveo

@Suite("ModelResolver")
struct ModelResolverTests {

    // MARK: - matchingModel

    @Test("Exact IDMatch")
    func exactIDMatch() {
        let model = TestFactories.makeModel(id: "gpt-4o")
        let provider = TestFactories.makeProvider(
            kind: .openAI,
            models: [model],
            catalogModels: [model]
        )
        let result = ModelResolver.matchingModel(for: "gpt-4o", in: provider)
        #expect(result?.id == "gpt-4o")
    }

    @Test("Manual Prefix Fuzzy Match")
    func manualPrefixFuzzyMatch() {
        let catalogModel = TestFactories.makeModel(id: "gpt-4o-mini")
        let provider = TestFactories.makeProvider(
            kind: .openAI,
            models: [catalogModel],
            catalogModels: [catalogModel]
        )
        let result = ModelResolver.matchingModel(for: "openAI-manual-gpt-4o-mini", in: provider)
        #expect(result?.id == "gpt-4o-mini")
    }

    @Test("No Match")
    func noMatch() {
        let model = TestFactories.makeModel(id: "gpt-4o")
        let provider = TestFactories.makeProvider(
            kind: .openAI,
            models: [model],
            catalogModels: [model]
        )
        let result = ModelResolver.matchingModel(for: "claude-3-sonnet", in: provider)
        #expect(result == nil)
    }

    @Test("Canonical IDMatches Snapshot Model")
    func canonicalIDMatchesSnapshotModel() {
        let snapshotModel = TestFactories.makeModel(
            id: "gpt-5.4-2026-03-05",
            name: "GPT-5.4",
            canonicalModelId: "gpt-5.4"
        )
        let provider = TestFactories.makeProvider(
            kind: .openAI,
            models: [snapshotModel],
            catalogModels: [snapshotModel]
        )

        let result = ModelResolver.matchingModel(for: "gpt-5.4", in: provider)
        #expect(result?.id == "gpt-5.4-2026-03-05")
    }

    // MARK: - modelsShareSameRemoteModel

    @Test("Same IDShare Model")
    func sameIDShareModel() {
        let a = TestFactories.makeModel(id: "gpt-4o", name: "GPT-4o")
        let b = TestFactories.makeModel(id: "gpt-4o", name: "GPT-4o v2")
        #expect(ModelResolver.modelsShareSameRemoteModel(a, b, providerKind: .openAI))
    }

    @Test("Non Open Router Name Fallback")
    func nonOpenRouterNameFallback() {
        let a = TestFactories.makeModel(id: "model-a", name: "Claude 3 Sonnet")
        let b = TestFactories.makeModel(id: "model-b", name: "claude 3 sonnet")
        #expect(ModelResolver.modelsShareSameRemoteModel(a, b, providerKind: .anthropic))
    }

    @Test("Open Router Strict ID")
    func openRouterStrictID() {
        let a = TestFactories.makeModel(id: "anthropic/claude-3-sonnet", name: "Claude 3 Sonnet")
        let b = TestFactories.makeModel(id: "anthropic/claude-3.5-sonnet", name: "Claude 3 Sonnet")
        #expect(!ModelResolver.modelsShareSameRemoteModel(a, b, providerKind: .openRouter))
    }

    @Test("Manual Prefix Share Model")
    func manualPrefixShareModel() {
        let manual = TestFactories.makeModel(id: "openAI-manual-gpt-4o", name: "gpt-4o")
        let catalog = TestFactories.makeModel(id: "gpt-4o", name: "GPT-4o")
        #expect(ModelResolver.modelsShareSameRemoteModel(manual, catalog, providerKind: .openAI))
    }

    @Test("Snapshot And Canonical Share Model")
    func snapshotAndCanonicalShareModel() {
        let snapshot = TestFactories.makeModel(
            id: "gpt-5.4-2026-03-05",
            name: "GPT-5.4",
            canonicalModelId: "gpt-5.4"
        )
        let canonical = TestFactories.makeModel(
            id: "gpt-5.4",
            name: "GPT-5.4",
            canonicalModelId: "gpt-5.4"
        )

        #expect(ModelResolver.modelsShareSameRemoteModel(snapshot, canonical, providerKind: .openAI))
    }

    // MARK: - resolvedProviderModelIdentifier

    @Test("Normal IDPassthrough")
    func normalIDPassthrough() {
        let result = ModelResolver.resolvedProviderModelIdentifier("gpt-4o", providerKind: .openAI)
        #expect(result == "gpt-4o")
    }

    @Test("Manual IDStrips Prefix")
    func manualIDStripsPrefix() {
        let result = ModelResolver.resolvedProviderModelIdentifier("openAI-manual-gpt-4o", providerKind: .openAI)
        #expect(result == "gpt-4o")
    }

    @Test("Preferred Stored Identifier Uses Canonical ID")
    func preferredStoredIdentifierUsesCanonicalID() {
        let model = TestFactories.makeModel(
            id: "gpt-5.4-2026-03-05",
            canonicalModelId: "gpt-5.4"
        )

        let result = ModelResolver.preferredStoredModelIdentifier(for: model, providerKind: .openAI)
        #expect(result == "gpt-5.4")
    }

    @Test("Wrong Provider Prefix Ignored")
    func wrongProviderPrefixIgnored() {
        let result = ModelResolver.resolvedProviderModelIdentifier("openAI-manual-gpt-4o", providerKind: .anthropic)
        #expect(result == "openAI-manual-gpt-4o")
    }

    // MARK: - isManualModel

    @Test("Is Manual Model Detection")
    func isManualModelDetection() {
        let manual = TestFactories.makeModel(id: "openRouter-manual-meta/llama-3")
        let catalog = TestFactories.makeModel(id: "meta/llama-3")
        #expect(ModelResolver.isManualModel(manual, providerKind: .openRouter))
        #expect(!ModelResolver.isManualModel(catalog, providerKind: .openRouter))
    }

    // MARK: - synchronizeDefaultSelection

    @Test("Sync Default Across Lists")
    func syncDefaultAcrossLists() {
        let m1 = TestFactories.makeModel(id: "m1", isDefault: true)
        let m2 = TestFactories.makeModel(id: "m2", isDefault: false)
        let c1 = TestFactories.makeModel(id: "m1", isDefault: false)
        let c2 = TestFactories.makeModel(id: "m2", isDefault: false)

        let provider = TestFactories.makeProvider(
            kind: .openAI,
            models: [m1, m2],
            catalogModels: [c1, c2]
        )

        let result = ModelResolver.synchronizeDefaultSelection(in: provider, preferredModelID: "m2")
        #expect(result.models.first(where: \.isDefault)?.id == "m2")
        #expect(result.catalogModels.first(where: \.isDefault)?.id == "m2")
    }

    @Test("Sync Default Keeps Existing")
    func syncDefaultKeepsExisting() {
        let m1 = TestFactories.makeModel(id: "m1", isDefault: true)
        let m2 = TestFactories.makeModel(id: "m2", isDefault: false)

        let provider = TestFactories.makeProvider(
            kind: .openAI,
            models: [m1, m2]
        )

        let result = ModelResolver.synchronizeDefaultSelection(in: provider, preferredModelID: nil)
        #expect(result.models.first(where: \.isDefault)?.id == "m1")
    }

    // MARK: - mergeManualModels

    @Test("Merge Manual Models No Duplication")
    func mergeManualModelsNoDuplication() {
        let manual = TestFactories.makeModel(id: "openAI-manual-gpt-4o", name: "gpt-4o")
        let synced = TestFactories.makeModel(id: "gpt-4o", name: "GPT-4o")

        let result = ModelResolver.mergeManualModels(
            from: [manual],
            into: [synced],
            providerKind: .openAI
        )
        #expect(result.count == 1)
    }

    @Test("Merge Manual Models Prepended")
    func mergeManualModelsPrepended() {
        let manual = TestFactories.makeModel(id: "openAI-manual-custom-model", name: "custom-model")
        let synced = TestFactories.makeModel(id: "gpt-4o", name: "GPT-4o")

        let result = ModelResolver.mergeManualModels(
            from: [manual],
            into: [synced],
            providerKind: .openAI
        )
        #expect(result.count == 2)
        #expect(result.first?.id == "openAI-manual-custom-model")
    }

    // MARK: - makeEnabledModels

    @Test("Make Enabled Models Retains Existing")
    func makeEnabledModelsRetainsExisting() {
        let existing = TestFactories.makeModel(id: "gpt-4o", isDefault: true)
        let catalog = [
            TestFactories.makeModel(id: "gpt-4o"),
            TestFactories.makeModel(id: "gpt-4o-mini"),
        ]

        let result = ModelResolver.makeEnabledModels(
            from: [existing],
            catalogModels: catalog,
            providerKind: .openAI
        )
        #expect(result.count == 1)
        #expect(result.first?.id == "gpt-4o")
        #expect(result.first?.isDefault == true)
    }

    @Test("Make Enabled Models Auto Select")
    func makeEnabledModelsAutoSelect() {
        let catalog = [
            TestFactories.makeModel(id: "gpt-4o", isAvailable: true, isDefault: true),
            TestFactories.makeModel(id: "gpt-4o-mini", isAvailable: true),
        ]

        let result = ModelResolver.makeEnabledModels(
            from: [],
            catalogModels: catalog,
            providerKind: .openAI
        )
        #expect(!result.isEmpty)
        #expect(result.contains(where: { $0.isDefault }))
    }

    @Test("All Enabled Models Preserves Preferred Default")
    func allEnabledModelsPreservesPreferredDefault() {
        let catalog = [
            TestFactories.makeModel(id: "gpt-4o"),
            TestFactories.makeModel(id: "gpt-4.1", isDefault: true),
            TestFactories.makeModel(id: "gpt-4.1-mini"),
        ]

        let result = ModelResolver.allEnabledModels(
            from: catalog,
            preferredModelID: "gpt-4o",
            providerKind: .openAI
        )

        #expect(result.map(\.id) == ["gpt-4o", "gpt-4.1", "gpt-4.1-mini"])
        #expect(result.first(where: \.isDefault)?.id == "gpt-4o")
    }



    @Test("Display Name Open Router")
    func displayNameOpenRouter() {
        let name = ModelResolver.displayName(forManualModelID: "meta-llama/llama-3-8b", providerKind: .openRouter)
        #expect(name == "llama-3-8b")
    }

    @Test("Display Name Silicon Flow")
    func displayNameSiliconFlow() {
        let name = ModelResolver.displayName(forManualModelID: "deepseek-ai/DeepSeek-V3.1", providerKind: .siliconFlow)
        #expect(name == "DeepSeek-V3.1")
    }

    @Test("Display Name Non Open Router")
    func displayNameNonOpenRouter() {
        let name = ModelResolver.displayName(forManualModelID: "gpt-4o", providerKind: .openAI)
        #expect(name == "gpt-4o")
    }

    @Test("Group Key Open Router")
    func groupKeyOpenRouter() {
        let key = ModelResolver.groupKey(forManualModelID: "meta-llama/llama-3-8b", providerKind: .openRouter)
        #expect(key == "meta-llama")
    }

    @Test("Group Key Silicon Flow")
    func groupKeySiliconFlow() {
        let key = ModelResolver.groupKey(forManualModelID: "deepseek-ai/DeepSeek-V3.1", providerKind: .siliconFlow)
        #expect(key == "deepseek-ai")
    }

    @Test("Group Key No Slash")
    func groupKeyNoSlash() {
        let key = ModelResolver.groupKey(forManualModelID: "llama-3-8b", providerKind: .openRouter)
        #expect(key == nil)
    }
}
