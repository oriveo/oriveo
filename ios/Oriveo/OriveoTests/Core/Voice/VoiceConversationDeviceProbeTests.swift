import AVFoundation
import Foundation
import SoundAnalysis
import Testing

/// Physical-device fact probe: the buffer format of the system TTS `write`, whether it can be scheduled into the
/// same AVAudioEngine that has voice processing on, speaker echo residual, the effect of VPIO on speaker loudness,
/// a rough click count, and how well the human voice is kept during double talk.
/// Only meaningful on a real device (the simulator has no VPIO and no real acoustic loop), so it is skipped on the simulator.
/// Results are printed as `VOICE_PROBE {json}` lines for a person to read; the assertions only guard against the pipeline not working at all.
/// To run, use an xcodebuild test invocation on the device (code signing enabled) with
///       -only-testing:OriveoTests/VoiceConversationDeviceProbeTests/<case>
/// The two cases that play audio through the speaker (`vpioPipeline`, `doubleTalk`) are skipped by default and only run when the environment variable
/// `ORIVEO_VOICE_PROBE_AUDIBLE=1` is set (pass `TEST_RUNNER_ORIVEO_VOICE_PROBE_AUDIBLE=1` on the xcodebuild side),
/// so nothing sounds off unexpectedly where noise is unwelcome. `doubleTalk` also needs another sound source speaking continuously nearby.
@Suite("Voice conversation device probe", .serialized, .enabled(if: VoiceProbeEnv.isPhysicalDevice))
struct VoiceConversationDeviceProbeTests {

    @Test("TTS write buffer formats per voice")
    func ttsWriteFormats() async throws {
        let voices = VoiceProbeEnv.probeVoices()
        VoiceProbeEnv.emit("voices", [
            "personalVoiceAuthorization": "\(AVSpeechSynthesizer.personalVoiceAuthorizationStatus.rawValue)",
            "available": voices.map { "\($0.language)|\($0.quality.rawValue)|\($0.name)|\($0.identifier)" },
            "premiumCount": AVSpeechSynthesisVoice.speechVoices().filter { $0.quality == .premium }.count,
            "enhancedCount": AVSpeechSynthesisVoice.speechVoices().filter { $0.quality == .enhanced }.count,
            "personalCount": AVSpeechSynthesisVoice.speechVoices().filter { $0.voiceTraits.contains(.isPersonalVoice) }.count,
        ])
        for voice in voices {
            let text = voice.language.hasPrefix("zh") ? VoiceProbeEnv.zhSentence : VoiceProbeEnv.enSentence
            let result = await TTSCollector.collect(text: text, voice: voice)
            VoiceProbeEnv.emit("tts_write", [
                "voice": voice.identifier,
                "quality": voice.quality.rawValue,
                "language": voice.language,
                "settings": voice.audioFileSettings.map { "\($0.key)=\($0.value)" }.sorted(),
            ].merging(result.summary) { $1 })
        }
        let defaultVoice = try #require(voices.first)
        let first = await TTSCollector.collect(text: VoiceProbeEnv.zhSentence, voice: defaultVoice)
        #expect(first.frames > 0, "default voice produced no PCM via write()")
    }

