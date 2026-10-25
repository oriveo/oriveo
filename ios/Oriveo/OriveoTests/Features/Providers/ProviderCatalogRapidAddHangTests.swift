import QuartzCore
import SwiftUI
import Testing
import UIKit
@testable import Oriveo

/// Main-thread cost of tapping "add" repeatedly deep in the model library (a device was killed by the watchdog after 14 quick taps).
///
/// Production path: the real `ProviderDetailView` in a window, the catalog group expanded and scrolled deep, rows "tapped" through
/// accessibility activation, which runs `handleCatalogModelAdd`. Wall-clock numbers are printed, not asserted (simulator vs device).
/// The assertion pins the mechanism: when rows are added far below, the enabled-models section above the viewport must not be laid
/// out again. With a non-lazy outer VStack every insert made it report its full height and re-measure the rows above, and the cost grew
/// with the enabled count (150 enabled: 470ms before, ~150ms after, simulator). Row body counts are similar either way, so watch the frame.
///
/// Always wait with `await Task.sleep`: spinning the run loop synchronously keeps the main queue busy, SwiftUI `.task` (catalog
/// projection) never runs, and the library stays on its spinner.
@MainActor
@Suite("Rapid add in the model library", .serialized, .sharedProcessState)
struct ProviderCatalogRapidAddHangTests {
    private static let catalogCount = 777
    private static let enabledCount = 150
    private static let taps = 14

    private func modelID(_ index: Int) -> String { "rapid-model-\(index)" }

    private func metadataJSON(catalogCount: Int = Self.catalogCount) -> String {
        var resolveEntries: [String] = []
        var modelEntries: [String] = []
        for index in 0..<catalogCount {
            let id = modelID(index)
            resolveEntries.append("\"\(id)\":\"\(id)\"")
            modelEntries.append("""
            "\(id)": {"canonicalModelId": "\(id)", "transport": "openai_responses",
              "capabilities": ["text", "web", "vision_input", "tool_call", "file"],
              "contextLength": 128000, "maxOutputTokens": 16384,
              "pricing": {"promptPerToken": 0.0000025, "completionPerToken": 0.00001}, "pricingUnit": "per_token"}
            """)
        }
        return """
        {"version": 1, "providers": {"openAI": {"resolveMap": {\(resolveEntries.joined(separator: ","))},
          "models": {\(modelEntries.joined(separator: ","))}}}}
        """
    }

    private func settle(_ seconds: TimeInterval) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private func accessibilityElement(where match: (String) -> Bool, in root: NSObject) -> NSObject? {
        var visited = Set<ObjectIdentifier>()
        func search(_ node: NSObject) -> NSObject? {
            guard visited.insert(ObjectIdentifier(node)).inserted else { return nil }
            if node.isAccessibilityElement, let label = node.accessibilityLabel, match(label) { return node }
            var children: [NSObject] = []
            if let elements = node.accessibilityElements as? [NSObject] {
                children.append(contentsOf: elements)
            } else {
                let count = node.accessibilityElementCount()
                if count != NSNotFound, count > 0 {
                    for index in 0..<count {
                        if let child = node.accessibilityElement(at: index) as? NSObject { children.append(child) }
                    }
                }
            }
            if let view = node as? UIView { children.append(contentsOf: view.subviews) }
            for child in children {
                if let hit = search(child) { return hit }
            }
            return nil
        }
        return search(root)
    }

    private func scrollView(in view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView { return scroll }
        for sub in view.subviews { if let hit = scrollView(in: sub) { return hit } }
        return nil
    }

