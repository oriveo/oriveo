import QuartzCore
import SwiftUI
import Testing
import UIKit
@testable import Oriveo

/// Main-thread stall probe: a 5ms timer cannot fire while the main thread is busy, so the gap
/// between two ticks minus the interval is how long the main thread was blocked. This is the same
/// signal an app-hang watchdog looks at.
@MainActor
final class MainThreadStallProbe {
    private let interval: CFTimeInterval = 0.005
    private var timer: Timer?
    private var lastTick: CFTimeInterval = 0
    private(set) var maxStall: CFTimeInterval = 0
    /// Sum of stalls longer than one frame (16ms), roughly the hitching a user can feel.
    private(set) var jankTotal: CFTimeInterval = 0

    func start() {
        lastTick = CACurrentMediaTime()
        maxStall = 0
        jankTotal = 0
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        tick()
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        let now = CACurrentMediaTime()
        let stall = max(0, now - lastTick - interval)
        maxStall = max(maxStall, stall)
        if stall > 0.016 { jankTotal += stall }
        lastTick = now
    }
}

@MainActor
func pumpMainRunLoop(_ seconds: TimeInterval) {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
}

/// Hang cost on the production path: mounts the real `ProviderDetailView` in an iPhone 12 sized
/// window with user-scale data and measures main-thread stalls and hot-path call counts on first
/// appearance and across repeated providers writes.
///
/// Wall-clock numbers are printed, not asserted (simulator and device differ by an order of
/// magnitude); assertions only pin machine-independent call counts. Before the fix, 150 enabled rows
/// took over a second to appear on a simulator, and every providers write recomputed every row.
@MainActor
@Suite("Provider detail hang cost", .serialized)
struct ProviderDetailHangCostTests {
    private static let catalogCount = 777
    private static let groupCount = 20

    private func modelID(_ index: Int) -> String { "hang-model-\(index)" }