    @Test("VPIO pipeline: echo residual, loudness, clicks", .enabled(if: VoiceProbeEnv.audibleAllowed))
    func vpioPipeline() async throws {
        try await VoiceProbeEnv.requireMicrophone()
        let voice = try #require(VoiceProbeEnv.probeVoices().first)
        let tts = await TTSCollector.collect(text: VoiceProbeEnv.zhSentence, voice: voice)
        let source = try #require(tts.buffers.first?.format)

        // 1) Voice processing on: noise floor, echo residual, and the raw mic after bypass (= speaker loudness on the VPIO output path)
        let vp = try ProbeEngine(voiceProcessing: true, ttsFormat: source)
        VoiceProbeEnv.emit("vp_session", vp.describe())
        let noise = try await vp.measure(label: "vp_noise", seconds: 2.0, play: nil)
        let residual = try await vp.measure(label: "vp_tts_residual", seconds: tts.seconds + 0.8, play: tts.buffers)
        vp.setBypassed(true)
        let rawVPIO = try await vp.measure(label: "vp_bypassed_tts_raw", seconds: tts.seconds + 0.8, play: tts.buffers)
        vp.setBypassed(false)
        vp.stop()

        // 2) Voice processing off, plain playAndRecord: raw mic level and click baseline for the same TTS played through the speaker
        let plain = try ProbeEngine(voiceProcessing: false, ttsFormat: source)
        VoiceProbeEnv.emit("plain_session", plain.describe())
        let plainNoise = try await plain.measure(label: "plain_noise", seconds: 2.0, play: nil)
        let rawPlain = try await plain.measure(label: "plain_tts_raw", seconds: tts.seconds + 0.8, play: tts.buffers)
        plain.stop()

        VoiceProbeEnv.emit("vp_summary", [
            "echoSuppressionDb": rawVPIO.activeMeanDb - residual.activeMeanDb,
            "residualOverNoiseDb": residual.activeMeanDb - noise.meanDb,
            "residualSpeechConfidenceMax": residual.speechMax,
            "residualSpeechWindowsOver0_5": residual.speechOver05,
            "speakerLevelVPIOvsPlainDb": rawVPIO.activeMeanDb - rawPlain.activeMeanDb,
            "mixerLevelVPIOvsPlainDb": rawVPIO.mixerMeanDb - rawPlain.mixerMeanDb,
            "clicksPerSecVPIO": rawVPIO.clicksPerSecond,
            "clicksPerSecPlain": rawPlain.clicksPerSecond,
            "noiseVPDb": noise.meanDb,
            "noisePlainDb": plainNoise.meanDb,
        ])
        #expect(rawVPIO.mixerMeanDb > -60, "TTS buffers did not reach the VPIO engine output")
    }

    @Test("Double talk: near-end speech kept while own TTS plays", .enabled(if: VoiceProbeEnv.audibleAllowed))
    func doubleTalk() async throws {
        try await VoiceProbeEnv.requireMicrophone()
        let voice = try #require(VoiceProbeEnv.probeVoices().first(where: { $0.language.hasPrefix("en") }) ?? VoiceProbeEnv.probeVoices().first)
        let tts = await TTSCollector.collect(text: VoiceProbeEnv.enSentence + " " + VoiceProbeEnv.enSentence, voice: voice)
        let source = try #require(tts.buffers.first?.format)

        let vp = try ProbeEngine(voiceProcessing: true, ttsFormat: source)
        let human = try await vp.measure(label: "dt_vp_human_only", seconds: tts.seconds, play: nil)
        let both = try await vp.measure(label: "dt_vp_human_plus_tts", seconds: tts.seconds, play: tts.buffers)
        vp.stop()
        let plain = try ProbeEngine(voiceProcessing: false, ttsFormat: source)
        let humanRaw = try await plain.measure(label: "dt_plain_human_only", seconds: tts.seconds, play: nil)
        plain.stop()

        VoiceProbeEnv.emit("dt_summary", [
            "humanVPDb": human.meanDb,
            "humanPlusTtsVPDb": both.meanDb,
            "humanRawDb": humanRaw.meanDb,
            "speechConfHumanOnlyVP": human.speechMean,
            "speechConfHumanPlusTtsVP": both.speechMean,
            "speechWindowsOver0_5HumanOnly": human.speechOver05,
            "speechWindowsOver0_5HumanPlusTts": both.speechOver05,
        ])
    }
}

// MARK: - Environment

