import Combine
import SwiftUI

/// The five things the voice bar reads and writes: both the cascade and the realtime controller conform, so the voice bar and its host do not depend on a concrete controller.
/// Refreshes through ObservableObject's objectWillChange.
protocol VoiceConversationSurface: ObservableObject where ObjectWillChangePublisher == ObservableObjectPublisher {
    var statusKey: VoiceConversationLogic.StatusKey? { get }
    var displayState: VoiceConversationLogic.DisplayState? { get }
    var level: Double { get }
    func tapOrb()
    func toggleMute()
}

/// In-conversation voice bar: ✕ on the left, status orb + status text centered (one button as a whole), mute on the right.
/// Looks like the dictation recording bar: frosted glass + a 1.5pt static gradient hairline, 22 corner radius, with no outer glow or rotating ring.
struct VoiceConversationBar: View {
    let surface: any VoiceConversationSurface
    var page: VoiceConversationPage = .chat
    /// Transition namespace shared with ≋: ≋ moves to the center and fades into the status orb.
    var orbNamespace: Namespace.ID? = nil
    var onEnd: () -> Void

    var body: some View {
        observing(surface)
    }

    /// Opens the existential so @ObservedObject gets a concrete type.
    private func observing<Surface: VoiceConversationSurface>(_ surface: Surface) -> AnyView {
        AnyView(ObservedVoiceConversationBar(surface: surface, page: page, orbNamespace: orbNamespace, onEnd: onEnd))
    }

    /// Spring response 0.35 / damping 0.85; under Reduce Motion only a 200 ms fade in and out.
    static func transitionAnimation(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.35, dampingFraction: 0.85)
    }
}

/// Subscribes to seam changes and hands the five things to the voice bar itself.
private struct ObservedVoiceConversationBar<Surface: VoiceConversationSurface>: View {
    @ObservedObject var surface: Surface
    let page: VoiceConversationPage
    let orbNamespace: Namespace.ID?
    let onEnd: () -> Void

    var body: some View {
        #if DEBUG
        let _ = {
            if let key = surface.statusKey, !page.reachableStatusKeys.contains(key) {
                assertionFailure("voice bar on \(page) reached unreachable status \(key)")
            }
        }()
        #endif
        VoiceConversationBarContent(
            displayState: surface.displayState,
            statusKey: surface.statusKey,
            level: surface.level,
            orbNamespace: orbNamespace,
            onEnd: onEnd,
            onOrb: { [weak surface] in surface?.tapOrb() },
            onMute: { [weak surface] in surface?.toggleMute() }
        )
    }
}

/// Home bar feed: forwards the live surface while the home page still owns the conversation;
/// once handed off it stops forwarding changes and keeps the last home state it served,
/// so the fading / covered home bar never reads chat-only states.
final class HomeVoiceBarFeed: VoiceConversationSurface {
    let objectWillChange = ObservableObjectPublisher()
    let sourceID: ObjectIdentifier
    private let source: any VoiceConversationSurface
    private let isAttached: () -> Bool
    private var forwarding: AnyCancellable?
    private var lastStatusKey: VoiceConversationLogic.StatusKey?
    private var lastDisplayState: VoiceConversationLogic.DisplayState?
    private var lastLevel: Double

    init(source: any VoiceConversationSurface, isAttached: @escaping () -> Bool) {
        self.source = source
        self.sourceID = ObjectIdentifier(source)
        self.isAttached = isAttached
        lastStatusKey = source.statusKey
        lastDisplayState = source.displayState
        lastLevel = source.level
        forwarding = source.objectWillChange.sink { [weak self] _ in
            self?.forwardChange()
        }
    }

    /// Whether the home page still owns the conversation; drops the subscription on first detach.
    private var attached: Bool {
        guard forwarding != nil else { return false }
        if isAttached() { return true }
        forwarding = nil
        return false
    }

    private func forwardChange() {
        if attached { objectWillChange.send() }
    }

    var statusKey: VoiceConversationLogic.StatusKey? {
        if attached { lastStatusKey = source.statusKey }
        return lastStatusKey
    }

    var displayState: VoiceConversationLogic.DisplayState? {
        if attached { lastDisplayState = source.displayState }
        return lastDisplayState
    }

    var level: Double {
        if attached { lastLevel = source.level }
        return lastLevel
    }

    func tapOrb() {
        if attached { source.tapOrb() }
    }

    func toggleMute() {
        if attached { source.toggleMute() }
    }
}

