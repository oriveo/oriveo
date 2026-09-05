import Foundation
import Testing
@testable import Oriveo

@Suite("Provider routing")
@MainActor
struct ProviderRoutingTests {
    @Test("Provider Routes Push Expected Destinations")
    func providerRoutesPushExpectedDestinations() {
        let appState = AppState(seedDemoData: true)
        let providerID = UUID()

        appState.openProviderSetup(from: .providers)
        appState.openProviderDetail(providerID: providerID)
        appState.openManualModelEntry(providerID: providerID, context: .providerDetail)

        #expect(appState.navigation.path[0] == .providerSetup(entryPoint: .providers))
        #expect(appState.navigation.path[1] == .providerDetail(providerID: providerID))
        #expect(appState.navigation.path[2] == .manualModelEntry(providerID: providerID, context: .providerDetail))
    }

    @Test("Relay Setup Without Catalog Routes To Manual Model Entry")
    func relaySetupWithoutCatalogRoutesToManualModelEntry() {
        let providerID = UUID()
        let provider = TestFactories.makeProvider(
            id: providerID,
            kind: .relay,
            models: [],
            catalogModels: []
        )

        #expect(
            relaySetupCompletionRoute(for: provider) ==
                .manualModelEntry(providerID: providerID, context: .providers)
        )
    }

    @Test("Relay Setup With Catalog Routes To Provider Detail")
    func relaySetupWithCatalogRoutesToProviderDetail() {
        let providerID = UUID()
        let provider = TestFactories.makeProvider(
            id: providerID,
            kind: .relay,
            models: [TestFactories.makeModel(id: "gpt-4o", isDefault: true)],
            catalogModels: [TestFactories.makeModel(id: "gpt-4o", isDefault: true)]
        )

        #expect(relaySetupCompletionRoute(for: provider) == .providerDetail(providerID: providerID))
    }
}
