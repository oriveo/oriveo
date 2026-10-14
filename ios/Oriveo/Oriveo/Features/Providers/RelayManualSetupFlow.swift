import Foundation

// MARK: - Manual setup flow (ManualSetup)
//
// Address and keys are the same inputs as quick setup step 1 (`RelayQuickSetupFlow`), so switching back and forth loses nothing; this flow only additionally manages
// the model, connection name, default protocol, authentication method and headers. Verification always goes through `RelayAddVerification.run`:
// the connection is stored only if it passes; on failure nothing is stored, and only when the user taps "Save anyway (unverified)" on the failure card is it stored, as an issue.

@MainActor
@Observable
final class RelayManualSetupFlow {
    /// One 1-token verification request. Production goes through `OpenAIService.pingRelay`; tests inject a stub.
    typealias Ping = @MainActor (
        _ apiKey: String,
        _ endpoint: String,
        _ modelID: String,
        _ requested: RelayRequestedConfig?
    ) async throws -> Void

    /// All inputs that can affect the verification verdict. The connection name and key names are just labels and are not included.
    struct Inputs: Equatable {
        var endpoint: String
        /// The primary key + the other keys that have a value.
        var secrets: [String]
        var modelID: String
        var transport: RelayTransport
        var authMode: RelayAuthMode
        var customUserAgent: String
        var headers: [RelayKeyValue]
        var queryParams: [RelayKeyValue]
    }

    /// One failed verification: the failure card + the draft awaiting explicit user confirmation. It is bound to the input snapshot taken when the request started;
    /// once the input changes, this draft can no longer be stored.
    private struct Failure {
        let card: OriveoError
        let reason: String
        let snapshot: Inputs
        let endpoint: String
        let requested: RelayRequestedConfig
    }

    let quick: RelayQuickSetupFlow
    @ObservationIgnored private let family: (String) async -> String?
    @ObservationIgnored private let ping: Ping?
    /// A custom relay is a public-internet entry point; the new-connection path accepts only HTTPS.
    private let securityMode: RelayConnectionSecurityMode = .remoteHTTPS

    private(set) var modelID = ""
    private(set) var connectionName = ""
    private(set) var transport: RelayTransport = .auto
    private(set) var authMode: RelayAuthMode = .auto
    private(set) var customUserAgent = ""
    private(set) var headers: [RelayKeyValue] = []
    private(set) var queryParams: [RelayKeyValue] = []

    private(set) var isValidating = false
    /// Already stored. In the beat before navigation pops this page, neither the primary button nor "Save anyway" responds, so no second record is written.
    private(set) var isCompleted = false
    private var failure: Failure?
    /// How many times the normalized address was written back to the input field; the view uses it to flash the address slot.
    private(set) var endpointWritebackToken = 0
    /// `provider_setup_abandoned` carries only the attempt count and a normalized error slug, never the error body or keys.
    private(set) var connectionAttempts = 0
    /// The non-blocking catalog refresh after saving (tests wait for it to finish).
    @ObservationIgnored private(set) var catalogRefreshTask: Task<Void, Never>?
    /// The most recent accepted tap of the primary button (`submit`). Changing input or leaving the page invalidates it.
    @ObservationIgnored private var submitTask: Task<Bool, Never>?
    /// A tap that was accepted but has not started verification: blocks rapid repeat taps so the same input cannot send two verifications.
    @ObservationIgnored private var hasQueuedSubmit = false

    init(
        quick: RelayQuickSetupFlow,
        family: @escaping (String) async -> String? = { await MetadataClient.shared.relayModelFamily(for: $0) },
        ping: Ping? = nil
    ) {
        self.quick = quick
        self.family = family
        self.ping = ping
    }

    private var coordinator: CustomLLMSetupCoordinator { quick.coordinator }

    // MARK: Input

    var inputs: Inputs {
        Inputs(
            endpoint: quick.endpoint,
            secrets: [quick.keys[0].trimmedSecret] + quick.keys.dropFirst().map(\.trimmedSecret).filter { !$0.isEmpty },
            modelID: trimmedModelID,
            transport: transport,
            authMode: authMode,
            customUserAgent: customUserAgent,
            headers: headers,
            queryParams: queryParams
        )
    }

