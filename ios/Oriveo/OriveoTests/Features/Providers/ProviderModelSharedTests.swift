import Foundation
import Testing
@testable import Oriveo

nonisolated private final class ProjectionExecutionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Bool] = []

    func record(isMainThread: Bool) {
        lock.lock()
        values.append(isMainThread)
        lock.unlock()
    }

    func snapshot() -> [Bool] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

@Suite("ProviderModelShared - Metadata Authoritative Grouping", .serialized)
struct ProviderModelSharedTests {

    @Test("Catalog Projection Runs Off Main And Memoizes Snapshot")
    func catalogProjectionRunsOffMainAndMemoizesSnapshot() async {
        let recorder = ProjectionExecutionRecorder()
        let inputRecorder = ProjectionExecutionRecorder()
        let memo = ProviderCatalogProjectionMemo(
            projector: { input, searchText in
                recorder.record(isMainThread: Thread.isMainThread)
                return projectProviderCatalogGroups(input: input, searchText: searchText)
            },
            inputBuilder: { provider in
                inputRecorder.record(isMainThread: Thread.isMainThread)
                return makeProviderCatalogProjectionInput(for: provider)
            }
        )
        let provider = makeProvider(
            kind: .relay,
            models: [],
            catalogModels: [
                TestFactories.makeModel(
                    id: "anthropic/claude-sonnet",
                    name: "Claude Sonnet",
                    groupKey: "anthropic",
                    groupName: "Anthropic",
                    sortRank: 200
                ),
                TestFactories.makeModel(
                    id: "openai/gpt-4.1",
                    name: "GPT-4.1",
                    groupKey: "openai",
                    groupName: "OpenAI",
                    sortRank: 150
                ),
            ]
        )
        let snapshot = ProviderCatalogSnapshotIdentity(
            providerID: provider.id,
            providersVersion: 7,
            metadataContentRevision: 11,
            metadataETag: "etag-a"
        )

        let first = await memo.groups(for: provider, searchText: "", snapshot: snapshot)
        let second = await memo.groups(for: provider, searchText: "", snapshot: snapshot)

        #expect(first == second)
        #expect(first.map { $0.id } == ["anthropic", "openai"])
        #expect(await memo.computationCountForTesting() == 1)
        #expect(recorder.snapshot() == [false])
        #expect(inputRecorder.snapshot() == [false])

        let changedSnapshot = ProviderCatalogSnapshotIdentity(
            providerID: provider.id,
            providersVersion: 7,
            metadataContentRevision: 12,
            metadataETag: "etag-b"
        )
        _ = await memo.groups(for: provider, searchText: "", snapshot: changedSnapshot)
        #expect(await memo.computationCountForTesting() == 2)
    }

    @Test("Recency Bucket Invalidates Projection Memo")
    func recencyBucketInvalidatesProjectionMemo() async {
        let memo = ProviderCatalogProjectionMemo()
        let provider = makeProvider(
            kind: .relay,
            models: [],
            catalogModels: [TestFactories.makeModel(id: "openai/gpt-4.1", name: "GPT-4.1")]
        )
        let firstSnapshot = ProviderCatalogSnapshotIdentity(
            providerID: provider.id,
            providersVersion: 1,
            metadataContentRevision: 1,
            metadataETag: "etag-stable",
            recencyBucket: 100
        )
        let nextDaySnapshot = ProviderCatalogSnapshotIdentity(
            providerID: provider.id,
            providersVersion: 1,
            metadataContentRevision: 1,
            metadataETag: "etag-stable",
            recencyBucket: 101
        )

        _ = await memo.groups(for: provider, searchText: "", snapshot: firstSnapshot)
        _ = await memo.groups(for: provider, searchText: "", snapshot: nextDaySnapshot)

        #expect(await memo.computationCountForTesting() == 2)
    }

    @Test("Search Projection Preserves Expansion State")
    func searchProjectionPreservesExpansionState() {
        let providerID = UUID()
        let baseSnapshot = ProviderCatalogSnapshotIdentity(
            providerID: providerID,
            providersVersion: 1,
            metadataContentRevision: 1,
            metadataETag: "etag-a",
            recencyBucket: 100
        )
        let baseProjection = ProviderCatalogProjectionRequestIdentity(snapshot: baseSnapshot, searchText: "")
        let baseGroups = [
            ProviderCatalogGroup(id: "anthropic", title: "Anthropic", models: []),
            ProviderCatalogGroup(id: "openai", title: "OpenAI", models: []),
        ]
        let initial = ProviderCatalogExpansionPolicy.reconcile(
            expandedGroupIDs: ["openai"],
            previousSignature: nil,
            projection: baseProjection,
            groups: baseGroups
        )
        let searchProjection = ProviderCatalogProjectionRequestIdentity(snapshot: baseSnapshot, searchText: "claude")

        let searched = ProviderCatalogExpansionPolicy.reconcile(
            expandedGroupIDs: initial.expandedGroupIDs,
            previousSignature: initial.signature,
            projection: searchProjection,
            groups: [baseGroups[0]]
        )

        #expect(searched.expandedGroupIDs == ["openai"])
        #expect(searched.signature == initial.signature)
        #expect(!searched.shouldPersist)
    }

