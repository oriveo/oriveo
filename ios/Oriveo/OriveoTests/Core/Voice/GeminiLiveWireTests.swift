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
        #expect(cases.count == 7)
        for item in cases {
            let id = item["id"] as? String ?? "?"
            let input = try #require(item["input"] as? [String: Any], "\(id)")
            let messages = try #require(input["messages"] as? [[String: Any]], "\(id)")
            var mapper = GeminiLiveEventMapper()
            let events = messages.flatMap { mapper.map($0) }
            #expect(try Self.canonical(events.map(\.jsonObject)) == Self.canonical(item["expected"] as Any), "\(id)")
        }
    }

    @Test func gemini_open_cases_match_fixture() throws {
        let cases = try Self.geminiCases("openCases")
        #expect(cases.count == 3)
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
                resumeHandle: input["resumeHandle"] as? String
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
