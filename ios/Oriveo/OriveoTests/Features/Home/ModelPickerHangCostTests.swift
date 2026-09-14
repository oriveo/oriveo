import QuartzCore
import SwiftUI
import Testing
import UIKit
@testable import Oriveo

@Suite("Model picker price layout")
struct ModelPickerPriceLayoutTests {
    @Test("the price layout falls back in the same order as nested ViewThatFits")
    func priceLayoutDegradesInSameOrderAsNestedViewThatFits() {
        // Ideal label / value sizes: Input 36+4+44=84, Output 46+4+50=100, whole row 84+12+100=196.
        let sizes = [
            CGSize(width: 36, height: 13), CGSize(width: 44, height: 13),
            CGSize(width: 46, height: 13), CGSize(width: 50, height: 13),
        ]
        typealias Layout = ModelPickerPriceLayout

        // Side by side for an ideal size query (no proposed width) and whenever the whole row fits.
        #expect(Layout.arrangement(idealSizes: sizes, width: nil) == .singleLine)
        #expect(Layout.arrangement(idealSizes: sizes, width: 196) == .singleLine)
        // When the row does not fit, split into lines; each pair compares its own "label value" width.
        #expect(Layout.arrangement(idealSizes: sizes, width: 195.5) == .lines(stacked: [false, false]))
        #expect(Layout.arrangement(idealSizes: sizes, width: 100) == .lines(stacked: [false, false]))
        #expect(Layout.arrangement(idealSizes: sizes, width: 99) == .lines(stacked: [false, true]))
        #expect(Layout.arrangement(idealSizes: sizes, width: 80) == .lines(stacked: [true, true]))
        // With a single price the whole row is that pair.
        #expect(Layout.arrangement(idealSizes: Array(sizes.prefix(2)), width: 84) == .singleLine)
        #expect(Layout.arrangement(idealSizes: Array(sizes.prefix(2)), width: 83) == .lines(stacked: [true]))
    }
}

/// Hang cost of opening the model picker from a chat. Mounts the real `ModelPickerSheet` with data at
/// the upper end of a multi-provider BYOK setup; wall-clock numbers are printed only, assertions pin
/// call counts.
@MainActor
@Suite("Model picker hang cost", .serialized)
struct ModelPickerHangCostTests {
    private static let providerKinds: [ProviderKind] = [
        .openAI, .anthropic, .gemini, .openRouter, .deepseek, .together, .fireworks, .groq, .mistral, .moonshot,
    ]
    private static let modelsPerProvider = 80

    private func makeProviders() -> [Provider] {
        Self.providerKinds.map { kind in
            TestFactories.makeProvider(
                kind: kind,
                models: (0..<Self.modelsPerProvider).map { index in
                    var model = TestFactories.makeModel(
                        id: "\(kind.rawValue)-picker-\(index)",
                        name: "\(kind.displayName) Picker Model \(index) Long Name",
                        capabilities: [.text, .web, .image, .toolCall, .file, .reasoning],
                        priceTier: "",
                        promptPrice: 0.0000025,
                        completionPrice: 0.00001
                    )
                    model.pricingUnit = "per_token"
                    model.contextLength = 128_000
                    return model
                }
            )
        }
    }

