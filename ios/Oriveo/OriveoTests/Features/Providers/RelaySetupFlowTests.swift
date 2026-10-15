import Foundation
import Testing
@testable import Oriveo

@Suite("Custom LLM setup flow")
struct RelaySetupFlowTests {
    private func localIdentity(
        engine: String = "ollama",
        endpoint: String = "http://192.168.1.20:11434",
        securityMode: RelayConnectionSecurityMode = .localHTTP,
        authFingerprint: String = "auth-a",
        selectedModel: String = "llama3.2",
        networkRevision: UInt = 1
    ) -> CustomLLMVerificationIdentity {
        CustomLLMVerificationIdentity(
            method: .local,
            engineProfile: engine,
            normalizedEndpoint: endpoint,
            securityMode: securityMode,
            authFingerprint: authFingerprint,
            selectedModel: selectedModel,
            networkRevision: networkRevision
        )
    }

    @Test("switching methods invalidates an in-flight relay result before it can commit or navigate")
    @MainActor
    func methodSwitchRejectsStaleGenerationEvidence() {
        let coordinator = CustomLLMSetupCoordinator(method: .relay)
        let relayAttempt = coordinator.beginVerification(for: .relay)
        // This evidence is created by the production coordinator lifecycle, not a fixture that
        // duplicates the UI's state decision.
        let staleEvidence = CustomLLMConnectionEvidence.verified(relayAttempt)

        coordinator.select(method: .local)

        #expect(!coordinator.acceptVerified(staleEvidence))
        #expect(!coordinator.canCommit(staleEvidence))
        #expect(coordinator.phase == .ready)
        #expect(coordinator.method == .local)
    }

    @Test("local verification evidence can commit only while its generation remains current")
    @MainActor
    func localEvidenceHasSingleCommitGate() {
        let coordinator = CustomLLMSetupCoordinator(method: .local)
        let identity = localIdentity()
        let attempt = coordinator.beginVerification(for: .local, identity: identity)
        let evidence = CustomLLMConnectionEvidence.verified(attempt, identity: identity)

        #expect(coordinator.acceptVerified(evidence))
        #expect(!coordinator.canCommit(evidence))
        #expect(coordinator.canCommit(evidence, matching: identity))

        coordinator.invalidate()
        #expect(!coordinator.canCommit(evidence, matching: identity))
    }

    @Test("Local evidence rejects every stale connection-identity dimension")
    @MainActor
    func localEvidenceRequiresExactCurrentIdentity() {
        let verifiedIdentity = localIdentity()
        let mutations = [
            localIdentity(engine: "vllm"),
            localIdentity(endpoint: "http://192.168.1.21:11434"),
            localIdentity(securityMode: .privateVPN),
            localIdentity(authFingerprint: "auth-b"),
            localIdentity(selectedModel: "qwen2.5"),
            localIdentity(networkRevision: 2),
        ]

        for currentIdentity in mutations {
            let coordinator = CustomLLMSetupCoordinator(method: .local)
            let attempt = coordinator.beginVerification(for: .local, identity: verifiedIdentity)
            let evidence = CustomLLMConnectionEvidence.verified(attempt, identity: verifiedIdentity)

            #expect(coordinator.acceptVerified(evidence))
            #expect(!coordinator.canCommit(evidence, matching: currentIdentity))
        }
    }

    @Test("catalog resolution may fill an empty requested model but never replace an explicit model")
    @MainActor
    func verifiedModelMustPreserveExplicitSelection() {
        let coordinator = CustomLLMSetupCoordinator(method: .local)
        let unresolved = localIdentity(selectedModel: "")
        let resolved = localIdentity(selectedModel: "catalog-model")
        let attempt = coordinator.beginVerification(for: .local, identity: unresolved)
        let evidence = CustomLLMConnectionEvidence.verified(attempt, identity: resolved)

        #expect(coordinator.acceptVerified(evidence))
        #expect(coordinator.canCommit(evidence, matching: resolved))

        let explicitCoordinator = CustomLLMSetupCoordinator(method: .local)
        let explicit = localIdentity(selectedModel: "requested-model")
        let explicitAttempt = explicitCoordinator.beginVerification(for: .local, identity: explicit)
        let replacedEvidence = CustomLLMConnectionEvidence.verified(explicitAttempt, identity: resolved)
        #expect(!explicitCoordinator.acceptVerified(replacedEvidence))
    }

