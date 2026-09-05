import Foundation
import Testing
@testable import Oriveo

@Suite("ModelPickerGroupExpansionStore", .serialized)
struct ModelPickerGroupExpansionStoreTests {
    @Test("Defaults To Empty")
    func defaultsToEmpty() {
        let providerID = UUID()
        defer { ModelPickerGroupExpansionStore.save([], for: providerID) }

        #expect(ModelPickerGroupExpansionStore.load(for: providerID).isEmpty)
    }

    @Test("Round Trips Per Provider")
    func roundTripsPerProvider() {
        let providerA = UUID()
        let providerB = UUID()
        defer {
            ModelPickerGroupExpansionStore.save([], for: providerA)
            ModelPickerGroupExpansionStore.save([], for: providerB)
        }

        ModelPickerGroupExpansionStore.save(["openai", "anthropic"], for: providerA)

        #expect(ModelPickerGroupExpansionStore.load(for: providerA) == ["openai", "anthropic"])
        #expect(ModelPickerGroupExpansionStore.load(for: providerB).isEmpty)
    }
}
