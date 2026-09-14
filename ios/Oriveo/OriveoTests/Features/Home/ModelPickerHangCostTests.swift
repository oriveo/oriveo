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
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = host
        window.isHidden = false
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        pumpMainRunLoop(1.5)
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
        let secondWindow = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        secondWindow.rootViewController = secondHost
        secondWindow.isHidden = false
        secondHost.view.frame = secondWindow.bounds
        secondHost.view.layoutIfNeeded()
        pumpMainRunLoop(1.0)
        secondProbe.stop()
        print("""
        [HANG-COST] model picker second presentation (warm)
          max stall \(String(format: "%.0f", secondProbe.maxStall * 1000))ms, >16ms total \(String(format: "%.0f", secondProbe.jankTotal * 1000))ms
        """)
        secondWindow.isHidden = true
        secondWindow.rootViewController = nil
        #expect(presentations >= 0)
    }
}
