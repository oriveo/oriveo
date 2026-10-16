import AVFoundation
import Foundation
import Testing
import UIKit
@testable import Oriveo

/// Drives ReadAloudController with a fake engine: start/stop, switching, finishing, failures and the automatic stops.
@Suite("Read aloud controller", .serialized)
@MainActor
struct ReadAloudControllerTests {

    private let engine = FakeSpeechEngine()
    private let platform = FakeReadAloudPlatform()
    private let center = NotificationCenter()
    private let messageA = UUID()
    private let messageB = UUID()
    private let conversation = UUID()
    private static let threeSentences = "First sentence. Second sentence. Third sentence."

    private func makeController() -> ReadAloudController {
        ReadAloudController(engine: engine, platform: platform, notificationCenter: center, detectLanguage: { _ in "en" })
    }

    // MARK: Start and stop

    @Test("Toggle starts reading: state, audio session and idle timer")
    func toggleStarts() {
        platform.isIdleTimerDisabled = false
        let controller = makeController()
        controller.toggle(messageID: messageA, text: Self.threeSentences)

        #expect(controller.state == .speaking(messageID: messageA, index: 0, total: 3))
        #expect(engine.spoken.last?.map(\.text) == ["First sentence.", "Second sentence.", "Third sentence."])
        #expect(engine.spoken.last?.allSatisfy { $0.language == "en" } == true)
        #expect(platform.activations == 1)
        #expect(platform.isIdleTimerDisabled)
    }

    @Test("Tapping the same reply again stops: back to idle, idle timer restored, session released")
    func toggleSameStops() {
        platform.isIdleTimerDisabled = false
        let controller = makeController()
        controller.toggle(messageID: messageA, text: Self.threeSentences)
        controller.toggle(messageID: messageA, text: Self.threeSentences)

        #expect(controller.state == .idle)
        #expect(engine.stopCount == 1)
        #expect(platform.deactivations == 1)
        #expect(!platform.isIdleTimerDisabled)
        #expect(engine.spoken.count == 1)
    }

    @Test("Tapping another reply stops the current one, then starts the new one")
    func toggleOtherSwitches() {
        let controller = makeController()
        controller.toggle(messageID: messageA, text: Self.threeSentences)
        controller.toggle(messageID: messageB, text: "Only one.")

        #expect(controller.state == .speaking(messageID: messageB, index: 0, total: 1))
        #expect(engine.stopCount == 1)
        #expect(platform.deactivations == 1)
        #expect(engine.spoken.count == 2)
    }

    @Test("Advances segment by segment and returns to idle when finished")
    func finishesAfterAllSegments() {
        let controller = makeController()
        controller.toggle(messageID: messageA, text: Self.threeSentences)
        engine.delegate?.speechEngineDidStartSegment(at: 1)
        #expect(controller.state == .speaking(messageID: messageA, index: 1, total: 3))
        engine.delegate?.speechEngineDidStartSegment(at: 2)
        engine.delegate?.speechEngineDidFinishAll()

        #expect(controller.state == .idle)
        #expect(platform.toasts.isEmpty)
        #expect(platform.deactivations == 1)
    }

    @Test("Engine failure marks the reply failed and shows a toast")
    func failureMarksFailed() {
        let controller = makeController()
        controller.toggle(messageID: messageA, text: Self.threeSentences)
        engine.delegate?.speechEngineDidStartSegment(at: 1)
        engine.delegate?.speechEngineDidFail()

        #expect(controller.state == .failed(messageID: messageA))
        #expect(platform.toasts == [.couldNotRead])
        #expect(platform.deactivations == 1)
    }

    @Test("After a failure the button looks idle (speaker) and tapping it starts again")
    func failedButtonLooksIdleAndRestarts() throws {
        let controller = makeController()
        let readAloud = ReadAloudButton(controller: controller)
        readAloud.configure(messageID: messageA, text: Self.threeSentences, isEligible: true)
        let button = try #require(readAloud.subviews.compactMap { $0 as? UIButton }.first)
        #expect(!readAloud.isHidden)

        button.sendActions(for: .touchUpInside)
        #expect(button.accessibilityLabel == L10n.tr("Stop Reading", table: .voice))
        engine.delegate?.speechEngineDidFail()
        #expect(controller.state == .failed(messageID: messageA))
        #expect(button.accessibilityLabel == L10n.tr("Read Aloud", table: .voice))
        #expect(button.accessibilityValue == nil)
        #expect(button.configuration?.baseForegroundColor != .clear)

        button.sendActions(for: .touchUpInside)
        #expect(controller.state == .speaking(messageID: messageA, index: 0, total: 3))
        #expect(engine.spoken.count == 2)
    }

    @Test("No system voice on the device shows a toast and does not start")
    func noVoiceShowsToast() {
        engine.hasAnyVoice = false
        let controller = makeController()
        controller.toggle(messageID: messageA, text: Self.threeSentences)

        #expect(controller.state == .failed(messageID: messageA))
        #expect(platform.toasts == [.noVoice])
        #expect(engine.spoken.isEmpty)
        #expect(platform.activations == 0)
    }

    @Test("Nothing speakable does nothing")
    func emptySpeakableTextIsIgnored() {
        let controller = makeController()
        controller.toggle(messageID: messageA, text: "```\ncode only\n```")
        #expect(controller.state == .speaking(messageID: messageA, index: 0, total: 1))
        controller.stop(.userStopped)
        controller.toggle(messageID: messageB, text: "🎉 👍")
        #expect(controller.state == .idle)
        #expect(engine.spoken.count == 1)
    }

