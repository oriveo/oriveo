import Testing
@testable import Oriveo

@Suite("AppRootView")
struct AppRootViewTests {
    @Test("Background Services Stay Disabled While Running Tests")
    func backgroundServicesStayDisabledWhileRunningTests() {
        #expect(
            AppRootBackgroundServicePolicy.shouldStart(
                hasStartedBackgroundServices: false,
                isRunningTests: true,
                isRunningPreviews: false
            ) == false
        )
    }

    @Test("Background Services Stay Disabled While Running Previews")
    func backgroundServicesStayDisabledWhileRunningPreviews() {
        #expect(
            AppRootBackgroundServicePolicy.shouldStart(
                hasStartedBackgroundServices: false,
                isRunningTests: false,
                isRunningPreviews: true
            ) == false
        )
    }

    @Test("Background Services Start Once On First Launch")
    func backgroundServicesStartOnceOnFirstLaunch() {
        #expect(
            AppRootBackgroundServicePolicy.shouldStart(
                hasStartedBackgroundServices: false,
                isRunningTests: false,
                isRunningPreviews: false
            ) == true
        )
    }

    @Test("Background Services Do Not Restart After First Launch")
    func backgroundServicesDoNotRestartAfterFirstLaunch() {
        #expect(
            AppRootBackgroundServicePolicy.shouldStart(
                hasStartedBackgroundServices: true,
                isRunningTests: false,
                isRunningPreviews: false
            ) == false
        )
    }
}
