import Foundation
import Testing
@testable import Oriveo

/// The "thinking" toggle on the model options panel for a custom LLM or a local engine.
///
/// It reads and writes `chat_template_kwargs.enable_thinking` in the additional request body. The first part covers the pure functions that rewrite the text;
/// the last assertion is on the **URLRequest the production send path really sends**: written through the same entry the panel calls when the toggle is flipped,
/// then through AppState → ChatManager → service builder → URLSession.
@Suite("Chat template thinking switch", .serialized)
@MainActor
struct ChatTemplateThinkingSwitchTests {
    typealias Switch = ChatTemplateThinkingSwitch

    private static func object(_ raw: String) throws -> NSDictionary {
        NSDictionary(dictionary: try #require(
            JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any], "not a valid JSON object: \(raw)"
        ))
    }

    private static func written(_ isOn: Bool, in raw: String) throws -> String {
        guard case let .success(result) = Switch.setting(isOn, in: raw) else {
            Issue.record("write failed: \(Switch.setting(isOn, in: raw))")
            return ""
        }
        return result
    }

    // MARK: - Writing

    @Test("empty content: writes an object holding just this item")
    func emptyContentBecomesAMinimalObject() throws {
        for raw in ["", "  \n "] {
            let on = try Self.written(true, in: raw)
            #expect(try Self.object(on) == ["chat_template_kwargs": ["enable_thinking": true]])
            #expect(on == "{\n  \"chat_template_kwargs\": {\n    \"enable_thinking\": true\n  }\n}")
        }
        #expect(try Self.object(try Self.written(false, in: "")) == ["chat_template_kwargs": ["enable_thinking": false]])
    }

    @Test("other fields present: not one character of the text changes, the item is appended at the end")
    func otherFieldsAndFormattingArePreserved() throws {
        let multiline = "{\n    \"top_k\": 40,\n    \"logit_bias\": {\"50256\": -100}\n}"
        let result = try Self.written(true, in: multiline)
        #expect(result == """
        {
            "top_k": 40,
            "logit_bias": {"50256": -100},
            "chat_template_kwargs": {
                "enable_thinking": true
            }
        }
        """)

        let singleLine = #"{"top_k": 40, "stop": ["}", "\"{"]}"#
        #expect(
            try Self.written(false, in: singleLine)
                == #"{"top_k": 40, "stop": ["}", "\"{"], "chat_template_kwargs": {"enable_thinking": false}}"#
        )
        #expect(try Self.written(true, in: "{}") == #"{"chat_template_kwargs": {"enable_thinking": true}}"#)
    }

    @Test("the item is present: only that one value changes")
    func existingValueIsReplacedInPlace() throws {
        let raw = "{\n  \"chat_template_kwargs\": { \"enable_thinking\" : false },\n  \"top_k\": 40\n}"
        #expect(
            try Self.written(true, in: raw)
                == "{\n  \"chat_template_kwargs\": { \"enable_thinking\" : true },\n  \"top_k\": 40\n}"
        )
        // A value of another type becomes a boolean too: this item belongs to the toggle.
        #expect(
            try Self.written(false, in: #"{"chat_template_kwargs": {"enable_thinking": "yes"}}"#)
                == #"{"chat_template_kwargs": {"enable_thinking": false}}"#
        )
        // When it already has the target value the text stays unchanged.
        #expect(try Self.written(false, in: raw) == raw)
    }

    @Test("the chat template arguments hold other items: they are kept and this one is added")
    func otherTemplateArgumentsArePreserved() throws {
        let raw = #"{"temperature": 0.2, "chat_template_kwargs": {"reasoning_effort": "low", "tools": {"a": [1, 2]}}}"#
        let result = try Self.written(true, in: raw)
        #expect(
            result
                == #"{"temperature": 0.2, "chat_template_kwargs": {"reasoning_effort": "low", "tools": {"a": [1, 2]}, "enable_thinking": true}}"#
        )
        #expect(try Self.object(result) == [
            "temperature": 0.2,
            "chat_template_kwargs": ["reasoning_effort": "low", "tools": ["a": [1, 2]], "enable_thinking": true],
        ])
        #expect(try Self.written(true, in: #"{"chat_template_kwargs": {}}"#) == #"{"chat_template_kwargs": {"enable_thinking": true}}"#)
    }

    @Test("when the text cannot be rewritten in place everything is laid out again and nothing is lost")
    func unusualSpellingFallsBackToReserialising() throws {
        // The key name is written with an escape: the scanner still recognizes it as the same key.
        let escaped = #"{"chat_template_kwargs": {"enable_thinking": false}, "top_k": 40}"#
        #expect(try Self.object(try Self.written(true, in: escaped)) == [
            "chat_template_kwargs": ["enable_thinking": true], "top_k": 40,
        ])
        // The same key is written twice: the parse result decides, and reading back after the write gives the target value.
        let duplicated = #"{"chat_template_kwargs": {"enable_thinking": false, "enable_thinking": false}}"#
        let result = try Self.written(true, in: duplicated)
        #expect(try Self.object(result) == ["chat_template_kwargs": ["enable_thinking": true]])
    }

    @Test("not a valid JSON object: not overwritten, returns a failure")
    func invalidContentIsNeverOverwritten() {
        for raw in [#"{"top_k": "#, "[1, 2]", "42", #""text""#, "not json"] {
            #expect(Switch.setting(true, in: raw) == .failure(.notAnObject), "\"\(raw)\" was overwritten")
        }
        for raw in [#"{"chat_template_kwargs": true}"#, #"{"chat_template_kwargs": ["enable_thinking"]}"#] {
            #expect(Switch.setting(true, in: raw) == .failure(.templateArgumentsNotAnObject), "\"\(raw)\" was overwritten")
        }
    }

    // MARK: - Reading

    @Test("displayed value: on only when written as true and sent with requests; blocked when the content has a problem")
    func stateReadsFromTheSamePlace() {
        func state(_ raw: String, sends: Bool = true) -> Switch.State {
            Switch.state(of: .init(rawJSON: raw, sendsWithRequest: sends))
        }
        #expect(state("") == .off)
        #expect(state(#"{"top_k": 40}"#) == .off)
        #expect(state(#"{"chat_template_kwargs": {"enable_thinking": true}}"#) == .on)
        #expect(state(#"{"chat_template_kwargs": {"enable_thinking": false}}"#) == .off)
        // "Send with requests" is off: the content is still there but will not go out this turn, and the toggle shows off.
        #expect(state(#"{"chat_template_kwargs": {"enable_thinking": true}}"#, sends: false) == .off)
        // The number 1 is not true.
        #expect(state(#"{"chat_template_kwargs": {"enable_thinking": 1}}"#) == .off)
        #expect(state(#"{"top_k": "#) == .blocked)
        #expect(state("[1]") == .blocked)
        #expect(state(#"{"chat_template_kwargs": 3}"#) == .blocked)
        // Content the device would reject (a protected field) has to be fixed first as well: sending it would make every message fail.
        #expect(state(#"{"messages": [], "chat_template_kwargs": {"enable_thinking": true}}"#) == .blocked)
        // Other fields are present and sending is off: flipping the toggle would send them along, so this is "not being sent" rather than "off".
        #expect(state(#"{"top_k": 40}"#, sends: false) == .notSending)
        #expect(state(#"{"top_k": 40, "chat_template_kwargs": {"enable_thinking": true}}"#, sends: false) == .notSending)
        #expect(state(#"{"chat_template_kwargs": {"enable_thinking": true, "reasoning_effort": "low"}}"#, sends: false) == .notSending)
        // With this item alone (or nothing) and sending off it is "off", and flipping turns sending on along the way.
        #expect(state(#"{"chat_template_kwargs": {}}"#, sends: false) == .off)
        #expect(state("{}", sends: false) == .off)
        // With sending off, a content problem is still reported first: it has to be solved first.
        #expect(state(#"{"top_k": "#, sends: false) == .blocked)
    }

    @Test("the toggle only appears on a protocol that applies a chat template: Chat Completions")
    func switchAppliesToChatCompletionsOnly() {
        for transport in RelayTransport.allCases {
            #expect(
                Switch.applies(toTransport: transport.rawValue) == (transport == .openaiChatCompletions),
                "wrong verdict for \(transport.rawValue)"
            )
        }
        // It does not appear while the protocol is undecided.
        #expect(!Switch.applies(toTransport: nil))
    }

    @Test("flipping the toggle: turns sending on along the way when the content is empty or holds this item alone; writes nothing when other fields are present but not sent, or the content has a problem")
    func applyingTurnsSendingOnOnlyWhenNothingElseWouldBeSent() throws {
        // Other fields present, sending off: nothing is written, and those fields are not sent on the user's behalf.
        #expect(Switch.applying(true, to: .init(rawJSON: #"{"top_k": 40}"#, sendsWithRequest: false)) == nil)
        // Empty content, or this item alone: flipping turns sending on along the way.
        for raw in ["", #"{"chat_template_kwargs": {"enable_thinking": false}}"#] {
            let opened = try #require(Switch.applying(true, to: .init(rawJSON: raw, sendsWithRequest: false)))
            #expect(opened.sendsWithRequest)
            #expect(Switch.state(of: opened) == .on)
            #expect(try Self.object(opened.rawJSON) == ["chat_template_kwargs": ["enable_thinking": true]])
        }

        // Sending was already on: the other fields stay as they are.
        let stored = AdditionalRequestBodyConfiguration(rawJSON: #"{"top_k": 40}"#, sendsWithRequest: true)
        let on = try #require(Switch.applying(true, to: stored))
        #expect(on.sendsWithRequest)
        #expect(Switch.state(of: on) == .on)
        #expect(try Self.object(on.rawJSON) == ["top_k": 40, "chat_template_kwargs": ["enable_thinking": true]])

        let off = try #require(Switch.applying(false, to: on))
        #expect(off.sendsWithRequest)
        #expect(Switch.state(of: off) == .off)
        #expect(try Self.object(off.rawJSON) == ["top_k": 40, "chat_template_kwargs": ["enable_thinking": false]])

        #expect(Switch.applying(true, to: .init(rawJSON: #"{"top_k": "#, sendsWithRequest: true)) == nil)
        #expect(Switch.applying(true, to: .init(rawJSON: #"{"messages": []}"#, sendsWithRequest: true)) == nil)
    }

    // MARK: - Production send path

    @Test("after the toggle is turned on for a custom connection, the request really sent carries chat_template_kwargs.enable_thinking and the existing fields")
    func turningTheSwitchOnReachesTheRealRequest() async throws {
        typealias Fixture = AdditionalRequestBodyProductionRequestTests.Fixture
        // The user wrote other fields in the model default scope; the toggle writes to the conversation layer and must not cover them.
        let fixture = Fixture(connectionDefaults: [:], additionalBody: #"{"top_k": 40}"#)
        defer { fixture.cleanUp() }
        let provider = try #require(fixture.state.provider(for: fixture.providerID))
        let model = try #require(provider.models.first)
        let modelID = CapabilityPreferenceRuntimeIdentity.canonicalModelID(provider: provider, model: model)
        let store = GenerationParameterSettingsStore.shared
        defer {
            store.setAdditionalRequestBody(
                nil, providerID: fixture.providerID, modelID: modelID, conversationID: fixture.conversationID
            )
            store.setAdditionalRequestBody(
                nil, providerID: fixture.providerID, modelID: modelID, conversationID: nil
            )
        }

        // Precondition: this is a custom connection without an official configuration, and the panel gives it exactly this toggle.
        #expect(provider.kind == .relay)
        let presentation = CapabilityControlPresentationResolver.presentation(
            provider: provider, model: model, capability: "reasoning"
        )
        let shape = ModelOptionCapabilityShape.resolve(.init(
            capability: .reasoning, presentation: presentation, connection: .custom
        ))
        #expect(shape.isChatTemplateThinkingToggle, "thinking on a custom connection is not the chat template toggle: \(shape)")

        // This is the write entry the panel calls when the toggle is flipped.
        #expect(Switch.write(
            true, providerID: fixture.providerID, modelID: modelID, conversationID: fixture.conversationID
        ))
        #expect(Switch.state(of: store.effectiveAdditionalRequestBody(
            providerID: fixture.providerID, modelID: modelID, conversationID: fixture.conversationID
        )) == .on)

        _ = try await fixture.send()
        let sent = try #require(AdditionalRequestBodyCaptureURLProtocol.captured.first, "the send path sent no request")
        #expect((sent["chat_template_kwargs"] as? [String: Any])?["enable_thinking"] as? Bool == true)
        #expect((sent["top_k"] as? NSNumber)?.intValue == 40, "turning the toggle on covered the user's other fields")
        #expect(sent["model"] as? String == Fixture.modelID)

        // Turned off: the next request carries false; the item is not removed.
        #expect(Switch.write(
            false, providerID: fixture.providerID, modelID: modelID, conversationID: fixture.conversationID
        ))
        _ = try await fixture.send()
        let next = try #require(AdditionalRequestBodyCaptureURLProtocol.captured.first)
        #expect((next["chat_template_kwargs"] as? [String: Any])?["enable_thinking"] as? Bool == false)
        #expect((next["top_k"] as? NSNumber)?.intValue == 40)

        // The copy in the model default scope was not touched.
        #expect(fixture.stored == .init(rawJSON: #"{"top_k": 40}"#, sendsWithRequest: true))
    }
}
