import Testing
@testable import Oriveo

@Suite("Provider Catalog Sorting")
struct ProviderCatalogSortingTests {

    @Test("Catalog Groups Prefer Weighted Vendors")
    func catalogGroupsPreferWeightedVendors() {
        let provider = TestFactories.makeProvider(
            kind: .openRouter,
            models: [],
            catalogModels: [
                TestFactories.makeModel(
                    id: "qwen/qwen-max",
                    name: "Qwen Max",
                    groupKey: "qwen",
                    groupName: "Qwen",
                    sortRank: 80,
                    createdAt: 100
                ),
                TestFactories.makeModel(
                    id: "anthropic/claude-3.7-sonnet",
                    name: "Claude 3.7 Sonnet",
                    reasoningModeAvailable: true,
                    groupKey: "anthropic",
                    groupName: "Anthropic",
                    isRecommended: true,
                    sortRank: 180,
                    createdAt: 300
                ),
                TestFactories.makeModel(
                    id: "anthropic/claude-3.5-haiku",
                    name: "Claude 3.5 Haiku",
                    groupKey: "anthropic",
                    groupName: "Anthropic",
                    sortRank: 120,
                    createdAt: 200
                ),
            ]
        )

        let groups = buildProviderCatalogGroups(for: provider, searchText: "")

        #expect(groups.map(\.id) == ["anthropic", "qwen"])
        #expect(groups.first?.models.map(\.name) == ["Claude 3.7 Sonnet", "Claude 3.5 Haiku"])
    }

    @Test("Enabled Default Group Does Not Bias Catalog Group Order")
    func enabledDefaultGroupDoesNotBiasCatalogGroupOrder() {
        let provider = TestFactories.makeProvider(
            kind: .openRouter,
            models: [
                TestFactories.makeModel(
                    id: "openai/gpt-4.1",
                    name: "GPT-4.1",
                    isDefault: true,
                    groupKey: "openai",
                    groupName: "OpenAI",
                    sortRank: 110
                )
            ],
            catalogModels: [
                TestFactories.makeModel(
                    id: "openai/gpt-4.1-mini",
                    name: "GPT-4.1 mini",
                    groupKey: "openai",
                    groupName: "OpenAI",
                    sortRank: 112
                ),
                TestFactories.makeModel(
                    id: "anthropic/claude-3.7-sonnet",
                    name: "Claude 3.7 Sonnet",
                    groupKey: "anthropic",
                    groupName: "Anthropic",
                    sortRank: 180
                )
            ]
        )

        let groups = buildProviderCatalogGroups(for: provider, searchText: "")

        #expect(groups.map(\.id) == ["anthropic", "openai"])
    }

    @Test("Supplier Search Keeps Whole Group")
    func supplierSearchKeepsWholeGroup() {
        let provider = TestFactories.makeProvider(
            kind: .openRouter,
            models: [],
            catalogModels: [
                TestFactories.makeModel(
                    id: "anthropic/claude-3.7-sonnet",
                    name: "Claude 3.7 Sonnet",
                    groupKey: "anthropic",
                    groupName: "Anthropic",
                    sortRank: 180,
                    createdAt: 300
                ),
                TestFactories.makeModel(
                    id: "anthropic/claude-3.5-haiku",
                    name: "Claude 3.5 Haiku",
                    groupKey: "anthropic",
                    groupName: "Anthropic",
                    sortRank: 120,
                    createdAt: 200
                )
            ]
        )

        let groups = buildProviderCatalogGroups(for: provider, searchText: "anthropic")

        #expect(groups.count == 1)
        #expect(groups.first?.models.map(\.name) == ["Claude 3.7 Sonnet", "Claude 3.5 Haiku"])
    }

    @Test("Open Router Models Prefer Newest Release When Rank Is Tied")
    func openRouterModelsPreferNewestReleaseWhenRankIsTied() {
        let provider = TestFactories.makeProvider(
            kind: .openRouter,
            models: [],
            catalogModels: [
                TestFactories.makeModel(
                    id: "anthropic/claude-sonnet",
                    name: "Claude Sonnet",
                    groupKey: "anthropic",
                    groupName: "Anthropic",
                    sortRank: 120,
                    createdAt: 100
                ),
                TestFactories.makeModel(
                    id: "anthropic/claude-haiku",
                    name: "Claude Haiku",
                    groupKey: "anthropic",
                    groupName: "Anthropic",
                    isRecommended: true,
                    sortRank: 120,
                    createdAt: 200
                ),
            ]
        )

        let groups = buildProviderCatalogGroups(for: provider, searchText: "")

        #expect(groups.first?.models.map(\.name) == ["Claude Haiku", "Claude Sonnet"])
    }

