import SwiftUI

enum RelaySetupDiscoveryInputPolicy {
    static func permitsDiscovery(endpoint: String, apiKey: String, authMode: RelayAuthMode) -> Bool {
        guard !endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let hasCredential = RelayCredentialPolicy.hasStoredKey(apiKey)
        guard !RelayCredentialPolicy.requiresCredential(authMode: authMode) || hasCredential else { return false }
        return !hasCredential || ProviderKeyInput.isPrintableASCII(apiKey)
    }
}

func relaySetupCompletionRoute(for provider: Provider) -> AppRoute {
    if provider.allModels.isEmpty {
        return .manualModelEntry(providerID: provider.id, context: .providers)
    }

    return .providerDetail(providerID: provider.id)
}

struct RelaySetupView: View {
    let entryPoint: ProviderSetupEntryPoint

    @Environment(AppState.self) private var appState

    @State private var showsManualProfiles = false
    @State private var selectedRelayKind: RelayKind?
    @State private var name = ""
    @State private var endpoint = ""
    @State private var apiKey = ""
    @State private var defaultModelID = ""
    private let securityMode: RelayConnectionSecurityMode = .remoteHTTPS
    @State private var endpointNormalizationHighlightToken = 0

    @State private var customTransport: RelayTransport = .openaiChatCompletions
    @State private var customAuthMode: RelayAuthMode = .bearer
    @State private var customReasoningEffort: RelayReasoningEffort = .automatic
    @State private var customServiceTier: String = ""
    @State private var customStream: Bool = true
    @State private var customDisableResponseStorage: Bool = false
    @State private var customUserAgent: String = ""
    @State private var customHeaders: [RelayKeyValue] = []
    @State private var customQueryParams: [RelayKeyValue] = []
    @State private var customWebSearchToolName: RelayWebSearchToolName? = nil

    @State private var isSubmitting = false
    @State private var submitTask: Task<Void, Never>?
    @State private var setupError: OriveoError?
    @State private var probeFailureNote: String?
    @State private var isTestingConnection = false
    @State private var testConnectionResult: TestConnectionResult?
    @State private var testTask: Task<Void, Never>?
    @State private var discoveryResult: RelayDiscoveryResult?
    @State private var selectedDetectionID: String?
    @State private var verifiedDetectionID: String?
    @State private var setupCoordinator: CustomLLMSetupCoordinator