    @Test("identity mutation cancels in-flight work before any verified evidence exists")
    @MainActor
    func invalidationAlwaysCancelsInFlightWork() {
        let coordinator = CustomLLMSetupCoordinator(method: .local)
        let identity = localIdentity()
        let attempt = coordinator.beginVerification(for: .local, identity: identity)
        var cancellationCount = 0
        coordinator.registerCancellation(for: attempt) { cancellationCount += 1 }

        coordinator.invalidate()

        #expect(cancellationCount == 1)
        #expect(coordinator.phase == .ready)
        #expect(!coordinator.isCurrent(attempt))
    }

    @Test("network revision is monotonic and provides an explicit invalidation boundary")
    @MainActor
    func networkRevisionChangesIdentity() {
        let monitor = LocalNetworkRevisionMonitor()
        let initial = monitor.revision
        monitor.recordPathChange()
        monitor.recordPathChange()

        #expect(monitor.revision == initial + 2)
        #expect(localIdentity(networkRevision: initial) != localIdentity(networkRevision: monitor.revision))
    }

    @Test("a relay without a catalog can commit only as the manual-model fallback")
    @MainActor
    func noCatalogKeepsTheExistingManualModelExit() {
        // An empty catalog, or only a generation route found, stops at step 1; tapping Next then enters the
        // manual-add state of step 2. Nothing is persisted without verification (the fixtures
        // catalog_empty_manual_exit / generation_probe_route_without_model have canPersist: false).
        var detection = RelaySetupDetection(keys: [.init(id: RelayKeyBinding.implicitKeyID, label: "sk-…")])
        detection.connection.status = .done
        detection.catalog.status = .failed
        detection.protocols.status = .skipped
        detection.failure = .emptyCatalog
        let board = RelaySetupBoardModel.make(.init(detection: detection, canAct: true))
        #expect(board.nextAction == .models(manualAdd: true))
        #expect(board.isPrimaryEnabled)

        // Manual-add state: nothing can be saved with 0 selections; saving verifies only the first selected model with a 1-token request.
        let manual = RelaySetupModelsBoard.make(.init())
        #expect(manual.showsEmptyNote)
        #expect(!manual.isSaveEnabled)
        let added = RelaySetupModelsBoard.make(.init(groups: [.init(id: "relay", title: "relay", modelIDs: ["typed"])], selected: ["typed"]))
        #expect(added.isSaveEnabled)
        #expect(added.firstSelectedID == "typed")
    }

    @Test("empty relay discovery is a failed terminal phase, never a stuck detector")
    @MainActor
    func emptyDiscoveryEndsTheAttempt() {
        let coordinator = CustomLLMSetupCoordinator(method: .relay)
        let attempt = coordinator.beginVerification(for: .relay)

        #expect(coordinator.acceptDiscoveryResult(for: attempt, hasDetections: false))
        #expect(coordinator.phase == .failed)
    }

    @Test("Open WebUI preset cannot inherit the credential-free local HTTP mode")
    func engineSecurityPresetsKeepBearerOffLocalHTTP() {
        #expect(LocalComputeSetupView.defaultSecurityMode(for: .openwebui) == .remoteHTTPS)
        #expect(LocalComputeSetupView.defaultSecurityMode(for: .ollama) == .remoteHTTPS)
    }