    func setEndpoint(_ value: String) { edit { quick.setEndpoint(value) } }
    func setSecret(_ value: String, for keyID: String) { edit { quick.setSecret(value, for: keyID) } }
    func removeKey(_ keyID: String) { edit { quick.removeKey(keyID) } }
    func setModelID(_ value: String) { edit { modelID = value } }
    func setTransport(_ value: RelayTransport) { edit { transport = value } }
    func setAuthMode(_ value: RelayAuthMode) { edit { authMode = value } }
    func setCustomUserAgent(_ value: String) { edit { customUserAgent = value } }
    func setHeaders(_ value: [RelayKeyValue]) { edit { headers = value } }
    func setQueryParams(_ value: [RelayKeyValue]) { edit { queryParams = value } }

    /// The name is just a label: it does not invalidate verification, and the value at save time is used.
    func setConnectionName(_ value: String) { connectionName = value }
    func setKeyName(_ value: String, for keyID: String) { quick.setName(value, for: keyID) }

    @discardableResult
    func addKey() -> String { quick.addKey() }

    /// Invalidate only when the input really changed: the failure card disappears, the primary button resets, and the result of an in-flight verification is no longer accepted.
    private func edit(_ change: () -> Void) {
        let before = inputs
        change()
        guard inputs != before else { return }
        invalidate()
    }

    private func invalidate() {
        failure = nil
        isValidating = false
        hasQueuedSubmit = false
        submitTask?.cancel()
        submitTask = nil
        coordinator.invalidate()
    }

    /// Entering the manual page from quick setup step 1: cancel the in-flight check (address and keys are kept).
    func enter() {
        quick.cancelDetection()
    }

    /// Returning to quick setup or leaving the page: the in-flight verification is invalidated.
    func leave() {
        invalidate()
    }

    // MARK: Derived values

