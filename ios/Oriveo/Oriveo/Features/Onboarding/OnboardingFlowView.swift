import SwiftUI


enum OnboardingPresentationMode {
    case live
    case rehearsal
}

struct OnboardingFlowView: View {
    var mode: OnboardingPresentationMode = .live
    var initialAct: OnboardingAct = .brand
    var onFinish: (() -> Void)?

    @Environment(AppState.self) private var appState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var progress: Double = 0
    @State private var appearedAt: Date?
    @State private var isExiting = false
    @State private var isStageAnimating = true

    @State private var auroraRevealed = false
    @State private var ringsRevealed = false
    @State private var nucleusRevealed = false
    @State private var copyRevealed = false
    @State private var controlsRevealed = false
    @State private var skipRevealed = false

    var body: some View {
        GeometryReader { proxy in
            let metrics = OnboardingLayoutMetrics(size: proxy.size)
            let values = OnboardingStageValues(progress: progress, width: Double(proxy.size.width))

            ScrollViewReader { reader in
                ZStack {
                    auroraBackground(values: values)

                    OnboardingOrbitStage(
                        values: values,
                        scale: metrics.stageScale,
                        ringsRevealed: ringsRevealed,
                        nucleusRevealed: nucleusRevealed,
                        isAnimating: isStageAnimating,
                    )
                    .position(x: proxy.size.width / 2, y: metrics.orbitCenterY)

                    copyPager(metrics: metrics, values: values)

                    controlLayer(metrics: metrics, values: values, reader: reader)

                    skipButton(values: values, reader: reader)
                }
                .onAppear {
                    guard initialAct != .brand else { return }
                    reader.scrollTo(initialAct.rawValue, anchor: .center)
                    progress = Double(initialAct.rawValue)
                }
            }
            .scaleEffect(isExiting ? 0.96 : 1)
            .opacity(isExiting ? 0 : 1)
        }
        .preferredColorScheme(.dark)
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .background(OnboardingPalette.bg0.ignoresSafeArea())
        .onAppear(perform: handleAppear)
        .onDisappear {
            isStageAnimating = false
        }
    }

    private func auroraBackground(values: OnboardingStageValues) -> some View {
        GeometryReader { geo in
            ZStack {
                OnboardingPalette.bg0

                auroraBlob(color: values.auroraTop.color, opacity: 0.5)
                    .position(x: geo.size.width * 0.05, y: geo.size.height * 0.06)

                auroraBlob(color: values.auroraBottom.color, opacity: 0.42)
                    .position(x: geo.size.width * 0.95, y: geo.size.height * 0.96)
            }
            .opacity(auroraRevealed ? 1 : 0)
            .overlay(noiseOverlay)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private func auroraBlob(color: Color, opacity: Double) -> some View {
        Circle()
            .fill(RadialGradient(
                colors: [color, .clear],
                center: .center,
                startRadius: 0,
                endRadius: 240
            ))
            .frame(width: 460, height: 460)
            .blur(radius: 75)
            .opacity(opacity)
    }

    @ViewBuilder
    private var noiseOverlay: some View {
        EmptyView()
    }


    private func copyPager(metrics: OnboardingLayoutMetrics, values: OnboardingStageValues) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 0) {
                ForEach(OnboardingAct.allCases) { act in
                    copyPage(act, metrics: metrics, values: values)
                        .frame(width: metrics.size.width)
                        .id(act.rawValue)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.always, axes: .horizontal)
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.contentOffset.x
        } action: { _, offsetX in
            progress = Double(offsetX / max(metrics.size.width, 1))
        }
    }

    private func copyPage(
        _ act: OnboardingAct,
        metrics: OnboardingLayoutMetrics,
        values: OnboardingStageValues
    ) -> some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            copyContent(act, metrics: metrics)
                .padding(.horizontal, metrics.horizontalPadding)
                .opacity(values.copyOpacity(for: act) * (copyRevealed ? 1 : 0))
                .offset(y: copyRevealed ? 0 : 14)

