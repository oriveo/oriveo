import SwiftUI
import Testing
import UIKit
@testable import Oriveo

/// Diagnostic: the rendering cost of the provider detail page's "model library" list.
///
/// Two questions that nothing else can answer:
/// 1. **Does laziness still hold?** `ProviderCatalogGroupList` is a `LazyVStack`, but every group card is **again**
///    a `LazyVStack` once expanded. When nested, the outer one asks the inner one for its ideal size to estimate the content size, and laziness may collapse as a whole.
///    Criterion: how many **distinct** models had a presentation built during one first-screen layout - close to the number of visible rows means laziness holds,
///    close to the total number of rows means it collapsed.
/// 2. **How big is the per-row constant factor?** Every `ModelCapabilityEvidencePresentation` construction runs 3-4 calls to
///    `MetadataClient.resolveCatalogModel`, which is not memoized (the similarly costly `ProviderCatalogResolver`
///    is). Criterion: the number of resolveCatalogModel calls and the wall clock triggered by one row body evaluation.
///
/// This file only measures and asserts no performance thresholds (simulator and device differ by an order of magnitude).
/// The numbers go to stdout, prefixed `[CATALOG-COST]`.
@MainActor
@Suite("Provider catalog list rendering cost measurement", .serialized, .sharedProcessState)
struct ProviderCatalogListCostMeasurementTests {

    /// The catalog size takes the upper bound of the usual case in the production comment: `ProviderCatalogGroupList` documents 400-777 rows.
    private static let modelCount = 777
    private static let groupCount = 20

    // MARK: - Fixtures

    private func modelID(_ index: Int) -> String { "cost-model-\(index)" }

    private func groupIndex(for modelIndex: Int) -> Int {
        modelIndex % Self.groupCount
    }

    /// Generate a metadata snapshot with a realistic structure: `resolveCatalogModel` only runs the full normalize + ResolvedModelMetadata construction when it can find the entry,
    /// and returns nil right at the guard when it cannot,
    /// which would badly underestimate the production cost.
    private func metadataJSON() -> String {
        var resolveEntries: [String] = []
        var modelEntries: [String] = []
        for index in 0..<Self.modelCount {
            let id = modelID(index)
            resolveEntries.append("\"\(id)\":\"\(id)\"")
            modelEntries.append("""
            "\(id)": {
              "canonicalModelId": "\(id)",
              "transport": "openai_responses",
              "capabilities": ["text", "web", "vision_input", "tool_call", "file"],
              "contextLength": 128000,
              "maxOutputTokens": 16384,
              "pricing": {"promptPerToken": 0.0000025, "completionPerToken": 0.00001},
              "pricingUnit": "per_token"
            }
            """)
        }
        return """
        {
          "version": 1,
          "providers": {"openAI": {
            "resolveMap": {\(resolveEntries.joined(separator: ","))},
            "models": {\(modelEntries.joined(separator: ","))}
          }}
        }
        """
    }

    private func makeModels() -> [AIModel] {
        (0..<Self.modelCount).map { index in
            TestFactories.makeModel(
                id: modelID(index),
                name: "Cost Model \(index) Long Enough Display Name",
                capabilities: [.text, .web, .image, .toolCall, .file],
                priceTier: "",
                groupKey: "group-\(groupIndex(for: index))",
                groupName: "Vendor \(groupIndex(for: index))",
                promptPrice: 0.0000025,
                completionPrice: 0.00001
            )
        }
    }

    private func makeGroups(_ models: [AIModel]) -> [ProviderCatalogGroup] {
        (0..<Self.groupCount).map { group in
            ProviderCatalogGroup(
                id: "group-\(group)",
                title: "Vendor \(group)",
                models: models.filter { groupIndex(for: Int($0.id.split(separator: "-").last!)!) == group }
            )
        }
    }

