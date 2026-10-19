import Foundation
import OriveoProviderKit
import Testing
@testable import Oriveo

/// Cross-platform alignment cases with the same names on every platform. Fixtures are reused from ContextPipelineTests+Overflow.swift.
extension ContextPipelineTests {

    /// An overflow body only the Anthropic family recognizes: the openai_compatible regex group does not match it, so the fallback resend only triggers if the family is judged correctly.
    private static let anthropicOverflowBody =
        #"{"type":"error","error":{"type":"invalid_request_error","message":"input length and max_tokens exceed context limit: 50000 + 4000 > 40000"}}"#

    /// An overflow body only the Gemini family recognizes.
    private static let geminiOverflowBody =
        #"{"error":{"code":400,"message":"The input token count (50000) exceeds the maximum number of tokens allowed (40000).","status":"INVALID_ARGUMENT"}}"#

    private static func shortHistory() -> [ChatMessage] {
        [
            TestFactories.makeMessage(role: .user, text: "First question"),
            TestFactories.makeMessage(role: .assistant, text: "First answer"),
        ]
    }

    private func assertOverflowRecoveredWithFamily(
        kind: ProviderKind,
        relayTransport: RelayTransport = .openaiChatCompletions,
        body: String,
        family: StopFamily
    ) async throws {
        let fixture = makeOverflowFixture(kind: kind, relayTransport: relayTransport, messages: Self.mediumHistory())
        let bodies = try await sendAndSettle(fixture, text: "Next", replies: [
            .init(status: 400, body: body),
            .init(status: 400, body: body),
        ])

        // Only when judged as overflow does the fallback resend once.
        #expect(bodies.count == 2)
        let manifests = try ledger(fixture).manifests(conversationId: fixture.conversationID.uuidString)
        #expect(manifests.count == 2)
        #expect(manifests.allSatisfy { $0.transport == family.rawValue })
        #expect(manifests.allSatisfy { $0.stopReason == .contextWindowExceeded })
        let assistant = try #require(fixture.state.conversation(for: fixture.conversationID)?.messages.last)
        #expect(assistant.stopReason == .contextWindowExceeded)
    }

    @Test func relay_anthropic_overflow_uses_anthropic_family() async throws {
        try await assertOverflowRecoveredWithFamily(
            kind: .relay, relayTransport: .anthropicMessages, body: Self.anthropicOverflowBody, family: .anthropic
        )
    }

    @Test func official_anthropic_overflow_uses_anthropic_family() async throws {
        try await assertOverflowRecoveredWithFamily(kind: .anthropic, body: Self.anthropicOverflowBody, family: .anthropic)
    }

    @Test func official_gemini_overflow_uses_gemini_family() async throws {
        try await assertOverflowRecoveredWithFamily(kind: .gemini, body: Self.geminiOverflowBody, family: .gemini)
    }

    @Test func relay_openai_chat_clean_end_records_stop() async throws {
        let fixture = makeOverflowFixture(messages: Self.shortHistory())
        _ = try await sendAndSettle(fixture, text: "Next", replies: [
            .init(status: 200, body: Self.sse([Self.contentFrame("Done"), Self.stopFrame(promptTokens: 40)])),
        ])

        let manifests = try ledger(fixture).manifests(conversationId: fixture.conversationID.uuidString)
        #expect(manifests.count == 1)
        let manifest = try #require(manifests.first)
        #expect(manifest.transport == StopFamily.openaiChat.rawValue)
        #expect(manifest.stopReason == .stop)
        #expect(manifest.observedInput == 40)
        #expect(manifest.basis == .observed)
    }