    @Test("OpenAI, 777 catalog / 150 enabled: 14 quick adds deep in the library")
    func rapidAddDeepInLibrary() async throws {
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(json: metadataJSON(), metadataETag: "rapid-etag")
        let catalog = (0..<Self.catalogCount).map { index in
            TestFactories.makeModel(
                id: modelID(index), name: "Rapid Model \(index) Long Enough Display Name",
                capabilities: [.text, .web, .image, .toolCall, .file, .reasoning], priceTier: "",
                promptPrice: 0.0000025, completionPrice: 0.00001
            )
        }
        let provider = TestFactories.makeProvider(
            kind: .openAI, models: Array(catalog.prefix(Self.enabledCount)), catalogModels: catalog
        )
        let state = AppState(seedDemoData: false, sessionUID: "rapid-\(UUID().uuidString)")
        defer {
            state.flushConversationPersistQueue()
            DatabaseManager.shared.close()
            try? FileManager.default.removeItem(at: AppSessionStore.userDir(for: state.sessionPartitionUID))
        }
        state.providers = [provider]

        // Logical width of iPhone 13 / 13 mini.
        let host = UIHostingController(rootView: ProviderDetailView(providerID: provider.id).environment(state))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 375, height: 812))
        window.rootViewController = host
        window.isHidden = false
        host.view.frame = window.bounds
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        host.view.layoutIfNeeded()
        await settle(1.5)

        let scroll = try #require(scrollView(in: host.view))
        func isGroupHeader(_ label: String) -> Bool {
            label.range(of: #", \d+ models$"#, options: .regularExpression) != nil
        }
        // Groups start collapsed: scroll to the library and open the group header.
        scroll.setContentOffset(CGPoint(x: 0, y: max(0, scroll.contentSize.height - scroll.bounds.height)), animated: false)
        let waitStart = Date()
        var header = accessibilityElement(where: isGroupHeader, in: host.view)
        while header == nil, Date().timeIntervalSince(waitStart) < 10 {
            host.view.layoutIfNeeded()
            await settle(0.2)
            header = accessibilityElement(where: isGroupHeader, in: host.view)
        }
        let groupHeader = try #require(header, "catalog projection never settled; the library has no group header")
        #expect(groupHeader.accessibilityActivate())
        await settle(0.5)

        // Users scroll deep into the catalog before tapping, far away from the enabled section.
        scroll.setContentOffset(CGPoint(x: 0, y: scroll.contentOffset.y + 30_000), animated: false)
        host.view.layoutIfNeeded()
        await settle(0.5)

        ProviderDetailFrameBox.debugFrameChangeCount = 0
        let probe = MainThreadStallProbe()
        probe.start()
        var tapped = 0
        var misses = 0
        while tapped < Self.taps, misses < 60 {
            let row = accessibilityElement(where: { label in
                guard label.hasPrefix("rapid-model-") else { return false }
                let digits = label.dropFirst("rapid-model-".count).prefix { $0.isNumber }
                guard let index = Int(digits), index >= Self.enabledCount else { return false }
                return !state.providers[0].models.contains { $0.id == modelID(index) }
            }, in: host.view)
            if let row, row.accessibilityActivate() {
                tapped += 1
                await settle(0.3)
            } else {
                misses += 1
                scroll.setContentOffset(
                    CGPoint(x: 0, y: min(scroll.contentOffset.y + 300, max(0, scroll.contentSize.height - scroll.bounds.height))),
                    animated: false
                )
                host.view.layoutIfNeeded()
                await settle(0.05)
            }
        }
        await settle(1.0)
        probe.stop()
        let enabledFrameChanges = ProviderDetailFrameBox.debugFrameChangeCount
        let added = state.providers[0].models.count - Self.enabledCount

        print("""
        [HANG-COST] rapid add deep in library: \(tapped) taps, \(added) added, longest stall \(String(format: "%.0f", probe.maxStall * 1000))ms, \
        >16ms total \(String(format: "%.0f", probe.jankTotal * 1000))ms, enabled section frame changes above viewport: \(enabledFrameChanges)
        """)
        #expect(tapped == Self.taps)
        #expect(added == Self.taps)
        // Before the fix (outer VStack) every insert laid out the off-screen enabled section again: 20 changes; lazy leaves the 1 when it leaves the viewport.
        #expect(enabledFrameChanges <= 2)
    }

    /// Observable box for the navigation stack path: the test pushes and pops from outside.
    @Observable
    final class PushPopPath {
        var path: [Int] = []
}

    @Test("tapping \"+\" after pushing the advanced page and popping back: the fly-in target still uses the real frame of the enabled section")
    func add_after_push_pop_keeps_fly_in_target() async throws {
        // Intent: on push every fragment of the enabled section fires onDisappear; after the pop the frame is unchanged, so
        // onGeometryChange does not call back again. If a fragment were removed on onDisappear, the reference box would be
        // left empty and the fly-in target would degrade to the "start point shifted up by 60" fallback.
        let catalogCount = 8
        let enabledCount = 2
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(json: metadataJSON(catalogCount: catalogCount), metadataETag: "push-pop-etag")
        let catalog = (0..<catalogCount).map { index in
            TestFactories.makeModel(
                id: modelID(index), name: "Rapid Model \(index)",
                capabilities: [.text], priceTier: "",
                promptPrice: 0.0000025, completionPrice: 0.00001
            )
        }
        let provider = TestFactories.makeProvider(
            kind: .openAI, models: Array(catalog.prefix(enabledCount)), catalogModels: catalog
        )
        let state = AppState(seedDemoData: false, sessionUID: "push-pop-\(UUID().uuidString)")
        defer {
            state.flushConversationPersistQueue()
            DatabaseManager.shared.close()
            try? FileManager.default.removeItem(at: AppSessionStore.userDir(for: state.sessionPartitionUID))
        }
        state.providers = [provider]

        let navigation = PushPopPath()
        let root = NavigationStack(path: Bindable(navigation).path) {
            ProviderDetailView(providerID: provider.id)
                .navigationDestination(for: Int.self) { _ in Text(verbatim: "advanced") }
        }
        .environment(state)
        // The window is tall enough for the enabled section and the model library to share the screen, so both adds should fly to the enabled section.
        // A navigation stack push only really transitions when the window is attached to the scene and is key.
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let host = UIHostingController(rootView: root)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 375, height: 1800)
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        host.view.layoutIfNeeded()
        await settle(1.5)

        func isGroupHeader(_ label: String) -> Bool {
            label.range(of: #", \d+ models$"#, options: .regularExpression) != nil
        }
        let waitStart = Date()
        var header = accessibilityElement(where: isGroupHeader, in: host.view)
        while header == nil, Date().timeIntervalSince(waitStart) < 10 {
            host.view.layoutIfNeeded()
            await settle(0.2)
            header = accessibilityElement(where: isGroupHeader, in: host.view)
        }
        let groupHeader = try #require(header, "the catalog projection never settled, so the model library has no group header")
        #expect(groupHeader.accessibilityActivate())
        await settle(0.5)

        func tapNextCatalogRow() async throws -> ProviderDetailFrameBox.DebugAddTarget {
            ProviderDetailFrameBox.debugLastAddTarget = nil
            let row = try #require(accessibilityElement(where: { label in
                guard label.hasPrefix("rapid-model-") else { return false }
                let digits = label.dropFirst("rapid-model-".count).prefix { $0.isNumber }
                guard let index = Int(digits), index >= enabledCount else { return false }
                return !state.providers[0].models.contains { $0.id == modelID(index) }
            }, in: host.view), "no catalog row left to add")
            #expect(row.accessibilityActivate())
            await settle(0.8)
            return try #require(ProviderDetailFrameBox.debugLastAddTarget, "tapping \"+\" did not go through handleCatalogModelAdd")
        }

        let before = try await tapNextCatalogRow()
        try #require(before.usesEnabledTarget, "baseline: an add on the same screen before the push should fly to the enabled section \(before.enabledModelsFrame)")

        let mid = try await tapNextCatalogRow()
        navigation.path.append(1)
        await settle(1.0)
        let pushed = accessibilityElement(where: { $0 == "advanced" }, in: host.view)
        print("[PUSH-POP] mid \(mid.enabledModelsFrame) pushed \(pushed != nil)")
        try #require(pushed != nil, "the advanced page was not pushed")
        navigation.path.removeAll()
        await settle(1.0)
        host.view.layoutIfNeeded()

        // The reference box is read at the moment "+" is pressed, before this enable: it should cover the rows enabled before that.
        let enabledIDs = Set(state.providers[0].models.map(\.id))
        let after = try await tapNextCatalogRow()
        // Every enabled model must have its own row's fragment in the union (missing when a new row was not built or not recorded in the box).
        #expect(enabledIDs.isSubset(of: Set(after.activeFragments.keys)), "missing fragments: \(enabledIDs.subtracting(after.activeFragments.keys).sorted())")
        print("[PUSH-POP] before \(before.enabledModelsFrame) after \(after.enabledModelsFrame)")
        #expect(after.usesEnabledTarget, "after the pop the fly-in target degraded to the shift-up-by-60 fallback: enabled section frame \(after.enabledModelsFrame)")
        // The top edge of the union is the top of the enabled section's group header: it does not move between the two adds (new rows go below the header).
        #expect(abs(after.enabledModelsFrame.minY - before.enabledModelsFrame.minY) <= 1)
    }

    @Observable
    final class EnabledModelsHolder {
        var provider: Provider
        init(provider: Provider) { self.provider = provider }
    }

    private struct EnabledSectionHost: View {
        let holder: EnabledModelsHolder
        let box: ProviderDetailFrameBox
        let lazy: Bool
        let catalog: [AIModel]
        let onReferenceFrame: (CGRect) -> Void

        var body: some View {
            ScrollView {
                if lazy {
                    // Production shape: the enabled section and the model library catalog are emitted as siblings into the single outer lazy stack; a model that gets added moves from the catalog group to the enabled section.
                    LazyVStack(alignment: .leading, spacing: 0) {
                        section
                        ProviderCatalogGroupList(
                            provider: holder.provider,
                            capabilityEvidenceRevision: 0,
                            groups: [ProviderCatalogGroup(
                                id: "vendor-0",
                                title: "Vendor 0",
                                models: catalog.filter { model in !holder.provider.models.contains { $0.id == model.id } }
                            )],
                            searchText: "",
                            expandedGroupIDs: ["vendor-0"],
                            coordinateSpaceName: nil,
                            onToggleGroup: { _ in },
                            onAddModel: { _, _ in }
                        )
                    }
                    .providerPanelGroupSurfaces()
                } else {
                    // The pre-fix shape: the whole section is one view, so its frame is the whole-section frame.
                    VStack(alignment: .leading, spacing: 0) { section }
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("enabled-union")) } action: { onReferenceFrame($0) }
                }
            }
            .coordinateSpace(name: "enabled-union")
        }

        private var section: some View {
            ProviderEnabledModelsSection(
                provider: holder.provider,
                highlightedModelID: holder.provider.models.last?.id,
                coordinateSpaceName: "enabled-union",
                enabledModelsFrameBox: box,
                onSetDefault: { _ in },
                onChat: { _ in },
                onRemove: { _ in }
            )
        }
    }

    @Test("after adding N rows in a row, the height of the enabled-section union equals the pre-fix whole-section height")
    func enabled_union_tracks_added_rows() async throws {
        // Intent: before flying in, "is the enabled section in the viewport" is judged from the union of the fragment frames; if the
        // slot of a new row was not written into the box, or an old row moved down and its old value was not refreshed, the union
        // would stay at its pre-add value, and the panel would still be judged not visible after growing and its bottom edge entering the viewport.
        // The catalog group and the enabled section sit in the same lazy stack: if both ForEach use model.id as identity, the added
        // model collides with the catalog row's identity in the enabled section, the lazy stack reuses the old catalog row view,
        // and the enabled section's new row is never built.
        let catalog = (0..<8).map { index in
            TestFactories.makeModel(id: modelID(index), name: "Rapid Model \(index)", capabilities: [.text], priceTier: "")
        }
        let start = TestFactories.makeProvider(kind: .openAI, models: Array(catalog.prefix(2)), catalogModels: catalog)
        let flatHolder = EnabledModelsHolder(provider: start)
        let referenceHolder = EnabledModelsHolder(provider: start)
        let flatBox = ProviderDetailFrameBox()
        var reference = CGRect.null

        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        func makeWindow<V: View>(_ view: V) -> UIWindow {
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 375, height: 1400)
            window.rootViewController = UIHostingController(rootView: view)
            window.makeKeyAndVisible()
            window.rootViewController?.view.frame = window.bounds
            window.rootViewController?.view.layoutIfNeeded()
            return window
        }
        let flatWindow = makeWindow(EnabledSectionHost(holder: flatHolder, box: flatBox, lazy: true, catalog: catalog, onReferenceFrame: { _ in }))
        let referenceWindow = makeWindow(EnabledSectionHost(
            holder: referenceHolder, box: ProviderDetailFrameBox(), lazy: false, catalog: catalog, onReferenceFrame: { reference = $0 }
        ))
        defer {
            for window in [flatWindow, referenceWindow] {
                window.isHidden = true
                window.rootViewController = nil
            }
        }
        await settle(0.6)
        let tolerance = 1 / flatWindow.screen.scale

        for added in 1...3 {
            let next = catalog[1 + added]
            for holder in [flatHolder, referenceHolder] {
                var provider = holder.provider
                provider.models.append(next)
                withAnimation(.snappy) { holder.provider = provider }
            }
            await settle(0.8)
            print("[ENABLED-UNION] +\(added) union \(flatBox.frame) reference \(reference)")
            #expect(
                abs(flatBox.frame.height - reference.height) <= tolerance,
                "+\(added): union \(flatBox.frame.height) vs whole section \(reference.height)"
            )
            #expect(abs(flatBox.frame.minY - reference.minY) <= tolerance, "+\(added): union top")
        }
    }
}
