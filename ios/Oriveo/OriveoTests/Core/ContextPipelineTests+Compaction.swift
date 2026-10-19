import Foundation
import OriveoProviderKit
import Testing
@testable import Oriveo

/// Records the request bodies the production send chain emits (reject cases assert there are none; fallback cases take the first).
private final class CompactionURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var capturedBodies: [[String: Any]] = []
    /// When non-nil, a request whose last message contains the compaction instruction is answered with this text as OpenAI SSE (the summary call).
    nonisolated(unsafe) static var summaryReply: String?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = Self.bodyObject(of: request)
        if let body {
            Self.capturedBodies.append(body)
        }
        var payload = "data: [DONE]\n\n"
        if let reply = Self.summaryReply, Self.isSummaryRequest(body) {
            let chunk: [String: Any] = [
                "id": "chatcmpl-summary",
                "object": "chat.completion.chunk",
                "choices": [["index": 0, "delta": ["content": reply]]],
            ]
            let data = (try? JSONSerialization.data(withJSONObject: chunk)) ?? Data()
            payload = "data: " + String(decoding: data, as: UTF8.self) + "\n\n" + payload
        }
        let url = request.url ?? URL(string: "https://relay.invalid")!
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "text/event-stream"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(payload.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func isSummaryRequest(_ body: [String: Any]?) -> Bool {
        let messages = body?["messages"] as? [[String: Any]] ?? []
        guard let last = messages.last else { return false }
        let text = (last["content"] as? String)
            ?? (last["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined(separator: "\n")
            ?? ""
        return text.contains("CONTEXT CHECKPOINT")
    }

    private static func bodyObject(of request: URLRequest) -> [String: Any]? {
        let data: Data
        if let body = request.httpBody {
            data = body
        } else if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = Data()
            let pointer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4_096)
            defer { pointer.deallocate() }
            while stream.hasBytesAvailable {
                let count = stream.read(pointer, maxLength: 4_096)
                if count <= 0 { break }
                buffer.append(pointer, count: count)
            }
            data = buffer
        } else {
            return nil
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

/// Reject and the 0.90 fallback: when plan.reject is non-empty no request is sent, no assistant message is created, and the input is kept;
/// when plan.compaction=required a deterministic checkpoint is prepended before sending. Fallback cases assert on the production request body.
extension ContextPipelineTests {

    @Test func reject_instructions_too_long_no_request() async throws {
        // W=2000, O=200 -> U=1800; the Skill body is far above U.
        let fixture = makeCompactionFixture(
            contextLength: 2_000,
            maxOutputTokens: 200,
            messages: [],
            skillPrompt: String(repeating: "Follow this rule carefully. ", count: 800)
        )
        try await expectRejected(fixture, text: "Hello", key: "context_reject_instructions_too_long")
    }

    @Test func reject_message_too_long_no_request() async throws {
        let fixture = makeCompactionFixture(contextLength: 2_000, maxOutputTokens: 200, messages: [])
        try await expectRejected(
            fixture,
            text: String(repeating: "A very long paragraph. ", count: 1_000),
            key: "context_reject_message_too_long"
        )
    }

    @Test func compaction_required_sends_checkpoint_first() async throws {
        // W=40000, O=4000 -> B=36000, 0.90 line 32400; a history of 20 messages of 8000 bytes each is far over the line.
        var history: [ChatMessage] = []
        for turn in 0..<10 {
            history.append(TestFactories.makeMessage(
                role: .user, text: "Question \(turn): " + String(repeating: "q", count: 8_000)
            ))
            history.append(TestFactories.makeMessage(
                role: .assistant, text: "Answer \(turn): " + String(repeating: "a", count: 8_000)
            ))
        }
        let fixture = makeCompactionFixture(contextLength: 40_000, maxOutputTokens: 4_000, messages: history)
        let bodies = try await sendCapturing(fixture, text: "Next")
        let messages = Self.compactionWireMessages(try #require(bodies.first))

        #expect(!messages.contains { $0.role == "system" })
        let first = try #require(messages.first)
        #expect(first.role == "user")
        #expect(first.text.hasPrefix("<oriveo-context-checkpoint v=\"1\""))
        #expect(first.text.contains(ContextCheckpoint.note))
        // The checkpoint and the first tail user message are one message, separated by a blank line.
        let checkpointEnd = "</oriveo-context-checkpoint>\n\n"
        let afterCheckpoint = try #require(first.text.range(of: checkpointEnd)).upperBound
        #expect(first.text[afterCheckpoint...].hasPrefix("Question "))
        #expect(messages.count < history.count + 1)
        #expect(messages.last?.text == "Next")
        // Persistence: one row with kind=fallback in the database; the message bodies in the conversation do not carry the checkpoint.
        let rows = try fixture.store().list(conversationId: fixture.conversationID.uuidString)
        #expect(rows.map(\.kind) == [.fallback])
        let stored = fixture.state.conversation(for: fixture.conversationID)?.messages ?? []
        #expect(!stored.contains { $0.text.contains("oriveo-context-checkpoint") })
    }

    /// With AI off the fallback row is persisted; the next send reads the same row back, the checkpoint prefix is byte-identical, no new row is written, and no summary is requested.
    @Test func presend_fallback_persists_and_next_send_reuses() async throws {
        let fixture = makeCompactionFixture(
            contextLength: 40_000, maxOutputTokens: 4_000, messages: Self.longCompactionHistory()
        )
        let firstBodies = try await sendCapturing(fixture, text: "Next")
        #expect(firstBodies.count == 1, "AI off: one chat request, no summary call")
        let firstBody = try #require(firstBodies.first)
        let firstUser = try #require(Self.compactionWireMessages(firstBody).first)
        let secondBodies = try await sendCapturing(fixture, text: "Again")
        #expect(secondBodies.count == 1, "AI off: one chat request, no summary call")
        let secondBody = try #require(secondBodies.first)
        let secondUser = try #require(Self.compactionWireMessages(secondBody).first)

        let checkpointEnd = "</oriveo-context-checkpoint>"
        let firstPrefix = try #require(firstUser.text.range(of: checkpointEnd)).upperBound
        let secondPrefix = try #require(secondUser.text.range(of: checkpointEnd)).upperBound
        #expect(firstUser.text.hasPrefix("<oriveo-context-checkpoint v=\"1\""))
        #expect(String(firstUser.text[..<firstPrefix]) == String(secondUser.text[..<secondPrefix]))
        #expect(!firstBodies.contains { Self.compactionWireMessages($0).last?.text.contains("CONTEXT CHECKPOINT") == true })
        let rows = try fixture.store().list(conversationId: fixture.conversationID.uuidString)
        #expect(rows.count == 1)
        #expect(rows.first?.kind == .fallback)
    }

    /// With AI on, a one-shot summary request (no tools) is sent first, a summary row is persisted, and the chat request is then assembled from that row.
    @Test func presend_ai_summary_sends_compaction_request_then_chat() async throws {
        let previous = AppPreferencesStore.savedContextAISummaryEnabled
        AppPreferencesStore.savedContextAISummaryEnabled = true
        CompactionURLProtocol.summaryReply = ContextCheckpoint.headings
            .map { "## \($0)\n(none)" }
            .joined(separator: "\n")
        defer {
            AppPreferencesStore.savedContextAISummaryEnabled = previous
            CompactionURLProtocol.summaryReply = nil
        }
        let fixture = makeCompactionFixture(
            contextLength: 40_000, maxOutputTokens: 4_000, messages: Self.longCompactionHistory(bytes: 3_500)
        )
        let bodies = try await sendCapturing(fixture, text: "Next", expecting: 2)
        #expect(bodies.count == 2)
        let summaryBody = try #require(bodies.first)
        #expect(summaryBody["tools"] == nil)
        let summaryLast = try #require(Self.compactionWireMessages(summaryBody).last)
        #expect(summaryLast.role == "user")
        #expect(summaryLast.text.contains("CONTEXT CHECKPOINT"))

        let chatBody = try #require(bodies.dropFirst().first)
        let chatMessages = Self.compactionWireMessages(chatBody)
        let firstUser = try #require(chatMessages.first { $0.role == "user" })
        #expect(firstUser.text.hasPrefix("<oriveo-context-checkpoint"))
        #expect(firstUser.text.contains("<summary>"))
        #expect(chatMessages.last?.text == "Next")
        let rows = try fixture.store().list(conversationId: fixture.conversationID.uuidString)
        #expect(rows.map(\.kind) == [.summary])
    }

    @Test func compaction_none_sends_full_history() async throws {
        let fixture = makeCompactionFixture(contextLength: 40_000, maxOutputTokens: 4_000, messages: [
            TestFactories.makeMessage(role: .user, text: "First question"),
            TestFactories.makeMessage(role: .assistant, text: "First answer"),
        ])
        let bodies = try await sendCapturing(fixture, text: "Next")
        let messages = Self.compactionWireMessages(try #require(bodies.first))
        #expect(messages.map(\.role) == ["user", "assistant", "user"])
        #expect(messages.map(\.text) == ["First question", "First answer", "Next"])
        #expect(!messages.contains { $0.text.contains("oriveo-context-checkpoint") })
    }

    /// With a checkpoint row in the database and a failed answer after the first tail user message, sending a new message ->
    /// the first user message of the request starts with the checkpoint text verbatim, and the checkpoint is not wrapped in <oriveo-unanswered> (not escaped).
    @Test func checkpoint_stays_outside_unanswered_after_failed_reply() async throws {
        let oldQuestion = TestFactories.makeMessage(role: .user, text: "Old question")
        let oldAnswer = TestFactories.makeMessage(role: .assistant, text: "Old answer")
        let recent = TestFactories.makeMessage(role: .user, text: "Recent question")
        let failed = TestFactories.makeMessage(
            role: .assistant, text: "", state: .failed, errorTitle: "Upstream error"
        )
        let fixture = makeCompactionFixture(
            contextLength: 40_000, maxOutputTokens: 4_000, messages: [oldQuestion, oldAnswer, recent, failed]
        )
        let conversationId = fixture.conversationID.uuidString
        let covered = [
            ContextCheckpoint.CoveredMessage(id: oldQuestion.id.uuidString, text: oldQuestion.text),
            ContextCheckpoint.CoveredMessage(id: oldAnswer.id.uuidString, text: oldAnswer.text),
        ]
        let checkpointText = "<oriveo-context-checkpoint v=\"1\">\n<note>\(ContextCheckpoint.note)</note>\n"
            + "Earlier turns: the user asked an old question.\n</oriveo-context-checkpoint>"
        try fixture.store().save(ContextCheckpointRecord(
            conversationId: conversationId,
            checkpointId: ContextCheckpoint.checkpointId(
                conversationId: conversationId, coversTo: oldAnswer.id.uuidString
            ),
            kind: .fallback,
            coversFrom: oldQuestion.id.uuidString,
            coversTo: oldAnswer.id.uuidString,
            coversDigest: ContextCheckpoint.coversDigest(covered),
            messagesCovered: 2,
            userMessageIds: [oldQuestion.id.uuidString],
            text: checkpointText,
            summary: nil,
            language: nil,
            model: "relay-window",
            packerVersion: ContextCheckpoint.packerVersion,
            createdAt: Int64(Date().timeIntervalSince1970 * 1_000),
            cost: nil
        ))

        let bodies = try await sendCapturing(fixture, text: "Next")
        let messages = Self.compactionWireMessages(try #require(bodies.first))
        let first = try #require(messages.first { $0.role == "user" })
        let envelope = "<oriveo-unanswered>\n<note>\(ContextSanitizer.unansweredNote)</note>\n"
            + "Recent question\n</oriveo-unanswered>"
        #expect(first.text.hasPrefix(checkpointText))
        #expect(!first.text.contains("&lt;oriveo-context-checkpoint"))
        #expect(first.text == checkpointText + "\n\n" + envelope + "\n\nNext")
        #expect(!messages.contains { $0.text.contains("Old question") })
    }

    /// When the deterministic fallback rebuilds the request, the unanswered envelope the original plan merged into the current message is kept; the assembler places the checkpoint in the first user message.
    @Test func compaction_keeps_unanswered_merge_in_current() throws {
        let history = Self.longCompactionHistory() + [
            TestFactories.makeMessage(role: .user, text: "Unanswered question"),
            TestFactories.makeMessage(role: .assistant, text: "Upstream error", state: .failed),
            TestFactories.makeMessage(role: .user, text: "Next"),
        ]
        let build = ChatRequestBuilder.build(
            from: ChatRequestSnapshot(
                conversation: ChatRequestConversationSnapshot(id: UUID(), useMemory: false, skillID: nil),
                messages: history, preferences: ChatRequestPreferencesSnapshot(), skill: nil,
                sendPath: .send(excludingMessageID: nil)
            ),
            assembly: ChatRequestAssemblyContext(
                window: ContextWindowInput(W: nil, windowKind: .total, maxOutput: ContextMaxOutputSources()),
                rhoHi: 0.5,
                overflowFallbackB: 36_000
            )
        )
        let checkpoint = try #require(build.checkpointText)
        let messages = build.planned.messages
        #expect(messages.count < history.count)
        let firstUser = try #require(messages.first { $0.role == .user })
        #expect(firstUser.text.hasPrefix(checkpoint + "\n\n"))
        let current = try #require(messages.last)
        #expect(current.role == .user)
        let envelope = "<oriveo-unanswered>\n<note>\(ContextSanitizer.unansweredNote)</note>\n"
            + "Unanswered question\n</oriveo-unanswered>"
        #expect(current.text.hasSuffix(envelope + "\n\nNext"))
        #expect(build.planned.plan.unansweredMerged == 1)
    }

    /// The deterministic fallback keeps the persistent-convention (directive) user message, going through ChatRequestBuilder.build as in compaction_inputs_mark_directives.
    @Test func fallback_keeps_directive_user() throws {
        let directive = TestFactories.makeMessage(role: .user, text: "From now on, reply in English.")
        let history = [directive, TestFactories.makeMessage(role: .assistant, text: "Sure.")]
            + Self.longCompactionHistory()
            + [TestFactories.makeMessage(role: .user, text: "Next")]
        let build = ChatRequestBuilder.build(
            from: ChatRequestSnapshot(
                conversation: ChatRequestConversationSnapshot(id: UUID(), useMemory: false, skillID: nil),
                messages: history, preferences: ChatRequestPreferencesSnapshot(), skill: nil,
                sendPath: .send(excludingMessageID: nil)
            ),
            assembly: ChatRequestAssemblyContext(
                window: ContextWindowInput(W: nil, windowKind: .total, maxOutput: ContextMaxOutputSources()),
                rhoHi: 0.5,
                overflowFallbackB: 36_000
            )
        )
        let checkpoint = try #require(build.checkpointText)
        #expect(checkpoint.contains("From now on, reply in English."))
        let messages = build.planned.messages
        #expect(messages.count < history.count)
        // The original directive message is folded into the checkpoint and does not reappear in the tail.
        #expect(messages.filter { $0.text.contains("From now on, reply in English.") }.count == 1)
    }

    // MARK: Fixtures

    private struct CompactionFixture {
        let state: AppState
        let conversationID: UUID

        func store() throws -> ContextCompactionStore {
            try #require(ContextCompactionStore.forPartition(state.sessionPartitionUID))
        }
    }

    /// 20 messages of `bytes` bytes each (rho defaults to 0.5). At 8000 bytes, W=40000 and O=4000 are far over the 0.90 line;
    /// at 3500 bytes it is about 35000 tokens: over the 0.90 line (32400), while the summary span still fits in U (appended form).
    private static func longCompactionHistory(bytes: Int = 8_000) -> [ChatMessage] {
        var history: [ChatMessage] = []
        for turn in 0..<10 {
            history.append(TestFactories.makeMessage(
                role: .user, text: "Question \(turn): " + String(repeating: "q", count: bytes)
            ))
            history.append(TestFactories.makeMessage(
                role: .assistant, text: "Answer \(turn): " + String(repeating: "a", count: bytes)
            ))
        }
        return history
    }

    private func makeCompactionFixture(
        contextLength: Int,
        maxOutputTokens: Int,
        messages: [ChatMessage],
        skillPrompt: String? = nil
    ) -> CompactionFixture {
        let providerID = UUID()
        let modelID = "relay-window"
        var model = TestFactories.makeModel(id: modelID, capabilities: [.text], isDefault: true)
        model.contextLength = contextLength
        model.maxOutputTokens = maxOutputTokens
        let provider = Provider(
            id: providerID,
            kind: .relay,
            status: .connected,
            models: [model],
            catalogModels: [],
            apiKey: "relay-key",
            apiKeyPreview: "...key",
            baseURLText: "https://relay.test/v1",
            relayRequested: RelayRequestedConfig(transport: .openaiChatCompletions)
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CompactionURLProtocol.self]
        let state = AppState(
            seedDemoData: false,
            sessionUID: "context-pipeline-compaction-\(UUID().uuidString)",
            providerSession: URLSession(configuration: configuration)
        )
        let stamped = messages.map { message -> ChatMessage in
            var message = message
            message.providerID = providerID
            message.providerKind = .relay
            message.modelID = modelID
            return message
        }
        var conversation = TestFactories.makeConversation(
            providerID: providerID,
            providerKind: .relay,
            modelID: modelID,
            messages: stamped
        )
        conversation.useMemory = false
        if let skillPrompt {
            let skill = Skill(name: "Long skill", systemPrompt: skillPrompt)
            state.skillManager.replaceUserSkills([skill])
            conversation.skillId = skill.id
        }
        state.providers = [provider]
        state.upsertConversationProjection(conversation)
        state.flushConversationPersistQueue()
        return CompactionFixture(state: state, conversationID: conversation.id)
    }

    private func sendCapturing(
        _ fixture: CompactionFixture,
        text: String,
        expecting count: Int = 1
    ) async throws -> [[String: Any]] {
        CompactionURLProtocol.capturedBodies = []
        defer { CompactionURLProtocol.capturedBodies = [] }
        _ = await fixture.state.sendMessage(text, in: fixture.conversationID)
        let deadline = ContinuousClock.now + .seconds(5)
        while CompactionURLProtocol.capturedBodies.count < count, ContinuousClock.now < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        // Let the stream finish so it does not interleave with the next case.
        try? await Task.sleep(nanoseconds: 300_000_000)
        return CompactionURLProtocol.capturedBodies
    }

    private func expectRejected(_ fixture: CompactionFixture, text: String, key: String) async throws {
        let before = fixture.state.conversation(for: fixture.conversationID)?.messages.map(\.id) ?? []
        CompactionURLProtocol.capturedBodies = []
        defer { CompactionURLProtocol.capturedBodies = [] }
        let sent = await fixture.state.sendMessage(text, in: fixture.conversationID)
        try await Task.sleep(nanoseconds: 800_000_000)
        // Returns nil: ChatView uses this to put the input text back.
        #expect(sent == nil)
        #expect(CompactionURLProtocol.capturedBodies.isEmpty)
        let after = fixture.state.conversation(for: fixture.conversationID)?.messages.map(\.id) ?? []
        #expect(after == before)
        #expect(ToastManager.shared.current?.message == L10n.tr(key, table: .chat))
    }

    private struct CompactionWireMessage {
        let role: String
        let text: String
    }

    private static func compactionWireMessages(_ body: [String: Any]) -> [CompactionWireMessage] {
        let raw = body["messages"] as? [[String: Any]] ?? []
        return raw.map { message in
            let role = message["role"] as? String ?? ""
            let text: String
            if let string = message["content"] as? String {
                text = string
            } else if let parts = message["content"] as? [[String: Any]] {
                text = parts.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
                    .joined(separator: "\n")
            } else {
                text = ""
            }
            return CompactionWireMessage(role: role, text: text)
        }
    }
}