    @Test("Regrouping Reconciles Expansion To New Groups")
    func regroupingReconcilesExpansionToNewGroups() {
        let providerID = UUID()
        let oldSnapshot = ProviderCatalogSnapshotIdentity(
            providerID: providerID,
            providersVersion: 1,
            metadataContentRevision: 1,
            metadataETag: "etag-old",
            recencyBucket: 100
        )
        let oldProjection = ProviderCatalogProjectionRequestIdentity(snapshot: oldSnapshot, searchText: "")
        let oldSignature = ProviderCatalogExpansionSignature(
            projection: oldProjection,
            groupIDs: ["legacy"]
        )
        let newSnapshot = ProviderCatalogSnapshotIdentity(
            providerID: providerID,
            providersVersion: 1,
            metadataContentRevision: 2,
            metadataETag: "etag-new",
            recencyBucket: 100
        )
        let newProjection = ProviderCatalogProjectionRequestIdentity(snapshot: newSnapshot, searchText: "")

        let update = ProviderCatalogExpansionPolicy.reconcile(
            expandedGroupIDs: ["legacy"],
            previousSignature: oldSignature,
            projection: newProjection,
            groups: [ProviderCatalogGroup(id: "openai", title: "OpenAI", models: [])]
        )

        #expect(update.expandedGroupIDs.isEmpty)
        #expect(update.signature?.groupIDs == ["openai"])
        #expect(update.shouldPersist)
    }

    @Test("First Appearance Keeps Every Group Collapsed")
    func firstAppearanceKeepsEveryGroupCollapsed() {
        let snapshot = ProviderCatalogSnapshotIdentity(
            providerID: UUID(),
            providersVersion: 1,
            metadataContentRevision: 1,
            metadataETag: "etag",
            recencyBucket: 100
        )
        let projection = ProviderCatalogProjectionRequestIdentity(snapshot: snapshot, searchText: "")

        let update = ProviderCatalogExpansionPolicy.reconcile(
            expandedGroupIDs: [],
            previousSignature: nil,
            projection: projection,
            groups: [
                ProviderCatalogGroup(id: "openai", title: "OpenAI", models: []),
                ProviderCatalogGroup(id: "anthropic", title: "Anthropic", models: []),
            ]
        )

        #expect(update.expandedGroupIDs.isEmpty)
        #expect(update.signature?.groupIDs == ["openai", "anthropic"])
        #expect(!update.shouldPersist)
    }

    @Test("Aggregator Catalog Groups Use Metadata Identity And Rank")
    func aggregatorCatalogGroupsUseMetadataIdentityAndRank() {
        let provider = Provider(
            id: .init(),
            kind: .openRouter,
            status: .connected,
            models: [],
            catalogModels: [
                AIModel(
                    id: "alpha/vendor-a-model",
                    name: "Vendor A",
                    capabilities: [.text],
                    reasoningModeAvailable: false,
                    isAvailable: true,
                    isDefault: false,
                    priceTier: "",
                    groupKey: "zeta-labs",
                    groupName: "Zeta Labs",
                    sortRank: 220
                ),
                AIModel(
                    id: "beta/vendor-b-model",
                    name: "Vendor B",
                    capabilities: [.text],
                    reasoningModeAvailable: false,
                    isAvailable: true,
                    isDefault: false,
                    priceTier: "",
                    groupKey: "alpha-ai",
                    groupName: "Alpha AI",
                    sortRank: 120
                ),
            ],
            lastCheckedAt: nil,
            apiKey: "sk-test",
            apiKeyPreview: "sk-...",
            lastError: nil,
            baseURLText: nil
        )

        let groups = buildProviderCatalogGroups(for: provider, searchText: "")

        #expect(groups.map(\.id) == ["zeta-labs", "alpha-ai"])
        #expect(groups.map(\.title) == ["Zeta Labs", "Alpha AI"])
    }

    @Test("enabled vendor groups only render explicit metadata groups and keep ungrouped models unheaded")
    func enabledVendorGroupsRequireExplicitMetadataIdentity() {
        let provider = Provider(
            id: .init(),
            kind: .openRouter,
            status: .connected,
            models: [
                AIModel(
                    id: "vendor-b/model-1",
                    name: "Vendor B",
                    capabilities: [.text],
                    reasoningModeAvailable: false,
                    isAvailable: true,
                    isDefault: false,
                    priceTier: "",
                    groupKey: "vendor-b",
                    groupName: "Vendor B",
                    sortRank: 120
                ),
                AIModel(
                    id: "vendor-a/model-1",
                    name: "Vendor A",
                    capabilities: [.text],
                    reasoningModeAvailable: false,
                    isAvailable: true,
                    isDefault: true,
                    priceTier: "",
                    groupKey: "vendor-a",
                    groupName: "Vendor A",
                    sortRank: 220
                ),
                AIModel(
                    id: "orphan/model",
                    name: "Orphan",
                    capabilities: [.text],
                    reasoningModeAvailable: false,
                    isAvailable: true,
                    isDefault: false,
                    priceTier: ""
                ),
            ],
            catalogModels: [],
            lastCheckedAt: nil,
            apiKey: "sk-test",
            apiKeyPreview: "sk-...",
            lastError: nil,
            baseURLText: nil
        )

        let groups = groupModelsByVendor(provider: provider, models: provider.models)

        #expect(groups.map(\.groupName) == ["Vendor A", "Vendor B", nil])
        #expect(groups.last?.models.map(\.id) == ["orphan/model"])
    }

