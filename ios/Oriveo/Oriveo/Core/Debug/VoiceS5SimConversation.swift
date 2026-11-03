#if DEBUG
import AVFoundation
import Combine
import Foundation
import UIKit

/// Simulator conversation acceptance: corpus PCM is injected into the production VPIOConversationAudioEngine capture tap (only inputTap is swapped),
/// and the conversation runs through the production VoiceConversationController, system recognition, and system TTS.
/// `-VOICE_SIM_PROBE s5-conversation <corpus dir> <set> <bed>` (corpus dir is relative to the data container; contains manifest.json, conv/, noise/).
/// set = conv (40 utterances) | short (20 short answers; before each, the same-language dictation opener is injected; the fake port replies with that answer's reply, played by system TTS,
/// after playback ends 30 ms later the short answer is injected; short answers reply with the language's ack word; items only record short answers) | noise (only background noise is pushed for 120 s; records spurious send and SayAgain);
/// bed = quiet (push silence) | fan | tv (noise loop overlaid for the whole run).
/// One session is opened per language (sttLanguage set to that language). The fake chat port records each send's {text, atMs} and replies with that utterance's reply, played by production system TTS;
/// the next utterance is injected <= 200 ms after returning to listening; after 10 s with no send, or after a SayAgain is recorded, it moves on.
/// All timestamps are relative to the start of injecting that utterance (including leadMs). Only the raw tmp/voice-sim-probe/s5-conversation-<set>-<bed>.json is written;
/// metrics are computed by scripts/lib/voice-s5-sim-metrics.mjs:summarizeConversation.
@MainActor
enum VoiceS5SimConversation {

    static let mode = "s5-conversation"
    /// Gap between returning to listening and injecting the next utterance (upper bound 200 ms).
    static let nextGapNanoseconds: UInt64 = 150_000_000
    /// If no send happens this long after feeding an utterance, record "no send".
    static let noSendMs = 10_000.0
    /// Fallback cap for the whole utterance after feeding it (reply never finishes playing / user keeps talking).
    static let itemLimitMs = 60_000.0
    static let pollNanoseconds: UInt64 = 20_000_000
    /// short: gap from the opener's reply finishing playback to injecting the short answer.
    static let shortGapNanoseconds: UInt64 = 30_000_000
    /// noise: duration of pushing background noise only.
    static let noiseDurationMs = 120_000.0

    struct Item {
        let id: String
        let lang: String
        let file: String
        let reply: String
    }

    /// Observations written by async callbacks during one utterance; timestamps are uptime nanoseconds.
    @MainActor
    final class Marks {
        var sends: [[String: Any]] = []
        var sayAgain: [Double] = []
        var firstPartialAtMs: Double?
        var errors: [String] = []
        /// Entered speaking after this utterance (reply started playing).
        var spoke = false
        /// Per reduce: event type, effect type, and VAD items queued after reduce (to locate lost second half after a pause).
        var events: [[String: Any]] = []
        /// Live / file transcription segments: text and start/end.
        var stt: [[String: Any]] = []
    }

    /// Controller diagnostics forwarded to the current utterance's trace; record only, does not affect the verdict.
    @MainActor
    final class TraceDiagnostics: VoiceConversationDiagnostics {
        var onReduced: ((VoiceConversationLogic.Event, [VoiceConversationLogic.Effect], Int) -> Void)?
        var onTranscribed: ((String, String, String?, UInt64, UInt64) -> Void)?

        func reduced(event: VoiceConversationLogic.Event, effects: [VoiceConversationLogic.Effect], pendingVad: Int) {
            onReduced?(event, effects, pendingVad)
        }

        func transcribed(utteranceId: String, source: String, text: String?, startNs: UInt64, endNs: UInt64) {
            onTranscribed?(utteranceId, source, text, startNs, endNs)
        }

        /// Enum case name (associated values removed).
        static func caseName(_ value: Any) -> String {
            String(String(describing: value).prefix { $0 != "(" })
        }
    }

