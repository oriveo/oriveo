#if DEBUG
import AVFoundation
import Combine
import Foundation
import Speech
import UIKit

/// Simulator dictation acceptance probe: corpus WAVs are fed as the microphone via FileAudioCapture and dictated turn by turn through the production DictationController (system engine).
/// Triggered by `-VOICE_SIM_PROBE s5-dictation <corpus dir>` (relative to the data container; contains manifest.json and dict/*.wav).
/// Turns: dictation loops 50 turns in order, then all of dictationIntl; each turn: bind → micTapped → feed + 1.5 s trailing silence → finish(.insert),
/// a single turn times out after 20 s and is recorded as a failure. Only raw per-turn results are written to tmp/voice-sim-probe/s5-dictation.json; metrics are computed by
/// scripts/lib/voice-s5-sim-metrics.mjs:summarizeDictation.
@MainActor
enum VoiceS5SimDictation {

    static let mode = "s5-dictation"
    static let slotKey = "probe:voice-s5-dictation"
    static let dictationRounds = 50
    static let tailSilenceSeconds = 1.5
    static let roundTimeoutSeconds = 20.0

    struct Item {
        let id: String
        let lang: String
        let file: String
        let leadMs: Double
    }

    /// Observations written by async callbacks during one turn.
    @MainActor
    final class Marks {
        var firstLiveUptime: UInt64?
        var finalText: String?
        var noSpeechHeard = false
        var done = false
    }

    /// Diagnostics (-S5_DIAG): timing records of each controller layer within one turn; times are milliseconds relative to origin.
    @MainActor
    final class Trace {
        let origin = DispatchTime.now().uptimeNanoseconds
        var live: [[String: Any]] = []
        var events: [[String: Any]] = []
        var states: [[String: Any]] = []

        func ms(_ uptime: UInt64 = DispatchTime.now().uptimeNanoseconds) -> Double {
            (Double(Int64(bitPattern: uptime &- origin)) / 1_000_000).rounded()
        }
    }

    static func run(arguments: [String]) async {
        if arguments.contains("-S5_DIAG") {
            await diagnose(arguments: arguments)
            return
        }
        guard let index = arguments.firstIndex(of: mode), index + 1 < arguments.count else {
            write(["phase": "error", "error": "missing corpus directory"])
            return
        }
        let directory = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(arguments[index + 1])
        let plan: [Item]
        do {
            plan = try makePlan(directory: directory)
        } catch {
            write(["phase": "error", "error": "manifest: \(error)"])
            return
        }
        let osVersion = UIDevice.current.systemVersion
        let settings = VoiceEngineSettings()
        let previousLanguage = settings.recognitionLanguage
        defer { settings.recognitionLanguage = previousLanguage }

        var rounds: [[String: Any]] = []
        write(["phase": "running", "osVersion": osVersion, "planned": plan.count, "rounds": rounds])
        for item in plan {
            rounds.append(await round(item, directory: directory))
            write(["phase": "running", "osVersion": osVersion, "planned": plan.count, "rounds": rounds])
        }
        write(["phase": "done", "osVersion": osVersion, "rounds": rounds])
    }

