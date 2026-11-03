#if DEBUG
import AVFoundation
import Foundation
import MediaPlayer
import os
import UIKit

/// Realtime playback echo bench (schema realtime-echo-bench/v1): the production VPIOConversationAudioEngine starts real-time capture,
/// after a 3 s silence baseline, plays the corpus replies[] (reply/*.wav, 16 kHz resampled to 24 kHz downlink) segment by segment as model downlink audio, waiting 2 s after each segment finishes;
/// nobody speaks throughout. Variable-length uplink chunks are cut into 20 ms frames, and each frame is stepped through the production RealtimeUplinkGate and both VoiceConversationLogic.Vad
/// (energy and Silero model modes). pb = before the first downlink chunk of the segment is enqueued, pe = onPlaybackDrained (same start and real drain timing as the production host).
/// `-VOICE_SIM_PROBE realtime-echo <corpus dir> <vpio|raw> <volumePct> <runId>` (corpus dir is relative to the data container; contains manifest.json and reply/).
/// The raw group injects a no-op setEnabled voice processing stub (no VPIO). Measurement only, no threshold assertions; criteria per contract item 6:
/// volumePct = requested value (matches the file name); actual system volume is recorded separately as outputVolumePct; baseline = median of the first 150 frames after capture starts;
/// if Silero fails to load, the group exits with phase=error; if inference fails during the run (sileroErrors > 0), the group records phase=error and does not fall back to energy. Results go to tmp/voice-sim-probe/realtime-echo-ios-<source>-<volume>.json
/// (with phase and runId). Logs one `realtime-echo platform=ios ...` summary line under category RealtimeEcho.
@MainActor
enum RealtimeEchoBench {

    static let mode = "realtime-echo"
    static let schema = "realtime-echo-bench/v1"
    /// Uplink at 16 kHz: 20 ms = 320 samples, fed directly to Silero without resampling.
    static let uplinkSampleRate = 16_000.0
    static let baselineNanoseconds: UInt64 = 3_000_000_000
    /// Baseline frame count: the first 150 frames (3 s) after capture starts.
    static let baselineFrames = 150
    /// Fallback cap when baseline frames cannot be collected in time.
    static let baselineLimitMs = 10_000.0
    static let tailNanoseconds: UInt64 = 2_000_000_000
    /// Each downlink chunk is 200 ms (24 kHz).
    static let downlinkChunkSamples = 4_800
    /// Fallback cap when a segment cannot finish playing.
    static let drainLimitMs = 60_000.0
    static let pollNanoseconds: UInt64 = 20_000_000
    private static let logger = Logger(subsystem: "ai.oriveo.community", category: "RealtimeEcho")

    struct Reply {
        let id: String
        let lang: String
        let pcm16: Data
    }

