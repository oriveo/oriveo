import Foundation
import Testing
@testable import Oriveo

/// The "Add relay > Manual setup" page (board ManualSetup).
/// Layout assertions run against the production row models; validation and persistence assertions run the production flow, with only the network replaced by an injected ping stub.
@Suite("Manual setup board: BOARD-MANUAL", .serialized, .sharedProcessState)
@MainActor
struct RelayManualSetupBoardTests {
    private typealias Board = RelayManualSetupBoardModel

    /// Injected 1-token stub: records every request, and can suspend (to simulate in-flight) or fail.
    @MainActor
    private final class PingProbe {
        struct Call {
            let apiKey: String
            let endpoint: String
            let modelID: String
            let requested: RelayRequestedConfig?
        }

        private(set) var calls: [Call] = []
        var error: Error?
        var isGated = false
        private var gate: CheckedContinuation<Void, Never>?

        func ping(apiKey: String, endpoint: String, modelID: String, requested: RelayRequestedConfig?) async throws {
            calls.append(Call(apiKey: apiKey, endpoint: endpoint, modelID: modelID, requested: requested))
            if isGated {
                await withCheckedContinuation { gate = $0 }
            }
            if let error { throw error }
        }

        func release() {
            gate?.resume()
            gate = nil
        }

        /// Waits until the nth request has been sent and is suspended.
        func waitForCall(_ count: Int) async {
            for _ in 0..<2_000 where calls.count < count || gate == nil {
                await Task.yield()
            }
        }
    }

    private struct Fixture {
        let stub: RelaySetupHTTPStub
        let state: AppState
        let probe: PingProbe
        let flow: RelayManualSetupFlow
    }

    private static func makeFixture() -> Fixture {
        let stub = RelaySetupHTTPStub()
        let state = AppState(
            seedDemoData: false,
            sessionUID: "manual-\(UUID().uuidString)",
            providerSession: RelaySetupHTTPStub.session()
        )
        let probe = PingProbe()
        let flow = RelayManualSetupFlow(
            quick: RelayQuickSetupFlow.stubbed(stub),
            family: { _ in nil },
            ping: { try await probe.ping(apiKey: $0, endpoint: $1, modelID: $2, requested: $3) }
        )
        return Fixture(stub: stub, state: state, probe: probe, flow: flow)
    }

    /// Fills in everything needed to be "ready to validate": address, main key, model.
    private static func fill(_ fixture: Fixture, endpoint: String? = nil, model: String = "my-model") {
        fixture.flow.setEndpoint(endpoint ?? fixture.stub.endpoint)
        fixture.flow.setSecret("sk-main-secret", for: RelayKeyBinding.implicitKeyID)
        fixture.flow.setModelID(model)
    }

    private static func relays(_ state: AppState) -> [Provider] {
        state.providers.filter { $0.kind == .relay }
    }

    private static let upstreamFailure = ProviderServiceError.network(detail: "HTTP 500 upstream failed")

    // MARK: - BOARD-MANUAL-01