    /// dictation loops in order to 50 turns, then continues with all of dictationIntl.
    private static func makePlan(directory: URL) throws -> [Item] {
        let data = try Data(contentsOf: directory.appendingPathComponent("manifest.json"))
        guard let manifest = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.coderReadCorrupt)
        }
        let defaultLead = (manifest["leadMs"] as? NSNumber)?.doubleValue ?? 0
        func items(_ key: String) -> [Item] {
            ((manifest[key] as? [[String: Any]]) ?? []).compactMap { entry in
                guard let id = entry["id"] as? String, let lang = entry["lang"] as? String,
                      let file = entry["file"] as? String else { return nil }
                let lead = (entry["leadMs"] as? NSNumber)?.doubleValue ?? defaultLead
                return Item(id: id, lang: lang, file: file, leadMs: lead)
            }
        }
        let dictation = items("dictation")
        guard !dictation.isEmpty else { throw CocoaError(.coderValueNotFound) }
        let cycled = (0..<dictationRounds).map { dictation[$0 % dictation.count] }
        return cycled + items("dictationIntl")
    }

    private static func round(_ item: Item, directory: URL, trace: Trace? = nil) async -> [String: Any] {
        var row: [String: Any] = ["id": item.id, "lang": item.lang, "ok": false, "finalText": "",
                                  "firstPartialMs": NSNull(), "err": NSNull()]
        let deadline = Date().addingTimeInterval(roundTimeoutSeconds)
        VoiceEngineSettings().recognitionLanguage = item.lang

        let capture: FileAudioCapture
        do {
            capture = try FileAudioCapture(url: directory.appendingPathComponent(item.file),
                                           tailSilenceSeconds: tailSilenceSeconds)
            try clearSlot()
        } catch {
            row["err"] = "audio: \(error)"
            return row
        }
        // A new controller per turn: failures and timeout residue from the previous turn must not carry into the next one.
        let hub = DictationHub(factory: { try DictationHub.makeProduction(providers: $0, capture: capture) })
        guard let controller = hub.controller else {
            row["err"] = "controllerUnavailable"
            return row
        }
        let marks = Marks()
        let watch = controller.liveText.$value.sink { value in
            MainActor.assumeIsolated {
                trace?.live.append(["ms": trace?.ms() ?? 0, "final": value?.final ?? NSNull(),
                                    "volatile": value?.volatile ?? NSNull(), "text": value?.text ?? NSNull()])
                guard marks.firstLiveUptime == nil, let text = value?.text,
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                marks.firstLiveUptime = DispatchTime.now().uptimeNanoseconds
            }
        }
        let stateWatch = controller.$state.sink { state in
            MainActor.assumeIsolated {
                trace?.states.append(["ms": trace?.ms() ?? 0, "state": "\(state)"])
            }
        }
        controller.onEvent = { event in
            trace?.events.append(["ms": trace?.ms() ?? 0, "event": "\(event)"])
            switch event {
            case .insert(let text): marks.finalText = text
            case .noSpeechHeard: marks.noSpeechHeard = true
            default: break
            }
        }
        defer {
            watch.cancel()
            stateWatch.cancel()
            capture.stop()
            withExtendedLifetime(hub) {}
        }

        controller.bind(slotKey: slotKey)
        await controller.bindLoad?.value
        guard await within(deadline, { await controller.micTapped() }) else {
            controller.interrupt()
            row["err"] = "timeout:start"
            return row
        }
        guard case .recording = controller.state else {
            row["err"] = "notRecording:\(controller.state)"
                + (controller.languagePackPrompt == nil ? "" : ":languagePack")
            return row
        }

        // Feed the file and trailing silence; if recording is left midway (failure / interruption), finish early.
        while capture.fedSeconds < capture.totalSeconds - 0.01, case .recording = controller.state {
            if Date() >= deadline {
                controller.interrupt()
                row["err"] = "timeout:feed"
                return row
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        if case .recording = controller.state {
            guard await within(deadline, { await controller.finish(.insert) }) else {
                controller.interrupt()
                row["err"] = "timeout:finish"
                return row
            }
        }

        row["finishState"] = "\(controller.state)"
        if let trace, let started = capture.startedAtUptime { row["feedStartMs"] = trace.ms(started) }
        if let first = marks.firstLiveUptime, let started = capture.startedAtUptime, first >= started {
            row["firstPartialMs"] = (Double(first - started) / 1_000_000 - item.leadMs).rounded()
        }
        let finalText = marks.finalText ?? ""
        row["finalText"] = finalText
        if case .failed(let kind) = controller.state {
            row["err"] = "failed:\(kind)"
        } else if marks.noSpeechHeard {
            row["err"] = "noSpeechHeard"
        } else if finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            row["err"] = "emptyFinal:\(controller.state)"
        } else {
            row["ok"] = true
        }
        return row
    }

    /// Returns true if work completes before the deadline; returns false if not done in time (work keeps running in the background; the caller interrupts the controller).
    private static func within(_ deadline: Date, _ work: @escaping @MainActor () async -> Void) async -> Bool {
        let marks = Marks()
        Task { @MainActor in
            await work()
            marks.done = true
        }
        while !marks.done {
            if Date() >= deadline { return false }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return true
    }

    // MARK: Diagnostics (-S5_DIAG)

    /// `-VOICE_SIM_PROBE s5-dictation <corpus dir> -S5_DIAG [id,id,…]`: runs the specified entries for 2 turns each, recording per layer, written to s5-diag.json.
    /// Each turn: controller (live transcript sequence / events / state / state after finish) → slot recording and original WAV each go through SystemSTTEngine.transcribe →
    /// direct feed to SystemSTTSession (snapshot sequence and finish result) → direct feed to SFSpeechRecognizer (isFinal and text of each result, and errors).
    private static func diagnose(arguments: [String]) async {
        guard let index = arguments.firstIndex(of: mode), index + 1 < arguments.count,
              let flag = arguments.firstIndex(of: "-S5_DIAG") else { return }
        let directory = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(arguments[index + 1])
        let ids = flag + 1 < arguments.count && !arguments[flag + 1].hasPrefix("-")
            ? arguments[flag + 1].split(separator: ",").map(String.init)
            : ["dict-en-US-01", "dict-zh-CN-05", "dict-en-US-03", "dict-zh-CN-04"]
        let all: [Item]
        do { all = try makePlan(directory: directory) } catch {
            write(["phase": "error", "error": "manifest: \(error)"], name: "s5-diag")
            return
        }
        let settings = VoiceEngineSettings()
        let previousLanguage = settings.recognitionLanguage
        defer { settings.recognitionLanguage = previousLanguage }
        let engine = SystemSTTEngine.makeDefault(assets: SpeechAssetManager.makeDefault())
        var rounds: [[String: Any]] = []
        for id in ids {
            guard let item = all.first(where: { $0.id == id }) else { continue }
            for pass in 1...2 {
                let trace = Trace()
                var row = await round(item, directory: directory, trace: trace)
                row["pass"] = pass
                row["liveSeq"] = trace.live
                row["events"] = trace.events
                row["states"] = trace.states
                let store = try? RecordingStore(root: try RecordingStore.productionRoot())
                if let slotURL = store?.audioURL(for: slotKey), FileManager.default.fileExists(atPath: slotURL.path) {
                    row["slotTranscribe"] = await transcribeFile(slotURL, language: item.lang, engine: engine)
                } else {
                    row["slotTranscribe"] = "no slot recording"
                }
                let wav = directory.appendingPathComponent(item.file)
                row["wavTranscribe"] = await transcribeFile(wav, language: item.lang, engine: engine)
                row["directSession"] = await directSession(wav, language: item.lang, engine: engine)
                row["sfSpeech"] = await directSFSpeech(wav, language: item.lang)
                rounds.append(row)
                write(["phase": "running", "rounds": rounds], name: "s5-diag")
            }
        }
        write(["phase": "done", "osVersion": UIDevice.current.systemVersion, "rounds": rounds], name: "s5-diag")
        // Diagnostics run directly via simctl launch --console-pty: they exit right after writing, so launch returns with them; no polling for results.
        settings.recognitionLanguage = previousLanguage
        exit(0)
    }

    private static func transcribeFile(_ url: URL, language: String, engine: SystemSTTEngine) async -> String {
        do {
            let file = try AVAudioFile(forReading: url)
            let seconds = Double(file.length) / file.processingFormat.sampleRate
            let text = try await engine.transcribe(RecordingResult(url: url, durationSec: seconds, envelope: []),
                                                   language: language)
            return "ok(\(seconds.formatted(.number.precision(.fractionLength(2))))s): \(text)"
        } catch {
            return "error: \(error)"
        }
    }

    /// Reads the whole WAV, appends 1.5 s silence, and chunks it into 0.1 s blocks.
    private static func chunks(_ url: URL) throws -> [AVAudioPCMBuffer] {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = file.processingFormat
        let size = AVAudioFrameCount(format.sampleRate / 10)
        var out: [AVAudioPCMBuffer] = []
        while file.framePosition < file.length {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: size) else { break }
            try file.read(into: buffer, frameCount: size)
            if buffer.frameLength == 0 { break }
            out.append(buffer)
        }
        for _ in 0..<Int(tailSilenceSeconds * 10) {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: size) else { break }
            buffer.frameLength = size
            for channel in 0..<Int(format.channelCount) {
                buffer.floatChannelData?[channel].update(repeating: 0, count: Int(size))
            }
            out.append(buffer)
        }
        return out
    }

    /// Production live session direct feed (real-time pacing): snapshot sequence and finish result.
    private static func directSession(_ url: URL, language: String, engine: SystemSTTEngine) async -> [String: Any] {
        let buffers: [AVAudioPCMBuffer]
        do { buffers = try chunks(url) } catch { return ["error": "\(error)"] }
        let trace = Trace()
        let session = engine.startLive(language: language)
        let reader = Task { @MainActor in
            for await snapshot in session.snapshots {
                trace.live.append(["ms": trace.ms(), "finals": snapshot.finals, "partial": snapshot.partial])
            }
        }
        for buffer in buffers {
            session.feed(buffer)
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        var out: [String: Any] = ["feedEndMs": trace.ms()]
        do {
            out["finish"] = try await session.finish()
        } catch {
            out["finishError"] = "\(error)"
        }
        out["finishMs"] = trace.ms()
        await reader.value
        out["snapshots"] = trace.live
        return out
    }

    /// Direct SFSpeechRecognizer feed (same request settings as production): isFinal and text of each result, and errors.
    private static func directSFSpeech(_ url: URL, language: String) async -> [String: Any] {
        let buffers: [AVAudioPCMBuffer]
        do { buffers = try chunks(url) } catch { return ["error": "\(error)"] }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: language)) else {
            return ["error": "unsupported locale"]
        }
        let trace = Trace()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.addsPunctuation = true
        let onDevice = recognizer.supportsOnDeviceRecognition
        if onDevice { request.requiresOnDeviceRecognition = true }
        let marks = Marks()
        let task = recognizer.recognitionTask(with: request) { result, error in
            Task { @MainActor in
                if let result {
                    trace.live.append(["ms": trace.ms(), "isFinal": result.isFinal,
                                       "text": result.bestTranscription.formattedString])
                    if result.isFinal { marks.done = true }
                }
                if let error {
                    let ns = error as NSError
                    trace.events.append(["ms": trace.ms(), "error": "\(ns.domain) \(ns.code) \(ns.localizedDescription)"])
                    marks.done = true
                }
            }
        }
        for buffer in buffers {
            request.append(buffer)
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        let endMs = trace.ms()
        request.endAudio()
        let deadline = Date().addingTimeInterval(10)
        while !marks.done, Date() < deadline { try? await Task.sleep(nanoseconds: 20_000_000) }
        if !marks.done { task.cancel() }
        return ["onDevice": onDevice, "endAudioMs": endMs, "results": trace.live, "errors": trace.events,
                "completed": marks.done]
    }

    private static func clearSlot() throws {
        let store = try RecordingStore(root: try RecordingStore.productionRoot())
        try? FileManager.default.removeItem(at: store.audioURL(for: slotKey))
        try? FileManager.default.removeItem(at: store.sidecarURL(for: slotKey))
    }

    private static func write(_ object: [String: Any], name: String = mode) {
        let directory = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(VoiceSimProbe.outputDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
        try? data.write(to: directory.appendingPathComponent("\(name).json"), options: .atomic)
    }
}
#endif
