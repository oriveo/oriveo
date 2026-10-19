import Foundation
import OriveoProviderKit
import Testing
@testable import Oriveo

/// Captures the request bodies the production send chain actually emits (each case only takes the first request).
private final class ContextPipelineURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var capturedBody: [String: Any]?
    nonisolated(unsafe) static var requestCount = 0

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requestCount += 1
        if Self.capturedBody == nil, let body = Self.bodyObject(of: request) {
            Self.capturedBody = body
        }
        let url = request.url ?? URL(string: "https://relay.invalid")!
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "text/event-stream"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        // Emit some body text and then finish normally so the answer ends as delivered (memoryItemIds is only persisted on a non-failed finish).
        let sse = "data: {\"choices\":[{\"delta\":{\"content\":\"OK\"}}]}\n\n"
            + "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n"
            + "data: [DONE]\n\n"
        client?.urlProtocol(self, didLoad: Data(sse.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

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

/// Projection and memory: the request bodies for send, retry, regenerate, and send-after-edit are projected from the ContextAssembler plan.
/// Every assertion reads the production request body captured by URLProtocol.
@Suite("Context pipeline chat projection", .serialized)
@MainActor
struct ContextPipelineTests {

    private static let memoryText = "The user prefers green tea."
    private static let modelID = "relay-model"

    /// Injects the memory-item reader. The default fixture is one global fact, which goes into the `<oriveo-memory>` envelope when the conversation switch is on.
    static let memoryFact = memoryItem("mem-tea", .fact, memoryText, createdAt: "2026-01-01T00:00:00Z")

    private static var memorySystem: String {
        let note = ContextAssembler.envelopeNotes["oriveo-memory"] ?? ""
        return "<oriveo-memory>\n<note>\(note)</note>\n<entry>\(memoryText)</entry>\n</oriveo-memory>"
    }

    private static var attachmentGuideBlock: String {
        "<oriveo-attachment-guide>\n\(AttachmentInjector.systemPromptGuidance)\n</oriveo-attachment-guide>"
    }

    // MARK: Cases

    @Test func send_body_system_from_plan() async throws {
        let fixture = try await memoryFixture(messages: [])
        let body = try await capture { _ = await fixture.state.sendMessage("Hello", in: fixture.conversationID) }
        let messages = Self.wireMessages(body)
        #expect(messages.first?.role == "system")
        #expect(messages.first?.text == Self.memorySystem)
        #expect(messages.dropFirst().map(\.role) == ["user"])
        #expect(messages.last?.text == "Hello")
    }

    @Test func send_body_dynamic_block_last() async throws {
        let file = Attachment(
            id: UUID(),
            kind: .file,
            fileName: "notes.txt",
            mimeType: "text/plain",
            base64Data: Data("alpha".utf8).base64EncodedString()
        )
        let fixture = makeFixture(messages: [
            TestFactories.makeMessage(role: .user, text: "Read this", attachments: [file]),
            TestFactories.makeMessage(role: .assistant, text: "Done"),
        ], useMemory: false)
        let body = try await capture { _ = await fixture.state.sendMessage("Next", in: fixture.conversationID) }
        let messages = Self.wireMessages(body)
        // The attachment note is [D]: it stays out of system and is appended to the end of the current user text, separated by a blank line.
        #expect(!messages.contains { $0.role == "system" })
        #expect(messages.last?.role == "user")
        #expect(messages.last?.text == "Next\n\n" + Self.attachmentGuideBlock)
    }

    /// Transport inputs come only from PlannedChatRequest; both system and [D] are written into options by the plan projection.
    @Test func transport_input_carries_plan_system_and_dynamic() throws {
        let file = Attachment(
            id: UUID(),
            kind: .file,
            fileName: "notes.txt",
            mimeType: "text/plain",
            base64Data: Data("alpha".utf8).base64EncodedString()
        )
        let snapshot = ChatRequestSnapshot(
            conversation: ChatRequestConversationSnapshot(id: UUID(), useMemory: true, skillID: nil),
            messages: [TestFactories.makeMessage(role: .user, text: "Read this", attachments: [file])],
            preferences: ChatRequestPreferencesSnapshot(memoryItems: [Self.memoryFact]),
            skill: nil,
            sendPath: .send(excludingMessageID: nil)
        )
        let planned = ChatRequestBuilder.build(from: snapshot, assembly: RetiredAntiForgetProbe.assembly).planned
        var base = ChatRequestOptions()
        base.attachmentConnectionID = UUID()
        let transport = planned.transportInput(base)

        #expect(planned.plan.system == Self.memorySystem)
        #expect(transport.options.systemPrompt == planned.plan.system)
        #expect(transport.options.dynamicText == Self.attachmentGuideBlock)
        #expect(planned.dynamicText == Self.attachmentGuideBlock)
        // The other options pass through unchanged; [D] is still appended to the last user message after a blank line.
        #expect(transport.options.attachmentConnectionID == base.attachmentConnectionID)
        #expect(transport.messages == planned.messages)
        #expect(transport.messages.last?.text == "Read this\n\n" + Self.attachmentGuideBlock)
    }

    @Test func send_body_memory_switch_off() async throws {
        let fixture = try await memoryFixture(messages: [], useMemory: false)
        let body = try await capture { _ = await fixture.state.sendMessage("Hello", in: fixture.conversationID) }
        let messages = Self.wireMessages(body)
        #expect(!messages.contains { $0.role == "system" })
        #expect(!messages.contains { $0.text.contains(Self.memoryText) })
        #expect(messages.map(\.text) == ["Hello"])
    }

    @Test func send_body_unanswered_merged() async throws {
        let fixture = makeFixture(messages: [
            TestFactories.makeMessage(role: .user, text: "First <question>"),
            TestFactories.makeMessage(role: .assistant, text: "boom", state: .failed),
        ], useMemory: false)
        let body = try await capture { _ = await fixture.state.sendMessage("Second", in: fixture.conversationID) }
        let messages = Self.wireMessages(body)
        let envelope = "<oriveo-unanswered>\n<note>\(ContextSanitizer.unansweredNote)</note>\n"
            + "First &lt;question&gt;\n</oriveo-unanswered>"
        #expect(messages.map(\.role) == ["user"])
        #expect(messages.first?.text == envelope + "\n\nSecond")
    }

    @Test func retry_body_from_plan() async throws {
        let failedID = UUID()
        let fixture = try await memoryFixture(messages: [
            TestFactories.makeMessage(role: .user, text: "Question"),
            TestFactories.makeMessage(id: failedID, role: .assistant, text: "boom", state: .failed),
        ])
        let body = try await capture {
            await fixture.state.retryMessage(messageID: failedID, in: fixture.conversationID)
        }
        let messages = Self.wireMessages(body)
        #expect(messages.map(\.role) == ["system", "user"])
        #expect(messages.first?.text == Self.memorySystem)
        #expect(messages.last?.text == "Question")
    }

    @Test func regenerate_body_from_plan() async throws {
        let answerID = UUID()
        let fixture = try await memoryFixture(messages: [
            TestFactories.makeMessage(role: .user, text: "Question"),
            TestFactories.makeMessage(id: answerID, role: .assistant, text: "Old answer"),
        ])
        let body = try await capture {
            await fixture.state.regenerateMessage(messageID: answerID, in: fixture.conversationID)
        }
        let messages = Self.wireMessages(body)
        #expect(messages.map(\.role) == ["system", "user"])
        #expect(messages.first?.text == Self.memorySystem)
        #expect(messages.last?.text == "Question")
    }

    @Test func edit_resend_body_from_plan() async throws {
        let questionID = UUID()
        let fixture = try await memoryFixture(messages: [
            TestFactories.makeMessage(id: questionID, role: .user, text: "Question"),
            TestFactories.makeMessage(role: .assistant, text: "Answer"),
        ])
        let body = try await capture {
            _ = fixture.state.beginEditingUserMessage(messageID: questionID, in: fixture.conversationID)
            _ = await fixture.state.sendMessage("Edited question", in: fixture.conversationID)
        }
        let messages = Self.wireMessages(body)
        #expect(messages.map(\.role) == ["system", "user"])
        #expect(messages.first?.text == Self.memorySystem)
        #expect(messages.last?.text == "Edited question")
    }

    /// The pre-send check and the real send go through the same projection. Two consecutive unanswered user messages each carry attachments (the failed turn in between is dropped),
    /// and the outbound history of the pre-send check matches the build projection message by message in id, role, and attachments.
    @Test func preflight_history_matches_sent_projection() throws {
        let video = Oriveo.Attachment(id: UUID(), kind: .video, fileName: "clip.mp4", mimeType: "video/mp4", base64Data: nil)
        let image = Oriveo.Attachment(id: UUID(), kind: .image, fileName: "photo.png", mimeType: "image/png", base64Data: "aGk=")
        var first = TestFactories.makeMessage(role: .user, text: "First <clip>")
        first.attachments = [video]
        let history = [first, TestFactories.makeMessage(role: .assistant, text: "boom", state: .failed)]

        var preflightInput: [ChatMessage] = []
        var preflightOutput: [ChatMessage] = []
        let hasVideo = ChatManager.preflightHistoryHasVideo(
            history: history, pendingText: "Second", pendingAttachments: [image],
            outboundHistory: { input in
                preflightInput = input
                preflightOutput = ChatRequestBuilder.outboundAttachmentHistory(input, sendPath: .send(excludingMessageID: nil))
                return preflightOutput
            }
        )
        let sent = ChatRequestBuilder.build(from: ChatRequestSnapshot(
            conversation: ChatRequestConversationSnapshot(id: UUID(), useMemory: false, skillID: nil),
            messages: preflightInput, preferences: ChatRequestPreferencesSnapshot(), skill: nil,
            sendPath: .send(excludingMessageID: nil)
        ), assembly: RetiredAntiForgetProbe.assembly).planned.messages

        #expect(hasVideo)
        try #require(sent.count == 1)
        #expect(preflightOutput.map(\.id) == sent.map(\.id))
        #expect(preflightOutput.map(\.role) == sent.map(\.role))
        #expect(preflightOutput.map { $0.attachments?.map(\.id) ?? [] } == sent.map { $0.attachments?.map(\.id) ?? [] })
        #expect(sent.first?.attachments?.map(\.id) == [video.id, image.id])
        let envelope = "<oriveo-unanswered>\n<note>\(ContextSanitizer.unansweredNote)</note>\n"
            + "First &lt;clip&gt;\n</oriveo-unanswered>\n\nSecond"
        #expect(preflightOutput.first?.text == envelope)
        #expect(sent.first?.text.hasPrefix(envelope) == true)
    }

    /// The reject pre-check yields the main thread while assembling in the background; if the conversation is deleted meanwhile, the send must not write back out of bounds or issue a request.
    /// The send task enters the main actor queue first; after a yield it reaches the pre-check's detached suspension point, and then the test continues by deleting the conversation.
    @Test func send_preflight_suspension_conversation_deleted() async throws {
        let fixture = makeFixture(messages: [TestFactories.makeMessage(role: .user, text: "Earlier")])
        ContextPipelineURLProtocol.capturedBody = nil
        defer { ContextPipelineURLProtocol.capturedBody = nil }
        let state = fixture.state
        let conversationID = fixture.conversationID
        let send = Task { await state.sendMessage("Hello", in: conversationID) }
        await Task.yield()
        state.deleteConversation(id: conversationID)
        let sent = await send.value
        #expect(sent == nil)
        #expect(!state.conversations.contains { $0.id == conversationID })
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(ContextPipelineURLProtocol.capturedBody == nil)
    }

    /// Tapping send again on the same conversation while the pre-check is suspended appends only one user message and issues only one request (same as double-tapping before the pre-check suspends).
    @Test func send_double_tap_during_preflight_sends_once() async throws {
        let fixture = makeFixture(messages: [])
        ContextPipelineURLProtocol.capturedBody = nil
        ContextPipelineURLProtocol.requestCount = 0
        defer {
            ContextPipelineURLProtocol.capturedBody = nil
            ContextPipelineURLProtocol.requestCount = 0
        }
        let state = fixture.state
        let conversationID = fixture.conversationID
        let first = Task { await state.sendMessage("Hello", in: conversationID) }
        let second = Task { await state.sendMessage("Hello", in: conversationID) }
        let results = [await first.value, await second.value]
        #expect(results.compactMap { $0 }.count == 1)
        let deadline = ContinuousClock.now + .seconds(5)
        while ContextPipelineURLProtocol.capturedBody == nil, ContinuousClock.now < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        let userCount = state.conversations.first { $0.id == conversationID }?
            .messages.filter { $0.role == .user }.count
        #expect(userCount == 1)
        #expect(ContextPipelineURLProtocol.requestCount == 1)
    }

    // MARK: Memory items

    /// Standing items (instruction / constraint) go into `<oriveo-standing-instructions>` and the rest into `<oriveo-memory>`, each in list order;
    /// only global / this-conversation / this-folder scopes are taken; memoryText is no longer injected. The injected ids are stored on the assistant message in render order and persisted.
    @Test func memoryItemsInjectedAsStandingAndFacts() async throws {
        let conversationID = UUID()
        let folderID = UUID()
        let items = [
            Self.memoryItem("mem-a", .instruction, "Always answer in English.", createdAt: "2026-01-01T00:00:01Z"),
            Self.memoryItem("mem-b", .fact, "The user prefers green tea.", createdAt: "2026-01-01T00:00:02Z"),
            Self.memoryItem(
                "mem-c", .constraint, "Never mention prices.",
                scope: MemoryScope(type: .conversation, id: conversationID.uuidString), createdAt: "2026-01-01T00:00:03Z"
            ),
            Self.memoryItem(
                "mem-d", .project, "Folder project Atlas.",
                scope: MemoryScope(type: .folder, id: folderID.uuidString), createdAt: "2026-01-01T00:00:04Z"
            ),
            Self.memoryItem(
                "mem-e", .fact, "Other conversation fact.",
                scope: MemoryScope(type: .conversation, id: UUID().uuidString), createdAt: "2026-01-01T00:00:05Z"
            ),
            Self.memoryItem(
                "mem-f", .fact, "Other folder fact.",
                scope: MemoryScope(type: .folder, id: UUID().uuidString), createdAt: "2026-01-01T00:00:06Z"
            ),
        ]
        let fixture = try await memoryFixture(
            messages: [], items: items, conversationID: conversationID, folderID: folderID
        )
        fixture.state.preferences.memoryText = "Legacy memory text."
        let body = try await capture { _ = await fixture.state.sendMessage("Hello", in: fixture.conversationID) }
        let messages = Self.wireMessages(body)
        let standing = Self.envelope("oriveo-standing-instructions", ["Always answer in English.", "Never mention prices."])
        let memory = Self.envelope("oriveo-memory", ["The user prefers green tea.", "Folder project Atlas."])
        #expect(messages.map(\.role) == ["system", "user"])
        #expect(messages.first?.text == standing + "\n\n" + memory)
        #expect(!messages.contains { $0.text.contains("Legacy memory text.") })

        let expectedIDs = ["mem-a", "mem-c", "mem-b", "mem-d"]
        let answer = try await settledAnswer(fixture)
        #expect(answer.state == .delivered)
        #expect(answer.memoryItemIds == expectedIDs)
        fixture.state.flushConversationPersistQueue()
        let stored = try fixture.state.conversationRuntimeBridge
            .fetchConversationProjection(id: fixture.conversationID, uid: fixture.uid)?
            .messages.first { $0.id == answer.id }
        #expect(stored?.memoryItemIds == expectedIDs, "the persisted ids are the same set")
    }

    /// With the conversation memory switch off: nothing is injected even if items exist, and the assistant message records no ids.
    @Test func memorySwitchOffNoItems() async throws {
        let fixture = try await memoryFixture(messages: [], useMemory: false, items: [
            Self.memoryItem("mem-a", .instruction, "Always answer in English.", createdAt: "2026-01-01T00:00:01Z"),
            Self.memoryFact,
        ])
        let body = try await capture { _ = await fixture.state.sendMessage("Hello", in: fixture.conversationID) }
        let messages = Self.wireMessages(body)
        #expect(messages.map(\.text) == ["Hello"])
        let answer = try await settledAnswer(fixture)
        #expect(answer.state == .delivered)
        #expect(answer.memoryItemIds.isEmpty)
    }

    /// Paused, conflicting, episodic, and expired items are not injected and record no ids.
    @Test func pausedAndConflictedNotInjected() async throws {
        let fixture = try await memoryFixture(messages: [], items: [
            Self.memoryItem("mem-a", .fact, "Active fact.", createdAt: "2026-01-01T00:00:01Z"),
            Self.memoryItem("mem-b", .fact, "Paused fact.", status: .paused, createdAt: "2026-01-01T00:00:02Z"),
            Self.memoryItem("mem-c", .fact, "Conflicted fact.", status: .conflicted, createdAt: "2026-01-01T00:00:03Z"),
            Self.memoryItem("mem-d", .instruction, "Paused rule.", status: .paused, createdAt: "2026-01-01T00:00:04Z"),
            Self.memoryItem(
                "mem-e", .event, "Episodic event.", layer: .episodic, createdAt: "2026-01-01T00:00:05Z"
            ),
            Self.memoryItem(
                "mem-f", .fact, "Expired fact.", createdAt: "2026-01-01T00:00:06Z", expiresAt: "2020-01-01T00:00:00Z"
            ),
        ])
        let body = try await capture { _ = await fixture.state.sendMessage("Hello", in: fixture.conversationID) }
        let messages = Self.wireMessages(body)
        #expect(messages.first?.text == Self.envelope("oriveo-memory", ["Active fact."]))
        let answer = try await settledAnswer(fixture)
        #expect(answer.memoryItemIds == ["mem-a"])
    }

    // MARK: L3 recall

    /// One episodic item in the store: after retrieval the production send chain puts it into the [D] `<oriveo-recall>` (with a date attribute, without an id), and its id is appended to memoryItemIds.
    @Test func l3RecallRenderedInDynamicBlock() async throws {
        let episodic = MemoryItem(
            id: "30000000-0000-4000-8000-000000000001", layer: .episodic, kind: .decision,
            content: "Decided the saga ends in 1453.", mutationId: "mut-l3", deviceId: "device-test",
            occurredAt: "2026-10-01T09:00:00Z", createdAt: "2026-10-01T09:00:00Z"
        )
        let fixture = try await memoryFixture(messages: [], items: [episodic])
        let body = try await capture {
            _ = await fixture.state.sendMessage("When does the saga end in 1453?", in: fixture.conversationID)
        }
        let messages = Self.wireMessages(body)
        let last = try #require(messages.last)
        #expect(last.role == "user")
        #expect(last.text.contains("<oriveo-recall>"))
        #expect(last.text.contains("<entry date=\"2026-10-01\">Decided the saga ends in 1453.</entry>"))
        #expect(!last.text.contains(episodic.id))
        #expect(!messages.contains { $0.role == "system" && $0.text.contains("1453") })
        let answer = try await settledAnswer(fixture)
        #expect(answer.memoryItemIds == [episodic.id])
    }

    /// With the conversation memory switch off: no retrieval and no envelope.
    @Test func l3RecallOffWhenMemorySwitchOff() async throws {
        let episodic = MemoryItem(
            id: "30000000-0000-4000-8000-000000000002", layer: .episodic, kind: .decision,
            content: "Decided the saga ends in 1453.", mutationId: "mut-l3b", deviceId: "device-test",
            occurredAt: "2026-10-01T09:00:00Z", createdAt: "2026-10-01T09:00:00Z"
        )
        let fixture = try await memoryFixture(messages: [], useMemory: false, items: [episodic])
        let body = try await capture {
            _ = await fixture.state.sendMessage("When does the saga end in 1453?", in: fixture.conversationID)
        }
        #expect(!Self.wireMessages(body).contains { $0.text.contains("<oriveo-recall>") })
    }

    // MARK: Fixtures

    struct Fixture {
        let state: AppState
        let conversationID: UUID
        var uid: String = ""
    }

    static func memoryItem(
        _ id: String,
        _ kind: MemoryKind,
        _ content: String,
        status: MemoryStatus = .active,
        layer: MemoryLayer = .semantic,
        scope: MemoryScope = .global,
        createdAt: String,
        expiresAt: String? = nil
    ) -> MemoryItem {
        MemoryItem(
            id: id, layer: layer, kind: kind, status: status, content: content, scope: scope,
            mutationId: "mut-\(id)", deviceId: "device-test", createdAt: createdAt, expiresAt: expiresAt
        )
    }

    static func envelope(_ tag: String, _ entries: [String]) -> String {
        let note = ContextAssembler.envelopeNotes[tag] ?? ""
        return "<\(tag)>\n<note>\(note)</note>\n" + entries.map { "<entry>\($0)</entry>" }.joined(separator: "\n") + "\n</\(tag)>"
    }

    /// Fixture with memory items: first tombstone the existing items in the partition (possibly migrated from shared preferences), then write the given items,
    /// and wait for the AppState item cache (delivered asynchronously by the database observation) to switch to this set.
    func memoryFixture(
        messages: [ChatMessage],
        useMemory: Bool = true,
        items: [MemoryItem] = [ContextPipelineTests.memoryFact],
        conversationID: UUID = UUID(),
        folderID: UUID? = nil
    ) async throws -> Fixture {
        let fixture = makeFixture(
            messages: messages, useMemory: useMemory, conversationID: conversationID, folderID: folderID
        )
        try await Self.seedMemory(fixture.state, items)
        return fixture
    }

    /// Writes the items into the partition database observed by the AppState item cache (tombstoning the other live items) and waits for the cache to switch to this set.
    /// If the cache is not yet bound to a partition (an AppState with seedDemoData), bind a test-only partition first.
    static func seedMemory(_ state: AppState, _ items: [MemoryItem]) async throws {
        if state.memoryItemsCache.uid == nil {
            state.memoryItemsCache.bind(uid: "memory-test-\(UUID().uuidString)")
        }
        let uid = try #require(state.memoryItemsCache.uid)
        let store = try #require(MemoryItemStore.forPartition(uid))
        let keep = Set(items.map(\.id))
        let stale = try store.all().filter { $0.status != .deleted && !keep.contains($0.id) }
        try store.upsert(stale.map {
            MemoryItems.tombstone($0, mutationId: "tomb-\($0.id)", deviceId: "device-test", deletedAt: "2026-01-01T00:00:00Z")
        }, syncState: .synced)
        try store.upsert(items, syncState: .synced)
        func cached() -> [String] { state.memoryItemsCache.items.map { "\($0.id)|\($0.content)" }.sorted() }
        let expected = items.filter { $0.status != .deleted }.map { "\($0.id)|\($0.content)" }.sorted()
        let deadline = ContinuousClock.now + .seconds(5)
        while cached() != expected, ContinuousClock.now < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        try #require(cached() == expected, "memory cache not refreshed")
    }

    /// Waits for this conversation's answer to finish and returns the last assistant message.
    func settledAnswer(_ fixture: Fixture) async throws -> ChatMessage {
        let deadline = ContinuousClock.now + .seconds(5)
        func answer() -> ChatMessage? {
            fixture.state.conversation(for: fixture.conversationID)?.messages.last { $0.role == .assistant }
        }
        while answer()?.state == .generating || fixture.state.chatManager.isBusyStreaming(in: fixture.conversationID),
              ContinuousClock.now < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        return try #require(answer())
    }

    func makeFixture(
        messages: [ChatMessage],
        useMemory: Bool = true,
        instructions: String = "",
        conversationID: UUID = UUID(),
        folderID: UUID? = nil
    ) -> Fixture {
        let providerID = UUID()
        let model = TestFactories.makeModel(id: Self.modelID, capabilities: [.text], isDefault: true)
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
        let uid = "context-pipeline-\(UUID().uuidString)"
        let state = AppState(
            seedDemoData: false,
            sessionUID: uid,
            providerSession: Self.session()
        )
        let stamped = messages.map { message -> ChatMessage in
            var message = message
            message.providerID = providerID
            message.providerKind = .relay
            message.modelID = Self.modelID
            return message
        }
        var conversation = TestFactories.makeConversation(
            id: conversationID,
            providerID: providerID,
            providerKind: .relay,
            modelID: Self.modelID,
            messages: stamped
        )
        conversation.useMemory = useMemory
        conversation.instructions = instructions
        conversation.folderID = folderID
        state.providers = [provider]
        state.upsertConversationProjection(conversation)
        return Fixture(state: state, conversationID: conversation.id, uid: uid)
    }

    private static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ContextPipelineURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    /// [D] takes effect in every protocol family: following AnthropicCacheBreakpointTests, each native Service sends once through the production mapTurns,
    /// and the request body is captured. Extracted file text is injected before [D]; [D] appears exactly once and is the last segment of its text part (Anthropic splits it into a separate final block).
    @Test func directive_marker_applies_to_every_family() async throws {
        let dynamic = "<oriveo-attachment-guide>\nDYNAMIC-MARKER\n</oriveo-attachment-guide>"
        let content = "Quarterly numbers: 42."
        let file = Attachment(
            id: UUID(), kind: .file, fileName: "notes.txt", mimeType: "text/plain",
            base64Data: Data(content.utf8).base64EncodedString(), extractedSizeBytes: content.utf8.count
        )
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ContextPipelineURLProtocol.self]
        let services = ProviderServiceRouter.Services(session: URLSession(configuration: config))
        var covered: [ProviderKind] = []
        for kind in ProviderKind.allCases {
            guard let service = services.native(for: kind) else { continue }
            var options = ChatRequestOptions(systemPrompt: "System.")
            options.dynamicText = dynamic
            let messages = [
                TestFactories.makeMessage(role: .user, text: "First"),
                TestFactories.makeMessage(role: .assistant, text: "Done"),
                TestFactories.makeMessage(role: .user, text: "Summarize the file.\n\n" + dynamic, attachments: [file]),
            ]
            ContextPipelineURLProtocol.capturedBody = nil
            do {
                for try await _ in service.sendMessageStream(
                    apiKey: "sk-test", modelID: "test-model", messages: messages, requestOptions: options
                ) {}
            } catch {
                // Only the outgoing request body matters
            }
            let body = try #require(ContextPipelineURLProtocol.capturedBody, "\(kind) issued no request")
            ContextPipelineURLProtocol.capturedBody = nil
            let strings = Self.leafStrings(body)
            let carriers = strings.filter { $0.contains("DYNAMIC-MARKER") }
            #expect(carriers.count == 1, "\(kind): [D] must appear exactly once")
            guard let carrier = carriers.first else { continue }
            #expect(carrier == dynamic || carrier.hasSuffix("\n\n" + dynamic), "\(kind): [D] must be the last segment")
            let contentCarrier = try #require(strings.first { $0.contains(content) }, "\(kind): file text missing")
            if contentCarrier == carrier {
                let contentRange = try #require(carrier.range(of: content))
                let dynamicRange = try #require(carrier.range(of: dynamic))
                #expect(contentRange.upperBound <= dynamicRange.lowerBound, "\(kind): file text must precede [D]")
            } else {
                // Families that split it into a separate final block: the body block excludes [D], and the [D] block is D itself.
                #expect(carrier == dynamic, "\(kind): split [D] block must be D itself")
                #expect(contentCarrier.hasPrefix("Summarize the file."), "\(kind)")
            }
            // History turns carry no [D].
            #expect(!strings.contains { $0.contains("First") && $0.contains("DYNAMIC-MARKER") }, "\(kind)")
            covered.append(kind)
        }
        #expect(covered.count == ProviderKind.allCases.count, "every native family covered: \(covered)")
    }

    /// All string leaves in the request body (keys excluded).
    static func leafStrings(_ value: Any) -> [String] {
        if let text = value as? String { return [text] }
        if let array = value as? [Any] { return array.flatMap(leafStrings) }
        if let object = value as? [String: Any] { return object.values.flatMap(leafStrings) }
        return []
    }

    func capture(_ action: () async -> Void) async throws -> [String: Any] {
        ContextPipelineURLProtocol.capturedBody = nil
        defer { ContextPipelineURLProtocol.capturedBody = nil }
        await action()
        let deadline = ContinuousClock.now + .seconds(5)
        while ContextPipelineURLProtocol.capturedBody == nil, ContinuousClock.now < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let body = try #require(ContextPipelineURLProtocol.capturedBody, "send pipeline issued no request")
        // Let the stream finish so the next case does not interleave with this one's conversation teardown.
        try? await Task.sleep(nanoseconds: 300_000_000)
        return body
    }

    struct WireMessage {
        let role: String
        let text: String
    }

    /// OpenAI chat shape: content is a string, or a text part in the parts array.
    static func wireMessages(_ body: [String: Any]) -> [WireMessage] {
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
            return WireMessage(role: role, text: text)
        }
    }
}
