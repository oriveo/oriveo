import SwiftUI
import Testing
import UIKit
@testable import Oriveo

/// Geometry invariants of the flattened catalog groups versus the pre-flattening whole card (`ProviderCatalogGroupCard`).
///
/// The start and end y of the group header, the hairline under the header and every row (including the hairlines between rows) must match the pre-fix whole-card algorithm; the card bottom sits against the bottom of the last row.
/// The pre-fix whole card ended about 0.833pt below the last row (on a 3x screen); that was a container side effect of the removed inner LazyVStack rounding its own height up to a whole point,
/// not a design intent, and it is not compensated after flattening.
@MainActor
@Suite("Catalog group geometry after flattening", .serialized)
struct ProviderCatalogGroupMetricsTests {
    /// Reference box for the measurement results: written in layout callbacks, kept out of view state.
    private final class Box {
        var slices: [CGRect] = []
        var cards: [ProviderPanelGroupCard] = []
        var referenceParts: [String: CGRect] = [:]
    }

    private struct Measurement {
        let scale: CGFloat
        /// The bounds of each slice in the flattened host (relative to the top of the group header).
        let slices: [CGRect]
        /// The whole cards computed by the production path `ProviderPanelGroupCard.cards` (relative to the top of the group header).
        let card: CGRect
        /// The group header / row frames under the pre-fix whole-card algorithm (relative to the top of the group header).
        let referenceHeader: CGRect
        let referenceRows: [CGRect]
    }

    private static let hairline: CGFloat = 0.5
    private static let widths: [CGFloat] = [390, 320, 280]

    private func models() -> [AIModel] {
        // Isomorphic to Vendor 0 in the `catalog-groups` visual snapshot: long-name and short-name rows mixed, with mixed capabilities and free tags.
        let capabilitySets: [[ModelCapability]] = [
            [.text, .web, .image, .toolCall, .file, .reasoning],
            [.text, .image],
            [.text, .toolCall, .web],
            [.text],
        ]
        return [0, 3, 6, 9].map { index in
            TestFactories.makeModel(
                id: "lib-\(index)",
                name: index % 5 == 0 ? "LIB Model \(index) With A Considerably Longer Display Name" : "LIB-\(index)",
                capabilities: capabilitySets[index % capabilitySets.count],
                isAvailable: index % 7 != 6,
                isDefault: index == 1,
                priceTier: index % 4 == 3 ? "Free" : "",
                groupKey: "vendor-0",
                groupName: "Vendor 0",
                promptPrice: index % 4 == 3 ? nil : 0.0000025,
                completionPrice: index % 4 == 3 ? nil : 0.00001
            )
        }
    }

