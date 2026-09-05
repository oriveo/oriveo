import Foundation
import Testing
@testable import Oriveo

@Suite("Capability execution truth")
struct CapabilityExecutionRuntimeTests {
    @Test("final JSON encoding gates requested and only the bound parser signal observes")
    func requestedAndObservedAreSeparate() throws {
        let (runtime, recipe) = try Self.runtimeAndRecipe(signals: [[
            "kind": "citation", "producerEvent": "citations", "pointer": "/citations", "nonEmpty": true,
        ]])
        let tracker = CapabilityExecutionTracker()
        tracker.recordCompiledDelta(recipe: recipe, runtime: runtime, finalTransport: "openai_chat")
        #expect(tracker.terminalResult().states.isEmpty, "A compiler candidate is not yet wire evidence")

        tracker.confirmFinalWireEncoded()
        #expect(tracker.terminalResult().states.isEmpty, "Encoding alone is not dispatch evidence")
        tracker.confirmRequestDispatched()
        #expect(tracker.terminalResult().states["web"] == .unconfirmed, "HTTP success alone is not observed")
        tracker.recordParserEvent(.reasoning, nonEmpty: true)
        #expect(tracker.terminalResult().states["web"] == .unconfirmed, "Wrong normalized event is ignored")
        tracker.recordParserEvent(.citations, nonEmpty: true)
        #expect(tracker.terminalResult().states["web"] == .observed)
    }

    @Test("requested callback occurs only at the actual dispatch boundary")
    func requestedCallbackRequiresDispatch() throws {
        let (runtime, recipe) = try Self.runtimeAndRecipe(signals: [[
            "kind": "citation", "producerEvent": "citations", "pointer": "/citations", "nonEmpty": true,
        ]])
        let recorder = RequestedRecorder()
        let tracker = CapabilityExecutionTracker { recorder.record($0) }
        tracker.recordCompiledDelta(recipe: recipe, runtime: runtime, finalTransport: "openai_chat")
        #expect(recorder.latest == nil)
        tracker.confirmFinalWireEncoded()
        #expect(recorder.latest == nil)
        tracker.confirmRequestDispatched()
        #expect(recorder.latest?.states["web"] == .requested)
    }

    @Test("custom owner uses the same revision-bound definition and can only be unconfirmed")
    func customOwnerIsRequestedThenUnconfirmed() throws {
        let (runtime, recipe) = try Self.runtimeAndRecipe(signals: [[
            "kind": "citation", "producerEvent": "citations", "pointer": "/citations", "nonEmpty": true,
        ]])
        let tracker = CapabilityExecutionTracker()
        let controls = ["web": MetadataClient.CapabilityControl(
            state: RequestControlAvailability.autoAvailable.rawValue,
            recipeRef: recipe.id,
            reasonCode: nil,
            sourceRefs: nil,
            availableIntents: nil,
            customControlRefs: nil
        )]
        tracker.freezeRuntimeEnvelope(runtime, controls: controls)
        tracker.recordCustomDelta(owner: "web", pointers: ["/web_search_options"], finalTransport: "openai_chat")
        tracker.confirmFinalWireEncoded()
        tracker.confirmRequestDispatched()
        tracker.recordParserEvent(.citations, nonEmpty: true)
        #expect(tracker.terminalResult().states["web"] == .unconfirmed)
        #expect(tracker.terminalResult().states["web"] != .observed)
        #expect(tracker.terminalResult().states["web"] != .rejected)
    }

    @Test("empty reviewed signals stay unconfirmed and cannot infer rejection")
    func unconfirmedWithoutInferredRejection() throws {
        let (runtime, recipe) = try Self.runtimeAndRecipe(signals: [])
        let tracker = CapabilityExecutionTracker()
        tracker.recordCompiledDelta(recipe: recipe, runtime: runtime, finalTransport: "openai_chat")
        tracker.confirmFinalWireEncoded()
        tracker.confirmRequestDispatched()
        tracker.recordParserEvent(.citations, nonEmpty: true)
        #expect(tracker.terminalResult().states["web"] == .unconfirmed)
        #expect(tracker.terminalResult().states["web"] != .rejected)
    }