            Color.clear.frame(height: metrics.copyBottomInset)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func copyContent(_ act: OnboardingAct, metrics: OnboardingLayoutMetrics) -> some View {
        VStack(spacing: 10) {
            switch act {
            case .brand:
                Text("Oriveo")
                    .font(.system(size: metrics.wordmarkSize, weight: .heavy))
                    .tracking(-0.7)
                    .foregroundStyle(OnboardingPalette.ink)
            case .models, .byok, .start:
                Text(eyebrow(for: act))
                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                    .tracking(2.3)
                    .textCase(.uppercase)
                    .foregroundStyle(OnboardingPalette.purpleBright)
            }

            highlightedTitle(title(for: act), size: metrics.titleSize)

            Text(subtitle(for: act))
                .font(.system(size: 14))
                .foregroundStyle(OnboardingPalette.muted)
                .lineSpacing(4)
                .frame(maxWidth: 300)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private func highlightedTitle(_ raw: String, size: CGFloat) -> some View {
        let segments = OnboardingCopyMarkup.parse(raw)
        let composed = segments.reduce(Text("")) { partial, segment in
            let piece = Text(segment.text)
            return partial + (
                segment.isHighlighted
                    ? piece.foregroundStyle(OnboardingPalette.highlightGradient)
                    : piece.foregroundStyle(OnboardingPalette.ink)
            )
        }

        return composed
            .font(.system(size: size, weight: .bold))
            .tracking(-0.4)
            .lineSpacing(size * 0.28)
            .accessibilityLabel(OnboardingCopyMarkup.plainText(raw))
    }


    private func controlLayer(
        metrics: OnboardingLayoutMetrics,
        values: OnboardingStageValues,
        reader: ScrollViewProxy
    ) -> some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            VStack(spacing: 0) {
                pillBar(values: values, reader: reader)
                    .padding(.top, 26)

                Button {
                    handleAddAPIKey()
                } label: {
                    Text(L10n.tr("Add an API Key", table: .onboarding))
                        .font(.system(size: 14))
                        .foregroundStyle(OnboardingPalette.purpleBright)
                }
                .buttonStyle(OnboardingPressStyle())
                .padding(.top, 15)
                .opacity(values.loginOpacity)
                .offset(y: values.loginOffsetY)
                .allowsHitTesting(values.loginOpacity > 0.5)
                .accessibilityHidden(values.loginOpacity <= 0.5)
            }
            .padding(.bottom, metrics.controlBottomPadding)
            .opacity(controlsRevealed ? 1 : 0)
            .offset(y: controlsRevealed ? 0 : 14)
        }
    }

    private func pillBar(values: OnboardingStageValues, reader: ScrollViewProxy) -> some View {
        ZStack {
            Capsule()
                .fill(OnboardingPalette.ctaGradient(opacity: values.ctaMorph))
                .shadow(
                    color: OnboardingPalette.purple.opacity(0.65 * values.ctaMorph),
                    radius: 34 * values.ctaMorph,
                    y: 12 * values.ctaMorph
                )

            HStack(spacing: 9) {
                ForEach(OnboardingAct.allCases) { act in
                    dot(for: act, values: values, reader: reader)
                }
            }
            .opacity(values.dotsOpacity)
            .allowsHitTesting(values.areDotsInteractive)

            Text(L10n.tr("Get Started", table: .onboarding))
                .font(.system(size: 16.5, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.horizontal, 20)
                .opacity(values.ctaLabelOpacity)
                .allowsHitTesting(false)
        }
        .frame(width: values.pillWidth, height: 52)
        .contentShape(Capsule())
        .scaleEffect(isExiting ? 0.98 : 1)
        .onTapGesture {
            guard values.isCTAInteractive else { return }
            handleStart()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(L10n.tr("Get Started", table: .onboarding))
        .accessibilityHidden(values.ctaMorph < 0.5)
        .accessibilityAction { handleStart() }
    }

    private func dot(
        for act: OnboardingAct,
        values: OnboardingStageValues,
        reader: ScrollViewProxy
    ) -> some View {
        let isActive = Int(values.progress.rounded()) == act.rawValue

        return Button {
            OriveoHaptic.tap()
            withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
                reader.scrollTo(act.rawValue, anchor: .center)
            }
        } label: {
            Capsule()
                .fill(isActive ? OnboardingPalette.purpleBright : Color.white.opacity(0.28))
                .frame(width: isActive ? 22 : 7, height: 7)
                .animation(.easeOut(duration: 0.35), value: isActive)
        }
        .buttonStyle(.plain)
        .accessibilityHidden(true)
    }


    private func skipButton(values: OnboardingStageValues, reader: ScrollViewProxy) -> some View {
        VStack {
            HStack {
                Spacer()
                Button {
                    OriveoHaptic.tap()
                    withAnimation(.spring(response: 0.5, dampingFraction: 0.88)) {
                        reader.scrollTo(OnboardingAct.start.rawValue, anchor: .center)
                    }
                } label: {
                    Text(L10n.tr("Skip", table: .onboarding))
                        .font(.system(size: 13.5))
                        .foregroundStyle(OnboardingPalette.muted)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(Color.white.opacity(0.05)))
                        .overlay(Capsule().strokeBorder(OnboardingPalette.hairline, lineWidth: 1))
                }
                .buttonStyle(OnboardingPressStyle())
            }
            Spacer()
        }
        .padding(.top, 6)
        .padding(.trailing, 22)
        .opacity(values.skipOpacity * (skipRevealed ? 1 : 0))
        .allowsHitTesting(values.isSkipInteractive)
        .accessibilityHidden(values.skipOpacity < 0.2)
    }


