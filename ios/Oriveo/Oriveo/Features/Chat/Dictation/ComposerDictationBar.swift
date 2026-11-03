import SwiftUI

/// Buttons on the recording bar.
enum DictationBarControl: Sendable, Hashable, CaseIterable {
    /// ✕ → discard()
    case discard
    /// Transcribe → finish(.insert)
    case transcribe
    /// Outer ↑ → finish(.send); enabled exactly when the host send button is
    case transcribeAndSend
}

@MainActor
extension DictationBarControl {
    var accessibilityLabel: String {
        switch self {
        case .discard: return L10n.tr("Discard Recording", table: .voice)
        case .transcribe: return L10n.tr("Done", table: .voice)
        case .transcribeAndSend: return L10n.tr("Transcribe and Send", table: .voice)
        }
    }
}

/// Dictation button slot (dictation visual contract, items 2-4): recording capsule (✕, timer, waveform, "Done") plus an outer 56pt send button,
/// Busy state shows ✕, a label and progress in the same capsule. The host draws the input field above; this view draws nothing in `.normal`.
struct ComposerDictationBar: View {
    let mode: DictationInputRowMode
    let levelMeter: DictationLevelMeter
    /// Whether the host send button is currently enabled; ↑ follows it.
    let canSend: Bool
    let onDiscard: () -> Void
    let onTranscribe: () -> Void
    let onTranscribeAndSend: () -> Void
    /// "Done" label; nil uses the current UI language (tests inject each of the 16 languages).
    var doneTitle: String?

    /// Buttons shown per mode (the busy state keeps only ✕).
    static func controls(for mode: DictationInputRowMode) -> [DictationBarControl] {
        switch mode {
        case .normal: return []
        case .recording: return [.discard, .transcribe, .transcribeAndSend]
        case .busy: return [.discard]
        }
    }

    static let minimumHitSize: CGFloat = 44
    /// Capsule height 56 (minimum; grows with content), corner radius 28; leading inset 4, trailing inset 6, item spacing 6.
    static let capsuleHeight: CGFloat = 56
    static let capsuleCornerRadius: CGFloat = 28
    static let capsuleLeadingPadding: CGFloat = 4
    static let capsuleTrailingPadding: CGFloat = 6
    static let capsuleSpacing: CGFloat = 6
    /// Outer send button: 56 round, 10 from the capsule.
    static let sendButtonSize: CGFloat = 56
    static let sendButtonSpacing: CGFloat = 10
    /// "Done" capsule: height 40, horizontal insets 14.
    static let doneHeight: CGFloat = 40
    /// Timer and Done text follow Dynamic Type up to this size so the 56pt capsule still fits.
    static let dynamicTypeCap: DynamicTypeSize = .accessibility2
    static let doneHorizontalPadding: CGFloat = 14
    static let doneFont: Font = .system(.subheadline, weight: .semibold)
    static let elapsedFont: Font = .system(.subheadline, design: .rounded, weight: .semibold).monospacedDigit()
    /// On narrow screens the timer and "Done" shrink to at most 0.75 (the waveform drops to 0 bars first); single line, never truncated.
    static let minimumTextScale: CGFloat = 0.75
    /// Timer text width 34.
    static let elapsedWidth: CGFloat = 34

    #if DEBUG
    /// Shots only: fixed elapsed seconds for the recording timer (no TimelineView ticking). nil = live timer.
    /// Must be set before the recording bar appears; it is not observed.
    @MainActor static var shotsFrozenElapsedSec: Int?
    #endif

