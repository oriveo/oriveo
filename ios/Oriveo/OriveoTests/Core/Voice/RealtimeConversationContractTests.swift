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
        case "tapOrb": return .tapOrb
        case "playbackDrained": return .playbackDrained
        case "tick": return (json["ms"] as? NSNumber).map { .tick(ms: $0.intValue) }
        case "end": return .end
        case "systemInterruption": return .systemInterruption
        case "failed": return (json["code"] as? String).map { .failed(code: $0) }
        case "sessionExpired": return .sessionExpired
        case "planChanged": return .planChanged
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
        }
    }

    @Test("constants match the fixture")
    func constants() throws {
        let c = try #require(try Self.fixture()["constants"] as? [String: Any])
        typealias K = Logic.Constants
        let ints: [String: Int] = [
            "idleEndMs": K.idleEndMs, "thinkingEarconMs": K.thinkingEarconMs,
            "lateUserTranscriptMs": K.lateUserTranscriptMs, "muteSilenceMs": K.muteSilenceMs,
        ]
        #expect(Set(c.keys) == Set(ints.keys))
        for (key, value) in ints { #expect((c[key] as? NSNumber)?.intValue == value, "\(key)") }
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
}
