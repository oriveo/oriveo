import Foundation
import Testing
@testable import Oriveo

/// The conversation host picks the VAD decision mode from the model readiness result at session preparation, and feeds each frame's speech probability into vad.step.
@Suite("Voice conversation model VAD", .serialized)
@MainActor
struct VoiceConversationModelVadTests {

    private let audio = FakeConversationAudio()
    private let defaults = UserDefaults(suiteName: "VoiceConversationModelVadTests-\(UUID().uuidString)")!
    private let cursor = ModelVadFrameCursor()

    private func makeController(modelReady: Bool) -> VoiceConversationController {
        VoiceConversationController(
            audio: audio,
            dictation: .fixed(ModelVadSilentSTT(), isSystem: false),
            readAloud: .fixed(ModelVadSilentSpeech()),
            chat: ModelVadChatPort(),
            prompt: { _ in "PROMPT" },
            memory: VoiceBargeInMemory(defaults: defaults, osMajorVersion: 27),
            stopReadAloud: {},
            detectLanguage: { _ in "en" },
            loadSpeechModel: { modelReady ? .ready : .unavailable }
        )
    }

    private func start(modelReady: Bool) async throws -> VoiceConversationController {
        let controller = makeController(modelReady: modelReady)
        try await controller.prepareAudioSession()
        try controller.start()
        return controller
    }

    /// Feeds `count` frames through the engine callback's three-argument entry point.
    private func feed(_ controller: VoiceConversationController, db: Double, prob: Double?, _ count: Int) {
        for _ in 0..<count {
            controller.conversationAudio(didCaptureFrame: cursor.next, db: db, speechProb: prob)
            cursor.next += 1
        }
    }

    private func settle() async {
        for _ in 0..<60 { await Task.yield() }
    }

    @Test("model ready: speech probability drives utterance start and end, loudness alone does not")
    func probabilityDrivesStartAndEnd() async throws {
        let controller = try await start(modelReady: true)
        feed(controller, db: -60, prob: 0, 10)
        // Loud enough but low probability: energy VAD starts an utterance, model VAD does not.
        feed(controller, db: -30, prob: 0.1, 20)
        #expect(audio.begins == 0)

        // Starting an utterance also requires being 4 dB above the background level (70th percentile of the smoothed value over the last 3 s, about -30 dB here).
        feed(controller, db: -24, prob: 0.9, 20)
        #expect(audio.begins == 1)
        #expect(audio.finishes == 0)

        // Still loud but probability drops: model VAD ends the utterance on silence.
        feed(controller, db: -30, prob: 0.05, 40)
        await settle()
        #expect(audio.finishes == 1)
        controller.end(.user)
    }

    @Test("model unavailable at prepare: whole session uses energy VAD and ignores probabilities")
    func unavailableModelUsesEnergyForSession() async throws {
        let controller = try await start(modelReady: false)
        feed(controller, db: -60, prob: 0, 10)
        feed(controller, db: -30, prob: 0, 20)
        #expect(audio.begins == 1)

        feed(controller, db: -60, prob: 0.95, 40)
        await settle()
        #expect(audio.finishes == 1)
        controller.end(.user)
    }

    @Test("probabilities stop mid-session: a fresh energy VAD takes over and loud frames start speech")
    func inferenceFailureSwitchesToEnergy() async throws {
        let controller = try await start(modelReady: true)
        feed(controller, db: -60, prob: 0, 10)
        feed(controller, db: -30, prob: 0.9, 20)
        #expect(audio.begins == 1)

        // Inference fails from chunk N on: frames carry no probability, the unfinished utterance is dropped, and the missing probability is not treated as 0.
        feed(controller, db: -60, prob: nil, 10)
        await settle()
        #expect(!audio.utteranceOpen)

        feed(controller, db: -30, prob: nil, 20)
        #expect(audio.begins == 2)

        // Switches only once: probabilities returning do not switch back to model mode (loud low-probability frames still keep the utterance going).
        feed(controller, db: -30, prob: 0.0, 40)
        await settle()
        #expect(audio.finishes == 0)
        #expect(audio.utteranceOpen)
        controller.end(.user)
    }
}

private final class ModelVadFrameCursor {
    var next = 0
}

private nonisolated final class ModelVadSilentSTT: STTEngine, @unchecked Sendable {
    func transcribe(_ recording: RecordingResult, language: String?) async throws -> String { "" }
}

private final class ModelVadSilentSpeech: SpeechEngine {
    weak var delegate: SpeechEngineDelegate?
    var hasAnyVoice: Bool { true }
    func speak(_ utterances: [SpeechUtterance]) {}
    func stop() {}
}

private final class ModelVadChatPort: VoiceConversationChatPort {
    func send(_ text: String) async -> Bool { true }
    func makeReplyEvents() -> AsyncStream<VoiceConversationReplyEvent> { AsyncStream { _ in } }
    func cancel() {}
}