    @Test("Placeholder sentences come from the Voice table in the placeholder locale")
    func placeholderUsesLocalizedSentence() {
        platform.uiLanguage = "ja"
        let controller = ReadAloudController(
            engine: engine, platform: platform, notificationCenter: center, detectLanguage: { _ in "fi" }
        )
        controller.toggle(messageID: messageA, text: "Before.\n\n| a |\n\nAfter.")

        let utterances = engine.spoken.last ?? []
        #expect(utterances.count == 3)
        #expect(utterances[1] == SpeechUtterance(text: "ja:Here's a table.", language: "ja"))
        #expect(utterances[0].language == "fi")
    }

    // MARK: observeChat

    @Test("observeChat: a conversation change stops reading")
    func conversationChangeStops() {
        let controller = makeController()
        controller.observeChat(conversationID: conversation, streamingMessageID: nil)
        controller.toggle(messageID: messageA, text: Self.threeSentences)
        controller.observeChat(conversationID: conversation, streamingMessageID: nil)
        #expect(controller.state != .idle)
        controller.observeChat(conversationID: UUID(), streamingMessageID: nil)

        #expect(controller.state == .idle)
        #expect(engine.stopCount == 1)
    }

    @Test("stopIfSpeaking stops only when the deleted messages include the one being read")
    func stopIfSpeakingOnlyForDeletedMessage() {
        let controller = makeController()
        controller.toggle(messageID: messageA, text: Self.threeSentences)
        controller.stopIfSpeaking(messageIDs: [messageB], .navigated)
        #expect(controller.state == .speaking(messageID: messageA, index: 0, total: 3))

        controller.stopIfSpeaking(messageIDs: [messageB, messageA], .navigated)
        #expect(controller.state == .idle)

        controller.toggle(messageID: messageB, text: Self.threeSentences)
        controller.stopIfSpeaking(messageIDs: [messageB], .newGeneration)
        #expect(controller.state == .idle)
        #expect(engine.stopCount == 2)
    }

    @Test("observeChat: keeps reading in the same conversation with no new generation (paged window changes do not stop it)")
    func sameConversationKeepsSpeaking() {
        let controller = makeController()
        controller.observeChat(conversationID: conversation, streamingMessageID: nil)
        controller.toggle(messageID: messageA, text: Self.threeSentences)
        controller.observeChat(conversationID: conversation, streamingMessageID: nil)
        controller.observeChat(conversationID: conversation, streamingMessageID: nil)
        #expect(controller.state == .speaking(messageID: messageA, index: 0, total: 3))
    }

    @Test("observeChat: streamingMessageID going from nil to non-nil stops reading")
    func newGenerationStops() {
        let controller = makeController()
        controller.observeChat(conversationID: conversation, streamingMessageID: nil)
        controller.toggle(messageID: messageA, text: Self.threeSentences)
        controller.observeChat(conversationID: conversation, streamingMessageID: messageB)

        #expect(controller.state == .idle)
        #expect(engine.stopCount == 1)
    }

    // MARK: System events

    @Test("Going to the background, an interruption beginning or the old route disappearing stops reading")
    func systemEventsStop() {
        do {
            let controller = makeController()

            controller.toggle(messageID: messageA, text: Self.threeSentences)
            center.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
            #expect(controller.state == .idle)

            controller.toggle(messageID: messageA, text: Self.threeSentences)
            center.post(
                name: AVAudioSession.interruptionNotification,
                object: nil,
                userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue]
            )
            #expect(controller.state != .idle)
            center.post(
                name: AVAudioSession.interruptionNotification,
                object: nil,
                userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue]
            )
            #expect(controller.state == .idle)

            controller.toggle(messageID: messageA, text: Self.threeSentences)
            center.post(
                name: AVAudioSession.routeChangeNotification,
                object: nil,
                userInfo: [AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.newDeviceAvailable.rawValue]
            )
            #expect(controller.state != .idle)
            center.post(
                name: AVAudioSession.routeChangeNotification,
                object: nil,
                userInfo: [AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue]
            )
            #expect(controller.state == .idle)

            #expect(engine.stopCount == 3)
            #expect(platform.deactivations == 3)
        }
    }
}

// MARK: - Test doubles

@MainActor
private final class FakeSpeechEngine: SpeechEngine {
    weak var delegate: SpeechEngineDelegate?
    var hasAnyVoice = true
    private(set) var spoken: [[SpeechUtterance]] = []
    private(set) var stopCount = 0

    func speak(_ utterances: [SpeechUtterance]) {
        spoken.append(utterances)
    }

    func stop() {
        stopCount += 1
    }
}

@MainActor
private final class FakeReadAloudPlatform: ReadAloudPlatform {
    var isIdleTimerDisabled = false
    var uiLanguage = "en"
    private(set) var activations = 0
    private(set) var deactivations = 0
    private(set) var toasts: [ReadAloudToast] = []

    func activateAudioSession() throws { activations += 1 }
    func deactivateAudioSession() { deactivations += 1 }
    func localizedVoiceString(_ key: String, locale: String) -> String { "\(locale):\(key)" }
    func showToast(_ toast: ReadAloudToast) { toasts.append(toast) }
}