    @Test("single explicit vendor group remains visible when mixed with ungrouped models")
    func singleExplicitVendorGroupRemainsVisible() {
        let provider = Provider(
            id: .init(),
            kind: .openRouter,
            status: .connected,
            models: [
                AIModel(
                    id: "vendor-a/model-1",
                    name: "Vendor A",
                    capabilities: [.text],
                    reasoningModeAvailable: false,
                    isAvailable: true,
                    isDefault: true,
                    priceTier: "",
                    groupKey: "vendor-a",
                    groupName: "Vendor A",
                    sortRank: 220
                ),
                AIModel(
                    id: "orphan/model",
                    name: "Orphan",
                    capabilities: [.text],
                    reasoningModeAvailable: false,
                    isAvailable: true,
                    isDefault: false,
                    priceTier: ""
                ),
            ],
            catalogModels: [],
            lastCheckedAt: nil,
            apiKey: "sk-test",
            apiKeyPreview: "sk-...",
            lastError: nil,
            baseURLText: nil
        )

        let groups = groupModelsByVendor(provider: provider, models: provider.models)

        #expect(groups.map(\.groupName) == ["Vendor A", nil])
        #expect(groups.first?.models.map(\.id) == ["vendor-a/model-1"])
        #expect(groups.last?.models.map(\.id) == ["orphan/model"])
    }

    @Test("model picker renders empty addable provider sections without search")
    func modelPickerRendersEmptyAddableProviderSections() {
        let openRouter = makeProvider(kind: .openRouter, models: [])
        let qwen = makeProvider(kind: .qwen, models: [])
        let sorted = sortedProvidersForModelPicker([qwen, openRouter])

        #expect(shouldRenderModelPickerProviderSection(provider: openRouter, query: "", models: []))
        #expect(!shouldRenderModelPickerProviderSection(provider: openRouter, query: "gpt", models: []))
        #expect(defaultExpandedModelPickerProviderIDs(sorted) == [openRouter.id])
    }

    @Test("Catalog Priority Uses Capability Evidence")
    func catalogPriorityUsesCapabilityEvidence() async throws {
        await MetadataClient.shared.resetForTesting()
        let runtime = try CapabilityRuntimeFixtures.runtimeEnvelopeJSON()
        let controls = try CapabilityRuntimeFixtures.controlsJSON(
            .init(
                capability: "reasoning",
                recipeRef: "openai.responses.reasoning.v1",
                availableIntents: try CapabilityRuntimeFixtures.reasoningIntents(
                    ofRecipe: "openai.responses.reasoning.v1"
                )
            )
        )
        try await MetadataClient.shared.loadForTesting(json: """
        {
          "version": 1,
          "capabilityRuntime": \(runtime),
          "profiles": {"reasoning": {"reasoning-profile": {"levels": ["deep"]}}},
          "providers": {"openAI": {
            "resolveMap": {"raw-liar":"raw-liar", "evidenced":"evidenced"},
            "models": {
              "raw-liar": {
                "canonicalModelId":"raw-liar", "transport":"openai_responses",
                "capabilities":["text"], "profiles":{}
              },
              "evidenced": {
                "canonicalModelId":"evidenced", "transport":"openai_responses",
                "capabilities":["text","reasoning"],
                "capabilityControls":\(controls),
                "profiles":{"reasoning":"reasoning-profile"}
              }
            }
          }}
        }
        """, metadataETag: "priority-evidence-etag")
        let rawLiar = TestFactories.makeModel(
            id: "raw-liar", capabilities: [.reasoning], reasoningModeAvailable: true
        )
        let evidenced = TestFactories.makeModel(id: "evidenced")
        let provider = TestFactories.makeProvider(
            kind: .openAI, models: [rawLiar, evidenced]
        )

        #expect(
            catalogPriorityScore(for: evidenced, provider: provider)
                > catalogPriorityScore(for: rawLiar, provider: provider)
        )
        await MetadataClient.shared.resetForTesting()
    }

    private func makeProvider(
        kind: ProviderKind,
        models: [AIModel],
        catalogModels: [AIModel] = [],
        customName: String? = nil
    ) -> Provider {
        Provider(
            id: .init(),
            kind: kind,
            status: .connected,
            models: models,
            catalogModels: catalogModels,
            lastCheckedAt: nil,
            apiKey: "sk-test",
            apiKeyPreview: "sk-...",
            lastError: nil,
            baseURLText: nil,
            customName: customName
        )
    }
}
