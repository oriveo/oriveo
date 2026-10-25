import Foundation
import Testing
@testable import Oriveo

/// Round-trip of the unified events in shared/voice-contracts/realtime-events.v1.json, and its three closed sets.
@Suite("RealtimeEventsContract")
struct RealtimeEventsContractTests {

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

    @Test("every expected event round-trips")
    func roundTrip() throws {
        let cases = try #require(try Self.fixture()["mapCases"] as? [[String: Any]])
        #expect(!cases.isEmpty)
        var seen = Set<String>()
        for item in cases {
            let id = item["id"] as? String ?? "?"
            let expected = try #require(item["expected"] as? [[String: Any]], "\(id)")
            for (index, raw) in expected.enumerated() {
                let event = try #require(RealtimeSessionEvent(json: raw), "\(id)[\(index)]")
                seen.insert(event.typeName)
                #expect(try Self.canonical(event.jsonObject) == Self.canonical(raw), "\(id)[\(index)]")
            }
        }
        #expect(seen == Set(RealtimeSessionEvent.typeNames))
    }

    @Test("goAway keeps null timeLeftMs")
    func goAwayNull() throws {
        let event = try #require(RealtimeSessionEvent(json: ["type": "goAway", "timeLeftMs": NSNull()]))
        #expect(event == .goAway(timeLeftMs: nil))
        #expect(try Self.canonical(event.jsonObject) == #"{"timeLeftMs":null,"type":"goAway"}"#)
    }

    @Test func goaway_missing_key_is_nil() {
        #expect(RealtimeSessionEvent(json: ["type": "goAway"]) == nil)
    }

    @Test func integer_fields_reject_fractions() {
        let audio: [String: Any] = [
            "type": "assistantAudio", "itemId": "i1", "contentIndex": 1.5, "base64": "AA==", "sampleRateHz": 24_000,
        ]
        #expect(RealtimeSessionEvent(json: audio) == nil)
        #expect(RealtimeSessionEvent(json: ["type": "goAway", "timeLeftMs": 1.5]) == nil)
        #expect(RealtimeSessionEvent(json: ["type": "goAway", "timeLeftMs": 500]) == .goAway(timeLeftMs: 500))
    }

    @Test func non_string_item_id_only_fails_item_events() {
        #expect(RealtimeSessionEvent(json: ["type": "ready", "itemId": 5]) == .ready)
        #expect(RealtimeSessionEvent(json: ["type": "goAway", "itemId": 5, "timeLeftMs": 500]) == .goAway(timeLeftMs: 500))
        let audio: [String: Any] = [
            "type": "assistantAudio", "itemId": 5, "contentIndex": 0, "base64": "AA==", "sampleRateHz": 24_000,
        ]
        #expect(RealtimeSessionEvent(json: audio) == nil)
    }

    @Test func integral_float_accepted_fraction_rejected() {
        func audio(_ contentIndex: Any) -> [String: Any] {
            ["type": "assistantAudio", "itemId": "i1", "contentIndex": contentIndex, "base64": "AA==", "sampleRateHz": 24_000]
        }
        #expect(
            RealtimeSessionEvent(json: audio(2.0))
                == .assistantAudio(itemId: "i1", contentIndex: 2, base64: "AA==", sampleRateHz: 24_000)
        )
        #expect(RealtimeSessionEvent(json: audio(1.5)) == nil)
    }

    @Test func numeric_string_rejected() {
        #expect(RealtimeSessionEvent(json: ["type": "goAway", "timeLeftMs": "5000"]) == nil)
        let audio: [String: Any] = [
            "type": "assistantAudio", "itemId": "i1", "contentIndex": "5000", "base64": "AA==", "sampleRateHz": 24_000,
        ]
        #expect(RealtimeSessionEvent(json: audio) == nil)
        #expect(RealtimeSessionEvent(json: ["type": "goAway", "timeLeftMs": true]) == nil)
    }

    @Test("unknown type decodes to nil")
    func unknownType() {
        #expect(RealtimeSessionEvent(json: ["type": "somethingElse"]) == nil)
        #expect(RealtimeSessionEvent(json: [:]) == nil)
    }

    @Test("closed sets match fixture constants")
    func closedSets() throws {
        let c = try #require(try Self.fixture()["constants"] as? [String: Any])
        #expect(c["unifiedEvents"] as? [String] == RealtimeSessionEvent.typeNames)
        #expect(c["turnStatuses"] as? [String] == RealtimeTurnStatus.allCases.map(\.rawValue))
        #expect(c["transports"] as? [String] == RealtimeTransportKind.allCases.map(\.rawValue))
    }
}