    var body: some View {
        switch mode {
        case .normal:
            EmptyView()
        case .recording(let startedAt):
            HStack(alignment: .center, spacing: Self.sendButtonSpacing) {
                capsule {
                    DictationRecordingRowLayout(
                        spacing: Self.capsuleSpacing,
                        doneTextInset: 2 * Self.doneHorizontalPadding,
                        minimumTextScale: Self.minimumTextScale
                    ) {
                        discardButton
                        DictationElapsedText(startedAt: startedAt)
                        DictationWaveform(levelMeter: levelMeter)
                        transcribeButton
                    }
                }
                transcribeAndSendButton
            }
        case .busy(let activity):
            capsule {
                discardButton
                DictationBusyIndicator(activity: activity)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - Capsule

    private func capsule<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Self.capsuleCornerRadius, style: .continuous)
        return HStack(alignment: .center, spacing: Self.capsuleSpacing) {
            content()
        }
        .padding(.leading, Self.capsuleLeadingPadding)
        .padding(.trailing, Self.capsuleTrailingPadding)
        .frame(minHeight: Self.capsuleHeight)
        .background {
            ZStack {
                shape.fill(.ultraThinMaterial)
                shape.fill(Self.capsuleFill)
            }
            .shadow(color: Self.capsuleShadow, radius: 13, y: 10)
        }
        .overlay {
            shape.strokeBorder(Self.capsuleHairline, lineWidth: 0.5)
                .allowsHitTesting(false)
        }
    }

    private static let capsuleFill = Color.dynamic(light: 0xFFFFFF, dark: 0xFFFFFF, lightAlpha: 0.86, darkAlpha: 0.08)
    private static let capsuleHairline = Color.dynamic(light: 0x7C3AED, dark: 0xFFFFFF, lightAlpha: 0.16, darkAlpha: 0.10) // capability-ui-lint: allow voice / dictation capsule brand violet, not a capability colour
    private static let capsuleShadow = Color.dynamic(light: 0x5B21B6, dark: 0x000000, lightAlpha: 0.12, darkAlpha: 0)
    private static let discardTint = Color.dynamic(light: 0x52525B, dark: 0xB3B3BA)
    // dark-palette-guard: keep (c) fixed dictation recording-bar colors, set by the dictation visual contract, not theme-dependent
    private static let doneText = Color.dynamic(light: 0x6D28D9, dark: 0xC4B5FD)
    // dark-palette-guard: keep (c) fixed dictation recording-bar colors, set by the dictation visual contract, not theme-dependent
    private static let doneFill = Color.dynamic(light: 0x8C5FF8, dark: 0xA78BFA, lightAlpha: 0.10, darkAlpha: 0.18) // capability-ui-lint: allow voice / dictation capsule brand violet, not a capability colour

    /// Blue → purple → magenta → warm → mint → back to blue (shared by the glow border and the waveform).
    static let borderColors: [Color] = [
        Color(hex: 0x6E8BFF),
        Color(hex: 0x9B6BFF),
        Color(hex: 0xE06BC4),
        Color(hex: 0xFFB36B),
        Color(hex: 0x66E0B8),
        Color(hex: 0x6E8BFF)
    ]

    /// Primary action purple: 135° two-color gradient (shared by the send button and the failure card's primary button).
    static let primaryGradient = LinearGradient(
        // dark-palette-guard: keep (c) fixed dictation recording-bar colors, set by the dictation visual contract, not theme-dependent
        colors: [Color(hex: 0x8347F5), Color(hex: 0x6B3BC7)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    // MARK: - Buttons

    private var discardButton: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            onDiscard()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Self.discardTint)
                .frame(width: Self.minimumHitSize, height: Self.minimumHitSize)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(DictationBarControl.discard.accessibilityLabel)
    }

    private var transcribeButton: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            onTranscribe()
        } label: {
            Text(doneTitle ?? DictationBarControl.transcribe.accessibilityLabel)
                .font(Self.doneFont)
                .dynamicTypeSize(...Self.dynamicTypeCap)
                .foregroundStyle(Self.doneText)
                .lineLimit(1)
                // "Done" is never truncated: it takes full width first; text shrinks only after the waveform drops to 0 bars and still does not fit (to 0.75 at most).
                .minimumScaleFactor(Self.minimumTextScale)
                .padding(.horizontal, Self.doneHorizontalPadding)
                .frame(minHeight: Self.doneHeight)
                .background(Capsule().fill(Self.doneFill))
                .frame(minWidth: Self.minimumHitSize, minHeight: Self.minimumHitSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(doneTitle ?? DictationBarControl.transcribe.accessibilityLabel)
    }

    /// Outer 56pt send button: 135° purple gradient, top inner highlight, purple shadow; falls back to a gray background when sending is unavailable (same as the host send button).
    private var transcribeAndSendButton: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            onTranscribeAndSend()
        } label: {
            Image(systemName: "arrow.up")
                .font(.system(size: 21, weight: .bold))
                .foregroundStyle(canSend ? Color.white : OriveoTheme.Palette.textTertiary)
                .frame(width: Self.sendButtonSize, height: Self.sendButtonSize)
                .background {
                    if canSend {
                        Circle()
                            .fill(Self.primaryGradient)
                            .overlay {
                                // Top inner highlight: white α.28 at the top edge, fading downward.
                                Circle().strokeBorder(
                                    LinearGradient(
                                        colors: [Color.white.opacity(0.28), Color.white.opacity(0)],
                                        startPoint: .top,
                                        endPoint: .center
                                    ),
                                    lineWidth: 1
                                )
                            }
                            .shadow(color: Color(hex: 0x7C3AED).opacity(0.32), radius: 11, y: 10) // capability-ui-lint: allow voice / dictation capsule brand violet, not a capability colour
                    } else {
                        Circle().fill(Color.brand(defaultLight: OriveoLightBrand.defaultBrand.ink, light: \.ink, lightAlpha: 0.12, darkFixed: 0xFFFFFF, darkAlpha: 0.10))
                    }
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .scaleEffect(canSend ? 1 : 0.96)
        .disabled(!canSend)
        .accessibilityLabel(DictationBarControl.transcribeAndSend.accessibilityLabel)
        .animation(.easeInOut(duration: 0.18), value: canSend)
    }
}

// MARK: - Flow border

/// Glow border on the input field while dictation records (dictation visual contract, item 1): 2pt angular gradient, one revolution every 6 s at constant speed;
/// static at 24° when Reduce Motion is on. Shared by the chat input and the home glass card; attached only while recording.
struct DictationFlowBorder: View {
    let cornerRadius: CGFloat