/// Keeps one feed per home conversation so the bar keeps observing the same object across renders.
final class HomeVoiceBarFeedCache {
    private var feed: HomeVoiceBarFeed?

    func feed(for session: VoiceConversationSession) -> HomeVoiceBarFeed? {
        guard let source = session.homeVoiceSurface else {
            // Handed off or ended: drop the cached feed so it no longer retains the finished controller.
            feed = nil
            return nil
        }
        let id = ObjectIdentifier(source)
        if let feed, feed.sourceID == id { return feed }
        let created = HomeVoiceBarFeed(source: source) { [weak session] in
            guard let current = session?.homeVoiceSurface else { return false }
            return ObjectIdentifier(current) == id
        }
        feed = created
        return created
    }
}

/// The page a voice bar lives on. The home voice bar exists only until the first transcript is sent (the first send creates the conversation and moves to the chat page),
/// so the home page only ever shows listening / thinking / muted / error; speaking, speaking · tap to interrupt and waiting for you occur only on the chat page.
enum VoiceConversationPage: Equatable {
    case home
    case chat

    var reachableStatusKeys: Set<VoiceConversationLogic.StatusKey> {
        switch self {
        case .home: return [.listening, .thinking, .muted, .error]
        case .chat: return [.listening, .thinking, .speaking, .speakingTapToInterrupt, .muted, .awaitingApproval, .error]
        }
    }
}

/// Screenshot hook (DEBUG only): `-VOICE_CONVERSATION_DEMO <state>` parks the input area of the chat / home page in that voice bar state,
/// without opening the microphone or making sound. The state is a raw StatusKey value: listening, thinking, speaking, speakingTapToInterrupt, muted, awaitingApproval, error.
enum VoiceConversationDemo {
    private static let launchStatus: VoiceConversationLogic.StatusKey? = {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-VOICE_CONVERSATION_DEMO"), index + 1 < arguments.count else {
            return nil
        }
        return VoiceConversationLogic.StatusKey(rawValue: arguments[index + 1])
        #else
        return nil
        #endif
    }()

    #if DEBUG
    /// Sample shots only: overrides the state from the launch argument; when nil it still reads `-VOICE_CONVERSATION_DEMO`.
    static var shotsStatus: VoiceConversationLogic.StatusKey?
    #endif

    static var status: VoiceConversationLogic.StatusKey? {
        #if DEBUG
        if let shotsStatus { return shotsStatus }
        #endif
        return launchStatus
    }

    static var displayState: VoiceConversationLogic.DisplayState? {
        displayState(for: status)
    }

    static func displayState(for status: VoiceConversationLogic.StatusKey?) -> VoiceConversationLogic.DisplayState? {
        switch status {
        case .listening: return .listening
        case .thinking: return .thinking
        case .speaking, .speakingTapToInterrupt: return .speaking
        case .muted: return .muted
        case .awaitingApproval: return .awaitingApproval
        case .error: return .error
        case nil: return nil
        }
    }

    @ViewBuilder
    static var bar: some View {
        if let status {
            VoiceConversationBarContent(
                displayState: displayState,
                statusKey: status,
                level: status == .listening || status == .speaking ? 0.55 : 0,
                onEnd: {},
                onOrb: {},
                onMute: {}
            )
        }
    }
}

/// The voice bar itself: reads only the display state and leaves actions to the outside.
struct VoiceConversationBarContent: View {
    let displayState: VoiceConversationLogic.DisplayState?
    let statusKey: VoiceConversationLogic.StatusKey?
    let level: Double
    var orbNamespace: Namespace.ID? = nil
    var onEnd: () -> Void
    var onOrb: () -> Void
    var onMute: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var revealed = false

    static let minimumHitSize: CGFloat = 44
    static let orbSize: CGFloat = 30

