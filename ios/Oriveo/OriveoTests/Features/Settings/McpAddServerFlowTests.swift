import Foundation
import Testing
@testable import Oriveo

// MARK: - The add-server flow
//
// Under test is the production `McpAddServerModel` (UI state) wired to the production `McpAddCoordinator` (probing +
// persisting); only the network is replayed. Every assertion lands on an object the production path actually
// produced: rows in the store, the credential store, outbound requests.

@Suite("MCP add flow: UI state machine", .serialized)
@MainActor
struct McpAddServerFlowTests {
    @Test("Form → connecting → review: a server without sign-in reaches the review-permissions page; nothing is stored before Done is tapped, and tapping it persists the server")
    func directSuccess() async throws {
        McpScriptedURLProtocol.reset()
        try McpScriptedURLProtocol.enqueue([McpUiFixture.toolsList(), McpUiFixture.toolsList()])
        let rig = try McpUiRig(); defer { rig.cleanUp() }
        let model = rig.addModel()
        #expect(model.state.screen == .form && !model.state.canConnect, "Connect is disabled while the address is empty")

        model.setURL(McpUiFixture.endpoint)
        #expect(model.state.canConnect)
        model.connect()
        #expect(model.state.screen == .progress(stage: .connecting, authorizationHost: nil, signedIn: false))
        #expect(model.state.nameIsUnknown && model.state.displayName == "mcp.example.com", "the hostname is shown while the name is unknown")
        await model.waitUntilSettled()

        guard case .review(let review) = model.state.screen else {
            Issue.record("expected the review-permissions page, got \(model.state.screen)")
            return
        }
        #expect(!review.tools.isEmpty && review.readOnlyPermission == .auto && review.changesPermission == .ask)
        // Before confirmation the server does not exist on this device.
        try rig.expectNothingLeft("before confirming default permissions")

        model.setChangesPermission(.off)
        model.finishReview()
        await model.waitUntilSettled()
        #expect(model.state.completedServerId == review.serverId)
        let saved = try #require(try rig.store.fetchServer(id: review.serverId))
        #expect(saved.url == McpUiFixture.endpoint && saved.authKind == .auto && !saved.localOnly)
        let snapshots = try rig.store.fetchToolSnapshots(serverId: review.serverId)
        #expect(!snapshots.isEmpty && snapshots.allSatisfy { !$0.pendingReview }, "the user reviewed and tapped Done: no longer quarantined")
        let permissions = try rig.store.fetchToolPermissions(serverId: review.serverId)
        for snapshot in snapshots {
            #expect(permissions[snapshot.toolName] == (snapshot.readOnly ? .auto : .off), "\(snapshot.toolName)")
        }
        #expect(try rig.directory.overview(uid: McpUiFixture.uid).first?.health == .connected)

        // The page disappears: a server that was already confirmed is left untouched.
        model.close()
        #expect(try rig.store.fetchServer(id: review.serverId) != nil)
    }

