#if DEBUG
import AVFoundation
import Foundation
import Speech
import UIKit

/// S0 on-device voice probe: records facts only, does not judge correctness.
/// Triggered by `-VOICE_SIM_PROBE s0 <zh audio> <en audio>` (relative to the data container, 16 kHz mono); results are written to tmp/voice-sim-probe/s0.json.
/// Measures three things: the first partial result and finalization latency of SpeechTranscriber / SFSpeechRecognizer when fed at real-time pace;
/// and the echo tail duration on the microphone after VPIO playback finishes (.dataPlayedBack).
@MainActor
enum VoiceS0Probe {

    static func run(arguments: [String]) async {
        guard let index = arguments.firstIndex(of: "s0"), index + 2 < arguments.count else {
            write(["phase": "error", "error": "usage: s0 <zh> <en>"])
            return
        }
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let zh = home.appendingPathComponent(arguments[index + 1])
        let en = home.appendingPathComponent(arguments[index + 2])
        var report: [String: Any] = ["phase": "running", "os": UIDevice.current.systemVersion]
        write(report)

        report["micGranted"] = await AVAudioApplication.requestRecordPermission()
        report["speechAuth"] = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: "\($0.rawValue)") }
        }
        var runs: [[String: Any]] = []
        // With tailOnly, only measure the echo tail (skips the recognition pass, which saves a minute when already measured).
        for (tag, url) in arguments.contains("tailOnly") ? [] : [("zh-CN", zh), ("en-US", en)] {
            if #available(iOS 26, *) {
                runs.append(await analyzerRun(tag: tag, url: url))
            } else {
                runs.append(["engine": "SpeechTranscriber.progressive", "lang": tag, "error": "iOS < 26"])
            }
            write(report.merging(["runs": runs]) { $1 })
            for onDevice in [true, false] {
                runs.append(await sfSpeechRun(tag: tag, url: url, onDevice: onDevice))
                write(report.merging(["runs": runs]) { $1 })
            }
        }
        report["runs"] = runs
        var tails: [[String: Any]] = []
        for round in 0..<3 {
            tails.append(await tailRound(url: en, round: round))
            write(report.merging(["tails": tails]) { $1 })
        }
        report["tails"] = tails
        report["phase"] = "done"
        write(report)
    }

    // MARK: Recognition

    @available(iOS 26, *)
    private static func analyzerRun(tag: String, url: URL) async -> [String: Any] {
        var out: [String: Any] = ["engine": "SpeechTranscriber.progressive", "lang": tag]
        guard SpeechTranscriber.isAvailable,
              let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: tag)) else {
            out["error"] = "unsupported"
            return out
        }
        out["locale"] = locale.identifier
        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        out["assetBefore"] = "\(await AssetInventory.status(forModules: [transcriber]))"
        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                let started = Date()
                try await request.downloadAndInstall()
                out["assetInstallSec"] = Date().timeIntervalSince(started)
            }
        } catch {
            out["assetError"] = "\(error)"
        }
        do {
            let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber], considering: file.processingFormat),
                  let converter = PCMFormatConverter(from: file.processingFormat, to: format) else {
                out["error"] = "no format"
                return out
            }
            let (stream, input) = AsyncStream.makeStream(of: AnalyzerInput.self)
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            try await analyzer.start(inputSequence: stream)
            let clock = S0Clock()
            let results = Task { () -> [String: Any] in
                var firstVolatile = -1.0
                var volatileCount = 0
                var finals: [String] = []
                var lastFinalAt = -1.0
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    if result.isFinal {
                        finals.append(text)
                        lastFinalAt = clock.ms()
                    } else if !text.isEmpty {
                        if firstVolatile < 0 { firstVolatile = clock.ms() }
                        volatileCount += 1
                    }
                }
                return ["firstVolatileMs": firstVolatile, "volatileCount": volatileCount, "finalMs": lastFinalAt, "text": finals.joined()]
            }
            let speechMs = await feed(file: file, clock: clock) { buffer in
                if let converted = converter.convert(buffer) { input.yield(AnalyzerInput(buffer: converted)) }
            }
            out["speechMs"] = speechMs
            input.finish()
            try await analyzer.finalizeAndFinishThroughEndOfInput()
            out.merge(try await results.value) { $1 }
        } catch {
            out["error"] = "\(error)"
        }
        return out
    }

    private static func sfSpeechRun(tag: String, url: URL, onDevice: Bool) async -> [String: Any] {
        var out: [String: Any] = ["engine": "SFSpeechRecognizer", "lang": tag, "requiresOnDevice": onDevice]
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: tag)), recognizer.isAvailable else {
            out["error"] = "unavailable"
            return out
        }
        out["supportsOnDevice"] = recognizer.supportsOnDeviceRecognition
        if onDevice && !recognizer.supportsOnDeviceRecognition {
            out["error"] = "onDevice unsupported"
            return out
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = onDevice
        let clock = S0Clock()
        let collector = S0PartialCollector(clock: clock)
        let done = AsyncStream.makeStream(of: Void.self)
        let task = recognizer.recognitionTask(with: request) { result, error in
            collector.observe(result: result, error: error)
            if error != nil || result?.isFinal == true { done.continuation.finish() }
        }
        do {
            let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
            out["speechMs"] = await feed(file: file, clock: clock) { request.append($0) }
            request.endAudio()
        } catch {
            out["error"] = "\(error)"
            task.cancel()
            return out
        }
        let timeout = Task { try? await Task.sleep(for: .seconds(15)); done.continuation.finish() }
        for await _ in done.stream {}
        timeout.cancel()
        task.cancel()
        out.merge(collector.snapshot()) { $1 }
        return out
    }

    /// Feeds the file at real-time pace plus 1.5 s of silence; returns the speech end time (ms, relative to the clock start).
    private static func feed(file: AVAudioFile, clock: S0Clock, append: @escaping (AVAudioPCMBuffer) -> Void) async -> Double {
        let format = file.processingFormat
        let chunk = AVAudioFrameCount(format.sampleRate / 50)
        clock.reset()
        var position: AVAudioFramePosition = 0
        var speechEnd = -1.0
        let silenceFrames = AVAudioFramePosition(format.sampleRate * 1.5)
        while true {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { break }
            if position < file.length {
                try? file.read(into: buffer, frameCount: chunk)
                if buffer.frameLength == 0 { break }
            } else if position < file.length + silenceFrames {
                buffer.frameLength = chunk
                for channel in 0..<Int(format.channelCount) {
                    buffer.floatChannelData?[channel].update(repeating: 0, count: Int(chunk))
                }
            } else {
                break
            }
            append(buffer)
            position += AVAudioFramePosition(buffer.frameLength)
            if position >= file.length && speechEnd < 0 { speechEnd = clock.ms() }
            let dueMs = Double(position) / format.sampleRate * 1000
            let wait = dueMs - clock.ms()
            if wait > 0 { try? await Task.sleep(for: .milliseconds(Int(wait))) }
        }
        return speechEnd
    }

    // MARK: Echo tail

    private static func tailRound(url: URL, round: Int) async -> [String: Any] {
        var out: [String: Any] = ["round": round]
        let session = AVAudioSession.sharedInstance()
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        do {
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker])
            try session.setActive(true)
            try engine.inputNode.setVoiceProcessingEnabled(true)
            let file = try AVAudioFile(forReading: url)
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: file.processingFormat)
            let meter = S0LevelLog()
            let inputFormat = engine.inputNode.outputFormat(forBus: 0)
            engine.inputNode.installTap(onBus: 0, bufferSize: 960, format: inputFormat) { buffer, _ in
                meter.add(buffer)
            }
            try engine.start()
            try await Task.sleep(for: .seconds(1))
            let playStart = ProcessInfo.processInfo.systemUptime
            let played = AsyncStream.makeStream(of: Double.self)
            player.scheduleFile(file, at: nil, completionCallbackType: .dataPlayedBack) { _ in
                played.continuation.yield(ProcessInfo.processInfo.systemUptime)
                played.continuation.finish()
            }
            player.play()
            // .dataPlayedBack may be delayed or never fire in the VPIO graph: fall back to file duration + 3 s and log it.
            let fileSeconds = Double(file.length) / file.processingFormat.sampleRate
            let watchdog = Task {
                try? await Task.sleep(for: .seconds(fileSeconds + 3))
                played.continuation.finish()
            }
            var playedAt = -1.0
            for await at in played.stream { playedAt = at }
            watchdog.cancel()
            out["playedBackCallback"] = playedAt > 0
            if playedAt < 0 { playedAt = playStart + fileSeconds }
            try await Task.sleep(for: .seconds(3))
            engine.inputNode.removeTap(onBus: 0)
            player.stop()
            engine.stop()
            out.merge(meter.summary(playStart: playStart, playedAt: playedAt)) { $1 }
            out["outputRoute"] = session.currentRoute.outputs.map(\.portType.rawValue).joined(separator: ",")
            out["outputVolume"] = session.outputVolume
        } catch {
            out["error"] = "\(error)"
        }
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
        return out
    }

    private static func write(_ object: [String: Any]) {
        let directory = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(VoiceSimProbe.outputDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .prettyPrinted]) else { return }
        try? data.write(to: directory.appendingPathComponent("s0.json"), options: .atomic)
    }
}