    static func run(arguments: [String]) async {
        guard let index = arguments.firstIndex(of: mode), index + 4 < arguments.count,
              let volume = Int(arguments[index + 3]) else {
            VoiceS5SimConversation.write(
                name: "\(mode).json",
                ["phase": "error", "error": "usage: realtime-echo <corpus> <vpio|raw> <volumePct> <runId>"]
            )
            return
        }
        let source = arguments[index + 2]
        let runId = arguments[index + 4]
        let output = "realtime-echo-ios-\(source)-\(volume).json"
        let device = deviceName
        let os = "iOS \(UIDevice.current.systemVersion)"
        var header: [String: Any] = [
            "schema": schema, "platform": "ios", "device": device, "os": os, "runId": runId,
            "source": source, "volumePct": volume, "uplinkSampleRate": uplinkSampleRate,
        ]
        func fail(_ message: String) {
            VoiceS5SimConversation.write(name: output, header.merging(["phase": "error", "error": message]) { $1 })
        }
        guard ["vpio", "raw"].contains(source) else { return fail("unsupported source \(source)") }
        VoiceS5SimConversation.write(name: output, header.merging(["phase": "running"]) { $1 })
        let replies: [Reply]
        do {
            replies = try loadReplies(
                directory: URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(arguments[index + 1])
            )
        } catch {
            return fail("manifest: \(error)")
        }

        let processing = EchoVoiceProcessing()
        let engine = VPIOConversationAudioEngine(voiceProcessing: { audioEngine in
            if source == "vpio" { processing.base = EngineConversationVoiceProcessing(audioEngine) }
            return processing
        })
        do {
            try await engine.prepareSession()
        } catch {
            return fail("prepareSession: \(error)")
        }
        header["outputVolumePct"] = await setVolume(volume)
        let route = engine.route
        header["route"] = route.rawValue
        let meter: EchoMeter
        do {
            meter = try EchoMeter(route: route)
        } catch {
            return fail("silero: \(error)")
        }
        var interrupted = false
        var drained = false
        engine.onPlaybackDrained = {
            meter.playbackEnded()
            drained = true
        }
        do {
            try engine.startRealtime(
                uplinkSampleRate: uplinkSampleRate,
                onFrame: { data in
                    // Same as production host: read the reference at capture callback time; item j = the chunk where the playhead was j gate frames back (up to this many frames from this chunk)
                    let most = data.count / 2 / EchoMeter.frameSamples + 1
                    let refs = engine.playbackReferenceDb(behindSamples: (0..<most).map { $0 * RealtimeUplink.referenceBlockSamples })
                    DispatchQueue.main.async { MainActor.assumeIsolated { meter.consume(data, refsBehind: refs) } }
                },
                onInterruption: { interrupted = true }
            )
        } catch {
            return fail("startRealtime: \(error)")
        }
        defer { engine.stopRealtime() }
        let aec = processing.isEnabled
        header["aec"] = aec
        VoiceS5SimConversation.write(name: output, header.merging(["phase": "running"]) { $1 })

        try? await Task.sleep(nanoseconds: baselineNanoseconds)
        let baselineStarted = DispatchTime.now().uptimeNanoseconds
        while meter.frameCount < baselineFrames && !interrupted {
            if VoiceS5SimConversation.milliseconds(from: baselineStarted, to: DispatchTime.now().uptimeNanoseconds) > baselineLimitMs {
                return fail("baseline: \(meter.frameCount)/\(baselineFrames) frames")
            }
            try? await Task.sleep(nanoseconds: pollNanoseconds)
        }
        if interrupted { return fail("audio interrupted") }
        meter.closeBaseline(frames: baselineFrames)
        header["baselineDb"] = round1(meter.baselineDb)

        var rows: [[String: Any]] = []
        var errors: [String] = []
        for reply in replies {
            drained = false
            meter.playbackStarted(id: reply.id, lang: reply.lang)
            var offset = 0
            while offset < reply.pcm16.count {
                let end = min(reply.pcm16.count, offset + downlinkChunkSamples * 2)
                engine.enqueue(pcm16: reply.pcm16.subdata(in: offset..<end), itemId: reply.id)
                offset = end
            }
            let started = DispatchTime.now().uptimeNanoseconds
            while !drained && !interrupted {
                if VoiceS5SimConversation.milliseconds(from: started, to: DispatchTime.now().uptimeNanoseconds) > drainLimitMs {
                    errors.append("\(reply.id): drain timeout")
                    engine.stopRealtimePlayback()
                    meter.playbackEnded()
                    break
                }
                try? await Task.sleep(nanoseconds: pollNanoseconds)
            }
            if interrupted {
                errors.append("\(reply.id): interrupted")
                break
            }
            try? await Task.sleep(nanoseconds: tailNanoseconds)
            rows = meter.segmentRows()
            VoiceS5SimConversation.write(
                name: output, header.merging(["phase": "running", "segments": rows]) { $1 }
            )
        }
        rows = meter.segmentRows()
        let totals = meter.totals()
        header["segments"] = rows
        header["totals"] = totals
        header["sileroErrors"] = meter.sileroErrors
        if !errors.isEmpty { header["errors"] = errors }
        header["phase"] = interrupted || meter.sileroErrors > 0 ? "error" : "done"
        if interrupted {
            header["error"] = "audio interrupted"
        } else if meter.sileroErrors > 0 {
            header["error"] = "silero feed failed on \(meter.sileroErrors) frames"
        }
        VoiceS5SimConversation.write(
            name: "realtime-echo-ios-\(source)-\(volume).trace.json",
            meter.trace().merging(["source": source, "volumePct": volume, "runId": runId]) { $1 }
        )
        VoiceS5SimConversation.write(name: output, header)
        let summary = "realtime-echo platform=ios source=\(source) volumePct=\(volume) route=\(route.rawValue)"
            + " aec=\(aec) baselineDb=\(round1(meter.baselineDb))"
            + " segments=\(totals["segments"] ?? 0) misreleased=\(totals["misreleased"] ?? 0)"
            + " vadEnergySegments=\(totals["vadEnergySegments"] ?? 0) vadSileroSegments=\(totals["vadSileroSegments"] ?? 0)"
            + " device=\(device) os=\(os)"
        logger.notice("\(summary, privacy: .public)")
        print(summary)
    }

