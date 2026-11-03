import Foundation
import Testing
@testable import Oriveo

/// Compares reduce / statusKey step by step against every case in shared/voice-contracts/realtime-conversation.v1.json.
@Suite("Realtime conversation contract")
struct RealtimeConversationContractTests {

    private typealias Logic = RealtimeConversationLogic

    private static func fixture() throws -> [String: Any] {
        var cursor = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while cursor.path != "/" {
            let candidate = cursor.appendingPathComponent("shared/voice-contracts/realtime-conversation.v1.json")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: candidate)) as? [String: Any])
            }
            cursor.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }

    /// JSON text with sorted keys, so both sides compare on the same basis.
    private static func canonical(_ value: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed])
        return String(decoding: data, as: UTF8.self)
    }

    /// Fixture input → closed-set input; an unknown type returns nil (the reducer never sees it, state and effects stay unchanged).
    /// When assistantTurnDone's text is null it is fed in as the unified event's empty string (the reducer falls back to the latest transcript when the trimmed text is empty).
    private static func input(_ json: [String: Any]) -> Logic.Input? {
        switch json["type"] as? String {
        case "mute": return .mute
        case "unmute": return .unmute
        case "wake": return .wake
        case "tapOrb": return .tapOrb
        case "playbackDrained": return .playbackDrained
        case "playbackProgress":
            // The host sends played ms floored after the player has played; itemId null stays nil
            return (json["playedMs"] as? NSNumber).map {
                .playbackProgress(itemId: json["itemId"] as? String, playedMs: Int($0.doubleValue.rounded(.down)))
            }
        case "tick": return (json["ms"] as? NSNumber).map { .tick(ms: $0.intValue) }
        case "end": return .end
        case "systemInterruption": return .systemInterruption
        case "failed": return (json["code"] as? String).map { .failed(code: $0) }
        case "sessionExpired": return .sessionExpired
        case "planChanged": return .planChanged
        case "gateOpened": return .gateOpened
        case "screenReaderSpeaking": return (json["speaking"] as? Bool).map { .screenReaderSpeaking($0) }
        case "assistantTurnDone" where json["text"] is NSNull:
            var patched = json
            patched["text"] = ""
            return RealtimeSessionEvent(json: patched).map { .event($0) }
        default: return RealtimeSessionEvent(json: json).map { .event($0) }
        }
    }

    private static func effectJSON(_ effect: Logic.Effect) -> [String: Any] {
        switch effect {
        case let .persist(role, text): ["type": "persist", "role": role.rawValue, "text": text]
        case .interruptPlayback: ["type": "interruptPlayback"]
        case let .sendSilence(ms): ["type": "sendSilence", "ms": ms]
        case let .setUplink(on): ["type": "setUplink", "on": on]
        case .earcon: ["type": "earcon"]
        case let .showError(code): ["type": "showError", "code": code]
        case let .writeDraft(text): ["type": "writeDraft", "text": text]
        case .close: ["type": "close"]
        case let .ended(reason): ["type": "ended", "reason": reason.rawValue]
        case .reopen: ["type": "reopen"]
        case .disableBargeIn: ["type": "disableBargeIn"]
        }
    }

    @Test("constants match the fixture")
    func constants() throws {
        let c = try #require(try Self.fixture()["constants"] as? [String: Any])
        typealias K = Logic.Constants
        let ints: [String: Int] = [
            "idleEndMs": K.idleEndMs, "thinkingEarconMs": K.thinkingEarconMs,
            "lateUserTranscriptMs": K.lateUserTranscriptMs, "muteSilenceMs": K.muteSilenceMs,
            "falseBargeInsPerSession": K.falseBargeInsPerSession,
        ]
        // F2c: echo reference decision constant lives inside the uplink gate
        typealias G = RealtimeUplinkGate
        let doubles: [String: Double] = [
            "echoRefWindowMs": Double(G.echoRefWindowMs), "echoRefDelayWindowMs": Double(G.echoRefDelayWindowMs),
            "echoRefMaxDelayMs": Double(G.echoRefMaxDelayMs), "echoRefMinCorrelation": G.echoRefMinCorrelation,
            "echoRefMinDelayCorrelation": G.echoRefMinDelayCorrelation,
            "echoRefBargeInMarginDb": G.echoRefBargeInMarginDb, "echoRefFloorDb": G.echoRefFloorDb,
        ]
        #expect(Set(c.keys) == Set(ints.keys).union(doubles.keys))
        for (key, value) in ints { #expect((c[key] as? NSNumber)?.intValue == value, "\(key)") }
        for (key, value) in doubles { #expect((c[key] as? NSNumber)?.doubleValue == value, "\(key)") }
    }

    @Test("realtime conversation cases match the fixture")
    func realtimeConversationCasesMatchFixture() throws {
        let cases = try #require(try Self.fixture()["cases"] as? [[String: Any]])
        #expect(cases.count >= 30)
        for item in cases {
            let id = item["id"] as? String ?? "?"
            let steps = try #require(item["steps"] as? [[String: Any]], "\(id)")
            var state = Logic.initialState
            for (index, step) in steps.enumerated() {
                let rawInput = try #require(step["input"] as? [String: Any], "\(id)#\(index)")
                let expected = try #require(step["expected"] as? [String: Any], "\(id)#\(index)")
                var effects: [Logic.Effect] = []
                if let input = Self.input(rawInput) {
                    (state, effects) = Logic.reduce(state, input)
                }
                let expectedKey = expected["statusKey"] as? String
                #expect(Logic.statusKey(state) == expectedKey, "\(id)#\(index) statusKey")
                let actual = try Self.canonical(effects.map(Self.effectJSON))
                #expect(actual == (try Self.canonical(expected["effects"] as Any)), "\(id)#\(index) effects")
                let expectedNext = (expected["nextTickMs"] as? NSNumber)?.intValue
                #expect(expected["nextTickMs"] != nil, "\(id)#\(index) nextTickMs present")
                #expect(Logic.nextTickMs(state) == expectedNext, "\(id)#\(index) nextTickMs")
            }
        }
    }

    /// displayCases compares the "your speech" bubble and reply bubble display text case by case.
    @Test("display cases match the fixture")
    func displayCasesMatchFixture() throws {
        let cases = try #require(try Self.fixture()["displayCases"] as? [[String: Any]])
        #expect(cases.count >= 5)
        for item in cases {
            let id = item["id"] as? String ?? "?"
            let steps = try #require(item["steps"] as? [[String: Any]], "\(id)")
            var state = Logic.initialState
            for (index, step) in steps.enumerated() {
                let rawInput = try #require(step["input"] as? [String: Any], "\(id)#\(index)")
                let expected = try #require(step["expected"] as? [String: Any], "\(id)#\(index)")
                if let input = Self.input(rawInput) { (state, _) = Logic.reduce(state, input) }
                #expect(Logic.userCaption(state) == expected["userCaption"] as? String, "\(id)#\(index) userCaption")
                #expect(Logic.assistantShown(state) == expected["assistantShown"] as? String, "\(id)#\(index) assistantShown")
                #expect(expected["stageLine"] != nil, "\(id)#\(index) stageLine present")
                #expect(Logic.stageLine(state) == Self.stageLine(expected["stageLine"]), "\(id)#\(index) stageLine")
            }
        }
    }

    /// Fixture stageLine: null → nil; {kind user|assistant, text} / {kind status, statusKey}.
    private static func stageLine(_ raw: Any?) -> Logic.StageLine? {
        guard let line = raw as? [String: Any], let kind = line["kind"] as? String else { return nil }
        switch kind {
        case "user": return (line["text"] as? String).map { .user($0) }
        case "assistant": return (line["text"] as? String).map { .assistant($0) }
        case "status": return (line["statusKey"] as? String).map { .status(key: $0) }
        default: return nil
        }
    }

    /// revealCases compares case by case the prefix revealed by the played ratio.
    @Test("reveal cases match the fixture")
    func revealCasesMatchFixture() throws {
        let cases = try #require(try Self.fixture()["revealCases"] as? [[String: Any]])
        #expect(cases.count >= 10)
        for item in cases {
            let id = item["id"] as? String ?? "?"
            let input = try #require(item["input"] as? [String: Any], "\(id)")
            let text = try #require(input["text"] as? String, "\(id)")
            let played = try #require(input["playedMs"] as? NSNumber, "\(id)").doubleValue
            let samples = try #require(input["audioSamples"] as? NSNumber, "\(id)").intValue
            let rate = try #require(input["sampleRateHz"] as? NSNumber, "\(id)").intValue
            let actual = Logic.revealPrefix(text: text, playedMs: Int(played.rounded(.down)), audioSamples: samples, sampleRateHz: rate)
            #expect(actual == item["expected"] as? String, "\(id)")
        }
    }

    /// uplinkGateCases per case. frames ([[db, n]] or [[db, n, prob]] expanded) are fed frame by frame into the streaming gate; playbackStarted / playbackEnded are called before the step at that frame;
    /// the per-frame output of the gate is restored to {openAtFrame, openReason, flushFromFrame, dropped}: dropped = held frames not re-emitted (head and tail).
    @Test("uplink gate cases match the fixture")
    func uplinkGateCasesMatchFixture() throws {
        let cases = try #require(try Self.fixture()["uplinkGateCases"] as? [[String: Any]])
        #expect(cases.count >= 15)
        for item in cases {
            let id = item["id"] as? String ?? "?"
            let input = try #require(item["input"] as? [String: Any], "\(id)")
            // F2b: a frame segment may be [db, n, prob]; prob null means the segment carries no probability (model inference failed)
            // F2c: may further carry a fourth ref element (downlink reference dB); null = not playing
            let runs = try #require(input["frames"] as? [[Any]], "\(id)")
            let frames = try runs.flatMap { run -> [(db: Double, prob: Double?, ref: Double?)] in
                let db = try #require(run[0] as? NSNumber, "\(id) db").doubleValue
                let count = try #require(run[1] as? NSNumber, "\(id) n").intValue
                let prob = run.count > 2 ? (run[2] as? NSNumber)?.doubleValue : nil
                let ref = run.count > 3 ? (run[3] as? NSNumber)?.doubleValue : nil
                return Array(repeating: (db, prob, ref), count: count)
            }
            let opts = input["opts"] as? [String: Any] ?? [:]
            let route = VoiceConversationLogic.Route(wire: opts["route"] as? String ?? "speaker")
            let start = (opts["playbackStartFrame"] as? NSNumber)?.intValue
            let end = (opts["playbackEndedFrame"] as? NSNumber)?.intValue
            var gate = RealtimeUplinkGate()
            if opts["bargeIn"] as? Bool == false { gate.setBargeIn(false) }
            var held: [Int] = []
            var openAt: Int?
            var reason: String?
            var flushFrom: Int?
            for (index, frame) in frames.enumerated() {
                if index == start { gate.playbackStarted(route: route) }
                if index == end { gate.playbackEnded() }
                switch gate.step(db: frame.db, prob: frame.prob, ref: frame.ref) {
                case .send:
                    break
                case .hold:
                    held.append(index)
                case let .open(openReason, from):
                    // Only one playback cycle in this case: release can only happen once
                    #expect(openAt == nil, "\(id) opened twice")
                    openAt = index
                    reason = openReason.rawValue
                    flushFrom = from
                }
            }
            if let openAt, let flushFrom {
                    // Re-emitted [flushFrom, openAt) must all be frames held earlier
                #expect(held.filter { $0 >= flushFrom } == Array(flushFrom..<openAt), "\(id) flushed frames")
            }
            let dropped = held.filter { frame in flushFrom.map { frame < $0 } ?? true }
            if let first = dropped.first, let last = dropped.last {
                #expect(dropped == Array(first...last), "\(id) dropped contiguous")
            }
            let actual: [String: Any] = [
                "openAtFrame": openAt.map { $0 as Any } ?? NSNull(),
                "openReason": reason.map { $0 as Any } ?? NSNull(),
                "flushFromFrame": flushFrom.map { $0 as Any } ?? NSNull(),
                "dropped": dropped.first.map { [$0, dropped.last ?? $0] as Any } ?? NSNull(),
            ]
            let expected = try #require(item["expected"] as? [String: Any], "\(id)")
            #expect(try Self.canonical(actual) == (try Self.canonical(expected)), "\(id)")
        }
    }

    /// Cycle stats for the gate log are read-only and do not participate in decisions; during holding, count frames, record the first voiced frame and the frames cleared by the echo reference; reset on cycle change.
    @Test("uplink gate cycle stats record held, voiced and echo-masked frames")
    func uplinkGateCycleStats() {
        var gate = RealtimeUplinkGate()
        for _ in 0..<10 { _ = gate.step(db: -60, prob: 0.01, ref: nil) }
        gate.playbackStarted(route: .speaker)
        #expect(gate.cycle == RealtimeUplinkGate.CycleStats(startFrame: 10))
        #expect(gate.holdReason == "noVoice")
        for _ in 0..<5 { #expect(gate.step(db: -62, prob: 0.02, ref: nil) == .hold) }
        // High-probability frames in the grace period: counted as voiced, but Vad does not start an utterance
        #expect(gate.step(db: -30, prob: 0.9, ref: nil) == .hold)
        #expect(gate.cycle.heldFrames == 6)
        #expect(gate.cycle.voicedFrames == 1)
        #expect(gate.cycle.firstVoicedFrame == 15)
        #expect(gate.cycle.echoMaskedFrames == 0)
        #expect(gate.cycle.maxProb == 0.9)
        #expect(gate.cycle.maxDb == -30)
        #expect(gate.cycle.longestVoicedRun == 1)
        #expect(gate.cycle.longestVadRun == 0)
        #expect(gate.holdReason == "vadRejected")
        gate.setBargeIn(false)
        #expect(gate.holdReason == "bargeInOff")
        gate.playbackStarted(route: .speaker)
        #expect(gate.cycle == RealtimeUplinkGate.CycleStats(startFrame: 16))
    }
}
