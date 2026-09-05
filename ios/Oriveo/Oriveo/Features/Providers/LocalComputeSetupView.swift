import CryptoKit
import SwiftUI
import UIKit

struct LocalComputeSetupView: View {
    let entryPoint: ProviderSetupEntryPoint
    /// The Local compute entry fixes the scenario before this view is created. The coordinator
    /// remains shared with Relay so connection evidence keeps one commit gate.
    let coordinator: CustomLLMSetupCoordinator
    let onCompleted: (Provider) -> Void

    init(
        entryPoint: ProviderSetupEntryPoint,
        coordinator: CustomLLMSetupCoordinator,
        onCompleted: @escaping (Provider) -> Void
    ) {
        self.entryPoint = entryPoint
        self.coordinator = coordinator
        self.onCompleted = onCompleted
    }

    @Environment(AppState.self) private var appState
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var engine: LocalEngineKind = .ollama
    @State private var endpoint = ""
    /// Engine templates suggest an address but never authorize a weaker transport.
    @State private var securityMode: RelayConnectionSecurityMode = .remoteHTTPS
    @State private var showsSecurityModePicker = false
    @State private var endpointNormalizationHighlightToken = 0
    @State private var modelID = ""
    @State private var apiKey = ""
    @State private var errorMessage: String?
    @State private var connectionAttempts = 0
    @State private var submissionWasFirstProvider = false
    @State private var recoveryAction: LocalConnectionRecoveryAction?
    @State private var showsLocalNetworkSettings = false
    @State private var isDiscovering = false
    @State private var discoveryPhase: LocalDiscoveryPhase = .idle
    @State private var discovery = LocalEngineDiscoverySession()
    @State private var discoveryToken: UUID?
    @State private var discoveryValidationTasks: [UUID: Task<Void, Never>] = [:]
    @State private var pendingDiscoveryValidations = 0
    @State private var discoveryDidComplete = false
    @State private var terminalDiscoveryState: LocalEngineDiscoveryState?
    @State private var networkRevisionMonitor = LocalNetworkRevisionMonitor()
    @State private var verifiedConnection: LocalEngineConnection?
    @State private var verifiedEvidence: CustomLLMConnectionEvidence?
    @AccessibilityFocusState private var accessibilityFocus: LocalAccessibilityField?