    /// Corpus plan: utterances to run one by one, the per-language opener for short, and background noise.
    struct Plan {
        let items: [Item]
        let leads: [String: Item]
        let bed: AudioClip?
        /// Session language for the noise set (the first language of the conversation corpus).
        let noiseLang: String?
    }

    static func run(arguments: [String]) async {
        guard let index = arguments.firstIndex(of: mode), index + 3 < arguments.count else {
            write(name: "\(mode).json", ["phase": "error", "error": "usage: s5-conversation <corpus> <set> <bed>"])
            return
        }
        let directory = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(arguments[index + 1])
        let set = arguments[index + 2]
        let bed = arguments[index + 3]
        let output = "\(mode)-\(set)-\(bed).json"
        guard ["conv", "short", "noise"].contains(set) else {
            write(name: output, ["phase": "error", "set": set, "bed": bed, "error": "unsupported set \(set)"])
            return
        }
        let made: Plan
        do {
            made = try makePlan(directory: directory, set: set, bed: bed)
        } catch {
            write(name: output, ["phase": "error", "set": set, "bed": bed, "error": "manifest: \(error)"])
            return
        }
        let plan = made.items
        let bedSamples = made.bed
        let osVersion = UIDevice.current.systemVersion
        let settings = VoiceEngineSettings()
        let previousLanguage = settings.recognitionLanguage
        defer { settings.recognitionLanguage = previousLanguage }

        if set == "noise", let lang = made.noiseLang {
            var header: [String: Any] = ["osVersion": osVersion, "set": set, "bed": bed, "lang": lang]
            write(name: output, header.merging(["phase": "running"]) { $1 })
            let runner = LanguageRun(lang: lang, items: [], directory: directory, bed: bedSamples, vpio: true)
            let result = await runner.runNoise(durationMs: noiseDurationMs)
            header["vpio"] = runner.vpio
            if let error = runner.vpioError { header["vpioError"] = error }
            switch result {
            case .failure(let failure):
                write(name: output, header.merging(["phase": "error", "error": failure.message]) { $1 })
            case .success(let row):
                write(name: output, header.merging(row) { $1 }.merging(["phase": "done"]) { $1 })
            }
            return
        }

        var header: [String: Any] = ["osVersion": osVersion, "set": set, "bed": bed, "planned": plan.count]
        var rows: [[String: Any]] = []
        var vpio = true
        // Group by language, keeping corpus order: one session per language.
        var languages: [String] = []
        for item in plan where !languages.contains(item.lang) { languages.append(item.lang) }
        for lang in languages {
            let items = plan.filter { $0.lang == lang }
            let runner = LanguageRun(
                lang: lang, items: items, directory: directory, bed: bedSamples, vpio: vpio, lead: made.leads[lang]
            )
            let result = await runner.run { row in
                rows.append(row)
                header["vpio"] = runner.vpio
                write(name: output, header.merging(["phase": "running", "items": rows]) { $1 })
            }
            vpio = runner.vpio
            header["vpio"] = vpio
            if let error = runner.vpioError { header["vpioError"] = error }
            if let failure = result {
                write(name: output, header.merging(["phase": "error", "error": failure, "items": rows]) { $1 })
                return
            }
        }
        write(name: output, header.merging(["phase": "done", "items": rows]) { $1 })
    }