    private func metadataJSON(providerKey: String) -> String {
        var resolveEntries: [String] = []
        var modelEntries: [String] = []
        for index in 0..<Self.catalogCount {
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
          "providers": {"\(providerKey)": {
            "resolveMap": {\(resolveEntries.joined(separator: ","))},
            "models": {\(modelEntries.joined(separator: ","))}
          }}
        }
        """
    }

    private func makeCatalog(grouped: Bool) -> [AIModel] {
        (0..<Self.catalogCount).map { index in
            TestFactories.makeModel(
                id: modelID(index),
                name: "Hang Model \(index) Long Enough Display Name",
                capabilities: [.text, .web, .image, .toolCall, .file, .reasoning],
                priceTier: "",
                groupKey: grouped ? "group-\(index % Self.groupCount)" : nil,
                groupName: grouped ? "Vendor \(index % Self.groupCount)" : nil,
                promptPrice: 0.0000025,
                completionPrice: 0.00001
            )
        }
    }

    struct Sample {
        let appearMaxStall: CFTimeInterval
        let appearJank: CFTimeInterval
        let invalidationMaxStall: CFTimeInterval
        let invalidationJank: CFTimeInterval
        let appearRowBodies: Int
        let invalidationRowBodies: Int
        let presentations: Int
        let systemLanguageResolves: Int
        let appearLogoInferences: Int
        let invalidationLogoInferences: Int
    }

    private func totalPresentations(_ models: [AIModel], kind: ProviderKind) -> Int {
        models.reduce(0) {
            $0 + ModelCapabilityEvidencePresentation.constructionCountForTesting(providerKind: kind, modelID: $1.id)
        }
    }

    /// Mount, let the first screen and the catalog projection settle, then write providers five times
    /// in a row (balance refresh, catalog sync and re-validation all take this path).
    private func runScenario(
        label: String,
        provider: Provider,
        catalog: [AIModel]
    ) async -> Sample {
        let state = AppState(seedDemoData: false, sessionUID: "hang-cost-\(UUID().uuidString)")
        defer {
            state.flushConversationPersistQueue()
            DatabaseManager.shared.close()
            try? FileManager.default.removeItem(at: AppSessionStore.userDir(for: state.sessionPartitionUID))
        }
        state.providers = [provider]

        ModelCapabilityEvidencePresentation.resetConstructionCountsForTesting()
        AppLanguage.debugSystemPreferredResolveCount = 0
        ProviderEnabledModelRow.debugBodyEvaluationCount = 0

        let host = UIHostingController(rootView: ProviderDetailView(providerID: provider.id).environment(state))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = host
        window.isHidden = false
        host.view.frame = window.bounds

        let probe = MainThreadStallProbe()
        probe.start()
        host.view.layoutIfNeeded()
        pumpMainRunLoop(1.5)
        probe.stop()
        let appearMaxStall = probe.maxStall
        let appearJank = probe.jankTotal
        let appearRowBodies = ProviderEnabledModelRow.debugBodyEvaluationCount
        let appearLogoInferences = ProviderLogoResolver.computationCountForTesting(providerID: provider.id)

        probe.start()
        for _ in 0..<5 {
            state.providers = state.providers
            pumpMainRunLoop(0.3)
        }
        probe.stop()
        let invalidationRowBodies = ProviderEnabledModelRow.debugBodyEvaluationCount - appearRowBodies

        let sample = Sample(
            appearMaxStall: appearMaxStall,
            appearJank: appearJank,
            invalidationMaxStall: probe.maxStall,
            invalidationJank: probe.jankTotal,
            appearRowBodies: appearRowBodies,
            invalidationRowBodies: invalidationRowBodies,
            presentations: totalPresentations(catalog, kind: provider.kind),
            systemLanguageResolves: AppLanguage.debugSystemPreferredResolveCount,
            appearLogoInferences: appearLogoInferences,
            invalidationLogoInferences: ProviderLogoResolver.computationCountForTesting(providerID: provider.id) - appearLogoInferences
        )
        print("""
        [HANG-COST] \(label)
          first appearance: max stall \(String(format: "%.0f", appearMaxStall * 1000))ms, >16ms total \(String(format: "%.0f", appearJank * 1000))ms, enabled row bodies \(appearRowBodies) (of \(provider.models.count) rows)
          5 providers writes: max stall \(String(format: "%.0f", sample.invalidationMaxStall * 1000))ms, >16ms total \(String(format: "%.0f", sample.invalidationJank * 1000))ms, row bodies \(invalidationRowBodies)
          capability presentations built = \(sample.presentations)
          system language re-resolved = \(sample.systemLanguageResolves)
          relay logo inferences: first appearance \(sample.appearLogoInferences), writes \(sample.invalidationLogoInferences)
        """)

        window.isHidden = true
        window.rootViewController = nil
        return sample
    }

    @Test("official provider: 777-model catalog with 150 enabled models")
    func officialProviderWithLargeEnabledList() async throws {
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(json: metadataJSON(providerKey: "openAI"), metadataETag: "hang-etag")
        let catalog = makeCatalog(grouped: true)
        let provider = TestFactories.makeProvider(kind: .openAI, models: Array(catalog.prefix(150)))

        let sample = await runScenario(label: "OpenAI 777 catalog / 150 enabled", provider: provider, catalog: catalog)
        // The first screen builds only the few visible rows (lazy), and a write that changes nothing
        // recomputes no row at all.
        #expect(sample.appearRowBodies < 40)
        #expect(sample.invalidationRowBodies == 0)
        #expect(sample.systemLanguageResolves <= 1)
        await MetadataClient.shared.resetForTesting()
    }

    @Test("official provider: 777-model catalog with 30 enabled models")
    func officialProviderWithTypicalEnabledList() async throws {
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(json: metadataJSON(providerKey: "openAI"), metadataETag: "hang-etag")
        let catalog = makeCatalog(grouped: true)
        let provider = TestFactories.makeProvider(kind: .openAI, models: Array(catalog.prefix(30)))

        let sample = await runScenario(label: "OpenAI 777 catalog / 30 enabled", provider: provider, catalog: catalog)
        #expect(sample.invalidationRowBodies == 0)
        await MetadataClient.shared.resetForTesting()
    }

    @Test("relay: 777-model ungrouped catalog with 150 enabled models")
    func relayWithLargeCatalog() async throws {
        await MetadataClient.shared.resetForTesting()
        let catalog = makeCatalog(grouped: false)
        let provider = TestFactories.makeProvider(
            kind: .relay,
            models: Array(catalog.prefix(150)),
            catalogModels: catalog,
            baseURLText: "https://relay.example.com/v1"
        )

        let sample = await runScenario(label: "Relay 777 catalog / 150 enabled", provider: provider, catalog: catalog)
        #expect(sample.appearRowBodies < 40)
        #expect(sample.invalidationRowBodies == 0)
        // The hero card reads the logo a dozen times per body: with unchanged inputs it is inferred
        // once for the first screen and never again across writes.
        #expect(sample.appearLogoInferences == 1)
        #expect(sample.invalidationLogoInferences == 0)
    }
}