    @Test("Keyless Relay Discovery Input Is Allowed")
    func keylessRelayDiscoveryInputIsAllowed() {
        let requested = RelayKindDefaults.makeRequested(
            for: .custom,
            preserving: RelayRequestedConfig(authMode: .none)
        )
        #expect(!RelayCredentialPolicy.requiresCredential(requested))
        #expect(RelaySetupDiscoveryInputPolicy.permitsDiscovery(
            endpoint: "http://192.168.1.8:1234/v1",
            apiKey: "",
            authMode: requested.authMode
        ))
        #expect(!RelaySetupDiscoveryInputPolicy.permitsDiscovery(
            endpoint: "https://relay.example.com/v1",
            apiKey: "bad\nkey",
            authMode: .none
        ))
    }

    @Test("Writing back a connection test result looks only at the connection fields this page can change: relayKind and the connection-level reasoning effort are not part of the connection identity")
    func persistedVerificationWritebackIgnoresKindAndConnectionReasoning() {
        var provider = TestFactories.makeProvider(
            kind: .relay,
            baseURLText: "https://relay.example.com/v1"
        )
        provider.relayKind = .codexStyle
        provider.relayRequested = RelayRequestedConfig(
            transport: .openaiResponses,
            authMode: .bearer,
            securityMode: .remoteHTTPS,
            modelID: "gpt-test",
            // A stored connection-level effort: outbound requests no longer read it and probes don't send it,
            // so it must not make an unchanged connection look like a draft.
            reasoningEffort: .high,
            serviceTier: "priority",
            disableResponseStorage: true,
            codexCompatIdentity: nil,
            webSearchToolName: .webSearch
        )
        let candidate = RelayRequestedConfig(
            transport: .openaiResponses,
            authMode: .bearer,
            securityMode: .remoteHTTPS,
            modelID: "gpt-test",
            reasoningEffort: nil,
            serviceTier: "priority",
            disableResponseStorage: true,
            codexCompatIdentity: nil,
            webSearchToolName: .webSearch
        )

        #expect(RelayConnectionPersistenceComparator.matches(
            provider: provider,
            candidateEndpoint: "https://relay.example.com/v1/",
            candidateRequested: candidate
        ))
        // A stored relayKind that disagrees with the kind implied by the protocol (e.g. the old
        // OpenAI-compatible + Responses) still counts as the same connection.
        var legacyKind = provider
        legacyKind.relayKind = .openaiCompatible
        #expect(RelayConnectionPersistenceComparator.matches(
            provider: legacyKind,
            candidateEndpoint: "https://relay.example.com/v1/",
            candidateRequested: candidate
        ))

        var changed = candidate
        changed.transport = .openaiChatCompletions
        #expect(!RelayConnectionPersistenceComparator.matches(provider: provider, candidateEndpoint: "https://relay.example.com/v1", candidateRequested: changed))
        changed = candidate
        changed.serviceTier = "default"
        #expect(!RelayConnectionPersistenceComparator.matches(provider: provider, candidateEndpoint: "https://relay.example.com/v1", candidateRequested: changed))
        changed = candidate
        changed.disableResponseStorage = nil
        #expect(!RelayConnectionPersistenceComparator.matches(provider: provider, candidateEndpoint: "https://relay.example.com/v1", candidateRequested: changed))
        changed = candidate
        changed.webSearchToolName = RelayWebSearchToolName.disabled
        #expect(!RelayConnectionPersistenceComparator.matches(provider: provider, candidateEndpoint: "https://relay.example.com/v1", candidateRequested: changed))
        // This page doesn't edit the Codex identity and the probe takes the stored value as is: only a mismatch makes it a different connection.
        changed = candidate
        changed.codexCompatIdentity = false
        #expect(!RelayConnectionPersistenceComparator.matches(provider: provider, candidateEndpoint: "https://relay.example.com/v1", candidateRequested: changed))
        #expect(!RelayConnectionPersistenceComparator.matches(provider: provider, candidateEndpoint: "https://relay-2.example.com/v1", candidateRequested: candidate))
    }

    @Test("Relay Edit Reverification Classification")
    func relayEditReverificationClassification() {
        var saved = TestFactories.makeProvider(
            kind: .relay,
            catalogModels: [TestFactories.makeModel(id: "old-catalog")],
            baseURLText: "https://relay.example.com/v1"
        )
        saved.relayKind = .openaiCompatible
        saved.relayRequested = RelayRequestedConfig(
            transport: .openaiChatCompletions,
            authMode: .bearer,
            securityMode: .remoteHTTPS,
            modelID: "gpt-live"
        )

        var displayOnly = RelayEditView.Editor(from: saved)
        displayOnly.modelID = "gpt-new-default"
        displayOnly.customUserAgent = "Oriveo/Test"
        displayOnly.headers = [RelayKeyValue(key: "X-Trace", value: "1")]
        displayOnly.queryParams = [RelayKeyValue(key: "debug", value: "true")]
        #expect(RelayEditSavePolicy.primaryAction(from: saved, editor: displayOnly) == .save)
        #expect(RelayEditSavePolicy.primaryAction(from: saved, editor: displayOnly).titleKey == "Save")

        var endpointChanged = displayOnly
        endpointChanged.endpoint = "https://relay-2.example.com/v1"
        #expect(RelayEditSavePolicy.primaryAction(from: saved, editor: endpointChanged) == .validateAndSave)
        #expect(RelayEditSavePolicy.primaryAction(from: saved, editor: endpointChanged).titleKey == "Validate and save")

        var transportChanged = displayOnly
        transportChanged.transport = .openaiResponses
        #expect(RelayEditSavePolicy.primaryAction(from: saved, editor: transportChanged) == .validateAndSave)
        #expect(RelayEditSavePolicy.clearsCatalogBeforeVerification(from: saved, editor: transportChanged))
        let verifiedCandidate = RelayEditSavePolicy.invalidatingCatalogIfConnectionChanged(
            saved,
            from: saved,
            editor: transportChanged
        )
        let unverifiedCandidate = RelayEditSavePolicy.invalidatingCatalogIfConnectionChanged(
            saved,
            from: saved,
            editor: transportChanged
        )
        #expect(verifiedCandidate.catalogModels.isEmpty)
        #expect(unverifiedCandidate.catalogModels.isEmpty)
        #expect(verifiedCandidate.models.map(\.id) == saved.models.map(\.id))
        #expect(unverifiedCandidate.models.map(\.id) == saved.models.map(\.id))

        var authChanged = displayOnly
        authChanged.authMode = .xApiKey
        #expect(RelayEditSavePolicy.primaryAction(from: saved, editor: authChanged) == .validateAndSave)

        // There is no type layer: a stored relayKind that disagrees with the kind implied by the protocol does not mean the connection changed.
        var legacyKind = saved
        legacyKind.relayKind = .custom
        #expect(RelayEditSavePolicy.primaryAction(from: legacyKind, editor: displayOnly) == .save)
        #expect(!RelayEditSavePolicy.clearsCatalogBeforeVerification(from: legacyKind, editor: displayOnly))
    }

    @Test("The model on the Relay edit page is the verification sample (it doesn't read the old isDefault / relayRequested.modelID), and saving doesn't write modelID")
    @MainActor
    func relayEditDefaultModelUsesSavedDefaultAndSingleCandidateSelection() {
        var firstEnabled = TestFactories.makeModel(id: "first-enabled", isDefault: false)
        firstEnabled.isManual = false
        let legacyDefault = TestFactories.makeModel(id: "legacy-default", isDefault: true)
        let catalogModel = TestFactories.makeModel(id: "catalog-only", isDefault: false)
        var provider = TestFactories.makeProvider(
            kind: .relay,
            models: [firstEnabled, legacyDefault],
            catalogModels: [catalogModel]
        )
        provider.relayRequested = RelayRequestedConfig(modelID: "legacy-default")

        // Editor(from:) is the production edit-entry path, not a hand-built fixture.
        var editor = RelayEditView.Editor(from: provider)
        #expect(editor.modelID == "first-enabled")
        editor.modelID = "catalog-only"
        let saved = RelayEditSavePolicy.savedRequested(
            editor: editor,
            provider: provider,
            normalizedEndpoint: "https://relay.example.com/v1"
        )
        #expect(saved.modelID == nil)

        // With no enabled model, the sample falls back to the first catalog model.
        var catalogOnly = provider
        catalogOnly.models = []
        #expect(RelayEditView.Editor(from: catalogOnly).modelID == "catalog-only")
    }

    @Test("Relay Edit Unverified Save Rejects Stale Editor Snapshot")
    func relayEditUnverifiedSaveRejectsStaleEditorSnapshot() {
        let provider = TestFactories.makeProvider(kind: .relay)
        var snapshot = RelayEditView.Editor.empty
        snapshot.endpoint = "https://relay.example.com/v1"

        #expect(RelayEditUnverifiedSavePolicy.mayPersist(
            candidateProviderID: provider.id,
            editorSnapshot: snapshot,
            currentEditor: snapshot,
            currentProviderID: provider.id,
            targetProviderID: provider.id
        ))

        var editedAfterFailure = snapshot
        editedAfterFailure.endpoint = "https://new-relay.example.com/v1"
        #expect(!RelayEditUnverifiedSavePolicy.mayPersist(
            candidateProviderID: provider.id,
            editorSnapshot: snapshot,
            currentEditor: editedAfterFailure,
            currentProviderID: provider.id,
            targetProviderID: provider.id
        ))
        #expect(!RelayEditUnverifiedSavePolicy.mayPersist(
            candidateProviderID: provider.id,
            editorSnapshot: snapshot,
            currentEditor: snapshot,
            currentProviderID: nil,
            targetProviderID: provider.id
        ))
    }

    @Test("Relay Edit Failure Presentation Redacts Connection Material")
    func relayEditFailurePresentationRedactsConnectionMaterial() {
        let apiKey = "sk-relay-secret-12345678"
        let endpoint = "https://relay.secret.example/v1"
        let headerName = "X-Private-Header"
        let headerValue = "header-secret-value"
        let queryName = "private_query"
        let queryValue = "query-secret-value"
        var provider = TestFactories.makeProvider(kind: .relay, apiKey: apiKey, baseURLText: endpoint)
        provider.relayRequested = RelayRequestedConfig(
            transport: .openaiChatCompletions,
            authMode: .bearer,
            securityMode: .remoteHTTPS,
            modelID: "gpt-live",
            headers: [RelayKeyValue(key: headerName, value: headerValue)],
            queryParams: [RelayKeyValue(key: queryName, value: queryValue)]
        )

        // The verifier's production error type may echo request material in its
        // technical detail.  The presentation helper is the UI's only ingress.
        let verifierError = ProviderServiceError.upstream(
            statusCode: 401,
            detail: "url=\(endpoint) key=\(apiKey) \(headerName)=\(headerValue) \(queryName)=\(queryValue)"
        )
        let card = RelayEditFailurePresentation.error(from: verifierError, provider: provider)
        let visibleState = [card.message, card.detail].joined(separator: "\n")

        #expect(card.actionTitle == L10n.tr("Save anyway (unverified)", table: .providers))
        #expect(card.detail.contains(String(
            format: L10n.tr("Retried %d time(s) automatically.", table: .providers),
            0
        )) == true)
        for visibleDiagnostic in [endpoint, headerName, queryName] {
            #expect(visibleState.contains(visibleDiagnostic), "failure presentation hid \(visibleDiagnostic)")
        }
        for secret in [apiKey, headerValue, queryValue] {
            #expect(!visibleState.contains(secret), "failure presentation leaked \(secret)")
        }

        // Key sheet must call the same presentation with a safe acknowledgement action,
        // so the just-rotated key follows the exact same redaction boundary.
        let keyRotationCard = RelayEditFailurePresentation.error(
            from: verifierError,
            provider: provider,
            actionTitle: L10n.tr("OK")
        )
        #expect(keyRotationCard.actionTitle == L10n.tr("OK"))
        for secret in [apiKey, headerValue, queryValue] {
            #expect(!keyRotationCard.detail.contains(secret), "key rotation presentation leaked \(secret)")
        }
    }

    @Test("The failure card redaction list includes the custom User-Agent, and edit connection and manual setup share the same list")
    func relayEditFailurePresentationRedactsCustomUserAgent() {
        let userAgent = "internal-agent/ua-secret-token"
        var provider = TestFactories.makeProvider(kind: .relay, apiKey: "sk-relay-secret-12345678", baseURLText: "https://relay.example/v1")
        provider.relayRequested = RelayRequestedConfig(
            transport: .openaiChatCompletions,
            authMode: .bearer,
            securityMode: .remoteHTTPS,
            customUserAgent: userAgent
        )
        let error = ProviderServiceError.network(detail: "POST https://relay.example/v1/chat/completions User-Agent: \(userAgent)")
        let card = RelayEditFailurePresentation.error(from: error, provider: provider)
        #expect(!card.detail.contains(userAgent))
        #expect(!card.message.contains(userAgent))
        #expect(card.detail.contains("/v1/chat/completions"))
        // A connection without a custom User-Agent is unaffected: the detail is left as is.
        provider.relayRequested?.customUserAgent = nil
        let plain = RelayEditFailurePresentation.error(from: error, provider: provider)
        #expect(plain.detail.contains(userAgent))
    }

    @Test("only relay setup may render the relay save bar")
    func relaySaveBarVisibilityIsMethodScoped() {
        // The local page brings its own single primary button; the three relay pages (step 1, step 2, manual setup) all get
        // their primary button from this action bar. Manual setup no longer has an in-between state with no button because no type is chosen yet (the type-card page is gone).
        #expect(!RelaySetupView.showsRelaySaveBar(method: .local))
        #expect(RelaySetupView.showsRelaySaveBar(method: .relay))
    }

    @Test("Provider Setup Has No Search And Uses Two Custom Entries")
    func providerSetupHasNoSearchAndUsesTwoCustomEntries() throws {
        let source = try String(
            contentsOf: projectRoot.appendingPathComponent("Oriveo/Features/Providers/ProviderSetupView.swift"),
            encoding: .utf8
        )

        #expect(!source.contains("providerSearchQuery"))
        #expect(!source.contains("Search providers"))
        #expect(source.contains("private struct CustomProviderEntry: View"))
        #expect(source.contains("private struct LocalComputeEntry: View"))
        #expect(source.contains("private struct CustomRelayEntry: View"))
        #expect(source.contains("title: L10n.tr(\"Local compute\""))
        #expect(source.contains("title: L10n.tr(\"Custom Relay\""))
        #expect(source.contains("systemImage: \"cpu\""))
        #expect(source.contains("systemImage: \"arrow.triangle.swap\""))
        #expect(source.contains("iconColor: OriveoTheme.Palette.primary"))
        #expect(!source.contains("iconShadow:"))
        #expect(source.contains(".frame(minHeight: 70)"))
        #expect(!source.contains("private struct CustomLLMEntry: View"))
    }

    @Test("Custom Entries Route To The Shared Shell")
    func customEntriesRouteToTheSharedShell() throws {
        // The route destination shared by the outer stack and the wide-screen right column lives in AppRouteDestination.
        let root = try String(
            contentsOf: projectRoot.appendingPathComponent("Oriveo/Features/App/AppRouteDestination.swift"),
            encoding: .utf8
        )
        let entry = try String(
            contentsOf: projectRoot.appendingPathComponent("Oriveo/Features/Providers/ProviderSetupView.swift"),
            encoding: .utf8
        )
        let setup = try String(
            contentsOf: projectRoot.appendingPathComponent("Oriveo/Features/Providers/RelaySetupView.swift"),
            encoding: .utf8
        )

        #expect(root.contains("RelaySetupView(entryPoint: entryPoint, initialMethod: .local)"))
        #expect(!root.contains("LocalComputeSetupView(entryPoint: entryPoint)"))
        #expect(root.contains("RelaySetupView(entryPoint: entryPoint)\n                .oriveoNavigationChrome()"))
        #expect(root.contains("RelaySetupView(entryPoint: entryPoint, initialMethod: .local)\n                .oriveoNavigationChrome()"))
        #expect(entry.contains("LocalComputeEntry"))
        #expect(entry.contains("CustomRelayEntry"))
        #expect(entry.contains(".localComputeSetup(entryPoint: entryPoint)"))
        #expect(entry.contains("appState.openRelaySetup(from: entryPoint)"))
        #expect(!setup.contains("connectionMethodPicker"))
        // Setup board: the top bar no longer shows "Local compute / Custom Relay"; the page title is only the Hero (BOARD-SETUP-01).
        #expect(!setup.contains("setupCoordinator.method == .local ? \"Local compute\" : \"Custom Relay\""))
        #expect(setup.contains("RelaySetupBoardModel.heroTitleKey"))
    }

    @Test("Relay Create Does Not Expose Local Security Choices")
    func relayCreateDoesNotExposeLocalSecurityChoices() throws {
        let setup = try String(
            contentsOf: projectRoot.appendingPathComponent("Oriveo/Features/Providers/RelaySetupView.swift"),
            encoding: .utf8
        )
        let local = try String(
            contentsOf: projectRoot.appendingPathComponent("Oriveo/Features/Providers/LocalComputeSetupView.swift"),
            encoding: .utf8
        )

        // Both the quick setup and the manual setup flows pin connection security to public HTTPS, and no page offers a choice.
        for relativePath in [
            "Oriveo/Features/Providers/RelaySetupTwoStep.swift",
            "Oriveo/Features/Providers/RelayManualSetupFlow.swift",
        ] {
            let flow = try String(contentsOf: projectRoot.appendingPathComponent(relativePath), encoding: .utf8)
            #expect(flow.contains("private let securityMode: RelayConnectionSecurityMode = .remoteHTTPS"), "\(relativePath)")
        }
        #expect(RelaySetupView.normalizedRelayEndpoint("http://relay.example.com/v1") == nil)
        for relativePath in [
            "Oriveo/Features/Providers/RelaySetupStepViews.swift",
            "Oriveo/Features/Providers/RelayManualSetupView.swift",
        ] {
            let fields = try String(contentsOf: projectRoot.appendingPathComponent(relativePath), encoding: .utf8)
            #expect(!fields.contains("RelaySecurityModeSummaryRow("), "\(relativePath)")
            #expect(!fields.contains("RelaySecurityModePickerSheet("), "\(relativePath)")
        }
        #expect(!setup.contains("RelaySecurityModePickerSheet("))
        #expect(!RelayManualSetupBoardModel.make(.init()).protocolGroup.rows.contains { $0.id == .connectionSecurity })
        #expect(local.contains("RelaySecurityModeSummaryRow("))
        #expect(local.contains("RelaySecurityModePickerSheet("))
    }

    @Test("Quick Setup Keeps Only Connection Fields")
    func quickSetupKeepsOnlyConnectionFields() throws {
        let stepOne = try String(
            contentsOf: projectRoot.appendingPathComponent("Oriveo/Features/Providers/RelaySetupStepViews.swift"),
            encoding: .utf8
        )
        // Step 1 of quick setup has only the address, the key, a key name (with 2 or more keys) and add-another-key; it never shows a connection name.
        #expect(RelaySetupBoardModel.slots(keyCount: 1) == [.address, .apiKey, .addKey])
        #expect(!stepOne.contains("Display Name"))
        #expect(!stepOne.contains("connectionName"))
        // The connection name appears only on the manual setup page, and it is optional.
        let manual = RelayManualSetupBoardModel.make(.init())
        #expect(manual.sections.contains(.connectionName))
        #expect(manual.connectionName.titleKey == RelayManualSetupBoardModel.connectionNameKey)
        #expect(manual.connectionName.slotLabelKey == "Name (optional)")
    }

    @Test("Local Fields Remain Available")
    func localFieldsRemainAvailable() throws {
        let local = try String(
            contentsOf: projectRoot.appendingPathComponent("Oriveo/Features/Providers/LocalComputeSetupView.swift"),
            encoding: .utf8
        )
        let relay = try String(
            contentsOf: projectRoot.appendingPathComponent("Oriveo/Features/Providers/RelaySetupView.swift"),
            encoding: .utf8
        )

        #expect(local.contains("let coordinator: CustomLLMSetupCoordinator"))
        #expect(local.contains("RelaySetupField("))
        #expect(local.contains("RelaySetupMenuField("))
        #expect(local.contains("RelaySetupStatusRow("))
        #expect(!local.contains(".textFieldStyle(.roundedBorder)"))
        #expect(!local.contains("DisclosureGroup(L10n.tr(\"Pairing code\""))
        #expect(!local.contains("LocalPairingScannerView"))
        #expect(local.contains("LocalEngineDiscoverySession()"))
        #expect(local.contains(".safeAreaInset(edge: .bottom)"))
        #expect(local.contains("L10n.tr(board.primaryButton.titleKey, table: .providers)"))
        #expect(!local.contains(".pickerStyle(.segmented)"))
        #expect(relay.contains("onCompleted: completeProviderSetup"))
    }

    @Test("Local Accessibility Release Surface")
    func localAccessibilityReleaseSurface() throws {
        let local = try String(
            contentsOf: projectRoot.appendingPathComponent("Oriveo/Features/Providers/LocalComputeSetupView.swift"),
            encoding: .utf8
        )
        let fields = try String(
            contentsOf: projectRoot.appendingPathComponent("Oriveo/Features/Providers/RelaySimpleSection.swift"),
            encoding: .utf8
        )
        // The model slot is gone, so only the address slot's technical value stays left-to-right.
        #expect(local.components(separatedBy: "forcesLeftToRightValue: true").count - 1 >= 1)
        #expect(local.contains("UIAccessibility.post(notification: .announcement"))
        #expect(local.contains("accessibilityFocused($accessibilityFocus"))
        #expect(fields.contains(".frame(minWidth: 44, minHeight: 44)"))
        #expect(fields.contains("accessibilityReduceMotion"))
    }

    @Test("Custom LLM Copy Is Fully Localized")
    func customLLMCopyIsFullyLocalized() throws {
        let data = try Data(contentsOf: projectRoot.appendingPathComponent("Oriveo/Providers.xcstrings"))
        let catalog = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try #require(catalog["strings"] as? [String: Any])
        let expectedLocales: Set<String> = [
            "ar", "de", "en", "es", "fr", "hi", "id", "ja",
            "ko", "pt-BR", "ru", "th", "tr", "vi", "zh-Hans", "zh-Hant",
        ]

        for key in [
            "Custom Relay",
            "Local compute",
            "Connection security",
        ] {
            let entry = try #require(strings[key] as? [String: Any], "missing \(key)")
            let localizations = try #require(entry["localizations"] as? [String: Any])
            #expect(Set(localizations.keys) == expectedLocales, "incomplete localization for \(key)")
        }
    }

    private var projectRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