nonisolated enum VoiceProbeEnv {
    static let zhSentence = "\u{7B2C}\u{4E8C}\u{5929}\u{53EF}\u{4EE5}\u{6539}\u{53BB}\u{5948}\u{826F}\u{FF1A}\u{4E0A}\u{5348}\u{5148}\u{770B}\u{4E1C}\u{5927}\u{5BFA}\u{FF0C}\u{4E2D}\u{5348}\u{5728}\u{9644}\u{8FD1}\u{5403}\u{4E00}\u{7897}\u{4E4C}\u{51AC}\u{FF0C}\u{4E0B}\u{5348}\u{53BB}\u{6625}\u{65E5}\u{5927}\u{793E}\u{6563}\u{6B65}\u{3002}"
    static let enSentence = "On the second day you can go to Nara, visit Todaiji in the morning, and walk to Kasuga Taisha in the afternoon."

    static var isPhysicalDevice: Bool {
        #if targetEnvironment(simulator)
        false
        #else
        true
        #endif
    }

    static var audibleAllowed: Bool {
        ProcessInfo.processInfo.environment["ORIVEO_VOICE_PROBE_AUDIBLE"] == "1"
    }

    /// For each language: the default voice, the highest-quality one, and personal voices (if authorized and visible).
    static func probeVoices() -> [AVSpeechSynthesisVoice] {
        var picked: [AVSpeechSynthesisVoice] = []
        for language in ["zh-CN", "en-US"] {
            if let v = AVSpeechSynthesisVoice(language: language) { picked.append(v) }
            let best = AVSpeechSynthesisVoice.speechVoices()
                .filter { $0.language == language }
                .max { $0.quality.rawValue < $1.quality.rawValue }
            if let best, !picked.contains(where: { $0.identifier == best.identifier }) { picked.append(best) }
        }
        picked += AVSpeechSynthesisVoice.speechVoices().filter { $0.voiceTraits.contains(.isPersonalVoice) }
        return picked
    }

    static func requireMicrophone() async throws {
        let granted = await AVAudioApplication.requestRecordPermission()
        emit("mic_permission", ["granted": granted])
        try #require(granted, "microphone permission not granted to test host")
    }

    static func emit(_ event: String, _ fields: [String: Any]) {
        var payload = fields
        payload["event"] = event
        let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data()
        print("VOICE_PROBE " + (String(data: data, encoding: .utf8) ?? "{}"))
    }
}

// MARK: - TTS collection

nonisolated final class TTSCollector: @unchecked Sendable {
    struct Result {
        var buffers: [AVAudioPCMBuffer] = []
        var bufferCount = 0
        var zeroLengthCount = 0
        var nonPCMCount = 0
        var frames: AVAudioFrameCount = 0
        var firstBufferMs: Double = -1
        var totalMs: Double = 0
        var format: String = ""
        var seconds: Double {
            guard let f = buffers.first?.format, f.sampleRate > 0 else { return 0 }
            return Double(frames) / f.sampleRate
        }
        var summary: [String: Any] {
            ["bufferCount": bufferCount, "zeroLengthCount": zeroLengthCount, "nonPCMCount": nonPCMCount,
             "frames": Int(frames), "audioSeconds": seconds, "firstBufferMs": firstBufferMs,
             "totalMs": totalMs, "format": format]
        }
    }

    private let synthesizer = AVSpeechSynthesizer()
    private let lock = NSLock()
    private var result = Result()
    private var finished = false

    static func collect(text: String, voice: AVSpeechSynthesisVoice) async -> Result {
        let collector = TTSCollector()
        return await collector.run(text: text, voice: voice)
    }

    private func run(text: String, voice: AVSpeechSynthesisVoice) async -> Result {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        let start = Date()
        return await withCheckedContinuation { (continuation: CheckedContinuation<Result, Never>) in
            let finish: @Sendable () -> Void = { [self] in
                lock.lock()
                guard !finished else { lock.unlock(); return }
                finished = true
                result.totalMs = Date().timeIntervalSince(start) * 1000
                let snapshot = result
                lock.unlock()
                continuation.resume(returning: snapshot)
            }
            synthesizer.write(utterance) { [self] buffer in
                lock.lock()
                result.bufferCount += 1
                guard let pcm = buffer as? AVAudioPCMBuffer else {
                    result.nonPCMCount += 1
                    lock.unlock()
                    return
                }
                if result.format.isEmpty { result.format = Self.describe(pcm.format) }
                if pcm.frameLength == 0 {
                    // The system signals the end with a zero-length buffer
                    result.zeroLengthCount += 1
                    lock.unlock()
                    finish()
                    return
                }
                if result.firstBufferMs < 0 { result.firstBufferMs = Date().timeIntervalSince(start) * 1000 }
                result.frames += pcm.frameLength
                result.buffers.append(pcm)
                lock.unlock()
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 20, execute: finish)
        }
    }

    static func describe(_ f: AVAudioFormat) -> String {
        "common=\(f.commonFormat.rawValue) sr=\(f.sampleRate) ch=\(f.channelCount) interleaved=\(f.isInterleaved)"
    }
}