    @Test("BOARD-MANUAL-01 Section order and content of the single page; Hero trailing tag and subtitle; no step counter and no type card")
    func board01SectionsAndHero() throws {
        let fixture = Self.makeFixture()
        let flow = fixture.flow
        flow.setEndpoint("api.myrelay.dev")
        let board = flow.board

        #expect(board.sections == [.requestURL, .apiKeys, .model, .connectionName, .protocolCard, .advanced])
        #expect(board.hero == Board.Hero(
            icon: .hardDrives,
            labelKey: RelaySetupBoardModel.heroLabelKey,
            titleKey: RelaySetupBoardModel.heroTitleKey,
            subtitleKey: "Fill in the address, key, model and protocol yourself. One tiny request is sent before saving to confirm it works.",
            trailingKey: "Manual setup"
        ))

        // Request address: carries the "will request ..." preview, the same function as step 1.
        #expect(board.address.titleKey == "Request URL")
        #expect(board.address.icon == .link)
        #expect(board.address.footnote == .format("Will request %@", "https://api.myrelay.dev/v1/…"))

        // Keys: the same slots as step 1 (a single key has no name slot; with two or more, every key has one).
        #expect(board.keySlots == [.apiKey, .addKey])
        #expect(board.keysNoteKey == RelaySetupBoardModel.keysLocalKey)
        let extra = flow.addKey()
        #expect(flow.board.keySlots == [.apiKey, .keyName, .addKey])
        flow.removeKey(extra)

        // Model: one model-ID slot whose placeholder is a real model ID.
        #expect(board.model.titleKey == "Model")
        #expect(board.model.placeholder == RelayModelPlaceholder.current)
        #expect(board.model.footnote == .key("Enter the model ID exactly as your Custom Relay lists it. You can add more from the model library later."))

        // Connection name: optional, the placeholder is the domain in the address.
        #expect(board.connectionName.titleKey == "Connection name")
        #expect(board.connectionName.slotLabelKey == "Name (optional)")
        let domain = try #require(ProviderManager.relayDomainName(from: "api.myrelay.dev"))
        #expect(board.connectionName.placeholder == domain)
        #expect(board.connectionName.footnote == .key("Leave it empty to use the domain from the address."))

        // Protocol card: only the default-protocol row.
        #expect(board.protocolGroup.titleKey == "Protocol")
        #expect(!board.protocolGroup.isCollapsible)
        #expect(board.protocolGroup.rows.map(\.id) == [.defaultProtocol])
        #expect(board.protocolGroup.rows.map(\.titleKey) == ["Default protocol"])

        // Collapsed group: collapsed by default; the auth-mode row plus the same User-Agent / headers / query-parameter rows as the edit page.
        #expect(board.advancedGroup.titleKey == "Authentication, headers & query params")
        #expect(board.advancedGroup.isCollapsible)
        #expect(!board.advancedGroup.startsExpanded)
        #expect(board.advancedGroup.rows.map(\.id) == [.authentication, .userAgent, .addEntry])
        flow.setHeaders([RelayKeyValue(key: "X-Token", value: "v")])
        flow.setQueryParams([RelayKeyValue(key: "tenant", value: "t")])
        let filled = flow.board.advancedGroup.rows
        #expect(filled.map(\.id) == [.authentication, .userAgent, .header, .queryParam, .addEntry])
        #expect(filled.map(\.titleKey) == ["Auth Mode", "User-Agent", "Headers", "Query params", "Add"])
        #expect(filled.map(\.control) == [.menu, .valueInput, .keyValue(masked: true), .keyValue(masked: false), .add])
        // No streaming / service tier / do-not-retain-response compatibility items.
        let allRows = flow.board.protocolGroup.rows + filled
        #expect(!allRows.contains { [.stream, .serviceTier, .disableResponseStorage, .connectionSecurity].contains($0.id) })

        // No step counter and no type card: the type-card file is deleted, and the page sources contain nothing of the old two-step wizard.
        let providersDir = Self.projectRoot.appendingPathComponent("Oriveo/Features/Providers")
        #expect(!FileManager.default.fileExists(atPath: providersDir.appendingPathComponent("RelayKindPickerView.swift").path))
        let setup = try Self.source("Oriveo/Features/Providers/RelaySetupView.swift")
        let manual = try Self.source("Oriveo/Features/Providers/RelayManualSetupView.swift")
        for banned in ["STEP 1 OF 2", "STEP 2 OF 2", "Add Custom Relay", "RelayKindPickerView", "RelayKindMeta", "selectedRelayKind", "RelaySimpleSection("] {
            #expect(!setup.contains(banned), "RelaySetupView still contains \(banned)")
            #expect(!manual.contains(banned), "RelayManualSetupView still contains \(banned)")
        }
        #expect(!manual.contains("stepOfKey"))
        #expect(manual.contains("RelayManualSetupBoardModel.quickSetupKey"))
        #expect(Board.quickSetupKey == "Use quick setup")

        try Self.expectKeysShipIn16Locales([
            board.hero.subtitleKey, board.hero.trailingKey, board.address.titleKey, "API Key", "Name (optional)",
            "Will request %@", "Model", "Enter the model ID exactly as your Custom Relay lists it. You can add more from the model library later.",
            "Connection name", "Leave it empty to use the domain from the address.", "Protocol", "Default protocol",
            "Authentication, headers & query params", "Not set", "%lld set", "Use quick setup",
            "Validate and save", "Validate again", "The connection hasn’t been saved yet.", "Save anyway (unverified)",
        ])
    }

    // MARK: - BOARD-MANUAL-02

    @Test("BOARD-MANUAL-02 The default protocol starts as automatic; the two footnote states use the same keys as the edit page; row icon and row color")
    func board02DefaultProtocol() throws {
        let fixture = Self.makeFixture()
        let flow = fixture.flow
        #expect(flow.transport == .auto)
        #expect(Board.transportOptions == LocalEngineChannelCandidates.transportOptions(engineProfile: nil))

        let auto = try #require(flow.board.protocolGroup.rows.first)
        #expect(auto.value == .transport(.auto))
        #expect(auto.footnote == .key(RelayEditBoardModel.protocolAutoNoteKey))
        #expect(auto.icon == .hardDrives)
        #expect(auto.tint == .indigo)
        #expect(auto.tint == RelayDetailBoardModel.iconTint(for: .defaultProtocol))
        #expect(auto.control == .menu)

        flow.setTransport(.openaiResponses)
        let fixed = try #require(flow.board.protocolGroup.rows.first)
        #expect(fixed.value == .transport(.openaiResponses))
        #expect(fixed.footnote == .format(RelayEditBoardModel.protocolFixedNoteKey, relayTransportLabel(.openaiResponses)))

        // Same row as the edit page: the same protocol produces the same row value in the edit-page board.
        var editor = RelayEditView.Editor.empty
        editor.transport = .openaiResponses
        let provider = RelayAddVerification.draftProvider(
            endpoint: "https://api.myrelay.dev",
            requested: RelayRequestedConfig(transport: .openaiResponses),
            modelID: "m"
        )
        let editRow = RelayEditBoardModel.make(provider: provider, editor: editor)
            .groups.flatMap(\.rows).first { $0.id == .defaultProtocol }
        #expect(editRow == fixed)
    }

    // MARK: - BOARD-MANUAL-03

    @Test("BOARD-MANUAL-03 Collapsed-group summary: auth value · Not set / %lld set")
    func board03AdvancedSummary() {
        let fixture = Self.makeFixture()
        let flow = fixture.flow
        #expect(flow.authMode == .auto)
        #expect(flow.board.advancedSummary == [.verbatim(relayAuthLabel(.auto)), .key("Not set")])

        flow.setAuthMode(.bearer)
        flow.setCustomUserAgent("my-agent/1.0")
        // A row with an empty name does not count as filled (same rule as the entries kept on save).
        flow.setHeaders([RelayKeyValue(key: "X-Token", value: "v"), RelayKeyValue(key: " ", value: "ignored")])
        #expect(flow.board.advancedSummary == [.verbatim("Bearer"), .count("%lld set", 2)])
        flow.setQueryParams([RelayKeyValue(key: "tenant", value: "t")])
        #expect(flow.board.advancedSummary == [.verbatim("Bearer"), .count("%lld set", 3)])

        let spoken = Board.summaryString(flow.board.advancedSummary)
        #expect(spoken.hasPrefix("Bearer · "))
        #expect(spoken.contains("3"))
    }

    // MARK: - BOARD-MANUAL-04

    @Test("BOARD-MANUAL-04 The bottom has a single primary button: default / validating / after-failure states; unavailable when the model is empty or validation has issues")
    func board04PrimaryButton() async throws {
        let fixture = Self.makeFixture()
        let flow = fixture.flow
        #expect(flow.board.primary == Board.Primary(titleKey: "Validate and save", showsProgress: false, isEnabled: false))

        // Address and key are filled but the model is still empty: unavailable (no model means no validation request can be sent).
        flow.setEndpoint(fixture.stub.endpoint)
        flow.setSecret("sk-main-secret", for: RelayKeyBinding.implicitKeyID)
        #expect(flow.formIssues.isEmpty)
        #expect(!flow.board.primary.isEnabled)
        flow.setModelID("  ")
        #expect(!flow.board.primary.isEnabled)
        flow.setModelID("my-model")
        #expect(flow.board.primary == Board.Primary(titleKey: "Validate and save", showsProgress: false, isEnabled: true))

        // Validation has an issue (a public endpoint accepts HTTPS only): unavailable.
        flow.setEndpoint("http://relay.example.com/v1")
        #expect(!flow.formIssues.isEmpty)
        #expect(!flow.board.primary.isEnabled)
        #expect(await flow.validateAndSave(appState: fixture.state, entryPoint: .providers) == false)
        #expect(fixture.probe.calls.isEmpty)
        flow.setEndpoint(fixture.stub.endpoint)

        // Validating: in progress and disabled.
        fixture.probe.isGated = true
        fixture.probe.error = Self.upstreamFailure
        let task = Task { await flow.validateAndSave(appState: fixture.state, entryPoint: .providers) }
        await fixture.probe.waitForCall(1)
        #expect(flow.isValidating)
        #expect(flow.board.primary == Board.Primary(titleKey: "Validate and save", showsProgress: true, isEnabled: false))
        fixture.probe.release()
        #expect(await task.value == false)

        // After a failure: the primary button becomes "Validate again" and can be tapped again.
        #expect(flow.board.primary == Board.Primary(titleKey: "Validate again", showsProgress: false, isEnabled: true))

        // There is no "Test connection" button, and no "failure does not affect saving" line.
        let setup = try Self.source("Oriveo/Features/Providers/RelaySetupView.swift")
        let manual = try Self.source("Oriveo/Features/Providers/RelayManualSetupView.swift")
        for source in [setup, manual] {
            #expect(!source.contains("Failures don't block save"))
            #expect(!source.contains("relay_setup_test_connection_button"))
            #expect(!source.contains("RelaySetupPrimaryButtonStyle"))
        }
    }

    // MARK: - BOARD-MANUAL-05

    @Test("BOARD-MANUAL-05 Validation failure: the connection list is unchanged, the failure card carries the 'not saved yet' line and the 'save anyway' action, and the details contain no key or header value")
    func board05FailureDoesNotPersist() async throws {
        let fixture = Self.makeFixture()
        let flow = fixture.flow
        Self.fill(fixture)
        let second = flow.addKey()
        flow.setSecret("sk-second-secret", for: second)
        flow.setHeaders([RelayKeyValue(key: "X-Token", value: "hdr-secret-value")])
        flow.setQueryParams([RelayKeyValue(key: "tenant", value: "query-secret-value")])
        flow.setCustomUserAgent("ua-secret-value/1.0")
        // Upstream often echoes the full request back in its error.
        fixture.probe.error = ProviderServiceError.network(
            detail: "POST \(fixture.stub.endpoint)/v1/chat/completions?tenant=query-secret-value "
                + "Authorization: Bearer sk-main-secret X-Token: hdr-secret-value retry-with sk-second-secret "
                + "User-Agent: ua-secret-value/1.0"
        )
        let before = fixture.state.providers.map(\.id)

        let saved = await flow.validateAndSave(appState: fixture.state, entryPoint: .providers)
        #expect(!saved)
        #expect(fixture.probe.calls.count == 1)
        // Validate with the main key only.
        #expect(fixture.probe.calls.first?.apiKey == "sk-main-secret")
        // Nothing persisted, the page was not left, no notice left behind.
        #expect(fixture.state.providers.map(\.id) == before)
        #expect(Self.relays(fixture.state).isEmpty)
        #expect(fixture.state.navigation.path.isEmpty)
        #expect(fixture.state.providerDetailNotice == nil)

        let board = flow.board
        #expect(board.sections.last == .failure)
        let card = try #require(board.failure)
        #expect(card.message.hasSuffix(L10n.tr("The connection hasn’t been saved yet.", table: .providers)))
        #expect(card.actionTitle == L10n.tr("Save anyway (unverified)", table: .providers))
        #expect(card.detail.contains("/v1/chat/completions"))
        for secret in ["sk-main-secret", "sk-second-secret", "hdr-secret-value", "query-secret-value", "ua-secret-value/1.0"] {
            #expect(!card.detail.contains(secret), "The technical details leaked \(secret)")
            #expect(!card.message.contains(secret), "The failure reason leaked \(secret)")
        }
    }

    // MARK: - BOARD-MANUAL-06

    // MARK: - BOARD-MANUAL-07

    @Test("BOARD-MANUAL-07 Validation passes: the chosen protocol is pinged once and the model keeps no protocol; configuration shape; all keys attached; empty name falls back to the domain")
    func board07ChosenProtocolVerifiesOnce() async throws {
        let fixture = Self.makeFixture()
        let flow = fixture.flow
        Self.fill(fixture, endpoint: fixture.stub.host)
        flow.setKeyName("Main group", for: RelayKeyBinding.implicitKeyID)
        let second = flow.addKey()
        flow.setSecret("sk-second-secret", for: second)
        flow.setKeyName("Second group", for: second)
        let empty = flow.addKey()
        #expect(flow.quick.keys.map(\.id) == [RelayKeyBinding.implicitKeyID, second, empty])
        flow.setTransport(.openaiResponses)
        flow.setAuthMode(.bearer)
        flow.setCustomUserAgent(" my-agent/1.0 ")
        flow.setHeaders([RelayKeyValue(key: "X-Token", value: "v"), RelayKeyValue(key: "", value: "dropped")])
        flow.setQueryParams([RelayKeyValue(key: "tenant", value: "t"), RelayKeyValue(key: "  ", value: "dropped")])

        var completed = 0
        let saved = await flow.validateAndSave(appState: fixture.state, entryPoint: .providers) { completed += 1 }
        #expect(saved)
        #expect(completed == 1)
        await flow.catalogRefreshTask?.value

        // Chosen protocol: sent once with no probing, using the normalized address and the main key.
        #expect(fixture.probe.calls.count == 1)
        let call = try #require(fixture.probe.calls.first)
        #expect(call.requested?.transport == .openaiResponses)
        #expect(call.modelID == "my-model")
        #expect(call.endpoint == fixture.stub.endpoint)
        #expect(call.apiKey == "sk-main-secret")
        #expect(flow.quick.endpoint == fixture.stub.endpoint)

        let provider = try #require(Self.relays(fixture.state).first)
        #expect(provider.status == .connected)
        #expect(provider.baseURLText == fixture.stub.endpoint)
        // Empty name -> the domain in the address.
        #expect(provider.customName == ProviderManager.relayDomainName(from: fixture.stub.endpoint))
        let model = try #require(provider.models.first { $0.id == "my-model" })
        #expect(provider.models.count == 1)
        // A chosen protocol is not written onto the model.
        #expect(model.relayTransport == nil)
        #expect(provider.relayKind == .codexStyle)

        let requested = try #require(provider.relayRequested)
        #expect(requested.transport == .openaiResponses)
        #expect(requested.authMode == .bearer)
        #expect(requested.securityMode == .remoteHTTPS)
        #expect(requested.stream == true)
        #expect(requested.disableResponseStorage == true)
        #expect(requested.codexCompatIdentity == true)
        #expect(requested.serviceTier == nil)
        #expect(requested.modelID == nil)
        #expect(requested.customUserAgent == "my-agent/1.0")
        #expect(requested.headers == [RelayKeyValue(key: "X-Token", value: "v")])
        #expect(requested.queryParams == [RelayKeyValue(key: "tenant", value: "t")])

        // Every key with a value is attached (the empty one is not), with its name.
        #expect(RelayKeyBinding.keyIDs(provider) == [RelayKeyBinding.implicitKeyID, second])
        #expect(provider.relayKeys?.map(\.name) == ["Main group", "Second group"])
        #expect(Set(ProviderCredentialResolver.allSecrets(provider: provider)) == ["sk-main-secret", "sk-second-secret"])

        #expect(fixture.state.providerDetailNotice == ProviderDetailNotice(providerID: provider.id, kind: .addedModels(1)))
        #expect(fixture.state.selectedTab == .providers)
        #expect(fixture.state.navigation.path == [.providerDetail(providerID: provider.id)])
        #expect(fixture.state.lastUsedModelRef == LastUsedModelRef(providerID: provider.id, modelID: "my-model"))

        // Tapping again between a successful persist and the page being popped: no request, no new connection.
        #expect(flow.isCompleted)
        #expect(await flow.validateAndSave(appState: fixture.state, entryPoint: .providers) == false)
        #expect(!flow.saveUnverified(appState: fixture.state, entryPoint: .providers))
        #expect(fixture.probe.calls.count == 1)
        #expect(Self.relays(fixture.state).count == 1)
    }

    @Test("BOARD-MANUAL-07 Analytics relay_kind uses the effective protocol: the chosen one if any, otherwise the address's own when set to automatic")
    func board07RelayKindUsesEffectiveTransport() {
        let fixture = Self.makeFixture()
        let flow = fixture.flow
        flow.setEndpoint("https://api.myrelay.dev")
        #expect(flow.relayKind == .custom)
        // The address carries its own protocol and the default protocol stays automatic: both the abandon event and the validation event report the address's protocol.
        flow.setEndpoint("https://api.myrelay.dev/v1/messages")
        #expect(RelayManualSetupFlow.effectiveTransport(
            chosen: .auto, endpoint: "https://api.myrelay.dev/v1/messages", securityMode: .remoteHTTPS
        ) == .anthropicMessages)
        #expect(flow.relayKind == .anthropicCompatible)
        // A protocol chosen by the user takes precedence over the address's.
        flow.setTransport(.openaiResponses)
        #expect(flow.relayKind == .codexStyle)
        // When the address cannot yet form a request, report automatic and do not guess.
        flow.setTransport(.auto)
        flow.setEndpoint("http://")
        #expect(flow.relayKind == .custom)
    }

    @Test("BOARD-MANUAL-07 Validation passes: in automatic mode validate by the candidate rule and write the passing protocol onto the model; the connection protocol stays automatic")
    func board07AutoProbesCandidates() async throws {
        let fixture = Self.makeFixture()
        let flow = fixture.flow
        Self.fill(fixture)
        flow.setConnectionName("  My Relay ")

        #expect(await flow.validateAndSave(appState: fixture.state, entryPoint: .providers))
        await flow.catalogRefreshTask?.value

        // No catalog information and the family is not found: the only candidate is Chat Completions.
        // Only this candidate is tried; the request goes through the send-path injection point (the same path as a real send): Chat is the default protocol of automatic mode,
        // so the connection protocol stays automatic as is, and only this candidate's root address is carried.
        #expect(fixture.probe.calls.count == 1)
        #expect(fixture.probe.calls.first?.requested?.transport == .auto)
        #expect(fixture.probe.calls.first?.requested?.resolvedAPIBaseURL == fixture.stub.endpoint + "/v1")
        let provider = try #require(Self.relays(fixture.state).first)
        #expect(provider.status == .connected)
        #expect(provider.customName == "My Relay")
        let model = try #require(provider.models.first { $0.id == "my-model" })
        #expect(model.relayTransport == .openaiChatCompletions)
        #expect(model.relayTransportSource == .reachable)
        let requested = try #require(provider.relayRequested)
        #expect(requested.transport == .auto)
        #expect(requested.authMode == .auto)
        #expect(requested.stream == true)
        #expect(requested.disableResponseStorage == true)
        #expect(requested.codexCompatIdentity == nil)
        #expect(requested.headers == nil)
        #expect(requested.queryParams == nil)
        #expect(requested.customUserAgent == nil)
        #expect(requested.modelID == nil)
        #expect(provider.relayKind == .custom)
        // Validation in add step 1 does not write key status; the catalog refresh after saving writes the main key status, and a single key materializes as one list entry.
        #expect(provider.relayKeys?.map(\.id) == ["initial"])
        #expect(provider.relayKeys?.first?.apiKey == "")
        // The fake upstream did not provision a catalog for this key (answers 401): the status is faithfully recorded as invalid.
        #expect(provider.relayKeys?.first?.status?.state == .invalid)
        #expect(provider.relayKeys?.first?.status?.httpStatus == 401)
        // After saving, one catalog refresh ran without blocking; validation sent only that one generation request.
        #expect(fixture.stub.requests.contains("GET /v1/models"))
        #expect(fixture.probe.calls.count == 1)
    }

    // MARK: - BOARD-MANUAL-08

    @Test("BOARD-MANUAL-08 After a failure, changing any input: the failure card clears, the primary button resets, and the old failure can no longer be saved anyway")
    func board08EditingClearsFailure() async throws {
        let fixture = Self.makeFixture()
        let flow = fixture.flow
        Self.fill(fixture)
        fixture.probe.error = Self.upstreamFailure

        let edits: [(String, () -> Void)] = [
            ("Address", { flow.setEndpoint(fixture.stub.endpoint + "/v1") }),
            ("Key", { flow.setSecret("sk-other-secret", for: RelayKeyBinding.implicitKeyID) }),
            ("Model", { flow.setModelID("other-model") }),
            ("Protocol", { flow.setTransport(.geminiGenerateContent) }),
            ("Auth", { flow.setAuthMode(.xApiKey) }),
            ("User-Agent", { flow.setCustomUserAgent("ua") }),
            ("Headers", { flow.setHeaders([RelayKeyValue(key: "X-A", value: "1")]) }),
            ("Query params", { flow.setQueryParams([RelayKeyValue(key: "a", value: "1")]) }),
        ]
        for (name, edit) in edits {
            #expect(await flow.validateAndSave(appState: fixture.state, entryPoint: .providers) == false)
            #expect(flow.board.failure != nil, "\(name): validation should produce a failure card")
            #expect(flow.board.primary.titleKey == "Validate again")
            edit()
            #expect(flow.board.failure == nil, "After changing \(name) the failure card should disappear")
            #expect(flow.board.sections.last == .advanced)
            #expect(flow.board.primary == Board.Primary(titleKey: "Validate and save", showsProgress: false, isEnabled: true))
            // The draft belonging to the old failure is void: it can no longer be persisted from it.
            #expect(!flow.saveUnverified(appState: fixture.state, entryPoint: .providers))
        }
        #expect(Self.relays(fixture.state).isEmpty)

        // The name is just a label: changing it does not void the failure card, and saving uses the name at that time.
        #expect(await flow.validateAndSave(appState: fixture.state, entryPoint: .providers) == false)
        flow.setConnectionName("Renamed")
        flow.setKeyName("ignored for single key", for: RelayKeyBinding.implicitKeyID)
        #expect(flow.board.failure != nil)
        #expect(flow.saveUnverified(appState: fixture.state, entryPoint: .providers))
        #expect(Self.relays(fixture.state).first?.customName == "Renamed")
    }

    @Test("BOARD-MANUAL-08 item 1 When a result returns, it is compared against the input snapshot taken at launch and the current input, so the comparison is not always true")
    func board08StaleComparisonUsesSnapshot() async throws {
        let fixture = Self.makeFixture()
        let flow = fixture.flow
        Self.fill(fixture)
        let snapshot = flow.inputs
        #expect(RelayManualSetupFlow.resultIsCurrent(snapshot: snapshot, current: flow.inputs, attemptIsCurrent: true))
        #expect(!RelayManualSetupFlow.resultIsCurrent(snapshot: snapshot, current: flow.inputs, attemptIsCurrent: false))
        flow.setModelID("other-model")
        #expect(flow.inputs != snapshot)
        #expect(!RelayManualSetupFlow.resultIsCurrent(snapshot: snapshot, current: flow.inputs, attemptIsCurrent: true))

        // Edited and then edited back while in flight: the input equals the snapshot, but that validation is already void, so the result is still dropped.
        flow.setModelID("my-model")
        fixture.probe.isGated = true
        let task = Task { await flow.validateAndSave(appState: fixture.state, entryPoint: .providers) }
        await fixture.probe.waitForCall(1)
        flow.setModelID("other-model")
        flow.setModelID("my-model")
        #expect(flow.inputs == snapshot)
        #expect(!flow.isValidating)
        fixture.probe.release()
        #expect(await task.value == false)
        #expect(Self.relays(fixture.state).isEmpty)

        // Input untouched: the result is committed as usual (the comparison is not always false).
        fixture.probe.isGated = false
        #expect(await flow.validateAndSave(appState: fixture.state, entryPoint: .providers))
        await flow.catalogRefreshTask?.value
        #expect(Self.relays(fixture.state).count == 1)
    }

    @Test("BOARD-MANUAL-08 item 3 Continuing to edit or leaving the page while in flight: the old result neither persists nor raises an old failure card")
    func board08InFlightResultsAreDropped() async throws {
        // A passing in-flight result: not persisted after an edit.
        let passing = Self.makeFixture()
        Self.fill(passing)
        passing.probe.isGated = true
        let passTask = Task { await passing.flow.validateAndSave(appState: passing.state, entryPoint: .providers) }
        await passing.probe.waitForCall(1)
        passing.flow.setHeaders([RelayKeyValue(key: "X-A", value: "1")])
        // The primary button resets immediately, without waiting for the old request to return.
        #expect(passing.flow.board.primary == Board.Primary(titleKey: "Validate and save", showsProgress: false, isEnabled: true))
        passing.probe.release()
        #expect(await passTask.value == false)
        #expect(Self.relays(passing.state).isEmpty)
        #expect(passing.state.navigation.path.isEmpty)
        #expect(passing.state.providerDetailNotice == nil)

        // A failing in-flight result: no old failure card after an edit.
        let failing = Self.makeFixture()
        Self.fill(failing)
        failing.probe.isGated = true
        failing.probe.error = Self.upstreamFailure
        let failTask = Task { await failing.flow.validateAndSave(appState: failing.state, entryPoint: .providers) }
        await failing.probe.waitForCall(1)
        failing.flow.setSecret("sk-other-secret", for: RelayKeyBinding.implicitKeyID)
        failing.probe.release()
        #expect(await failTask.value == false)
        #expect(failing.flow.board.failure == nil)
        #expect(failing.flow.board.primary.titleKey == "Validate and save")
        #expect(!failing.flow.saveUnverified(appState: failing.state, entryPoint: .providers))
        #expect(Self.relays(failing.state).isEmpty)

        // Leaving the page: the in-flight result is void.
        let leaving = Self.makeFixture()
        Self.fill(leaving)
        leaving.probe.isGated = true
        let leaveTask = Task { await leaving.flow.validateAndSave(appState: leaving.state, entryPoint: .providers) }
        await leaving.probe.waitForCall(1)
        leaving.flow.leave()
        #expect(!leaving.flow.isValidating)
        leaving.probe.release()
        #expect(await leaveTask.value == false)
        #expect(Self.relays(leaving.state).isEmpty)
        #expect(leaving.flow.board.failure == nil)
    }

    // MARK: - BOARD-MANUAL-09

    @Test("BOARD-MANUAL-09 Switching back and forth between quick and manual keeps the address and keys; entering the manual page cancels the in-flight detection")
    func board09SharedInputsAndCancelledDetection() async throws {
        let fixture = Self.makeFixture()
        let quick = fixture.flow.quick
        fixture.stub.catalog(secret: "sk-main-secret", modelIDs: ["gpt-6"])

        // The address and keys filled in quick-setup step 1 (including the second key and the name).
        quick.setEndpoint(fixture.stub.endpoint)
        quick.setSecret("sk-main-secret", for: RelayKeyBinding.implicitKeyID)
        let second = quick.addKey()
        quick.setSecret("sk-second-secret", for: second)
        quick.setName("Second group", for: second)

        // Entering the manual page while detection is in flight: detection is cancelled, and coming back does not suddenly jump to step 2.
        let detection = quick.next(appState: fixture.state)
        #expect(quick.isDetecting)
        fixture.flow.enter()
        #expect(!quick.isDetecting)
        #expect(quick.detection == nil)
        await detection?.value
        #expect(quick.detection == nil)
        #expect(quick.step == .connection)

        // The manual page sees the same set of inputs.
        #expect(fixture.flow.board.address.footnote == .format("Will request %@", "https://\(fixture.stub.host)/v1/…"))
        #expect(fixture.flow.board.keySlots == [.apiKey, .keyName, .addKey])
        #expect(fixture.flow.inputs.endpoint == fixture.stub.endpoint)
        #expect(fixture.flow.inputs.secrets == ["sk-main-secret", "sk-second-secret"])

        // Edits made on the manual page are still there back in quick setup; the manual page's own fields are kept too.
        fixture.flow.setEndpoint(fixture.stub.endpoint + "/v1")
        fixture.flow.setSecret("sk-main-edited", for: RelayKeyBinding.implicitKeyID)
        fixture.flow.setModelID("my-model")
        fixture.flow.setTransport(.openaiResponses)
        fixture.flow.leave()
        #expect(quick.endpoint == fixture.stub.endpoint + "/v1")
        #expect(quick.keys.map(\.secret) == ["sk-main-edited", "sk-second-secret"])
        #expect(quick.keys.map(\.name) == ["", "Second group"])
        #expect(quick.step == .connection)
        fixture.flow.enter()
        #expect(fixture.flow.modelID == "my-model")
        #expect(fixture.flow.transport == .openaiResponses)
        #expect(fixture.flow.inputs.secrets == ["sk-main-edited", "sk-second-secret"])
    }

    // MARK: - BOARD-MANUAL-10

    @Test("BOARD-MANUAL-10 Validation hints go where they belong: address / key hints sit under the key block; header / query-parameter hints go under their rows in the collapsed group and expand it")
    func board10IssuePlacement() throws {
        let fixture = Self.makeFixture()
        let flow = fixture.flow
        Self.fill(fixture)
        #expect(flow.board.keyIssues.isEmpty)
        #expect(flow.board.advancedGroup.issues.isEmpty)
        #expect(!flow.board.advancedGroup.isExpanded(userChoice: nil))

        // The issues this page can currently get from production validation (a public endpoint accepts HTTPS only, a key containing non-ASCII characters) all belong to the address / key:
        // they stay under the key block and do not expand the collapsed group.
        flow.setEndpoint("http://relay.example.com/v1")
        flow.setSecret("sk-\u{4E3B}\u{5BC6}\u{94A5}", for: RelayKeyBinding.implicitKeyID)
        flow.setHeaders([RelayKeyValue(key: "X-A", value: "1"), RelayKeyValue(key: "X-B", value: "2")])
        flow.setQueryParams([RelayKeyValue(key: "v", value: "1")])
        let issues = flow.formIssues
        #expect(issues.map(\.code) == [.endpointRejected, .credentialInvalidCharacters])
        #expect(flow.board.keyIssues == issues)
        #expect(flow.board.advancedGroup.issues.isEmpty)
        #expect(!flow.board.advancedGroup.isExpanded(userChoice: nil))
        #expect(!flow.board.primary.isEnabled)

        // Header / query-parameter issues: this page fixes connection security to HTTPS, so shared validation does not currently report this kind here
        // (where production validation actually reports them is BOARD-EDIT-12); the row-model placement rule is the same one as the edit connection page, and this pins down this page's shape.
        let headerIssue = RelayFormValidation.FieldIssue(field: .headers, code: .cleartextCredentials)
        let queryIssue = RelayFormValidation.FieldIssue(field: .queryParams, code: .cleartextCredentials)
        let board = Board.make(.init(
            endpoint: flow.inputs.endpoint,
            modelID: flow.modelID,
            headers: flow.headers,
            queryParams: flow.queryParams,
            hasFormIssues: true,
            issues: issues + [headerIssue, queryIssue]
        ))
        #expect(board.keyIssues == issues)
        let group = board.advancedGroup
        #expect(group.startsExpanded == false)
        #expect(group.issues == [headerIssue, queryIssue])
        #expect(group.isExpanded(userChoice: nil))
        #expect(group.isExpanded(userChoice: false))
        #expect(group.rows.map(\.id) == [.authentication, .userAgent, .header, .header, .queryParam, .addEntry])
        #expect(group.rows.indices.map { group.notes(belowRowAt: $0) } == [[], [], [], [headerIssue], [queryIssue], []])

        // View: only the items outside the group appear under the key block, instead of piling the whole result there.
        let manual = try Self.source("Oriveo/Features/Providers/RelayManualSetupView.swift")
        #expect(manual.contains("RelayFormIssueNotes(issues: board.keyIssues)"))
        #expect(!manual.contains("RelayFormIssueNotes(issues: flow.formIssues)"))
    }

    // MARK: - BOARD-MANUAL-11

    @Test("BOARD-MANUAL-11 Editing input while in flight and then tapping the primary button: the tap is accepted and starts a new validation at once, the old result returns without persisting or touching the UI; rapid taps send only once")
    func board11ClickAfterInFlightEditStartsNewVerification() async throws {
        let fixture = Self.makeFixture()
        let flow = fixture.flow
        let state = fixture.state
        Self.fill(fixture)

        // When the button cannot be tapped, a tap is not accepted (the model is still empty).
        flow.setModelID("")
        #expect(flow.submit(appState: state, entryPoint: .providers) == nil)
        flow.setModelID("my-model")

        fixture.probe.isGated = true
        let first = try #require(flow.submit(appState: state, entryPoint: .providers))
        // Rapid taps: the previous tap has not started validating yet, so a second one is not accepted.
        #expect(flow.submit(appState: state, entryPoint: .providers) == nil)
        await fixture.probe.waitForCall(1)
        #expect(flow.isValidating)
        // Validation in flight: the primary button cannot be tapped, and a tap is likewise not accepted.
        #expect(!flow.board.primary.isEnabled)
        #expect(flow.submit(appState: state, entryPoint: .providers) == nil)
        #expect(fixture.probe.calls.count == 1)

        // Editing while in flight: the primary button resets at once (BOARD-MANUAL-08 item 3). The old validation is still hanging without returning,
        // and since the button is lit now, the tap must be accepted: whether a tap is accepted and whether the button is tappable are the same criterion.
        flow.setModelID("other-model")
        #expect(flow.board.primary == Board.Primary(titleKey: "Validate and save", showsProgress: false, isEnabled: true))
        fixture.probe.isGated = false
        let second = try #require(flow.submit(appState: state, entryPoint: .providers))
        #expect(await second.value)
        await flow.catalogRefreshTask?.value
        #expect(fixture.probe.calls.last?.modelID == "other-model")
        let saved = try #require(Self.relays(state).first)
        #expect(Self.relays(state).count == 1)
        #expect(saved.models.map(\.id) == ["other-model"])
        #expect(saved.status == .connected)

        // The old one finally returns: no second connection, no failure card, and the UI is not pulled back to in-progress.
        fixture.probe.release()
        #expect(await first.value == false)
        #expect(Self.relays(state).count == 1)
        #expect(flow.board.failure == nil)
        #expect(!flow.isValidating)

        // The page shell no longer adds a "previous one has not returned" gate of its own: taps are handed to the flow only.
        let setup = try Self.source("Oriveo/Features/Providers/RelaySetupView.swift")
        #expect(setup.contains("manualFlow.submit(appState: appState, entryPoint: entryPoint)"))
        #expect(!setup.contains("manualFlow.validateAndSave("))
    }

    @Test("BOARD-MANUAL-11 Leaving the page or editing input voids an accepted tap that has not started yet, so no validation is sent after the user has gone")
    func board11QueuedClickIsDroppedOnLeave() async throws {
        let fixture = Self.makeFixture()
        let flow = fixture.flow
        Self.fill(fixture)

        let queued = try #require(flow.submit(appState: fixture.state, entryPoint: .providers))
        flow.leave()
        #expect(await queued.value == false)
        #expect(fixture.probe.calls.isEmpty)
        #expect(!flow.isValidating)
        #expect(Self.relays(fixture.state).isEmpty)

        // After the void, the button is tappable as usual.
        #expect(flow.board.primary.isEnabled)
        let next = try #require(flow.submit(appState: fixture.state, entryPoint: .providers))
        #expect(await next.value)
        await flow.catalogRefreshTask?.value
        #expect(Self.relays(fixture.state).count == 1)
    }

    // MARK: - BOARD-MANUAL-12

    @Test("BOARD-MANUAL-12 Failure card reveal: only a newly appearing failure card dismisses the keyboard and scrolls to it; edit connection and manual setup behave the same")
    func board12FailureCardReveal() async throws {
        let fixture = Self.makeFixture()
        let flow = fixture.flow
        Self.fill(fixture)
        fixture.probe.error = Self.upstreamFailure
        #expect(flow.failureCardID == nil)

        // First failure: a new card appears -> reveal.
        #expect(await flow.validateAndSave(appState: fixture.state, entryPoint: .providers) == false)
        let firstCard = try #require(flow.failureCardID)
        #expect(firstCard == flow.board.failure?.id)
        #expect(RelayFailureCardReveal.shouldReveal(previous: nil, current: firstCard))
        // The same card is still there: do not scroll again.
        #expect(!RelayFailureCardReveal.shouldReveal(previous: firstCard, current: flow.failureCardID))

        // Input edited: the card is cleared -> no scroll.
        flow.setModelID("other-model")
        #expect(flow.failureCardID == nil)
        #expect(!RelayFailureCardReveal.shouldReveal(previous: firstCard, current: flow.failureCardID))

        // Fail once more: it is a different card -> reveal again.
        #expect(await flow.validateAndSave(appState: fixture.state, entryPoint: .providers) == false)
        let secondCard = try #require(flow.failureCardID)
        #expect(secondCard != firstCard)
        #expect(RelayFailureCardReveal.shouldReveal(previous: nil, current: secondCard))

        // Both pages hang the failure card on the same anchor and reveal it with the same function.
        let edit = try Self.source("Oriveo/Features/Providers/RelayEditView.swift")
        let manual = try Self.source("Oriveo/Features/Providers/RelayManualSetupView.swift")
        let setup = try Self.source("Oriveo/Features/Providers/RelaySetupView.swift")
        for card in [edit, manual] {
            #expect(card.contains(".id(RelayFailureCardReveal.anchorID)"))
        }
        for page in [edit, setup] {
            #expect(page.contains("RelayFailureCardReveal.revealIfNeeded("))
        }
    }

    // MARK: - RL2-EDITFAIL-05

    @Test("RL2-EDITFAIL-05 After a manual-setup validation failure, focus is cleared, the keyboard dismissed and the failure card scrolled into view; the shots entry no longer taps back into an input after a failure")
    func editFail05ManualSetupFailureLeavesKeyboardDown() async throws {
        // Production path: a validation failure produces a new card, and the page shell dismisses the keyboard and scrolls to the card accordingly.
        let fixture = Self.makeFixture()
        Self.fill(fixture)
        fixture.probe.error = Self.upstreamFailure
        #expect(await fixture.flow.validateAndSave(appState: fixture.state, entryPoint: .providers) == false)
        let card = try #require(fixture.flow.failureCardID)
        #expect(RelayFailureCardReveal.shouldReveal(previous: nil, current: card))
        let setup = try Self.source("Oriveo/Features/Providers/RelaySetupView.swift")
        #expect(setup.contains(".onChange(of: manualFlow.failureCardID) { previous, current in\n                RelayFailureCardReveal.revealIfNeeded("))

        // Shots entry: once the failure card is out, no input field may become first responder again.
        let shots = try Self.source("Oriveo/Features/Providers/RelayFamilyDebugShots.swift")
        let start = try #require(shots.range(of: "case .relayManualSetupFailure:\n            guard let flows"))
        let end = try #require(shots.range(of: "case .relayManualSetup:\n", range: start.upperBound..<shots.endIndex))
        let branch = String(shots[start.upperBound..<end.lowerBound])
        #expect(branch.contains("failureCardID != nil"))
        #expect(!branch.contains("focusInput"))
    }

    // MARK: - BOARD-MANUAL-15

    @Test("BOARD-MANUAL-15 The 'switch to quick setup' button has three fixed tiers: 100% one line -> 85% one line -> 85% wrapping with no line limit, never truncated; no more continuous font shrinking")
    func board15QuickSetupButtonTiers() throws {
        typealias Layout = RelayManualSetupQuickSetupLayout
        // Tier 1 / tier 2 boundary: a single line at 100% that just fits is still tier 1; slightly more drops to 85%.
        #expect(Layout.tier(availableWidth: 120, fullSizeSingleLineWidth: 120) == .fullSingleLine)
        #expect(Layout.tier(availableWidth: 120, fullSizeSingleLineWidth: 120.5) == .reducedSingleLine)
        // Tier 2 / tier 3 boundary: a single line at 85% that just fits is still tier 2; any narrower wraps.
        #expect(Layout.tier(availableWidth: 85, fullSizeSingleLineWidth: 100) == .reducedSingleLine)
        #expect(Layout.tier(availableWidth: 84.5, fullSizeSingleLineWidth: 100) == .reducedWrapped)

        // Tier fonts and line counts, in placement order; the wrapping tier has no line limit and no tier truncates.
        #expect(Layout.Tier.allCases == [.fullSingleLine, .reducedSingleLine, .reducedWrapped])
        #expect(Layout.Tier.allCases.map(\.scale) == [1, 0.85, 0.85])
        #expect(Layout.Tier.allCases.map(\.lineLimit) == [1, 1, nil])

        // The view places the three tiers in that order; the old continuous-shrink combination "lineLimit(2) + minimumScaleFactor(0.85)" no longer appears.
        let page = try Self.source("Oriveo/Features/Providers/RelayManualSetupView.swift")
        let start = try #require(page.range(of: "struct RelayManualSetupQuickSetupButton"))
        let button = String(page[start.lowerBound...])
        #expect(!button.contains("minimumScaleFactor(0.85)"))
        #expect(!button.contains("lineLimit(2)"))
        #expect(!page.contains(".lineLimit(2)\n                .minimumScaleFactor(0.85)"))
        #expect(button.contains("ViewThatFits(in: .horizontal)"))
        #expect(button.contains("label(.fullSingleLine)\n                label(.reducedSingleLine)\n                label(.reducedWrapped)"))
    }

    // MARK: - Helpers

    private static var projectRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Providers
            .deletingLastPathComponent()   // Features
            .deletingLastPathComponent()   // OriveoTests
            .deletingLastPathComponent()   // Oriveo
    }

    private static func source(_ relativePath: String) throws -> String {
        try String(contentsOf: projectRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    private static func expectKeysShipIn16Locales(_ keys: [String]) throws {
        let data = try Data(contentsOf: projectRoot.appendingPathComponent("Oriveo/Providers.xcstrings"))
        let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try #require(root["strings"] as? [String: Any])
        for key in keys {
            let entry = try #require(strings[key] as? [String: Any], "Providers table is missing \(key)")
            let localizations = try #require(entry["localizations"] as? [String: Any])
            #expect(localizations.count == 16, "\(key) has only \(localizations.count) languages")
        }
    }
}
