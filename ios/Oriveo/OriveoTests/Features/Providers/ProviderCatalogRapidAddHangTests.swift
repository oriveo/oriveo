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
@Suite("Rapid add in the model library", .serialized)
struct ProviderCatalogRapidAddHangTests {
    private static let catalogCount = 777
    private static let enabledCount = 150
    private static let taps = 14

    private func modelID(_ index: Int) -> String { "rapid-model-\(index)" }

    private func metadataJSON() -> String {
        var resolveEntries: [String] = []
        var modelEntries: [String] = []
        for index in 0..<Self.catalogCount {
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
        defer { Task { await MetadataClient.shared.resetForTesting() } }
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
}