    // MARK: Corpus

    /// manifest replies[] in corpus order; each 16 kHz wav segment is converted to 24 kHz PCM16 LE downlink.
    private static func loadReplies(directory: URL) throws -> [Reply] {
        let data = try Data(contentsOf: directory.appendingPathComponent("manifest.json"))
        guard let manifest = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.coderReadCorrupt)
        }
        let entries = (manifest["replies"] as? [[String: Any]]) ?? []
        let replies: [Reply] = try entries.compactMap { entry in
            guard let id = entry["id"] as? String, let lang = entry["lang"] as? String,
                  let file = entry["file"] as? String else { return nil }
            let clip = try AudioClip(url: directory.appendingPathComponent(file)).resampled(to: RealtimePCM.sampleRate)
            guard clip.sampleRate == RealtimePCM.sampleRate else {
                throw CocoaError(.fileReadCorruptFile, userInfo: [NSDebugDescriptionErrorKey: "resample \(file)"])
            }
            return Reply(id: id, lang: lang, pcm16: RealtimePCM.encodePCM16LE(clip.samples))
        }
        guard !replies.isEmpty else {
            throw CocoaError(.coderValueNotFound, userInfo: [NSDebugDescriptionErrorKey: "replies"])
        }
        return replies
    }

    // MARK: Volume and device

    /// Sets the system volume via the MPVolumeView slider; returns the actual outputVolume after setting (percent, recorded as outputVolumePct). If it cannot be set (simulator or system refuses), returns the actual value as-is.
    private static func setVolume(_ pct: Int) async -> Int {
        let view = MPVolumeView(frame: CGRect(x: -1000, y: -1000, width: 100, height: 40))
        let window = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.windows.first }
            .first
        window?.addSubview(view)
        defer { view.removeFromSuperview() }
        if let slider = view.subviews.compactMap({ $0 as? UISlider }).first {
            slider.value = Float(pct) / 100
            slider.sendActions(for: .valueChanged)
        }
        try? await Task.sleep(nanoseconds: 500_000_000)
        return Int((AVAudioSession.sharedInstance().outputVolume * 100).rounded())
    }

    private static var deviceName: String {
        var info = utsname()
        uname(&info)
        let machine = withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        return "\(UIDevice.current.model) \(machine)"
    }

    static func round1(_ value: Double) -> Double { (value * 10).rounded() / 10 }
}

/// vpio group forwards to production EngineConversationVoiceProcessing; raw group base is nil: setEnabled is a no-op and always off.
private final class EchoVoiceProcessing: ConversationVoiceProcessing {
    var base: ConversationVoiceProcessing?
    var isEnabled: Bool { base?.isEnabled ?? false }
    func setEnabled(_ enabled: Bool) throws { try base?.setEnabled(enabled) }
}

/// Per-20 ms-frame gate and dual-VAD records and per-segment metrics (contract item 2). Used on the main actor only.
@MainActor
private final class EchoMeter {

    private struct Segment {
        let id: String
        let lang: String
        let pb: Int
        var pe: Int?
        var gateOpenSpeech = false
        var gateEnergyOpenSpeech = false
    }

    nonisolated static let frameSamples = Int(RealtimeEchoBench.uplinkSampleRate) * VoiceConversationLogic.Constants.frameMs / 1000
    private static let vadTailFrames = 40

