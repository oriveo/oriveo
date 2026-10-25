import QuartzCore
import SwiftUI
import Testing
import UIKit
@testable import Oriveo

/// Main-thread cost of a search that fully expands the model library of an aggregator provider (a regression: pasting a term that matches many models
/// and dismissing the keyboard with Return got the app killed by the watchdog after >= 2s, with a stack of only LazySubviewPlacements -> sizeThatFits and no app frames).
///
/// It takes the production path: the real `ProviderDetailView` is mounted in a window and a whole text is inserted into the model library search field at once (= paste),
/// then it waits for the catalog projection to settle (any search text expands every group), and resizes the window height 844 -> 500 -> 844 to simulate the keyboard coming and going.
/// The keyboard changes the viewport height, so the outer lazy container has to place its subviews again; if the rows of an expanded group sit inside "non-lazy card -> inner lazy stack",
/// every placement of the outer one asks every expanded card for the ideal height of the whole group, which amounts to measuring all the hundreds of matching rows.
///
/// Waiting always uses `await Task.sleep` (same as `ProviderCatalogRapidAddHangTests`): when the run loop is spun synchronously `.task` cannot be scheduled.
///
/// The simulator cannot reproduce the iOS 26 race in the lazy allocation of nested lazy stacks (the permanent hang confirmed by Apple DTS only shows on real devices), so the wall-clock gate here
/// only guards against cost regressions such as "measure every row of an expanded group". There are two regression gates: the number of distinct catalog rows whose body is evaluated while the keyboard comes and goes is <= 40
/// (`visibleRowCeiling`), plus the structure gate of `ProviderLazyNestingStructureTests` (only one level of LazyVStack on the same scroll axis).
@MainActor
@Suite("Cost of a model library search that fully expands", .serialized, .sharedProcessState)
struct ProviderCatalogSearchExpandHangTests {
    private static let enabledCount = 10
    /// Ceiling for the longest single main-thread stall: neither the keyboard coming and going nor the paste settling may exceed about three frames.
    private static let stallCeiling: CFTimeInterval = 0.05
    /// How many times each tier is measured within one case, taking the median of each segment: a single sample at the same revision swings about +/-20% with runner load.
    private static let sampleCount = 3
    /// The noise margin of the "no worse than before the fix" gate: the scaled pre-fix median x 1.25, which covers the +/-20% single-segment swing under the same machine state and still catches regressions beyond the noise.
    private static let nestedNoiseFactor = 1.25
    /// The reference workload time taken at the moment the pre-fix baseline was captured (median of [HangReferenceWorkload]), taken in the same process at the same time as the pre-fix medians in the Tier.
    /// The machine's baseline drifts as a whole from day to day (an A/B on the same machine on different days: the revision that fixed the thresholds measured 43.4-50.1 ms one day and the current revision 34.0-43.7 ms,
    /// and an absolute snapshot taken earlier would read red or borderline against both), so the pre-fix medians are scaled by "reference now / baseline reference" before comparing.
    static let referenceBaseline: CFTimeInterval = 0.06105
    /// A 390x844 screen shows about 14 catalog rows, plus the lazy stack's prefetch buffer.
    private static let visibleRowCeiling = 40

    private func modelID(_ index: Int) -> String { "search-model-\(index)" }

    private func metadataJSON(catalogCount: Int) -> String {
        var resolveEntries: [String] = []
        var modelEntries: [String] = []
        for index in 0..<catalogCount {
            let id = modelID(index)
            resolveEntries.append("\"\(id)\":\"\(id)\"")
            modelEntries.append("""
            "\(id)": {"canonicalModelId": "\(id)", "transport": "openai_chat",
              "capabilities": ["text", "web", "vision_input", "tool_call", "file"],
              "contextLength": 128000, "maxOutputTokens": 16384,
              "pricing": {"promptPerToken": 0.0000025, "completionPerToken": 0.00001}, "pricingUnit": "per_token"}
            """)
        }
        return """
        {"version": 1, "providers": {"openRouter": {"resolveMap": {\(resolveEntries.joined(separator: ","))},
          "models": {\(modelEntries.joined(separator: ","))}}}}
        """
    }