// MARK: - Engine and measurement

nonisolated final class ProbeEngine: @unchecked Sendable {
    struct Measurement {
        var meanDb: Double
        var activeMeanDb: Double
        var mixerMeanDb: Double
        var clicksPerSecond: Double
        var speechMax: Double
        var speechMean: Double
        var speechOver05: Int
    }

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let voiceProcessing: Bool
    private let playFormat: AVAudioFormat
    private let lock = NSLock()
    private var micDb: [Double] = []
    private var mixerDb: [Double] = []
    private var clicks = 0
    private var micSeconds: Double = 0
    private let analysisQueue = DispatchQueue(label: "voice.probe.analysis")

    init(voiceProcessing: Bool, ttsFormat: AVAudioFormat) throws {
        self.voiceProcessing = voiceProcessing
        let session = AVAudioSession.sharedInstance()
        if voiceProcessing {
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker])
        } else {
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
        }
        try session.setActive(true)
        try engine.inputNode.setVoiceProcessingEnabled(voiceProcessing)
        if voiceProcessing {
            engine.inputNode.voiceProcessingOtherAudioDuckingConfiguration =
                .init(enableAdvancedDucking: false, duckingLevel: .min)
        }
        // The write buffers may be Int16 / Float32; the player takes standard non-interleaved Float32, converted with AVAudioConverter
        guard let standard = AVAudioFormat(standardFormatWithSampleRate: ttsFormat.sampleRate, channels: ttsFormat.channelCount) else {
            throw ProbeError.format
        }
        playFormat = standard
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: standard)
        engine.prepare()
        try engine.start()
    }

    func describe() -> [String: Any] {
        let session = AVAudioSession.sharedInstance()
        let route = session.currentRoute
        return [
            "voiceProcessing": voiceProcessing,
            "category": session.category.rawValue,
            "mode": session.mode.rawValue,
            "outputs": route.outputs.map { "\($0.portType.rawValue)" },
            "inputs": route.inputs.map { "\($0.portType.rawValue)" },
            "sessionSampleRate": session.sampleRate,
            "ioBufferDuration": session.ioBufferDuration,
            "outputVolume": session.outputVolume,
            "inputFormat": TTSCollector.describe(engine.inputNode.outputFormat(forBus: 0)),
            "outputFormat": TTSCollector.describe(engine.outputNode.outputFormat(forBus: 0)),
            "agcEnabled": engine.inputNode.isVoiceProcessingAGCEnabled,
            "playFormat": TTSCollector.describe(playFormat),
        ]
    }

    func setBypassed(_ bypassed: Bool) {
        engine.inputNode.isVoiceProcessingBypassed = bypassed
    }

    func stop() {
        player.stop()
        engine.stop()
        try? engine.inputNode.setVoiceProcessingEnabled(false)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func measure(label: String, seconds: Double, play: [AVAudioPCMBuffer]?) async throws -> Measurement {
        reset()
        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        let stream = SNAudioStreamAnalyzer(format: inFormat)
        let obs = SpeechObserver()
        try stream.add(SNClassifySoundRequest(classifierIdentifier: .version1), withObserver: obs)
        let queue = analysisQueue
        input.installTap(onBus: 0, bufferSize: 1024, format: inFormat) { [self] buffer, time in
            consumeMic(buffer)
            queue.async { stream.analyze(buffer, atAudioFramePosition: time.sampleTime) }
        }
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { [self] buffer, _ in
            let db = Self.rmsDb(buffer)
            lock.lock(); mixerDb.append(db); lock.unlock()
        }
        if let play {
            let converted = try play.map { try convert($0) }
            for buffer in converted { player.scheduleBuffer(buffer, completionHandler: nil) }
            player.play()
        }
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        input.removeTap(onBus: 0)
        engine.mainMixerNode.removeTap(onBus: 0)
        player.stop()
        queue.sync { stream.completeAnalysis() }

        lock.lock()
        let mic = micDb, mixer = mixerDb, clickCount = clicks, micSecs = micSeconds
        lock.unlock()
        let scores = obs.snapshot()
        let mean = Self.powerMean(mic)
        // "Active" = buffers above the 25th percentile + 6 dB of this stretch, so pauses between sentences do not pull the mean down
        let floor = Self.percentile(mic, 0.25)
        let active = mic.filter { $0 > floor + 6 }
        let m = Measurement(
            meanDb: mean,
            activeMeanDb: active.isEmpty ? mean : Self.powerMean(active),
            mixerMeanDb: Self.powerMean(mixer.filter { $0 > -90 }),
            clicksPerSecond: micSecs > 0 ? Double(clickCount) / micSecs : 0,
            speechMax: scores.max() ?? 0,
            speechMean: scores.isEmpty ? 0 : scores.reduce(0, +) / Double(scores.count),
            speechOver05: scores.filter { $0 > 0.5 }.count
        )
        VoiceProbeEnv.emit("measure", [
            "label": label, "meanDb": m.meanDb, "activeMeanDb": m.activeMeanDb, "mixerMeanDb": m.mixerMeanDb,
            "clicksPerSecond": m.clicksPerSecond, "speechMax": m.speechMax, "speechMean": m.speechMean,
            "speechWindowsOver0_5": m.speechOver05, "speechWindows": scores.count, "micBuffers": mic.count,
        ])
        return m
    }

    private func reset() {
        lock.lock()
        micDb = []; mixerDb = []; clicks = 0; micSeconds = 0
        lock.unlock()
    }

    private func convert(_ buffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        if buffer.format == playFormat { return buffer }
        guard let converter = AVAudioConverter(from: buffer.format, to: playFormat),
              let out = AVAudioPCMBuffer(pcmFormat: playFormat, frameCapacity: buffer.frameLength) else {
            throw ProbeError.format
        }
        try converter.convert(to: out, from: buffer)
        return out
    }

    private func consumeMic(_ buffer: AVAudioPCMBuffer) {
        let db = Self.rmsDb(buffer)
        let n = Int(buffer.frameLength)
        var clickCount = 0
        if let ch = buffer.floatChannelData?[0], n > 3 {
            // Rough click count: samples whose second difference exceeds 12 times this buffer's second-difference RMS and whose absolute value is > 0.02 (at least 1 ms apart)
            var sum = 0.0
            for i in 2..<n {
                let d2 = Double(ch[i] - 2 * ch[i - 1] + ch[i - 2])
                sum += d2 * d2
            }
            let rms = (sum / Double(n - 2)).squareRoot()
            var lastClick = -1000
            for i in 2..<n {
                let d2 = abs(Double(ch[i] - 2 * ch[i - 1] + ch[i - 2]))
                if d2 > max(12 * rms, 0.02), i - lastClick > 48 {
                    clickCount += 1
                    lastClick = i
                }
            }
        }
        lock.lock()
        micDb.append(db)
        clicks += clickCount
        micSeconds += Double(n) / buffer.format.sampleRate
        lock.unlock()
    }

    static func rmsDb(_ buffer: AVAudioPCMBuffer) -> Double {
        guard let ch = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return -120 }
        var sum: Float = 0
        for i in 0..<Int(buffer.frameLength) { sum += ch[i] * ch[i] }
        let rms = (sum / Float(buffer.frameLength)).squareRoot()
        return rms > 0 ? 20 * log10(Double(rms)) : -120
    }

    static func powerMean(_ dbs: [Double]) -> Double {
        guard !dbs.isEmpty else { return -120 }
        let p = dbs.map { pow(10, $0 / 10) }.reduce(0, +) / Double(dbs.count)
        return 10 * log10(max(p, 1e-12))
    }

    static func percentile(_ values: [Double], _ q: Double) -> Double {
        guard !values.isEmpty else { return -120 }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int(Double(sorted.count) * q))]
    }
}

nonisolated enum ProbeError: Error { case format }

nonisolated final class SpeechObserver: NSObject, SNResultsObserving, @unchecked Sendable {
    private let lock = NSLock()
    private var scores: [Double] = []

    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let result = result as? SNClassificationResult else { return }
        let speech = result.classification(forIdentifier: "speech")?.confidence ?? 0
        lock.lock(); scores.append(speech); lock.unlock()
    }

    func snapshot() -> [Double] {
        lock.lock(); defer { lock.unlock() }
        return scores
    }
}