    private var isMuted: Bool { displayState == .muted }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: ComposerDictationBar.cornerRadius, style: .continuous)
        HStack(spacing: Self.controlSpacing) {
            endButton
                .modifier(RevealModifier(revealed: revealed, reduceMotion: reduceMotion))
            orbButton
                .frame(maxWidth: .infinity)
                .layoutPriority(-1)
            muteButton
                .modifier(RevealModifier(revealed: revealed, reduceMotion: reduceMotion))
        }
        .padding(.horizontal, Self.barPadding)
        .padding(.vertical, 5)
        .frame(minHeight: 56)
        .background(.ultraThinMaterial, in: shape)
        .overlay {
            shape.strokeBorder(
                AngularGradient(
                    gradient: Gradient(colors: ComposerDictationBar.borderColors),
                    center: .center,
                    angle: .degrees(24)
                ),
                lineWidth: 1.5
            )
            .allowsHitTesting(false)
        }
        .onAppear {
            withAnimation(VoiceConversationBar.transitionAnimation(reduceMotion: reduceMotion)) { revealed = true }
        }
    }

    // MARK: Controls

    private var endButton: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            onEnd()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(OriveoTheme.Palette.textSecondary)
                .frame(width: 40, height: 40)
                .background(Circle().fill(Self.ghostFill))
                .frame(width: Self.minimumHitSize, height: Self.minimumHitSize)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(VoiceConversationCopy.endA11y)
        .accessibilityIdentifier("voice_conversation_end_button")
    }

    static let mutedForegroundUIColor = UIColor.oriveoDynamic(light: 0xFFFFFF, dark: \.bg)
    static let mutedForeground = Color(uiColor: mutedForegroundUIColor)

    private var muteButton: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            onMute()
        } label: {
            // Always a slashed microphone, inverted when muted.
            Image(systemName: "mic.slash")
                .font(.system(size: 15, weight: .semibold))
                // Inverted: the fill is textPrimary (the near-white palette text in dark mode), so the text is inverted: white in light mode, the palette bg in dark mode.
                .foregroundStyle(isMuted ? Self.mutedForeground : OriveoTheme.Palette.textSecondary)
                .frame(width: 40, height: 40)
                .background(Circle().fill(isMuted ? AnyShapeStyle(OriveoTheme.Palette.textPrimary) : AnyShapeStyle(Self.ghostFill)))
                .frame(width: Self.minimumHitSize, height: Self.minimumHitSize)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isMuted ? VoiceConversationCopy.unmuteA11y : VoiceConversationCopy.muteA11y)
        .accessibilityAddTraits(isMuted ? .isSelected : [])
    }

    /// The whole "orb + status text" block is one button of at least 44pt.
    private var orbButton: some View {
        Button {
            onOrb()
        } label: {
            // If it fits on one line the orb and status text sit side by side; if not (long locales / large type) the orb goes on top with the status text centered on at most 2 lines, never truncated.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Self.inlineSpacing) {
                    orb(size: Self.orbSize)
                    statusText.fixedSize()
                }
                VStack(spacing: 2) {
                    orb(size: Self.stackedOrbSize)
                    statusText
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, Self.labelPadding)
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, minHeight: Self.minimumHitSize)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(statusKey.map(VoiceConversationCopy.status) ?? "")
        .accessibilityHint(VoiceConversationCopy.orbHint(displayState) ?? "")
        .animation(.easeInOut(duration: 0.2), value: statusKey)
    }

    private func orb(size: CGFloat) -> some View {
        VoiceConversationOrb(state: displayState, level: level)
            .frame(width: size, height: size)
            .voiceOrbMatched(orbNamespace, reduceMotion: reduceMotion)
            .accessibilityHidden(true)
    }

    /// Geometry id shared by ≋ and the status orb.
    static let orbMatchID = "voice-conversation-orb"

    @ViewBuilder
    private var statusText: some View {
        if let key = statusKey {
            Text(VoiceConversationCopy.status(key))
                .font(Self.statusFont)
                .foregroundStyle(OriveoTheme.Palette.textPrimary)
                .minimumScaleFactor(Self.minimumScale)
                .dynamicTypeSize(...Self.maxDynamicType)
                .contentTransition(.opacity)
        }
    }

    // Layout constants: tests compute the available width for the status text from the same set.
    static let statusFont = Font.system(.callout, weight: .semibold)
    static let minimumScale: CGFloat = 0.85
    static let maxDynamicType = DynamicTypeSize.xLarge
    static let barPadding: CGFloat = 6
    static let controlSpacing: CGFloat = 8
    static let labelPadding: CGFloat = 4
    static let inlineSpacing: CGFloat = 10
    static let stackedOrbSize: CGFloat = 20

    /// The same light fill layer as the ghost buttons on the bottom bar.
    private static let ghostFill = Color.dynamic(light: 0x0F172A, dark: 0xFFFFFF, lightAlpha: 0.06, darkAlpha: 0.10)
}

/// ✕ and mute scale and fade in (under Reduce Motion, fade only).
private struct RevealModifier: ViewModifier {
    let revealed: Bool
    let reduceMotion: Bool