    private static func makePlan(directory: URL, set: String, bed: String) throws -> Plan {
        let data = try Data(contentsOf: directory.appendingPathComponent("manifest.json"))
        guard let manifest = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.coderReadCorrupt)
        }
        func entries(_ key: String, needsReply: Bool) -> [Item] {
            ((manifest[key] as? [[String: Any]]) ?? []).compactMap { entry in
                guard let id = entry["id"] as? String, let lang = entry["lang"] as? String,
                      let file = entry["file"] as? String else { return nil }
                let reply = entry["reply"] as? String
                if needsReply && reply == nil { return nil }
                return Item(id: id, lang: lang, file: file, reply: reply ?? "")
            }
        }
        let conversation = entries("conversation", needsReply: true)
        let items: [Item]
        var leads: [String: Item] = [:]
        var noiseLang: String?
        switch set {
        case "short":
            items = entries("shortAnswers", needsReply: true)
            // Per-language opener: the first same-language dictation utterance.
            let dictation = entries("dictation", needsReply: false)
            for lang in Set(items.map(\.lang)) {
                guard let lead = dictation.first(where: { $0.lang == lang }) else {
                    throw CocoaError(.coderValueNotFound, userInfo: [NSDebugDescriptionErrorKey: "dictation \(lang)"])
                }
                leads[lang] = lead
            }
        case "noise":
            items = []
            noiseLang = conversation.first?.lang
            guard noiseLang != nil else { throw CocoaError(.coderValueNotFound) }
        default:
            items = conversation
        }
        guard set == "noise" || !items.isEmpty else { throw CocoaError(.coderValueNotFound) }
        guard bed != "quiet" else {
            guard set != "noise" else {
                throw CocoaError(.coderValueNotFound, userInfo: [NSDebugDescriptionErrorKey: "noise needs bed fan|tv"])
            }
            return Plan(items: items, leads: leads, bed: nil, noiseLang: noiseLang)
        }
        let noise = (manifest["noise"] as? [[String: Any]]) ?? []
        guard let file = noise.first(where: { $0["id"] as? String == bed })?["file"] as? String else {
            throw CocoaError(.coderValueNotFound, userInfo: [NSDebugDescriptionErrorKey: "bed \(bed)"])
        }
        let bedClip = try AudioClip(url: directory.appendingPathComponent(file))
        return Plan(items: items, leads: leads, bed: bedClip, noiseLang: noiseLang)
    }

    /// Reply for short answers and noise-triggered sends: the Chinese ack, otherwise "OK".
    static func ackReply(lang: String) -> String { lang.hasPrefix("zh") ? "好的" : "OK" }

    struct Failure: Error {
        let message: String
    }

    static func write(name: String, _ object: [String: Any]) {
        let directory = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(VoiceSimProbe.outputDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
        try? data.write(to: directory.appendingPathComponent(name), options: .atomic)
    }

    static func milliseconds(from start: UInt64, to end: UInt64) -> Double {
        end >= start ? (Double(end - start) / 1_000_000).rounded() : -(Double(start - end) / 1_000_000).rounded()
    }

    // MARK: one session per language

    @MainActor
    final class LanguageRun {
        let lang: String
        let items: [Item]
        let directory: URL
        let bed: AudioClip?
        /// short: opener injected before each short answer (same-language dictation first utterance); nil for conv.
        let lead: Item?
        private(set) var vpio: Bool
        private(set) var vpioError: String?
        private var listening: DictationEngineChoice?
        private var clips: [AudioClip] = []
        /// noise: start time (when background noise starts being pushed); when non-nil, replaces the current utterance's injection start.
        private var noiseStart: UInt64?

        private var controller: VoiceConversationController?
        private var tap: InjectedConversationInputTap?
        private var port: ProbeChatPort?
        private var watches: [AnyCancellable] = []
        private var marks = Marks()
        private var endReason: String?

        init(lang: String, items: [Item], directory: URL, bed: AudioClip?, vpio: Bool, lead: Item? = nil) {
            self.lang = lang
            self.items = items
            self.directory = directory
            self.bed = bed
            self.vpio = vpio
            self.lead = lead
        }

        /// Reads the corpus, prepares recognition, and starts the session; returns the reason if it cannot start. Clips end with the opener (if any).
        private func prepare() async -> String? {
            VoiceEngineSettings().recognitionLanguage = lang
            do {
                clips = try (items + (lead.map { [$0] } ?? [])).map {
                    try AudioClip(url: directory.appendingPathComponent($0.file))
                }
            } catch {
                return "audio \(lang): \(error)"
            }
            // STT as in Dependencies.production: prepared through the shared dictation controller (authorization / engine selection).
            guard let dictation = DictationHub.shared.controller else { return "dictation controller unavailable" }
            guard let listening = await dictation.prepareConversationListening() else {
                return "prepareConversationListening nil (\(lang))"
            }
            self.listening = listening
            return await startSession(listening: listening, clips: clips)
        }

        /// Restarts the session if it has ended; returns the reason if it cannot start.
        private func ensureSession() async -> String? {
            guard controller?.isActive != true, let listening else { return nil }
            return await startSession(listening: listening, clips: clips)
        }

        /// Returns nil after all utterances run; returns the reason if it cannot start. One line per utterance is handed to emit.
        func run(emit: ([String: Any]) -> Void) async -> String? {
            if let failure = await prepare() { return failure }
            defer { stopSession() }

            for (index, item) in items.enumerated() {
                if let failure = await ensureSession() { return failure }
                if let lead {
                    let leadErrors = await runLead(reply: item.reply, index: items.count, clip: clips[items.count])
                    if let failure = await ensureSession() { return failure }
                    let ack = VoiceS5SimConversation.ackReply(lang: lang)
                    var row = await runItem(item, index: index, clip: clips[index], reply: ack)
                    row["leadId"] = lead.id
                    row["leadErr"] = leadErrors.isEmpty ? NSNull() : leadErrors.joined(separator: ",")
                    emit(row)
                } else {
                    emit(await runItem(item, index: index, clip: clips[index], reply: item.reply))
                }
            }
            return nil
        }

        /// short: injects the opener, the fake port replies and system TTS plays it; returns 30 ms after back to listening; returns the opener's exception record.
        private func runLead(reply: String, index: Int, clip: AudioClip) async -> [String] {
            marks = Marks()
            port?.reply = reply
            await observe(index: index, clip: clip, untilSpoken: true, gap: VoiceS5SimConversation.shortGapNanoseconds)
            return marks.errors + (marks.sayAgain.isEmpty ? [] : ["sayAgain"])
        }

        /// noise: pushes only background noise for durationMs, recording send and SayAgain in that window (times relative to noise start).
        func runNoise(durationMs: Double) async -> Result<[String: Any], Failure> {
            if let failure = await prepare() { return .failure(Failure(message: failure)) }
            defer { stopSession() }
            marks = Marks()
            port?.reply = VoiceS5SimConversation.ackReply(lang: lang)
            // Wait for the tap to be installed and streaming to begin; that is the start point.
            let startLimit = DispatchTime.now().uptimeNanoseconds + 10_000_000_000
            while tap?.pumpStart == nil {
                if DispatchTime.now().uptimeNanoseconds > startLimit {
                    return .failure(Failure(message: "noise: tap never started"))
                }
                try? await Task.sleep(nanoseconds: VoiceS5SimConversation.pollNanoseconds)
            }
            let start = tap?.pumpStart ?? DispatchTime.now().uptimeNanoseconds
            noiseStart = start
            defer { noiseStart = nil }
            var elapsed = 0.0
            while elapsed < durationMs {
                if let reason = endReason {
                    marks.errors.append("ended:\(reason)")
                    if let failure = await ensureSession() { return .failure(Failure(message: failure)) }
                    port?.reply = VoiceS5SimConversation.ackReply(lang: lang)
                }
                try? await Task.sleep(nanoseconds: VoiceS5SimConversation.pollNanoseconds)
                elapsed = VoiceS5SimConversation.milliseconds(from: start, to: DispatchTime.now().uptimeNanoseconds)
            }
            return .success([
                "durationMs": elapsed, "sends": marks.sends, "sayAgain": marks.sayAgain,
                "err": marks.errors.isEmpty ? NSNull() : marks.errors.joined(separator: ","),
            ])
        }

        private func startSession(listening: DictationEngineChoice, clips: [AudioClip]) async -> String? {
            stopSession()
            let bed = self.bed
            let attempt: (Bool) async -> (VoiceConversationController, InjectedConversationInputTap, ProbeChatPort, Error?) = {
                [lang] processing in
                let tap = InjectedConversationInputTap(clips: clips, bed: bed)
                let port = ProbeChatPort()
                let trace = TraceDiagnostics()
                trace.onReduced = { [weak self] event, effects, pendingVad in
                    self?.recordReduce(event, effects, pendingVad: pendingVad)
                }
                trace.onTranscribed = { [weak self] id, source, text, startNs, endNs in
                    self?.recordTranscript(id, source: source, text: text, startNs: startNs, endNs: endNs)
                }
                let owner = VoiceAudioSessionOwner.shared
                let engine = VPIOConversationAudioEngine(
                    owner: owner,
                    inputTap: { _ in tap },
                    voiceProcessing: processing ? nil : { _ in DisabledVoiceProcessing() }
                )
                let controller = VoiceConversationController(
                    audio: SessionLeasedConversationAudio(engine, owner: owner),
                    dictation: DictationEngineSource { listening },
                    readAloud: .resolving(
                        catalog: { ReadAloudCatalogSnapshot.shared.current() },
                        providers: { ReadAloudController.providers() },
                        system: SystemSpeechEngine()
                    ),
                    chat: port,
                    prompt: VoiceConversationCopy.prompt,
                    sttLanguage: { lang },
                    diagnostics: trace
                )
                do {
                    try await controller.prepareAudioSession()
                    try controller.start()
                    return (controller, tap, port, nil)
                } catch {
                    return (controller, tap, port, error)
                }
            }
            var result = await attempt(vpio)
            if let error = result.3, vpio {
                // Only disable voice processing if VPIO fails to start; JSON records vpio.
                vpio = false
                vpioError = "\(error)"
                result = await attempt(false)
            }
            if let error = result.3 { return "start (\(lang), vpio \(vpio)): \(error)" }
            let (controller, tap, port, _) = result
            self.controller = controller
            self.tap = tap
            self.port = port
            endReason = nil
            port.onSend = { [weak self] text, kind in self?.recordSend(text, kind: kind) }
            controller.onEnded = { [weak self] end in self?.endReason = "\(end.reason)" }
            watches = [
                controller.$caption.sink { [weak self] caption in
                    MainActor.assumeIsolated { self?.recordCaption(caption) }
                },
                controller.$displayState.sink { [weak self] state in
                    MainActor.assumeIsolated {
                        if state == .sayAgain { self?.recordSayAgain() }
                        if state == .speaking { self?.marks.spoke = true }
                    }
                },
            ]
            return nil
        }

        private func stopSession() {
            watches.forEach { $0.cancel() }
            watches = []
            controller?.end(.system)
            controller = nil
            tap = nil
            port = nil
        }

        /// Time the current utterance started injecting; nil if not started yet.
        private var itemStart: UInt64? { noiseStart ?? tap?.utteranceMarks.start }

        private func recordSend(_ text: String, kind: String) {
            guard let start = itemStart else {
                marks.errors.append("sendBeforeInject")
                return
            }
            let at = VoiceS5SimConversation.milliseconds(from: start, to: DispatchTime.now().uptimeNanoseconds)
            marks.sends.append(["text": text, "atMs": at, "kind": kind])
        }

        private func recordReduce(_ event: VoiceConversationLogic.Event, _ effects: [VoiceConversationLogic.Effect], pendingVad: Int) {
            guard let start = itemStart else { return }
            marks.events.append([
                "atMs": VoiceS5SimConversation.milliseconds(from: start, to: DispatchTime.now().uptimeNanoseconds),
                "type": TraceDiagnostics.caseName(event),
                "effects": effects.map(TraceDiagnostics.caseName),
                "pendingVad": pendingVad,
            ])
        }

        private func recordTranscript(_ id: String, source: String, text: String?, startNs: UInt64, endNs: UInt64) {
            guard let start = itemStart else { return }
            marks.stt.append([
                "utteranceId": id, "source": source, "text": text ?? NSNull(),
                "startMs": VoiceS5SimConversation.milliseconds(from: start, to: startNs),
                "endMs": VoiceS5SimConversation.milliseconds(from: start, to: endNs),
            ])
        }

        private func recordCaption(_ caption: String?) {
            guard marks.firstPartialAtMs == nil, let start = itemStart, let text = caption,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            marks.firstPartialAtMs = VoiceS5SimConversation.milliseconds(from: start, to: DispatchTime.now().uptimeNanoseconds)
        }

        private func recordSayAgain() {
            guard let start = itemStart else { return }
            marks.sayAgain.append(VoiceS5SimConversation.milliseconds(from: start, to: DispatchTime.now().uptimeNanoseconds))
        }

        private func runItem(_ item: Item, index: Int, clip: AudioClip, reply: String) async -> [String: Any] {
            marks = Marks()
            port?.reply = reply
            await observe(index: index, clip: clip)
            return [
                "id": item.id, "lang": item.lang, "wavMs": clip.durationMs,
                "sends": marks.sends, "sayAgain": marks.sayAgain,
                "firstPartialAtMs": marks.firstPartialAtMs ?? NSNull(),
                "err": marks.errors.isEmpty ? NSNull() : marks.errors.joined(separator: ","),
                "trace": ["events": marks.events, "stt": marks.stt],
            ]
        }

        /// Injects utterance index and waits for it to finish (back to listening / SayAgain / no send / fallback cap); observations go into marks;
        /// with untilSpoken, after send it must also wait for the reply to play (entered speaking) before back to listening counts as finished; returns after gap.
        private func observe(
            index: Int, clip: AudioClip, untilSpoken: Bool = false,
            gap: UInt64 = VoiceS5SimConversation.nextGapNanoseconds
        ) async {
            guard let tap else {
                marks.errors.append("noSession")
                return
            }
            tap.inject(index)
            // Wait for this utterance to finish injecting (including leadMs and corpus tail); also finishes if the session ends midway.
            let feedLimit = DispatchTime.now().uptimeNanoseconds + UInt64(clip.durationMs + 10_000) * 1_000_000
            while tap.utteranceMarks.end == nil {
                if DispatchTime.now().uptimeNanoseconds > feedLimit {
                    marks.errors.append("timeout:inject")
                    return
                }
                try? await Task.sleep(nanoseconds: VoiceS5SimConversation.pollNanoseconds)
            }
            let fedAt = tap.utteranceMarks.end ?? DispatchTime.now().uptimeNanoseconds
            while true {
                let sinceFed = VoiceS5SimConversation.milliseconds(from: fedAt, to: DispatchTime.now().uptimeNanoseconds)
                if let reason = endReason {
                    marks.errors.append("ended:\(reason)")
                    break
                }
                let state = controller?.displayState
                if !marks.sayAgain.isEmpty {
                    // After SayAgain is recorded, wait for the prompt to finish and return to listening before the next utterance.
                    if state == .listening { break }
                } else if marks.sends.isEmpty {
                    if sinceFed >= VoiceS5SimConversation.noSendMs {
                        marks.errors.append("noSend")
                        break
                    }
                } else if state == .listening, port?.pendingReplies == 0, !untilSpoken || marks.spoke {
                    break
                }
                if sinceFed >= VoiceS5SimConversation.itemLimitMs {
                    marks.errors.append("timeout:\(state.map { $0.rawValue } ?? "nil")")
                    break
                }
                try? await Task.sleep(nanoseconds: VoiceS5SimConversation.pollNanoseconds)
            }
            try? await Task.sleep(nanoseconds: gap)
        }
    }

    // MARK: fake chat port

    /// Records each send / amend (distinguished by kind) and replies with the current utterance's reply (text + completed); the controller hands the reply to production system TTS.
    @MainActor
    final class ProbeChatPort: VoiceConversationChatPort {
        var reply = ""
        /// kind = "send" / "amend".
        var onSend: ((String, String) -> Void)?
        /// Count of sends whose reply events have not all been emitted yet.
        private(set) var pendingReplies = 0
        private var continuation: AsyncStream<VoiceConversationReplyEvent>.Continuation?

        func send(_ text: String) async -> Bool {
            reply(to: text, kind: "send")
        }

        /// Interjection while thinking: replies with the current reply, same as send.
        func amend(_ text: String) async -> Bool {
            reply(to: text, kind: "amend")
        }

        private func reply(to text: String, kind: String) -> Bool {
            onSend?(text, kind)
            let reply = self.reply
            pendingReplies += 1
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.continuation?.yield(.text(reply))
                self.continuation?.yield(.completed)
                self.pendingReplies -= 1
            }
            return true
        }

        func makeReplyEvents() -> AsyncStream<VoiceConversationReplyEvent> {
            continuation?.finish()
            let (stream, continuation) = AsyncStream<VoiceConversationReplyEvent>.makeStream()
            self.continuation = continuation
            return stream
        }

        func cancel() {}
    }

    /// Stand-in used when VPIO fails to start: voice processing stays off.
    final class DisabledVoiceProcessing: ConversationVoiceProcessing {
        var isEnabled: Bool { false }
        func setEnabled(_ enabled: Bool) throws {}
    }
}