    private var trimmedModelID: String {
        modelID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A draft from the same source as the shared form validation (add and edit use the same pure function, so the criteria are not rewritten here).
    private var formDraft: RelayFormDraft {
        RelayFormDraft(
            endpoint: quick.endpoint,
            apiKey: quick.keys[0].secret,
            authMode: authMode,
            securityMode: securityMode,
            transport: transport,
            modelID: modelID,
            headers: headers,
            queryParams: queryParams
        )
    }

    var formIssues: [RelayFormValidation.FieldIssue] {
        RelayFormValidation.validate(formDraft, mode: .create)
    }

    /// The other keys follow the same character-set rule as step 1: empty is fine, a filled value must be visible ASCII.
    private var extraKeysAreUsable: Bool {
        quick.keys.dropFirst().allSatisfy { $0.trimmedSecret.isEmpty || ProviderKeyInput.isPrintableASCII($0.trimmedSecret) }
    }

    /// A card exists only while the input behind the failure has not changed: writing the address back does not count as changing input (the snapshot is taken after the write-back).
    private var currentFailure: Failure? {
        guard let failure, failure.snapshot == inputs else { return nil }
        return failure
    }

    var board: RelayManualSetupBoardModel {
        RelayManualSetupBoardModel.make(.init(
            endpoint: quick.endpoint,
            previewLine: quick.previewLine,
            keyCount: quick.keys.count,
            modelID: modelID,
            transport: transport,
            authMode: authMode,
            customUserAgent: customUserAgent,
            headers: headers,
            queryParams: queryParams,
            hasFormIssues: !formIssues.isEmpty || !extraKeysAreUsable,
            issues: formIssues,
            isValidating: isValidating,
            failure: currentFailure?.card
        ))
    }

    /// Identity of the current failure card; the view uses it to dismiss the keyboard and scroll to the card when a new one appears.
    var failureCardID: UUID? { currentFailure?.card.id }

    /// Effective protocol: the selected default protocol if any; if it stays on auto but the address carries its own protocol (.../v1/messages), the address's protocol is used.
    /// The stored config, the verification request and analytics all take this one value.
    static func effectiveTransport(
        chosen: RelayTransport,
        endpoint: String,
        securityMode: RelayConnectionSecurityMode
    ) -> RelayTransport {
        guard chosen == .auto else { return chosen }
        guard let normalized = RelaySetupView.normalizedRelayEndpoint(
            endpoint.trimmingCharacters(in: .whitespacesAndNewlines),
            securityMode: securityMode
        ) else { return .auto }
        return (try? RelayEndpointResolver.describe(normalized))?.explicitTransport ?? .auto
    }

    /// relay_kind in analytics: there is no kind layer, so it is derived only from the effective protocol; the abandon event and the verification event use the same value.
    var relayKind: RelayKind {
        RelayKind(transport: Self.effectiveTransport(chosen: transport, endpoint: quick.endpoint, securityMode: securityMode))
    }


    /// Whether the result of an in-flight verification can still be accepted: this verification was not invalidated, and the current input equals the snapshot taken when it started.
    static func resultIsCurrent(snapshot: Inputs, current: Inputs, attemptIsCurrent: Bool) -> Bool {
        attemptIsCurrent && snapshot == current
    }

    /// Shape of the stored config: the same shape as "add manually after the connection check failed" on the quick path, plus the protocol / authentication / headers chosen on this page.
    /// It does not go through a kind template; streaming is always on, and the other compatibility items are changed in edit connection after saving.
    static func requestedConfig(
        transport: RelayTransport,
        authMode: RelayAuthMode,
        securityMode: RelayConnectionSecurityMode,
        modelID: String,
        customUserAgent: String,
        headers: [RelayKeyValue],
        queryParams: [RelayKeyValue]
    ) -> RelayRequestedConfig {
        let isBlank: (String) -> Bool = { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        // Rows with an empty name are neither stored nor sent with the request.
        let cleanedHeaders = headers.filter { !isBlank($0.key) }
        let cleanedQueries = queryParams.filter { !isBlank($0.key) }
        let userAgent = customUserAgent.trimmingCharacters(in: .whitespacesAndNewlines)
        var config = RelayRequestedConfig(
            transport: transport,
            authMode: authMode,
            securityMode: securityMode,
            modelID: modelID,
            stream: true
        )
        switch transport {
        case .openaiResponses:
            config.disableResponseStorage = true
            config.codexCompatIdentity = true
        case .auto:
            config.disableResponseStorage = true
        default:
            break
        }
        config.headers = cleanedHeaders.isEmpty ? nil : cleanedHeaders
        config.queryParams = cleanedQueries.isEmpty ? nil : cleanedQueries
        config.customUserAgent = userAgent.isEmpty ? nil : userAgent
        return config
    }

    // MARK: Verify and save

    /// Entry point of the primary-button tap. Whether a tap is accepted uses the same criterion as whether the button is enabled: if the button is lit, a tap always starts a verification.
    /// If the input was changed while one is in flight, the previous one is already invalidated and may still be winding down; we do not wait for it and start this one right away,
    /// and when the old result returns it neither stores nor touches the UI (it is discarded by verification generation in `validateAndSave`).
    /// Returns nil = this tap was not accepted (the button was not enabled, or the previous tap has not started verifying yet).
    @discardableResult
    func submit(
        appState: AppState,
        entryPoint: ProviderSetupEntryPoint,
        onWillComplete: @escaping () -> Void = {}
    ) -> Task<Bool, Never>? {
        guard !hasQueuedSubmit, !isCompleted, board.primary.isEnabled else { return nil }
        hasQueuedSubmit = true
        let task = Task<Bool, Never> { @MainActor [weak self] in
            // The input changed or the page was left while queued: this tap is invalidated with it.
            guard let self, !Task.isCancelled else { return false }
            self.hasQueuedSubmit = false
            return await self.validateAndSave(
                appState: appState,
                entryPoint: entryPoint,
                onWillComplete: onWillComplete
            )
        }
        submitTask = task
        return task
    }

    @discardableResult
    func validateAndSave(
        appState: AppState,
        entryPoint: ProviderSetupEntryPoint,
        onWillComplete: () -> Void = {}
    ) async -> Bool {
        guard !isCompleted, !isValidating, board.primary.isEnabled else { return false }
        // Write the normalized address back to the visible input before sending: what the user sees, what is stored and what the network layer uses are the same string.
        // The write-back does not take the invalidation path; the snapshot below is taken after it, so it also does not make the later failure draft mismatch.
        if quick.writeBackEndpoint() { endpointWritebackToken &+= 1 }
        guard let normalized = RelaySetupView.normalizedRelayEndpoint(
            quick.endpoint.trimmingCharacters(in: .whitespacesAndNewlines),
            securityMode: securityMode
        ) else { return false }

        let sampleModelID = trimmedModelID
        let primarySecret = quick.keys[0].trimmedSecret
        let requested = Self.requestedConfig(
            transport: Self.effectiveTransport(chosen: transport, endpoint: normalized, securityMode: securityMode),
            authMode: authMode,
            securityMode: securityMode,
            modelID: sampleModelID,
            customUserAgent: customUserAgent,
            headers: headers,
            queryParams: queryParams
        )
        let chosenTransport: RelayTransport? = requested.transport == .auto ? nil : requested.transport

        failure = nil
        isValidating = true
        connectionAttempts += 1
        let snapshot = inputs
        let attempt = coordinator.beginVerification(for: .relay)

        let service = appState.providerManager.openAIService
        // Verification runs in its own task registered with the coordinator: changing input or leaving the page can cancel it immediately without waiting for the request to time out.
        let box = VerificationBox()
        let verification = Task { @MainActor [weak self] in
            box.result = try? await self?.runVerification(
                endpoint: normalized,
                requested: requested,
                chosenTransport: chosenTransport,
                modelID: sampleModelID,
                secret: primarySecret,
                service: service
            )
        }
        coordinator.registerCancellation(for: attempt) { verification.cancel() }
        await withTaskCancellationHandler {
            await verification.value
        } onCancel: {
            verification.cancel()
        }
        guard let result = box.result else {
            // Only cancellation reaches here; if this run still counts, clear the in-progress state.
            if coordinator.isCurrent(attempt) {
                isValidating = false
                _ = coordinator.acceptFailure(for: attempt)
            }
            return false
        }
        // If input changed, the page was left, or another run started in the meantime: the old result neither stores nor shows a failure card.
        guard Self.resultIsCurrent(
            snapshot: snapshot,
            current: inputs,
            attemptIsCurrent: coordinator.isCurrent(attempt)
        ) else {
            if coordinator.isCurrent(attempt) {
                isValidating = false
                _ = coordinator.acceptFailure(for: attempt)
            }
            return false
        }
        isValidating = false

        guard result.verified else {
            _ = coordinator.acceptFailure(for: attempt)
            let error: Error = result.lastError ?? ProviderServiceError.network(
                detail: L10n.tr("No detected protocol completed the test request.", table: .providers)
            )
            let presentation = failurePresentation(for: error)
            failure = Failure(
                card: presentation.card,
                reason: presentation.reason,
                snapshot: snapshot,
                endpoint: normalized,
                requested: requested
            )
            return false
        }

        let evidence = CustomLLMConnectionEvidence.verified(attempt)
        guard coordinator.acceptVerified(evidence), coordinator.canCommit(evidence) else { return false }

        let provider = persist(
            appState: appState,
            endpoint: normalized,
            requested: requested,
            connectionState: .connected,
            modelOutcome: result.modelOutcome
        )
        // Navigation removes this page synchronously and triggers onDisappear: record completion first so a success is not recorded as abandonment.
        onWillComplete()
        appState.completeRelaySetup(
            providerID: provider.id,
            entryPoint: entryPoint,
            verifiedModelID: sampleModelID,
            addedModelCount: 1
        )
        // A catalog failure does not roll back the save: fetch once without blocking, and the existing failure state on the connection page handles a failure.
        let manager = appState.providerManager
        let providerID = provider.id
        catalogRefreshTask = Task { @MainActor in
            _ = await manager.refreshRelayCatalog(providerID: providerID)
        }
        return true
    }

    /// Where the verification result lands: `RelayAddVerification.Result` carries an `Error`, which is not passed across task boundaries.
    private final class VerificationBox {
        var result: RelayAddVerification.Result?
    }

    private func runVerification(
        endpoint: String,
        requested: RelayRequestedConfig,
        chosenTransport: RelayTransport?,
        modelID: String,
        secret: String,
        service: OpenAIService
    ) async throws -> RelayAddVerification.Result {
        let ping = ping
        let family = family
        return try await RelayAddVerification.run(
            endpoint: endpoint,
            requested: requested,
            // Selected protocol: send once, no probing, and do not store a protocol on the model; auto: follow the candidate rules (no catalog info).
            userChosenTransport: chosenTransport,
            modelID: modelID,
            supportedEndpointTypes: nil,
            family: { await family(modelID) },
            ping: { routed, model in
                if let ping {
                    try await ping(secret, endpoint, model, routed)
                } else {
                    _ = try await service.pingRelay(
                        apiKey: secret,
                        baseURL: endpoint,
                        modelID: model,
                        relayRequested: routed
                    )
                }
            }
        )
    }

    /// "Save anyway (unverified)" on the failure card: the only exit that stores an unverified connection. It sends no further request.
    @discardableResult
    func saveUnverified(
        appState: AppState,
        entryPoint: ProviderSetupEntryPoint,
        onWillComplete: () -> Void = {}
    ) -> Bool {
        guard !isCompleted else { return false }
        guard !isValidating, let pending = currentFailure else {
            // The input has changed since: the old draft is invalidated and the card is dismissed with it.
            failure = nil
            return false
        }
        let provider = persist(
            appState: appState,
            endpoint: pending.endpoint,
            requested: pending.requested,
            // Store only the stable key in state (the same one as the edit-connection page's unverified save), not free text in the current language.
            connectionState: .issue(ProviderIssueMessage.unverifiedConnectionKey),
            modelOutcome: nil
        )
        failure = nil
        // Put the reason into a one-time notice on the detail page so it does not flash by on this page that is about to be left.
        appState.providerDetailNotice = ProviderDetailNotice(
            providerID: provider.id,
            kind: .unverifiedSave(pending.reason)
        )
        onWillComplete()
        appState.selectedTab = .providers
        appState.navigation.path = [relaySetupCompletionRoute(for: provider)]
        return true
    }

    // MARK: Persistence

    private func persist(
        appState: AppState,
        endpoint: String,
        requested: RelayRequestedConfig,
        connectionState: ProviderConnectionState,
        modelOutcome: RelayModelProbe.Outcome?
    ) -> Provider {
        isCompleted = true
        let manager = appState.providerManager
        let sampleModelID = requested.modelID ?? trimmedModelID
        let primary = quick.keys[0]
        var provider = manager.registerRelay(
            name: connectionName.trimmingCharacters(in: .whitespacesAndNewlines),
            endpoint: endpoint,
            apiKey: primary.trimmedSecret,
            relayRequested: requested,
            preferredModelID: sampleModelID,
            connectionState: connectionState
        )
        // There is no kind layer: relayKind is just a display value derived from the protocol.
        provider.relayKind = RelayKind(transport: requested.transport)
        // The verification model lives only in the in-memory draft; the persisted relayRequested.modelID is always empty.
        provider.relayRequested = requested.withoutModelID
        // The other keys are attached the way the quick path does it; no check ran, so the per-key lister and status are not written.
        let extras = quick.keys.dropFirst().filter { !$0.trimmedSecret.isEmpty }
        if !extras.isEmpty {
            for key in extras {
                if let next = RelayKeyBinding.apply(
                    .add(id: key.id, name: key.trimmedName, apiKey: key.trimmedSecret),
                    to: provider
                ) {
                    provider = next
                }
            }
            if let name = primary.trimmedName,
               let renamed = RelayKeyBinding.apply(.rename(id: primary.id, name: name), to: provider) {
                provider = renamed
            }
        }
        manager.updateProvider(provider)

        _ = manager.ensureModelEnabledAsDefault(providerID: provider.id, modelID: sampleModelID)
        if let modelOutcome, var refreshed = manager.provider(for: provider.id) {
            RelayModelProbe.apply(modelOutcome, modelID: sampleModelID, to: &refreshed)
            manager.updateProvider(refreshed)
        }
        return manager.provider(for: provider.id) ?? provider
    }

    /// The failure card reuses the edit-connection page's construction and redaction; a sentence "the connection has not been saved yet" follows the reason.
    /// `reason` is the localized reason on the card itself (without "not saved yet"), used for the detail page's one-time notice:
    /// `ProviderServiceError` is not `LocalizedError`, so `localizedDescription` would only yield the system fallback in English.
    private func failurePresentation(for error: Error) -> (card: OriveoError, reason: String) {
        var card = RelayEditFailurePresentation.error(
            from: error,
            // Errors often echo the full request: none of this page's keys, header and query parameter values, or the custom User-Agent may appear in the details.
            sensitiveMaterial: quick.keys.map(\.secret) + headers.map(\.value) + queryParams.map(\.value)
                + [customUserAgent]
        )
        let reason = card.message
        card.message += "\n" + L10n.tr(RelayManualSetupBoardModel.notSavedKey, table: .providers)
        return (card, reason)
    }
}
