import AVFoundation
import Combine
import Foundation
import NaturalLanguage
import UIKit

// MARK: - State and end reasons

enum ReadAloudState: Equatable {
    case idle
    /// index is the segment being spoken (zero-based); total is the number of segments.
    case speaking(messageID: UUID, index: Int, total: Int)
    case failed(messageID: UUID)
}

/// Why a read-aloud session ended.
enum ReadAloudEndReason: String {
    case finished
    case userStopped = "user_stopped"
    case navigated
    case newGeneration = "new_generation"
    case backgrounded
    case interrupted
    case failed
}

enum ReadAloudToast: Equatable {
    case couldNotRead
    case noVoice

    var localizationKey: String {
        switch self {
        case .couldNotRead: return "Couldn't read this reply aloud"
        case .noVoice: return "No system voice is available on this device"
        }
    }
}

// MARK: - Engine and platform abstractions

/// One segment to speak; language is BCP-47, nil means the system default voice.
struct SpeechUtterance: Equatable {
    let text: String
    let language: String?
}

protocol SpeechEngineDelegate: AnyObject {
    func speechEngineDidStartSegment(at index: Int)
    func speechEngineDidFinishAll()
    func speechEngineDidFail()
}

/// Speech engine: speaks segments in order and reports segment i started / all finished / failed. No callbacks after stop().
protocol SpeechEngine: AnyObject {
    var delegate: SpeechEngineDelegate? { get set }
    var hasAnyVoice: Bool { get }
    func speak(_ utterances: [SpeechUtterance])
    func stop()
}

/// Audio session, idle timer, strings and toasts: the system in production, fakes in tests.
protocol ReadAloudPlatform: AnyObject {
    func activateAudioSession() throws
    func deactivateAudioSession()
    var isIdleTimerDisabled: Bool { get set }
    var uiLanguage: String { get }
    func localizedVoiceString(_ key: String, locale: String) -> String
    func showToast(_ toast: ReadAloudToast)
}

// MARK: - Controller

/// Reads assistant replies aloud with the system TTS. Only one reply plays at a time: tapping the same
/// reply again stops it; tapping another reply stops the current one and starts the new one.
final class ReadAloudController: ObservableObject {
    static let shared = ReadAloudController(engine: SystemSpeechEngine(), platform: SystemReadAloudPlatform())

    @Published private(set) var state: ReadAloudState = .idle

    private struct Session {
        let messageID: UUID
        let total: Int
        var index: Int
        let savedIdleTimerDisabled: Bool
    }

    private let engine: SpeechEngine
    private let platform: ReadAloudPlatform
    private let detectLanguage: (String) -> String?
    private var session: Session?
    private var hasObservedChat = false
    private var observedConversationID: UUID?
    private var observedStreamingMessageID: UUID?
    private var notificationTokens: [NSObjectProtocol] = []

    init(
        engine: SpeechEngine,
        platform: ReadAloudPlatform,
        notificationCenter: NotificationCenter = .default,
        detectLanguage: @escaping (String) -> String? = ReadAloudController.dominantLanguage
    ) {
        self.engine = engine
        self.platform = platform
        self.detectLanguage = detectLanguage
        engine.delegate = self
        observeSystemNotifications(notificationCenter)
    }

    var speakingMessageID: UUID? {
        if case .speaking(let messageID, _, _) = state { return messageID }
        return nil
    }

    func toggle(messageID: UUID, text: String) {
        if let current = speakingMessageID {
            stop(.userStopped)
            if current == messageID { return }
        }
        start(messageID: messageID, text: text)
    }

    /// Stops the current reading; does nothing when idle.
    func stop(_ reason: ReadAloudEndReason) {
        guard session != nil else { return }
        engine.stop()
        finish(reason)
    }

    /// Called on every chat list update (every frame while streaming): compares two ids only, free when idle.
    /// Conversation changed → navigated; a new generation started → newGeneration.
    /// It does not stop when the message is missing from the list: the list is a paged window, and expanding
    /// or jumping can leave a message that still exists temporarily outside the rows.
    func observeChat(conversationID: UUID?, streamingMessageID: UUID?) {
        let wasObserved = hasObservedChat
        let previousConversationID = observedConversationID
        let previousStreamingMessageID = observedStreamingMessageID
        hasObservedChat = true
        observedConversationID = conversationID
        observedStreamingMessageID = streamingMessageID

        guard wasObserved, session != nil else { return }
        if previousConversationID != conversationID {
            stop(.navigated)
        } else if previousStreamingMessageID == nil && streamingMessageID != nil {
            stop(.newGeneration)
        }
    }