nonisolated final class S0Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var start = ProcessInfo.processInfo.systemUptime

    func reset() {
        lock.lock()
        start = ProcessInfo.processInfo.systemUptime
        lock.unlock()
    }

    func ms() -> Double {
        lock.lock()
        defer { lock.unlock() }
        return (ProcessInfo.processInfo.systemUptime - start) * 1000
    }
}

nonisolated final class S0PartialCollector: @unchecked Sendable {
    private let lock = NSLock()
    private let clock: S0Clock
    private var firstPartial = -1.0
    private var partials = 0
    private var finalAt = -1.0
    private var text = ""
    private var error = ""

    init(clock: S0Clock) { self.clock = clock }

    func observe(result: SFSpeechRecognitionResult?, error: Error?) {
        lock.lock()
        defer { lock.unlock() }
        if let error { self.error = "\(error)" }
        guard let result else { return }
        let best = result.bestTranscription.formattedString
        if result.isFinal {
            finalAt = clock.ms()
            text = best
        } else if !best.isEmpty {
            if firstPartial < 0 { firstPartial = clock.ms() }
            partials += 1
            text = best
        }
    }

    func snapshot() -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        return ["firstPartialMs": firstPartial, "partials": partials, "finalMs": finalAt, "text": text, "taskError": error]
    }
}

