import Testing
@testable import Oriveo

@Suite("Welcome flow")
@MainActor
struct WelcomeFlowTests {
    @Test("Welcome Start Still Marks Completion")
    func welcomeStartStillMarksCompletion() {
        let appState = AppState(seedDemoData: true)
        appState.hasCompletedOnboarding = false

        appState.startOnboarding()

        #expect(appState.hasCompletedOnboarding == true)
    }
}
