import Foundation
import Testing
@testable import Oriveo

/// Production gemini_live wire pure functions and event mapping, checked against shared/voice-contracts/realtime-events.v1.json.
@Suite("GeminiLiveWire")
struct GeminiLiveWireTests {

    private static func fixture() throws -> [String: Any] {
        var cursor = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while cursor.path != "/" {
            let candidate = cursor.appendingPathComponent("shared/voice-contracts/realtime-events.v1.json")
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

    /// Cases in a fixture group with transport == gemini_live.
    private static func geminiCases(_ group: String) throws -> [[String: Any]] {
        let all = try #require(try fixture()[group] as? [[String: Any]])
        return all.filter { (($0["input"] as? [String: Any])?["transport"] as? String) == "gemini_live" }
    }

    @Test func gemini_map_cases_match_fixture() throws {
        let cases = try Self.geminiCases("mapCases")
        #expect(cases.count == 11)
        for item in cases {
            let id = item["id"] as? String ?? "?"
            let input = try #require(item["input"] as? [String: Any], "\(id)")
            let messages = try #require(input["messages"] as? [[String: Any]], "\(id)")
            var mapper = GeminiLiveEventMapper()
            let events = messages.flatMap { mapper.map($0) }
            #expect(try Self.canonical(events.map(\.jsonObject)) == Self.canonical(item["expected"] as Any), "\(id)")
        }
    }

    /// Picks one fixture case from mapCases by id, feeds each message to the new mapper, and returns the actual event JSON shape with the expected value.
    private static func replayMapCase(_ id: String) throws -> (actual: [[String: Any]], expected: Any) {
        let all = try #require(try fixture()["mapCases"] as? [[String: Any]])
        let item = try #require(all.first { ($0["id"] as? String) == id }, "\(id)")
        let input = try #require(item["input"] as? [String: Any], "\(id)")
        let messages = try #require(input["messages"] as? [[String: Any]], "\(id)")
        var mapper = GeminiLiveEventMapper()
        let events = messages.flatMap { mapper.map($0) }
        return (events.map(\.jsonObject), item["expected"] as Any)
    }

    private static func userTranscripts(_ events: [[String: Any]]) -> [[String: Any]] {
        events.filter { ($0["type"] as? String) == "userTranscript" }
    }

    @Test func duplicate_input_transcription_after_final_dropped() throws {
        // A same-sentence transcription arriving after the turn is final, with no ACTIVITY_START (including one arriving after turnComplete), is dropped: exactly one final and no non-final tail.
        for id in ["gemini_duplicate_input_transcription_after_final_dropped", "gemini_duplicate_input_after_turn_complete_dropped"] {
            let (actual, expected) = try Self.replayMapCase(id)
            #expect(try Self.canonical(actual) == Self.canonical(expected), "\(id)")
            let users = Self.userTranscripts(actual)
            #expect(users.filter { ($0["final"] as? Bool) == true }.count == 1, "\(id)")
            #expect((users.last?["final"] as? Bool) == true, "\(id)")
        }
        // Prefix trimmed, then new text arrives: the held segment moves to the next turn together with this chunk.
        let (actual, expected) = try Self.replayMapCase("gemini_duplicate_prefix_then_new_text_kept_whole")
        #expect(try Self.canonical(actual) == Self.canonical(expected))
        let lastFinal = Self.userTranscripts(actual).last { ($0["final"] as? Bool) == true }
        #expect((lastFinal?["text"] as? String) == "\u{4ECA}\u{5929}\u{660E}\u{5929}\u{5462}?")
    }

    @Test func same_text_after_activity_start_kept() throws {
        // A same-sentence transcription after ACTIVITY_START is kept as the next turn.
        let (actual, expected) = try Self.replayMapCase("gemini_same_text_after_activity_start_kept")
        #expect(try Self.canonical(actual) == Self.canonical(expected))
        #expect(Self.userTranscripts(actual).filter { ($0["final"] as? Bool) == true }.count == 2)
    }

    @Test func gemini_open_cases_match_fixture() throws {
        let cases = try Self.geminiCases("openCases")
        #expect(cases.count == 6)
        for item in cases {
            let id = item["id"] as? String ?? "?"
            let input = try #require(item["input"] as? [String: Any], "\(id)")
            let plan = try #require(input["plan"] as? [String: Any], "\(id)")
            let entry = try #require(input["entry"] as? [String: Any], "\(id)")
            let history = try #require(plan["history"] as? [[String: String]], "\(id)").map {
                GeminiLiveHistoryTurn(role: $0["role"] ?? "", text: $0["text"] ?? "")
            }
            let opening = GeminiLiveWire.openingMessages(
                instructions: try #require(plan["instructions"] as? String),
                history: history,
                model: try #require(entry["model"] as? String),
                voice: try #require(input["voice"] as? String),
                resumeHandle: input["resumeHandle"] as? String,
                route: VoiceConversationLogic.Route(wire: try #require(input["route"] as? String, "\(id)")),
                language: input["language"] as? String
            )
            let actual: [String: Any] = ["beforeReady": opening.beforeReady, "afterReady": opening.afterReady]
            #expect(try Self.canonical(actual) == Self.canonical(item["expected"] as Any), "\(id)")
        }
    }

    @Test func gemini_url_case_matches_fixture() throws {
        let cases = try Self.geminiCases("urlCases")
        #expect(cases.count == 1)
        for item in cases {
            let input = try #require(item["input"] as? [String: Any])
            let entry = try #require(input["entry"] as? [String: Any])
            let url = GeminiLiveWire.connectURL(
                host: try #require(input["host"] as? String),
                path: try #require(entry["path"] as? String)
            )
            #expect(url == item["expected"] as? String)
        }
    }

    @Test func gemini_append_case_matches_fixture() throws {
        let cases = try Self.geminiCases("appendCases")
        #expect(cases.count == 1)
        for item in cases {
            let input = try #require(item["input"] as? [String: Any])
            let message = GeminiLiveWire.audioAppendMessage(base64: try #require(input["base64"] as? String))
            #expect(try Self.canonical(message) == Self.canonical(item["expected"] as Any))
        }
    }

    @Test func authenticated_url_appends_percent_encoded_key() {
        let url = GeminiLiveWire.authenticatedURL(host: "example.com", path: "/ws", key: "a+b/c=~")
        #expect(url == "wss://example.com/ws?key=a%2Bb%2Fc%3D~")
        let mixed = GeminiLiveWire.authenticatedURL(host: "example.com", path: "/ws", key: "a b%c\u{4E2D}é")
        #expect(mixed == "wss://example.com/ws?key=a%20b%25c%E4%B8%AD%C3%A9")
    }

    @Test func mid_turn_tracks_turn_boundary() {
        var mapper = GeminiLiveEventMapper()
        #expect(!mapper.midTurn)
        _ = mapper.map(["setupComplete": [String: Any]()])
        #expect(!mapper.midTurn)
        _ = mapper.map(["serverContent": ["outputTranscription": ["text": "Hi"]]])
        #expect(mapper.midTurn)
        _ = mapper.map(["serverContent": ["turnComplete": true]])
        #expect(!mapper.midTurn)
        _ = mapper.map(["serverContent": ["modelTurn": ["parts": [["inlineData": ["data": "AAAA"]]]]]])
        #expect(mapper.midTurn)
        _ = mapper.map(["serverContent": ["turnComplete": true]])
        #expect(!mapper.midTurn)
        _ = mapper.map(["serverContent": ["interrupted": true]])
        #expect(mapper.midTurn)
        _ = mapper.map(["serverContent": ["turnComplete": true]])
        #expect(!mapper.midTurn)
        _ = mapper.map(["serverContent": ["inputTranscription": ["text": "Late"]]])
        #expect(mapper.midTurn)
        _ = mapper.map(["goAway": ["timeLeft": "1s"]])
        #expect(mapper.midTurn)
        _ = mapper.map(["serverContent": ["turnComplete": true]])
        #expect(!mapper.midTurn)
        _ = mapper.map(["goAway": ["timeLeft": "1s"]])
        #expect(!mapper.midTurn)
        _ = mapper.map(["serverContent": ["outputTranscription": ["text": ""]]])
        #expect(!mapper.midTurn)
        _ = mapper.map(["serverContent": ["inputTranscription": ["text": ""]]])
        #expect(!mapper.midTurn)
        _ = mapper.map(["serverContent": ["modelTurn": ["parts": [["inlineData": ["data": ""]]]]]])
        #expect(!mapper.midTurn)
    }

    @Test func duration_ms_integer_exact() {
        #expect(GeminiLiveWire.durationMs("10s") == 10_000)
        #expect(GeminiLiveWire.durationMs("0.250s") == 250)
        #expect(GeminiLiveWire.durationMs("1.5s") == 1_500)
        #expect(GeminiLiveWire.durationMs("1.0005s") == 1_001)
        #expect(GeminiLiveWire.durationMs("1.0004s") == 1_000)
        for invalid in ["10", "-1s", "1.s", ".5s", "1.0123456789s", "abc", ""] {
            #expect(GeminiLiveWire.durationMs(invalid) == nil, "\(invalid)")
        }
        #expect(GeminiLiveWire.durationMs("9223372036854775s") == 9_223_372_036_854_775_000)
        #expect(GeminiLiveWire.durationMs("9223372036854775.807s") == 9_223_372_036_854_775_807)
        #expect(GeminiLiveWire.durationMs("9223372036854775.808s") == nil)
        #expect(GeminiLiveWire.durationMs("9223372036854776s") == nil)
    }
}