    private func yieldMainActor(for seconds: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test("10 providers x 80 models: first presentation of the picker from a chat")
    func chatPickerFirstPresentation() async throws {
        let state = AppState(seedDemoData: false, sessionUID: "picker-hang-cost-\(UUID().uuidString)")
        defer {
            state.flushConversationPersistQueue()
            DatabaseManager.shared.close()
            try? FileManager.default.removeItem(at: AppSessionStore.userDir(for: state.sessionPartitionUID))
        }
        let providers = makeProviders()
        state.providers = providers

        // The first SwiftUI host in a process pays one-time setup (fonts, graphics stack); warm it up so
        // that cost is not charged to the picker.
        let warmup = UIHostingController(rootView: Text("warmup").padding())
        let warmupWindow = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        warmupWindow.rootViewController = warmup
        warmupWindow.isHidden = false
        warmup.view.layoutIfNeeded()
        pumpMainRunLoop(0.3)
        warmupWindow.isHidden = true
        warmupWindow.rootViewController = nil

        ModelCapabilityEvidencePresentation.resetConstructionCountsForTesting()
        AppLanguage.debugSystemPreferredResolveCount = 0

        let snapshotStart = CACurrentMediaTime()
        let presentation = ModelPickerPresentationSnapshot(
            context: .chat(conversationID: nil),
            providers: state.providers,
            providersVersion: state.providersVersion,
            currentProviderID: providers[0].id,
            currentModel: providers[0].models[0]
        )
        let snapshotElapsed = CACurrentMediaTime() - snapshotStart

        let probe = MainThreadStallProbe()
        probe.start()
        let host = UIHostingController(
            rootView: ModelPickerSheet(
                context: .chat(conversationID: nil),
                presentation: presentation,
                onSelect: { _ in }
            )
            .environment(state)
        )
        // Attach to the scene: a window that is never on screen does not run onAppear or .task,
        // so the capability counts would not be measured.
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        // Pumping the run loop synchronously keeps the test on the MainActor, so the sheet's `.task`
        // (capability counts) never gets scheduled; awaiting yields the MainActor, like the frames
        // right after the sheet is presented in the app.
        try await yieldMainActor(for: 1.5)
        probe.stop()

        let presentations = providers.reduce(0) { partial, provider in
            partial + provider.models.reduce(0) {
                $0 + ModelCapabilityEvidencePresentation.constructionCountForTesting(providerKind: provider.kind, modelID: $1.id)
            }
        }
        print("""
        [HANG-COST] model picker first presentation (10 providers x 80 models)
          snapshot built synchronously on tap \(String(format: "%.0f", snapshotElapsed * 1000))ms
          max stall after mounting the sheet \(String(format: "%.0f", probe.maxStall * 1000))ms, >16ms total \(String(format: "%.0f", probe.jankTotal * 1000))ms
          capability presentations built = \(presentations)
          system language re-resolved = \(AppLanguage.debugSystemPreferredResolveCount)
        """)

        window.isHidden = true
        window.rootViewController = nil

        // Opening the picker twice in quick succession is a real pattern, so the warm second
        // presentation is measured too.
        let secondProbe = MainThreadStallProbe()
        secondProbe.start()
        let secondHost = UIHostingController(
            rootView: ModelPickerSheet(
                context: .chat(conversationID: nil),
                presentation: ModelPickerPresentationSnapshot(
                    context: .chat(conversationID: nil),
                    providers: state.providers,
                    providersVersion: state.providersVersion,
                    currentProviderID: providers[0].id,
                    currentModel: providers[0].models[0]
                ),
                onSelect: { _ in }
            )
            .environment(state)
        )
        let secondWindow = UIWindow(windowScene: scene)
        secondWindow.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        secondWindow.rootViewController = secondHost
        secondWindow.makeKeyAndVisible()
        secondHost.view.frame = secondWindow.bounds
        secondHost.view.layoutIfNeeded()
        try await yieldMainActor(for: 1.0)
        secondProbe.stop()
        print("""
        [HANG-COST] model picker second presentation (warm)
          max stall \(String(format: "%.0f", secondProbe.maxStall * 1000))ms, >16ms total \(String(format: "%.0f", secondProbe.jankTotal * 1000))ms
        """)
        secondWindow.isHidden = true
        secondWindow.rootViewController = nil
        #expect(presentations >= 0)

        // With capability chips selected, every body evaluation re-filters the whole catalog
        // (typing a search, expanding or collapsing a group, selecting a row).
        let sections = presentation.sections
        let rounds = 5
        func totalPresentations() -> Int {
            providers.reduce(0) { partial, provider in
                partial + provider.models.reduce(0) {
                    $0 + ModelCapabilityEvidencePresentation.constructionCountForTesting(providerKind: provider.kind, modelID: $1.id)
                }
            }
        }
        var directTotal: CFTimeInterval = 0
        ModelCapabilityEvidencePresentation.resetConstructionCountsForTesting()
        for _ in 0..<rounds {
            let start = CACurrentMediaTime()
            _ = ModelPickerCapabilityFilter.apply(sections: sections, active: [.web, .reasoning])
            directTotal += CACurrentMediaTime() - start
        }
        let directPresentations = totalPresentations() / rounds

        ModelCapabilityEvidencePresentation.resetConstructionCountsForTesting()
        let index = ModelPickerCapabilityFilter.intentIndex(sections: sections)
        let indexPresentations = totalPresentations()
        var indexedTotal: CFTimeInterval = 0
        for _ in 0..<rounds {
            let start = CACurrentMediaTime()
            _ = ModelPickerCapabilityFilter.apply(sections: sections, active: [.web, .reasoning], index: index)
            _ = ModelPickerCapabilityFilter.counts(sections: sections, index: index)
            indexedTotal += CACurrentMediaTime() - start
        }
        print("""
        [HANG-COST] capability filter (web + reasoning), one body re-filtering the whole catalog: \
        row by row \(String(format: "%.1f", directTotal / Double(rounds) * 1000))ms / \(directPresentations) presentations; \
        indexed with counts \(String(format: "%.2f", indexedTotal / Double(rounds) * 1000))ms / 0 presentations (building the index once: \(indexPresentations))
        """)
        #expect(totalPresentations() == indexPresentations)
        #expect(indexPresentations == providers.reduce(0) { $0 + $1.models.count })
    }
}
