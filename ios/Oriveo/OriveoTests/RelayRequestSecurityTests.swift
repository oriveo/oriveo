import Foundation
import Testing
@testable import Oriveo

private actor AddressSequence {
    private var values: [Set<String>]

    init(_ values: [Set<String>]) {
        self.values = values
    }

    func next() -> Set<String> {
        values.removeFirst()
    }
}

@Suite("Relay request security", .serialized)
struct RelayRequestSecurityTests {
    @Test("remote HTTPS redirects stay on the exact origin for every supported status")
    func remoteRedirectMatrix() throws {
        let original = try #require(URL(string: "https://relay.example.com:8443/v1/chat"))

        for status in [301, 302, 307, 308] {
            let response = try #require(HTTPURLResponse(
                url: original,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            ))
            let sameOrigin = URLRequest(url: URL(string: "https://relay.example.com:8443/v2/chat")!)
            #expect(RelayRequestSecurity.validatedHTTPSRedirect(
                originalURL: original, response: response, request: sameOrigin
            ) != nil)

            var crossOrigin = URLRequest(url: URL(string: "https://capture.example.net/steal")!)
            crossOrigin.httpMethod = "POST"
            crossOrigin.httpBody = Data("private prompt".utf8)
            crossOrigin.setValue("Bearer private-key", forHTTPHeaderField: "Authorization")
            #expect(RelayRequestSecurity.validatedHTTPSRedirect(
                originalURL: original, response: response, request: crossOrigin
            ) == nil)

            let downgraded = URLRequest(url: URL(string: "http://relay.example.com:8443/steal")!)
            #expect(RelayRequestSecurity.validatedHTTPSRedirect(
                originalURL: original, response: response, request: downgraded
            ) == nil)
        }
    }

    @Test("local cleartext preparation rejects DNS rebinding before transport")
    func rejectsDNSRebinding() async throws {
        var request = URLRequest(url: URL(string: "http://engine.lan:11434/api/ps")!)
        request.applyRelaySecurityMode(RelayRequestedConfig(
            transport: .openaiChatCompletions,
            authMode: .none,
            securityMode: .localHTTP
        ))
        let sequence = AddressSequence([
            ["192.168.1.20"],
            ["192.168.1.21"],
        ])

        do {
            _ = try await RelayRequestSecurity.prepare(request) { _ in
                await sequence.next()
            }
            Issue.record("DNS rebinding must be rejected")
        } catch ProviderServiceError.invalidConfiguration(let detail) {
            #expect(detail == "dns_rebinding")
        }
    }

    @Test("local cleartext preparation rejects a private-to-public DNS classification change")
    func rejectsDNSClassificationChange() async throws {
        var request = URLRequest(url: URL(string: "http://engine.lan:11434/api/ps")!)
        request.applyRelaySecurityMode(RelayRequestedConfig(
            transport: .openaiChatCompletions,
            authMode: .none,
            securityMode: .localHTTP
        ))
        let sequence = AddressSequence([
            ["192.168.1.20"],
            ["203.0.113.9"],
        ])

        do {
            _ = try await RelayRequestSecurity.prepare(request) { _ in
                await sequence.next()
            }
            Issue.record("A public re-resolution must be rejected before transport")
        } catch ProviderServiceError.invalidConfiguration(let detail) {
            #expect(detail == "public_address")
        }
    }

    @Test("shared production transport is cookie, credential, and cache free")
    func sharedTransportIsEphemeral() {
        let configuration = RelayRequestSecurity.transportSession(for: .shared).configuration
        #expect(configuration.httpShouldSetCookies == false)
        #expect(configuration.httpCookieStorage == nil)
        #expect(configuration.urlCredentialStorage == nil)
        #expect(configuration.urlCache == nil)
        #expect(configuration.requestCachePolicy == .reloadIgnoringLocalCacheData)
    }

}
