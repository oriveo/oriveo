import Foundation
import Testing
@testable import Oriveo

// MARK: - Failures while adding a server (the failure pages, plus limit reached / not saved / cancelled)
//
// Every failure outcome is driven end to end through the production `McpAddServerModel`, then asserted on:
// where the page lands, and no new record in the store or the credential store.

@Suite("MCP add flow: a failed outcome never leaves half a server behind", .serialized)
@MainActor
struct McpAddServerFailureTests {
    private func run(
        stubs: [McpScriptedURLProtocol.Stub],
        transport: FakeMcpAuthTransport = FakeMcpAuthTransport(),
        browser: FakeMcpBrowserSession = FakeMcpBrowserSession(),
        runtimeConfig: McpRuntimeConfig = .fallback,
        prepare: (McpUiRig) throws -> Void = { _ in },
        drive: (McpAddServerModel) async -> Void,
        verify: (McpAddServerModel, McpUiRig) async throws -> Void
    ) async throws {
        McpScriptedURLProtocol.reset()
        McpScriptedURLProtocol.enqueue(stubs)
        let rig = try McpUiRig(transport: transport, browser: browser, runtimeConfig: runtimeConfig)
        defer { rig.cleanUp() }
        try prepare(rig)
        let model = rig.addModel()
        await drive(model)
        await model.waitUntilSettled()
        try await verify(model, rig)
    }

    /// Runs the browser sign-in to the end (accepting the pre-sign-in notice).
    private func connectApproving(_ model: McpAddServerModel) async {
        model.setURL(McpUiFixture.endpoint)
        model.connect()
        _ = await McpUiWait.until {
            if case .progress(.authPrompt, _, _) = model.state.screen { return true }
            return !model.isRunning
        }
        model.approveSignIn()
    }

    @Test("Malformed address: stays on the form, error under the field, primary button disabled; no request is sent")
    func invalidAddressStaysOnForm() async throws {
        for raw in ["linear.app/mcp", "http://mcp.example.com/mcp", "ftp://mcp.example.com"] {
            try await run(stubs: []) { model in
                model.setURL(raw)
                model.connect()
            } verify: { model, rig in
                #expect(model.state.screen == .form && model.state.urlError == .malformed, "\(raw)")
                #expect(!model.state.canConnect, "Connect is disabled while the error shows")
                #expect(McpAddServerContent.urlErrorText(.malformed).contains("https://"))
                #expect(McpScriptedURLProtocol.requests().isEmpty, "an invalid address sends no request")
                try rig.expectNothingLeft("malformed address \(raw)")

                // Editing the address clears the error and re-enables the button.
                model.setURL(McpUiFixture.endpoint)
                #expect(model.state.urlError == nil && model.state.canConnect)
            }
        }
    }

