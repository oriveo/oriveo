import Testing
@testable import Oriveo

@Suite("Provider Setup Catalog", .sharedProcessState)
struct ProviderSetupCatalogTests {
    @Test("Nil Provider Configs Use Fallback Catalog")
    func nilProviderConfigsUseFallbackCatalog() {
        let catalog = ProviderSetupCatalog.fromProviderConfigs(nil)

        #expect(catalog.directProviders.first == .openAI)
        #expect(catalog.aggregatorProviders.contains(.openRouter))
        #expect(catalog.defaultBaseURLText(for: .openAI) == "api.openai.com/v1")
        // The local region-table fallback also goes through the trusted table: when the shipped table is missing, only siliconflow.cn is trusted and the international site is not shown.
        #expect(catalog.setupEndpointOptions(for: .siliconFlow).map(\.id) == ["cn"])
        // Deterministic-ID reverse lookup is not filtered: existing international-site connections still resolve to intl.
        #expect(catalog.resolvedIdentityEndpointOption(for: .siliconFlow, baseURLText: "api.siliconflow.com/v1")?.id == "intl")
    }

    @Test("Remote Provider Configs Drive Setup Catalog")
    func remoteProviderConfigsDriveSetupCatalog() {
        let catalog = ProviderSetupCatalog.fromProviderConfigs([
            MetadataClient.PublicProviderConfig(
                kind: "qwen",
                displayName: "Qwen Remote",
                shortName: "Qwen",
                selectionLabel: "Alibaba Cloud",
                autoFillNote: nil,
                defaultBaseURL: "https://dashscope.example/v1",
                apiKeyPlaceholder: "sk-qwen",
                apiKeyHelpURL: nil,
                apiProtocol: nil,
                category: "direct",
                supportsAutoSync: true,
                attachmentSupport: nil,
                regionOptions: [
                    MetadataClient.ProviderRegionOption(
                        id: "hk",
                        label: "Hong Kong",
                        baseURL: "https://hk.example/v1"
                    )
                ],
                sortOrder: 20,
                // Region options must pass the trusted table: shown only if the shipped table contains its host.
                trustedHosts: TrustedHostList(hosts: ["hk.example"])
            ),
            MetadataClient.PublicProviderConfig(
                kind: "miniMax",
                displayName: "MiniMax Remote",
                shortName: "MiniMax",
                selectionLabel: nil,
                autoFillNote: nil,
                defaultBaseURL: "https://minimax.example/v1",
                apiKeyPlaceholder: "sk-api",
                apiKeyHelpURL: nil,
                apiProtocol: nil,
                category: "direct",
                supportsAutoSync: true,
                attachmentSupport: nil,
                regionOptions: [],
                sortOrder: 10
            ),
            MetadataClient.PublicProviderConfig(
                kind: "unknownNative",
                displayName: "Unknown",
                shortName: nil,
                selectionLabel: nil,
                autoFillNote: nil,
                defaultBaseURL: "https://unknown.example/v1",
                apiKeyPlaceholder: "sk",
                apiKeyHelpURL: nil,
                apiProtocol: nil,
                category: "direct",
                supportsAutoSync: true,
                attachmentSupport: nil,
                regionOptions: [],
                sortOrder: 1
            ),
        ])

        #expect(catalog.directProviders == [.miniMax, .qwen])
        #expect(catalog.aggregatorProviders.isEmpty)
        #expect(catalog.displayName(for: .qwen) == "Alibaba Cloud")
        #expect(catalog.apiKeyPlaceholder(for: .qwen) == "sk-qwen")
        #expect(catalog.defaultBaseURLText(for: .qwen) == "dashscope.example/v1")
        #expect(catalog.setupEndpointOptions(for: .qwen) == [
            ProviderEndpointOption(id: "hk", label: "Hong Kong", baseURLText: "hk.example/v1")
        ])
    }

    @Test("Explicit Empty Provider Configs Hide Official Setup Entries")
    func explicitEmptyProviderConfigsHideOfficialSetupEntries() {
        let catalog = ProviderSetupCatalog.fromProviderConfigs([])

        #expect(catalog.directProviders.isEmpty)
        #expect(catalog.aggregatorProviders.isEmpty)
    }
}