    private func handleAppear() {
        isStageAnimating = true

        if appearedAt == nil {
            appearedAt = Date()
            if mode == .live {
            }
        }

        guard !OnboardingMotionPolicy.revealsInstantly(reduceMotion: reduceMotion) else {
            auroraRevealed = true
            ringsRevealed = true
            nucleusRevealed = true
            copyRevealed = true
            controlsRevealed = true
            skipRevealed = true
            return
        }

        withAnimation(.easeOut(duration: 1.1).delay(0.05)) { auroraRevealed = true }
        withAnimation(.easeOut(duration: 1.0).delay(0.25)) { ringsRevealed = true }
        withAnimation(.spring(response: 0.5, dampingFraction: 0.78).delay(0.18)) { nucleusRevealed = true }
        withAnimation(.spring(response: 0.5, dampingFraction: 0.85).delay(0.34)) { copyRevealed = true }
        withAnimation(.spring(response: 0.5, dampingFraction: 0.85).delay(0.52)) { controlsRevealed = true }
        withAnimation(.easeOut(duration: 0.5).delay(0.6)) { skipRevealed = true }
    }

    private func handleStart() {
        guard !isExiting else { return }
        OriveoHaptic.tap()

        guard !reduceMotion else {
            finish()
            return
        }

        withAnimation(.easeOut(duration: 0.28)) { isExiting = true }
        Task {
            try? await Task.sleep(for: .seconds(0.26))
            finish()
        }
    }

    private func finish() {
        isStageAnimating = false
        switch mode {
        case .rehearsal:
            appState.selectedTab = .home
            onFinish?()
        case .live:
            appState.startOnboarding()
            onFinish?()
        }
    }

    private func handleAddAPIKey() {
        appState.openProviderSetup(from: .welcome)
    }


    private func eyebrow(for act: OnboardingAct) -> String {
        switch act {
        case .brand: return ""
        case .models: return L10n.tr("Models", table: .onboarding)
        case .byok: return L10n.tr("BYOK", table: .onboarding)
        case .start: return L10n.tr("Start", table: .onboarding)
        }
    }

    private func title(for act: OnboardingAct) -> String {
        switch act {
        case .brand: return L10n.tr("All Your Models, {One App}", table: .onboarding)
        case .models: return L10n.tr("The Right Model for {Every Question}", table: .onboarding)
        case .byok: return L10n.tr("Your Keys, {Your Bill}", table: .onboarding)
        case .start: return L10n.tr("Start {Now}", table: .onboarding)
        }
    }

    private func subtitle(for act: OnboardingAct) -> String {
        switch act {
        case .brand:
            return L10n.tr("15 official providers and custom LLMs, in one conversation.", table: .onboarding)
        case .models:
            return L10n.tr("GPT, Claude, Gemini, DeepSeek — switch in a tap, without losing the thread.", table: .onboarding)
        case .byok:
            return L10n.tr("Your API keys never leave this device, and every call's cost is visible in real time.", table: .onboarding)
        case .start:
            return L10n.tr("No account. Your keys stay on this device.", table: .onboarding)
        }
    }
}


struct OnboardingLayoutMetrics {
    let size: CGSize

    var stageScale: CGFloat {
        let raw = min(size.width / OnboardingStageValues.referenceWidth, size.height / 844)
        return min(max(raw, 0.78), 1.12)
    }

    var orbitCenterY: CGFloat { size.height * 0.355 }

    var copyBottomInset: CGFloat { 190 * verticalScale }

    var controlBottomPadding: CGFloat { 18 }

    var horizontalPadding: CGFloat { size.width < 380 ? 28 : 36 }

    var titleSize: CGFloat { size.height < 720 ? 24 : 27 }

    var wordmarkSize: CGFloat { size.height < 720 ? 30 : 34 }

    private var verticalScale: CGFloat { min(max(size.height / 844, 0.84), 1.06) }
}

#Preview("Full flow") {
    OnboardingFlowView()
        .environment(AppState.preview)
}

#Preview("Act 1 - Gather") {
    OnboardingFlowView(initialAct: .models)
        .environment(AppState.preview)
}

#Preview("Act 2 - Control") {
    OnboardingFlowView(initialAct: .byok)
        .environment(AppState.preview)
}

#Preview("Act 3 - Launch") {
    OnboardingFlowView(initialAct: .start)
        .environment(AppState.preview)
}