// MARK: - Corpus audio

/// Mono Float32 samples and their sample rate; resampled to the tap format's rate on demand.
nonisolated final class AudioClip: @unchecked Sendable {
    let samples: [Float]
    let sampleRate: Double

    init(url: URL) throws {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = file.processingFormat
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try file.read(into: buffer)
        guard let data = buffer.floatChannelData?[0] else { throw CocoaError(.fileReadCorruptFile) }
        samples = Array(UnsafeBufferPointer(start: data, count: Int(buffer.frameLength)))
        sampleRate = format.sampleRate
    }

    private init(samples: [Float], sampleRate: Double) {
        self.samples = samples
        self.sampleRate = sampleRate
    }

    var durationMs: Double { (Double(samples.count) / sampleRate * 1000).rounded() }

    /// Converts to the target sample rate (mono) with AVAudioConverter; on failure returns the input unchanged (sample rate unchanged).
    func resampled(to rate: Double) -> AudioClip {
        guard rate != sampleRate, !samples.isEmpty,
              let from = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let to = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1),
              let converter = AVAudioConverter(from: from, to: to),
              let input = AVAudioPCMBuffer(pcmFormat: from, frameCapacity: AVAudioFrameCount(samples.count)),
              let output = AVAudioPCMBuffer(
                  pcmFormat: to, frameCapacity: AVAudioFrameCount(Double(samples.count) * rate / sampleRate) + 4096
              )
        else { return self }
        input.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            input.floatChannelData?[0].update(from: source.baseAddress!, count: samples.count)
        }
        final class Fed { var done = false }
        let fed = Fed()
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if fed.done {
                status.pointee = .endOfStream
                return nil
            }
            fed.done = true
            status.pointee = .haveData
            return input
        }
        guard error == nil, let data = output.floatChannelData?[0] else { return self }
        return AudioClip(samples: Array(UnsafeBufferPointer(start: data, count: Int(output.frameLength))), sampleRate: rate)
    }
}