    /// 9 in every 10 names contain "Model" (90% match), the rest are called "Other"; the id does not take part in matching (it does not contain the query).
    private func makeCatalog(catalogCount: Int, groupCount: Int) -> [AIModel] {
        (0..<catalogCount).map { index in
            let hits = index % 10 != 9
            return TestFactories.makeModel(
                id: hits ? modelID(index) : "search-other-\(index)",
                name: hits ? "Paste Model \(index) Long Enough Display Name" : "Paste Other \(index) Long Display Name",
                capabilities: [.text, .web, .image, .toolCall, .file, .reasoning],
                priceTier: "",
                groupKey: "vendor-\(index % groupCount)",
                groupName: "Vendor \(index % groupCount)",
                promptPrice: 0.0000025,
                completionPrice: 0.00001
            )
        }
    }

    private func settle(_ seconds: TimeInterval) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private func firstView<T: UIView>(of type: T.Type, in view: UIView) -> T? {
        if let hit = view as? T { return hit }
        for sub in view.subviews { if let hit = firstView(of: type, in: sub) { return hit } }
        return nil
    }

    private func accessibilityNodes(where match: (String) -> Bool, in root: NSObject) -> [NSObject] {
        var visited = Set<ObjectIdentifier>()
        var hits: [NSObject] = []
        func search(_ node: NSObject) {
            guard visited.insert(ObjectIdentifier(node)).inserted else { return }
            if node.isAccessibilityElement, let label = node.accessibilityLabel, match(label) { hits.append(node) }
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
            children.forEach(search)
        }
        search(root)
        return hits
    }

    private func resize(_ window: UIWindow, host: UIViewController, height: CGFloat) {
        window.frame = CGRect(x: 0, y: 0, width: 390, height: height)
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
    }

    /// Structural counts: the catalog rows built during this round.
    /// - distinct: the number of distinct matching models whose capability projection was built (once per row body) - close to the viewport row count when laziness holds, close to the total match count when it collapses;
    /// - bodies: the total number of catalog row body evaluations;
    /// - materialized: the number of matching-row accessibility elements that actually exist in the host hierarchy right now.
    struct BuildCount {
        let distinct: Int
        let bodies: Int
        let materialized: Int
        var text: String { "distinct \(distinct) / body \(bodies) / in tree \(materialized)" }
    }

    struct Sample {
        let pasteStall: CFTimeInterval
        let dismissStall: CFTimeInterval
        /// First reveal: the synchronous layout in which the window height first returns to 844 after the paste has fully expanded the groups (at height 500), including the first build of the newly revealed rows.
        let firstReveal: CFTimeInterval
        let jank: CFTimeInterval
        var maxStall: CFTimeInterval { max(pasteStall, dismissStall) }
        let hits: Int
        let afterPaste: BuildCount
        let afterDismiss: BuildCount
    }

    private func buildCount(hitIDs: [String], root: UIView) -> BuildCount {
        BuildCount(
            distinct: hitIDs.filter {
                ModelCapabilityEvidencePresentation.constructionCountForTesting(providerKind: .openRouter, modelID: $0) > 0
            }.count,
            bodies: ProviderCatalogModelRow.debugBodyEvaluationCount,
            materialized: accessibilityNodes(where: { $0.hasPrefix("search-model-") }, in: root).count
        )
    }

    private func resetBuildCounters() {
        ModelCapabilityEvidencePresentation.resetConstructionCountsForTesting()
        ProviderCatalogModelRow.debugBodyEvaluationCount = 0
    }

    /// Two catalog sizes: matches from 639 to 1791, and the product's layout segments do not grow with the match count.
    struct Tier: Sendable, CustomTestStringConvertible {
        let catalogCount: Int
        let groupCount: Int
        /// Pre-fix baseline of the same shape: the pre-fix code measured with this file's method, the median of each segment over 6 samples per tier (see the comment of the comparison case for the samples).
        let nestedPasteMedian: CFTimeInterval
        let nestedDismissMedian: CFTimeInterval
        let nestedDismissDistinct: Int
        var testDescription: String { "\(catalogCount) catalog / \(groupCount) groups" }
    }

    static let tiers = [
        Tier(catalogCount: 720, groupCount: 12, nestedPasteMedian: 0.0375, nestedDismissMedian: 0.0210, nestedDismissDistinct: 639),
        Tier(catalogCount: 2000, groupCount: 20, nestedPasteMedian: 0.0385, nestedDismissMedian: 0.0330, nestedDismissDistinct: 1791),
    ]

    @Test("OpenRouter search that fully expands: paste a term matching 90%, keyboard up and down", arguments: tiers)
    func search_paste_expands_all_groups_without_hang(tier: Tier) async throws {
        let median = try await runMedianScenario(tier: tier)
        #expect(median.pasteStall <= Self.stallCeiling)
        #expect(median.dismissStall <= Self.stallCeiling)
        #expect(median.firstReveal <= Self.stallCeiling)
    }

