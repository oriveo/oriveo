import Testing
@testable import Oriveo

@Suite("ServiceReachabilityMonitor")
@MainActor
struct ServiceReachabilityMonitorTests {
    @Test("System Offline Still Shows Global Banner")
    func systemOfflineStillShowsGlobalBanner() {
        let monitor = ServiceReachabilityMonitor.makeForTesting()

        monitor.applyPathSatisfiedForTesting(false)

        #expect(monitor.state == .noNetwork)
        #expect(monitor.bannerState == .noNetwork)
    }
}
