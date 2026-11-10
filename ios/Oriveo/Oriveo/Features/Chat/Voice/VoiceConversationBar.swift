import Combine
import SwiftUI

/// The five things the voice bar reads and writes: both the cascade and the realtime controller conform, so the voice bar and its host do not depend on a concrete controller.
/// Refreshes through ObservableObject's objectWillChange.
protocol VoiceConversationSurface: ObservableObject where ObjectWillChangePublisher == ObservableObjectPublisher {
    var statusKey: VoiceConversationLogic.StatusKey? { get }
    var displayState: VoiceConversationLogic.DisplayState? { get }
    var level: Double { get }
    /// Realtime subtitle for the cascaded conversation (shown in the caption state); the realtime engine does not provide it, default nil.
    var caption: String? { get }
    /// Realtime stage line: when non-nil the stage decides between subtitle and status line; the cascade does not provide it, default nil (uses statusKey == .caption).
    var stageLine: RealtimeConversationLogic.StageLine? { get }
    /// Number of light nudges to the status orb in this session (+1 when an echo is detected); the realtime engine does not provide it, default 0.
    var nudgeCount: Int { get }
    /// Hint for the idle resident voice dock ("Tap to start speaking"); an ongoing conversation is always nil.
    var idleHint: String? { get }
    /// Realtime session failure: the voice dock shows its copy in the status-line position, with recovery buttons below; nil when there is no failure.
    var failure: RealtimeVoiceFailure? { get }
    /// Whether the "Switch to typing" capsule is shown at the center of the voice dock's bottom row (switch to typing state): true only for the realtime idle dock; always false during an ongoing conversation.
    var showsTypingSwitch: Bool { get }
    /// Whether the end button (✕) is shown: true for an ongoing conversation; the realtime idle dock has no conversation to end, so false.
    var showsEndButton: Bool { get }
    /// Whether the mute button is shown: only during a session; the realtime idle dock has no open microphone, so false.
    var showsMuteButton: Bool { get }
    func tapOrb()
    func toggleMute()
    /// Tapped a failure recovery button (go to connection page / retry / switch model).
    func performFailureAction(_ action: RealtimeModelPolicy.FailureAction)
    /// Tapped the "Switch to typing" capsule: switch to typing state (only appears when showsTypingSwitch is true).
    func switchToTyping()
}

extension VoiceConversationSurface {
    var caption: String? { nil }
    var stageLine: RealtimeConversationLogic.StageLine? { nil }
    var nudgeCount: Int { 0 }
    var idleHint: String? { nil }
    var failure: RealtimeVoiceFailure? { nil }
    var showsTypingSwitch: Bool { false }
    var showsEndButton: Bool { true }
    var showsMuteButton: Bool { true }
    func performFailureAction(_ action: RealtimeModelPolicy.FailureAction) {}
    func switchToTyping() {}
}

/// Recognition language capsule: current recognition language name + tap action (opens the language form).
struct VoiceLanguageChip {
    let name: String
    let action: () -> Void
}

/// In-conversation voice stage (v3): aurora fog + liquid orb + two lines of subtitles, with mute (left) / end (right) 64pt round buttons at the bottom.
struct VoiceConversationBar: View {
    let surface: any VoiceConversationSurface
    var page: VoiceConversationPage = .chat
    /// Transition namespace shared with ≋: ≋ moves to the center and fades into the status orb.
    var orbNamespace: Namespace.ID? = nil
    /// Recognition language capsule (shown only in checkLanguage); nil means not shown.
    var languageChip: VoiceLanguageChip? = nil
    var onEnd: () -> Void

    var body: some View {
        observing(surface)
    }