    /// Mount the list into a real window, run one full layout, and return the wall-clock time.
    private func hostAndLayoutKeepingWindow(
        provider: Provider,
        groups: [ProviderCatalogGroup],
        expandedGroupIDs: Set<String>
    ) -> (window: UIWindow, host: UIViewController, elapsed: TimeInterval) {
        let host = UIHostingController(
            rootView: ScrollView {
                // The host's only lazy layer: the list emits only sibling group headers and rows, isomorphic to the detail page / home.
                LazyVStack(alignment: .leading, spacing: 0) {
                    ProviderCatalogGroupList(
                        provider: provider,
                        capabilityEvidenceRevision: 1,
                        groups: groups,
                        searchText: "",
                        expandedGroupIDs: expandedGroupIDs,
                        coordinateSpaceName: nil,
                        onToggleGroup: { _ in },
                        onAddModel: { _, _ in }
                    )
                }
                .providerPanelGroupSurfaces()
                .padding(16)
            }
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.rootViewController = host
        window.isHidden = false
        host.view.frame = window.bounds
        let start = Date()
        host.view.layoutIfNeeded()
        for _ in 0..<6 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        return (window, host, Date().timeIntervalSince(start))
    }

    private func firstScrollView(_ view: UIView) -> UIScrollView? {
        if let scrollView = view as? UIScrollView { return scrollView }
        for subview in view.subviews {
            if let found = firstScrollView(subview) { return found }
        }
        return nil
    }

    private func hostAndLayout(
        provider: Provider,
        groups: [ProviderCatalogGroup],
        expandedGroupIDs: Set<String>
    ) -> (elapsed: TimeInterval, maxStall: CFTimeInterval) {
        let host = UIHostingController(
            rootView: ScrollView {
                // The host's only lazy layer: the list emits only sibling group headers and rows, isomorphic to the detail page / home.
                LazyVStack(alignment: .leading, spacing: 0) {
                    ProviderCatalogGroupList(
                        provider: provider,
                        capabilityEvidenceRevision: 1,
                        groups: groups,
                        searchText: "",
                        expandedGroupIDs: expandedGroupIDs,
                        coordinateSpaceName: nil,
                        onToggleGroup: { _ in },
                        onAddModel: { _, _ in }
                    )
                }
                .providerPanelGroupSurfaces()
                .padding(16)
            }
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.rootViewController = host
        window.isHidden = false
        host.view.frame = window.bounds

        // The wall clock includes 6 runloop waits; the longest single main-thread stall is what the user perceives as jank, and the probe measures it.
        let probe = MainThreadStallProbe()
        probe.start()
        let start = Date()
        host.view.layoutIfNeeded()
        // The first SwiftUI frame is asynchronous: run a few runloop turns so the layout settles
        for _ in 0..<6 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        let elapsed = Date().timeIntervalSince(start)
        probe.stop()

        window.isHidden = true
        window.rootViewController = nil
        return (elapsed, probe.maxStall)
    }

    private func distinctConstructedModels(_ models: [AIModel], kind: ProviderKind) -> (distinct: Int, total: Int) {
        var distinct = 0
        var total = 0
        for model in models {
            let count = ModelCapabilityEvidencePresentation.constructionCountForTesting(
                providerKind: kind,
                modelID: model.id
            )
            if count > 0 { distinct += 1 }
            total += count
        }
        return (distinct, total)
    }

    // MARK: - 1. Is laziness holding

    @Test("measurement: how many rows the first-screen layout materializes with all groups expanded")
    func measureExpandedCatalogFirstLayout() async throws {
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(json: metadataJSON(), metadataETag: "cost-etag")

        let models = makeModels()
        let provider = TestFactories.makeProvider(id: UUID(), kind: .openAI, models: models)
        let groups = makeGroups(models)
        let allExpanded = Set(groups.map(\.id))

        ModelCapabilityEvidencePresentation.resetConstructionCountsForTesting()
        MetadataClient.debugResolveCatalogModelCount = 0

        let (elapsed, maxStall) = hostAndLayout(provider: provider, groups: groups, expandedGroupIDs: allExpanded)

        let counts = distinctConstructedModels(models, kind: provider.kind)
        let resolves = MetadataClient.debugResolveCatalogModelCount

        print("""
        [CATALOG-COST] expanded first screen
          total models                          = \(Self.modelCount) (in \(Self.groupCount) groups)
          distinct models with a presentation built = \(counts.distinct)
          total presentation constructions          = \(counts.total)
          resolveCatalogModel calls                 = \(resolves)
          wall clock (layout + 6 runloop turns)     = \(String(format: "%.3f", elapsed))s
          longest main-thread stall                 = \(String(format: "%.0f", maxStall * 1000))ms
        """)

        #expect(counts.distinct >= 0)
        // The same ceiling as ProviderCatalogSearchExpandHangTests: the first-screen layout with everything expanded must not block the main thread for more than 50ms.
        #expect(maxStall <= 0.05)
        await MetadataClient.shared.resetForTesting()
    }

    // MARK: - 2. Collapsed baseline

    @Test("measurement: how many rows the first-screen layout materializes with all groups collapsed")
    func measureCollapsedCatalogFirstLayout() async throws {
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(json: metadataJSON(), metadataETag: "cost-etag")

        let models = makeModels()
        let provider = TestFactories.makeProvider(id: UUID(), kind: .openAI, models: models)
        let groups = makeGroups(models)

        ModelCapabilityEvidencePresentation.resetConstructionCountsForTesting()
        MetadataClient.debugResolveCatalogModelCount = 0

        let (elapsed, _) = hostAndLayout(provider: provider, groups: groups, expandedGroupIDs: [])

        let counts = distinctConstructedModels(models, kind: provider.kind)
        let resolves = MetadataClient.debugResolveCatalogModelCount

        print("""
        [CATALOG-COST] collapsed first screen (baseline)
          distinct models with a presentation built = \(counts.distinct)
          total presentation constructions          = \(counts.total)
          resolveCatalogModel calls                 = \(resolves)
          wall clock                                = \(String(format: "%.3f", elapsed))s
        """)

        #expect(counts.distinct >= 0)
        await MetadataClient.shared.resetForTesting()
    }

    // MARK: - 3. Per-row constant factor

    @Test("measurement: resolveCatalogModel calls and wall clock of one row body evaluation")
    func measurePerRowConstantFactor() async throws {
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(json: metadataJSON(), metadataETag: "cost-etag")

        let models = makeModels()
        let provider = TestFactories.makeProvider(id: UUID(), kind: .openAI, models: models)

        // A single row
        ModelCapabilityEvidencePresentation.resetConstructionCountsForTesting()
        MetadataClient.debugResolveCatalogModelCount = 0
        _ = ProviderCatalogModelRow(
            model: models[0],
            provider: provider,
            capabilityEvidenceRevision: 1,
            nested: true,
            addAction: {}
        ).body
        let singleRowResolves = MetadataClient.debugResolveCatalogModelCount
        let singleRowPresentations = ModelCapabilityEvidencePresentation.constructionCountForTesting(
            providerKind: provider.kind,
            modelID: models[0].id
        )

        // Full body evaluation (body only, without SwiftUI layout / CoreText)
        ModelCapabilityEvidencePresentation.resetConstructionCountsForTesting()
        MetadataClient.debugResolveCatalogModelCount = 0
        let start = Date()
        for model in models {
            _ = ProviderCatalogModelRow(
                model: model,
                provider: provider,
                capabilityEvidenceRevision: 1,
                nested: true,
                addAction: {}
            ).body
        }
        let elapsed = Date().timeIntervalSince(start)
        let allResolves = MetadataClient.debugResolveCatalogModelCount

        print("""
        [CATALOG-COST] per-row constant factor
          single row body: presentation constructions = \(singleRowPresentations), resolveCatalogModel = \(singleRowResolves)
          \(Self.modelCount) row body evaluations: resolveCatalogModel = \(allResolves)
          \(Self.modelCount) row body wall clock (without layout / text layout) = \(String(format: "%.3f", elapsed))s
          per-row average = \(String(format: "%.3f", elapsed * 1000 / Double(Self.modelCount)))ms
        """)

        #expect(singleRowResolves >= 0)
        await MetadataClient.shared.resetForTesting()
    }

    // MARK: - 4. Scrolling through the whole catalog (the real interaction beyond the first screen)

    @Test("measurement: cumulative cost of scrolling through the whole expanded catalog")
    func measureFullScrollSweep() async throws {
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(json: metadataJSON(), metadataETag: "cost-etag")

        let models = makeModels()
        let provider = TestFactories.makeProvider(id: UUID(), kind: .openAI, models: models)
        let groups = makeGroups(models)
        let allExpanded = Set(groups.map(\.id))

        let hosted = hostAndLayoutKeepingWindow(
            provider: provider, groups: groups, expandedGroupIDs: allExpanded
        )
        guard let scrollView = firstScrollView(hosted.host.view) else {
            Issue.record("UIScrollView not found, the scroll measurement cannot run")
            await MetadataClient.shared.resetForTesting()
            return
        }

        ModelCapabilityEvidencePresentation.resetConstructionCountsForTesting()
        MetadataClient.debugResolveCatalogModelCount = 0

        let contentHeight = scrollView.contentSize.height
        let page = scrollView.bounds.height
        let start = Date()
        var offset: CGFloat = 0
        var steps = 0
        while offset < contentHeight - page, steps < 400 {
            offset += page
            scrollView.contentOffset = CGPoint(x: 0, y: min(offset, max(0, contentHeight - page)))
            scrollView.layoutIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.001))
            steps += 1
        }
        let elapsed = Date().timeIntervalSince(start)

        let counts = distinctConstructedModels(models, kind: provider.kind)
        let resolves = MetadataClient.debugResolveCatalogModelCount

        print("""
        [CATALOG-COST] scrolling through the whole expanded catalog
          contentSize.height = \(String(format: "%.0f", contentHeight))pt, viewport \(String(format: "%.0f", page))pt, \(steps) page turns
          distinct models with a presentation built = \(counts.distinct) / \(Self.modelCount)
          total presentation constructions          = \(counts.total)
          resolveCatalogModel calls                 = \(resolves)
          total scroll wall clock                   = \(String(format: "%.3f", elapsed))s
          per-page average                          = \(String(format: "%.1f", elapsed * 1000 / Double(max(1, steps))))ms
        """)

        hosted.window.isHidden = true
        hosted.window.rootViewController = nil
        #expect(counts.distinct >= 0)
        await MetadataClient.shared.resetForTesting()
    }

