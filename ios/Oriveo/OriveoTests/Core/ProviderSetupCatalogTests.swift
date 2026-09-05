import Testing
@testable import Oriveo

@Suite("Provider Setup Catalog")
struct ProviderSetupCatalogTests {
    @Test("Nil Provider Configs Use Fallback Catalog")
    func nilProviderConfigsUseFallbackCatalog() {
        let catalog = ProviderSetupCatalog.fromProviderConfigs(nil)

        #expect(catalog.directProviders.first == .openAI)
        #expect(catalog.aggregatorProviders.contains(.openRouter))
        #expect(catalog.defaultBaseURLText(for: .openAI) == "api.openai.com/v1")
        #expect(catalog.setupEndpointOptions(for: .siliconFlow).map(\.id) == ["cn", "intl"])
        #expect(catalog.setupEndpointOptions(for: .siliconFlow).last?.baseURLText == "api.siliconflow.com/v1")
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
                sortOrder: 20
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
