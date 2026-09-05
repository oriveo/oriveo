import Testing
@testable import Oriveo

@Suite("AppState Launch Policy")
struct AppStateLaunchPolicyTests {
    @Test("Test Runtime Disables Provider Price Migration")
    func testRuntimeDisablesProviderPriceMigration() {
        #expect(
            AppStateLaunchPolicy.shouldRunProviderPriceMigration(
                seedDemoData: false,
                isRunningTests: true,
                providers: [SampleData.makeProvider(kind: .openRouter, apiKey: "sk-or-demo-9012")]
            ) == false
        )
    }

    @Test("Demo Seed Disables Provider Price Migration")
    func demoSeedDisablesProviderPriceMigration() {
        #expect(
            AppStateLaunchPolicy.shouldRunProviderPriceMigration(
                seedDemoData: true,
                isRunningTests: false,
                providers: [SampleData.makeProvider(kind: .openRouter, apiKey: "sk-or-demo-9012")]
            ) == false
        )
    }

    @Test("Production Only Migrates Legacy Open Router Pricing")
    func productionOnlyMigratesLegacyOpenRouterPricing() {
        var pricedOpenRouter = SampleData.makeProvider(kind: .openRouter, apiKey: "sk-or-demo-9012")
        pricedOpenRouter.models = pricedOpenRouter.models.map { model in
            var updated = model
            updated.promptPrice = 0.000003
            return updated
        }

        #expect(
            AppStateLaunchPolicy.shouldRunProviderPriceMigration(
                seedDemoData: false,
                isRunningTests: false,
                providers: [pricedOpenRouter]
            ) == false
        )

        #expect(
            AppStateLaunchPolicy.shouldRunProviderPriceMigration(
                seedDemoData: false,
                isRunningTests: false,
                providers: [SampleData.makeProvider(kind: .openRouter, apiKey: "sk-or-demo-9012")]
            ) == true
        )
    }
}