    private func host<V: View>(width: CGFloat, @ViewBuilder content: () -> V) throws -> (UIWindow, CGFloat) {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: width, height: 1600)
        let controller = UIHostingController(rootView: content())
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.frame = window.bounds
        controller.view.layoutIfNeeded()
        pumpMainRunLoop(0.6)
        return (window, window.screen.scale)
    }

    private func tearDown(_ window: UIWindow) {
        window.isHidden = true
        window.rootViewController = nil
    }

    private func measure(width: CGFloat) throws -> Measurement {
        let models = models()
        let provider = TestFactories.makeProvider(kind: .openAI, models: Array(models.prefix(1)))
        let group = ProviderCatalogGroup(id: "vendor-0", title: "Vendor 0", models: models)
        let box = Box()

        // After the fix: the group header and rows are emitted as siblings inside the host's only lazy layer (spacing 0).
        let (flatWindow, scale) = try host(width: width) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ProviderCatalogGroupList(
                        provider: provider,
                        capabilityEvidenceRevision: 1,
                        groups: [group],
                        searchText: "",
                        expandedGroupIDs: ["vendor-0"],
                        coordinateSpaceName: nil,
                        onToggleGroup: { _ in },
                        onAddModel: { _, _ in }
                    )
                }
                .backgroundPreferenceValue(ProviderPanelGroupBoundsKey.self) { fragments in
                    GeometryReader { proxy in
                        let slices = fragments.map { proxy[$0.bounds] }
                        let cards = ProviderPanelGroupCard.cards(from: fragments, in: proxy)
                        let _ = {
                            box.slices = slices
                            box.cards = cards
                        }()
                        Color.clear
                    }
                }
                .padding(16)
            }
        }

        // Before the fix: a whole-card VStack (group header -> 0.5pt hairline -> inner LazyVStack rows + hairlines between rows),
        // with the group header taken from the same production group header (the collapsed state emits only the header slice, and the button geometry is the same as expanded).
        let (referenceWindow, _) = try host(width: width) {
            ScrollView {
                VStack(spacing: 0) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ProviderCatalogGroupList(
                            provider: provider,
                            capabilityEvidenceRevision: 1,
                            groups: [group],
                            searchText: "",
                            expandedGroupIDs: [],
                            coordinateSpaceName: nil,
                            onToggleGroup: { _ in },
                            onAddModel: { _, _ in }
                        )
                    }
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { box.referenceParts["header"] = $0 }
                    Rectangle()
                        .fill(OriveoTheme.Palette.border.opacity(0.45))
                        .frame(height: Self.hairline)
                    LazyVStack(spacing: 0) {
                        ForEach(Array(models.enumerated()), id: \.element.id) { index, model in
                            ProviderCatalogModelRow(
                                model: model,
                                provider: provider,
                                capabilityEvidenceRevision: 1,
                                nested: true,
                                catalogBoard: nil,
                                openAdvancedAction: {}
                            ) {}
                            .equatable()
                            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { box.referenceParts["row\(index)"] = $0 }

                            if index < models.count - 1 {
                                Rectangle()
                                    .fill(OriveoTheme.Palette.border.opacity(0.45))
                                    .frame(height: Self.hairline)
                                    .padding(.leading, OriveoTheme.Spacing.md)
                            }
                        }
                    }
                }
                .padding(16)
            }
        }
        defer {
            tearDown(flatWindow)
            tearDown(referenceWindow)
        }

        let card = try #require(box.cards.first, "w\(Int(width)): no card from production fragments")
        let flatTop = try #require(box.slices.first).minY
        let referenceHeader = try #require(box.referenceParts["header"])
        let referenceTop = referenceHeader.minY
        let referenceRows = try (0..<models.count).map { index in
            try #require(box.referenceParts["row\(index)"], "w\(Int(width)): row\(index) not laid out")
        }
        func relative(_ rect: CGRect, _ top: CGFloat) -> CGRect { rect.offsetBy(dx: 0, dy: -top) }
        return Measurement(
            scale: scale,
            slices: box.slices.map { relative($0, flatTop) },
            card: relative(card.frame, flatTop),
            referenceHeader: relative(referenceHeader, referenceTop),
            referenceRows: referenceRows.map { relative($0, referenceTop) }
        )
    }

    @Test("after flattening the start and end y of the group header / hairline / rows match the pre-fix whole-card algorithm")
    func flattened_group_slices_match_card_layout() throws {
        for width in Self.widths {
            let m = try measure(width: width)
            let tolerance = 1 / m.scale
            let rowCount = m.referenceRows.count
            try #require(m.slices.count == rowCount + 1, "w\(Int(width)): slices \(m.slices.count)")

            // Header slice = header button + the hairline under the header.
            #expect(abs(m.slices[0].minY - m.referenceHeader.minY) <= tolerance, "w\(Int(width)) header top")
            #expect(
                abs(m.slices[0].maxY - (m.referenceHeader.maxY + Self.hairline)) <= tolerance,
                "w\(Int(width)) header bottom \(m.slices[0].maxY) vs \(m.referenceHeader.maxY + Self.hairline)"
            )
            // Row slice = row + the hairline between rows (the last row has none).
            for (index, row) in m.referenceRows.enumerated() {
                let slice = m.slices[index + 1]
                let expectedBottom = row.maxY + (index < rowCount - 1 ? Self.hairline : 0)
                #expect(abs(slice.minY - row.minY) <= tolerance, "w\(Int(width)) row\(index) top \(slice.minY) vs \(row.minY)")
                #expect(
                    abs(slice.maxY - expectedBottom) <= tolerance,
                    "w\(Int(width)) row\(index) bottom \(slice.maxY) vs \(expectedBottom)"
                )
            }
        }
    }

    @Test("the whole-card bottom edge sits against the bottom of the last row")
    func group_card_bottom_hugs_last_row() throws {
        for width in Self.widths {
            let m = try measure(width: width)
            let tolerance = 1 / m.scale
            let lastRow = try #require(m.referenceRows.last)
            let lastSlice = try #require(m.slices.last)
            #expect(m.card.minY.magnitude <= tolerance, "w\(Int(width)) card top \(m.card.minY)")
            #expect(abs(m.card.maxY - lastSlice.maxY) <= tolerance, "w\(Int(width)) card bottom vs last slice")
            #expect(abs(m.card.maxY - lastRow.maxY) <= tolerance, "w\(Int(width)) card bottom \(m.card.maxY) vs last row \(lastRow.maxY)")
        }
    }

    private func scrollView(in view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView { return scroll }
        for sub in view.subviews { if let hit = scrollView(in: sub) { return hit } }
        return nil
    }

    @Test("header scrolled out of the viewport with several groups: the highlight gradient height does not change with the built slices")
    func highlight_height_independent_of_built_slices() throws {
        // Intent: the highlight gradient is one gradient across the whole card from top left to bottom right. After flattening the whole-card frame is only the union of the built slices (plus the extension of the unbuilt side),
        // and stretches and shrinks with slices being built / recycled while scrolling; if the gradient were laid over this frame, scrolling the same card would stretch / squash the gradient.
        let groupCount = 3
        let rowsPerGroup = 30
        let groups = (0..<groupCount).map { groupIndex in
            ProviderCatalogGroup(
                id: "vendor-\(groupIndex)",
                title: "Vendor \(groupIndex)",
                models: (0..<rowsPerGroup).map { index in
                    TestFactories.makeModel(
                        id: "hl-\(groupIndex)-\(index)",
                        name: "HL-\(groupIndex)-\(index)",
                        capabilities: [.text],
                        groupKey: "vendor-\(groupIndex)",
                        groupName: "Vendor \(groupIndex)"
                    )
                }
            )
        }
        let provider = TestFactories.makeProvider(kind: .openAI, models: [])
        let box = Box()
        let (window, scale) = try host(width: 390) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ProviderCatalogGroupList(
                        provider: provider,
                        capabilityEvidenceRevision: 1,
                        groups: groups,
                        searchText: "",
                        expandedGroupIDs: Set(groups.map(\.id)),
                        coordinateSpaceName: nil,
                        onToggleGroup: { _ in },
                        onAddModel: { _, _ in }
                    )
                }
                .backgroundPreferenceValue(ProviderPanelGroupBoundsKey.self) { fragments in
                    GeometryReader { proxy in
                        let cards = ProviderPanelGroupCard.cards(from: fragments, in: proxy)
                        let _ = { box.cards = cards }()
                        Color.clear
                    }
                }
                .padding(16)
            }
        }
        defer { tearDown(window) }
        window.frame.size.height = 700
        window.rootViewController?.view.frame = window.bounds
        window.rootViewController?.view.layoutIfNeeded()
        pumpMainRunLoop(0.4)
        let scroll = try #require(window.rootViewController.flatMap { scrollView(in: $0.view) })

        var heights: [String: [CGFloat]] = [:]
        var sawHeaderlessCard = false
        let maxOffset = max(0, scroll.contentSize.height - scroll.bounds.height)
        for offset in stride(from: CGFloat(0), through: maxOffset, by: 600) {
            scroll.setContentOffset(CGPoint(x: 0, y: offset), animated: false)
            scroll.layoutIfNeeded()
            pumpMainRunLoop(0.2)
            for card in box.cards {
                heights[card.id, default: []].append(card.highlightFrame.height)
                if !card.closesTop { sawHeaderlessCard = true }
            }
        }
        try #require(sawHeaderlessCard, "no card with a recycled header was measured, so drift cannot be tested")
        let all = heights.values.flatMap { $0 }
        let reference = try #require(all.first)
        let tolerance = 1 / scale
        print("[HIGHLIGHT] heights \(heights.mapValues { $0.map { Int($0) } })")
        for (id, values) in heights {
            for value in values {
                // Every group has the same row count and the same nominal height: neither the same card at different scroll positions nor different cards may change.
                #expect(abs(value - reference) <= tolerance, "\(id) highlight height \(value) vs \(reference)")
            }
        }
    }

    @Observable
    final class ExpansionHolder {
        var expanded: Set<String> = []
    }

    private final class FragmentBox {
        var slices: [String] = []
        /// The height of each whole card (computed by `ProviderPanelGroupCard.cards`), and the actual height of each card's header slice.
        var cardHeights: [String: CGFloat] = [:]
        var headerHeights: [String: CGFloat] = [:]
    }

    /// The catalog group list + the host lazy stack; the background layer reads the slice preference and records the slices and the whole-card heights by the production whole-card algorithm.
    private struct CatalogHost: View {
        let provider: Provider
        let groups: [ProviderCatalogGroup]
        let holder: ExpansionHolder
        let box: FragmentBox
        var body: some View {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ProviderCatalogGroupList(
                        provider: provider,
                        capabilityEvidenceRevision: 1,
                        groups: groups,
                        searchText: "",
                        expandedGroupIDs: holder.expanded,
                        coordinateSpaceName: nil,
                        onToggleGroup: { _ in },
                        onAddModel: { _, _ in }
                    )
                }
                .backgroundPreferenceValue(ProviderPanelGroupBoundsKey.self) { fragments in
                    GeometryReader { proxy in
                        let _ = {
                            box.slices = fragments.map { "\($0.groupID)#\($0.index)/\($0.count)" }
                            box.cardHeights = Dictionary(
                                ProviderPanelGroupCard.cards(from: fragments, in: proxy).map { ($0.id, $0.frame.height) },
                                uniquingKeysWith: { first, _ in first }
                            )
                            box.headerHeights = Dictionary(
                                fragments.filter { $0.index == 0 }.map { ($0.groupID, proxy[$0.bounds].height) },
                                uniquingKeysWith: { first, _ in first }
                            )
                        }()
                        Color.clear
                    }
                }
            }
        }
    }

    private func catalogModel(_ id: String, group: String) -> AIModel {
        TestFactories.makeModel(id: id, name: "Model \(id)", capabilities: [.text], groupKey: group, groupName: group)
    }

    /// The set of slices each group's "header + expanded rows" should have.
    private func expectedSlices(_ groups: [ProviderCatalogGroup], expanded: Set<String>) -> [String] {
        groups.flatMap { group -> [String] in
            let count = expanded.contains(group.id) ? group.models.count + 1 : 1
            return (0..<count).map { "catalog:\(group.id)#\($0)/\(count)" }
        }.sorted()
    }

    @Test("when a group id equals some model id the group header and that row are both built")
    func group_header_and_row_with_same_id_both_built() throws {
        // Intent: the group header and the catalog rows are emitted as siblings in the same lazy stack. The family ids of a relay / local catalog (qwen / deepseek / other)
        // may equal some model id; if both identities used the raw id they would collide, the lazy stack would reuse the old view, and the group header or that row would not be built
        // (the same root as the enabled section colliding with catalog rows). Only expand step by step: leftovers after collapsing are locked separately by `collapse_drops_removed_slice_bounds`.
        // Every group has one model whose id equals another group's id (or its own).
        let groups = [
            ProviderCatalogGroup(id: "other", title: "Other", models: [catalogModel("o-1", group: "other"), catalogModel("qwen", group: "other")]),
            ProviderCatalogGroup(id: "qwen", title: "Qwen", models: [catalogModel("other", group: "qwen"), catalogModel("deepseek", group: "qwen"), catalogModel("q-2", group: "qwen")]),
            ProviderCatalogGroup(id: "deepseek", title: "DeepSeek", models: [catalogModel("d-1", group: "deepseek")]),
        ]
        let provider = TestFactories.makeProvider(kind: .relay, models: [])
        let holder = ExpansionHolder()
        let box = FragmentBox()
        let (window, _) = try host(width: 390) { CatalogHost(provider: provider, groups: groups, holder: holder, box: box) }
        defer { tearDown(window) }

        #expect(box.slices.sorted() == expectedSlices(groups, expanded: holder.expanded), "collapsed: \(box.slices)")
        for step in [Set(["other"]), Set(["other", "qwen"]), Set(["other", "qwen", "deepseek"])] {
            withAnimation(.snappy) { holder.expanded = step }
            pumpMainRunLoop(0.6)
            window.rootViewController?.view.layoutIfNeeded()
            pumpMainRunLoop(0.2)
            print("[GROUP-ID] \(step.sorted()) -> \(box.slices)")
            #expect(box.slices.sorted() == expectedSlices(groups, expanded: step), "expanded \(step.sorted()): \(box.slices)")
        }
    }

    @Test("after a group collapses the slice bounds of removed rows do not linger: the whole-card height returns to the header height")
    func collapse_drops_removed_slice_bounds() throws {
        // Intent: when a group collapses, the removed rows carry a removal transition; once it ends their bounds must not remain in the preference the whole-card background reads,
        // otherwise the whole card (background / stroke) would still be drawn at the old expanded height and cover the group below. The ids do not collide, only collapsing is measured.
        let groups = (0..<3).map { g in
            ProviderCatalogGroup(
                id: "family-\(g)", title: "Family \(g)",
                models: (0..<3).map { catalogModel("family-\(g)-model-\($0)", group: "family-\(g)") }
            )
        }
        let provider = TestFactories.makeProvider(kind: .relay, models: [])
        let holder = ExpansionHolder()
        let box = FragmentBox()
        let (window, _) = try host(width: 390) { CatalogHost(provider: provider, groups: groups, holder: holder, box: box) }
        defer { tearDown(window) }

        let all = Set(groups.map(\.id))
        withAnimation(.snappy) { holder.expanded = all }
        pumpMainRunLoop(0.6)
        window.rootViewController?.view.layoutIfNeeded()
        pumpMainRunLoop(0.2)
        #expect(box.slices.sorted() == expectedSlices(groups, expanded: all), "expanded: \(box.slices)")

        let remaining: Set<String> = ["family-1"]
        withAnimation(.snappy) { holder.expanded = remaining }
        // Record how the leftovers change over time during the transition, and assert after settling.
        var elapsed: TimeInterval = 0
        for delta in [0.2, 0.4, 0.6, 0.8] {
            pumpMainRunLoop(delta)
            elapsed += delta
            window.rootViewController?.view.layoutIfNeeded()
            print("[COLLAPSE] t=\(elapsed)s slices=\(box.slices.count) \(box.slices.sorted()) cards=\(box.cardHeights) headers=\(box.headerHeights)")
        }
        #expect(box.slices.sorted() == expectedSlices(groups, expanded: remaining), "settled: \(box.slices)")
        for id in all.subtracting(remaining) {
            let cardID = "catalog:\(id)"
            let card = try #require(box.cardHeights[cardID])
            let header = try #require(box.headerHeights[cardID])
            #expect(abs(card - header) <= 0.5, "\(cardID) card \(card) vs header \(header)")
        }
    }
}
