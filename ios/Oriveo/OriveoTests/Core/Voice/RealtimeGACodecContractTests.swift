import Foundation
import OriveoProviderKit
import Testing
@testable import Oriveo

/// openai_realtime / xai_realtime event mapping and client JSON, checked against shared/voice-contracts/realtime-events.v1.json.
@Suite("RealtimeGACodecContract")
struct RealtimeGACodecContractTests {

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

    /// Cases in a fixture group whose transport is openai_realtime / xai_realtime.
    private static func gaCases(_ group: String) throws -> [(id: String, input: [String: Any], codec: GARealtimeCodec, expected: Any)] {
        let all = try #require(try fixture()[group] as? [[String: Any]])
        return try all.compactMap { item in
            let input = try #require(item["input"] as? [String: Any])
            let transport = try #require((input["transport"] as? String).flatMap(RealtimeTransportKind.init(rawValue:)))
            guard let codec = GARealtimeCodec(transport: transport) else { return nil }
            return (item["id"] as? String ?? "?", input, codec, item["expected"] as Any)
        }
    }

    @Test func map_cases() throws {
        let cases = try Self.gaCases("mapCases")
        #expect(cases.count == 10)
        for c in cases {
            let messages = try #require(c.input["messages"] as? [[String: Any]], "\(c.id)")
            var state = GARealtimeCodec.State()
            let events = messages.flatMap { c.codec.map($0, state: &state) }
            #expect(try Self.canonical(events.map(\.jsonObject)) == Self.canonical(c.expected), "\(c.id)")
        }
    }

    @Test func open_cases() throws {
        let cases = try Self.gaCases("openCases")
        #expect(cases.count == 3)
        for c in cases {
            let plan = try #require(c.input["plan"] as? [String: Any], "\(c.id)")
            let entry = try #require(c.input["entry"] as? [String: Any], "\(c.id)")
            let history = try #require(plan["history"] as? [[String: String]], "\(c.id)").map {
                RealtimeTransportInput.Turn(role: $0["role"] == "assistant" ? .assistant : .user, text: $0["text"] ?? "")
            }
            let opening = c.codec.openingMessages(
                instructions: try #require(plan["instructions"] as? String),
                history: history,
                voice: try #require(c.input["voice"] as? String),
                inputTranscriptionModel: entry["inputTranscriptionModel"] as? String
            )
            let actual: [String: Any] = ["beforeReady": opening.beforeReady, "afterReady": opening.afterReady]
            #expect(try Self.canonical(actual) == Self.canonical(c.expected), "\(c.id)")
        }
    }

    @Test func url_cases() throws {
        let cases = try Self.gaCases("urlCases")
        #expect(cases.count == 3)
        for c in cases {
            let entry = try #require(c.input["entry"] as? [String: Any], "\(c.id)")
            let url = c.codec.connectURL(
                host: try #require(c.input["host"] as? String),
                path: try #require(entry["path"] as? String),
                model: try #require(entry["model"] as? String)
            )
            #expect(url == c.expected as? String, "\(c.id)")
        }
    }

    @Test func truncate_cases() throws {
        let cases = try Self.gaCases("truncateCases")
        #expect(cases.count == 4)
        for c in cases {
            let message = GARealtimeCodec.truncate(
                transport: c.codec.transport,
                itemId: c.input["itemId"] as? String,
                contentIndex: (c.input["contentIndex"] as? NSNumber)?.intValue ?? 0,
                playedMs: try #require((c.input["playedMs"] as? NSNumber)?.doubleValue, "\(c.id)")
            )
            if c.expected is NSNull {
                #expect(message == nil, "\(c.id)")
            } else {
                let message = try #require(message, "\(c.id)")
                #expect(try Self.canonical(message) == Self.canonical(c.expected), "\(c.id)")
            }
        }
    }

    @Test func truncate_gemini_not_sent() throws {
        let all = try #require(try Self.fixture()["truncateCases"] as? [[String: Any]])
        let item = try #require(all.first { $0["id"] as? String == "truncate_gemini_not_sent" })
        let input = try #require(item["input"] as? [String: Any])
        #expect(item["expected"] is NSNull)
        #expect(GARealtimeCodec.truncate(
            transport: .geminiLive,
            itemId: input["itemId"] as? String,
            playedMs: (input["playedMs"] as? NSNumber)?.doubleValue ?? 0
        ) == nil)
        // The fixture's itemId is null; passing an itemId must not send either, confirming it is the transport that blocks it.
        #expect(GARealtimeCodec.truncate(transport: .geminiLive, itemId: "msg_010", playedMs: 900) == nil)
        #expect(GARealtimeCodec.truncate(transport: .openaiRealtime, itemId: "msg_010", playedMs: 900) != nil)
    }

    @Test func append_cases() throws {
        let cases = try Self.gaCases("appendCases")
        #expect(cases.count == 2)
        for c in cases {
            let message = c.codec.append(base64: try #require(c.input["base64"] as? String, "\(c.id)"))
            #expect(try Self.canonical(message) == Self.canonical(c.expected), "\(c.id)")
        }
    }
}