    private let route: VoiceConversationLogic.Route
    /// Production gate (model mode, frames carry Silero prob) and the energy gate control (original F2 criteria), same frames same cycle.
    private var gate = RealtimeUplinkGate()
    private var gateEnergy = RealtimeUplinkGate()
    private var energyVad = VoiceConversationLogic.Vad()
    private var sileroVad = VoiceConversationLogic.Vad()
    private let silero: SileroVad
    private var pending: [Float] = []
    private var dbs: [Double] = []
    /// Prob fed to the production gate frame by frame (nil after an inference failure), written to trace for offline replay.
    private var probs: [Double?] = []
    /// Downlink reference dB fed to the production gate frame by frame (nil when nothing is playing), written to the trace as the third element.
    private var refs: [Double?] = []
    private var sileroFailed = false
    private var released: [Bool] = []
    private var energyStarts: [Int] = []
    private var sileroStarts: [Int] = []
    private var segments: [Segment] = []
    private(set) var baselineDb = ConversationAudioMath.silenceDb
    /// Number of frames with Silero inference errors; > 0 records phase=error for this group (vadSileroStarts is no longer valid, same as a load failure).
    private(set) var sileroErrors = 0

    /// Silero load failure is thrown directly: the group records phase=error and does not degrade to energy-only.
    init(route: VoiceConversationLogic.Route) throws {
        self.route = route
        silero = try SileroVad()
    }

    private var frame: Int { dbs.count }
    var frameCount: Int { dbs.count }

    /// Uplink PCM16 LE (16 kHz) variable-length chunks: frames are processed one at a time once 20 ms accumulates. refsBehind[j] = reference dB of the chunk where the playhead was j frames back when this chunk arrived;
    /// when this chunk yields m frames, frame k uses refsBehind[m − 1 − k] (same as production host).
    func consume(_ data: Data, refsBehind: [Double?]) {
        let count = data.count / 2
        guard count > 0 else { return }
        data.withUnsafeBytes { raw in
            for index in 0..<count {
                let value = Int16(bitPattern: UInt16(raw[index * 2]) | UInt16(raw[index * 2 + 1]) << 8)
                pending.append(Float(value) / 32_768)
            }
        }
        let completed = pending.count / Self.frameSamples
        for k in 0..<completed {
            let samples = Array(pending.prefix(Self.frameSamples))
            pending.removeFirst(Self.frameSamples)
            let back = completed - 1 - k
            step(samples, ref: refsBehind.indices.contains(back) ? refsBehind[back] : nil)
        }
    }

    private func step(_ samples: [Float], ref: Double?) {
        let index = frame
        let db = ConversationAudioMath.dbfs(samples)
        do {
            try samples.withUnsafeBufferPointer { try silero.feed($0) }
        } catch {
            sileroErrors += 1
            sileroFailed = true
        }
        let prob = Double(silero.latestProb)
        // Same as production host: on inference failure the gate prob is passed as nil and the gate switches to the energy Vad
        let gateProb: Double? = sileroFailed ? nil : prob
        dbs.append(db)
        probs.append(gateProb)
        refs.append(ref)
        released.append(false)
        if case .open(.speech, _) = gateEnergy.step(db: db), !segments.isEmpty {
            segments[segments.count - 1].gateEnergyOpenSpeech = true
        }
        switch gate.step(db: db, prob: gateProb, ref: ref) {
        case .send:
            released[index] = true
        case .hold:
            break
        case .open(let reason, let flushFrom):
            for flushed in max(0, flushFrom)...index { released[flushed] = true }
            if reason == .speech, !segments.isEmpty { segments[segments.count - 1].gateOpenSpeech = true }
        }
        let current = segments.last
        let speaker = route.isSpeaker
        for event in energyVad.step(
            frame: index, db: db, speaker: speaker, playbackStartFrame: current?.pb, playbackEndedFrame: current?.pe
        ) where Self.isStart(event) {
            energyStarts.append(index)
        }
        for event in sileroVad.step(
            frame: index, db: db, speaker: speaker, playbackStartFrame: current?.pb, playbackEndedFrame: current?.pe,
            prob: prob
        ) where Self.isStart(event) {
            sileroStarts.append(index)
        }
    }

    private static func isStart(_ event: VoiceConversationLogic.VadEvent) -> Bool {
        if case .speechStart = event { return true }
        return false
    }