    static let lineWidth: CGFloat = 2
    static let period: TimeInterval = 6
    static let restingAngle: Angle = .degrees(24)

    /// Rotation animation; nil when Reduce Motion is on (no rotation).
    static func rotation(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .linear(duration: period).repeatForever(autoreverses: false)
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var turned = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        GeometryReader { proxy in
            // The angular gradient covers a square spanning the diagonal and is rotated as a whole, equivalent to rotating the gradient's start angle; the outline is clipped by the stroke mask.
            let side = (proxy.size.width * proxy.size.width + proxy.size.height * proxy.size.height).squareRoot()
            AngularGradient(
                gradient: Gradient(colors: ComposerDictationBar.borderColors),
                center: .center,
                angle: Self.restingAngle
            )
            .frame(width: side, height: side)
            .rotationEffect(.degrees(turned ? 360 : 0))
            .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
        }
        .mask(shape.strokeBorder(lineWidth: Self.lineWidth))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear { startTurning() }
        .onChange(of: reduceMotion) { _, _ in startTurning() }
    }

    private func startTurning() {
        guard let animation = Self.rotation(reduceMotion: reduceMotion) else {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { turned = false }
            return
        }
        turned = false
        withAnimation(animation) { turned = true }
    }
}

// MARK: - Elapsed time

/// Timer: refreshes every second, 15 semibold monospaced digits, width 34.
private struct DictationElapsedText: View {
    let startedAt: Date

    private static let tint = Color.dynamic(light: 0x3F3F46, dark: 0xD4D4D8)

    var body: some View {
        #if DEBUG
        if let frozen = ComposerDictationBar.shotsFrozenElapsedSec {
            label(TimeInterval(frozen))
        } else {
            live
        }
        #else
        live
        #endif
    }

    private var live: some View {
        TimelineView(.periodic(from: startedAt, by: 1)) { context in
            label(context.date.timeIntervalSince(startedAt))
        }
    }

    private func label(_ elapsed: TimeInterval) -> some View {
        Text(DictationPresentation.formattedDuration(elapsed))
            .font(ComposerDictationBar.elapsedFont)
            .dynamicTypeSize(...ComposerDictationBar.dynamicTypeCap)
            .foregroundStyle(Self.tint)
            .lineLimit(1)
            // Same as "Done": on narrow screens shrinks to at most 0.75, never truncated.
            .minimumScaleFactor(ComposerDictationBar.minimumTextScale)
            .frame(minWidth: ComposerDictationBar.elapsedWidth)
    }
}

// MARK: - Recording row layout

/// Width allocation for the recording capsule row (✕, timer, waveform, "Done"): the timer and "Done" are never truncated.
/// At the original font size both take full width and the waveform gets the remaining width (bar count reduced by width); when that does not fit, the waveform drops to 0 bars,
/// and the timer and "Done" text shrink by the same ratio (not below minimumTextScale; minimumScaleFactor scales the text), always on one line.
struct DictationRecordingRowLayout: Layout {
    let spacing: CGFloat
    /// Sum of the "Done" capsule's horizontal insets; does not shrink with text scaling.
    let doneTextInset: CGFloat
    let minimumTextScale: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let widths = widths(for: proposal.width, subviews: subviews)
        let height = zip(subviews, widths)
            .map { $0.sizeThatFits(ProposedViewSize(width: $1, height: proposal.height)).height }
            .max() ?? 0
        let total = widths.reduce(0, +) + spacing * CGFloat(max(0, subviews.count - 1))
        return CGSize(width: proposal.width ?? total, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        for (subview, width) in zip(subviews, widths(for: bounds.width, subviews: subviews)) {
            subview.place(
                at: CGPoint(x: x, y: bounds.midY),
                anchor: .leading,
                proposal: ProposedViewSize(width: width, height: bounds.height)
            )
            x += width + spacing
        }
    }