    /// Called by the paths that really delete messages (edit truncation, regeneration replacement): stops if
    /// the message being read is among them.
    func stopIfSpeaking(messageIDs: some Sequence<UUID>, _ reason: ReadAloudEndReason) {
        guard let current = speakingMessageID, messageIDs.contains(current) else { return }
        stop(reason)
    }

    // MARK: Start / finish

    private func start(messageID: UUID, text: String) {
        let segments = SpeakableText.segments(text: text, final: true)
        guard !segments.isEmpty else { return }
        guard engine.hasAnyVoice else {
            state = .failed(messageID: messageID)
            platform.showToast(.noVoice)
            return
        }
        do {
            try platform.activateAudioSession()
        } catch {
            state = .failed(messageID: messageID)
            platform.showToast(.couldNotRead)
            return
        }

        let utterances = makeUtterances(segments)
        let savedIdleTimer = platform.isIdleTimerDisabled
        platform.isIdleTimerDisabled = true
        session = Session(
            messageID: messageID,
            total: utterances.count,
            index: 0,
            savedIdleTimerDisabled: savedIdleTimer
        )
        state = .speaking(messageID: messageID, index: 0, total: utterances.count)
        engine.speak(utterances)
    }

    private func finish(_ reason: ReadAloudEndReason) {
        guard let current = session else { return }
        session = nil
        platform.deactivateAudioSession()
        platform.isIdleTimerDisabled = current.savedIdleTimerDisabled
        state = reason == .failed ? .failed(messageID: current.messageID) : .idle
        if reason == .failed { platform.showToast(.couldNotRead) }
    }

    private func makeUtterances(_ segments: [SpeakableSegment]) -> [SpeechUtterance] {
        let sentences = segments.compactMap { segment -> String? in
            if case .sentence(let text) = segment { return text }
            return nil
        }
        let readingLanguage = sentences.isEmpty ? nil : detectLanguage(sentences.joined(separator: " "))
        let placeholderLocale = SpeakableText.placeholderLocale(reading: readingLanguage, ui: platform.uiLanguage)
        return segments.map { segment in
            switch segment {
            case .sentence(let text):
                return SpeechUtterance(text: text, language: readingLanguage)
            case .placeholder(let kind):
                let text = platform.localizedVoiceString(Self.placeholderKey(kind), locale: placeholderLocale)
                return SpeechUtterance(text: text, language: placeholderLocale)
            }
        }
    }

    // MARK: System events

    private func observeSystemNotifications(_ center: NotificationCenter) {
        notificationTokens.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: nil
        ) { [weak self] note in
            let reason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            guard reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue else { return }
            Self.onMain { [weak self] in self?.stop(.interrupted) }
        })
        notificationTokens.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: nil
        ) { [weak self] note in
            let type = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            guard type == AVAudioSession.InterruptionType.began.rawValue else { return }
            Self.onMain { [weak self] in self?.stop(.interrupted) }
        })
        notificationTokens.append(center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil
        ) { [weak self] _ in
            Self.onMain { [weak self] in self?.stop(.backgrounded) }
        })
    }

    /// Runs synchronously on the main thread (tests post there); hops to the main thread otherwise.
    private nonisolated static func onMain(_ work: @escaping @MainActor () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { work() }
        } else {
            Task { @MainActor in work() }
        }
    }

    // MARK: Pure functions

    static func placeholderKey(_ kind: SpeakablePlaceholder) -> String {
        switch kind {
        case .code: return "Here's a code block."
        case .table: return "Here's a table."
        case .math: return "Here's a formula."
        }
    }

    nonisolated static func dominantLanguage(_ text: String) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        return recognizer.dominantLanguage?.rawValue
    }
}

extension ReadAloudController: SpeechEngineDelegate {
    func speechEngineDidStartSegment(at index: Int) {
        guard var current = session, index >= 0, index < current.total else { return }
        current.index = index
        session = current
        state = .speaking(messageID: current.messageID, index: index, total: current.total)
    }

    func speechEngineDidFinishAll() {
        finish(.finished)
    }

    func speechEngineDidFail() {
        guard session != nil else { return }
        engine.stop()
        finish(.failed)
    }
}

// MARK: - Production implementations

/// AVSpeechSynthesizer: queues one utterance per segment and picks the best system voice for each segment's language.
final class SystemSpeechEngine: NSObject, SpeechEngine {
    weak var delegate: SpeechEngineDelegate?

    private let synthesizer = AVSpeechSynthesizer()
    private var queued: [AVSpeechUtterance] = []

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    var hasAnyVoice: Bool {
        !Self.usableVoices().isEmpty
    }