    /// Opens the existential so @ObservedObject gets a concrete type.
    private func observing<Surface: VoiceConversationSurface>(_ surface: Surface) -> AnyView {
        AnyView(ObservedVoiceConversationBar(
            surface: surface, page: page, orbNamespace: orbNamespace, languageChip: languageChip, onEnd: onEnd
        ))
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
    let languageChip: VoiceLanguageChip?
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
            caption: surface.caption,
            stageLine: surface.stageLine,
            nudges: surface.nudgeCount,
            idleHint: surface.idleHint,
            failure: surface.failure,
            languageChip: languageChip,
            page: page,
            orbNamespace: orbNamespace,
            showsTypingSwitch: surface.showsTypingSwitch,
            showsEndButton: surface.showsEndButton,
            showsMuteButton: surface.showsMuteButton,
            onEnd: onEnd,
            onOrb: { [weak surface] in surface?.tapOrb() },
            onMute: { [weak surface] in surface?.toggleMute() },
            onFailureAction: { [weak surface] in surface?.performFailureAction($0) },
            onSwitchToTyping: { [weak surface] in surface?.switchToTyping() }
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
    private var lastCaption: String?
    private var lastStageLine: RealtimeConversationLogic.StageLine?
    private var lastNudgeCount: Int

    init(source: any VoiceConversationSurface, isAttached: @escaping () -> Bool) {
        self.source = source
        self.sourceID = ObjectIdentifier(source)
        self.isAttached = isAttached
        lastStatusKey = source.statusKey
        lastDisplayState = source.displayState
        lastLevel = source.level
        lastCaption = source.caption
        lastStageLine = source.stageLine
        lastNudgeCount = source.nudgeCount
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

    var caption: String? {
        if attached { lastCaption = source.caption }
        return lastCaption
    }

    var stageLine: RealtimeConversationLogic.StageLine? {
        if attached { lastStageLine = source.stageLine }
        return lastStageLine
    }

    var nudgeCount: Int {
        if attached { lastNudgeCount = source.nudgeCount }
        return lastNudgeCount
    }

    func tapOrb() {
        if attached { source.tapOrb() }
    }

    func toggleMute() {
        if attached { source.toggleMute() }
    }
}

/// Idle state of the resident voice dock: shown when a realtime item is selected and this page has no ongoing conversation.
/// Orb at rest + "Tap to start speaking", not connected, microphone not open; a tap hands off to the page and uses the same entry path as ≋.
/// After a failed previous session the status line switches to the failure copy and offers recovery: retry takes the same path as tapping the orb (max_duration tap = start a new session with history),
/// Going to the connection page / switching model is handled by the page.
final class RealtimeIdleStageSurface: VoiceConversationSurface {
    let objectWillChange = ObservableObjectPublisher()
    let failure: RealtimeVoiceFailure?
    private let onTap: () -> Void
    private let onFailureAction: (RealtimeModelPolicy.FailureAction) -> Void
    private let onSwitchToTyping: () -> Void

    init(
        failure: RealtimeVoiceFailure? = nil,
        onTap: @escaping () -> Void,
        onFailureAction: @escaping (RealtimeModelPolicy.FailureAction) -> Void = { _ in },
        onSwitchToTyping: @escaping () -> Void = {}
    ) {
        self.failure = failure
        self.onTap = onTap
        self.onFailureAction = onFailureAction
        self.onSwitchToTyping = onSwitchToTyping
    }

    /// The idle dock's bottom row center shows the "Switch to typing" capsule that switches to typing; with no ongoing conversation, no ✕ and no mute (mute is only during a session).
    var showsTypingSwitch: Bool { true }
    var showsEndButton: Bool { false }
    var showsMuteButton: Bool { false }
    func switchToTyping() { onSwitchToTyping() }

    var statusKey: VoiceConversationLogic.StatusKey? { nil }
    var displayState: VoiceConversationLogic.DisplayState? { nil }
    var level: Double { 0 }
    var idleHint: String? { failure == nil ? VoiceConversationCopy.tapToStartHint : nil }

    func tapOrb() { onTap() }

    func performFailureAction(_ action: RealtimeModelPolicy.FailureAction) {
        switch action {
        case .retry, .continueWithHistory: onTap()
        case .openConnection, .switchModel: onFailureAction(action)
        }
    }

    /// The microphone is not open while idle, so there is nothing to mute.
    func toggleMute() {}
}

/// Transition surface while the responder changes mid-conversation (engineSwitchMidSession): from the old session collapsing to the new session ending, this surface occupies the page,
/// the surface does not collapse and the orb does not change target. Before the new session connects it shows as connecting; after connecting it forwards everything from the new session,
/// and only the status line switches to "Switched to <model>" during the notice period (engineSwitchNoticeSeconds).
final class EngineSwitchStageSurface: VoiceConversationSurface {
    let objectWillChange = ObservableObjectPublisher()
    let host: VoiceConversationSession.HostKey
    let notice: String?
    private let noticeUntil: Date
    private let now: () -> Date
    private(set) var live: (any VoiceConversationSurface)?
    /// Session number of the new session being connected; ending this session removes the transition surface.
    private(set) var liveSerial: Int?
    private var forwarding: AnyCancellable?

    init(host: VoiceConversationSession.HostKey, notice: String?, noticeUntil: Date, now: @escaping () -> Date) {
        self.host = host
        self.notice = notice
        self.noticeUntil = noticeUntil
        self.now = now
    }

    func attach(_ surface: any VoiceConversationSurface, serial: Int) {
        live = surface
        liveSerial = serial
        forwarding = surface.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        objectWillChange.send()
    }

    /// Notice period over: have the surface re-read the status line.
    func noticeExpired() { objectWillChange.send() }

    private var showsNotice: Bool { notice != nil && now() < noticeUntil }

    var statusKey: VoiceConversationLogic.StatusKey? { live.map { $0.statusKey } ?? .thinking }
    var displayState: VoiceConversationLogic.DisplayState? { live.map { $0.displayState } ?? .thinking }
    var level: Double { live?.level ?? 0 }
    var caption: String? { live?.caption }
    var stageLine: RealtimeConversationLogic.StageLine? {
        if showsNotice, let notice { return .notice(notice) }
        return live?.stageLine
    }
    var nudgeCount: Int { live?.nudgeCount ?? 0 }
    var failure: RealtimeVoiceFailure? { live?.failure }
    var showsMuteButton: Bool { live?.showsMuteButton ?? false }

    func tapOrb() { live?.tapOrb() }
    func toggleMute() { live?.toggleMute() }
    func performFailureAction(_ action: RealtimeModelPolicy.FailureAction) { live?.performFailureAction(action) }
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

/// Peripheral effects of the voice stage on the chat page: page glow / aurora fade out; the stage panel is transparent, and the top of the message list fades via an alpha mask (no background layer).
enum VoiceStageChrome {
    /// Share of visible height over which the alpha mask fades the top edge of the list.
    static let listFadeFraction: CGFloat = 0.3

    /// Whether the voice stage is shown on this page (a real session, the resident idle dock in the realtime selected state, or the screenshot hook).
    static func isShown(session: VoiceConversationSession, conversationID: UUID?, realtimeSelected: Bool = false) -> Bool {
        (session.isPresented(in: conversationID) && session.surface != nil)
            || session.isEngineSwitching(in: conversationID)
            || realtimeSelected
            || VoiceConversationDemo.shows(on: .chat)
    }

    /// Page brand glow and aurora ambient base: 0 while the stage is up.
    static func pageGlowOpacity(stageShown: Bool) -> Double { stageShown ? 0 : 1 }

    /// Alpha mask fade on the top edge of the message list: 1 while the stage is up.
    static func listFadeOpacity(stageShown: Bool) -> Double { stageShown ? 1 : 0 }
}

/// The page hosting the voice dock. The home page's voice dock only exists before the first transcription is sent (the first send creates the session and moves to the chat page),
/// so the home page only shows listening / caption / thinking / muted / sayAgain / error (per fixture pageReachableStatusKeys); speaking, speaking · tap to interrupt, and awaiting confirmation only appear on the chat page.
enum VoiceConversationPage: Equatable {
    case home
    case chat

    var reachableStatusKeys: Set<VoiceConversationLogic.StatusKey> {
        switch self {
        case .home: return [.listening, .caption, .thinking, .muted, .sayAgain, .checkLanguage, .error]
        case .chat:
            return [
                .listening, .caption, .thinking, .speaking, .speakingTapToInterrupt, .muted, .awaitingApproval, .sayAgain,
                .checkLanguage, .error,
            ]
        }
    }
}

/// Screenshot hook (DEBUG only): `-VOICE_CONVERSATION_DEMO <state>` keeps the input area of the chat / home page on the voice dock's given state,
/// no microphone, no audio. State values are the raw StatusKey values: listening, caption, thinking, speaking, speakingTapToInterrupt, muted,
/// awaitingApproval, sayAgain, checkLanguage, error.
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
    /// Sample shots only: caption-state subtitle (manifest caption); nil shows no subtitle.
    static var shotsCaption: String?
    /// Sample shots only: fixed level (manifest level, 0…1; the voice dock page gives 0); nil uses the default demo level.
    static var shotsLevel: Double?
    /// Sample shots only: stage animation clock (seconds, manifest stageClockMs / 1000); orb and fog freeze at this moment; nil follows the wall clock.
    static var shotsStageClock: TimeInterval?
    /// Sample shots only: settings read by the recognition language capsule (sample UserDefaults suite); nil reads standard settings.
    static var shotsSettings: VoiceEngineSettings?
    /// Shots only: draw the demo bar on this page alone; nil draws it on both home and chat (launch-argument behavior).
    /// In two-pane wide layouts the home sidebar and the chat page share the screen, so an unscoped demo draws two
    /// voice stages.
    static var shotsPage: VoiceConversationPage?
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

    /// Whether this page draws the demo voice bar.
    static func shows(on page: VoiceConversationPage) -> Bool {
        guard status != nil else { return false }
        #if DEBUG
        if let shotsPage { return shotsPage == page }
        #endif
        return true
    }

    static func displayState(for status: VoiceConversationLogic.StatusKey?) -> VoiceConversationLogic.DisplayState? {
        switch status {
        case .listening: return .listening
        case .caption: return .userSpeaking
        case .thinking: return .thinking
        case .speaking, .speakingTapToInterrupt: return .speaking
        case .sayAgain: return .sayAgain
        case .checkLanguage: return .checkLanguage
        case .muted: return .muted
        case .awaitingApproval: return .awaitingApproval
        case .error: return .error
        case nil: return nil
        }
    }

    /// Demo level: uses the fixed value if the sample provides one, otherwise the default demo value.
    static func level(default value: Double = 0.55) -> Double {
        #if DEBUG
        if let shotsLevel { return shotsLevel }
        #endif
        return value
    }

    /// Stage clock override: only provided by sample shots.
    static var stageClock: TimeInterval? {
        #if DEBUG
        return shotsStageClock
        #else
        return nil
        #endif
    }

    /// Demo subtitle: only provided by sample shots.
    static var caption: String? {
        #if DEBUG
        return shotsCaption
        #else
        return nil
        #endif
    }

    /// Recognition language capsule for checkLanguage: language name uses the same display function as the production capsule; tapping does nothing in the demo. nil for other states.
    static func languageChip(for status: VoiceConversationLogic.StatusKey?) -> VoiceLanguageChip? {
        guard status == .checkLanguage else { return nil }
        var settings = VoiceEngineSettings()
        #if DEBUG
        if let shotsSettings { settings = shotsSettings }
        #endif
        return VoiceLanguageChip(name: RecognitionLanguageSheetModel.displayName(settings.recognitionLanguage), action: {})
    }

    @ViewBuilder
    static func bar(page: VoiceConversationPage = .chat, level: Double = 0.55) -> some View {
        if let status {
            VoiceConversationBarContent(
                displayState: displayState,
                statusKey: status,
                level: Self.level(default: level),
                caption: caption,
                languageChip: languageChip(for: status),
                page: page,
                onEnd: {},
                onOrb: {},
                onMute: {}
            )
            .environment(\.voiceStageClock, stageClock)
        }
    }
}

/// Voice stage body: read-only display state; actions are handed to the caller.
/// From top: 148pt liquid orb (18 from top) → two lines of subtitle / status (30 below the orb's bottom) → recognition language capsule (14 below subtitle, only in checkLanguage);
/// mute (left) / end (right) two 64pt round buttons at the bottom, 20 from the content bottom and 44 inset left and right. The aurora fog fills the panel and overflows downward.
struct VoiceConversationBarContent: View {
    let displayState: VoiceConversationLogic.DisplayState?
    let statusKey: VoiceConversationLogic.StatusKey?
    let level: Double
    var caption: String? = nil
    /// Realtime stage line; nil = cascaded (caption is shown when statusKey == .caption).
    var stageLine: RealtimeConversationLogic.StageLine? = nil
    /// Number of light nudges to the status orb (+1 when an echo is detected).
    var nudges: Int = 0
    /// Hint for the idle resident voice dock; shown in the status-line position when statusKey is nil.
    var idleHint: String? = nil
    /// Realtime session failure: a failure card floats below the orb (title = failure copy, primary action on the right); the status-line position is left empty.
    var failure: RealtimeVoiceFailure? = nil
    var languageChip: VoiceLanguageChip? = nil
    var page: VoiceConversationPage = .chat
    var orbNamespace: Namespace.ID? = nil
    /// Realtime idle dock: the "Switch to typing" capsule appears at the bottom center (switches to typing); no mute or end buttons.
    var showsTypingSwitch: Bool = false
    var showsEndButton: Bool = true
    var showsMuteButton: Bool = true
    var onEnd: () -> Void
    var onOrb: () -> Void
    var onMute: () -> Void
    var onFailureAction: (RealtimeModelPolicy.FailureAction) -> Void = { _ in }
    var onSwitchToTyping: () -> Void = {}

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var revealed = false
    @State private var textWidth: CGFloat = 0

    private var isMuted: Bool { displayState == .muted }
    private var orbMode: VoiceOrbMode { Self.orbMode(statusKey: statusKey, displayState: displayState) }
    private var notice: Bool { Self.fogNotice(statusKey: statusKey) }

    /// Stage height = max(366, required by content): when enlarged text overflows, the stage grows upward (compressing the message stream above); the two buttons stay anchored to the bottom edge, and the orb and buttons do not scale.
    var body: some View {
        // No Spacer: the stage height is determined only by its content, not by filling the parent container's height.
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                orbButton
                if let failure {
                    failureCard(failure)
                        .padding(.top, Self.chipSpacing)
                        .transition(.opacity)
                }
                if Self.showsLanguageChip(statusKey: statusKey, chip: languageChip), let languageChip {
                    chipButton(languageChip)
                        .padding(.top, Self.chipSpacing)
                        .transition(.opacity)
                }
            }
            .frame(minHeight: Self.stageContentHeight - Self.controlsGap - Self.buttonSize - Self.buttonBottom, alignment: .top)
            controls
                .padding(.top, Self.controlsGap)
        }
        .frame(maxWidth: .infinity)
        .background(alignment: .bottom) { panelBackground }
        .dynamicTypeSize(...Self.maxTextSize)
        .animation(.easeInOut(duration: 0.2), value: statusKey)
        .onAppear {
            withAnimation(VoiceConversationBar.transitionAnimation(reduceMotion: reduceMotion)) { revealed = true }
        }
    }

