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
    /// The verification sample resolved by the connector (first catalog entry): used only to compare connection identity and to persist; there is no input slot for it.
    @State private var modelID = ""
    @State private var apiKey = ""
    @State private var errorMessage: String?
    @State private var recoveryAction: LocalRecoveryButton?
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
    /// Connection-level channel. When the fingerprint recognizes the engine it supplies the channel; with a manual pick only llama.cpp has a second one (native).
    @State private var channel: RelayTransport = .openaiChatCompletions
    /// Whether the manual engine / channel picker is expanded: opened from the secondary row, or automatically when the fingerprint cannot recognize the engine (generic / manual).
    @State private var showsManualPicker = false
    @State private var detectionFailure: LocalSetupBoardModel.Failure?
    @AccessibilityFocusState private var accessibilityFocus: LocalAccessibilityField?

    private var isVerificationInFlight: Bool {
        coordinator.phase == .detecting
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: OriveoTheme.Spacing.xl) {
                let board = self.board

                localQuickSetupHeader

                RelaySetupField(
                    title: L10n.tr("Engine address", table: .providers),
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
                    leadingPhosphor: .hardDrives,
                    schemePrefix: securityMode == .localHTTP || securityMode == .privateVPN ? "http" : "https",
                    trailingActionTitle: isDiscovering ? L10n.tr("Cancel") : L10n.tr("Search"),
                    trailingActionSystemImage: isDiscovering ? "xmark" : "magnifyingglass",
                    trailingActionPhosphor: isDiscovering ? .x : .scan,
                    trailingActionInSlot: true,
                    onTrailingAction: toggleDiscovery
                )
                .accessibilityFocused($accessibilityFocus, equals: .address)

                if !board.networkChips.isEmpty {
                    SetupNetworkChipRow(addresses: board.networkChips)
                } else {
                    discoveryStatus
                }

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

                if board.showsManualPicker {
                    manualEnginePicker(showsChannel: board.showsChannelPicker)
                }

                if authenticationPolicy.requiresCredential {
                    RelaySetupField(
                        title: L10n.tr("API Key", table: .providers),
                        text: apiKeyBinding,
                        placeholder: "sk-...",
                        footnote: L10n.tr("This engine requires an encrypted connection for its access token.", table: .providers),
                        isSecure: true,
                        isEnabled: !isVerificationInFlight,
                        leadingSystemImage: "key.horizontal",
                        usesQuickSetupStyle: true,
                        leadingPhosphor: .key
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

                localDetectionCard(board)

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

    private var localQuickSetupHeader: some View {
        SetupBoardHero(
            icon: .plug,
            labelKey: LocalSetupBoardModel.heroLabelKey,
            titleKey: LocalSetupBoardModel.heroTitleKey,
            subtitleKey: LocalSetupBoardModel.heroSubtitleKey
        )
    }

    /// The single source of state for the setup page: the view only renders it.
    private var board: LocalSetupBoardModel {
        LocalSetupBoardModel.make(.init(
            isDetecting: isVerificationInFlight,
            summary: isConnectionVerified ? verifiedConnection.map(LocalSetupBoardModel.Summary.make) : nil,
            failure: detectionFailure,
            engine: engine,
            showsManualPicker: showsManualPicker,
            discoveredAddresses: discoveredAddresses,
            canAct: canConnect
        ))
    }

    private var discoveredAddresses: [String] {
        if case .candidate(let address) = discoveryPhase { return [address] }
        return []
    }

    /// Manual pick: the existing engine menu plus the llama.cpp channel.
    private func manualEnginePicker(showsChannel: Bool) -> some View {
        VStack(alignment: .leading, spacing: OriveoTheme.Spacing.lg) {
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

            if showsChannel {
                RelaySetupMenuField(
                    title: L10n.tr(LocalSetupBoardModel.channelTileKey, table: .providers),
                    selection: channelBinding,
                    options: LocalEngineChannelCandidates.candidates(engineProfile: engine.rawValue).map {
                        .init(id: $0.rawValue, title: relayTransportLabel($0))
                    },
                    footnote: nil,
                    isEnabled: !isVerificationInFlight,
                    leadingSystemImage: "arrow.left.arrow.right",
                    leadingPhosphor: .slidersHorizontal
                )
            }
        }
    }

    @ViewBuilder
    private func localDetectionCard(_ board: LocalSetupBoardModel) -> some View {
        switch board.card {
        case .hidden:
            EmptyView()
        case .detecting:
            SetupDetectionCardSurface(tone: .progress) {
                SetupDetectionHeadline(
                    icon: nil,
                    tint: OriveoTheme.Palette.primary,
                    title: L10n.tr(SetupPrimaryButton.detecting.titleKey, table: .providers),
                    showsProgress: true
                )
            }
        case .succeeded:
            if let summary = board.summary {
                SetupDetectionCardSurface(tone: .success) {
                    SetupDetectionHeadline(
                        icon: .checkCircle,
                        tint: OriveoTheme.Palette.success,
                        title: String(
                            format: L10n.tr(LocalSetupBoardModel.recognizedKey, table: .providers),
                            Self.displayName(for: summary.engine),
                            summary.modelCount
                        )
                    )
                    LocalDetectionTiles(summary: summary)
                }
            }
        case .failed:
            // A connection failure keeps using the existing failure row below; this card only draws "engine not recognized".
            if board.failure == .unrecognized {
                SetupDetectionCardSurface(tone: .warning) {
                    SetupDetectionHeadline(
                        icon: .warningCircle,
                        tint: OriveoTheme.Palette.warning,
                        title: L10n.tr(LocalSetupBoardModel.unrecognizedTitleKey, table: .providers),
                        detail: L10n.tr(LocalSetupBoardModel.unrecognizedBodyKey, table: .providers)
                    )
                }
            }
        }
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
            let board = self.board
            VStack(spacing: OriveoTheme.Spacing.sm) {
                Button {
                    connect()
                } label: {
                    HStack(spacing: OriveoTheme.Spacing.sm) {
                        if board.primaryButton.showsProgress {
                            ProgressView()
                                .controlSize(.small)
                        } else if board.primaryButton == .connectAndSave {
                            PhosphorIcon.check.image(.regular)
                                .resizable()
                                .renderingMode(.template)
                                .scaledToFit()
                                .frame(width: 18, height: 18)
                                .accessibilityHidden(true)
                        }
                        Text(L10n.tr(board.primaryButton.titleKey, table: .providers))
                    }
                }
                .buttonStyle(RelaySetupPrimaryButtonStyle())
                .disabled(!board.isPrimaryEnabled)
                .opacity(board.isPrimaryEnabled || board.primaryButton.showsProgress ? 1 : 0.48)
                .accessibilityHint(connectionBlockReason ?? "")
                .accessibilityFocused($accessibilityFocus, equals: .primaryAction)

                SetupBoardSecondaryRow(
                    icon: .slidersHorizontal,
                    titleKey: LocalSetupBoardModel.secondaryActionKey,
                    isEnabled: !isVerificationInFlight
                ) {
                    withAnimation(.snappy(duration: 0.18)) {
                        showsManualPicker.toggle()
                    }
                    if showsManualPicker { accessibilityFocus = .engine }
                }
            }
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
            .ignoresSafeArea(edges: [.bottom, .horizontal])
        }
    }

    private static let bottomFade = Color.dynamic(light: 0xF6F5FA, dark: \.bg)

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
        detectionFailure = nil
        if LocalSetupDetectRoute.skipsFingerprint(showsManualPicker: showsManualPicker) {
            startConnection(address: writeback.endpoint)
        } else {
            detectEngine(address: writeback.endpoint)
        }
    }

    /// "Detect" first identifies the engine (five read-only GETs); if recognized it connects with that engine and channel,
    /// otherwise it falls back to the manual picker. A fingerprint is not verification evidence: the attempt carries no
    /// identity, and once the engine is recognized `startConnection` opens a new attempt with it.
    private func detectEngine(address: String) {
        let revision = networkRevisionMonitor.revision
        let mode = securityMode
        let attempt = coordinator.beginVerification(for: .local)
        let fingerprintTask = Task {
            let outcome = await LocalEngineConnector.fingerprint(endpoint: address, securityMode: mode)
            guard !Task.isCancelled,
                  coordinator.isCurrent(attempt),
                  networkRevisionMonitor.revision == revision else { return }
            switch LocalSetupDetectRoute.route(for: outcome) {
            case .connect(let detected, let detectedChannel):
                engine = detected
                channel = detectedChannel
                startConnection(address: address)
            case .unrecognized:
                guard coordinator.acceptFailure(for: attempt) else { return }
                detectionFailure = .unrecognized
                withAnimation(.snappy(duration: 0.18)) { showsManualPicker = true }
            }
        }
        coordinator.registerCancellation(for: attempt) { fingerprintTask.cancel() }
    }

    private func startConnection(address: String) {
        let selectedChannel = channel
        let draft = LocalConnectionDraft(
            engine: engine,
            endpoint: address,
            securityMode: securityMode,
            // There is no model slot: the connector takes the first catalog entry as the verification sample.
            modelID: "",
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
                            modelHint: nil,
                            apiKey: draft.apiKey,
                            certificateFingerprint: nil,
                            channel: selectedChannel
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
                detectionFailure = .connection
                showsLocalNetworkSettings = (error as? LocalEngineConnectionError) == .localNetworkDenied
                recoveryAction = (error as? LocalEngineConnectionError).flatMap { LocalRecoveryButton(.action(for: $0)) }
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
        detectionFailure = nil
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

    private func recoveryTitle(for action: LocalRecoveryButton) -> String {
        switch action {
        case .editAddress: L10n.tr("Engine address", table: .providers)
        case .chooseEngine: L10n.tr("Engine", table: .providers)
        case .openSettings: L10n.tr("Settings")
        case .retry: L10n.tr("Retry")
        }
    }

    private func performRecovery(_ action: LocalRecoveryButton) {
        switch action {
        case .openSettings:
            openAppSettings()
        case .retry:
            connect()
        case .editAddress:
            errorMessage = nil
            recoveryAction = nil
            accessibilityFocus = .address
        case .chooseEngine:
            errorMessage = nil
            recoveryAction = nil
            accessibilityFocus = .engine
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
            channel = next.defaultTransport
            securityMode = Self.defaultSecurityMode(for: next)
            if next != .openwebui { apiKey = "" }
            errorMessage = nil
            recoveryAction = nil
            showsLocalNetworkSettings = false
        })
    }

    private var channelBinding: Binding<String> {
        Binding(get: { channel.rawValue }, set: { rawValue in
            guard let next = RelayTransport(rawValue: rawValue), next != channel else { return }
            invalidateConnectionState(clearDiscovery: false)
            channel = next
            errorMessage = nil
            recoveryAction = nil
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
    case primaryAction
}

/// Recovery buttons on the error row: only actions that have a landing spot on this page. "Switch model" actions
/// (no models, context too long) went away with the model slot, so those errors show the message without a button.
enum LocalRecoveryButton: Equatable {
    case editAddress
    case chooseEngine
    case retry
    case openSettings

    init?(_ action: LocalConnectionRecoveryAction) {
        switch action {
        case .editAddress: self = .editAddress
        case .chooseEngine: self = .chooseEngine
        case .waitAndRetry, .startEngine, .freeMemory: self = .retry
        case .openSettings: self = .openSettings
        case .chooseModel, .shortenContext: return nil
        }
    }
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