    @Test func manifest_written_on_user_cancel() async throws {
        let fixture = makeOverflowFixture(messages: Self.shortHistory())
        OverflowURLProtocol.reset([
            .init(status: 200, body: "data: \(Self.contentFrame("Partial"))\n\n", hang: true),
        ])
        defer { OverflowURLProtocol.reset([]) }
        _ = await fixture.state.sendMessage("Next", in: fixture.conversationID)
        let deadline = ContinuousClock.now + .seconds(8)
        while ContinuousClock.now < deadline, OverflowURLProtocol.bodies.isEmpty {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        fixture.state.cancelGeneration(in: fixture.conversationID)
        try await Task.sleep(nanoseconds: 300_000_000)

        let assistant = try #require(fixture.state.conversation(for: fixture.conversationID)?.messages.last)
        #expect(assistant.stopReason == .interrupted)
        let manifests = try ledger(fixture).manifests(conversationId: fixture.conversationID.uuidString)
        #expect(manifests.count == 1)
        #expect(manifests.first?.stopReason == .interrupted)
        #expect(manifests.first?.transport == StopFamily.openaiChat.rawValue)
    }

    @Test func overflow_no_checkpoint_no_retry() async throws {
        // History too short: the fallback cannot fold out a checkpoint, so a resend would just overflow again unchanged.
        let fixture = makeOverflowFixture(messages: Self.shortHistory())
        let bodies = try await sendAndSettle(fixture, text: "Next", replies: [
            .init(status: 400, body: Self.overflowBody),
            .init(status: 200, body: Self.sse([Self.contentFrame("Never"), Self.stopFrame(promptTokens: nil)])),
        ])

        #expect(bodies.count == 1)
        let assistant = try #require(fixture.state.conversation(for: fixture.conversationID)?.messages.last)
        #expect(assistant.state == .failed)
        #expect(assistant.stopReason == .contextWindowExceeded)
        let manifests = try ledger(fixture).manifests(conversationId: fixture.conversationID.uuidString)
        #expect(manifests.count == 1)
        #expect(manifests.first?.stopReason == .contextWindowExceeded)
    }

    @Test func overflow_after_reasoning_no_retry() async throws {
        let fixture = makeOverflowFixture(messages: Self.mediumHistory())
        let reasoningFrame = #"{"choices":[{"index":0,"delta":{"reasoning_content":"Thinking"},"finish_reason":null}]}"#
        let bodies = try await sendAndSettle(fixture, text: "Next", replies: [
            .init(status: 200, body: Self.sse([reasoningFrame, Self.overflowBody])),
            .init(status: 200, body: Self.sse([Self.contentFrame("Never"), Self.stopFrame(promptTokens: nil)])),
        ])

        // Reasoning already emitted counts as output already emitted: no resend.
        #expect(bodies.count == 1)
        let assistant = try #require(fixture.state.conversation(for: fixture.conversationID)?.messages.last)
        #expect(assistant.stopReason == .contextWindowExceeded)
    }

    @Test func raw_body_not_in_error_details() async throws {
        let sentinel = "RAWBODY-SENTINEL-7f3a"
        // The sentinel sits in a field other than message: only the full raw text (rawBody) carries it, not the upstream message summary.
        let body = #"{"error":{"code":"context_length_exceeded","message":"maximum context length is 40000 tokens","param":"\#(sentinel)"}}"#
        let fixture = makeOverflowFixture(messages: Self.mediumHistory())
        _ = try await sendAndSettle(fixture, text: "Next", replies: [
            .init(status: 400, body: body),
            .init(status: 400, body: body),
        ])

        // The failure card details and the persisted message do not carry the raw text.
        let assistant = try #require(fixture.state.conversation(for: fixture.conversationID)?.messages.last)
        #expect(assistant.state == .failed)
        #expect(assistant.stopReason == .contextWindowExceeded)
        #expect(!(assistant.errorTitle ?? "").contains(sentinel))
        #expect(!(assistant.errorDetail ?? "").contains(sentinel))
        #expect(!assistant.text.contains(sentinel))
        // The manifest does not carry the raw text.
        let manifests = try ledger(fixture).manifests(conversationId: fixture.conversationID.uuidString)
        #expect(!manifests.isEmpty)
        #expect(!manifests.contains { String(describing: $0).contains(sentinel) })

        // The error mapped by production keeps the raw text only in the on-site record (rawBody), not in the error itself.
        let service = BaseAPIService(session: URLSession(configuration: .ephemeral))
        let diagnostics = ChatFailureDiagnostics()
        let error = ChatFailureDiagnostics.$current.withValue(diagnostics) {
            service.mapHTTPError(statusCode: 400, data: Data(body.utf8))
        }
        #expect(diagnostics.snapshot.rawBody?.contains(sentinel) == true)
        #expect(!String(describing: error).contains(sentinel))
    }
}
