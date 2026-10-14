import SwiftUI

/// The discovery input gate shares its source with the submit path: an empty key with auth=none is a verifiable
/// production configuration, so printable-ASCII validation applies only to a non-empty key. This keeps the UI
/// button from being tappable while the action silently returns.
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

    /// Quick setup is the default entry; manual setup is a separate page reached from the secondary row at the bottom of step 1.
    @State private var showsManualSetup = false
    @State private var endpointNormalizationHighlightToken = 0
    @State private var submitTask: Task<Void, Never>?
    /// The two-step quick setup: state and actions live in the flow, and this page only renders.
    @State private var flow: RelayQuickSetupFlow
    /// The single-page manual setup: it shares the address and key inputs with quick setup, and its state and actions live in manualFlow.
    @State private var manualFlow: RelayManualSetupFlow
    @State private var setupCoordinator: CustomLLMSetupCoordinator

    init(
        entryPoint: ProviderSetupEntryPoint,
        initialMethod: CustomLLMConnectionMethod = .relay
    ) {
        self.entryPoint = entryPoint
        let coordinator = CustomLLMSetupCoordinator(method: initialMethod)
        #if DEBUG
        // Sample pages only: swap in flows that make no network calls so the catalog and a validation failure can be staged.
        if let flows = RelayFamilyDebugShots.makeSetupFlows(coordinator: coordinator) {
            _setupCoordinator = State(initialValue: coordinator)
            _flow = State(initialValue: flows.quick)
            _manualFlow = State(initialValue: flows.manual)
            _showsManualSetup = State(initialValue: flows.startsInManualSetup)
            return
        }
        #endif
        let quick = RelayQuickSetupFlow(coordinator: coordinator)
        _setupCoordinator = State(initialValue: coordinator)
        _flow = State(initialValue: quick)
        _manualFlow = State(initialValue: RelayManualSetupFlow(quick: quick))
    }

    var body: some View {
        VStack(spacing: 0) {
            if showsManualSetup || flow.step == .connection || setupCoordinator.method == .local {
                topBar
            }

            if setupCoordinator.method == .local {
                LocalComputeSetupView(
                    entryPoint: entryPoint,
                    coordinator: setupCoordinator,
                    onCompleted: completeProviderSetup
                )
            } else {
            ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: OriveoTheme.Spacing.xl) {
                    if showsManualSetup {
                        RelayManualSetupFormView(
                            flow: manualFlow,
                            board: manualFlow.board,
                            onSaveUnverified: saveUnverified
                        )
                    } else if flow.step == .models {
                        RelaySetupModelsView(flow: flow) {
                            withAnimation(.snappy(duration: 0.18)) { flow.backToConnection() }
                        }
                    } else {
                        quickSetupHeader

                        RelaySetupStepOneView(
                            flow: flow,
                            board: relayBoard,
                            endpointHighlightToken: endpointNormalizationHighlightToken
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
                if showsRelaySaveBar {
                    saveBar
                }
            }
            // The only inputs on step 2 are the search field at the top and the dialog: letting the footer rise with the keyboard would only cover list rows.
            .ignoresSafeArea(.keyboard, edges: Self.keyboardIgnoredEdges(showsManualSetup: showsManualSetup, step: flow.step))
            // The manual-setup failure card sits at the end of the form: when it appears, dismiss the keyboard and scroll to it, otherwise it lands off-screen behind the open keyboard.
            .onChange(of: manualFlow.failureCardID) { previous, current in
                RelayFailureCardReveal.revealIfNeeded(previous: previous, current: current, proxy: proxy)
            }
            }
            }
        }
        .background(alignment: .top) { topAura }
        .oriveoScreenBackground()
        .onDisappear {
            // Leaving the page invalidates any in-flight detection and validation (the manual-setup failure card goes away with it).
            manualFlow.leave()
            submitTask?.cancel()
            submitTask = nil
        }
    }

    @MainActor
    private func completeProviderSetup(_ provider: Provider) {
        completeProviderSetup(provider, verifiedModelID: nil)
    }

    private func completeProviderSetup(_ provider: Provider, verifiedModelID: String?) {
        appState.completeProviderSetup(
            providerID: provider.id,
            entryPoint: entryPoint,
            verifiedModelID: verifiedModelID
        )
    }

    /// Top ambient layer: pinned to the very top edge, spanning the full width, extending behind the status bar, and fading out downward.
    /// It sits above `oriveoScreenBackground` and below all content, so the title and back button float over the grid.
    /// Quick-setup step 1 and manual setup share the same page shell and both show it; step 2 (model selection) does not.
    @ViewBuilder
    private var topAura: some View {
        if showsManualSetup || flow.step == .connection {
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
                if showsManualSetup {
                    manualActionBar
                } else if flow.step == .models {
                    modelsSaveBar
                } else {
                    stepOneActionBar
                }
            }
            .padding(.horizontal, OriveoTheme.Spacing.xl)
            .padding(.top, OriveoTheme.Spacing.xl)
            .padding(.bottom, OriveoTheme.Spacing.md)
            .frame(maxWidth: 608)
            .frame(maxWidth: .infinity)
        }
        // The bottom action bar is no longer a block of white chrome: it uses a top-to-bottom fade mask in the page background color,
        // so scrolling content disappears into it naturally, with no abrupt color block or shadow edge in light or dark mode.
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

    /// The actual background color at the bottom of the page (the end of the `OriveoScreenBackground` diagonal gradient); the fade mask must match it to be seamless.
    private static let bottomFade = Color.dynamic(light: 0xF6F5FA, dark: 0x10141C)

    /// The local conditional fields own their only primary action. This guard prevents the
    /// relay save bar from surviving a method switch and rendering a second primary button.
    private var showsRelaySaveBar: Bool {
        Self.showsRelaySaveBar(method: setupCoordinator.method)
    }

    /// Only step 2 ignores keyboard avoidance; the inputs on step 1 and in manual setup live in the form and still need to be lifted above the keyboard.
    static func keyboardIgnoredEdges(showsManualSetup: Bool, step: RelayQuickSetupFlow.Step) -> Edge.Set {
        !showsManualSetup && step == .models ? .bottom : []
    }

    /// Each of the three relay pages (step 1, step 2, manual setup) has exactly one primary button at the bottom.
    nonisolated static func showsRelaySaveBar(method: CustomLLMConnectionMethod) -> Bool {
        method == .relay
    }

    /// Step 1 action bar: "Step 1 of 2" plus a "Cancel detection" link shown only while detecting, then the primary button (always Next), then the manual-setup secondary row.
    @ViewBuilder
    private var stepOneActionBar: some View {
        let board = relayBoard
        HStack(spacing: OriveoTheme.Spacing.sm) {
            Text(L10n.format(L10n.tr(RelaySetupBoardModel.stepOfKey, table: .providers), 1, 2))
                .font(OriveoTheme.Typography.footnote)
                .foregroundStyle(OriveoTheme.Palette.textSecondary)
            Spacer(minLength: 0)
            if board.card?.showsCancel == true {
                Button {
                    withAnimation(.snappy(duration: 0.18)) { flow.cancelDetection() }
                } label: {
                    Text(L10n.tr(RelaySetupBoardModel.cancelDetectionKey, table: .providers))
                        .font(OriveoTheme.Typography.footnote.weight(.medium))
                        .foregroundStyle(OriveoTheme.Palette.textSecondary)
                        .frame(minHeight: 44)
                }
                .buttonStyle(.plain)
            }
        }
        Button {
            beginSubmit()
        } label: {
            Text(L10n.tr(board.primaryTitleKey, table: .providers))
                .lineLimit(1)
                .minimumScaleFactor(0.84)
        }
        .buttonStyle(OriveoPrimaryButtonStyle())
        .disabled(!board.isPrimaryEnabled)
        .opacity(board.isPrimaryEnabled ? 1 : 0.48)

        manualSetupEntry
    }

    /// Step 2 action bar: a footnote (only the first checked model gets one request) plus "Save (n selected)", disabled at 0 selected.
    @ViewBuilder
    private var modelsSaveBar: some View {
        let board = flow.modelsBoard
        Label {
            Text(L10n.tr(RelaySetupModelsBoard.saveNoteKey, table: .providers))
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            PhosphorIcon.info.image(.regular)
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
                .frame(width: 16, height: 16)
        }
        .font(OriveoTheme.Typography.caption)
        .foregroundStyle(OriveoTheme.Palette.textSecondary)
        .frame(maxWidth: .infinity, alignment: .leading)

        Button {
            beginSubmit()
        } label: {
            HStack(spacing: OriveoTheme.Spacing.sm) {
                if flow.isSaving {
                    ProgressView().controlSize(.small).tint(.white)
                }
                Text(L10n.format(
                    L10n.tr(RelaySetupModelsBoard.saveSelectedKey, table: .providers),
                    board.saveCount
                ))
                .lineLimit(1)
                .minimumScaleFactor(0.84)
            }
        }
        .buttonStyle(OriveoPrimaryButtonStyle())
        .disabled(!board.isSaveEnabled)
        .opacity(board.isSaveEnabled || flow.isSaving ? 1 : 0.48)
    }

    /// Manual-setup action bar: a single primary button in the same style as the step 1 primary button, with no step counter and no "Test connection".
    /// Its title, in-progress state and enabled state all come from the row model ("Validate and save" by default, "Validate again" after a failure).
    @ViewBuilder
    private var manualActionBar: some View {
        let primary = manualFlow.board.primary
        Button {
            beginSubmit()
        } label: {
            HStack(spacing: OriveoTheme.Spacing.sm) {
                if primary.showsProgress {
                    ProgressView().controlSize(.small).tint(.white)
                }
                Text(L10n.tr(primary.titleKey, table: .providers))
                    .lineLimit(1)
                    .minimumScaleFactor(0.84)
            }
        }
        .buttonStyle(OriveoPrimaryButtonStyle())
        .disabled(!primary.isEnabled)
        .opacity(primary.isEnabled || primary.showsProgress ? 1 : 0.48)
    }

    /// The single source of state for the step 1 board: the view only renders it.
    private var relayBoard: RelaySetupBoardModel {
        flow.connectionBoard(canAct: setupCoordinator.method == .relay)
    }

    /// The only page title is the one in the Hero, which keeps the page header and the top bar from showing the same name twice.
    /// The manual-setup page puts "Use quick setup" at the top left instead of a back button to return to the quick path; the other pages keep only the back button.
    private var topBar: some View {
        HStack {
            if showsManualSetup {
                RelayManualSetupQuickSetupButton {
                    withAnimation(.snappy(duration: 0.18)) {
                        // Keep the address and key; invalidate any in-flight validation.
                        manualFlow.leave()
                        submitTask?.cancel()
                        submitTask = nil
                        showsManualSetup = false
                    }
                }
            } else {
                OriveoBackButton {
                    appState.pop()
                }
                .padding(.leading, -OriveoBackButton.edgeInset)
            }

            Spacer(minLength: 0)
            // This trailing spacer only mirrors the back button; when the leading item is a text button it is dropped so the text gets the full width.
            if !showsManualSetup {
                Color.clear
                    .frame(width: OriveoBackButton.hitSize - OriveoBackButton.edgeInset, height: 44)
            }
        }
        .padding(.horizontal, OriveoTheme.Spacing.xl)
        .padding(.vertical, OriveoTheme.Spacing.md)
    }

    /// The hero no longer has any container: the constellation grid is promoted to the page-wide ambient layer at the top (see `topAura`),
    /// leaving only text that spans the content width, with the title back at hero size to carry the page.
    /// The connected-dots icon on the left is gone too, because it is the same symbol as the background grid and the two clash side by side.
    private var quickSetupHeader: some View {
        SetupBoardHero(
            icon: .hardDrives,
            labelKey: RelaySetupBoardModel.heroLabelKey,
            titleKey: RelaySetupBoardModel.heroTitleKey,
            subtitleKey: RelaySetupBoardModel.heroSubtitleKey
        )
    }

    /// Manual setup is an explicit secondary exit: a secondary row under a hairline in the action bar. Tapping it opens the manual-setup page directly.
    private var manualSetupEntry: some View {
        SetupBoardSecondaryRow(
            icon: .slidersHorizontal,
            titleKey: RelaySetupBoardModel.secondaryActionKey,
            isEnabled: !flow.isDetecting
        ) {
            withAnimation(.snappy(duration: 0.18)) {
                // Cancel any in-flight detection; the address and key carry over unchanged.
                manualFlow.enter()
                showsManualSetup = true
            }
        }
    }

    /// URL normalization: the user may enter only host/path and the app prepends `https://`.
    /// TLS, DNS and reachability are not checked here; the actual network layer reports those errors.
    static func normalizedRelayEndpoint(
        _ raw: String,
        securityMode: RelayConnectionSecurityMode = .remoteHTTPS
    ) -> String? {
        RelaySecurityModeSelection.normalizedEndpoint(raw, securityMode: securityMode)
    }

    // MARK: - Submit

    private func beginSubmit() {
        guard !showsManualSetup else {
            // Whether a submit is accepted is decided by the flow alone: it uses the same criterion as the primary button being enabled,
            // so there is no extra "previous call has not returned" gate here. Once the input is edited mid-flight the button is already
            // lit, and such a gate would swallow the tap.
            manualFlow.submit(appState: appState, entryPoint: entryPoint)
            return
        }
        switch flow.step {
        case .connection:
            if flow.writeBackEndpoint() { endpointNormalizationHighlightToken &+= 1 }
            withAnimation(.snappy(duration: 0.18)) { _ = flow.next(appState: appState) }
        case .models:
            guard submitTask == nil else { return }
            submitTask = Task {
                await flow.save(appState: appState, entryPoint: entryPoint)
                await MainActor.run { submitTask = nil }
            }
        }
    }

    /// "Save anyway (unverified)" on the failure card: persist the connection with an issue, then open its detail page.
    private func saveUnverified() {
        manualFlow.saveUnverified(appState: appState, entryPoint: entryPoint)
    }
}