    // MARK: Panel

    /// Panel bottom: transparent (does not paint the page background; the list fades out via the ChatListEdgeFade mask) + aurora fog (frame see VoiceOrbMath.fogFrame:
    /// width = panel + 80, height 520, bottom edge extends 120 below the screen bottom (stage bottom + bottom safe area), moves with the stage bottom). When the stage grows taller, the fog moves down with the bottom.
    private var panelBackground: some View {
        ZStack(alignment: .bottom) {
            // Fog layer extends to the screen bottom: measure the bottom safe area; the frame is computed by VoiceOrbMath.fogFrame (bottom = stage bottom + safe area + 120).
            GeometryReader { proxy in
                let inset = Double(proxy.safeAreaInsets.bottom)
                let fog = VoiceOrbMath.fogFrame(
                    panelSize: CGSize(width: proxy.size.width, height: max(0, Double(proxy.size.height) - inset)),
                    bottomInset: inset
                )
                VoiceAuroraFog(mode: orbMode, level: level, notice: notice)
                    .frame(width: fog.width, height: fog.height)
                    .offset(x: fog.minX, y: fog.minY)
            }
            .ignoresSafeArea(.container, edges: .bottom)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: Orb + caption

    /// The orb and subtitle form one button (interrupt / mark finished); the screen-reader label and hint are unchanged.
    private var orbButton: some View {
        Button {
            onOrb()
        } label: {
            VStack(spacing: Self.captionSpacing) {
                VoiceAuroraOrb(mode: orbMode, level: level, nudges: nudges, notice: notice, size: Self.orbSize)
                    .voiceOrbMatched(orbNamespace, reduceMotion: reduceMotion)
                    .padding(.top, Self.orbTop)
                    .accessibilityHidden(true)
                statusText
                    .frame(maxWidth: .infinity)
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { textWidth = $0 }
                    .padding(.horizontal, Self.captionInset)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            failure.map(VoiceConversationCopy.failure)
                ?? Self.notice(stageLine)
                ?? statusKey.map { VoiceConversationCopy.status($0, caption: caption) } ?? idleHint ?? ""
        )
        .accessibilityHint(VoiceConversationCopy.orbHint(displayState) ?? "")
        .accessibilityIdentifier("voice_conversation_orb_button")
    }

    @ViewBuilder
    private var statusText: some View {
        if failure != nil {
            // Failure copy lives in the failure card title, so it is not repeated in the status-line position.
            EmptyView()
        } else if let caption = Self.stageCaption(statusKey: statusKey, caption: caption, stageLine: stageLine) {
            let captionFont = Self.captionUIFont(dynamicTypeSize)
            let fitted = textWidth > 0
                ? Self.headTruncated(caption, font: captionFont, width: textWidth, lines: 2)
                : caption
            // The engine-switch notice is a single status line, with no light / bright split like subtitles.
            let segments = if case .notice = stageLine { (dim: "", bright: fitted) } else { Self.captionSegments(fitted) }
            (Text(segments.dim).foregroundStyle(Self.captionDim)
                + Text(segments.bright).foregroundStyle(OriveoTheme.Palette.textPrimary))
                .font(Font(captionFont))
                .tracking(Self.captionTracking)
                .lineSpacing(Self.lineSpacing(for: captionFont))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        } else if let key = statusKey {
            let font = Self.statusUIFont(for: key, size: dynamicTypeSize)
            let isNotice = Self.fogNotice(statusKey: key)
            Text(VoiceConversationCopy.status(key))
                .font(Font(font))
                .tracking(isNotice ? Self.captionTracking : 0)
                .lineSpacing(isNotice ? Self.lineSpacing(for: font) : 0)
                .foregroundStyle(isNotice ? Self.noticeColor : Self.statusColor)
                .lineLimit(Self.statusLineLimit)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .contentTransition(.opacity)
        } else if let idleHint {
            let font = Self.statusUIFont(for: .listening, size: dynamicTypeSize)
            Text(idleHint)
                .font(Font(font))
                .foregroundStyle(Self.statusColor)
                .lineLimit(Self.statusLineLimit)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .contentTransition(.opacity)
        }
    }

    /// Text shown on the stage for subtitles, nil = status line. The realtime dock uses stageLine (user subtitle / revealed text shows text, status shows the status line);
    /// the cascade dock shows caption only when statusKey == .caption.
    static func stageCaption(
        statusKey: VoiceConversationLogic.StatusKey?,
        caption: String?,
        stageLine: RealtimeConversationLogic.StageLine?
    ) -> String? {
        let text: String? = switch stageLine {
        case let .user(line), let .assistant(line), let .notice(line): line
        case .status: nil
        case nil: statusKey == .caption ? caption : nil
        }
        guard let text, !text.isEmpty else { return nil }
        return text
    }

    /// Text of the engine-switch notice (for the screen-reader label); nil when it is not a notice.
    static func notice(_ stageLine: RealtimeConversationLogic.StageLine?) -> String? {
        if case let .notice(text) = stageLine { return text }
        return nil
    }

    // MARK: Failure card

    /// Recovery options with button text, left to right per classification.buttonCopyKeys: secondary action first, primary action (actions[0]) on the right;
    /// continueWithHistory is the tap-the-orb action itself and shows no button (max_duration card has no button).
    static func failureButtons(_ failure: RealtimeVoiceFailure) -> [RealtimeModelPolicy.FailureAction] {
        failure.classification.actions.reversed().filter { VoiceConversationCopy.failureAction($0) != nil }
    }

    static let failureCardRadius: CGFloat = OriveoTheme.Radius.hero
    static let failureCardPadding: CGFloat = 16
    static let failureCardSpacing: CGFloat = 14
    static let failureCardHairline: CGFloat = 0.5
    static let failureIconSize: CGFloat = 40
    static let failureGlyphSize: CGFloat = 19
    static let failureTitleSize: CGFloat = 17
    static let failureButtonHeight: CGFloat = 40
    static let failureButtonSpacing: CGFloat = 10

    static func failureTitleUIFont(_ size: DynamicTypeSize) -> UIFont {
        scaled(UIFont.systemFont(ofSize: failureTitleSize, weight: .semibold), .body, size)
    }

    /// Failure card: 24pt rounded floating card (surfaceElevated + shadow + 0.5pt border hairline); left 40pt amber circle + waveform 19, right title 17;
    /// the button row is 40 high split evenly; primary action brand gradient on the right, secondary action gray fill on the left; colors only come from theme tokens.
    private func failureCard(_ failure: RealtimeVoiceFailure) -> some View {
        let actions = Self.failureButtons(failure)
        let primary = failure.classification.actions.first
        let shape = RoundedRectangle(cornerRadius: Self.failureCardRadius, style: .continuous)
        return VStack(alignment: .leading, spacing: Self.failureCardSpacing) {
            HStack(spacing: 12) {
                Image(systemName: "waveform")
                    .font(.system(size: Self.failureGlyphSize, weight: .semibold))
                    .foregroundStyle(OriveoTheme.Palette.warning)
                    .frame(width: Self.failureIconSize, height: Self.failureIconSize)
                    .background(Circle().fill(OriveoTheme.Palette.warningSoft))
                    .accessibilityHidden(true)
                // The screen reader reads the failure copy from the orb button's label, so it is not repeated here.
                Text(VoiceConversationCopy.failure(failure))
                    .font(Font(Self.failureTitleUIFont(dynamicTypeSize)))
                    .foregroundStyle(OriveoTheme.Palette.textPrimary)
                    .lineLimit(Self.statusLineLimit)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityHidden(true)
            }
            if !actions.isEmpty {
                HStack(spacing: Self.failureButtonSpacing) {
                    ForEach(Array(actions.enumerated()), id: \.offset) { _, action in
                        failureButton(action, primary: action == primary)
                    }
                }
            }
        }
        .padding(Self.failureCardPadding)
        .background {
            shape.fill(OriveoTheme.Palette.surfaceElevated)
                .shadow(color: OriveoTheme.Palette.shadow, radius: 18, y: 8)
        }
        .overlay(shape.strokeBorder(OriveoTheme.Palette.border, lineWidth: Self.failureCardHairline))
        .padding(.horizontal, Self.chipLeading + Self.chipTrailing)
    }

    private func failureButton(_ action: RealtimeModelPolicy.FailureAction, primary: Bool) -> some View {
        let title = VoiceConversationCopy.failureAction(action) ?? ""
        let shape = Capsule(style: .continuous)
        return Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            onFailureAction(action)
        } label: {
            Text(title)
                .font(Font(Self.chipUIFont(dynamicTypeSize)).weight(.semibold))
                .foregroundStyle(primary ? OriveoTheme.Palette.onPrimary : OriveoTheme.Palette.secondaryActionText)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity, minHeight: Self.failureButtonHeight)
                .background {
                    if primary {
                        shape.fill(OriveoTheme.Palette.primaryGradient)
                    } else {
                        shape.fill(OriveoTheme.Palette.secondaryActionFill)
                    }
                }
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityIdentifier(Self.failureAccessibilityID(action))
    }

    static func failureAccessibilityID(_ action: RealtimeModelPolicy.FailureAction) -> String {
        switch action {
        case .openConnection: "voice_conversation_failure_open_connection_button"
        case .retry: "voice_conversation_failure_retry_button"
        case .switchModel, .continueWithHistory: "voice_conversation_failure_switch_model_button"
        }
    }

    // MARK: Language chip

    private func chipButton(_ chip: VoiceLanguageChip) -> some View {
        Button {
            chip.action()
        } label: {
            Self.chipLabel(title: Self.languageChipTitle(chip.name), dark: colorScheme == .dark, size: dynamicTypeSize)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("voice_conversation_language_chip")
    }

    /// Capsule appearance: font size follows the system font size (relative to subheadline, capped at accessibility2), up to three lines without truncation, at least 36 high, growing with content.
    static func chipLabel(title: String, dark: Bool, size: DynamicTypeSize) -> some View {
        let shape = Capsule(style: .continuous)
        return HStack(spacing: chipIconSpacing) {
            Image(systemName: "globe")
                .font(Font(chipIconUIFont(size)))
            Text(title)
                .font(Font(chipUIFont(size)))
                .lineLimit(chipLineLimit)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(dark ? Color(hex: 0xEDE9FE) : Color(hex: 0x6D28D9))
        .padding(.leading, chipLeading)
        .padding(.trailing, chipTrailing)
        .padding(.vertical, chipVerticalPadding)
        .frame(minHeight: chipMinHeight)
        // dark-palette-guard: keep (c) voice-stage fixed colors; the contract stage layout is fixed and does not follow the palette.
        .background(shape.fill(dark ? Color(hex: 0xA78BFA).opacity(0.20) : Color(hex: 0x7C4DFF).opacity(0.10))) // capability-ui-lint: allow voice / dictation capsule brand violet, not a capability colour
        .overlay {
            // dark-palette-guard: keep (c) voice-stage fixed colors; the contract stage layout is fixed and does not follow the palette.
            if dark { shape.strokeBorder(Color(hex: 0xC4B5FD).opacity(0.35), lineWidth: 0.5) }
        }
        .contentShape(shape)
    }

    /// Width taken by the capsule other than its text (left/right inset + globe icon + spacing).
    static func chipTextInset(_ size: DynamicTypeSize) -> CGFloat {
        let icon = UIImage(systemName: "globe", withConfiguration: UIImage.SymbolConfiguration(font: chipIconUIFont(size)))
        return chipLeading + chipTrailing + chipIconSpacing + (icon?.size.width ?? chipIconUIFont(size).pointSize * 1.2)
    }

    // MARK: Controls

    /// In progress: mute (left) / end (right); realtime idle dock: only the center "Switch to typing" capsule, no mute and no end button.
    /// Placement comes from controlSlots; each control is vertically centered in a 64-high row, on the same center line.
    /// When opening, the capsule fades out and the two buttons appear from 0.6 → 1 (Reduce Motion: fade only).
    private var controls: some View {
        let slots = Self.controlSlots(
            showsTypingSwitch: showsTypingSwitch,
            showsMuteButton: showsMuteButton,
            showsEndButton: showsEndButton
        )
        return HStack(spacing: 0) {
            control(at: .leading, in: slots)
            Spacer(minLength: 0)
            control(at: .center, in: slots)
            Spacer(minLength: 0)
            control(at: .trailing, in: slots)
        }
        .frame(height: Self.buttonSize)
        .animation(VoiceConversationBar.transitionAnimation(reduceMotion: reduceMotion), value: showsTypingSwitch)
        .padding(.horizontal, Self.buttonInset)
        .padding(.bottom, Self.buttonBottom)
        .modifier(RevealModifier(revealed: revealed, reduceMotion: reduceMotion))
    }

    @ViewBuilder
    private func control(at placement: ControlPlacement, in slots: [ControlSlot]) -> some View {
        if let slot = slots.first(where: { $0.placement == placement }) {
            switch slot.kind {
            case .typingCapsule:
                typingCapsule
                    .transition(.opacity)
            case .mute:
                muteButton
                    .transition(buttonTransition)
            case .end:
                endButton
                    .transition(buttonTransition)
            }
        }
    }

    private var buttonTransition: AnyTransition {
        reduceMotion ? .opacity : .scale(scale: 0.6).combined(with: .opacity)
    }

    private var endButton: some View {
        let dark = colorScheme == .dark
        return Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            onEnd()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: Self.buttonSize, height: Self.buttonSize)
                .background {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [Color(hex: 0xFF5A52), Color(hex: 0xE8382F)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                            .shadow(.inner(color: .white.opacity(0.32), radius: 0.5, x: 0, y: 1))
                        )
                        .shadow(color: Color(hex: 0xE8382F).opacity(dark ? 0.42 : 0.30), radius: 12, x: 0, y: 10)
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(VoiceConversationCopy.endA11y)
        .accessibilityIdentifier("voice_conversation_end_button")
    }

    /// The "Switch to typing" capsule at the center of the realtime idle dock's bottom row: 36 high, 14 horizontal inset, thin material background + 0.5 hairline; tap switches to typing; hit area 44.
    private var typingCapsule: some View {
        let dark = colorScheme == .dark
        let shape = Capsule(style: .continuous)
        return Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            onSwitchToTyping()
        } label: {
            HStack(spacing: Self.chipIconSpacing) {
                Image(systemName: "keyboard")
                    .font(.system(size: 15, weight: .medium))
                Text(Self.typingCapsuleTitle)
                    .font(Font(Self.rounded(14.5, .semibold)))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            // dark-palette-guard: keep (c) voice-stage fixed colors; the contract stage layout is fixed and does not follow the palette.
            .foregroundStyle(dark ? Color(hex: 0xC4B5FD) : Color(hex: 0x7C4DFF))
            .padding(.horizontal, Self.typingCapsulePadding)
            .frame(height: Self.typingCapsuleHeight)
            .background(.ultraThinMaterial, in: shape)
            .overlay {
                // dark-palette-guard: keep (c) voice-stage fixed colors; the contract stage layout is fixed and does not follow the palette.
                shape.strokeBorder(dark ? Color.white.opacity(0.10) : Color(hex: 0x7C3AED).opacity(0.16), lineWidth: 0.5) // capability-ui-lint: allow voice / dictation capsule brand violet, not a capability colour
            }
            .frame(minHeight: Self.typingCapsuleHitHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Self.typingCapsuleTitle)
        .accessibilityIdentifier("realtime_voice_dock_keyboard_button")
    }

    /// Foreground of the muted-state mic.slash: white in light mode, #18181B in dark mode.
    static let mutedForegroundUIColor = UIColor { trait in
        UIColor(oriveoHex: trait.userInterfaceStyle == .dark ? 0x18181B : 0xFFFFFF, alpha: 1)
    }
    static let mutedForeground = Color(uiColor: mutedForegroundUIColor)
    // dark-palette-guard: keep (c) voice-stage fixed colors; the contract stage layout is fixed and does not follow the palette.
    /// Solid fill for the muted state: #7C4DFF in light mode, #C4B5FD in dark mode.
    static let mutedFillUIColor = UIColor { trait in
        // dark-palette-guard: keep (c) voice-stage fixed colors; the contract stage layout is fixed and does not follow the palette.
        UIColor(oriveoHex: trait.userInterfaceStyle == .dark ? 0xC4B5FD : 0x7C4DFF, alpha: 1)
    }

    private var muteButton: some View {
        let dark = colorScheme == .dark
        return Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            onMute()
        } label: {
            Image(systemName: isMuted ? "mic.slash" : "mic")
                .font(.system(size: 25, weight: .medium))
                // dark-palette-guard: keep (c) voice-stage fixed colors; the contract stage layout is fixed and does not follow the palette.
                .foregroundStyle(isMuted ? Self.mutedForeground : (dark ? Color(hex: 0xC4B5FD) : Color(hex: 0x7C4DFF)))
                .frame(width: Self.buttonSize, height: Self.buttonSize)
                .background {
                    if isMuted {
                        Circle()
                            .fill(Color(uiColor: Self.mutedFillUIColor)
                                .shadow(.inner(color: .white.opacity(0.32), radius: 0.5, x: 0, y: 1)))
                    } else {
                        Circle()
                            .fill(Color.white.opacity(dark ? 0.10 : 0.78)
                                .shadow(.inner(color: .white.opacity(0.32), radius: 0.5, x: 0, y: 1)))
                            .overlay {
                                Circle().strokeBorder(
                                    dark ? Color.white.opacity(0.10) : Color(hex: 0x7C3AED).opacity(0.16), // capability-ui-lint: allow voice / dictation capsule brand violet, not a capability colour
                                    lineWidth: 0.5
                                )
                            }
                            .shadow(color: dark ? .clear : Color(hex: 0x5B21B6).opacity(0.14), radius: 12, x: 0, y: 10)
                    }
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isMuted ? VoiceConversationCopy.unmuteA11y : VoiceConversationCopy.muteA11y)
        .accessibilityAddTraits(isMuted ? .isSelected : [])
        .accessibilityIdentifier("voice_conversation_mute_button")
    }

    /// Geometry id shared by ≋ and the status orb.
    static let orbMatchID = "voice-conversation-orb"

    // MARK: Mapping

    /// Status → orb mode (contract stage layout, item 5): under listening, the user counts as User once they have started speaking.
    static func orbMode(
        statusKey: VoiceConversationLogic.StatusKey?,
        displayState: VoiceConversationLogic.DisplayState?
    ) -> VoiceOrbMode {
        switch statusKey {
        case .listening: return displayState == .userSpeaking ? .user : .listen
        case .caption: return .user
        case .thinking: return .think
        case .speaking, .speakingTapToInterrupt: return .ai
        case .muted, .awaitingApproval, .error, nil: return .muted
        case .sayAgain, .checkLanguage: return .listen
        }
    }

    /// The two "didn't catch that" states: fog turns amber, status text amber 20 semibold.
    static func fogNotice(statusKey: VoiceConversationLogic.StatusKey?) -> Bool {
        statusKey == .sayAgain || statusKey == .checkLanguage
    }

    /// Capsule copy (voice_conversation_language_chip); each language carries its own punctuation.
    static func languageChipTitle(_ name: String) -> String {
        L10n.format(L10n.tr("Recognition Language: %1$@", table: .voice), name)
    }

    static func showsLanguageChip(statusKey: VoiceConversationLogic.StatusKey?, chip: VoiceLanguageChip?) -> Bool {
        statusKey == .checkLanguage && chip != nil
    }

    /// Caption highlight split (voice-conversation.v1 captionHighlight): for Han / kana / Hangul, count code points from the end by grapheme cluster until ≥ 8,
    /// otherwise take the last 3 words after whitespace tokenization (≤ 3 words: whole sentence lit); no trim, the segment before the lit part is in the light color. If a code-point boundary falls mid-grapheme, the whole grapheme goes to the lit segment.
    static func captionSegments(_ text: String) -> (dim: String, bright: String) {
        if !containsCJK(text) {
            let words = text.split(whereSeparator: \.isWhitespace)
            guard words.count > captionBrightWords else { return ("", text) }
            let start = words[words.count - captionBrightWords].startIndex
            return (String(text[..<start]), String(text[start...]))
        }
        var start = text.endIndex
        var scalars = 0
        while start > text.startIndex, scalars < captionBrightScalars {
            start = text.index(before: start)
            scalars += text[start].unicodeScalars.count
        }
        return (String(text[..<start]), String(text[start...]))
    }

    private static let cjkScript = try! NSRegularExpression(pattern: "[\\p{Han}\\p{Hiragana}\\p{Katakana}\\p{Hangul}]")

    /// Only treats text scripts Han / Hiragana / Katakana / Hangul as CJK (full-width punctuation and full-width Latin do not count), consistent with the fixture reference implementation's
    /// \p{Script=…} and Android UnicodeScript.
    /// The whole string runs the regex once (static compile) to decide whether it contains CJK script, rather than matching scalar by scalar.
    static func containsCJK(_ text: String) -> Bool {
        cjkScript.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// When lines exceed the limit, trim from the start and add "…", keeping the end.
    static func headTruncated(_ text: String, font: UIFont, width: CGFloat, lines: Int) -> String {
        func fits(_ candidate: String) -> Bool {
            let rect = (candidate as NSString).boundingRect(
                with: CGSize(width: width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: font, .kern: captionTracking],
                context: nil
            )
            return Int((rect.height / font.lineHeight).rounded(.up)) <= lines
        }
        guard width > 0, !fits(text) else { return text }
        let characters = Array(text)
        var low = 1
        var high = characters.count
        while low < high {
            let mid = (low + high) / 2
            if fits("…" + String(characters[mid...])) { high = mid } else { low = mid + 1 }
        }
        return "…" + String(characters[min(low, characters.count)...])
    }

    static func lineSpacing(for font: UIFont) -> CGFloat {
        max(0, font.pointSize * captionLineHeight - font.lineHeight)
    }

    private static func rounded(_ size: CGFloat, _ weight: UIFont.Weight) -> UIFont {
        let base = UIFont.systemFont(ofSize: size, weight: weight)
        guard let descriptor = base.fontDescriptor.withDesign(.rounded) else { return base }
        return UIFont(descriptor: descriptor, size: size)
    }

    // MARK: Layout constants (contract stage layout; tests compute with the same set of numbers)

    /// Minimum stage content height; grows with content when content overflows.
    static let stageContentHeight: CGFloat = 366
    /// Minimum distance between the orb / subtitle / capsule and the two bottom buttons (default size: single-line status + capsule exactly 366).
    static let controlsGap: CGFloat = 12
    /// Status text (listening / thinking / didn't catch that, etc.) up to three lines without truncation; subtitles still truncate the head at two lines.
    static let statusLineLimit = 3
    static let orbSize: CGFloat = 148
    static let orbTop: CGFloat = 18
    static let captionSpacing: CGFloat = 30
    static let captionInset: CGFloat = 36
    static let chipSpacing: CGFloat = 14
    static let buttonSize: CGFloat = 64
    static let buttonInset: CGFloat = 44
    static let buttonBottom: CGFloat = 20
    static let captionTracking: CGFloat = -0.3
    static let captionLineHeight: CGFloat = 1.32
    static let captionBrightScalars = 8
    static let captionBrightWords = 3

    // MARK: Controls layout

    /// Bottom-row control kinds: "Switch to typing" capsule for the idle dock; mute / end during a session.
    enum ControlKind: Equatable { case typingCapsule, mute, end }
    enum ControlPlacement: Equatable { case leading, center, trailing }
    /// Position of one bottom-row control: horizontal placement, visual height, distance of its center line from the stage bottom.
    struct ControlSlot: Equatable {
        let kind: ControlKind
        let placement: ControlPlacement
        let height: CGFloat
        let centerFromBottom: CGFloat
    }

    static func controlSlots(showsTypingSwitch: Bool, showsMuteButton: Bool, showsEndButton: Bool) -> [ControlSlot] {
        let center = buttonBottom + buttonSize / 2
        var slots: [ControlSlot] = []
        // The idle dock has only one "Switch to typing" capsule at the center; there is still no typing entry during a session.
        if showsTypingSwitch {
            return [ControlSlot(kind: .typingCapsule, placement: .center, height: typingCapsuleHeight, centerFromBottom: center)]
        }
        if showsMuteButton {
            slots.append(ControlSlot(kind: .mute, placement: .leading, height: buttonSize, centerFromBottom: center))
        }
        if showsEndButton {
            slots.append(ControlSlot(kind: .end, placement: .trailing, height: buttonSize, centerFromBottom: center))
        }
        return slots
    }

    /// Visible capsule text (key voice_realtime_switch_to_keyboard), same sentence as the screen-reader name.
    static var typingCapsuleTitle: String { VoiceConversationCopy.switchToTypingA11y }
    static let typingCapsuleHeight: CGFloat = 36
    static let typingCapsuleHitHeight: CGFloat = 44
    static let typingCapsulePadding: CGFloat = 14

    static let chipMinHeight: CGFloat = 36
    /// The longest language name needs 3 lines at accessibility2 (es / fr / pt-BR with Bahasa Indonesia); allowed up to 3 lines without truncation; same on both platforms.
    static let chipLineLimit = 3
    static let chipLeading: CGFloat = 12
    static let chipTrailing: CGFloat = 14
    static let chipIconSpacing: CGFloat = 7
    static let chipVerticalPadding: CGFloat = 6

    /// Upper limit of stage text (subtitle / status / didn't catch that / capsule) with system text size: about 2x, aligned with Android's system cap of 200%; the bottom two buttons and the orb do not scale.
    static let maxTextSize: DynamicTypeSize = .accessibility2

    /// Font scaled by the system text size (capped at accessibility2); the default large tier is the original size.
    /// Uses scaledValue rather than scaledFont: the latter would round non-integer sizes such as 14.5.
    static func scaled(_ font: UIFont, _ style: UIFont.TextStyle, _ size: DynamicTypeSize) -> UIFont {
        let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(min(size, maxTextSize)))
        let pointSize = UIFontMetrics(forTextStyle: style).scaledValue(for: font.pointSize, compatibleWith: traits)
        return font.withSize(pointSize)
    }

    /// Default-tier subtitle font (the subtitle clipping test computes with this tier).
    static var captionUIFont: UIFont { captionUIFont(.large) }
    static func captionUIFont(_ size: DynamicTypeSize) -> UIFont {
        scaled(rounded(20, .semibold), .body, size)
    }

    static func statusUIFont(for key: VoiceConversationLogic.StatusKey, size: DynamicTypeSize = .large) -> UIFont {
        scaled(fogNotice(statusKey: key) ? rounded(20, .semibold) : rounded(17, .medium), .body, size)
    }

    static func chipUIFont(_ size: DynamicTypeSize) -> UIFont {
        scaled(rounded(14.5, .semibold), .subheadline, size)
    }

    static func chipIconUIFont(_ size: DynamicTypeSize) -> UIFont {
        scaled(UIFont.systemFont(ofSize: 15, weight: .semibold), .subheadline, size)
    }

    // Old text and status text overlay the aurora fog: the fog darkens / tints the base color at the subtitle; the undecided color #71717A measured only 2.9–3.9:1, so use the secondary color.
    static let captionDim = Color.dynamic(light: 0x52525B, dark: 0xB3B3BA)
    static let statusColor = Color.dynamic(light: 0x52525B, dark: 0xB3B3BA)
    private static let noticeColor = Color.dynamic(light: 0xB45309, dark: 0xFCD34D)
}

/// Scale-fade in of the two round buttons (0.6 → 1; Reduce Motion: fade only).
private struct RevealModifier: ViewModifier {
    let revealed: Bool
    let reduceMotion: Bool

    func body(content: Content) -> some View {
        content
            .scaleEffect(revealed || reduceMotion ? 1 : 0.6)
            .opacity(revealed ? 1 : 0)
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
