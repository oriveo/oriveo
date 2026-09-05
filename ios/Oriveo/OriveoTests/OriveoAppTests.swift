import Testing
@testable import Oriveo

@Suite("OriveoApp")
struct OriveoAppTests {
    @Test("Test Runtime Launch Configuration Disables External Startup Dependencies")
    func testRuntimeLaunchConfigurationDisablesExternalStartupDependencies() {
        let configuration = AppLaunchConfiguration(isRunningTests: true)

        #expect(configuration.shouldSeedDemoData == true)
    }

    @Test("Production Launch Configuration Does Not Seed Demo Data")
    func productionLaunchConfigurationDoesNotSeedDemoData() {
        let configuration = AppLaunchConfiguration(isRunningTests: false)

        #expect(configuration.shouldSeedDemoData == false)
    }
}
