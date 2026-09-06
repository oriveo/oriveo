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
        let coordinator = CustomLLMSetupCoordinator(method: .relay)
        let attempt = coordinator.beginVerification(for: .relay)
        let evidence = CustomLLMConnectionEvidence.needsManualModel(attempt)

        #expect(coordinator.acceptVerified(evidence))
        #expect(coordinator.canCommit(evidence))
        #expect(evidence.verification == .needsManualModel)
        #expect(evidence.catalog == .unavailable)
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

    @Test("saved Codex default identity and UI true are the same connection for status writeback")
    func codexDefaultIdentityAllowsPersistedVerificationWriteback() {
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
            reasoningEffort: .high,
            serviceTier: "priority",
            disableResponseStorage: true,
            codexCompatIdentity: true,
            webSearchToolName: .webSearch
        )

        #expect(RelayConnectionPersistenceComparator.matches(
            provider: provider,
            candidateEndpoint: "https://relay.example.com/v1/",
            candidateRequested: candidate,
            candidateKind: .codexStyle
        ))
        #expect(!RelayConnectionPersistenceComparator.matches(
            provider: provider,
            candidateEndpoint: "https://relay.example.com/v1/",
            candidateRequested: candidate,
            candidateKind: .custom
        ))

        var changed = candidate
        changed.reasoningEffort = RelayReasoningEffort.low
        #expect(!RelayConnectionPersistenceComparator.matches(provider: provider, candidateEndpoint: "https://relay.example.com/v1", candidateRequested: changed, candidateKind: .codexStyle))
        changed = candidate
        changed.serviceTier = "default"
        #expect(!RelayConnectionPersistenceComparator.matches(provider: provider, candidateEndpoint: "https://relay.example.com/v1", candidateRequested: changed, candidateKind: .codexStyle))
        changed = candidate
        changed.disableResponseStorage = nil
        #expect(!RelayConnectionPersistenceComparator.matches(provider: provider, candidateEndpoint: "https://relay.example.com/v1", candidateRequested: changed, candidateKind: .codexStyle))
        changed = candidate
        changed.webSearchToolName = RelayWebSearchToolName.disabled
        #expect(!RelayConnectionPersistenceComparator.matches(provider: provider, candidateEndpoint: "https://relay.example.com/v1", candidateRequested: changed, candidateKind: .codexStyle))
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
        displayOnly.customName = "Renamed relay"
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

        var kindChanged = displayOnly
        kindChanged.relayKind = .custom
        #expect(RelayEditSavePolicy.primaryAction(from: saved, editor: kindChanged) == .validateAndSave)
        #expect(RelayEditSavePolicy.clearsCatalogBeforeVerification(from: saved, editor: kindChanged))
    }

    @Test("Relay Edit Default Model Uses Saved Default And Single Candidate Selection")
    @MainActor
    func relayEditDefaultModelUsesSavedDefaultAndSingleCandidateSelection() {
        var oldDefault = TestFactories.makeModel(id: "old-default", isDefault: true)
        oldDefault.isManual = false
        let catalogModel = TestFactories.makeModel(id: "new-default", isDefault: false)
        var provider = TestFactories.makeProvider(
            kind: .relay,
            models: [oldDefault],
            catalogModels: [catalogModel]
        )
        provider.relayRequested = RelayRequestedConfig(modelID: nil)

        // Editor(from:) is the production edit-entry path, not a hand-built fixture.
        var editor = RelayEditView.Editor(from: provider)
        #expect(editor.modelID == "old-default")
        editor.modelID = "new-default"
        var candidate = provider
        candidate.relayRequested = RelayRequestedConfig(modelID: editor.modelID)
        let selected = ProviderManager.applyingRelayDefaultModelSelection(
            to: candidate,
            modelID: editor.modelID
        )

        #expect(selected.relayRequested?.modelID == "new-default")
        #expect(selected.defaultModel?.id == "new-default")
        #expect(selected.models.filter(\.isDefault).count == 1)
    }

    @Test("Relay Default Model Picker Rejects Stale Catalog Evidence")
    func relayDefaultModelPickerRejectsStaleCatalogEvidence() {
        let staleCatalog = TestFactories.makeProvider(
            kind: .relay,
            catalogModels: [TestFactories.makeModel(id: "stale-catalog")],
            lastError: ProviderIssueMessage.catalogUnavailableKey
        )
        #expect(!RelayDefaultModelPresentation.usesCatalogPicker(
            for: staleCatalog,
            isCatalogRefreshing: false
        ))

        let loadingCatalog = TestFactories.makeProvider(
            kind: .relay,
            catalogModels: [TestFactories.makeModel(id: "still-loading")]
        )
        #expect(!RelayDefaultModelPresentation.usesCatalogPicker(
            for: loadingCatalog,
            isCatalogRefreshing: true
        ))
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

    @Test("only relay setup may render the relay save bar")
    func relaySaveBarVisibilityIsMethodScoped() {
        #expect(!RelaySetupView.showsRelaySaveBar(
            method: .local,
            showsManualProfiles: false,
            hasSelectedRelayKind: false
        ))
        #expect(RelaySetupView.showsRelaySaveBar(
            method: .relay,
            showsManualProfiles: false,
            hasSelectedRelayKind: false
        ))
        #expect(!RelaySetupView.showsRelaySaveBar(
            method: .relay,
            showsManualProfiles: true,
            hasSelectedRelayKind: false
        ))
        #expect(RelaySetupView.showsRelaySaveBar(
            method: .relay,
            showsManualProfiles: true,
            hasSelectedRelayKind: true
        ))
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
        let root = try String(
            contentsOf: projectRoot.appendingPathComponent("Oriveo/Features/App/AppRootView.swift"),
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
        #expect(setup.contains("setupCoordinator.method == .local ? \"Local compute\" : \"Custom Relay\""))
    }

    @Test("Relay Create Does Not Expose Local Security Choices")
    func relayCreateDoesNotExposeLocalSecurityChoices() throws {
        let setup = try String(
            contentsOf: projectRoot.appendingPathComponent("Oriveo/Features/Providers/RelaySetupView.swift"),
            encoding: .utf8
        )
        let fields = try String(
            contentsOf: projectRoot.appendingPathComponent("Oriveo/Features/Providers/RelaySimpleSection.swift"),
            encoding: .utf8
        )
        let local = try String(
            contentsOf: projectRoot.appendingPathComponent("Oriveo/Features/Providers/LocalComputeSetupView.swift"),
            encoding: .utf8
        )

        #expect(setup.contains("private let securityMode: RelayConnectionSecurityMode = .remoteHTTPS"))
        #expect(RelaySetupView.normalizedRelayEndpoint("http://relay.example.com/v1") == nil)
        #expect(!setup.contains("RelaySecurityModePickerSheet("))
        #expect(!fields.contains("RelaySecurityModeSummaryRow("))
        #expect(local.contains("RelaySecurityModeSummaryRow("))
        #expect(local.contains("RelaySecurityModePickerSheet("))
    }

    @Test("Quick Setup Keeps Only Connection Fields")
    func quickSetupKeepsOnlyConnectionFields() throws {
        let setup = try String(
            contentsOf: projectRoot.appendingPathComponent("Oriveo/Features/Providers/RelaySetupView.swift"),
            encoding: .utf8
        )
        let fields = try String(
            contentsOf: projectRoot.appendingPathComponent("Oriveo/Features/Providers/RelaySimpleSection.swift"),
            encoding: .utf8
        )

        #expect(setup.contains("showsName: false"))
        #expect(fields.contains("if showsName"))
        #expect(fields.contains("title: L10n.tr(\"Display Name\""))
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
        #expect(local.contains("L10n.tr(\"Test connection\""))
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
        #expect(local.components(separatedBy: "forcesLeftToRightValue: true").count - 1 >= 2)
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