    func speak(_ utterances: [SpeechUtterance]) {
        guard !utterances.isEmpty else {
            delegate?.speechEngineDidFail()
            return
        }
        let voices = Self.usableVoices()
        var voiceByLanguage: [String: AVSpeechSynthesisVoice?] = [:]
        queued = utterances.map { item in
            let utterance = AVSpeechUtterance(string: item.text)
            if let language = item.language {
                if voiceByLanguage[language] == nil {
                    voiceByLanguage[language] = Self.bestVoice(for: language, among: voices)
                }
                utterance.voice = voiceByLanguage[language] ?? nil
            }
            utterance.prefersAssistiveTechnologySettings = true
            return utterance
        }
        for utterance in queued { synthesizer.speak(utterance) }
    }

    func stop() {
        queued = []
        synthesizer.stopSpeaking(at: .immediate)
    }

    private func handleStart(_ utterance: AVSpeechUtterance) {
        guard let index = queued.firstIndex(where: { $0 === utterance }) else { return }
        delegate?.speechEngineDidStartSegment(at: index)
    }

    private func handleFinish(_ utterance: AVSpeechUtterance) {
        guard let last = queued.last, last === utterance else { return }
        queued = []
        delegate?.speechEngineDidFinishAll()
    }

    private static func usableVoices() -> [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices().filter {
            !$0.voiceTraits.contains(.isNoveltyVoice) && !$0.voiceTraits.contains(.isPersonalVoice)
        }
    }

    /// The highest-quality voice for the language (premium > enhanced > default); on a tie, an exact language tag wins.
    static func bestVoice(for language: String, among voices: [AVSpeechSynthesisVoice]) -> AVSpeechSynthesisVoice? {
        let tag = language.replacingOccurrences(of: "_", with: "-").lowercased()
        let parts = tag.split(separator: "-").map(String.init)
        guard let base = parts.first else { return nil }
        let candidates = voices.filter { voice in
            let voiceParts = voice.language.lowercased().split(separator: "-").map(String.init)
            guard voiceParts.first == base else { return false }
            guard base == "zh" else { return true }
            let voiceRegion = voiceParts.dropFirst().last ?? ""
            let traditional = parts.contains("hant") || parts.contains { ["tw", "hk", "mo"].contains($0) }
            return traditional ? ["tw", "hk", "mo"].contains(voiceRegion) : !["tw", "hk", "mo"].contains(voiceRegion)
        }
        return candidates.max { lhs, rhs in
            let lhsScore = lhs.quality.rawValue * 10 + (lhs.language.lowercased() == tag ? 1 : 0)
            let rhsScore = rhs.quality.rawValue * 10 + (rhs.language.lowercased() == tag ? 1 : 0)
            return lhsScore < rhsScore
        } ?? AVSpeechSynthesisVoice(language: language)
    }
}

extension SystemSpeechEngine: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        let box = UtteranceBox(utterance)
        Self.deliver { [weak self] in self?.handleStart(box.utterance) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let box = UtteranceBox(utterance)
        Self.deliver { [weak self] in self?.handleFinish(box.utterance) }
    }

    private nonisolated static func deliver(_ work: @escaping @MainActor () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { work() }
        } else {
            Task { @MainActor in work() }
        }
    }
}

/// AVSpeechUtterance is not Sendable; this box is only used to compare identity across callbacks.
private nonisolated final class UtteranceBox: @unchecked Sendable {
    let utterance: AVSpeechUtterance
    init(_ utterance: AVSpeechUtterance) { self.utterance = utterance }
}

final class SystemReadAloudPlatform: ReadAloudPlatform {
    func activateAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .spokenAudio)
        try session.setActive(true)
    }

    func deactivateAudioSession() {
        // Failure only means other audio still holds the session; reading has already stopped, so no toast
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    var isIdleTimerDisabled: Bool {
        get { UIApplication.shared.isIdleTimerDisabled }
        set { UIApplication.shared.isIdleTimerDisabled = newValue }
    }

    var uiLanguage: String {
        AppLocalization.currentLanguage.rawValue
    }

    /// Placeholder sentences come from the Voice table of the placeholderLocale's .lproj, not the UI language.
    func localizedVoiceString(_ key: String, locale: String) -> String {
        for candidate in [locale, "en"] {
            if let path = Bundle.main.path(forResource: candidate, ofType: "lproj"),
               let bundle = Bundle(path: path) {
                return bundle.localizedString(forKey: key, value: key, table: L10n.Table.voice.rawValue)
            }
        }
        return key
    }

    func showToast(_ toast: ReadAloudToast) {
        ToastManager.shared.show(L10n.tr(toast.localizationKey, table: .voice), style: .error)
    }
}
