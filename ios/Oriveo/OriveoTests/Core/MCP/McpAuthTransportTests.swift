import Foundation
import Testing
@testable import Oriveo

// MARK: - Production OAuth transport
//
// These tests exercise `URLSessionMcpAuthTransport` itself: it sends the requests, and the assertions are about
// what the replay layer actually received. The authorizer logic tests use a fake transport
// (`McpAuthorizerTests`), which cannot prove the redirect and https constraints.

private typealias Scripted = McpScriptedURLProtocol

private let tokenEndpoint = URL(string: "https://auth.example.com/token")!
private let registrationEndpoint = URL(string: "https://auth.example.com/register")!
private let metadataEndpoint = URL(string: "https://auth.example.com/.well-known/oauth-authorization-server")!

private func makeTransport(timeout: TimeInterval = 10) -> URLSessionMcpAuthTransport {
    URLSessionMcpAuthTransport(session: Scripted.session(), timeout: timeout)
}

private let secretForm = [
    McpFormField("grant_type", "authorization_code"),
    McpFormField("code", "ac_secret_code"),
    McpFormField("code_verifier", "verifier_secret"),
]

private func okJSON(_ text: String = #"{"ok":true}"#) -> Scripted.Stub {
    Scripted.Stub(status: 200, headers: ["Content-Type": "application/json"], body: Data(text.utf8), rewriteID: false)
}

@Suite("MCP OAuth production transport", .serialized)
struct McpAuthTransportTests {

    @Test("The token endpoint never follows redirects, not even same-origin ones, so the authorization code and verifier are never carried elsewhere",
          arguments: ["https://auth.example.com/token2", "https://evil.example/token"])
    func tokenEndpointNeverFollowsRedirects(target: String) async throws {
        Scripted.reset()
        Scripted.enqueue([McpClientHarness.redirect(to: target), okJSON()])
        await #expect(throws: McpHTTPError.redirectRejected) {
            _ = try await makeTransport().postForm(tokenEndpoint, form: secretForm)
        }
        let requests = Scripted.requests()
        #expect(requests.count == 1)
        #expect(requests.first?.request.url == tokenEndpoint)
        #expect(requests.first?.bodyText?.contains("ac_secret_code") == true)
    }

    @Test("The registration endpoint never follows redirects",
          arguments: ["https://auth.example.com/register2", "https://evil.example/register"])
    func registrationEndpointNeverFollowsRedirects(target: String) async throws {
        Scripted.reset()
        Scripted.enqueue([McpClientHarness.redirect(to: target), okJSON()])
        await #expect(throws: McpHTTPError.redirectRejected) {
            _ = try await makeTransport().postJSON(registrationEndpoint, body: McpClientMetadata.registrationBody(scope: nil))
        }
        #expect(Scripted.requests().count == 1)
    }

    @Test("Metadata GET: a same-origin https redirect may be followed")
    func metadataFollowsSameOriginRedirect() async throws {
        Scripted.reset()
        Scripted.enqueue([
            McpClientHarness.redirect(to: "https://auth.example.com/metadata.json"),
            okJSON(#"{"issuer":"https://auth.example.com"}"#),
        ])
        let response = try await makeTransport().get(metadataEndpoint)
        #expect(response.status == 200)
        #expect(String(decoding: response.body, as: UTF8.self).contains("https://auth.example.com"))
        #expect(Scripted.requests().map { $0.request.url?.path } == [
            "/.well-known/oauth-authorization-server", "/metadata.json",
        ])
    }

    @Test("Metadata GET: a cross-origin redirect or a downgrade to http is rejected and the second URL receives no request",
          arguments: ["https://evil.example/metadata.json", "http://auth.example.com/metadata.json"])
    func metadataRejectsCrossOriginRedirect(target: String) async throws {
        Scripted.reset()
        Scripted.enqueue([McpClientHarness.redirect(to: target), okJSON(#"{"issuer":"https://evil.example"}"#)])
        await #expect(throws: McpHTTPError.redirectRejected) {
            _ = try await makeTransport().get(metadataEndpoint)
        }
        #expect(Scripted.requests().count == 1)
    }

    @Test("Non-https OAuth endpoints are always refused and no request is sent")
    func nonHTTPSEndpointsSendNothing() async throws {
        Scripted.reset()
        Scripted.setFallback(okJSON())
        let transport = makeTransport()
        let insecure = URL(string: "http://auth.example.com/token")!

        await #expect(throws: McpHTTPError.insecureURL) { _ = try await transport.get(insecure) }
        await #expect(throws: McpHTTPError.insecureURL) { _ = try await transport.postForm(insecure, form: secretForm) }
        await #expect(throws: McpHTTPError.insecureURL) {
            _ = try await transport.postJSON(insecure, body: .object(JSONObject()))
        }
        #expect(Scripted.requests().isEmpty)
    }

    @Test("A response body over 1 MB aborts the request")
    func oversizedResponseIsRejected() async throws {
        Scripted.reset()
        let huge = Data(repeating: 0x20, count: McpHTTPLimits.maxAuthResponseBytes + 1)
        Scripted.enqueue(Scripted.Stub(status: 200, headers: ["Content-Type": "application/json"], body: huge, rewriteID: false))
        await #expect(throws: McpHTTPError.bodyTooLarge) { _ = try await makeTransport().get(metadataEndpoint) }
    }

    @Test("Overall deadline: when the peer never answers, report a timeout at the deadline and close the connection")
    func deadlineApplies() async throws {
        Scripted.reset()
        var slow = okJSON()
        slow.delay = 5
        Scripted.enqueue(slow)
        await #expect(throws: McpHTTPError.timedOut) { _ = try await makeTransport(timeout: 0.3).get(metadataEndpoint) }
        let aborted = await McpClientHarness.eventually { !Scripted.abortedRequests().isEmpty }
        #expect(aborted)
    }

    @Test("Form encoding: everything outside the RFC 3986 unreserved set is percent-encoded; response header names are lowercased")
    func formEncodingAndHeaderNormalization() async throws {
        Scripted.reset()
        Scripted.enqueue(Scripted.Stub(
            status: 200,
            headers: ["Content-Type": "application/json", "WWW-Authenticate": "Bearer"],
            body: Data("{}".utf8),
            rewriteID: false
        ))
        let form = [McpFormField("resource", "https://mcp.example.com/mcp?a=b&c"), McpFormField("scope", "files:read files:write")]
        let response = try await makeTransport().postForm(tokenEndpoint, form: form)
        #expect(response.headers["www-authenticate"] == "Bearer")
        #expect(response.contentType == "application/json")

        let sent = try #require(Scripted.requests().first)
        #expect(sent.bodyText == "resource=https%3A%2F%2Fmcp.example.com%2Fmcp%3Fa%3Db%26c&scope=files%3Aread%20files%3Awrite")
        #expect(sent.header("Content-Type") == "application/x-www-form-urlencoded")
    }
}
