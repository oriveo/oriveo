import QuartzCore
import SwiftUI
import Testing
import UIKit
@testable import Oriveo

/// Regression gate: the catalog list must stay lazy.
///
/// Division of labour with `ProviderCatalogListCostMeasurementTests` in the same directory: that one is an **attribution measurement**,
/// printing numbers to stdout for a person to read, with every assertion `>= 0` and no thresholds (wall-clock differs by an order of magnitude between simulator and device);
/// this file only locks **machine-independent structural facts**: the number of rows built in the expanded state must stay close to the number of visible rows, not the whole catalog.
/// With it, turning `ProviderCatalogGroupList`'s `LazyVStack` back into a `VStack` turns this red on the spot.
///
/// It covers the shape the measurement file does not: a relay's catalog comes from the user's own relay and mostly **has no vendor grouping**,
/// so the whole catalog falls into one fallback group - once there is any search text it expands as a whole, and a single `LazyVStack` holds thousands of rows instead of dozens.
/// When the outer `LazyVStack` estimates its content size it asks the inner one for its ideal size, which is the shape most at risk of nested lazy collapse.
@MainActor
@Suite("Provider catalog list laziness regression gate", .serialized)
struct ProviderCatalogLibraryHangTests {
    /// A 390x844 viewport cannot hold 40 rows on one screen; when laziness holds only the rows near the visible window are built.
    private static let visibleRowCeiling = 40

    private func makeUngroupedCatalog(count: Int) -> [AIModel] {
        (0..<count).map { index in
            TestFactories.makeModel(
                id: "relay-model-\(index)",
                name: "Relay Model \(index) Long Enough Display Name",
                capabilities: [.text, .web, .image, .toolCall, .file, .reasoning],
                priceTier: "",
                groupKey: nil,
                groupName: nil,
                promptPrice: 0.0000025,
                completionPrice: 0.00001
            )
        }
    }

    /// Mount the real `ProviderCatalogGroupList` into the ScrollView of an iPhone-sized window,
    /// isomorphic to its hosts in `ProviderDetailView` / `HomeModelPickerSheet`.
    /// A non-empty `searchText` triggers `shouldAutoExpandProviderCatalogGroups`, taking the production expand-all path.
    private func renderExpanded(models: [AIModel]) -> (rowBodies: Int, maxStall: CFTimeInterval) {
        let provider = TestFactories.makeProvider(kind: .relay, models: [])
        let groups = [ProviderCatalogGroup(id: "relay", title: "Relay", models: models)]

        ProviderCatalogModelRow.debugBodyEvaluationCount = 0

        let host = UIHostingController(
            rootView: ScrollView {
                // The host's only lazy layer: the list emits only sibling group headers and rows, isomorphic to the detail page / home.
                LazyVStack(alignment: .leading, spacing: 0) {
                    ProviderCatalogGroupList(
                        provider: provider,
                        capabilityEvidenceRevision: 0,
                        groups: groups,
                        searchText: "model",
                        expandedGroupIDs: [],
                        coordinateSpaceName: nil,
                        onToggleGroup: { _ in },
                        onAddModel: { _, _ in }
                    )
                }
                .providerPanelGroupSurfaces()
            }
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = host
        window.isHidden = false
        host.view.frame = window.bounds

        let probe = MainThreadStallProbe()
        probe.start()
        host.view.layoutIfNeeded()
        pumpMainRunLoop(1.5)
        probe.stop()

        let rowBodies = ProviderCatalogModelRow.debugBodyEvaluationCount
        print("""
        [CATALOG-LAZY] \(models.count) models / 1 fallback group, search triggers expansion
          catalog row body evaluations \(rowBodies) (ceiling \(Self.visibleRowCeiling))
          longest stall \(String(format: "%.0f", probe.maxStall * 1000))ms (printed only, not asserted)
        """)

        window.isHidden = true
        window.rootViewController = nil
        return (rowBodies, probe.maxStall)
    }

    @Test("Relay ungrouped huge single group: after expanding, only the visible rows are still built")
    func ungroupedHugeCatalogStaysLazy() async throws {
        let sample = renderExpanded(models: makeUngroupedCatalog(count: 3000))
        #expect(sample.rowBodies < Self.visibleRowCeiling)
    }
}