    /// Baseline = median dB of the first frames frames after capture starts (nearest rank).
    func closeBaseline(frames: Int) {
        baselineDb = Self.percentile(Array(dbs.prefix(frames)), 0.5) ?? ConversationAudioMath.silenceDb
    }

    /// pb: before the first downlink chunk of the segment is enqueued. The gate opens a new cycle; both VADs use runVad resetFrame to drop in-flight utterances and keep the noise floor.
    func playbackStarted(id: String, lang: String) {
        segments.append(Segment(id: id, lang: lang, pb: frame))
        gate.playbackStarted(route: route)
        gateEnergy.playbackStarted(route: route)
        energyVad.reset()
        sileroVad.reset()
    }

    /// pe: downlink actually finished playing (onPlaybackDrained).
    func playbackEnded() {
        guard let last = segments.indices.last, segments[last].pe == nil else { return }
        segments[last].pe = frame
        gate.playbackEnded()
        gateEnergy.playbackEnded()
    }

    /// Per-frame trace (schema realtime-echo-trace/v1, read by scripts/realtime-echo-replay.mjs): frames [[db, prob|null, ref|null]], cycles [{id, pb, pe}].
    func trace() -> [String: Any] {
        [
            "schema": "realtime-echo-trace/v1",
            "frameMs": VoiceConversationLogic.Constants.frameMs,
            "frames": dbs.indices.map { index -> [Any] in
                [
                    RealtimeEchoBench.round1(dbs[index]),
                    probs[index].map { ($0 * 1000).rounded() / 1000 } ?? NSNull(),
                    refs[index].map { RealtimeEchoBench.round1($0) } ?? NSNull(),
                ]
            },
            "cycles": segments.map { segment -> [String: Any] in
                ["id": segment.id, "pb": segment.pb, "pe": segment.pe.map { $0 as Any } ?? NSNull()]
            },
        ]
    }

    func segmentRows() -> [[String: Any]] {
        segments.map { segment in
            let pe = segment.pe ?? frame
            let played = Array(dbs[min(segment.pb, dbs.count)..<min(pe, dbs.count)]).map { $0 - baselineDb }
            let vadEnd = pe + Self.vadTailFrames
            let releasedCount = released.indices.filter { $0 >= segment.pb && $0 <= pe && released[$0] }.count
            var row: [String: Any] = [
                "id": segment.id, "lang": segment.lang, "playFrames": pe - segment.pb,
                "vadEnergyStarts": energyStarts.filter { $0 >= segment.pb && $0 < vadEnd }.count,
                "vadSileroStarts": sileroStarts.filter { $0 >= segment.pb && $0 < vadEnd }.count,
                "gateOpenSpeech": segment.gateOpenSpeech,
                "gateEnergyOpenSpeech": segment.gateEnergyOpenSpeech,
                "releasedDuringPlayback": releasedCount,
            ]
            if played.isEmpty {
                row["residualDbMean"] = NSNull()
                row["residualDbP95"] = NSNull()
            } else {
                row["residualDbMean"] = RealtimeEchoBench.round1(played.reduce(0, +) / Double(played.count))
                row["residualDbP95"] = Self.percentile(played, 0.95).map(RealtimeEchoBench.round1) ?? NSNull()
            }
            if segment.pe == nil { row["drained"] = false }
            return row
        }
    }

    func totals() -> [String: Any] {
        let rows = segmentRows()
        return [
            "segments": rows.count,
            "misreleased": rows.filter { $0["gateOpenSpeech"] as? Bool == true }.count,
            "misreleasedEnergy": rows.filter { $0["gateEnergyOpenSpeech"] as? Bool == true }.count,
            "vadEnergySegments": rows.filter { ($0["vadEnergyStarts"] as? Int ?? 0) > 0 }.count,
            "vadSileroSegments": rows.filter { ($0["vadSileroStarts"] as? Int ?? 0) > 0 }.count,
        ]
    }

    /// Nearest-rank percentile sorted[ceil(p·n) − 1] (p = 0.5 is the median); nil when empty.
    private static func percentile(_ values: [Double], _ p: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let rank = Int((p * Double(sorted.count)).rounded(.up)) - 1
        return sorted[min(max(rank, 0), sorted.count - 1)]
    }
}
#endif
