import Foundation
import Network
import Testing
@testable import Oriveo

@Suite("Local network permission errors")
struct LocalNetworkPermissionErrorTests {
    @Test("local network privacy denial is not reported as a stopped engine")
    func classifiesLocalNetworkPrivacyDenial() {
        let underlying = NSError(
            domain: "kCFErrorDomainCFNetwork",
            code: -1009,
            userInfo: ["_NSURLErrorNWPathKey": "unsatisfied (Local network prohibited)"]
        )
        let error = NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorNotConnectedToInternet,
            userInfo: [NSUnderlyingErrorKey: underlying]
        )

        #expect(LocalEngineConnector.classifyNetworkError(error) == .localNetworkDenied)
    }

    @Test("ordinary offline state remains an engine availability error")
    func keepsOrdinaryOfflineClassification() {
        #expect(LocalEngineConnector.classifyNetworkError(URLError(.notConnectedToInternet)) == .engineStopped)
    }

    @Test("Bonjour permission and network failures remain distinct")
    func distinguishesDiscoveryPermissionFromUnavailableNetwork() {
        #expect(LocalEngineDiscoverySession.discoveryState(for: .posix(.EPERM)) == .permissionDenied)
        #expect(LocalEngineDiscoverySession.discoveryState(for: .posix(.ENETDOWN)) == .unavailable)
    }
}
