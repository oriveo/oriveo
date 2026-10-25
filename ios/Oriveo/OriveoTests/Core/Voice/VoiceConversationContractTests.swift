import Foundation
import Testing
@testable import Oriveo

/// Compares shared/voice-contracts/voice-conversation.v1.json case by case against runVad / isEcho / reduce / displayState.
@Suite("Voice conversation contract")
struct VoiceConversationContractTests {

    private typealias Logic = VoiceConversationLogic

    private static func fixture() throws -> [String: Any] {
        var cursor = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while cursor.path != "/" {
            let candidate = cursor.appendingPathComponent("shared/voice-contracts/voice-conversation.v1.json")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: candidate)) as? [String: Any])
            }
            cursor.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }

    private static func cases(_ group: String) throws -> [[String: Any]] {
        try #require(try fixture()[group] as? [[String: Any]])
    }

    /// Key-sorted JSON text, so both sides are compared the same way.
    private static func canonical(_ value: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed])
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Constants

    @Test("constants match the fixture")
    func constants() throws {
        let c = try #require(try Self.fixture()["constants"] as? [String: Any])
        typealias K = Logic.Constants
        let ints: [String: Int] = [
            "frameMs": K.frameMs, "vadStartMs": K.vadStartMs, "vadEndSilenceMs": K.vadEndSilenceMs,
            "vadMinUtteranceMs": K.vadMinUtteranceMs, "vadPrerollMs": K.vadPrerollMs, "bargeInGraceMs": K.bargeInGraceMs,
            "bargeInMinSpeechMs": K.bargeInMinSpeechMs, "falseBargeInsPerConversation": K.falseBargeInsPerConversation,
            "conversationsToRemember": K.conversationsToRemember, "idleTimeoutMs": K.idleTimeoutMs,
            "thinkingEarconMs": K.thinkingEarconMs, "listenToThinkTapGuardMs": K.listenToThinkTapGuardMs,
            "stopToVoiceGuardMs": K.stopToVoiceGuardMs, "sttRetries": K.sttRetries,
        ]
        let doubles: [String: Double] = [
            "vadStartOverFloorDb": K.vadStartOverFloorDb, "vadContinueOverFloorDb": K.vadContinueOverFloorDb,
            "vadAbsoluteMinDb": K.vadAbsoluteMinDb, "floorInitDb": K.floorInitDb, "floorAlpha": K.floorAlpha,
            "echoOverlapRatio": K.echoOverlapRatio,
        ]
        let ranges: [String: ClosedRange<Double>] = ["floorClampDb": K.floorClampDb, "frameDbClampDb": K.frameDbClampDb]
        #expect(Set(c.keys) == Set(ints.keys).union(doubles.keys).union(ranges.keys))
        for (key, value) in ints { #expect((c[key] as? NSNumber)?.intValue == value, "\(key)") }
        for (key, value) in doubles { #expect((c[key] as? NSNumber)?.doubleValue == value, "\(key)") }
        for (key, value) in ranges {
            let pair = try #require(c[key] as? [NSNumber])
            #expect(pair.map(\.doubleValue) == [value.lowerBound, value.upperBound], "\(key)")
        }
    }

    // MARK: - VAD

    private static func vadJSON(_ event: Logic.VadEvent) -> [String: Any] {
        switch event {
        case .speechStart(let frame, let preroll): return ["type": "speechStart", "frame": frame, "prerollFrame": preroll]
        case .speechEnd(let frame, let voicedMs): return ["type": "speechEnd", "frame": frame, "voicedMs": voicedMs]
        case .discarded(let frame): return ["type": "discarded", "frame": frame]
        }
    }

    @Test("vad cases")
    func vad() throws {
        let cases = try Self.cases("vad")
        #expect(cases.count >= 25)
        for item in cases {
            let id = item["id"] as? String ?? "?"
            let input = try #require(item["input"] as? [String: Any])
            let runs = try #require(input["frames"] as? [[NSNumber]])
            var frames: [Double] = []
            for run in runs { frames += Array(repeating: run[0].doubleValue, count: run[1].intValue) }
            let opts = input["opts"] as? [String: Any] ?? [:]
            let route = Logic.Route(wire: opts["route"] as? String ?? "speaker")
            let start = (opts["playbackStartFrame"] as? NSNumber)?.intValue
            let actual = Logic.runVad(frames: frames, route: route, playbackStartFrame: start).map(Self.vadJSON)
            #expect(try Self.canonical(actual) == Self.canonical(item["expected"] as Any), "\(id)")
        }
    }

    // MARK: - Self-echo

    @Test("echo cases")
    func echo() throws {
        let cases = try Self.cases("echo")
        #expect(cases.count >= 22)
        for item in cases {
            let id = item["id"] as? String ?? "?"
            let input = try #require(item["input"] as? [String: Any])
            let expected = try #require(item["expected"] as? [String: Any])
            let result = Logic.isEcho(
                transcript: try #require(input["transcript"] as? String),
                sentences: try #require(input["sentences"] as? [String])
            )
            #expect(result.echo == (expected["echo"] as? Bool), "\(id)")
            if let overlap = expected["overlap"] as? NSNumber {
                let actual = try #require(result.overlap, "\(id)")
                #expect(abs(actual - overlap.doubleValue) <= 0.00005, "\(id) \(actual)")
            } else {
                #expect(result.overlap == nil, "\(id)")
            }
        }
    }

    // MARK: - State machine

    private static func event(_ json: [String: Any]) -> Logic.Event? {
        let string = { (key: String) in json[key] as? String ?? "" }
        switch json["type"] as? String {
        case "start":
            return .start(route: .init(wire: string("route")),
                          deviceRemembersNoSpeakerBargeIn: json["deviceRemembersNoSpeakerBargeIn"] as? Bool ?? false)
        case "vadSpeechStart": return .vadSpeechStart
        case "vadSpeechEnd": return .vadSpeechEnd(utteranceId: string("utteranceId"))
        case "vadDiscarded": return .vadDiscarded
        case "bargeInDetected": return .bargeInDetected
        case "sttResult": return .sttResult(utteranceId: string("utteranceId"), text: string("text"))
        case "sttFailed": return .sttFailed(utteranceId: string("utteranceId"))
        case "replySentence": return .replySentence(text: string("text"))
        case "sentenceStarted": return .sentenceStarted(text: string("text"))
        case "replyCompleted": return .replyCompleted
        case "playbackDrained": return .playbackDrained
        case "replyFailed": return .replyFailed(code: string("code"))
        case "approvalPending": return .approvalPending
        case "approvalResolved": return .approvalResolved
        case "tapOrb": return .tapOrb
        case "toggleMute": return .toggleMute
        case "deadline": return .deadline
        case "interruptionBegan": return .interruptionBegan
        case "interruptionEnded": return .interruptionEnded
        case "screenReaderSpeaking": return .screenReaderSpeaking(json["speaking"] as? Bool ?? false)
        case "routeChanged": return .routeChanged(route: .init(wire: string("route")))
        case "playMessage": return .playMessage(messageId: string("messageId"))
        case "messagePlaybackEnded": return .messagePlaybackEnded
        case "end": return .end(reason: .init(endEvent: string("reason")))
        default: return nil
        }
    }

    private static func effectJSON(_ effect: Logic.Effect) -> [String: Any] {
        switch effect {
        case .startCapture: return ["type": "startCapture"]
        case .pauseCapture: return ["type": "pauseCapture"]
        case .resumeCapture: return ["type": "resumeCapture"]
        case .setCaptureMuted(let muted): return ["type": "setCaptureMuted", "muted": muted]
        case .transcribe(let id): return ["type": "transcribe", "utteranceId": id]
        case .transcribeToDraft: return ["type": "transcribeToDraft"]
        case .sendMessage(let text): return ["type": "sendMessage", "text": text]
        case .cancelGeneration: return ["type": "cancelGeneration"]
        case .pausePlayback: return ["type": "pausePlayback"]
        case .resumePlayback(let from): return ["type": "resumePlayback", "from": from.rawValue]
        case .stopPlayback: return ["type": "stopPlayback"]
        case .enqueueSpeech(let text): return ["type": "enqueueSpeech", "text": text]
        case .speakPrompt(let prompt): return ["type": "speakPrompt", "prompt": prompt.rawValue]
        case .earcon(let kind): return ["type": "earcon", "kind": kind.rawValue]
        case .forceEndUtterance: return ["type": "forceEndUtterance"]
        case .rememberFalseBargeInConversation: return ["type": "rememberFalseBargeInConversation"]
        case .playMessage(let id): return ["type": "playMessage", "messageId": id]
        case .endConversation(let reason, let code):
            var json: [String: Any] = ["type": "endConversation", "reason": reason.rawValue]
            if let code { json["code"] = code }
            return json
        }
    }

    @Test("reduce cases")
    func reduce() throws {
        let cases = try Self.cases("reduce")
        #expect(cases.count >= 58)
        for item in cases {
            let id = item["id"] as? String ?? "?"
            let input = try #require(item["input"] as? [String: Any])
            let events = try #require(input["events"] as? [[String: Any]])
            let expected = try #require(item["expected"] as? [[String: Any]])
            #expect(events.count == expected.count, "\(id)")
            var state = Logic.initialState()
            for (index, json) in events.enumerated() where index < expected.count {
                var effects: [Logic.Effect] = []
                if let event = Self.event(json) {
                    (state, effects) = Logic.reduce(state, event, atMs: (json["atMs"] as? NSNumber)?.intValue ?? 0)
                }
                let step = expected[index]
                let actual: [String: Any] = [
                    "displayState": Logic.displayState(state)?.rawValue ?? NSNull(),
                    "statusKey": Logic.statusKey(state)?.rawValue ?? NSNull(),
                    "effects": effects.map(Self.effectJSON),
                    "nextDeadlineMs": Logic.nextDeadlineMs(state).map { $0 as Any } ?? NSNull(),
                ]
                #expect(try Self.canonical(actual) == Self.canonical(step), "\(id) #\(index)")
            }
        }
    }

    @Test("reduce never mutates its input")
    func reducePure() {
        let start = Logic.initialState()
        let (listening, _) = Logic.reduce(start, .start(route: .speaker, deviceRemembersNoSpeakerBargeIn: false), atMs: 0)
        #expect(start == Logic.initialState())
        let copy = listening
        _ = Logic.reduce(listening, .vadSpeechStart, atMs: 10)
        #expect(listening == copy)
    }
}
