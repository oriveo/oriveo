import Foundation
import Testing
@testable import Oriveo

private let physicalLANFixtureURL: URL? = {
    let environment = ProcessInfo.processInfo.environment
    let environmentValue = environment["ORIVEO_PHYSICAL_LAN_URL"]
        ?? environment["TEST_RUNNER_ORIVEO_PHYSICAL_LAN_URL"]
    let bundleValue = Bundle.main.object(forInfoDictionaryKey: "ORIVEO_PHYSICAL_LAN_URL") as? String
    guard let rawValue = environmentValue ?? bundleValue else { return nil }
    return URL(string: rawValue.trimmingCharacters(in: .whitespacesAndNewlines))
}()

@Suite("Physical LAN local HTTP")
struct PhysicalLANLocalHTTPTests {
    @Test(
        "physical device reaches an RFC1918 engine without credentials",
        .enabled(if: physicalLANFixtureURL != nil)
    )
    func reachesRFC1918EngineWithoutCredentials() async throws {
        let fixtureBaseURL = try #require(physicalLANFixtureURL)
        let configuredBaseURL = try RelayEndpointPolicy.requireConfigured(
            fixtureBaseURL.absoluteString,
            securityMode: .localHTTP,
            credentials: RelayEndpointPolicy.Credentials(authMode: .none, hasKey: false)
        )
        let baseURL = try #require(URL(string: configuredBaseURL))
        let modelsURL = try #require(URL(string: "/v1/models", relativeTo: baseURL)?.absoluteURL)

        var request = URLRequest(url: modelsURL)
        request.timeoutInterval = 10
        let (data, response) = try await URLSession.shared.data(for: request)
        let httpResponse = try #require(response as? HTTPURLResponse)

        #expect(httpResponse.statusCode == 200)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.value(forHTTPHeaderField: "API-Key") == nil)
        #expect(request.value(forHTTPHeaderField: "x-api-key") == nil)
        #expect(modelsURL.query == nil)

        let body = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let models = body?["data"] as? [[String: Any]]
        #expect(models?.isEmpty == false)
    }
}