/// Top ambient layer: the constellation grid spans the full screen width, runs behind the status bar, and fades out downward.
///
/// An earlier version used it as the background of the hero card, which confined the pattern to a rounded rectangle and clipped
/// the grid before it could spread out, so it looked cramped. An ambient layer should either fill the width or not exist; the
/// in-between state looks worst.
private struct RelayQuickSetupBackdrop: View {
    @Environment(\.colorScheme) private var colorScheme

    /// Normalized coordinates. Once the layer fills the screen it stretches horizontally, so there are more points over a wider span
    /// than in the card version, which keeps the same few points from being thinned out into scattered specks.
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
            // Single-color vertical fade: the ambient layer has no solid card behind it, so a two-color or diagonal ending would reveal a boundary.
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
        // The grid fades out downward as a whole so the bottom edge is not cut off hard (the gradient handles color, this mask handles the pattern).
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

struct RelaySetupOrbIcon: View {
    var systemImage: String
    var badgeSystemImage: String? = nil
    var tone: StatusTone = .primary
    var size: CGFloat = 72

    var body: some View {
        ZStack {
            Circle()
                .fill(orbGradient)
                .frame(width: size, height: size)
                .overlay(
                    Circle()
                        .stroke(OriveoTheme.Palette.hairline, lineWidth: 1)
                )
                .shadow(color: tone.foreground.opacity(0.18), radius: 10, y: 5)

            Circle()
                .fill(OriveoTheme.Palette.cardHighlight)
                .frame(width: size * 0.45, height: size * 0.45)
                .offset(x: -size * 0.16, y: -size * 0.18)

            Image(systemName: systemImage)
                .font(.system(size: size * 0.32, weight: .semibold))
                .foregroundStyle(Color.white)

            if let badgeSystemImage {
                Circle()
                    .fill(OriveoTheme.Palette.surfaceChrome)
                    .frame(width: size * 0.34, height: size * 0.34)
                    .overlay(
                        Circle()
                            .stroke(OriveoTheme.Palette.border, lineWidth: 1)
                    )
                    .overlay {
                        Image(systemName: badgeSystemImage)
                            .font(.system(size: size * 0.14, weight: .bold))
                            .foregroundStyle(tone.foreground)
                    }
                    .offset(x: size * 0.26, y: size * 0.26)
            }
        }
        .frame(width: size + 12, height: size + 12)
    }