    @Test("Unweighted Open Router Vendors Sort Alphabetically")
    func unweightedOpenRouterVendorsSortAlphabetically() {
        let provider = TestFactories.makeProvider(
            kind: .relay,
            models: [],
            catalogModels: [
                TestFactories.makeModel(
                    id: "nvidia/llama-3.1-nemotron-super",
                    name: "Nemotron Super",
                    groupKey: "nvidia",
                    groupName: "NVIDIA",
                    sortRank: 100
                ),
                TestFactories.makeModel(
                    id: "bytedance-seed/seed-1.6",
                    name: "Seed 1.6",
                    groupKey: "bytedance-seed",
                    groupName: "ByteDance Seed",
                    sortRank: 100
                )
            ]
        )

        let groups = buildProviderCatalogGroups(for: provider, searchText: "")

        #expect(groups.map(\.id) == ["bytedance-seed", "nvidia"])
        #expect(groups.first?.models.map(\.name) == ["Seed 1.6"])
    }

    @Test("Open Router Vendors Sort By Backend Rank")
    func openRouterVendorsSortByBackendRank() {
        let provider = TestFactories.makeProvider(
            kind: .openRouter,
            models: [],
            catalogModels: [
                TestFactories.makeModel(id: "qwen/qwen-max", name: "Qwen Max", groupKey: "qwen", groupName: "Qwen", sortRank: 300),
                TestFactories.makeModel(id: "google/gemini-2.5-pro", name: "Gemini 2.5 Pro", groupKey: "google", groupName: "Google", sortRank: 400),
                TestFactories.makeModel(id: "x-ai/grok-3", name: "Grok 3", groupKey: "x-ai", groupName: "xAI", sortRank: 100),
                TestFactories.makeModel(id: "openai/gpt-4.1", name: "GPT-4.1", groupKey: "openai", groupName: "OpenAI", sortRank: 500),
                TestFactories.makeModel(id: "anthropic/claude-sonnet", name: "Claude Sonnet", groupKey: "anthropic", groupName: "Anthropic", sortRank: 600),
                TestFactories.makeModel(id: "deepseek/deepseek-r1", name: "DeepSeek R1", groupKey: "deepseek", groupName: "DeepSeek", sortRank: 200),
            ]
        )

        let groups = buildProviderCatalogGroups(for: provider, searchText: "")

        #expect(groups.map(\.id) == ["anthropic", "openai", "google", "qwen", "deepseek", "x-ai"])
    }

    @Test("Silicon Flow Vendors Sort By Backend Rank")
    func siliconFlowVendorsSortByBackendRank() {
        let provider = TestFactories.makeProvider(
            kind: .siliconFlow,
            models: [],
            catalogModels: [
                TestFactories.makeModel(id: "tencent/hunyuan", name: "Hunyuan", groupKey: "tencent", groupName: "Tencent", sortRank: 300),
                TestFactories.makeModel(id: "stepfun-ai/step-3", name: "Step 3", groupKey: "stepfun-ai", groupName: "StepFun", sortRank: 200),
                TestFactories.makeModel(id: "moonshotai/kimi-k2", name: "Kimi K2", groupKey: "moonshotai", groupName: "Moonshot AI", sortRank: 100),
                TestFactories.makeModel(id: "Qwen/Qwen3-32B", name: "Qwen3 32B", groupKey: "qwen", groupName: "Qwen", sortRank: 500),
                TestFactories.makeModel(id: "deepseek-ai/DeepSeek-V3.1", name: "DeepSeek V3.1", groupKey: "deepseek-ai", groupName: "DeepSeek", sortRank: 600),
                TestFactories.makeModel(id: "zai-org/GLM-4.5V", name: "GLM-4.5V", groupKey: "zai-org", groupName: "Z.ai / GLM", sortRank: 400),
            ]
        )

        let groups = buildProviderCatalogGroups(for: provider, searchText: "")

        #expect(groups.map(\.id) == ["deepseek-ai", "qwen", "zai-org", "tencent", "stepfun-ai", "moonshotai"])
    }

    @Test("Model Picker Providers Prefer Best Catalogs")
    func modelPickerProvidersPreferBestCatalogs() {
        let openAI = TestFactories.makeProvider(
            kind: .openAI,
            models: [
                TestFactories.makeModel(id: "gpt-4.1", name: "GPT-4.1", sortRank: 110)
            ],
            catalogModels: [
                TestFactories.makeModel(id: "gpt-4.1", name: "GPT-4.1", sortRank: 110)
            ]
        )
        let anthropic = TestFactories.makeProvider(
            kind: .anthropic,
            models: [
                TestFactories.makeModel(id: "claude-3.7-sonnet", name: "Claude 3.7 Sonnet", sortRank: 165)
            ],
            catalogModels: [
                TestFactories.makeModel(id: "claude-3.7-sonnet", name: "Claude 3.7 Sonnet", sortRank: 165)
            ]
        )

        let sorted = sortedProvidersForModelPicker([openAI, anthropic])

        #expect(sorted.first?.kind == .anthropic)
        #expect(sorted.last?.kind == .openAI)
    }
}
