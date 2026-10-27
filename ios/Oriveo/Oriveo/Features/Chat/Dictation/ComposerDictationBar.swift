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
        case .transcribe: return L10n.tr("Transcribe", table: .voice)
        case .transcribeAndSend: return L10n.tr("Transcribe and Send", table: .voice)
        }
    }
}

/// Dictation input row: the recording bar (✕, timer, waveform, Transcribe, outer ↑) and the busy state (✕ + caption + progress).
/// The host draws the normal input row itself; this view draws nothing in `.normal`.
struct ComposerDictationBar: View {
    let mode: DictationInputRowMode
    let levelMeter: DictationLevelMeter
    /// Whether the host send button is currently enabled; ↑ follows it.
    let canSend: Bool
    let onDiscard: () -> Void
    let onTranscribe: () -> Void
    let onTranscribeAndSend: () -> Void

    /// Buttons shown per mode (the busy state keeps only ✕).
    static func controls(for mode: DictationInputRowMode) -> [DictationBarControl] {
        switch mode {
        case .normal: return []
        case .recording: return [.discard, .transcribe, .transcribeAndSend]
        case .busy: return [.discard]
        }
    }

    static let minimumHitSize: CGFloat = 44

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
            HStack(alignment: .bottom, spacing: 8) {
                shell {
                    discardButton
                    DictationElapsedText(startedAt: startedAt)
                    DictationWaveform(levelMeter: levelMeter)
                        .frame(maxWidth: .infinity)
                    transcribeButton
                }
                transcribeAndSendButton
                    .padding(.bottom, 5)
            }
        case .busy(let activity):
            shell {
                discardButton
                DictationBusyIndicator(activity: activity)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - Shell

    private func shell<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
        return HStack(alignment: .center, spacing: 8) {
            content()
        }
        .padding(.horizontal, 4)
        .frame(minHeight: 50)
        .background(.ultraThinMaterial, in: shape)
        .overlay {
            // Static gradient hairline: no glow, no rotation.
            shape.strokeBorder(
                AngularGradient(gradient: Gradient(colors: Self.borderColors), center: .center, angle: .degrees(24)),
                lineWidth: 1.5
            )
            .allowsHitTesting(false)
        }
    }

    static let cornerRadius: CGFloat = 22

    /// Same values as ChatComposerBar.aiBorderColors: blue → purple → magenta → warm → mint → back to blue.
    static let borderColors: [Color] = [
        Color(hex: 0x6E8BFF),
        Color(hex: 0x9B6BFF),
        Color(hex: 0xE06BC4),
        Color(hex: 0xFFB36B),
        Color(hex: 0x66E0B8),
        Color(hex: 0x6E8BFF)
    ]

    // MARK: - Buttons

    private var discardButton: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            onDiscard()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(OriveoTheme.Palette.textSecondary)
                .frame(width: Self.minimumHitSize, height: Self.minimumHitSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(DictationBarControl.discard.accessibilityLabel)
    }

    private var transcribeButton: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            onTranscribe()
        } label: {
            Text(DictationBarControl.transcribe.accessibilityLabel)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(OriveoTheme.Palette.primary)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .frame(minWidth: Self.minimumHitSize, minHeight: Self.minimumHitSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(DictationBarControl.transcribe.accessibilityLabel)
    }

    /// Outer purple ↑: styled like the send button in ChatComposerBar.composerActionCluster, with a 44pt hit area.
    private var transcribeAndSendButton: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            onTranscribeAndSend()
        } label: {
            Image(systemName: "arrow.up")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(canSend ? OriveoTheme.Palette.onPrimary : OriveoTheme.Palette.textTertiary)
                .frame(width: 40, height: 40)
                .background(
                    Circle()
                        .fill(canSend
                              ? AnyShapeStyle(OriveoTheme.Palette.primaryGradient)
                              : AnyShapeStyle(Color.dynamic(light: 0x8C5FF8, dark: 0xFFFFFF, lightAlpha: 0.12, darkAlpha: 0.10)))
                        .overlay(Circle().stroke(canSend ? OriveoTheme.Palette.hairline : .clear, lineWidth: 1))
                        .shadow(color: canSend ? OriveoTheme.Palette.primaryGlow : .clear, radius: 9, y: 5)
                )
                .frame(width: Self.minimumHitSize, height: Self.minimumHitSize)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .scaleEffect(canSend ? 1 : 0.96)
        .disabled(!canSend)
        .accessibilityLabel(DictationBarControl.transcribeAndSend.accessibilityLabel)
        .animation(.easeInOut(duration: 0.18), value: canSend)
    }
}

// MARK: - Elapsed time

/// Timer: refreshes every second, SF Rounded 15 medium with monospaced digits.
private struct DictationElapsedText: View {
    let startedAt: Date

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
            .font(.system(size: 15, weight: .medium, design: .rounded).monospacedDigit())
            .foregroundStyle(OriveoTheme.Palette.textPrimary)
            .lineLimit(1)
            .fixedSize()
    }
}

// MARK: - Waveform

/// Waveform: gradient bars; only this view observes levelMeter, so level updates do not redraw the whole bar.
private struct DictationWaveform: View {
    @ObservedObject var levelMeter: DictationLevelMeter

    private static let barWidth: CGFloat = 3
    private static let minBarHeight: CGFloat = 3
    private static let maxBarHeight: CGFloat = 24

    var body: some View {
        let levels = Self.padded(levelMeter.levels)
        LinearGradient(
            colors: ComposerDictationBar.borderColors,
            startPoint: .leading,
            endPoint: .trailing
        )
        .mask {
            HStack(alignment: .center, spacing: 0) {
                ForEach(levels.indices, id: \.self) { index in
                    Capsule()
                        .frame(width: Self.barWidth, height: Self.height(for: levels[index]))
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .frame(height: Self.maxBarHeight)
        .animation(.linear(duration: 1 / DictationLevelMeter.maxUpdatesPerSecond), value: levelMeter.levels)
        .accessibilityHidden(true)
    }

    /// Pads the left with silence when there are fewer than capacity samples, so the newest bar is always rightmost.
    private static func padded(_ levels: [Float]) -> [Float] {
        let missing = max(0, DictationLevelMeter.capacity - levels.count)
        return Array(repeating: 0, count: missing) + levels.suffix(DictationLevelMeter.capacity)
    }

    private static func height(for level: Float) -> CGFloat {
        minBarHeight + CGFloat(min(1, max(0, level))) * (maxBarHeight - minBarHeight)
    }
}

// MARK: - Busy

/// Busy state: system ProgressView + caption (determinate bar while preparing, indeterminate spinner while transcribing).
private struct DictationBusyIndicator: View {
    let activity: DictationBusyActivity

    var body: some View {
        HStack(spacing: 8) {
            if case .transcribing = activity {
                ProgressView()
                    .progressViewStyle(.circular)
            }
            Text(activity.localizedCaption)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(OriveoTheme.Palette.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)
            if case .preparing(let progress) = activity {
                // The circular style on iOS does not draw determinate progress, so the download uses a linear bar.
                ProgressView(value: min(1, max(0, progress)))
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 72)
                    .padding(.trailing, 12)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