    @Test("Address with a username and password: also stays on the form, and the hint says to use an access token instead")
    func userinfoAddressIsRejected() async throws {
        try await run(stubs: []) { model in
            model.setURL("https://alice:s3cret@mcp.example.com/mcp")
            model.connect()
        } verify: { model, rig in
            #expect(model.state.screen == .form && model.state.urlError == .hasUserinfo)
            #expect(
                McpAddServerContent.urlErrorText(.hasUserinfo)
                    == L10n.tr("The address can't include a username or password. Use an access token instead.", table: .mcp)
            )
            #expect(McpScriptedURLProtocol.requests().isEmpty)
            try rig.expectNothingLeft("address with a userinfo component")
        }
    }

    @Test("Unreachable: the failure page offers Retry / Edit address; Retry reconnects with the same input; Edit address returns to the form with its content intact")
    func unreachable() async throws {
        let down = McpScriptedURLProtocol.Stub(errorCode: .cannotConnectToHost)
        try await run(stubs: [down, down]) { model in
            model.setURL(McpUiFixture.endpoint)
            model.setName("Home NAS")
            model.connect()
        } verify: { model, rig in
            #expect(model.state.screen == .failure(.unreachable))
            try rig.expectNothingLeft("unreachable")
        }

        try await run(stubs: [down, down]) { model in
            model.setURL(McpUiFixture.endpoint)
            model.setName("Home NAS")
            model.connect()
            await model.waitUntilSettled()
            model.retry()
        } verify: { model, rig in
            #expect(model.state.screen == .failure(.unreachable), "a retry runs again with the same input")
            model.editAddress()
            #expect(model.state.screen == .form && model.state.url == McpUiFixture.endpoint && model.state.name == "Home NAS")
            try rig.expectNothingLeft("still unreachable after retry")
        }
    }

    @Test("Not an MCP server: all four fixture responses land on the same page, which only offers Edit address")
    func notMcp() async throws {
        for item in try McpClientFixture.notMcpCases() {
            try await run(stubs: [item.stub, item.stub]) { model in
                model.setURL(McpUiFixture.endpoint)
                model.connect()
            } verify: { model, rig in
                #expect(model.state.screen == .failure(.notMcp), "\(item.id)")
                try rig.expectNothingLeft("not MCP: \(item.id)")
            }
        }
    }

    @Test("Access token required: paste the token in place and connect; the token only goes to the credential store and never into the server record")
    func needsTokenThenPasteToken() async throws {
        // The authorization server supports neither CIMD nor DCR, so the client cannot register automatically.
        try await run(stubs: [
            try McpUiFixture.unauthorized(),
            try McpUiFixture.unauthorized(), try McpUiFixture.toolsList(), try McpUiFixture.toolsList(),
        ]) { model in
            model.setURL(McpUiFixture.endpoint)
            model.connect()
            await model.waitUntilSettled()
            #expect(model.state.screen == .failure(.needsToken))
            model.setToken("  pat_live_123  ")
            model.connectWithToken()
        } verify: { model, rig in
            guard case .review(let review) = model.state.screen else {
                Issue.record("expected the review-permissions page after pasting the token, got \(model.state.screen)")
                return
            }
            #expect(McpScriptedURLProtocol.requests().last?.header("Authorization") == "Bearer pat_live_123")
            try rig.expectNothingLeft("before tapping Done")
            model.finishReview()
            await model.waitUntilSettled()
            #expect(rig.credentials.load(serverId: review.serverId, uid: McpUiFixture.uid)?.pastedToken == "pat_live_123")
            let saved = try #require(try rig.store.fetchServer(id: review.serverId))
            #expect(saved.authKind == .token)
            #expect(!String(describing: saved).contains("pat_live_123"), "the record carries no credential")
        }
    }

    @Test("Pasted token rejected by the server: stays on the page with a field error; no record and no credential is left")
    func tokenRejectedOnNeedsTokenPage() async throws {
        try await run(stubs: [
            try McpUiFixture.unauthorized(), try McpUiFixture.unauthorized(), try McpUiFixture.unauthorized(),
        ]) { model in
            model.setURL(McpUiFixture.endpoint)
            model.connect()
            await model.waitUntilSettled()
            model.setToken("pat_wrong")
            model.connectWithToken()
        } verify: { model, rig in
            #expect(model.state.screen == .failure(.needsToken) && model.state.tokenRejected)
            try rig.expectNothingLeft("token rejected")
            model.setToken("pat_other")
            #expect(!model.state.tokenRejected, "editing the token clears the error")
        }
    }

    @Test("The form has only address and name; connecting again after editing the address from the token-required page still auto-detects and does not carry the previous token")
    func formHasNoSignInMethodChoice() async throws {
        try await run(stubs: [try McpUiFixture.unauthorized(), try McpUiFixture.unauthorized()]) { model in
            model.setURL(McpUiFixture.endpoint)
            model.connect()
            await model.waitUntilSettled()
            #expect(model.state.screen == .failure(.needsToken))
            model.setToken("pat_live_123")
            model.editAddress()
            model.connect()
        } verify: { model, rig in
            #expect(model.state.screen == .failure(.needsToken) && model.state.authKind == .auto)
            #expect(McpScriptedURLProtocol.requests().allSatisfy { $0.header("Authorization") == nil }, "auto-detection sends no token")
            try rig.expectNothingLeft("access token required")
        }
    }

    @Test("Sign-in not completed: user closes the sign-in page / provider denies / callback state mismatch all leave no record and no credential; Sign in again restarts the flow")
    func authCancelled() async throws {
        // The user closes the sign-in page (the browser session throws).
        let closed = FakeMcpAuthTransport()
        try McpUiFixture.stubAuthorization(closed)
        try await run(stubs: [try McpUiFixture.unauthorized()], transport: closed, browser: FakeMcpBrowserSession()) { model in
            await connectApproving(model)
        } verify: { model, rig in
            #expect(model.state.screen == .failure(.authCancelled))
            try rig.expectNothingLeft("sign-in page closed")
        }

        // The provider denies the request (the callback carries an error).
        let denied = FakeMcpAuthTransport()
        try McpUiFixture.stubAuthorization(denied)
        let denyingBrowser = FakeMcpBrowserSession()
        denyingBrowser.callbackBuilder = { url in
            let state = McpOAuthCallbackRouter.state(in: url) ?? ""
            return URL(string: "oriveo://mcp/oauth/callback?error=access_denied&state=\(state)&iss=https://auth.example.com")!
        }
        try await run(stubs: [try McpUiFixture.unauthorized()], transport: denied, browser: denyingBrowser) { model in
            await connectApproving(model)
        } verify: { model, rig in
            #expect(model.state.screen == .failure(.authCancelled))
            #expect(denied.formRequests.isEmpty, "a denied callback does not exchange a token")
            try rig.expectNothingLeft("provider denied")
        }

        // The callback state does not match: no token exchange and no token is stored.
        let forged = FakeMcpAuthTransport()
        try McpUiFixture.stubAuthorization(forged)
        let forgingBrowser = FakeMcpBrowserSession()
        forgingBrowser.callbackBuilder = { _ in
            URL(string: "oriveo://mcp/oauth/callback?code=ac_123&state=attacker&iss=https://auth.example.com")!
        }
        try await run(stubs: [try McpUiFixture.unauthorized()], transport: forged, browser: forgingBrowser) { model in
            await connectApproving(model)
        } verify: { model, rig in
            #expect(model.state.screen == .failure(.authCancelled))
            #expect(forged.formRequests.isEmpty, "state mismatch: no token exchange")
            try rig.expectNothingLeft("state mismatch")
        }
    }

    @Test("Limit reached: rejected before probing starts, no request is sent; the page states the limit")
    func limitReached() async throws {
        try await run(stubs: [], runtimeConfig: McpRuntimeConfig(maxServers: 1)) { rig in
            try rig.seedServer(name: "Existing", url: "https://existing.example.org/mcp")
        } drive: { model in
            model.setURL(McpUiFixture.endpoint)
            model.connect()
        } verify: { model, rig in
            #expect(model.state.screen == .failure(.limitReached(max: 1)))
            #expect(McpAddServerContent.failureCopy(.limitReached(max: 1)).message.contains("1"))
            #expect(McpScriptedURLProtocol.requests().isEmpty, "no request is sent once the limit is reached")
            let count = try rig.store.serverCount()
            #expect(count == 1, "the existing server is untouched")
        }
    }

    @Test("Not saved: the server connected and the user tapped Done, but the token cannot be written to the device's secure storage; the freshly inserted record is rolled back, leaving no half server")
    func saveFailed() async throws {
        try await run(stubs: [
            try McpUiFixture.unauthorized(),
            try McpUiFixture.unauthorized(), try McpUiFixture.toolsList(), try McpUiFixture.toolsList(),
        ]) { model in
            model.setURL(McpUiFixture.endpoint)
            model.connect()
            await model.waitUntilSettled()
            model.setToken("pat_live_123")
            model.connectWithToken()
        } verify: { model, rig in
            guard case .review = model.state.screen else {
                Issue.record("expected the review-permissions page, got \(model.state.screen)")
                return
            }
            rig.storage.failWrites = true
            model.finishReview()
            await model.waitUntilSettled()
            #expect(model.state.screen == .failure(.saveFailed) && model.state.completedServerId == nil)
            try rig.expectNothingLeft("token could not be stored")
        }
    }

    @Test("Cancelled: going back or tapping Cancel while connecting returns to the form, leaves no record and no credential, and a late result no longer changes the page")
    func cancelledWhileConnecting() async throws {
        let slow = McpScriptedURLProtocol.Stub(status: 200, body: Data(), delay: 2)
        try await run(stubs: [slow]) { model in
            model.setURL(McpUiFixture.endpoint)
            model.connect()
            try? await Task.sleep(nanoseconds: 100_000_000)
            model.close()
        } verify: { model, rig in
            #expect(model.state.screen == .form && model.state.url == McpUiFixture.endpoint)
            // Let the cancelled attempt unwind: its result must not change the page.
            try await Task.sleep(nanoseconds: 300_000_000)
            #expect(model.state.screen == .form)
            try rig.expectNothingLeft("cancelled while connecting")
        }
    }

    @Test("Address that looks like it embeds a secret: the full address goes to the credential store and the database holds only the display address")
    func localOnlyAddress() async throws {
        let secret = "https://mcp.example.com/mcp?api_key=sk_live_abc123"
        try await run(stubs: [try McpUiFixture.toolsList(), try McpUiFixture.toolsList()]) { model in
            model.setURL(secret)
            model.connect()
        } verify: { model, rig in
            guard case .review(let review) = model.state.screen else {
                Issue.record("expected the review-permissions page, got \(model.state.screen)")
                return
            }
            try rig.expectNothingLeft("before tapping Done")
            model.finishReview()
            await model.waitUntilSettled()
            let saved = try #require(try rig.store.fetchServer(id: review.serverId))
            #expect(saved.localOnly && !saved.url.contains("sk_live_abc123"))
            #expect(rig.credentials.loadEndpoint(serverId: review.serverId, uid: McpUiFixture.uid) == secret)
        }
    }
}