    // MARK: - 5. Cold-start cost of the catalog resolve (background thread, but it competes with the main thread for CPU and the Swift runtime cache)

    @Test("measurement: cold cost of ProviderCatalogResolver.resolve for a provider with 777 models")
    func measureCatalogResolveColdCost() async throws {
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(json: metadataJSON(), metadataETag: "cost-etag")

        let models = makeModels()
        let provider = TestFactories.makeProvider(id: UUID(), kind: .openAI, models: models)

        ProviderCatalogResolver.resetMemoForTesting()
        MetadataClient.debugResolveCatalogModelCount = 0
        let coldStart = Date()
        _ = ProviderCatalogResolver.resolve(provider: provider)
        let cold = Date().timeIntervalSince(coldStart)
        let coldResolves = MetadataClient.debugResolveCatalogModelCount

        let warmStart = Date()
        _ = ProviderCatalogResolver.resolve(provider: provider)
        let warm = Date().timeIntervalSince(warmStart)

        print("""
        [CATALOG-COST] ProviderCatalogResolver.resolve (\(Self.modelCount) models)
          cold (memoization miss) = \(String(format: "%.3f", cold))s, resolveCatalogModel = \(coldResolves) calls
          warm (memoization hit)  = \(String(format: "%.4f", warm))s
        """)

        #expect(cold >= 0)
        await MetadataClient.shared.resetForTesting()
    }
}