    @Test("Going back from review abandons the add: the token obtained through browser sign-in lives only in memory, and the device keeps no trace of the server")
    func abandoningReviewLeavesNothing() async throws {
        McpScriptedURLProtocol.reset()
        try McpScriptedURLProtocol.enqueue([McpUiFixture.unauthorized(), McpUiFixture.toolsList(), McpUiFixture.toolsList()])
        let transport = FakeMcpAuthTransport()
        try McpUiFixture.stubAuthorization(transport)
        let rig = try McpUiRig(transport: transport, browser: McpUiFixture.approvingBrowser()); defer { rig.cleanUp() }
        let model = rig.addModel()
        model.setURL(McpUiFixture.endpoint)
        model.connect()
        #expect(await McpUiWait.until {
            model.state.screen == .progress(stage: .authPrompt, authorizationHost: "auth.example.com", signedIn: false)
        })
        model.approveSignIn()
        await model.waitUntilSettled()
        guard case .review = model.state.screen else {
            Issue.record("expected the review-permissions page, got \(model.state.screen)")
            return
        }
        #expect(transport.formRequests.count == 1, "precondition: the token was actually exchanged")
        // Killing the process before persisting cannot leave an orphan token: the token is not in the credential store yet.
        try rig.expectNothingLeft("signed in, Done not tapped yet")

        model.close()
        #expect(model.state.screen == .form)
        try rig.expectNothingLeft("add abandoned")
    }

    @Test("Tapping Done for a browser sign-in server: the record is persisted first, then the token goes to the credential store; if that fails the record is rolled back")
    func oauthCredentialsPersistAfterTheRecord() async throws {
        McpScriptedURLProtocol.reset()
        try McpScriptedURLProtocol.enqueue([McpUiFixture.unauthorized(), McpUiFixture.toolsList(), McpUiFixture.toolsList()])
        let transport = FakeMcpAuthTransport()
        try McpUiFixture.stubAuthorization(transport)
        let rig = try McpUiRig(transport: transport, browser: McpUiFixture.approvingBrowser()); defer { rig.cleanUp() }
        let model = rig.addModel()
        model.setURL(McpUiFixture.endpoint)
        model.connect()
        #expect(await McpUiWait.until {
            if case .progress(.authPrompt, _, _) = model.state.screen { return true }
            return false
        })
        model.approveSignIn()
        await model.waitUntilSettled()
        guard case .review(let review) = model.state.screen else {
            Issue.record("expected the review-permissions page, got \(model.state.screen)")
            return
        }

        // The first Done tap cannot write to the credential store: treated as a failed add, leaving no half server.
        rig.storage.failWrites = true
        model.finishReview()
        await model.waitUntilSettled()
        #expect(model.state.screen == .failure(.saveFailed) && model.state.completedServerId == nil)
        try rig.expectNothingLeft("token could not be stored")

        // Retry: probe again, sign in again, and this time the write succeeds.
        rig.storage.failWrites = false
        McpScriptedURLProtocol.reset()
        try McpScriptedURLProtocol.enqueue([McpUiFixture.unauthorized(), McpUiFixture.toolsList(), McpUiFixture.toolsList()])
        model.retry()
        #expect(await McpUiWait.until {
            if case .progress(.authPrompt, _, _) = model.state.screen { return true }
            return false
        })
        model.approveSignIn()
        await model.waitUntilSettled()
        model.finishReview()
        await model.waitUntilSettled()
        let serverId = try #require(model.state.completedServerId)
        #expect(serverId != review.serverId, "a retry is a fresh add")
        #expect(try rig.store.fetchServer(id: serverId) != nil)
        let credentials = try #require(rig.credentials.load(serverId: serverId, uid: McpUiFixture.uid))
        #expect(credentials.accessToken != nil && credentials.refreshToken != nil)
    }

    @Test("The pre-sign-in notice is a gate: it shows the sign-in page hostname; no client registration and no browser before Continue; afterwards browser sign-in → connecting (signed in) → review")
    func authPromptGate() async throws {
        McpScriptedURLProtocol.reset()
        try McpScriptedURLProtocol.enqueue([McpUiFixture.unauthorized(), McpUiFixture.toolsList(), McpUiFixture.toolsList()])
        let transport = FakeMcpAuthTransport()
        try McpUiFixture.stubDCRAuthorization(transport)
        let browser = McpUiFixture.approvingBrowser()
        let rig = try McpUiRig(transport: transport, browser: browser); defer { rig.cleanUp() }
        let model = rig.addModel()
        model.setURL(McpUiFixture.endpoint)
        model.setName("Linear")
        model.connect()

        #expect(await McpUiWait.until {
            if case .progress(.authPrompt, _, _) = model.state.screen { return true }
            return false
        })
        #expect(model.state.screen == .progress(stage: .authPrompt, authorizationHost: "auth.example.com", signedIn: false))
        #expect(model.state.displayName == "Linear" && model.state.host == "mcp.example.com")
        try await Task.sleep(nanoseconds: 150_000_000)
        #expect(transport.jsonRequests.isEmpty, "no client registration before consent")
        #expect(browser.openedURLs.isEmpty, "no browser before consent")
        #expect(try rig.database.nonEmptyTables() == [:])

        model.approveSignIn()
        await model.waitUntilSettled()
        #expect(transport.jsonRequests.map(\.url) == [McpUiFixture.registrationURL])
        #expect(browser.openedURLs.count == 1)
        guard case .review(let review) = model.state.screen else {
            Issue.record("expected the review-permissions page, got \(model.state.screen)")
            return
        }
        model.finishReview()
        await model.waitUntilSettled()
        #expect(try rig.store.fetchServer(id: review.serverId)?.name == "Linear")
    }

    @Test("Cancel on the pre-sign-in notice: back to the form with its content kept; no registration, no browser, no record and no credential left")
    func cancellingAtAuthPrompt() async throws {
        McpScriptedURLProtocol.reset()
        try McpScriptedURLProtocol.enqueue([McpUiFixture.unauthorized()])
        let transport = FakeMcpAuthTransport()
        try McpUiFixture.stubDCRAuthorization(transport)
        let browser = McpUiFixture.approvingBrowser()
        let rig = try McpUiRig(transport: transport, browser: browser); defer { rig.cleanUp() }
        let model = rig.addModel()
        model.setURL(McpUiFixture.endpoint)
        model.setName("Linear")
        model.connect()
        #expect(await McpUiWait.until {
            if case .progress(.authPrompt, _, _) = model.state.screen { return true }
            return false
        })

        model.cancel()
        #expect(model.state.screen == .form && model.state.url == McpUiFixture.endpoint && model.state.name == "Linear")
        // The abandoned attempt has to finish unwinding before "it left nothing behind" means anything.
        await model.waitUntilSettled()
        #expect(model.state.screen == .form)
        #expect(transport.jsonRequests.isEmpty && browser.openedURLs.isEmpty)
        try rig.expectNothingLeft("cancelled on the pre-sign-in notice")
    }

    @Test(
        "Cancel while the sign-in page is open: back to the form at once; the abandoned sign-in is torn down, and waiting for the page to settle covers that teardown",
        .timeLimit(.minutes(1))
    )
    func cancellingDuringBrowserSignIn() async throws {
        McpScriptedURLProtocol.reset()
        try McpScriptedURLProtocol.enqueue([McpUiFixture.unauthorized()])
        let transport = FakeMcpAuthTransport()
        try McpUiFixture.stubDCRAuthorization(transport)
        let browser = FakeMcpBrowserSession()
        browser.holdsUntilCancelled = true
        let rig = try McpUiRig(transport: transport, browser: browser); defer { rig.cleanUp() }
        let model = rig.addModel()
        model.setURL(McpUiFixture.endpoint)
        model.setName("Linear")
        model.connect()
        #expect(await McpUiWait.until {
            if case .progress(.authPrompt, _, _) = model.state.screen { return true }
            return false
        })
        model.approveSignIn()
        await browser.waitUntilOpened()

        model.cancel()
        #expect(model.state.screen == .form && model.state.url == McpUiFixture.endpoint && model.state.name == "Linear")
        #expect(browser.releasedSignIns == 0, "the page moves on before the sign-in has been torn down")
        await model.waitUntilSettled()
        #expect(browser.releasedSignIns == 1, "settled means the abandoned sign-in has returned")
        #expect(model.state.screen == .form, "the abandoned attempt's result does not change the page")
        #expect(browser.openedURLs.count == 1 && transport.formRequests.isEmpty, "no token exchange after a cancel")
        try rig.expectNothingLeft("cancelled while the sign-in page was open")
    }

    @Test("The three-step checklist only marks what has already happened as done; \"Signed in\" appears only after a sign-in")
    func checklistMapping() {
        func states(_ stage: McpAddStage, signedIn: Bool = false) -> [McpChecklistState] {
            McpAddServerContent.checklist(stage: stage, signedIn: signedIn, name: "Linear").map(\.state)
        }
        #expect(states(.connecting) == [.active, .waiting, .waiting], "the first step is not checked before the connection is made")
        #expect(states(.authPrompt) == [.done, .done, .waiting])
        #expect(states(.browser) == [.done, .active, .waiting])
        #expect(states(.finishing) == [.done, .done, .active])

        let prompt = McpAddServerContent.checklist(stage: .authPrompt, signedIn: false, name: "Linear")
        #expect(prompt[1].detail == String(format: L10n.tr("Sign-in needed for %@", table: .mcp), "Linear"))
        let signedIn = McpAddServerContent.checklist(stage: .finishing, signedIn: true, name: "Linear")
        #expect(signedIn[1].title == String(format: L10n.tr("Signed in to %@", table: .mcp), "Linear"))
        let direct = McpAddServerContent.checklist(stage: .finishing, signedIn: false, name: "Linear")
        #expect(direct[1].title == L10n.tr("Checking how to sign in", table: .mcp), "no \"Signed in\" without a sign-in")
    }

    @Test("Settings entry: the subtitle is built from the server count and the pending count; omitted when nothing has been read; the entry is hidden when MCP is switched off in the model catalog")
    func settingsEntrySubtitle() throws {
        #expect(McpHealthCopy.settingsSubtitle(nil) == nil)
        #expect(
            McpHealthCopy.settingsSubtitle(McpSettingsEntrySummary(serverCount: 0, attentionCount: 0))
                == L10n.tr("Let the model use your services", table: .mcp)
        )
        #expect(
            McpHealthCopy.settingsSubtitle(McpSettingsEntrySummary(serverCount: 4, attentionCount: 0))
                == String(format: L10n.tr("Servers: %d", table: .mcp), 4)
        )
        #expect(
            McpHealthCopy.settingsSubtitle(McpSettingsEntrySummary(serverCount: 4, attentionCount: 1))
                == String(format: L10n.tr("Servers: %1$d · Need attention: %2$d", table: .mcp), 4, 1)
        )

        // The overview comes from the production directory reading local storage: one healthy server, one with expired authorization, one with tools awaiting review.
        let rig = try McpUiRig(); defer { rig.cleanUp() }
        try rig.seedServer(name: "Linear")
        try rig.seedServer(name: "GitHub", url: "https://api.example.org/mcp", status: .needsAuth)
        try rig.seedServer(name: "Notion", url: "https://notion.example.org/mcp", pendingReview: true)
        let summary = McpSettingsEntrySummary(try rig.directory.overview(uid: McpUiFixture.uid))
        #expect(summary == McpSettingsEntrySummary(serverCount: 3, attentionCount: 2))

        // With `enabled = false` the settings page hides the entry (existing configuration is kept); the switch is read
        // from the runtime configuration in the model catalog.
        #expect(McpRuntimeConfig(json: .object(JSONObject([("enabled", .bool(false))]))).enabled == false)
        #expect(McpRuntimeConfig(json: nil).enabled, "a missing configuration does not hide the entry")
    }
}