    /// Compared with the pre-fix code of the same shape (the expanded groups nested inside "non-lazy card -> inner lazy stack"): the same flow (wait for the projection to land, pin the pre-built state, then dismiss the keyboard),
    /// the paste segment and the dismiss segment compared separately. The pre-fix baseline was produced by taking this file's method to the pre-fix code (in a working tree, not on a branch), 6 samples per tier
    /// (3 each from two cases), taking the median of each segment, taken in the same process at the same time as the reference workload (reference 60.69 / 61.41 ms -> baseline reference 61.05 ms):
    /// - 720 / 12 groups: paste 41 33 40 36 39 36 -> median 37.5; dismiss 20 22 15 23 20 25 -> median 21.0
    /// - 2000 / 20 groups: paste 38 39 41 33 38 40 -> median 38.5; dismiss 40 28 28 39 38 27 -> median 33.0
    /// (Baselines such as 42.0 / 25.0 taken before pinning the pre-built state were captured under bimodality and have been replaced; under the same conditions the current code dismisses in 8-20 ms on the 720 tier
    /// and 14-21 ms on the 2000 tier, unimodal.)
    /// Each segment is measured `sampleCount` times and the median taken, with two ceilings: <= 50ms, and <= the pre-fix median of the same segment x the factor (reference now / baseline reference) x `nestedNoiseFactor`;
    /// the number of built rows (the maximum over runs) must be <= the pre-fix one and <= the viewport row ceiling (locks laziness).
    /// The noise margin is a uniform 1.25 for every segment and is not tuned per segment; against the current baseline all four relative gates are within 50 ms (46.9 / 26.3 /
    /// 48.1 / 41.3 ms x factor), and all of them bind.
    @Test("OpenRouter search that fully expands: no segment is worse than the pre-fix nested lazy stack", arguments: tiers)
    func search_expand_layout_not_worse_than_nested(tier: Tier) async throws {
        // The reference workload runs in the same process and the same exclusive phase as the measured segment: measure once before and once after the segment and take the smaller (an occasional spike only tightens the gate, never loosens it),
        // and a factor outside [0.7, 1.5] means the machine state is abnormal (thermal throttling / the simulator runtime changed and the baseline reference has to be retaken), so no conclusion is drawn from it.
        let referenceBefore = try await HangReferenceWorkload.measure()
        let median = try await runMedianScenario(tier: tier)
        let referenceAfter = try await HangReferenceWorkload.measure()
        let reference = min(referenceBefore, referenceAfter)
        let gate = CalibratedNestedGate(
            reference: reference, referenceBaseline: Self.referenceBaseline, noise: Self.nestedNoiseFactor
        )
        #expect(
            CalibratedNestedGate.plausibleFactor.contains(gate.factor),
            "reference workload factor \(gate.factor) is outside \(CalibratedNestedGate.plausibleFactor): before \(referenceBefore * 1000)ms / after \(referenceAfter * 1000)ms"
        )
        func ms(_ value: CFTimeInterval) -> String { String(format: "%.2f", value * 1000) }
        print(
            "[HANG-COST] \(tier.testDescription) load calibration: reference \(ms(reference))ms / baseline reference \(ms(Self.referenceBaseline))ms"
                + " = factor \(String(format: "%.3f", gate.factor)); raw paste segment \(ms(median.pasteStall))ms"
                + " vs ceiling \(ms(gate.ceiling(nested: tier.nestedPasteMedian)))ms; raw dismiss segment \(ms(median.dismissStall))ms"
                + " vs ceiling \(ms(gate.ceiling(nested: tier.nestedDismissMedian)))ms; raw first reveal \(ms(median.firstReveal))ms vs cap \(ms(Self.stallCeiling))ms"
        )
        #expect(median.pasteStall <= Self.stallCeiling)
        #expect(gate.passes(measured: median.pasteStall, nested: tier.nestedPasteMedian))
        #expect(median.dismissStall <= Self.stallCeiling)
        #expect(gate.passes(measured: median.dismissStall, nested: tier.nestedDismissMedian))
        #expect(median.firstReveal <= Self.stallCeiling)
        #expect(median.maxDismissDistinct <= tier.nestedDismissDistinct)
        #expect(median.maxDismissDistinct <= Self.visibleRowCeiling)
    }

    /// Measure `sampleCount` times in a row within one case: each of the two segments takes the median; the built-row count takes the maximum over runs (laziness gates do not let an occasional collapse through on the median).
    struct MedianSample {
        let pasteStall: CFTimeInterval
        let dismissStall: CFTimeInterval
        let firstReveal: CFTimeInterval
        let maxDismissDistinct: Int
    }

    private func runMedianScenario(tier: Tier) async throws -> MedianSample {
        var samples: [Sample] = []
        for _ in 0..<Self.sampleCount {
            samples.append(try await runScenario(catalogCount: tier.catalogCount, groupCount: tier.groupCount))
        }
        func median(_ values: [CFTimeInterval]) -> CFTimeInterval { values.sorted()[values.count / 2] }
        let result = MedianSample(
            pasteStall: median(samples.map(\.pasteStall)),
            dismissStall: median(samples.map(\.dismissStall)),
            firstReveal: median(samples.map(\.firstReveal)),
            maxDismissDistinct: samples.map(\.afterDismiss.distinct).max() ?? 0
        )
        print("""
        [HANG-COST] \(tier.testDescription) median of \(Self.sampleCount): \
        paste segment \(String(format: "%.1f", result.pasteStall * 1000))ms, \
        dismiss segment \(String(format: "%.1f", result.dismissStall * 1000))ms, \
        first reveal \(String(format: "%.1f", result.firstReveal * 1000))ms, most rows built after dismissing \(result.maxDismissDistinct)
        """)
        return result
    }

    /// Home "Add model" inline catalog: the only lazy layer on the page is the top-level LazyVStack, and the catalog group list emits group headers and rows as siblings.
    /// After a search that fully expands, only the rows near the viewport should be built (about 14 rows per 390x844 screen), and on collapse it would be the total match count (639).
    @Test("home inline catalog, 720 catalog / 12 groups: after a search that fully expands, only the rows near the viewport are still built")
    func inline_catalog_search_expand_stays_lazy() async throws {
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(
            json: metadataJSON(catalogCount: 720), metadataETag: "search-expand-inline-etag"
        )
        let catalog = makeCatalog(catalogCount: 720, groupCount: 12)
        let provider = TestFactories.makeProvider(
            kind: .openRouter, models: Array(catalog.prefix(Self.enabledCount)), catalogModels: catalog
        )
        let state = AppState(seedDemoData: false, sessionUID: "search-expand-inline-\(UUID().uuidString)")
        defer {
            state.flushConversationPersistQueue()
            DatabaseManager.shared.close()
            try? FileManager.default.removeItem(at: AppSessionStore.userDir(for: state.sessionPartitionUID))
        }
        state.providers = [provider]

        let host = UIHostingController(rootView: InlineModelCatalogView(providerID: provider.id).environment(state))
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        host.view.layoutIfNeeded()

        var field: UITextField?
        let waitStart = Date()
        while field == nil, Date().timeIntervalSince(waitStart) < 10 {
            await settle(0.2)
            host.view.layoutIfNeeded()
            field = firstView(of: UITextField.self, in: host.view)
        }
        let searchField = try #require(field, "the inline catalog search field did not appear (the catalog projection never settled)")

        ProviderCatalogModelRow.debugBodyEvaluationCount = 0
        _ = searchField.becomeFirstResponder()
        searchField.insertText("model")
        searchField.sendActions(for: .editingChanged)
        _ = searchField.resignFirstResponder()
        await settle(1.5)
        host.view.layoutIfNeeded()
        await settle(0.5)

        let rowBodies = ProviderCatalogModelRow.debugBodyEvaluationCount
        let materialized = accessibilityNodes(where: { $0.hasPrefix("search-model-") }, in: host.view).count
        print("[HANG-COST] home inline catalog fully expanded by search: catalog row body evaluations \(rowBodies), matching rows in the tree \(materialized)")
        #expect(searchField.text == "model")
        #expect(materialized > 0)
        #expect(rowBodies <= Self.visibleRowCeiling)
        await MetadataClient.shared.resetForTesting()
    }

    private func runScenario(catalogCount: Int, groupCount: Int) async throws -> Sample {
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(
            json: metadataJSON(catalogCount: catalogCount), metadataETag: "search-expand-etag-\(catalogCount)"
        )
        let catalog = makeCatalog(catalogCount: catalogCount, groupCount: groupCount)
        let hitIDs = catalog.dropFirst(Self.enabledCount).map(\.id).filter { $0.hasPrefix("search-model-") }
        let provider = TestFactories.makeProvider(
            kind: .openRouter, models: Array(catalog.prefix(Self.enabledCount)), catalogModels: catalog
        )
        let state = AppState(seedDemoData: false, sessionUID: "search-expand-\(UUID().uuidString)")
        defer {
            state.flushConversationPersistQueue()
            DatabaseManager.shared.close()
            try? FileManager.default.removeItem(at: AppSessionStore.userDir(for: state.sessionPartitionUID))
        }
        state.providers = [provider]

        let host = UIHostingController(rootView: ProviderDetailView(providerID: provider.id).environment(state))
        // Mount into the host's window scene: in a detached window SwiftUI does not build the UIKit text field and the search field cannot be tapped into.
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        host.view.layoutIfNeeded()
        await settle(1.5)

        // Scroll screen by screen from the top until the model library search field enters the viewport (the outer layer is lazy, and a search field outside the viewport is not in the view tree).
        let scroll = try #require(firstView(of: UIScrollView.self, in: host.view))
        var field: UITextField?
        var offset: CGFloat = 0
        while field == nil, offset <= scroll.contentSize.height {
            scroll.setContentOffset(CGPoint(x: 0, y: offset), animated: false)
            host.view.layoutIfNeeded()
            await settle(0.2)
            field = firstView(of: UITextField.self, in: host.view)
            offset += 300
        }
        let searchField = try #require(field, "the model library search field did not appear")

        // Warm up the keyboard: the cold start of the keyboard on the first becomeFirstResponder is a one-off system cost (74-129 ms synchronously) that does not belong to the product layout.
        _ = searchField.becomeFirstResponder()
        resize(window, host: host, height: 500)
        await settle(0.5)
        _ = searchField.resignFirstResponder()
        resize(window, host: host, height: 844)
        await settle(1.0)

        resetBuildCounters()
        let probe = MainThreadStallProbe()
        probe.start()
        // Tap into the search field: the keyboard comes up and the viewport gets shorter.
        _ = searchField.becomeFirstResponder()
        resize(window, host: host, height: 500)
        await settle(0.3)
        // Paste: insert the whole text at once, which triggers the projection only once.
        searchField.insertText("model")
        searchField.sendActions(for: .editingChanged)
        // 150 ms debounce + projection + expanding every group.
        await settle(1.5)
        probe.stop()
        let pasteStall = probe.maxStall
        var jank = probe.jankTotal
        // Counting structure walks the accessibility tree (30-50 ms), so it sits outside the timing window with one settle round before the next segment so that it does not merge into the runloop turn of the resize.
        let afterPaste = buildCount(hitIDs: hitIDs, root: host.view)
        resetBuildCounters()
        await settle(0.3)
        // Pin the pre-built state of the lazy stack: the rows the keyboard dismissal will reveal are built outside the timing window first (stretch the viewport to 844 and back to 500). Without pinning,
        // whether these rows were built by idle prefetch depends on timing, and the same code takes 18-27 ms in one round and 29-41 ms in another for the dismiss segment (a bimodal distribution measured);
        // after pinning, what is measured is "rows that are already built being placed again in a taller viewport", and the pre-fix baseline was taken under the same condition. The cost of building rows for the first time is measured by the paste segment.
        // The pre-build happens after resetBuildCounters: the built-row count after dismissing includes this pre-build (the rows an 844 viewport has to build are the same ones the dismissal reveals), so the laziness gate still works.
        // This pre-build is also the "first reveal" sub-measurement: after the paste has fully expanded, the window returns to 844 for the first time in this host, and the newly revealed rows are built for the first time in this synchronous layout.
        // With the pre-built state pinned, the dismiss segment only measures re-placement, and "building rows gets slower only when dismissing" is guarded by this segment: a 50 ms absolute ceiling + the built-row laziness gate (the count after dismissing includes this pre-build).
        // There is no relative "no worse than before the fix" gate: the pre-fix nested lazy stack already built all matching rows on paste (639 / 1791 rows built after dismissing), so first reveal has no rows left to build,
        // and under the same conditions in the same process the pre-fix code measured 27-30 ms on the 720 tier and 6-8 ms on the 2000 tier, while the current code measured 26-45 ms on the 720 tier (depending on whether idle prefetch had built them on both tiers) and 38-44 ms on the 2000 tier
        //(exclusive, reference factor 0.99-1.00). The pre-fix reading does not measure the same thing, and using it as a baseline gate would stay red forever; a baseline taken from the current code x 1.25
        // is already looser than 50 ms, so the absolute ceiling is what always binds.
        let revealStart = CACurrentMediaTime()
        resize(window, host: host, height: 844)
        let firstReveal = CACurrentMediaTime() - revealStart
        await settle(0.3)
        resize(window, host: host, height: 500)
        await settle(0.3)

        probe.start()
        // Return dismisses the keyboard: the viewport is restored.
        _ = searchField.resignFirstResponder()
        resize(window, host: host, height: 844)
        await settle(1.5)
        probe.stop()
        let dismissStall = probe.maxStall
        jank += probe.jankTotal
        let afterDismiss = buildCount(hitIDs: hitIDs, root: host.view)

        print("""
        [HANG-COST] model library search fully expanded: \(catalogCount) catalog / \(groupCount) groups, \(hitIDs.count) matches, \
        paste segment longest stall \(String(format: "%.0f", pasteStall * 1000))ms, \
        dismiss segment longest stall \(String(format: "%.0f", dismissStall * 1000))ms, \
        first reveal \(String(format: "%.0f", firstReveal * 1000))ms, >16ms total \(String(format: "%.0f", jank * 1000))ms
          paste settled (height 500): \(afterPaste.text)
          dismissed back to 844: \(afterDismiss.text)
        """)
        #expect(searchField.text == "model")
        // Projection settled and groups expanded: matching rows are visible in the viewport (proving that what is measured is the fully expanded state, not a spinner or the collapsed state).
        #expect(afterDismiss.materialized > 0)
        await MetadataClient.shared.resetForTesting()
        return Sample(
            pasteStall: pasteStall, dismissStall: dismissStall, firstReveal: firstReveal, jank: jank, hits: hitIDs.count,
            afterPaste: afterPaste, afterDismiss: afterDismiss
        )
    }
}