    private var orbGradient: LinearGradient {
        switch tone {
        case .primary:
            return LinearGradient(
                colors: [
                    Color.dynamic(light: 0xA78BFA, dark: 0xC4B5FD),
                    Color.dynamic(light: 0x7C3AED, dark: 0x8B5CF6)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .success:
            return LinearGradient(
                colors: [
                    Color.dynamic(light: 0x34D399, dark: 0x4ADE80),
                    Color.dynamic(light: 0x059669, dark: 0x16A34A)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .warning:
            return LinearGradient(
                colors: [
                    Color.dynamic(light: 0xFBBF24, dark: 0xFCD34D),
                    Color.dynamic(light: 0xD97706, dark: 0xF59E0B)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .danger:
            return LinearGradient(
                colors: [
                    Color.dynamic(light: 0xFB7185, dark: 0xFB7185),
                    Color.dynamic(light: 0xE11D48, dark: 0xE11D48)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .neutral:
            return LinearGradient(
                colors: [
                    Color.dynamic(light: 0xCBD5E1, dark: 0x64748B),
                    Color.dynamic(light: 0x94A3B8, dark: 0x475569)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }
}

func relaySetupFeatureItems() -> [HeroIconTextItem] {
    [
        HeroIconTextItem(
            id: "endpoint",
            title: L10n.tr("Request URL", table: .providers),
            systemImage: "point.bottomleft.forward.to.point.topright.scurvepath",
            gradientColors: [Color.dynamic(light: 0x818CF8, dark: 0xA78BFA), Color.dynamic(light: 0x5B21B6, dark: 0x7C3AED)],
            shadowColor: Color.dynamic(light: 0x4338CA, dark: 0x000000, lightAlpha: 0.10, darkAlpha: 0.12)
        ),
        HeroIconTextItem(
            id: "model",
            title: L10n.tr("Model", table: .providers),
            systemImage: "cpu",
            gradientColors: [Color.dynamic(light: 0x22C55E, dark: 0x4ADE80), Color.dynamic(light: 0x15803D, dark: 0x16A34A)],
            shadowColor: Color.dynamic(light: 0x166534, dark: 0x000000, lightAlpha: 0.10, darkAlpha: 0.12)
        ),
        HeroIconTextItem(
            id: "transport",
            title: L10n.tr("Transport", table: .providers),
            systemImage: "arrow.triangle.branch",
            gradientColors: [Color.dynamic(light: 0xF59E0B, dark: 0xFBBF24), Color.dynamic(light: 0xD97706, dark: 0xD97706)],
            shadowColor: Color.dynamic(light: 0xB45309, dark: 0x000000, lightAlpha: 0.10, darkAlpha: 0.12)
        ),
    ]
}
