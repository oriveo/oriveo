import QuartzCore
import Testing
@testable import Oriveo

/// Cost of reading generation parameter settings. The chat screen resolves them on every body
/// evaluation (every keystroke in the composer), a resolve reads three layers, and each layer decoded
/// the whole record table from UserDefaults. Wall-clock numbers are printed only.
@Suite("Generation parameter settings read cost", .serialized)
struct GenerationParameterSettingsReadCostTests {
    @Test("60 model defaults: the read cost of one resolve, and rewrites from another instance are visible immediately")
    func resolveCost() {
        let suiteName = "generation-parameter-read-cost-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = GenerationParameterSettingsStore(defaults: defaults)
        let provider = UUID()
        for index in 0..<60 {
            store.setModelDefaults(
                .init(values: [
                    "temperature": .init(state: .value, value: .number(0.4)),
                    "top_p": .init(state: .value, value: .number(0.9)),
                    "max_tokens": .init(state: .value, value: .number(4096)),
                    "reasoning_effort": .init(state: .value, value: .string("high")),
                ]),
                providerID: provider,
                modelID: "model-\(index)"
            )
        }
        let conversation = UUID()
        _ = store.resolve(transient: nil, providerID: provider, modelID: "model-7", conversationID: conversation)
        let rounds = 100
        let start = CACurrentMediaTime()
        for _ in 0..<rounds {
            _ = store.resolve(transient: nil, providerID: provider, modelID: "model-7", conversationID: conversation)
        }
        let elapsed = (CACurrentMediaTime() - start) / Double(rounds)
        print("[HANG-COST] generation parameter settings, 60 records: one resolve \(String(format: "%.2f", elapsed * 1000))ms")
        #expect(store.resolve(transient: nil, providerID: provider, modelID: "model-7", conversationID: conversation)?.values["top_p"]?.value == .number(0.9))

        // The decode cache compares stored bytes: after another instance on the same defaults rewrites
        // the table, the new value is read immediately, and so is clearing it.
        let otherWriter = GenerationParameterSettingsStore(defaults: defaults)
        otherWriter.setModelDefaults(
            .init(values: ["top_p": .init(state: .value, value: .number(0.5))]),
            providerID: provider,
            modelID: "model-7"
        )
        #expect(store.resolve(transient: nil, providerID: provider, modelID: "model-7", conversationID: conversation)?.values["top_p"]?.value == .number(0.5))
        otherWriter.setModelDefaults(nil, providerID: provider, modelID: "model-7")
        #expect(store.resolve(transient: nil, providerID: provider, modelID: "model-7", conversationID: conversation) == nil)
    }
}