    private var isVerificationInFlight: Bool {
        coordinator.phase == .detecting
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: OriveoTheme.Spacing.xl) {
                localQuickSetupHeader

                RelaySetupMenuField(
                    title: L10n.tr("Engine", table: .providers),
                    selection: engineIDBinding,
                    options: LocalEngineKind.allCases.map {
                        .init(id: $0.rawValue, title: Self.displayName(for: $0))
                    },
                    footnote: nil,
                    isEnabled: !isVerificationInFlight,
                    leadingSystemImage: "cpu"
                )
                .accessibilityFocused($accessibilityFocus, equals: .engine)

                RelaySetupField(
                    title: L10n.tr("Request URL", table: .providers),
                    text: endpointBinding,
                    placeholder: "192.168.1.20:11434",
                    footnote: L10n.tr("localhost means this phone, not your computer.", table: .providers),
                    isSecure: false,
                    isEnabled: !isVerificationInFlight,
                    leadingSystemImage: "link",
                    usesQuickSetupStyle: true,
                    highlightToken: endpointNormalizationHighlightToken,
                    keyboardType: .URL,
                    forcesLeftToRightValue: true,
                    trailingActionTitle: isDiscovering ? L10n.tr("Cancel") : L10n.tr("Search"),
                    trailingActionSystemImage: isDiscovering ? "xmark" : "magnifyingglass",
                    onTrailingAction: toggleDiscovery
                )
                .accessibilityFocused($accessibilityFocus, equals: .address)

                discoveryStatus

                RelaySecurityModeSummaryRow(
                    securityMode: securityMode,
                    isDisabled: isVerificationInFlight,
                    onChange: { showsSecurityModePicker = true }
                )
                .background {
                    RoundedRectangle(cornerRadius: OriveoTheme.Radius.inset, style: .continuous)
                        .fill(OriveoTheme.Palette.primarySoft.opacity(0.62))
                }
                .accessibilityHint(RelaySecurityModeSummaryRow.detail(for: securityMode))
                .accessibilityFocused($accessibilityFocus, equals: .security)

                if authenticationPolicy.requiresCredential {
                    RelaySetupField(
                        title: L10n.tr("API Key", table: .providers),
                        text: apiKeyBinding,
                        placeholder: "sk-...",
                        footnote: L10n.tr("This engine requires an encrypted connection for its access token.", table: .providers),
                        isSecure: true,
                        isEnabled: !isVerificationInFlight,
                        leadingSystemImage: "key.horizontal",
                        usesQuickSetupStyle: true
                    )
                    .accessibilityFocused($accessibilityFocus, equals: .authentication)
                } else {
                    Label(
                        L10n.tr("No authentication. No credentials are sent.", table: .providers),
                        systemImage: "lock.open"
                    )
                    .font(OriveoTheme.Typography.footnote)
                    .foregroundStyle(OriveoTheme.Palette.textSecondary)
                }

                if let connection = verifiedConnection, !connection.modelIDs.isEmpty {
                    RelaySetupMenuField(
                        title: L10n.tr("Model", table: .providers),
                        selection: modelBinding,
                        options: connection.modelIDs.map { .init(id: $0, title: $0) },
                        footnote: String(
                            format: L10n.tr("Found %d model(s) in the catalog.", table: .providers),
                            connection.modelIDs.count
                        ),
                        isEnabled: !isVerificationInFlight,
                        leadingSystemImage: "sparkles",
                        forcesLeftToRightValue: true
                    )
                    .accessibilityFocused($accessibilityFocus, equals: .model)
                } else {
                    RelaySetupField(
                        title: L10n.tr("Model (optional)", table: .providers),
                        text: modelBinding,
                        placeholder: "llama3.2",
                        footnote: nil,
                        isSecure: false,
                        isEnabled: !isVerificationInFlight,
                        leadingSystemImage: "sparkles",
                        usesQuickSetupStyle: true,
                        forcesLeftToRightValue: true
                    )
                    .accessibilityFocused($accessibilityFocus, equals: .model)
                }

                if let errorMessage {
                    RelaySetupStatusRow(
                        message: errorMessage,
                        systemImage: "exclamationmark.triangle.fill",
                        tone: .warning,
                        actionTitle: showsLocalNetworkSettings
                            ? L10n.tr("Settings")
                            : recoveryAction.map(recoveryTitle),
                        action: showsLocalNetworkSettings
                            ? openAppSettings
                            : recoveryAction.map { action in { performRecovery(action) } }
                    )
                }

                if isConnectionVerified {
                    RelaySetupStatusRow(
                        message: L10n.tr("Connection verified.", table: .providers),
                        systemImage: "checkmark.circle.fill",
                        tone: .success
                    )
                }
            }
            .padding(OriveoTheme.Spacing.xl)
            .padding(.bottom, OriveoTheme.Spacing.lg)
            .frame(maxWidth: 560, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom) {
            localActionBar
        }
        .sheet(isPresented: $showsSecurityModePicker) {
            RelaySecurityModePickerSheet(
                endpoint: endpoint,
                currentMode: securityMode,
                hasCredentialMaterial: RelaySecurityModeSelection.hasCredentialMaterial(
                    apiKey: apiKey,
                    authMode: engine == .openwebui ? .bearer : .none,
                    headers: [],
                    queryParams: []
                ),
                allowedModes: authenticationPolicy.allowedSecurityModes,
                onSelect: applySecurityMode
            )
        }
        .onAppear { networkRevisionMonitor.start() }
        .onChange(of: networkRevisionMonitor.revision) { _, _ in
            invalidateConnectionState(clearDiscovery: true)
        }
        .onChange(of: discoveryPhase) { _, phase in
            announceDiscoveryPhase(phase)
        }
        .onChange(of: coordinator.phase) { _, phase in
            guard phase == .detecting else { return }
            UIAccessibility.post(
                notification: .announcement,
                argument: L10n.tr("Connecting...", table: .providers)
            )
        }
        .onChange(of: errorMessage) { _, message in
            guard let message else { return }
            UIAccessibility.post(notification: .announcement, argument: message)
        }
        .onChange(of: isConnectionVerified) { _, isVerified in
            guard isVerified else { return }
            UIAccessibility.post(
                notification: .announcement,
                argument: L10n.tr("Connection verified.", table: .providers)
            )
            accessibilityFocus = .primaryAction
        }
        .onChange(of: scenePhase) { _, nextPhase in
            guard nextPhase != .active else { return }
            invalidateConnectionState(clearDiscovery: true)
        }
        .onDisappear {
            networkRevisionMonitor.stop()
            invalidateConnectionState(clearDiscovery: true)
        }
    }

    @ViewBuilder
    private var localQuickSetupHeader: some View {
        VStack(alignment: .leading, spacing: OriveoTheme.Spacing.sm) {
            Label(L10n.tr("Quick Setup", table: .providers), systemImage: "wand.and.stars")
                .font(OriveoTheme.Typography.footnote.weight(.semibold))
                .foregroundStyle(OriveoTheme.Palette.primary)

            Text(L10n.tr("Connect a relay or local engine", table: .providers))
                .font(OriveoTheme.Typography.hero)
                .foregroundStyle(OriveoTheme.Palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            Text(L10n.tr("Connect directly to an engine on this device or your private network.", table: .providers))
                .font(OriveoTheme.Typography.body)
                .foregroundStyle(OriveoTheme.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, OriveoTheme.Spacing.sm)
        .padding(.bottom, OriveoTheme.Spacing.xs)
    }

    @ViewBuilder
    private var discoveryStatus: some View {
        switch discoveryPhase {
        case .idle:
            EmptyView()
        case .scanning:
            RelaySetupStatusRow(
                message: L10n.tr("Search"),
                systemImage: "magnifyingglass",
                tone: .progress,
                showsProgress: true
            )
        case .checking(let address):
            RelaySetupStatusRow(
                message: address,
                systemImage: "network",
                tone: .progress,
                showsProgress: true
            )
        case .candidate(let address):
            RelaySetupStatusRow(message: address, systemImage: "network", tone: .neutral)
        case .noService:
            RelaySetupStatusRow(
                message: L10n.tr("No local models were found.", table: .providers),
                systemImage: "magnifyingglass",
                tone: .warning,
                actionTitle: L10n.tr("Retry"),
                action: toggleDiscovery
            )
        case .permissionDenied:
            RelaySetupStatusRow(
                message: L10n.tr("Allow local network access in Settings.", table: .providers),
                systemImage: "gear",
                tone: .warning,
                actionTitle: L10n.tr("Settings"),
                action: openAppSettings
            )
        case .unavailable:
            RelaySetupStatusRow(
                message: L10n.tr("The local network is unavailable.", table: .providers),
                systemImage: "wifi.exclamationmark",
                tone: .warning,
                actionTitle: L10n.tr("Retry"),
                action: toggleDiscovery
            )
        }
    }

    private var localActionBar: some View {
        VStack(spacing: 0) {
            if let connectionBlockReason {
                Text(connectionBlockReason)
                    .font(OriveoTheme.Typography.footnote)
                    .foregroundStyle(OriveoTheme.Palette.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, OriveoTheme.Spacing.xl)
            }
            Button(
                isVerificationInFlight
                    ? L10n.tr("Connecting...", table: .providers)
                    : isConnectionVerified
                        ? L10n.tr("Connect and save", table: .providers)
                        : L10n.tr("Test connection", table: .providers)
            ) {
                connect()
            }
            .buttonStyle(RelaySetupPrimaryButtonStyle())
            .disabled(!canConnect)
            .opacity(canConnect ? 1 : 0.48)
            .accessibilityHint(connectionBlockReason ?? "")
            .accessibilityFocused($accessibilityFocus, equals: .primaryAction)
            .padding(.horizontal, OriveoTheme.Spacing.xl)
            .padding(.top, OriveoTheme.Spacing.xl)
            .padding(.bottom, OriveoTheme.Spacing.md)
            .frame(maxWidth: 608)
            .frame(maxWidth: .infinity)
        }
        .background {
            LinearGradient(
                colors: [Self.bottomFade.opacity(0), Self.bottomFade.opacity(0.92), Self.bottomFade],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea(edges: .bottom)
        }
    }

    private static let bottomFade = Color.dynamic(light: 0xF6F5FA, dark: 0x10141C)

    private var canConnect: Bool {
        let hasCredential = !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return !isVerificationInFlight
            && !endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && authenticationPolicy.permits(securityMode: securityMode, hasCredential: hasCredential)
    }

    private var isConnectionVerified: Bool {
        guard let evidence = verifiedEvidence, verifiedConnection != nil else { return false }
        return coordinator.canCommit(evidence, matching: currentIdentity())
    }

    private func toggleDiscovery() {
        guard !isVerificationInFlight else { return }
        if isDiscovering {
            cancelDiscovery(resetPhase: true)
            return
        }
        invalidateConnectionState(clearDiscovery: true)
        errorMessage = nil
        recoveryAction = nil
        isDiscovering = true
        discoveryPhase = .scanning
        discoveryDidComplete = false
        terminalDiscoveryState = nil
        pendingDiscoveryValidations = 0
        let token = UUID()
        discoveryToken = token
        discovery.start(
            knownHosts: endpointHost.map { [$0] } ?? [],
            onResult: { result in
                Task { @MainActor in
                    validateDiscoveryCandidate(result, token: token)
                }
            },
            onState: { state in
                Task { @MainActor in
                    guard discoveryToken == token, isDiscovering else { return }
                    terminalDiscoveryState = state
                    if state == .permissionDenied {
                        finishDiscoveryIfPossible(force: true)
                    }
                }
            },
            onComplete: {
                Task { @MainActor in
                    guard discoveryToken == token, isDiscovering else { return }
                    discoveryDidComplete = true
                    finishDiscoveryIfPossible(force: false)
                }
            }
        )
    }

    nonisolated private static func displayName(for engine: LocalEngineKind) -> String {
        switch engine {
        case .llamacpp: return "llama.cpp"
        case .ollama: return "Ollama"
        case .lmstudio: return "LM Studio"
        case .vllm: return "vLLM"
        case .openwebui: return "Open WebUI"
        }
    }

    private func connect() {
        connectionAttempts += 1
        submissionWasFirstProvider = appState.providers.isEmpty
        guard !isVerificationInFlight else { return }
        if let connection = verifiedConnection,
           let evidence = verifiedEvidence,
           coordinator.canCommit(evidence, matching: currentIdentity()) {
            saveVerifiedConnection(connection)
            return
        }
        guard let writeback = RelaySecurityModeSelection.endpointWriteback(
            endpoint.trimmingCharacters(in: .whitespacesAndNewlines),
            securityMode: securityMode
        ) else {
            errorMessage = L10n.tr(RelayEndpointPolicy.httpsRequiredMessageKey, table: .providers)
            recoveryAction = .editAddress
            return
        }
        if writeback.didChange {
            endpoint = writeback.endpoint
            endpointNormalizationHighlightToken &+= 1
        }
        errorMessage = nil
        recoveryAction = nil
        showsLocalNetworkSettings = false
        let draft = LocalConnectionDraft(
            engine: engine,
            endpoint: writeback.endpoint,
            securityMode: securityMode,
            modelID: modelID.trimmingCharacters(in: .whitespacesAndNewlines),
            apiKey: apiKey,
            networkRevision: networkRevisionMonitor.revision
        )
        let attemptIdentity = draft.identity(selectedModel: draft.modelID)
        let attempt = coordinator.beginVerification(for: .local, identity: attemptIdentity)
        let connectionTask = Task {
            do {
                let candidates = [Self.manualCandidate(
                    endpoint: draft.endpoint,
                    selectedSecurityMode: draft.securityMode
                )]
                var connection: LocalEngineConnection?
                var lastError: Error?
                for candidate in candidates {
                    try Task.checkCancellation()
                    do {
                        connection = try await LocalEngineConnector.connect(
                            engine: draft.engine,
                            endpoint: candidate.endpoint,
                            securityMode: candidate.securityMode,
                            modelHint: draft.modelID,
                            apiKey: draft.apiKey,
                            certificateFingerprint: nil
                        )
                        break
                    } catch {
                        lastError = error
                    }
                }
                guard let connection else { throw lastError ?? LocalEngineConnectionError.invalidEndpoint }
                try Task.checkCancellation()
                guard coordinator.isCurrent(attempt),
                      networkRevisionMonitor.revision == draft.networkRevision else {
                    return
                }
                let verifiedIdentity = draft.identity(
                    endpoint: connection.endpoint,
                    selectedModel: connection.selectedModelID
                )
                let evidence = CustomLLMConnectionEvidence.verified(attempt, identity: verifiedIdentity)
                guard coordinator.acceptVerified(evidence) else { return }
                // Write the exact production-resolved values back before enabling persistence.
                endpoint = connection.endpoint
                modelID = connection.selectedModelID
                guard coordinator.canCommit(evidence, matching: currentIdentity()) else {
                    coordinator.invalidate()
                    return
                }
                verifiedConnection = connection
                verifiedEvidence = evidence
            } catch is CancellationError {
                return
            } catch {
                guard coordinator.acceptFailure(for: attempt) else { return }
                showsLocalNetworkSettings = (error as? LocalEngineConnectionError) == .localNetworkDenied
                recoveryAction = (error as? LocalEngineConnectionError).map(LocalConnectionRecoveryAction.action)
                errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
        coordinator.registerCancellation(for: attempt) { connectionTask.cancel() }
    }

    private func saveVerifiedConnection(_ connection: LocalEngineConnection) {
        guard let evidence = verifiedEvidence,
              coordinator.canCommit(evidence, matching: currentIdentity()) else {
            invalidateConnectionState(clearDiscovery: false)
            return
        }
        var provider = appState.providerManager.registerRelay(
            name: engineDisplayName,
            endpoint: connection.endpoint,
            apiKey: apiKey,
            relayRequested: connection.requested,
            catalogModelIDs: connection.modelIDs,
            preferredModelID: connection.selectedModelID,
            runtimeMetadata: connection.runtimeMetadata
        )
        provider.relayKind = .openaiCompatible
        appState.providerManager.updateProvider(provider)
        verifiedConnection = nil
        verifiedEvidence = nil
        onCompleted(provider)
    }

    private func invalidateConnectionState(clearDiscovery: Bool) {
        coordinator.invalidate()
        cancelDiscovery(resetPhase: clearDiscovery)
        verifiedConnection = nil
        verifiedEvidence = nil
    }

    nonisolated static func defaultSecurityMode(for engine: LocalEngineKind) -> RelayConnectionSecurityMode {
        _ = engine
        return .remoteHTTPS
    }

    nonisolated static func manualCandidate(
        endpoint: String,
        selectedSecurityMode: RelayConnectionSecurityMode
    ) -> LocalPairingCandidate {
        LocalPairingCandidate(endpoint: endpoint, securityMode: selectedSecurityMode)
    }

    nonisolated struct PairingSecurityDecision: Equatable {
        let appliedMode: RelayConnectionSecurityMode?
        let candidates: [LocalPairingCandidate]
        let keepsFingerprint: Bool
        let allowsImmediateConnect: Bool
        let requiresExplicitWeakConfirmation: Bool
    }

    nonisolated static func pairingSecurityDecision(
        endpoint: String,
        payloadMode: RelayConnectionSecurityMode,
        candidates: [LocalPairingCandidate],
        fingerprint: String?
    ) -> PairingSecurityDecision {
        let hasFingerprint = fingerprint?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty == false

        if payloadMode == .tofuHTTPS, hasFingerprint {
            let tofuCandidates = candidates.filter { $0.securityMode == .tofuHTTPS }
            return PairingSecurityDecision(
                appliedMode: .tofuHTTPS,
                candidates: tofuCandidates,
                keepsFingerprint: true,
                allowsImmediateConnect: !tofuCandidates.isEmpty,
                requiresExplicitWeakConfirmation: false
            )
        }

        if payloadMode == .remoteHTTPS {
            var remoteCandidates = candidates.filter { $0.securityMode == .remoteHTTPS }
            if remoteCandidates.isEmpty {
                remoteCandidates = [LocalPairingCandidate(endpoint: endpoint, securityMode: .remoteHTTPS)]
            }
            return PairingSecurityDecision(
                appliedMode: .remoteHTTPS,
                candidates: remoteCandidates,
                keepsFingerprint: false,
                allowsImmediateConnect: true,
                requiresExplicitWeakConfirmation: false
            )
        }

        if payloadMode == .localHTTP || payloadMode == .privateVPN {
            return PairingSecurityDecision(
                appliedMode: nil,
                candidates: [],
                keepsFingerprint: false,
                allowsImmediateConnect: false,
                requiresExplicitWeakConfirmation: true
            )
        }

        return PairingSecurityDecision(
            appliedMode: nil,
            candidates: [],
            keepsFingerprint: false,
            allowsImmediateConnect: false,
            requiresExplicitWeakConfirmation: false
        )
    }

    @MainActor
    private func applySecurityMode(_ nextMode: RelayConnectionSecurityMode) {
        guard RelaySecurityModeSelection.selectableModes.contains(nextMode),
              authenticationPolicy.allowedSecurityModes.contains(nextMode),
              nextMode != securityMode else {
            return
        }
        invalidateConnectionState(clearDiscovery: true)
        if nextMode == .localHTTP || nextMode == .privateVPN {
            apiKey = ""
        }
        securityMode = nextMode
        if let writeback = RelaySecurityModeSelection.endpointWriteback(
            endpoint,
            securityMode: nextMode
        ), writeback.didChange {
            endpoint = writeback.endpoint
            endpointNormalizationHighlightToken &+= 1
        }
        errorMessage = nil
        recoveryAction = nil
    }

    private var engineDisplayName: String {
        switch engine {
        case .llamacpp: return "llama.cpp"
        case .ollama: return "Ollama"
        case .lmstudio: return "LM Studio"
        case .vllm: return "vLLM"
        case .openwebui: return "Open WebUI"
        }
    }

    private var authenticationPolicy: LocalEngineAuthenticationPolicy {
        .policy(for: engine)
    }

    private var connectionBlockReason: String? {
        if endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return L10n.tr("Enter a request URL.", table: .providers)
        }
        if authenticationPolicy.requiresCredential,
           apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return L10n.tr("Enter the access token required by this engine.", table: .providers)
        }
        if !authenticationPolicy.allowedSecurityModes.contains(securityMode) {
            return L10n.tr("This engine requires an encrypted connection for its access token.", table: .providers)
        }
        return nil
    }

    private func recoveryTitle(for action: LocalConnectionRecoveryAction) -> String {
        switch action {
        case .editAddress: L10n.tr("Request URL", table: .providers)
        case .chooseEngine: L10n.tr("Engine", table: .providers)
        case .chooseModel: L10n.tr("Model", table: .providers)
        case .openSettings: L10n.tr("Settings")
        case .waitAndRetry, .startEngine, .freeMemory, .shortenContext: L10n.tr("Retry")
        }
    }

    private func performRecovery(_ action: LocalConnectionRecoveryAction) {
        switch action {
        case .openSettings:
            openAppSettings()
        case .waitAndRetry, .startEngine, .freeMemory:
            connect()
        case .editAddress:
            errorMessage = nil
            recoveryAction = nil
            accessibilityFocus = .address
        case .chooseEngine:
            errorMessage = nil
            recoveryAction = nil
            accessibilityFocus = .engine
        case .chooseModel, .shortenContext:
            errorMessage = nil
            recoveryAction = nil
            accessibilityFocus = .model
        }
    }

    private func openAppSettings() {
        guard let settingsURL = URL(string: UIApplication.openSettingsURLString) else { return }
        openURL(settingsURL)
    }

    private func announceDiscoveryPhase(_ phase: LocalDiscoveryPhase) {
        let message: String?
        switch phase {
        case .idle:
            message = nil
        case .scanning:
            message = L10n.tr("Search")
        case .checking:
            message = L10n.tr("Detecting...", table: .providers)
        case .candidate:
            message = L10n.tr("Connection has not been verified.", table: .providers)
        case .noService:
            message = L10n.tr("No local models were found.", table: .providers)
        case .permissionDenied:
            message = L10n.tr("Allow local network access in Settings.", table: .providers)
        case .unavailable:
            message = L10n.tr("The local network is unavailable.", table: .providers)
        }
        guard let message else { return }
        UIAccessibility.post(notification: .announcement, argument: message)
    }

    private var endpointHost: String? {
        URL(string: endpoint)?.host.flatMap { ["localhost", "127.0.0.1"].contains($0) ? nil : $0 }
    }

    private var engineIDBinding: Binding<String> {
        Binding(get: { engine.rawValue }, set: { rawValue in
            guard let next = LocalEngineKind(rawValue: rawValue) else { return }
            guard next != engine else { return }
            invalidateConnectionState(clearDiscovery: true)
            engine = next
            securityMode = Self.defaultSecurityMode(for: next)
            if next != .openwebui { apiKey = "" }
            errorMessage = nil
            recoveryAction = nil
            showsLocalNetworkSettings = false
        })
    }

    private var endpointBinding: Binding<String> {
        Binding(get: { endpoint }, set: { next in
            guard next != endpoint else { return }
            invalidateConnectionState(clearDiscovery: true)
            endpoint = next
            errorMessage = nil
            recoveryAction = nil
        })
    }

    private var apiKeyBinding: Binding<String> {
        Binding(get: { apiKey }, set: { next in
            guard next != apiKey else { return }
            invalidateConnectionState(clearDiscovery: true)
            apiKey = next
            errorMessage = nil
            recoveryAction = nil
        })
    }

    private var modelBinding: Binding<String> {
        Binding(get: { modelID }, set: { next in
            guard next != modelID else { return }
            invalidateConnectionState(clearDiscovery: false)
            modelID = next
            errorMessage = nil
            recoveryAction = nil
        })
    }

    private func currentIdentity() -> CustomLLMVerificationIdentity {
        LocalConnectionDraft(
            engine: engine,
            endpoint: endpoint,
            securityMode: securityMode,
            modelID: modelID,
            apiKey: apiKey,
            networkRevision: networkRevisionMonitor.revision
        ).identity(selectedModel: modelID)
    }

    @MainActor
    private func validateDiscoveryCandidate(_ result: LocalEngineDiscoveryResult, token: UUID) {
        guard discoveryToken == token, isDiscovering else { return }
        let validationID = UUID()
        pendingDiscoveryValidations += 1
        discoveryPhase = .checking(result.endpoint)
        let selectedEngine = engine
        let selectedMode = securityMode
        let selectedKey = apiKey
        let task = Task {
            defer {
                discoveryValidationTasks[validationID] = nil
                pendingDiscoveryValidations = max(0, pendingDiscoveryValidations - 1)
                finishDiscoveryIfPossible(force: false)
            }
            do {
                let verifiedEndpoint = try await LocalEngineConnector.verifyCandidate(
                    engine: selectedEngine,
                    endpoint: result.endpoint,
                    securityMode: selectedMode,
                    apiKey: selectedKey
                )
                guard !Task.isCancelled, discoveryToken == token, isDiscovering else { return }
                cancelDiscovery(resetPhase: false, excluding: validationID)
                endpoint = verifiedEndpoint
                discoveryPhase = .candidate(verifiedEndpoint)
            } catch let connectionError as LocalEngineConnectionError {
                guard !Task.isCancelled, discoveryToken == token, isDiscovering else { return }
                if connectionError == .localNetworkDenied {
                    terminalDiscoveryState = .permissionDenied
                    finishDiscoveryIfPossible(force: true)
                }
            } catch {
                return
            }
        }
        discoveryValidationTasks[validationID] = task
    }

    @MainActor
    private func finishDiscoveryIfPossible(force: Bool) {
        guard isDiscovering, force || (discoveryDidComplete && pendingDiscoveryValidations == 0) else { return }
        let terminal = terminalDiscoveryState ?? .noService
        cancelDiscovery(resetPhase: false)
        switch terminal {
        case .noService: discoveryPhase = .noService
        case .permissionDenied: discoveryPhase = .permissionDenied
        case .unavailable: discoveryPhase = .unavailable
        }
    }

    @MainActor
    private func cancelDiscovery(resetPhase: Bool, excluding retainedTaskID: UUID? = nil) {
        discovery.cancel()
        for (id, task) in discoveryValidationTasks where id != retainedTaskID {
            task.cancel()
        }
        if retainedTaskID == nil {
            discoveryValidationTasks = [:]
            pendingDiscoveryValidations = 0
        }
        discoveryToken = nil
        isDiscovering = false
        discoveryDidComplete = false
        terminalDiscoveryState = nil
        if resetPhase { discoveryPhase = .idle }
    }

}

private struct LocalConnectionDraft: Sendable {
    let engine: LocalEngineKind
    let endpoint: String
    let securityMode: RelayConnectionSecurityMode
    let modelID: String
    let apiKey: String
    let networkRevision: UInt

    func identity(endpoint identityEndpoint: String? = nil, selectedModel: String) -> CustomLLMVerificationIdentity {
        CustomLLMVerificationIdentity(
            method: .local,
            engineProfile: engine.rawValue,
            normalizedEndpoint: (identityEndpoint ?? endpoint).trimmingCharacters(in: .whitespacesAndNewlines),
            securityMode: securityMode,
            authFingerprint: Self.fingerprint(apiKey: apiKey),
            selectedModel: selectedModel.trimmingCharacters(in: .whitespacesAndNewlines),
            networkRevision: networkRevision
        )
    }

    private static func fingerprint(apiKey: String) -> String {
        let material = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return SHA256.hash(data: Data(material.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

private enum LocalAccessibilityField: Hashable {
    case engine
    case address
    case security
    case authentication
    case model
    case primaryAction
}

private enum LocalDiscoveryPhase: Equatable {
    case idle
    case scanning
    case checking(String)
    case candidate(String)
    case noService
    case permissionDenied
    case unavailable
}
