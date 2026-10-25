import SwiftUI
import Testing
@testable import Oriveo

/// Structure gate: on one scroll axis the provider model page allows only one level of lazy stack.
///
/// "outer LazyVStack -> card VStack -> inner LazyVStack" has a lazy-allocation race on iOS 26 that can hang the main thread permanently
/// (Apple DTS, developer.apple.com/forums/thread/814208); the slowdown cannot be measured on the simulator, so only the structure can be locked.
/// The outer lazy layer is provided by the host (`ProviderDetailView` / `InlineModelCatalogView`); what is locked here is the body of the
/// block embedded in the host: its concrete type string must no longer contain `LazyVStack`.
@MainActor
@Suite("Provider model page lazy-stack nesting structure gate")
struct ProviderLazyNestingStructureTests {
    private func bodyTypeName<V: View>(_ view: V) -> String {
        String(describing: type(of: view.body))
    }

    private func makeModels(count: Int) -> [AIModel] {
        (0..<count).map { index in
            TestFactories.makeModel(
                id: "nesting-model-\(index)",
                name: "Nesting Model \(index)",
                groupKey: "vendor-\(index % 2)",
                groupName: "Vendor \(index % 2)"
            )
        }
    }

    @Test("catalog group list: no lazy stack inside the group card, group header and rows are emitted as siblings")
    func catalog_group_card_has_no_inner_lazy_stack() {
        let models = makeModels(count: 6)
        let provider = TestFactories.makeProvider(kind: .openRouter, models: [], catalogModels: models)
        let list = ProviderCatalogGroupList(
            provider: provider,
            capabilityEvidenceRevision: 0,
            groups: [ProviderCatalogGroup(id: "vendor-0", title: "Vendor 0", models: models)],
            searchText: "model",
            expandedGroupIDs: [],
            coordinateSpaceName: nil,
            onToggleGroup: { _ in },
            onAddModel: { _, _ in }
        )
        let name = bodyTypeName(list)
        print("[LAZY-NESTING] ProviderCatalogGroupList.body = \(name)")
        #expect(!name.contains("LazyVStack"))
        // When a whole group is wrapped into one card view, the row container inside the card body is invisible here; once emitted as siblings there should be no card wrapper.
        #expect(!name.contains("ProviderCatalogGroupCard"))
    }

    @Test("enabled models section: rows are emitted as siblings, no lazy stack inside the block")
    func enabled_models_section_has_no_inner_lazy_stack() {
        let provider = TestFactories.makeProvider(kind: .openRouter, models: makeModels(count: 4))
        let section = ProviderEnabledModelsSection(
            provider: provider,
            highlightedModelID: nil,
            coordinateSpaceName: "nesting",
            enabledModelsFrameBox: ProviderDetailFrameBox(),
            onSetDefault: { _ in },
            onChat: { _ in },
            onRemove: { _ in }
        )
        let name = bodyTypeName(section)
        print("[LAZY-NESTING] ProviderEnabledModelsSection.body = \(name)")
        #expect(!name.contains("LazyVStack"))
    }

    @Test("model library block: search field, status card and catalog list are emitted as siblings, no lazy stack inside the block")
    func model_library_section_has_no_inner_lazy_stack() {
        let provider = TestFactories.makeProvider(kind: .openRouter, models: [], catalogModels: makeModels(count: 6))
        let section = ProviderModelLibrarySection(
            provider: provider,
            providersVersion: 0,
            projection: ProviderCatalogLibraryProjection(),
            modelSearchText: .constant(""),
            expandedLibraryGroups: .constant([]),
            coordinateSpaceName: "nesting",
            viewportSize: CGSize(width: 390, height: 844),
            onAddCatalogModel: { _, _ in },
            onRetryCatalog: {},
            onAddManualModel: {},
            isCatalogRefreshing: false
        )
        let name = bodyTypeName(section)
        print("[LAZY-NESTING] ProviderModelLibrarySection.body = \(name)")
        #expect(!name.contains("LazyVStack"))
    }

    @Test("model library subpage: page header and content are emitted as siblings, no lazy stack inside the page")
    func relay_model_library_page_has_no_inner_lazy_stack() {
        let provider = TestFactories.makeProvider(kind: .relay, models: makeModels(count: 2))
        let page = RelayModelLibraryPage(
            provider: provider,
            isRefreshing: false,
            onBack: {},
            onRefresh: {}
        ) {
            Text(verbatim: "content")
        }
        let name = bodyTypeName(page)
        print("[LAZY-NESTING] RelayModelLibraryPage.body = \(name)")
        #expect(!name.contains("LazyVStack"))
    }

    @Test("catalog group header and catalog row: no lazy stack in their own body")
    func catalog_group_header_and_rows_have_no_inner_lazy_stack() {
        let models = makeModels(count: 2)
        let provider = TestFactories.makeProvider(kind: .openRouter, models: [], catalogModels: models)
        let group = ProviderCatalogGroup(id: "vendor-0", title: "Vendor 0", models: models)
        let header = ProviderCatalogGroupHeader(
            provider: provider,
            group: group,
            isExpanded: true,
            canToggle: true,
            catalogBoard: nil,
            onToggle: {}
        )
        let groupRow = ProviderCatalogGroupRow(
            provider: provider,
            capabilityEvidenceRevision: 0,
            model: models[0],
            showsDivider: true,
            coordinateSpaceName: "nesting",
            rowFrames: CatalogRowFrameStore(),
            catalogBoard: nil,
            onAddModel: { _, _ in }
        )
        let modelRow = ProviderCatalogModelRow(
            model: models[0],
            provider: provider,
            capabilityEvidenceRevision: 0,
            nested: true,
            catalogBoard: nil,
            openAdvancedAction: {}
        ) {}
        for (label, name) in [
            ("ProviderCatalogGroupHeader", bodyTypeName(header)),
            ("ProviderCatalogGroupRow", bodyTypeName(groupRow)),
            ("ProviderCatalogModelRow", bodyTypeName(modelRow)),
        ] {
            print("[LAZY-NESTING] \(label).body = \(name)")
            #expect(!name.contains("LazyVStack"), "\(label)")
        }
    }
}