/// Load calibration of the "no worse than before the fix" gate: the pre-fix median is scaled to the current machine baseline by "reference workload now / baseline reference workload", then multiplied by the noise margin.
/// When the whole machine slows down the reference slows in proportion and the ceiling loosens with it; when the code really gets slower the reference stays put while the measured segment slows, and it still crosses the line.
struct CalibratedNestedGate {
    let reference: CFTimeInterval
    let referenceBaseline: CFTimeInterval
    let noise: Double

    /// The plausible range of the factor: outside it the machine state has changed (or the baseline reference has to be retaken after an SDK / simulator runtime upgrade), and no conclusion is drawn from the scaling.
    static let plausibleFactor: ClosedRange<Double> = 0.7...1.5

    var factor: Double { reference / referenceBaseline }

    func ceiling(nested: CFTimeInterval) -> CFTimeInterval { nested * factor * noise }

    func passes(measured: CFTimeInterval, nested: CFTimeInterval) -> Bool { measured <= ceiling(nested: nested) }
}

/// The reference workload of the machine factor: a fixed non-lazy SwiftUI layout (400 text rows); each time a new host is mounted in a window and the synchronous time of the first `layoutIfNeeded`
/// (whole-tree measurement + layout) is measured, taking the median of 7 after 2 warm-ups. A new host each time avoids the measurement cache in the view graph - reusing one host and changing only the width by 1pt
/// measured two levels of 2.8 / 9.3 ms in the same process, which made the factor unusable. Like the measured segment it is main-thread SwiftUI layout,
/// scales with the machine baseline, has fixed content, touches no product code, and slows down only when the machine does.
@MainActor
enum HangReferenceWorkload {
    private struct ReferenceTree: View {
        var body: some View {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(0..<400, id: \.self) { index in
                    HStack {
                        Text("Reference row \(index) with a fixed label").font(.body)
                        Spacer()
                        Text("\(index * 7 % 101)").font(.caption).monospacedDigit()
                    }
                }
            }
            .padding(.horizontal, 16)
        }
    }

    static func measure() async throws -> CFTimeInterval {
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        var samples: [CFTimeInterval] = []
        for round in 0..<9 {
            let host = UIHostingController(rootView: ReferenceTree())
            let start = CACurrentMediaTime()
            window.rootViewController = host
            host.view.frame = window.bounds
            host.view.layoutIfNeeded()
            let elapsed = CACurrentMediaTime() - start
            if round >= 2 { samples.append(elapsed) }
            window.rootViewController = nil
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return samples.sorted()[samples.count / 2]
    }
}