    /// Item order is fixed: ✕, timer, waveform, "Done".
    private func widths(for available: CGFloat?, subviews: Subviews) -> [CGFloat] {
        let ideal = subviews.map { $0.sizeThatFits(.unspecified).width }
        guard subviews.count == 4, let available else { return ideal }
        let discard = ideal[0], elapsed = ideal[1], done = ideal[3]
        let rest = max(0, available - discard - spacing * 3)
        if elapsed + done <= rest {
            return [discard, elapsed, rest - elapsed - done, done]
        }
        let doneText = max(0, done - doneTextInset)
        let textual = elapsed + doneText
        let scale = textual > 0 ? max(minimumTextScale, min(1, (rest - doneTextInset) / textual)) : 1
        return [discard, elapsed * scale, 0, doneText * scale + doneTextInset]
    }
}

// MARK: - Waveform

/// Waveform (dictation visual contract, item 3): 22 vertical bars, newest on the right; only it observes levelMeter, so volume updates do not redraw the whole strip.
struct DictationWaveform: View {
    @ObservedObject var levelMeter: DictationLevelMeter

    static let barCount = 22
    static let barWidth: CGFloat = 3
    static let barCornerRadius: CGFloat = 2
    static let areaHeight: CGFloat = 28
    static let horizontalPadding: CGFloat = 4
    /// Color ring: bar i fades vertically from ring[k] to ring[k+1].
    static let ring: [Color] = [
        Color(hex: 0x6E8BFF),
        Color(hex: 0x9B6BFF),
        Color(hex: 0xE06BC4),
        Color(hex: 0xFFB36B),
        Color(hex: 0x66E0B8)
    ]

    var body: some View {
        let heights = Self.heights(for: levelMeter.levels)
        GeometryReader { proxy in
            // When the width fits fewer than 22 bars, only the newest ones are drawn (right-aligned); colors still use each bar's position among the 22.
            let count = Self.visibleBarCount(width: proxy.size.width)
            let first = heights.count - count
            HStack(alignment: .center, spacing: 0) {
                ForEach(first..<heights.count, id: \.self) { index in
                    let k = Self.ringIndex(for: index)
                    RoundedRectangle(cornerRadius: Self.barCornerRadius, style: .continuous)
                        .fill(LinearGradient(colors: [Self.ring[k], Self.ring[k + 1]], startPoint: .top, endPoint: .bottom))
                        .frame(width: Self.barWidth, height: heights[index])
                    if index < heights.count - 1 {
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(.horizontal, Self.horizontalPadding)
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .trailing)
        }
        .frame(height: Self.areaHeight)
        .animation(.linear(duration: 1 / DictationLevelMeter.maxUpdatesPerSecond), value: levelMeter.levels)
        .accessibilityHidden(true)
    }

    /// Minimum bar spacing; when the available width cannot fit 22 bars, the count is reduced by it.
    static let minimumBarGap: CGFloat = 1

    /// Number of bars that fit the given width (0–22).
    static func visibleBarCount(width: CGFloat) -> Int {
        let usable = width - 2 * horizontalPadding + minimumBarGap
        guard usable > 0 else { return 0 }
        return min(barCount, Int((usable / (barWidth + minimumBarGap)).rounded(.down)))
    }

    /// The last 22 cells of the level meter; when fewer, silence is padded on the left, and the newest cell is always on the right.
    static func displayed(_ levels: [Float]) -> [Float] {
        let tail = Array(levels.suffix(barCount))
        return Array(repeating: 0, count: barCount - tail.count) + tail
    }

    static func heights(for levels: [Float]) -> [CGFloat] {
        displayed(levels).enumerated().map { barHeight(level: $0.element, index: $0.offset) }
    }

    /// height = 4 + round(22 × clamp(v × (0.8 + 0.2 sin(1.9 i)), 0, 1)).
    static func barHeight(level: Float, index: Int) -> CGFloat {
        let scaled = Double(level) * (0.8 + 0.2 * sin(1.9 * Double(index)))
        return 4 + (22 * min(1, max(0, scaled))).rounded()
    }

    /// k = floor(i / 22 × 4).
    static func ringIndex(for index: Int) -> Int {
        Int((Double(index) / Double(barCount) * 4).rounded(.down))
    }
}

// MARK: - Busy

/// Busy state: system indeterminate progress spinner + transcribing label.
private struct DictationBusyIndicator: View {
    let activity: DictationBusyActivity

    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .progressViewStyle(.circular)
            Text(activity.localizedCaption)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(OriveoTheme.Palette.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)
        }
        .accessibilityElement(children: .combine)
    }
}