    @Test("custom 400 retry gate closes on a parser event even without assistant text")
    func customRetryGateClosesOnCitationOrReasoning() throws {
        let citationsTracker = CapabilityExecutionTracker()
        #expect(citationsTracker.canOfferExplicitCustomRetry)
        // This is the real TransportStrategy → StreamEvent citation bridge.
        citationsTracker.recordParserEvent(.citations, nonEmpty: true)
        #expect(!citationsTracker.canOfferExplicitCustomRetry)

        let reasoningTracker = CapabilityExecutionTracker()
        #expect(reasoningTracker.canOfferExplicitCustomRetry)
        // An empty reasoning heartbeat is still an upstream response.
        reasoningTracker.recordParserEvent(.reasoning, nonEmpty: false)
        #expect(!reasoningTracker.canOfferExplicitCustomRetry)
    }

    @Test("custom 400 retry gate closes after a tool side effect but stays open pre-token")
    func customRetryGateClosesOnSideEffect() {
        let preTokenTracker = CapabilityExecutionTracker()
        #expect(preTokenTracker.canOfferExplicitCustomRetry)

        let sideEffectTracker = CapabilityExecutionTracker()
        sideEffectTracker.recordSideEffect()
        #expect(!sideEffectTracker.canOfferExplicitCustomRetry)
    }

    @Test("protocol or parser mismatch cannot create a requested fact")
    func exactBindingRequired() throws {
        let (runtime, recipe) = try Self.runtimeAndRecipe(signals: [[
            "kind": "citation", "producerEvent": "citations", "pointer": "/citations", "nonEmpty": true,
        ]])
        let tracker = CapabilityExecutionTracker()
        tracker.recordCompiledDelta(recipe: recipe, runtime: runtime, finalTransport: "anthropic_messages")
        tracker.confirmFinalWireEncoded()
        tracker.confirmRequestDispatched()
        #expect(tracker.terminalResult().states.isEmpty)
    }

    private static func runtimeAndRecipe(
        signals: [[String: Any]]
    ) throws -> (MetadataClient.CapabilityRuntimeEnvelope, MetadataClient.CapabilityRecipe) {
        let definition: [String: Any] = [
            "capability": "web", "protocol": "openai_chat", "responseParserKind": "openai_chat_web_v1",
            "signals": signals,
        ]
        let document: [String: Any] = [
            "schemaVersion": 2, "revision": "p5-test", "generatedAt": "2026-08-12T00:00:00Z",
            "recipes": ["web": [
                "id": "web", "providerKind": "openAI", "transport": ["protocol": "openai_chat"],
                "capability": "web", "executionKind": "server_tool", "requestOps": [],
                "responseParserKind": "openai_chat_web_v1", "responseEvidenceRef": "web-evidence",
                "errorRecoveryRef": "web-evidence",
            ]],
            "controlDefinitions": [:], "sourceIndex": [:],
            "responseEvidenceDefinitions": ["web-evidence": definition],
            "errorRecoveryDefinitions": ["web-evidence": [
                "capability": "web", "protocol": "openai_chat",
                "responseParserKind": "openai_chat_web_v1", "locatorRules": [],
            ]],
        ]
        let runtime = try JSONDecoder().decode(
            MetadataClient.CapabilityRuntimeEnvelope.self,
            from: JSONSerialization.data(withJSONObject: document)
        )
        return (runtime, try #require(runtime.recipes["web"]))
    }
}

private final class RequestedRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var value: CapabilityExecutionResult?

    var latest: CapabilityExecutionResult? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func record(_ result: CapabilityExecutionResult) {
        lock.lock()
        value = result
        lock.unlock()
    }
}