    init(
        entryPoint: ProviderSetupEntryPoint,
        initialMethod: CustomLLMConnectionMethod = .relay
    ) {
        self.entryPoint = entryPoint
        _setupCoordinator = State(initialValue: CustomLLMSetupCoordinator(method: initialMethod))
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar

            if setupCoordinator.method == .local {
                LocalComputeSetupView(
                    entryPoint: entryPoint,
                    coordinator: setupCoordinator,
                    onCompleted: completeProviderSetup
                )
            } else {
            ScrollView {
                VStack(alignment: .leading, spacing: OriveoTheme.Spacing.xl) {
                    if !showsManualProfiles {
                        quickSetupHeader

                        quickSetupForm

                        RelayFormIssueNotes(issues: formIssues)

                        if let testConnectionResult, case .success = testConnectionResult {
                            testConnectionResultRow(testConnectionResult)
                        }

                        if let automaticSetupFailureMessage {
                            automaticSetupFailureCard(automaticSetupFailureMessage)
                        }

                        if let setupError {
                            OriveoErrorCard(error: setupError) { self.setupError = nil }
                        }
                    } else if let kind = selectedRelayKind {
                        header(for: kind)

                        RelaySimpleSection(
                            name: $name,
                            endpoint: endpointInputBinding,
                            apiKey: $apiKey,
                            defaultModelID: $defaultModelID,
                            isSubmitting: isSubmitting,
                            endpointNormalizationHighlightToken: endpointNormalizationHighlightToken
                        )

                        if kind == .custom {
                            RelayAdvancedFieldsView(
                                transport: $customTransport,
                                authMode: $customAuthMode,
                                reasoningEffort: $customReasoningEffort,
                                serviceTier: $customServiceTier,
                                stream: $customStream,
                                disableResponseStorage: $customDisableResponseStorage,
                                isSubmitting: isSubmitting
                            )

                            if customTransport == .openaiResponses {
                                RelayWebSearchToolNameSection(
                                    webSearchToolName: $customWebSearchToolName,
                                    isSubmitting: isSubmitting
                                )
                            }

                            RelayAdvancedHTTPSection(
                                customUserAgent: $customUserAgent,
                                headers: $customHeaders,
                                queryParams: $customQueryParams,
                                isSubmitting: isSubmitting
                            )
                        }

                        RelayFormIssueNotes(issues: formIssues)

                        if let setupError {
                            OriveoErrorCard(error: setupError) {
                                self.setupError = nil
                            }
                        }

                        if let probeFailureNote {
                            probeFailureBanner(probeFailureNote)
                        }
                    } else {
                        RelayKindPickerView { kind in
                            withAnimation(.snappy(duration: 0.18)) {
                                selectedRelayKind = kind
                                probeFailureNote = nil
                                setupError = nil
                            }
                        }
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
                if showsRelaySaveBar {
                    saveBar
                }
            }
            }
        }
        .background(alignment: .top) { topAura }
        .oriveoScreenBackground()
        .onDisappear {
            setupCoordinator.invalidate()
            submitTask?.cancel()
            submitTask = nil
            testTask?.cancel()
            testTask = nil
        }
        .onChange(of: customTransport) { _, newTransport in
            if newTransport != .openaiResponses {
                customWebSearchToolName = nil
            }
            clearTestResult()
        }
        .onChange(of: apiKey) { _, _ in clearDiscovery() }
        .onChange(of: defaultModelID) { _, newValue in
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !discoveredModelIDs.contains(trimmed) else { return }
            clearDiscovery()
        }
    }

    @MainActor
    private func completeProviderSetup(_ provider: Provider) {
        appState.completeProviderSetup(providerID: provider.id, entryPoint: entryPoint)
    }

    @ViewBuilder
    private var topAura: some View {
        if !showsManualProfiles {
            RelayQuickSetupBackdrop()
                .frame(height: 380)
                .ignoresSafeArea(edges: [.top, .horizontal])
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var saveBar: some View {
        VStack(spacing: 0) {
            VStack(spacing: OriveoTheme.Spacing.sm) {
                if !showsManualProfiles {
                    Button {
                        beginSubmit()
                    } label: {
                        HStack(spacing: OriveoTheme.Spacing.sm) {
                            if isQuickVerificationInFlight {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: quickActionSystemImage)
                            }
                            Text(quickActionTitle)
                                .lineLimit(1)
                                .minimumScaleFactor(0.84)
                        }
                    }
                    .buttonStyle(OriveoPrimaryButtonStyle())
                    .disabled(!canQuickAction)
                    .opacity(canQuickAction ? 1 : 0.48)
                } else {
                if let testConnectionResult {
                    testConnectionResultRow(testConnectionResult)
                }

                Text(L10n.tr("Sends a probe via the same path as chat. Failures don't block save.", table: .providers))
                    .font(OriveoTheme.Typography.caption)
                    .foregroundStyle(OriveoTheme.Palette.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, alignment: .center)

                HStack(spacing: OriveoTheme.Spacing.sm) {
                    Button {
                        beginTestConnection()
                    } label: {
                        Label(testTitle, systemImage: isTestingConnection ? "arrow.triangle.2.circlepath" : "network")
                            .symbolEffect(.rotate, options: .repeating, value: isTestingConnection)
                    }
                    .buttonStyle(OriveoSecondaryButtonStyle())
                    .disabled(!canTestConnection)
                    .opacity(canTestConnection ? 1 : 0.5)

                    Button {
                        beginSubmit()
                    } label: {
                        Label(saveTitle, systemImage: isSubmitting ? "arrow.triangle.2.circlepath" : "square.and.arrow.down")
                            .symbolEffect(.rotate, options: .repeating, value: isSubmitting)
                    }
                    .buttonStyle(RelaySetupPrimaryButtonStyle())
                    .disabled(!canSubmit)
                }
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
                colors: [
                    Self.bottomFade.opacity(0),
                    Self.bottomFade.opacity(0.92),
                    Self.bottomFade,
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea(edges: .bottom)
        }
    }

    private static let bottomFade = Color.dynamic(light: 0xF6F5FA, dark: 0x10141C)

    private var isQuickVerificationInFlight: Bool {
        setupCoordinator.phase == .detecting
    }

    /// The local conditional fields own their only primary action.  This guard prevents the
    /// relay save bar from surviving a method switch and rendering a second primary button.
    private var showsRelaySaveBar: Bool {
        Self.showsRelaySaveBar(
            method: setupCoordinator.method,
            showsManualProfiles: showsManualProfiles,
            hasSelectedRelayKind: selectedRelayKind != nil
        )
    }

    nonisolated static func showsRelaySaveBar(
        method: CustomLLMConnectionMethod,
        showsManualProfiles: Bool,
        hasSelectedRelayKind: Bool
    ) -> Bool {
        method == .relay && (!showsManualProfiles || hasSelectedRelayKind)
    }

    private var quickActionTitle: String {
        if isQuickVerificationInFlight { return L10n.tr("Detecting...", table: .providers) }
        if isSelectedDetectionVerified { return L10n.tr("Connect and save", table: .providers) }
        if needsDefaultModelInput { return L10n.tr("Save and continue", table: .providers) }
        return L10n.tr("Detect connection settings", table: .providers)
    }

    private var quickActionSystemImage: String {
        if isSelectedDetectionVerified { return "checkmark.circle.fill" }
        if needsDefaultModelInput { return "square.and.arrow.down" }
        return "wand.and.stars"
    }

    private var discoveredModelIDs: [String] {
        guard let discoveryResult else { return [] }
        var seen = Set<String>()
        return discoveryResult.detections
            .flatMap(\.modelIDs)
            .filter { seen.insert($0).inserted }
    }

    private var selectedDetection: RelayDetectedConfiguration? {
        guard let discoveryResult else { return nil }
        return discoveryResult.detections.first(where: { $0.id == selectedDetectionID })
    }

    private var canQuickAction: Bool {
        canSubmit && !isQuickVerificationInFlight && submitTask == nil
    }

    private var isSelectedDetectionVerified: Bool {
        guard let selectedDetectionID,
              verifiedDetectionID == selectedDetectionID,
              setupCoordinator.evidence?.verification == .generationVerified else { return false }
        return true
    }

    private var saveTitle: String {
        isSubmitting ? L10n.tr("Saving...", table: .providers) : L10n.tr("Save")
    }

    private var testTitle: String {
        isTestingConnection ? L10n.tr("Testing...", table: .providers) : L10n.tr("Test connection", table: .providers)
    }

    private var topBar: some View {
        ZStack {
            Text(L10n.tr(
                setupCoordinator.method == .local ? "Local compute" : "Custom Relay",
                table: .providers
            ))
                .font(OriveoTheme.Typography.title3)
                .foregroundStyle(OriveoTheme.Palette.textPrimary)

            HStack {
                Button {
                    if showsManualProfiles, selectedRelayKind != nil {
                        withAnimation(.snappy(duration: 0.18)) {
                            selectedRelayKind = nil
                            probeFailureNote = nil
                            setupError = nil
                        }
                    } else if showsManualProfiles {
                        withAnimation(.snappy(duration: 0.18)) {
                            showsManualProfiles = false
                            clearDiscovery()
                        }
                    } else {
                        appState.pop()
                    }
                } label: {
                    Image(systemName: "chevron.backward")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(OriveoTheme.Palette.textPrimary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.tr("Back"))

                Spacer()
                Color.clear
                    .frame(width: 44, height: 44)
            }
        }
        .padding(.horizontal, OriveoTheme.Spacing.xl)
        .padding(.vertical, OriveoTheme.Spacing.md)
    }

    private var quickSetupHeader: some View {
        VStack(alignment: .leading, spacing: OriveoTheme.Spacing.sm) {
            Label(L10n.tr("Quick Setup", table: .providers), systemImage: "wand.and.stars")
                .font(OriveoTheme.Typography.footnote.weight(.semibold))
                .foregroundStyle(OriveoTheme.Palette.primary)

            Text(L10n.tr("Connect a relay", table: .providers))
                .font(OriveoTheme.Typography.hero)
                .foregroundStyle(OriveoTheme.Palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            Text(L10n.tr("Enter what your relay gave you. Oriveo will detect the API root, authentication style, and compatible protocol.", table: .providers))
                .font(OriveoTheme.Typography.body)
                .foregroundStyle(OriveoTheme.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, OriveoTheme.Spacing.sm)
        .padding(.bottom, OriveoTheme.Spacing.xs)
    }

    private var quickSetupForm: some View {
        VStack(alignment: .leading, spacing: OriveoTheme.Spacing.lg) {
            RelaySimpleSection(
                name: $name,
                endpoint: endpointInputBinding,
                apiKey: $apiKey,
                defaultModelID: $defaultModelID,
                isSubmitting: isSubmitting,
                showsName: false,
                endpointFootnote: L10n.tr("Paste the host, /v1 or /v1beta base URL, or a full API route. Oriveo will normalize it safely.", table: .providers),
                usesQuickSetupStyle: true,
                discoveredModelIDs: discoveredModelIDs,
                endpointNormalizationHighlightToken: endpointNormalizationHighlightToken
            )

            manualSetupEntry
        }
    }

    private var manualSetupEntry: some View {
        VStack(spacing: OriveoTheme.Spacing.lg) {
            fadingHairline

            Button {
                withAnimation(.snappy(duration: 0.18)) {
                    showsManualProfiles = true
                    selectedRelayKind = nil
                    clearDiscovery()
                }
            } label: {
                HStack(spacing: OriveoTheme.Spacing.md) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(OriveoTheme.Palette.primary)
                        .frame(width: 22)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.tr("Manual setup", table: .providers))
                            .font(OriveoTheme.Typography.caption.weight(.semibold))
                            .foregroundStyle(OriveoTheme.Palette.textPrimary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.82)

                        Text(L10n.tr("Choose a protocol manually", table: .providers))
                            .font(OriveoTheme.Typography.footnote)
                            .foregroundStyle(OriveoTheme.Palette.textSecondary)
                            .lineLimit(2)
                    }
                    .layoutPriority(1)

                    Spacer(minLength: OriveoTheme.Spacing.lg)

                    Image(systemName: "chevron.forward")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(OriveoTheme.Palette.textTertiary)
                        .accessibilityHidden(true)
                }
                .padding(.vertical, OriveoTheme.Spacing.sm)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(L10n.tr("Choose a protocol manually", table: .providers))
        }
        .padding(.top, OriveoTheme.Spacing.xs)
    }

    private var fadingHairline: some View {
        LinearGradient(
            colors: [
                .clear,
                OriveoTheme.Palette.borderStrong.opacity(0.65),
                .clear,
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
        .frame(height: 1)
        .padding(.horizontal, OriveoTheme.Spacing.lg)
    }

    private var automaticSetupFailureMessage: String? {
        if let discoveryResult, discoveryResult.detections.isEmpty {
            return discoveryFailureMessage(discoveryResult.blockingFailure)
        }
        if case .failure(let message) = testConnectionResult {
            return message
        }
        return nil
    }

    private var needsDefaultModelInput: Bool {
        guard defaultModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let discoveryResult,
              !discoveryResult.detections.isEmpty else { return false }
        return discoveryResult.detections.allSatisfy(\.modelIDs.isEmpty)
    }

    private var probeDetectedTransport: RelayTransport? {
        guard let discoveryResult,
              !discoveryResult.detections.isEmpty,
              discoveryResult.detections.allSatisfy({ $0.detectionEvidence == .generationProbe })
        else { return nil }
        return discoveryResult.detections.first?.transport
    }

    private var attemptDiagnostics: [String] {
        guard let discoveryResult else { return [] }
        return discoveryResult.attempts.map { attempt in
            let method = attempt.kind == .catalog ? "GET" : "POST"
            let path = URL(string: attempt.requestURL)?.path ?? attempt.requestURL
            let status = attempt.statusCode.map(String.init) ?? "-"
            return "\(method) \(path) → \(status)"
        }
    }

    private var upstreamDiagnostic: String? {
        guard let discoveryResult else { return nil }
        let informative = discoveryResult.attempts.filter { $0.upstreamMessage?.isEmpty == false }
        let preferred = informative.last { attempt in
            guard let status = attempt.statusCode else { return false }
            return status == 400 || status == 422
        }
        return (preferred ?? informative.last)?.upstreamMessage
    }

    private func automaticSetupFailureCard(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: OriveoTheme.Spacing.sm) {
            Label(
                L10n.tr("Could not detect this relay", table: .providers),
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(OriveoTheme.Typography.body.weight(.semibold))
            .foregroundStyle(OriveoTheme.Palette.warning)

            Text(message)
                .font(OriveoTheme.Typography.caption)
                .foregroundStyle(OriveoTheme.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if let upstreamDiagnostic {
                Text(upstreamDiagnostic)
                    .font(OriveoTheme.Typography.caption.monospaced())
                    .foregroundStyle(OriveoTheme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }

            if !attemptDiagnostics.isEmpty {
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(attemptDiagnostics, id: \.self) { line in
                            Text(line)
                                .font(OriveoTheme.Typography.caption.monospaced())
                                .foregroundStyle(OriveoTheme.Palette.textTertiary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
                } label: {
                    Text(L10n.tr("What Oriveo tried", table: .providers))
                        .font(OriveoTheme.Typography.caption.weight(.medium))
                        .foregroundStyle(OriveoTheme.Palette.textSecondary)
                }
                .tint(OriveoTheme.Palette.textSecondary)
            }
        }
        .padding(OriveoTheme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .oriveoRoundedSurface(
            fill: OriveoTheme.Palette.warningSoft,
            border: OriveoTheme.Palette.warning.opacity(0.3),
            radius: OriveoTheme.Radius.inset,
            shadow: .none
        )
    }

    @ViewBuilder
    private func header(for kind: RelayKind) -> some View {
        let meta = RelayKindMeta.meta(for: kind)
        VStack(alignment: .leading, spacing: OriveoTheme.Spacing.sm) {
            Text(L10n.tr("STEP 2 OF 2", table: .providers))
                .font(OriveoTheme.Typography.footnote.weight(.semibold))
                .tracking(1.2)
                .foregroundStyle(OriveoTheme.Palette.primary)

            HStack(spacing: 8) {
                Image(systemName: meta.systemImage)
                    .font(.system(size: 14, weight: .semibold))
                Text(meta.title)
                    .font(OriveoTheme.Typography.footnote.weight(.semibold))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .foregroundStyle(meta.tint)
            .background(Capsule().fill(meta.tint.opacity(0.12)))

            Text(L10n.tr("Add Custom Relay", table: .providers))
                .font(OriveoTheme.Typography.title1)
                .foregroundStyle(OriveoTheme.Palette.textPrimary)

            Text(meta.subtitle)
                .font(OriveoTheme.Typography.body)
                .foregroundStyle(OriveoTheme.Palette.textSecondary)
        }
    }

    private func transportTitle(_ transport: RelayTransport) -> String {
        switch transport {
        case .llamacppNative: return L10n.tr("llama.cpp native completion", table: .providers)
        case .openaiChatCompletions: return L10n.tr("OpenAI Chat Completions", table: .providers)
        case .openaiResponses: return L10n.tr("OpenAI Responses", table: .providers)
        case .anthropicMessages: return L10n.tr("Anthropic Messages", table: .providers)
        case .geminiGenerateContent: return L10n.tr("Gemini generateContent", table: .providers)
        case .auto: return L10n.tr("Automatic", table: .providers)
        }
    }

    private func discoveryFailureMessage(_ failure: RelayDiscoveryFailureKind?) -> String {
        switch failure {
        case .embeddedQuery:
            return L10n.tr("Remove query parameters from the request URL. Oriveo never tries API keys from query parameters automatically.", table: .providers)
        case .authenticationRejected:
            return L10n.tr("The server rejected the API key. Check the key or choose the documented protocol manually.", table: .providers)
        case .rateLimited:
            return L10n.tr("The relay is rate limited. Wait and try again; Oriveo did not rotate credentials or protocols.", table: .providers)
        case .temporaryFailure, .network:
            return L10n.tr("The relay could not be reached reliably. Check the address and try again.", table: .providers)
        case .routeUnavailable:
            return L10n.tr("Neither a model catalog nor a known generation endpoint answered at this address. Check the address, or choose the protocol manually.", table: .providers)
        case .invalidEndpoint:
            return L10n.tr("Enter a valid HTTPS request URL.", table: .providers)
        case .invalidResponse:
            return L10n.tr("The relay answered, but its model catalog format was not recognized.", table: .providers)
        case nil:
            return L10n.tr("No supported relay configuration was detected.", table: .providers)
        }
    }

    @ViewBuilder
    private func probeFailureBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: OriveoTheme.Spacing.sm) {
            Image(systemName: "info.circle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(OriveoTheme.Palette.warning)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.tr("Saved without a model catalog", table: .providers))
                    .font(OriveoTheme.Typography.footnote.weight(.semibold))
                    .foregroundStyle(OriveoTheme.Palette.textPrimary)
                Text(message)
                    .font(OriveoTheme.Typography.caption)
                    .foregroundStyle(OriveoTheme.Palette.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(OriveoTheme.Spacing.md)
        .oriveoRoundedSurface(
            fill: OriveoTheme.Palette.warningSoft,
            border: OriveoTheme.Palette.warning.opacity(0.3),
            radius: OriveoTheme.Radius.md,
            shadow: .none
        )
    }

    // MARK: - Submit gating

    private var draftAuthMode: RelayAuthMode {
        guard let selectedRelayKind else { return .auto }
        if selectedRelayKind == .custom { return customAuthMode }
        return RelayKindDefaults.makeRequested(for: selectedRelayKind).authMode
    }

    private var formDraft: RelayFormDraft {
        let template = selectedRelayKind.map { RelayKindDefaults.makeRequested(for: $0) }
        let isCustom = selectedRelayKind == .custom
        return RelayFormDraft(
            endpoint: endpoint,
            apiKey: apiKey,
            authMode: draftAuthMode,
            securityMode: securityMode,
            transport: isCustom ? customTransport : (template?.transport ?? .auto),
            modelID: defaultModelID,
            headers: isCustom ? customHeaders : [],
            queryParams: isCustom ? customQueryParams : []
        )
    }

    private var formIssues: [RelayFormValidation.FieldIssue] {
        RelayFormValidation.validate(formDraft, mode: .create)
    }

    private var canSubmit: Bool {
        formIssues.isEmpty && !isSubmitting
    }

    private var canTestConnection: Bool {
        !endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !isTestingConnection &&
        !isSubmitting
    }

    enum TestConnectionResult: Equatable {
        case success(message: String)
        case failure(message: String)
    }

    static func normalizedRelayEndpoint(
        _ raw: String,
        securityMode: RelayConnectionSecurityMode = .remoteHTTPS
    ) -> String? {
        RelaySecurityModeSelection.normalizedEndpoint(raw, securityMode: securityMode)
    }

    private var endpointInputBinding: Binding<String> {
        Binding(
            get: { endpoint },
            set: { next in
                guard endpoint != next else { return }
                endpoint = next
                clearDiscovery()
            }
        )
    }

    @MainActor
    @discardableResult
    private func writeBackEndpointBeforeRequest() -> String? {
        let raw = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let writeback = RelaySecurityModeSelection.endpointWriteback(
            raw,
            securityMode: securityMode
        ) else { return nil }
        if writeback.didChange || endpoint != writeback.endpoint {
            endpoint = writeback.endpoint
            endpointNormalizationHighlightToken &+= 1
            clearDiscovery()
        }
        return writeback.endpoint
    }


    private func beginSubmit() {
        guard submitTask == nil else { return }
        _ = writeBackEndpointBeforeRequest()
        submitTask = Task {
            if !showsManualProfiles {
                if isSelectedDetectionVerified {
                    await saveDetectedRelay(verified: true)
                } else if needsDefaultModelInput {
                    await saveDetectedRelay(verified: false)
                } else {
                    await detectAndVerifyRelay()
                }
            } else {
                await submit()
            }
            await MainActor.run {
                submitTask = nil
            }
        }
    }

    @MainActor
    private func detectAndVerifyRelay() async {
        let attempt = setupCoordinator.beginVerification(for: .relay)
        if let submitTask {
            setupCoordinator.registerCancellation(for: attempt) { submitTask.cancel() }
        }
        await discoverRelay(attempt: attempt)
        guard !Task.isCancelled, setupCoordinator.isCurrent(attempt) else { return }
        let hasDetections = discoveryResult?.detections.isEmpty == false
        guard setupCoordinator.acceptDiscoveryResult(for: attempt, hasDetections: hasDetections),
              let discoveryResult, !discoveryResult.detections.isEmpty else {
            return
        }

        if let verified = discoveryResult.detections.first(where: \.generationVerified) {
            guard setupCoordinator.acceptVerified(.verified(attempt)) else { return }
            selectedDetectionID = verified.id
            verifiedDetectionID = verified.id
            testConnectionResult = .success(message: String(
                format: L10n.tr("Verified %@ through the actual chat path.", table: .providers),
                transportTitle(verified.transport)
            ))
            return
        }

        if needsDefaultModelInput {
            guard setupCoordinator.acceptVerified(.needsManualModel(attempt)) else { return }
            if let transport = probeDetectedTransport {
                testConnectionResult = .failure(message: String(
                    format: L10n.tr("Confirmed the %@ protocol, but this relay does not publish a model catalog. Enter a model ID above to continue.", table: .providers),
                    transportTitle(transport)
                ))
            } else {
                testConnectionResult = .failure(
                    message: L10n.tr("Catalog found, but it returned no model IDs. Enter a model above to continue.", table: .providers)
                )
            }
        } else {
            await verifyDetectedRelay(attempt: attempt)
        }
    }

    @MainActor
    private func clearDiscovery() {
        // The coordinator owns generation, cancellation, evidence, and the sole commit gate.
        setupCoordinator.invalidate()
        discoveryResult = nil
        selectedDetectionID = nil
        verifiedDetectionID = nil
        testConnectionResult = nil
        setupError = nil
    }

    @MainActor
    private func discoverRelay(attempt: CustomLLMSetupAttempt) async {
        let trimmedEndpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard RelaySetupDiscoveryInputPolicy.permitsDiscovery(
            endpoint: trimmedEndpoint,
            apiKey: trimmedKey,
            authMode: draftAuthMode
        ) else {
            if !trimmedKey.isEmpty && !ProviderKeyInput.isPrintableASCII(trimmedKey) {
                setupError = ProviderKeyInput.illegalCharsError()
            }
            return
        }
        guard let normalizedEndpoint = Self.normalizedRelayEndpoint(trimmedEndpoint, securityMode: securityMode) else {
            discoveryResult = nil
            setupError = OriveoError(
                id: UUID(),
                title: L10n.tr("Invalid request URL", table: .providers),
                message: L10n.tr(RelayEndpointPolicy.httpsRequiredMessageKey, table: .providers),
                actionTitle: L10n.tr("OK"),
                detail: trimmedEndpoint,
                severity: .warning
            )
            return
        }

        isSubmitting = true
        setupError = nil
        defer { isSubmitting = false }

        do {
            let hint = defaultModelID.trimmingCharacters(in: .whitespacesAndNewlines)
            let result = try await RelayDiscoveryService().discover(
                endpoint: normalizedEndpoint,
                apiKey: trimmedKey,
                modelHint: hint.isEmpty ? nil : hint,
                securityMode: securityMode
            )
            guard setupCoordinator.isCurrent(attempt) else { return }
            discoveryResult = result
            selectedDetectionID = nil
            verifiedDetectionID = nil
            testConnectionResult = nil

            if defaultModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               let firstDiscovered = result.detections.first(where: { !$0.modelIDs.isEmpty })?.modelIDs.first {
                defaultModelID = firstDiscovered
            }
        } catch is CancellationError {
            return
        } catch {
            guard setupCoordinator.isCurrent(attempt) else { return }
            _ = setupCoordinator.acceptFailure(for: attempt)
            setupError = OriveoError(
                id: UUID(),
                title: L10n.tr("Detection failed", table: .providers),
                message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription,
                actionTitle: L10n.tr("OK"),
                detail: normalizedEndpoint,
                severity: .warning
            )
        }
    }

    @MainActor
    private func verifyDetectedRelay(attempt: CustomLLMSetupAttempt) async {
        guard let discoveryResult, !discoveryResult.detections.isEmpty else { return }
        let trimmedEndpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let normalizedEndpoint = Self.normalizedRelayEndpoint(trimmedEndpoint, securityMode: securityMode) else { return }

        isTestingConnection = true
        selectedDetectionID = nil
        verifiedDetectionID = nil
        testConnectionResult = nil
        defer { isTestingConnection = false }

        let preferredModel = defaultModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        var finalFailure: String?

        for detection in discoveryResult.detections {
            do {
                try Task.checkCancellation()
                guard let modelID = preferredModel.isEmpty ? detection.modelIDs.first : preferredModel else {
                    continue
                }
                let requested = detectedRequestedConfig(for: detection, modelID: modelID)
                _ = try await appState.providerManager.openAIService.pingRelay(
                    apiKey: trimmedKey,
                    baseURL: normalizedEndpoint,
                    modelID: modelID,
                    relayRequested: requested
                )
                guard setupCoordinator.isCurrent(attempt) else { return }
                guard setupCoordinator.acceptVerified(.verified(attempt)) else { return }
                selectedDetectionID = detection.id
                verifiedDetectionID = detection.id
                testConnectionResult = .success(message: String(
                    format: L10n.tr("Verified %@ through the actual chat path.", table: .providers),
                    transportTitle(detection.transport)
                ))
                return
            } catch is CancellationError {
                return
            } catch {
                guard setupCoordinator.isCurrent(attempt) else { return }
                if let providerError = error as? ProviderServiceError {
                    finalFailure = providerError.technicalDetail.isEmpty
                        ? providerError.message
                        : providerError.technicalDetail
                } else {
                    finalFailure = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                }
            }
        }

        guard setupCoordinator.isCurrent(attempt) else { return }
        _ = setupCoordinator.acceptFailure(for: attempt)
        let detail = finalFailure ?? L10n.tr("No detected protocol completed the test request.", table: .providers)
        testConnectionResult = .failure(message: String(
            format: L10n.tr("Automatic protocol testing failed: %@", table: .providers),
            detail
        ))
    }

    @MainActor
    private func saveDetectedRelay(verified: Bool) async {
        guard let evidence = setupCoordinator.evidence, setupCoordinator.canCommit(evidence) else { return }
        if verified {
            guard evidence.verification == .generationVerified else { return }
        } else {
            guard evidence.verification == .needsManualModel, evidence.catalog == .unavailable else { return }
        }
        let detection: RelayDetectedConfiguration
        if verified {
            guard let selected = selectedDetection, verifiedDetectionID == selected.id else { return }
            detection = selected
        } else {
            guard let first = discoveryResult?.detections.first else { return }
            detection = first
        }

        let trimmedEndpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedModel = defaultModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let normalizedEndpoint = Self.normalizedRelayEndpoint(trimmedEndpoint, securityMode: securityMode) else { return }

        isSubmitting = true
        defer { isSubmitting = false }

        let requested = detectedRequestedConfig(
            for: detection,
            modelID: trimmedModel.isEmpty ? nil : trimmedModel
        )
        let kind = relayKind(for: detection.transport)

        var provider = appState.providerManager.registerRelay(
            name: name,
            endpoint: normalizedEndpoint,
            apiKey: trimmedKey,
            relayRequested: requested,
            catalogModelIDs: detection.modelIDs,
            preferredModelID: trimmedModel.isEmpty ? nil : trimmedModel,
            connectionState: verified
                ? .connected
                : .issue(L10n.tr("Connection has not been verified.", table: .providers))
        )
        provider.relayKind = kind
        provider.relayRequested = requested
        appState.providerManager.updateProvider(provider)

        if !trimmedModel.isEmpty {
            _ = appState.providerManager.ensureModelEnabledAsDefault(
                providerID: provider.id,
                modelID: trimmedModel
            )
            if let refreshed = appState.providerManager.provider(for: provider.id) {
                provider = refreshed
            }
        }

        guard ProviderSelectionSnapshot.defaultModel(in: provider) != nil else {
            if entryPoint == .welcome {
                appState.navigation.path = [
                    .manualModelEntry(providerID: provider.id, context: .onboarding)
                ]
            } else {
                appState.selectedTab = .providers
                appState.navigation.path = [
                    .manualModelEntry(providerID: provider.id, context: .providers)
                ]
            }
            return
        }

        completeProviderSetup(provider)
    }

    @MainActor
    private func discoveredCatalogIDs(
        endpoint: String,
        apiKey: String,
        modelHint: String?
    ) async -> [String] {
        guard let result = try? await RelayDiscoveryService().discover(
            endpoint: endpoint,
            apiKey: apiKey,
            modelHint: modelHint,
            securityMode: securityMode
        ) else { return [] }
        var seen = Set<String>()
        return result.detections.flatMap(\.modelIDs).filter { seen.insert($0).inserted }
    }

    private func detectedRequestedConfig(
        for detection: RelayDetectedConfiguration,
        modelID: String?
    ) -> RelayRequestedConfig {
        var requested = RelayRequestedConfig(
            transport: detection.transport,
            authMode: detection.authMode,
            securityMode: securityMode,
            modelID: modelID,
            stream: true,
            resolvedAPIBaseURL: detection.apiBaseURL
        )
        if detection.transport == .openaiResponses {
            requested.disableResponseStorage = true
            requested.codexCompatIdentity = true
        }
        return requested
    }

    private func relayKind(for transport: RelayTransport) -> RelayKind {
        RelayKind(transport: transport)
    }

    private func beginTestConnection() {
        guard testTask == nil else { return }
        _ = writeBackEndpointBeforeRequest()
        testTask = Task {
            await runTestConnection()
            await MainActor.run {
                testTask = nil
            }
        }
    }

    @MainActor
    private func clearTestResult() {
        testConnectionResult = nil
    }

    @ViewBuilder
    private func testConnectionResultRow(_ result: TestConnectionResult) -> some View {
        let isSuccess: Bool = {
            if case .success = result { return true }
            return false
        }()
        let message: String = {
            switch result {
            case .success(let message), .failure(let message):
                return message
            }
        }()

        RelaySetupStatusRow(
            message: message,
            systemImage: isSuccess ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
            tone: isSuccess ? .success : .warning
        )
    }

    @MainActor
    private func runTestConnection() async {
        guard !isTestingConnection else { return }

        let trimmedEndpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedEndpoint.isEmpty else {
            testConnectionResult = .failure(message: L10n.tr("Enter a request URL.", table: .providers))
            return
        }
        guard let normalizedEndpoint = Self.normalizedRelayEndpoint(trimmedEndpoint, securityMode: securityMode) else {
            testConnectionResult = .failure(message: L10n.tr(RelayEndpointPolicy.httpsRequiredMessageKey, table: .providers))
            return
        }

        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedKey.isEmpty || ProviderKeyInput.isPrintableASCII(trimmedKey) else {
            testConnectionResult = .failure(message: ProviderKeyInput.illegalCharsMessage)
            return
        }

        isTestingConnection = true
        testConnectionResult = nil
        defer { isTestingConnection = false }

        let trimmedModel = defaultModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        let requested = buildRelayRequested(
            kind: selectedRelayKind ?? .openaiCompatible,
            modelID: trimmedModel.isEmpty ? nil : trimmedModel
        )

        do {
            let result = try await appState.providerManager.openAIService.pingRelay(
                apiKey: trimmedKey,
                baseURL: normalizedEndpoint,
                modelID: trimmedModel.isEmpty ? nil : trimmedModel,
                relayRequested: requested
            )
            let message = result.modelCount > 0
                ? String(format: L10n.tr("Connected via %@. %d model(s) reachable.", table: .providers),
                         result.probedEndpoint, result.modelCount)
                : String(format: L10n.tr("Connected via %@.", table: .providers), result.probedEndpoint)
            testConnectionResult = .success(message: message)
        } catch {
            if let providerErr = error as? ProviderServiceError {
                let detail = providerErr.technicalDetail
                testConnectionResult = .failure(message: detail.isEmpty ? providerErr.message : detail)
            } else {
                testConnectionResult = .failure(
                    message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                )
            }
        }
    }

    private func submit() async {
        let trimmedEndpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedModel = defaultModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        let kind = selectedRelayKind ?? .custom

        guard formIssues.isEmpty else { return }

        guard trimmedKey.isEmpty || ProviderKeyInput.isPrintableASCII(trimmedKey) else {
            setupError = ProviderKeyInput.illegalCharsError()
            return
        }

        guard let normalizedEndpoint = Self.normalizedRelayEndpoint(trimmedEndpoint, securityMode: securityMode) else {
            setupError = OriveoError(
                id: UUID(),
                title: L10n.tr("Invalid request URL", table: .providers),
                message: L10n.tr(RelayEndpointPolicy.httpsRequiredMessageKey, table: .providers),
                actionTitle: L10n.tr("OK"),
                detail: trimmedEndpoint,
                severity: .warning
            )
            return
        }

        isSubmitting = true
        setupError = nil
        probeFailureNote = nil

        let requested = buildRelayRequested(
            kind: kind,
            modelID: trimmedModel.isEmpty ? nil : trimmedModel
        )

        var provider: Provider
        var probeFailedReason: String?

        do {
            if shouldUseOpenAIModelCatalogSync(requested) {
                provider = try await appState.registerProvider(
                    kind: .relay,
                    apiKey: trimmedKey,
                    baseURLText: normalizedEndpoint,
                    customName: name
                )
            } else {
                _ = try await OpenAIService().pingRelay(
                    apiKey: trimmedKey,
                    baseURL: normalizedEndpoint,
                    modelID: requested.modelID,
                    relayRequested: requested
                )
                let catalogIDs = await discoveredCatalogIDs(
                    endpoint: normalizedEndpoint,
                    apiKey: trimmedKey,
                    modelHint: requested.modelID
                )
                provider = appState.providerManager.registerRelay(
                    name: name,
                    endpoint: normalizedEndpoint,
                    apiKey: trimmedKey,
                    relayRequested: requested,
                    catalogModelIDs: catalogIDs,
                    preferredModelID: trimmedModel.isEmpty ? nil : trimmedModel
                )
            }
        } catch is CancellationError {
            isSubmitting = false
            return
        } catch {
            probeFailedReason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            provider = appState.providerManager.registerRelay(
                name: name,
                endpoint: normalizedEndpoint,
                apiKey: trimmedKey,
                relayRequested: requested,
                connectionState: .issue(probeFailedReason ?? L10n.tr("Connection has not been verified.", table: .providers))
            )
        }

        if Task.isCancelled {
            isSubmitting = false
            return
        }

        provider.relayKind = kind
        provider.relayRequested = requested
        appState.providerManager.updateProvider(provider)

        if !trimmedModel.isEmpty {
            _ = appState.providerManager.ensureModelEnabledAsDefault(
                providerID: provider.id,
                modelID: trimmedModel
            )
            if let refreshed = appState.providerManager.provider(for: provider.id) {
                provider = refreshed
            }
        }

        isSubmitting = false
        if let probeFailedReason {
            probeFailureNote = probeFailedReason
        }
        appState.selectedTab = .providers
        appState.navigation.path = [relaySetupCompletionRoute(for: provider)]
    }

    private func shouldUseOpenAIModelCatalogSync(_ requested: RelayRequestedConfig) -> Bool {
        (requested.transport == .openaiChatCompletions || requested.transport == .auto) &&
        (requested.authMode == .bearer || requested.authMode == .auto) &&
        (requested.headers?.isEmpty ?? true) &&
        (requested.queryParams?.isEmpty ?? true) &&
        (requested.customUserAgent?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    private func buildRelayRequested(kind: RelayKind, modelID: String?) -> RelayRequestedConfig {
        var requested = RelayKindDefaults.makeRequested(for: kind)
        if let modelID, !modelID.isEmpty { requested.modelID = modelID }
        requested.securityMode = securityMode

        if kind == .custom {
            let trimmedTier = customServiceTier.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedUA = customUserAgent.trimmingCharacters(in: .whitespacesAndNewlines)
            let cleanedHeaders = customHeaders
                .filter { !$0.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            let cleanedQueries = customQueryParams
                .filter { !$0.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

            requested.transport = customTransport
            requested.authMode = customAuthMode
            requested.reasoningEffort = customReasoningEffort == .automatic ? nil : customReasoningEffort
            requested.serviceTier = trimmedTier.isEmpty ? nil : trimmedTier
            requested.stream = customStream
            requested.disableResponseStorage = customDisableResponseStorage ? true : nil
            requested.headers = cleanedHeaders.isEmpty ? nil : cleanedHeaders
            requested.queryParams = cleanedQueries.isEmpty ? nil : cleanedQueries
            requested.customUserAgent = trimmedUA.isEmpty ? nil : trimmedUA
            if customTransport == .openaiResponses,
               let webSearchTool = customWebSearchToolName,
               webSearchTool != .webSearch {
                requested.webSearchToolName = webSearchTool
            }
        }

        return requested
    }
}

private struct RelayQuickSetupBackdrop: View {
    @Environment(\.colorScheme) private var colorScheme

    private let points: [CGPoint] = [
        CGPoint(x: 0.03, y: 0.20),
        CGPoint(x: 0.17, y: 0.08),
        CGPoint(x: 0.31, y: 0.27),
        CGPoint(x: 0.46, y: 0.11),
        CGPoint(x: 0.59, y: 0.31),
        CGPoint(x: 0.73, y: 0.09),
        CGPoint(x: 0.87, y: 0.26),
        CGPoint(x: 0.98, y: 0.13),
        CGPoint(x: 0.08, y: 0.55),
        CGPoint(x: 0.24, y: 0.68),
        CGPoint(x: 0.40, y: 0.52),
        CGPoint(x: 0.55, y: 0.72),
        CGPoint(x: 0.69, y: 0.54),
        CGPoint(x: 0.84, y: 0.70),
        CGPoint(x: 0.97, y: 0.56),
        CGPoint(x: 0.14, y: 0.92),
        CGPoint(x: 0.47, y: 0.95),
        CGPoint(x: 0.78, y: 0.90),
    ]

    private let edges: [(Int, Int)] = [
        (0, 1), (1, 2), (2, 3), (3, 4), (4, 5), (5, 6), (6, 7),
        (0, 8), (2, 8), (2, 10), (4, 10), (4, 12), (6, 12), (6, 14), (7, 14),
        (8, 9), (9, 10), (10, 11), (11, 12), (12, 13), (13, 14),
        (8, 15), (9, 15), (11, 16), (13, 17), (15, 16), (16, 17),
        (1, 10), (5, 12),
    ]

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    OriveoTheme.Palette.primarySoft.opacity(colorScheme == .dark ? 1 : 0.95),
                    OriveoTheme.Palette.primarySoft.opacity(0),
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            Canvas { context, size in
                let resolved = points.map { point in
                    CGPoint(x: point.x * size.width, y: point.y * size.height)
                }

                for edge in edges {
                    var path = Path()
                    path.move(to: resolved[edge.0])
                    path.addLine(to: resolved[edge.1])
                    context.stroke(
                        path,
                        with: .color(OriveoTheme.Palette.primary.opacity(colorScheme == .dark ? 0.20 : 0.16)),
                        lineWidth: 0.9
                    )
                }

                for (index, point) in resolved.enumerated() {
                    let isHub = index.isMultiple(of: 3)
                    let diameter: CGFloat = isHub ? 8 : 5
                    let rect = CGRect(
                        x: point.x - diameter / 2,
                        y: point.y - diameter / 2,
                        width: diameter,
                        height: diameter
                    )
                    context.fill(
                        Path(ellipseIn: rect),
                        with: .color(OriveoTheme.Palette.primary.opacity(isHub ? 0.46 : 0.26))
                    )
                }
            }
        }
        .mask {
            LinearGradient(
                stops: [
                    .init(color: .black, location: 0),
                    .init(color: .black, location: 0.52),
                    .init(color: .clear, location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .accessibilityHidden(true)
    }
}