    func body(content: Content) -> some View {
        content
            .scaleEffect(revealed || reduceMotion ? 1 : 0.6)
            .opacity(revealed ? 1 : 0)
    }
}

// MARK: - Status orb

/// A soft glowing orb modeled on the swirl in the Oriveo logo: several radial gradients, no seams.
/// While listening / speaking it scales with the level; while thinking the colors inside flow slowly without rotating; muted / waiting / error are still and dimmed.
/// Under Reduce Motion only the opacity changes.
struct VoiceConversationOrb: View {
    let state: VoiceConversationLogic.DisplayState?
    let level: Double

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Logo colors: blue, purple, magenta, cyan.
    static let palette: [Color] = [
        Color(hex: 0x4F7BFF),
        Color.dynamic(light: 0x8B5CF6, dark: \.primary),
        Color(hex: 0xE04FC0),
        Color(hex: 0x38D6E8)
    ]

    private var isDimmed: Bool {
        switch state {
        case .muted, .awaitingApproval, .error, nil: return true
        case .listening, .thinking, .speaking: return false
        }
    }

    private var tracksLevel: Bool { state == .listening || state == .speaking }

    /// Level → scale; no scaling under Reduce Motion.
    static func scale(level: Double, tracksLevel: Bool, reduceMotion: Bool) -> CGFloat {
        guard tracksLevel, !reduceMotion else { return 1 }
        return 1 + 0.28 * CGFloat(min(1, max(0, level)))
    }

    /// Under Reduce Motion the level is expressed through opacity.
    static func opacity(level: Double, tracksLevel: Bool, dimmed: Bool, reduceMotion: Bool) -> Double {
        if dimmed { return 0.45 }
        guard reduceMotion, tracksLevel else { return 1 }
        return 0.6 + 0.4 * min(1, max(0, level))
    }

    var body: some View {
        let flowing = state == .thinking && !reduceMotion
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !flowing)) { context in
            let t = flowing ? context.date.timeIntervalSinceReferenceDate : 0
            orb(phase: t)
        }
        .scaleEffect(Self.scale(level: level, tracksLevel: tracksLevel, reduceMotion: reduceMotion))
        .opacity(Self.opacity(level: level, tracksLevel: tracksLevel, dimmed: isDimmed, reduceMotion: reduceMotion))
        .saturation(isDimmed ? 0.4 : 1)
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : .easeOut(duration: 0.08), value: level)
        .animation(.easeInOut(duration: 0.25), value: state)
    }

    /// The centers of several colored lights drift slowly along their own small ellipses (not a whole-orb rotation), and stacked together they give the flow inside.
    private func orb(phase t: Double) -> some View {
        GeometryReader { proxy in
            let size = min(proxy.size.width, proxy.size.height)
            ZStack {
                Circle().fill(Self.palette[1])
                ForEach(0..<Self.palette.count, id: \.self) { index in
                    let speed = 0.35 + 0.12 * Double(index)
                    let angle = t * speed + Double(index) * .pi / 2
                    let center = UnitPoint(
                        x: 0.5 + 0.28 * cos(angle),
                        y: 0.5 + 0.22 * sin(angle * 1.3)
                    )
                    Circle().fill(
                        RadialGradient(
                            colors: [Self.palette[index], Self.palette[index].opacity(0)],
                            center: center,
                            startRadius: 0,
                            endRadius: size * 0.62
                        )
                    )
                }
                // Highlight: a touch of white at the upper left to give the orb volume.
                Circle().fill(
                    RadialGradient(
                        colors: [Color.white.opacity(0.75), Color.white.opacity(0)],
                        center: UnitPoint(x: 0.32, y: 0.28),
                        startRadius: 0,
                        endRadius: size * 0.42
                    )
                )
            }
            .clipShape(Circle())
            .shadow(color: Self.palette[1].opacity(0.35), radius: size * 0.18, y: size * 0.06)
        }
    }
}

extension View {
    /// ≋ and the status orb share one geometry id: on entering, ≋ moves to the center and fades into the orb, and on exit it reverses; under Reduce Motion nothing moves, only a fade in and out.
    @ViewBuilder
    func voiceOrbMatched(_ namespace: Namespace.ID?, reduceMotion: Bool) -> some View {
        if let namespace, !reduceMotion {
            matchedGeometryEffect(id: VoiceConversationBarContent.orbMatchID, in: namespace)
        } else {
            self
        }
    }
}
