import AVFoundation
import Foundation
import Testing
@testable import Oriveo

/// Compares each case in shared/voice-contracts/voice-conversation.v1.json against runVad / isEcho / zhNumberRun /
/// endsWithContinuation / joinAmend / reduce / displayState / statusKey / caption, and the state strings reachable from both pages.
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
            "vadMinUtteranceMs": K.vadMinUtteranceMs, "vadMaxUtteranceMs": K.vadMaxUtteranceMs,
            "vadPrerollMs": K.vadPrerollMs, "bargeInGraceMs": K.bargeInGraceMs,
            "bargeInMinSpeechMs": K.bargeInMinSpeechMs, "postPlaybackGuardMs": K.postPlaybackGuardMs,
            "postPlaybackGuardMinSpeechMs": K.postPlaybackGuardMinSpeechMs,
            "echoWindowMs": K.echoWindowMs, "echoMinWeight": K.echoMinWeight, "echoHanUnitWeight": K.echoHanUnitWeight,
            "echoOtherUnitWeight": K.echoOtherUnitWeight, "falseBargeInsPerConversation": K.falseBargeInsPerConversation,
            "conversationsToRemember": K.conversationsToRemember, "idleTimeoutMs": K.idleTimeoutMs,
            "thinkingEarconMs": K.thinkingEarconMs, "partialStallMs": K.partialStallMs, "replyAudioGateMs": K.replyAudioGateMs,
            "endpointMaxSilenceMs": K.endpointMaxSilenceMs, "endpointPartialSettleMs": K.endpointPartialSettleMs,
            "sayAgainMinVoicedMs": K.sayAgainMinVoicedMs, "checkLanguageMinVoicedMs": K.checkLanguageMinVoicedMs,
            "checkLanguageAfterMisses": K.checkLanguageAfterMisses, "listenToThinkTapGuardMs": K.listenToThinkTapGuardMs,
            "stopToVoiceGuardMs": K.stopToVoiceGuardMs, "sttRetries": K.sttRetries,
            "floorWindowMs": K.floorWindowMs, "floorSmoothMs": K.floorSmoothMs, "vadModelBgPercentile": K.vadModelBgPercentile,
            "vadModelOnsetBacktrackMs": K.vadModelOnsetBacktrackMs, "vadModelOnsetMinRunFrames": K.vadModelOnsetMinRunFrames,
            "captionBrightScalars": VoiceConversationBarContent.captionBrightScalars,
            "captionBrightWords": VoiceConversationBarContent.captionBrightWords,
        ]
        let doubles: [String: Double] = [
            "vadStartOverFloorDb": K.vadStartOverFloorDb, "vadContinueOverFloorDb": K.vadContinueOverFloorDb,
            "vadAbsoluteMinDb": K.vadAbsoluteMinDb, "vadContinueAbsMinDb": K.vadContinueAbsMinDb, "floorInitDb": K.floorInitDb, "floorAlpha": K.floorAlpha,
            "echoOverlapRatio": K.echoOverlapRatio,
            "vadModelStartProb": K.vadModelStartProb, "vadModelContinueProb": K.vadModelContinueProb,
            "vadModelGateOverFloorDb": K.vadModelGateOverFloorDb, "vadModelContinueOverFloorDb": K.vadModelContinueOverFloorDb,
            "vadModelStartOverBgDb": K.vadModelStartOverBgDb, "vadModelContinueOverBgDb": K.vadModelContinueOverBgDb,
            "vadModelFollowUpFloorOverBgDb": K.vadModelFollowUpFloorOverBgDb,
        ]
        let ranges: [String: ClosedRange<Double>] = ["floorClampDb": K.floorClampDb, "frameDbClampDb": K.frameDbClampDb]
        let lists: [String: [String]] = [
            "continuationPunctuation": K.continuationPunctuation, "continuationWords": K.continuationWords,
        ]
        #expect(Set(c.keys) == Set(ints.keys).union(doubles.keys).union(ranges.keys).union(lists.keys))
        for (key, value) in lists { #expect(c[key] as? [String] == value, "\(key)") }
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
        case .speechEnd(let frame, let voicedMs, let reason):
            return ["type": "speechEnd", "frame": frame, "voicedMs": voicedMs, "reason": reason.rawValue]
        case .discarded(let frame): return ["type": "discarded", "frame": frame]
        }
    }

    @Test("vad cases")
    func vad() throws {
        let cases = try Self.cases("vad")
        #expect(cases.count >= 36)
        for item in cases {
            let id = item["id"] as? String ?? "?"
            let input = try #require(item["input"] as? [String: Any])
            let runs = try #require(input["frames"] as? [[NSNumber]])
            // Frame segments are written as [dB, count] or [dB, count, prob]; a segment with prob means model mode
            var frames: [Double] = []
            var probs: [Double] = []
            for run in runs {
                frames += Array(repeating: run[0].doubleValue, count: run[1].intValue)
                if run.count > 2 { probs += Array(repeating: run[2].doubleValue, count: run[1].intValue) }
            }
            let opts = input["opts"] as? [String: Any] ?? [:]
            let route = Logic.Route(wire: opts["route"] as? String ?? "speaker")
            let frame = { (key: String) in (opts[key] as? NSNumber)?.intValue }
            let actual = Logic.runVad(
                frames: frames, probs: probs.isEmpty ? nil : probs, route: route, playbackStartFrame: frame("playbackStartFrame"),
                playbackEndedFrame: frame("playbackEndedFrame"), resetFrame: frame("resetFrame"),
                forceEndFrame: frame("forceEndFrame")
            ).map(Self.vadJSON)
            #expect(try Self.canonical(actual) == Self.canonical(item["expected"] as Any), "\(id)")
        }
    }

    // MARK: - Self-echo

    @Test("echo cases")
    func echo() throws {
        let cases = try Self.cases("echo")
        #expect(cases.count >= 35)
        for item in cases {
            let id = item["id"] as? String ?? "?"
            let input = try #require(item["input"] as? [String: Any])
            let expected = try #require(item["expected"] as? [String: Any])
            let result = Logic.isEcho(
                transcript: try #require(input["transcript"] as? String),
                pool: try #require(input["pool"] as? [String])
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

    // MARK: - Chinese numbers / continuation / amendment

    /// Output device → route. The fixture uses the Swift member names of AVAudioSession.Port; each is mapped to Port here
    @Test("output route cases (ios)")
    func outputRoute() throws {
        let ports: [String: AVAudioSession.Port] = [
            "builtInSpeaker": .builtInSpeaker, "builtInReceiver": .builtInReceiver, "headphones": .headphones,
            "carAudio": .carAudio, "airPlay": .airPlay, "HDMI": .HDMI, "lineOut": .lineOut, "usbAudio": .usbAudio,
            "bluetoothA2DP": .bluetoothA2DP, "bluetoothHFP": .bluetoothHFP, "bluetoothLE": .bluetoothLE,
            "displayPort": .displayPort,
        ]
        let cases = try Self.cases("outputRoute").filter { ($0["input"] as? [String: Any])?["platform"] as? String == "ios" }
        #expect(cases.count >= 10)
        for item in cases {
            let input = try #require(item["input"] as? [String: Any])
            let names = try #require(input["outputs"] as? [String])
            let outputs = try names.map { try #require(ports[$0], "unknown port \($0)") }
            let expected = try #require(item["expected"] as? String)
            #expect(VPIOConversationAudioEngine.route(ofOutputs: outputs).rawValue == expected, "\(item["id"] ?? "?")")
        }
    }

    @Test("numeral cases")
    func numerals() throws {
        let cases = try Self.cases("numerals")
        #expect(cases.count >= 11)
        for item in cases {
            let input = try #require(item["input"] as? [String: Any])
            let run = try #require(input["run"] as? String)
            #expect(Logic.zhNumberRun(run) == item["expected"] as? String, "\(item["id"] ?? "?")")
        }
    }

    @Test("continuation cases")
    func continuation() throws {
        let cases = try Self.cases("continuation")
        #expect(cases.count >= 16)
        for item in cases {
            let input = try #require(item["input"] as? [String: Any])
            let text = try #require(input["text"] as? String)
            #expect(Logic.endsWithContinuation(text) == item["expected"] as? Bool, "\(item["id"] ?? "?")")
        }
    }

    @Test("amend cases")
    func amend() throws {
        let cases = try Self.cases("amend")
        #expect(cases.count >= 8)
        for item in cases {
            let input = try #require(item["input"] as? [String: Any])
            let joined = Logic.joinAmend(
                try #require(input["previous"] as? String), try #require(input["text"] as? String)
            )
            #expect(joined == item["expected"] as? String, "\(item["id"] ?? "?")")
        }
    }

    // MARK: - Caption highlight

    @Test("captionHighlight matches the fixture")
    func captionHighlight() throws {
        let cases = try Self.cases("captionHighlight")
        #expect(cases.count >= 10)
        for item in cases {
            let input = try #require(item["input"] as? [String: Any])
            let expected = try #require(item["expected"] as? [String: String])
            let split = VoiceConversationBarContent.captionSegments(try #require(input["text"] as? String))
            let id = "\(item["id"] ?? "?")"
            #expect(split.dim == expected["dim"], "\(id) dim")
            #expect(split.bright == expected["bright"], "\(id) bright")
        }
    }

    // MARK: - Page-reachable state strings

    @Test("page reachable status keys match the fixture")
    func pageReachableStatusKeys() throws {
        let pages = try #require(try Self.fixture()["pageReachableStatusKeys"] as? [String: [String]])
        let expected: [String: VoiceConversationPage] = ["home": .home, "chat": .chat]
        #expect(Set(pages.keys) == Set(expected.keys))
        for (name, page) in expected {
            let keys = try #require(pages[name])
            #expect(Set(page.reachableStatusKeys.map(\.rawValue)) == Set(keys), "\(name)")
            #expect(keys.allSatisfy { Logic.StatusKey(rawValue: $0) != nil }, "\(name)")
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
        case "vadSpeechEnd":
            return .vadSpeechEnd(utteranceId: string("utteranceId"), voicedMs: (json["voicedMs"] as? NSNumber)?.intValue ?? 0)
        case "sttPartial": return .sttPartial(text: string("text"))
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
        case "promptStarted": return .promptStarted(text: string("text"))
        case "promptEnded": return .promptEnded
        case "end": return .end(reason: .init(endEvent: string("reason")))
        default: return nil  // Unknown event (the fixture's somethingNew counterexample): dropped on decode
        }
    }

    private static func effectJSON(_ effect: Logic.Effect) -> [String: Any] {
        switch effect {
        case .startCapture: return ["type": "startCapture"]
        case .pauseCapture: return ["type": "pauseCapture"]
        case .resumeCapture: return ["type": "resumeCapture"]
        case .setCaptureMuted(let muted): return ["type": "setCaptureMuted", "muted": muted]
        case .resetVad(let endedAt): return ["type": "resetVad", "playbackEndedAtMs": endedAt.map { $0 as Any } ?? NSNull()]
        case .transcribe(let id): return ["type": "transcribe", "utteranceId": id]
        case .transcribeToDraft: return ["type": "transcribeToDraft"]
        case .sendMessage(let text): return ["type": "sendMessage", "text": text]
        case .amendLastMessage(let text): return ["type": "amendLastMessage", "text": text]
        case .cancelGeneration: return ["type": "cancelGeneration"]
        case .pausePlayback: return ["type": "pausePlayback"]
        case .resumePlayback(let from): return ["type": "resumePlayback", "from": from.rawValue]
        case .stopPlayback: return ["type": "stopPlayback"]
        case .enqueueSpeech(let text): return ["type": "enqueueSpeech", "text": text]
        case .speakPrompt(let prompt): return ["type": "speakPrompt", "prompt": prompt.rawValue]
        case .earcon(let kind): return ["type": "earcon", "kind": kind.rawValue]
        case .haptic(let kind): return ["type": "haptic", "kind": kind.rawValue]
        case .nudgeOrb: return ["type": "nudgeOrb"]
        case .continueUtterance(let id): return ["type": "continueUtterance", "utteranceId": id]
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
        #expect(cases.count >= 106)
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
                    "caption": Logic.caption(state).map { $0 as Any } ?? NSNull(),
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
