import Foundation
import Testing
@testable import Oriveo

/// Contract tests for typing reset, typed-send outcomes, and return-to-voice-stage playback:
/// shared/voice-contracts/realtime-model.v1.json (typingResetCases / typedSendCases / backToStageCases).
/// Typing reset goes through RealtimeTypingReset.apply, the same call the page makes (selected {connectionId, model} mapping).
@MainActor
@Suite("Realtime composer contract")
struct RealtimeComposerContractTests {
    private typealias Policy = RealtimeModelPolicy

    private static func bool(_ value: Any?) -> Bool? {
        guard let n = value as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { return nil }
        return n.boolValue
    }

    /// Maps a fixture connectionId to a stable providerID (the same string always yields the same UUID).
    private static func uuid(_ connectionId: String) -> UUID {
        var bytes = [UInt8](repeating: 0, count: 16)
        for (index, byte) in connectionId.utf8.enumerated() { bytes[index % 16] &+= byte &+ UInt8(index % 251) }
        return NSUUID(uuidBytes: bytes) as UUID
    }

    private static func selection(_ value: Any?) throws -> RealtimeModelSelection? {
        guard let json = value as? [String: Any] else { return nil }
        let connectionId = try #require(json["connectionId"] as? String)
        let model = try #require(json["model"] as? String)
        return RealtimeModelSelection(providerID: uuid(connectionId), providerKind: .openAI, model: model)
    }

    @Test("typing reset cases match the fixture")
    func typingResetCases() throws {
        let cases = try RealtimeModelContractTests.cases("typingResetCases")
        #expect(cases.count >= 5)
        for item in cases {
            let id = item["id"] as? String ?? "?"
            let input = try #require(item["input"] as? [String: Any], "\(id)")
            let expected = try #require(Self.bool((item["expected"] as? [String: Any])?["typing"]), "\(id)")
            let typing = try #require(Self.bool(input["typing"]), "\(id)")
            let conversation = UUID()
            var hosts: Set<UUID?> = typing ? [conversation] : []
            RealtimeTypingReset.apply(
                old: .init(conversationID: conversation, selection: try Self.selection(input["before"])),
                new: .init(conversationID: conversation, selection: try Self.selection(input["after"])),
                hosts: &hosts
            )
            #expect(hosts.contains(conversation) == expected, "\(id)")
        }
    }

    @Test("switching conversation alone keeps typing")
    func switchingConversationKeepsTyping() throws {
        let a = UUID(), b = UUID()
        let selection = RealtimeModelSelection(providerID: UUID(), providerKind: .openAI, model: "gpt-realtime-2.1")
        var hosts: Set<UUID?> = [a]
        RealtimeTypingReset.apply(
            old: .init(conversationID: a, selection: selection),
            new: .init(conversationID: b, selection: nil),
            hosts: &hosts
        )
        #expect(hosts == [a])
    }

    @Test("typed send cases match the fixture")
    func typedSendCases() throws {
        let cases = try RealtimeModelContractTests.cases("typedSendCases")
        #expect(cases.count >= 7)
        for item in cases {
            let id = item["id"] as? String ?? "?"
            let input = try #require(item["input"] as? [String: Any], "\(id)")
            let expected = try #require(item["expected"] as? [String: Any], "\(id)")
            let context = try #require(Policy.TypedSendContext(rawValue: input["context"] as? String ?? ""), "\(id)")
            let outcome = try #require(Policy.TypedSendOutcomeKind(rawValue: input["outcome"] as? String ?? ""), "\(id)")
            let got = Policy.typedSendOutcome(context: context, outcome: outcome)
            #expect(Set(expected.keys) == ["inputKeepsText", "conversationCreated"], "\(id) fields")
            #expect(Self.bool(expected["inputKeepsText"]) == got.inputKeepsText, "\(id) inputKeepsText")
            #expect(Self.bool(expected["conversationCreated"]) == got.conversationCreated, "\(id) conversationCreated")
        }
    }

    @Test("back to stage cases match the fixture")
    func backToStageCases() throws {
        let cases = try RealtimeModelContractTests.cases("backToStageCases")
        #expect(cases.count >= 3)
        for item in cases {
            let id = item["id"] as? String ?? "?"
            let input = try #require(item["input"] as? [String: Any], "\(id)")
            let expected = try #require(item["expected"] as? [String: Any], "\(id)")
            let session = try #require(Policy.BackToStageSession(rawValue: input["session"] as? String ?? "none"), "\(id)")
            let got = Policy.backToStage(session: session, assistantSpeaking: Self.bool(input["assistantSpeaking"]) ?? false)
            #expect(got.action.rawValue == expected["action"] as? String, "\(id) action")
            #expect(Self.bool(expected["interruptsPlayback"]) == got.interruptsPlayback, "\(id) interruptsPlayback")
        }
    }
}
