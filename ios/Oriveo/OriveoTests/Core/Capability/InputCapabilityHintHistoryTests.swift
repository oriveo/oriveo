import Foundation
import Testing
@testable import Oriveo

@Suite("InputCapabilityHintHistory")
struct InputCapabilityHintHistoryTests {
    private static func fresh() throws -> (InputCapabilityHintHistory, UserDefaults) {
        let defaults = try #require(UserDefaults(suiteName: "input-hint-\(UUID().uuidString)"))
        return (InputCapabilityHintHistory(defaults: defaults), defaults)
    }

    @Test("The same model is hinted only once")
    func sameModelHintsOnce() throws {
        let (history, defaults) = try Self.fresh()
        let provider = UUID()
        #expect(history.consumeFirstHint(providerID: provider, modelID: "m1"))
        #expect(!history.consumeFirstHint(providerID: provider, modelID: "m1"))
        #expect(history.hasShownHint(providerID: provider, modelID: "m1"))
        #expect(defaults.stringArray(forKey: "input_capability_hint_seen.v1")?.count == 1)
    }

    @Test("Different models are hinted once each")
    func differentModelsHintEach() throws {
        let (history, _) = try Self.fresh()
        let provider = UUID()
        #expect(history.consumeFirstHint(providerID: provider, modelID: "m1"))
        #expect(history.consumeFirstHint(providerID: provider, modelID: "m2"))
        #expect(!history.consumeFirstHint(providerID: provider, modelID: "m2"))
        #expect(!history.consumeFirstHint(providerID: provider, modelID: "m1"))
    }

    @Test("Capped at 300 entries, the oldest is evicted beyond that")
    func capacityEvictsOldest() throws {
        let (history, defaults) = try Self.fresh()
        let provider = UUID()
        for index in 0...300 {
            #expect(history.consumeFirstHint(providerID: provider, modelID: "m\(index)"))
        }
        #expect(defaults.stringArray(forKey: InputCapabilityHintHistory.storageKey)?.count == 300)
        #expect(!history.hasShownHint(providerID: provider, modelID: "m0"), "The oldest entry is evicted")
        #expect(history.hasShownHint(providerID: provider, modelID: "m1"))
        #expect(history.hasShownHint(providerID: provider, modelID: "m300"))
    }
}