/// One dBFS sample per tap buffer, stamped with system uptime.
nonisolated final class S0LevelLog: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [(Double, Double)] = []

    func add(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
        var sum: Float = 0
        for i in 0..<Int(buffer.frameLength) { sum += data[i] * data[i] }
        let rms = sqrt(sum / Float(buffer.frameLength))
        let db = rms > 0 ? 20 * log10(Double(rms)) : -120
        lock.lock()
        samples.append((ProcessInfo.processInfo.systemUptime, db))
        lock.unlock()
    }

    func summary(playStart: Double, playedAt: Double) -> [String: Any] {
        lock.lock()
        let all = samples
        lock.unlock()
        let baseline = all.filter { $0.0 < playStart }.map(\.1).sorted()
        let floor = baseline.isEmpty ? -90 : baseline[baseline.count / 2]
        let during = all.filter { $0.0 >= playStart && $0.0 <= playedAt }.map(\.1)
        let after = all.filter { playedAt > 0 && $0.0 > playedAt }
        let loud = after.filter { $0.1 > floor + 6 }
        let tailMs = (loud.map(\.0).max().map { ($0 - playedAt) * 1000 }) ?? 0
        let peakAfter300 = after.filter { ($0.0 - playedAt) < 0.3 }.map(\.1).max() ?? -120
        return [
            "floorDb": floor, "peakDuringDb": during.max() ?? -120, "peakFirst300msAfterDb": peakAfter300,
            "tailAboveFloor6Ms": tailMs, "playedBackMs": playedAt > 0 ? (playedAt - playStart) * 1000 : -1,
        ]
    }
}
#endif