// MARK: - Injection tap

/// Replaces the production VPIO engine's input node tap: install records the format and block, and on a serial queue pushes one chunk every 20 ms at real-time pace
/// (format as given by the input node when EngineConversationInputTap installs its tap): background noise loop (silence for quiet) + the currently injected utterance.
final class InjectedConversationInputTap: ConversationInputTap {
    private let state: InjectionState

    init(clips: [AudioClip], bed: AudioClip?) {
        state = InjectionState(clips: clips, bed: bed)
    }

    /// Uptime nanoseconds when the current utterance started / finished feeding.
    var utteranceMarks: (start: UInt64?, end: UInt64?) { state.marks }

    /// Uptime nanoseconds when streaming first started; nil if the tap is not installed yet.
    var pumpStart: UInt64? { state.pumpStart }

    /// Next chunk onward injects utterance index.
    func inject(_ index: Int) { state.inject(index) }

    func install(bufferSize: AVAudioFrameCount, format: AVAudioFormat?, block: @escaping AVAudioNodeTapBlock) {
        let format = format ?? AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        state.start(format: format, block: block)
    }

    func remove() { state.stop() }
}

nonisolated final class InjectionState: @unchecked Sendable {
    private let lock = NSLock()
    private let sources: [AudioClip]
    private let bedSource: AudioClip?
    private let queue = DispatchQueue(label: "ai.oriveo.community.voice-s5-conversation.inject", qos: .userInteractive)
    private var generation = 0
    // Audio prepared at the current tap sample rate.
    private var rate: Double = 0
    private var clips: [AudioClip] = []
    private var bed: AudioClip?
    private var bedPosition = 0
    private var pending: Int?
    private var current: Int?
    private var position = 0
    private var startUptime: UInt64?
    private var endUptime: UInt64?
    private var firstPumpUptime: UInt64?

    init(clips: [AudioClip], bed: AudioClip?) {
        sources = clips
        bedSource = bed
    }

    var marks: (start: UInt64?, end: UInt64?) {
        lock.lock()
        defer { lock.unlock() }
        return (startUptime, endUptime)
    }

    var pumpStart: UInt64? {
        lock.lock()
        defer { lock.unlock() }
        return firstPumpUptime
    }

    func inject(_ index: Int) {
        lock.lock()
        pending = index
        current = nil
        startUptime = nil
        endUptime = nil
        lock.unlock()
    }

    func start(format: AVAudioFormat, block: @escaping AVAudioNodeTapBlock) {
        let newRate = format.sampleRate
        lock.lock()
        let needsResample = newRate != rate
        lock.unlock()
        // Resampling happens on the calling thread (once at tap install); the streaming thread only copies.
        let prepared = needsResample ? sources.map { $0.resampled(to: newRate) } : nil
        let preparedBed = needsResample ? bedSource?.resampled(to: newRate) : nil
        lock.lock()
        if let prepared {
            if rate > 0 { position = Int(Double(position) * newRate / rate) }
            clips = prepared
            bed = preparedBed
            bedPosition = 0
            rate = newRate
        }
        generation += 1
        let current = generation
        lock.unlock()
        queue.async { [self] in pump(format: format, block: block, generation: current) }
    }

    func stop() {
        lock.lock()
        generation += 1
        lock.unlock()
    }

    private func pump(format: AVAudioFormat, block: @escaping AVAudioNodeTapBlock, generation current: Int) {
        let rate = format.sampleRate
        let chunk = max(1, Int(rate / 50))
        let channels = Int(format.channelCount)
        let started = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        if firstPumpUptime == nil { firstPumpUptime = started }
        lock.unlock()
        var delivered: AVAudioFramePosition = 0
        var mono = [Float](repeating: 0, count: chunk)
        while true {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunk)) else { return }
            buffer.frameLength = AVAudioFrameCount(chunk)
            lock.lock()
            guard generation == current else {
                lock.unlock()
                return
            }
            fill(&mono, now: DispatchTime.now().uptimeNanoseconds)
            lock.unlock()
            guard let data = buffer.floatChannelData else { return }
            if format.isInterleaved {
                for i in 0..<chunk { for c in 0..<channels { data[0][i * channels + c] = mono[i] } }
            } else {
                for c in 0..<channels { data[c].update(from: mono, count: chunk) }
            }
            block(buffer, AVAudioTime(sampleTime: delivered, atRate: rate))
            delivered += AVAudioFramePosition(chunk)
            // Real-time pacing: the next chunk is pushed at the time matching the duration already pushed.
            let due = started + UInt64(Double(delivered) / rate * 1_000_000_000)
            let now = DispatchTime.now().uptimeNanoseconds
            if due > now { usleep(useconds_t((due - now) / 1000)) }
        }
    }

    /// Called under the lock: writes background noise + current utterance into mono.
    private func fill(_ mono: inout [Float], now: UInt64) {
        let count = mono.count
        if let bed, !bed.samples.isEmpty {
            let samples = bed.samples
            for i in 0..<count { mono[i] = samples[(bedPosition + i) % samples.count] }
            bedPosition = (bedPosition + count) % samples.count
        } else {
            for i in 0..<count { mono[i] = 0 }
        }
        if current == nil, let next = pending {
            pending = nil
            current = next
            position = 0
            startUptime = now
        }
        guard let index = current, clips.indices.contains(index) else { return }
        let samples = clips[index].samples
        let take = min(count, max(0, samples.count - position))
        for i in 0..<take { mono[i] += samples[position + i] }
        position += take
        if position >= samples.count {
            current = nil
            endUptime = now
        }
    }
}
#endif
