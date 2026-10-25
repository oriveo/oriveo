import Foundation
import Testing
@testable import Oriveo
import OriveoProviderKit

final class AppStateSendMessageURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    /// Request ownership guard: every stubbed URLSession carries an owner header; on entry (suite init) the owner set is cleared,
    /// and the sessions created by this case are registered afterwards. A late request from a previous case's send task (e.g. the first propose_memory leg) carries a stale owner,
    /// so it is recorded as an issue and failed outright instead of being fed to the current case's stub.
    static let ownerHeader = "X-Oriveo-Test-Owner"
    private static let ownerLock = NSLock()
    nonisolated(unsafe) private static var currentOwners: Set<String> = []
    nonisolated(unsafe) private static var currentSessions: [URLSession] = []

    /// On entry: invalidate the previous case's owner and invalidateAndCancel the sessions it created.
    /// Report first: an unfinished task on an old session means the previous case did not wait for its teardown; record an issue (with the URL and the last tool),
    /// so that invalidating does not silently hide the leak.
    static func beginTestOwnership() async {
        let stale = ownerLock.withLock {
            currentOwners.removeAll()
            defer { currentSessions.removeAll() }
            return currentSessions
        }
        for session in stale {
            for task in await session.allTasks where task.state != .completed {
                let request = task.originalRequest
                Issue.record("""
                Previous test left an unfinished request: \
                url=\(request?.url?.absoluteString ?? "nil") \
                lastTool=\(request.flatMap { lastToolName(in: $0) } ?? "nil")
                """)
            }
            session.invalidateAndCancel()
        }
    }

    static func track(_ session: URLSession) {
        ownerLock.withLock { currentSessions.append(session) }
    }

    static func registerOwner() -> String {
        let owner = UUID().uuidString
        ownerLock.withLock { _ = currentOwners.insert(owner) }
        return owner
    }

    private static func isCurrentOwner(_ owner: String?) -> Bool {
        guard let owner else { return false }
        return ownerLock.withLock { currentOwners.contains(owner) }
    }

    /// Fingerprint of a late request: the name of the last tool in the request body (propose_memory means the first leg arrived late).
    static func lastToolName(in request: URLRequest) -> String? {
        guard let body = appStateSendMessageRequestBody(from: request),
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let tools = json["tools"] as? [[String: Any]],
              let last = tools.last else { return nil }
        if let function = last["function"] as? [String: Any], let name = function["name"] as? String {
            return name
        }
        return last["name"] as? String
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let owner = request.value(forHTTPHeaderField: Self.ownerHeader)
        guard Self.isCurrentOwner(owner) else {
            Issue.record("""
            Request does not belong to the current test: owner=\(owner ?? "nil") \
            url=\(request.url?.absoluteString ?? "nil") lastTool=\(Self.lastToolName(in: request) ?? "nil")
            """)
            client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
            return
        }
        guard let handler = AppStateSendMessageURLProtocol.requestHandler else {
            // Fail outright when no stub is installed: finishing without a response traps async URLSession.data(for:) and crashes the whole test host.
            client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private func registerAppStateSendMessageMock() {
    AppStateSendMessageURLProtocol.requestHandler = nil
}

private func unregisterAppStateSendMessageMock() {
    AppStateSendMessageURLProtocol.requestHandler = nil
}

private func appStateSendMessageSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [AppStateSendMessageURLProtocol.self]
    configuration.httpAdditionalHeaders = [
        AppStateSendMessageURLProtocol.ownerHeader: AppStateSendMessageURLProtocol.registerOwner()
    ]
    let session = URLSession(configuration: configuration)
    AppStateSendMessageURLProtocol.track(session)
    return session
}

private func appStateSendMessageHTTPResponse(
    url: URL,
    statusCode: Int,
    headers: [String: String]? = nil
) -> HTTPURLResponse {
    HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: nil, headerFields: headers)!
}

private func appStateSendMessageRequestBody(from request: URLRequest) -> Data? {
    if let body = request.httpBody {
        return body
    }

    guard let stream = request.httpBodyStream else { return nil }
    stream.open()
    defer { stream.close() }

    let bufferSize = 1_024
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
    defer { buffer.deallocate() }

    var data = Data()
    while stream.hasBytesAvailable {
        let read = stream.read(buffer, maxLength: bufferSize)
        guard read > 0 else { break }
        data.append(buffer, count: read)
    }
    return data.isEmpty ? nil : data
}

@Suite("AppState sendMessage", .serialized, .sharedProcessState)
@MainActor
struct AppStateSendMessageTests {

    init() async {
        // One fresh instance per case: entering it invalidates the previous case's session owner, and late requests are recorded as issues by the stub guard.
        await AppStateSendMessageURLProtocol.beginTestOwnership()
    }

    private func loadRelayReasoningEvidence() async throws {
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(json: """
        {
          "version": 1,
          "updatedAt": "2026-08-09T00:00:00Z",
          "profiles": {
            "reasoning": {
              "relay_reasoning_retry_test": {
                "transport": "openai_responses",
                "levels": ["max"],
                "params": { "max": { "reasoning_effort": "xhigh" } }
              }
            },
            "webSearch": {},
            "imageGen": {}
          },
          "providers": {}
        }
        """, metadataETag: "relay-reasoning-retry-etag")
    }

    private func relayReasoningRetryModel() -> AIModel {
        var model = TestFactories.makeModel(
            id: "gpt-5.4",
            name: "GPT-5.4",
            capabilities: [.text, .reasoning],
            reasoningModeAvailable: true,
            isDefault: true
        )
        model.reasoningProfile = "relay_reasoning_retry_test"
        return model
    }

    @MainActor
    private func makeIsolatedAppState(
        prefix: String = "app-state-send-message-"
    ) -> AppState {
        AppState(
            seedDemoData: false,
            sessionUID: "\(prefix)\(UUID().uuidString)",
            providerSession: appStateSendMessageSession()
        )
    }

    private func waitUntil(
        timeoutNanoseconds: UInt64 = 3_000_000_000,
        intervalNanoseconds: UInt64 = 20_000_000,
        condition: @MainActor @escaping () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + .nanoseconds(Int64(timeoutNanoseconds))
        while await condition() == false {
            if ContinuousClock.now >= deadline {
                Issue.record("Timed out waiting for condition")
                return
            }
            try await Task.sleep(nanoseconds: intervalNanoseconds)
        }
    }

    /// Wait for every conversation's send task to finish: the streaming session stays until the propose_memory first leg / last leg / degraded resend all end,
    /// so checking only that messages are not generating would release before the first leg finishes and let a late request leak into the next case's stub.
    /// Teardown requests after the session is gone (the catalog refresh after a failure) are blocked when the next case invalidates this case's session on entry.
    private func waitForSendsToSettle(_ state: AppState) async throws {
        try await waitUntil(timeoutNanoseconds: 10_000_000_000) {
            !state.chatManager.isAnyStreaming
                && !state.conversations.contains { $0.messages.contains { $0.state == .generating } }
        }
    }

    @Test("When an existing conversation's provider is removed and there is no fallback, sendMessage returns nil (no longer pretends to succeed)")
    func existingConversationWithMissingProviderReturnsNil() async throws {
        let state = AppState(seedDemoData: true)
        let conversationID = try #require(state.conversations.first?.id)

        state.providers = []

        // With the provider removed and no usable provider to fall back to, sendMessage short-circuits and returns nil
        // and ChatManager shows a send-refused toast (see ChatManager.providerMissingMessage),
        // instead of pretending to succeed and returning the conversationID.
        let returnedID = await state.sendMessage("Hello", in: conversationID)

        #expect(returnedID == nil)
    }

    @Test("Sending is refused when the conversation's connection was deleted, and the conversation's provider / model are not rewritten")
    func sendToRemovedConnectionRefusesWithoutRewritingSelection() async {
        let state = makeIsolatedAppState(prefix: "repair-selection-")
        let fallbackProvider = TestFactories.makeProvider(
            kind: .openAI,
            models: [
                TestFactories.makeModel(
                    id: "gpt-4o",
                    name: "GPT-4o",
                    isDefault: true,
                    canonicalModelId: "gpt-4o"
                )
            ]
        )
        let deletedID = UUID()
        let conversation = TestFactories.makeConversation(
            providerID: deletedID,
            modelID: "missing-model"
        )

        state.providers = [fallbackProvider]
        state.upsertConversationProjection(conversation)

        let outcome = await state.sendMessageOutcome("Hello", in: conversation.id)

        #expect(outcome == .refused)
        let stored = state.conversation(for: conversation.id)
        #expect(stored?.providerID == deletedID)
        #expect(stored?.modelID == "missing-model")
    }

    @Test("Connection temporarily unavailable: a BYOK connection that is not loaded refuses to send, with a 5 second warning toast offering Choose model, and the conversation is not rewritten")
    func pendingConnectionRefusesWithKindSpecificReason() async throws {
        let byokID = UUID()
        let chooseModel = L10n.tr(ChatModelRemovedBanner.actionKey, table: .chat)
        let cases: [(providerID: UUID, kind: ProviderKind, modelID: String, message: String, actionTitle: String?)] = [
            (byokID, .openAI, "gpt-5.5",
             L10n.tr("Select Model", table: .home), chooseModel),
        ]
        for item in cases {
            let state = makeIsolatedAppState(prefix: "pending-connection-")
            let conversation = TestFactories.makeConversation(
                providerID: item.providerID,
                providerKind: item.kind,
                modelID: item.modelID
            )
            state.upsertConversationProjection(conversation)

            let outcome = await state.sendMessageOutcome("Hello", in: conversation.id)

            #expect(outcome == .refused)
            #expect(ToastManager.shared.current?.message == item.message)
            #expect(ToastManager.shared.current?.actionTitle == item.actionTitle)
            #expect(ToastManager.shared.current?.style == .warning)
            #expect(ToastManager.shared.currentDuration == 5)
            if item.actionTitle != nil {
                // Tapping "Choose model": the active window's navigation receives one request to open the model picker.
                let before = state.navigation.modelPickerRequest
                ToastManager.shared.performCurrentAction()
                #expect(state.navigation.modelPickerRequest == before &+ 1)
            }
            let stored = try #require(state.conversation(for: conversation.id))
            #expect(stored.providerID == item.providerID)
            #expect(stored.providerKind == item.kind)
            #expect(stored.modelID == item.modelID)
        }
    }

    /// A hardware Return and the send button fire a send in the same frame: only one round of messages is created; the later one reports "blocked while sending",
    /// and the composer does not restore its text for it (only a rejected send restores).
    @Test func hardware_return_and_button_same_frame_sends_once() async throws {
        registerAppStateSendMessageMock()
        defer {
            AppStateSendMessageURLProtocol.requestHandler = nil
            unregisterAppStateSendMessageMock()
        }
        AppStateSendMessageURLProtocol.requestHandler = { request in
            (
                appStateSendMessageHTTPResponse(url: request.url!, statusCode: 503),
                Data()
            )
        }

        let state = makeIsolatedAppState(prefix: "same-frame-send-")
        let provider = TestFactories.makeProvider(
            kind: .openAI,
            models: [TestFactories.makeModel(id: "model-a", name: "Model A", isDefault: true)]
        )
        let conversation = TestFactories.makeConversation(
            providerID: provider.id,
            providerKind: provider.kind,
            modelID: "model-a"
        )
        state.providers = [provider]
        state.upsertConversationProjection(conversation)

        async let viaReturn = state.sendMessageOutcome("Hello", in: conversation.id)
        async let viaButton = state.sendMessageOutcome("Hello", in: conversation.id)
        let outcomes = await [viaReturn, viaButton]

        #expect(outcomes.filter { $0 == .sent(conversation.id) }.count == 1)
        #expect(outcomes.filter { $0 == .blockedWhileSending }.count == 1)
        let updated = try #require(state.conversation(for: conversation.id))
        #expect(updated.messages.filter { $0.role == .user }.count == 1)
        #expect(updated.messages.count == 2)

        try await waitForSendsToSettle(state)
    }

    /// Double send in the same frame for a new conversation (in: nil): the composer's in-flight gate creates only one conversation and one round of messages; the later one reports "blocked while sending".
    @Test func new_conversation_same_frame_sends_once() async throws {
        registerAppStateSendMessageMock()
        defer {
            AppStateSendMessageURLProtocol.requestHandler = nil
            unregisterAppStateSendMessageMock()
        }
        AppStateSendMessageURLProtocol.requestHandler = { request in
            (
                appStateSendMessageHTTPResponse(url: request.url!, statusCode: 503),
                Data()
            )
        }

        let state = makeIsolatedAppState(prefix: "same-frame-new-conversation-")
        let provider = TestFactories.makeProvider(
            kind: .openAI,
            models: [TestFactories.makeModel(id: "model-a", name: "Model A", isDefault: true)]
        )
        state.providers = [provider]
        state.setActiveModel(providerID: provider.id, modelID: "model-a")

        let gate = ComposerSendGate()
        async let viaReturn = gate.send { await state.sendMessageOutcome("Hello", in: nil) }
        async let viaButton = gate.send { await state.sendMessageOutcome("Hello", in: nil) }
        let outcomes = await [viaReturn, viaButton]

        #expect(outcomes.filter { $0.sentID != nil }.count == 1)
        #expect(outcomes.filter { $0 == .blockedWhileSending }.count == 1)
        #expect(state.conversations.count == 1)
        #expect(state.conversations.first?.messages.filter { $0.role == .user }.count == 1)

        try await waitForSendsToSettle(state)
    }

    @Test("Sending after switching the model of an existing conversation writes the new model into this turn's messages")
    func existingConversationSendUsesSelectedModelAfterSwitch() async throws {
        registerAppStateSendMessageMock()
        defer {
            AppStateSendMessageURLProtocol.requestHandler = nil
            unregisterAppStateSendMessageMock()
        }
        AppStateSendMessageURLProtocol.requestHandler = { request in
            (
                appStateSendMessageHTTPResponse(url: request.url!, statusCode: 503),
                Data()
            )
        }

        let state = makeIsolatedAppState(prefix: "switch-model-send-")
        let provider = TestFactories.makeProvider(
            kind: .openAI,
            models: [
                TestFactories.makeModel(id: "model-a", name: "Model A", isDefault: true),
                TestFactories.makeModel(id: "model-b", name: "Model B")
            ]
        )
        let conversation = TestFactories.makeConversation(
            providerID: provider.id,
            providerKind: provider.kind,
            modelID: "model-a"
        )
        state.providers = [provider]
        state.upsertConversationProjection(conversation)

        state.selectModel(modelID: "model-b", providerID: provider.id, for: conversation.id)
        let returnedID = await state.sendMessage("Hello after switching", in: conversation.id)

        let updated = try #require(state.conversation(for: conversation.id))
        #expect(returnedID == conversation.id)
        #expect(updated.modelID == "model-b")
        #expect(updated.messages.count == 2)
        #expect(updated.messages.allSatisfy { $0.modelID == "model-b" })

        try await waitForSendsToSettle(state)
    }

    @Test("Every actual send in an existing conversation records the last used connection + model")
    func existingConversationSendWritesLastUsed() async throws {
        registerAppStateSendMessageMock()
        defer {
            AppStateSendMessageURLProtocol.requestHandler = nil
            unregisterAppStateSendMessageMock()
        }
        AppStateSendMessageURLProtocol.requestHandler = { request in
            (
                appStateSendMessageHTTPResponse(url: request.url!, statusCode: 503),
                Data()
            )
        }

        let state = makeIsolatedAppState(prefix: "send-writes-last-used-")
        let provider = TestFactories.makeProvider(
            kind: .openAI,
            models: [
                TestFactories.makeModel(id: "model-a", name: "Model A", isDefault: true),
                TestFactories.makeModel(id: "model-b", name: "Model B")
            ]
        )
        let conversation = TestFactories.makeConversation(
            providerID: provider.id,
            providerKind: provider.kind,
            modelID: "model-b"
        )
        state.providers = [provider]
        state.upsertConversationProjection(conversation)
        state.lastUsedModelRef = LastUsedModelRef(providerID: provider.id, modelID: "model-a")

        let returnedID = await state.sendMessage("Hello", in: conversation.id)

        #expect(returnedID == conversation.id)
        #expect(state.lastUsedModelRef == LastUsedModelRef(providerID: provider.id, modelID: "model-b"))

        try await waitForSendsToSettle(state)
    }

    @Test("Qwen3.6 Plus still completes a text conversation after a long reasoning_content")
    func qwenSendMessageSurvivesReasoningOnlyChunksBeforeFinalContent() async throws {
        registerAppStateSendMessageMock()
        defer {
            AppStateSendMessageURLProtocol.requestHandler = nil
            unregisterAppStateSendMessageMock()
        }

        var requestedModelID: String?
        var requestedStream: Bool?
        AppStateSendMessageURLProtocol.requestHandler = { request in
            let url = try #require(request.url)
            #expect(url.absoluteString == "https://dashscope-intl.aliyuncs.com/compatible-mode/v1/chat/completions")

            if let body = appStateSendMessageRequestBody(from: request),
               let json = try JSONSerialization.jsonObject(with: body) as? [String: Any] {
                requestedModelID = json["model"] as? String
                requestedStream = json["stream"] as? Bool
            }

            let responseBody = """
            data: {"choices":[{"delta":{"content":null,"role":"assistant","reasoning_content":""},"index":0,"finish_reason":null}]}
            data: {"choices":[{"delta":{"content":null,"reasoning_content":"Here"},"index":0,"finish_reason":null}]}
            data: {"choices":[{"delta":{"content":null,"reasoning_content":"'s a thinking process"},"index":0,"finish_reason":null}]}
            data: {"choices":[{"delta":{"content":"\u{4F60}\u{597D}"},"index":0,"finish_reason":null}]}
            data: {"choices":[{"delta":{"content":"\u{FF01}\u{6709}\u{4EC0}\u{4E48}\u{6211}\u{53EF}\u{4EE5}\u{5E2E}"},"index":0,"finish_reason":null}]}
            data: {"choices":[{"delta":{"content":"\u{4F60}\u{7684}\u{5417}\u{FF1F}"},"index":0,"finish_reason":null}]}
            data: {"usage":{"prompt_tokens":8,"completion_tokens":12}}
            data: [DONE]

            """

            return (
                appStateSendMessageHTTPResponse(
                    url: url,
                    statusCode: 200,
                    headers: ["Content-Type": "text/event-stream"]
                ),
                Data(responseBody.utf8)
            )
        }

        let state = makeIsolatedAppState(prefix: "qwen-reasoning-stream-")
        let qwenProvider = TestFactories.makeProvider(
            kind: .qwen,
            models: [
                TestFactories.makeModel(
                    id: "qwen3.6-plus",
                    name: "Qwen3.6 Plus",
                    capabilities: [.text, .reasoning],
                    reasoningModeAvailable: true,
                    isDefault: true,
                    canonicalModelId: "qwen3.6-plus"
                )
            ]
        )
        state.providers = [qwenProvider]
        state.setActiveModel(providerID: qwenProvider.id, modelID: "qwen3.6-plus")

        let conversationID = try #require(await state.sendMessage("\u{4F60}\u{597D}", in: nil))

        try await waitUntil {
            guard let conversation = state.conversation(for: conversationID),
                  let assistant = conversation.messages.last(where: { $0.role == .assistant }) else {
                return false
            }
            return assistant.state != .generating
        }
        try await waitForSendsToSettle(state)

        let conversation = try #require(state.conversation(for: conversationID))
        let assistant = try #require(conversation.messages.last(where: { $0.role == .assistant }))
        #expect(requestedModelID == "qwen3.6-plus")
        #expect(requestedStream == true)
        #expect(assistant.state == .delivered)
        #expect(assistant.text == "\u{4F60}\u{597D}\u{FF01}\u{6709}\u{4EC0}\u{4E48}\u{6211}\u{53EF}\u{4EE5}\u{5E2E}\u{4F60}\u{7684}\u{5417}\u{FF1F}")
        #expect(assistant.errorTitle == nil)
        #expect(assistant.errorDetail == nil)
    }

    @Test("Relay Claude with an explicit transport uses /messages and x-api-key by default")
    func relayAnthropicExplicitTransportUsesMessagesEndpoint() async throws {
        registerAppStateSendMessageMock()
        defer {
            AppStateSendMessageURLProtocol.requestHandler = nil
            unregisterAppStateSendMessageMock()
        }

        var capturedRequest: URLRequest?
        AppStateSendMessageURLProtocol.requestHandler = { request in
            let url = try #require(request.url)
            capturedRequest = request
            let responseBody = """
            event: message_start
            data: {"message":{"usage":{"input_tokens":5}}}

            event: content_block_delta
            data: {"delta":{"type":"text_delta","text":"hello"}}

            event: message_delta
            data: {"usage":{"output_tokens":3}}
            """

            return (
                appStateSendMessageHTTPResponse(
                    url: url,
                    statusCode: 200,
                    headers: ["Content-Type": "text/event-stream"]
                ),
                Data(responseBody.utf8)
            )
        }

        let state = makeIsolatedAppState(prefix: "relay-anthropic-stream-")
        var relayProvider = TestFactories.makeProvider(
            kind: .relay,
            models: [
                TestFactories.makeModel(
                    id: "claude-sonnet-4-5",
                    name: "Claude Sonnet 4.5",
                    capabilities: [.text],
                    isDefault: true
                )
            ],
            catalogModels: [
                TestFactories.makeModel(
                    id: "claude-sonnet-4-5",
                    name: "Claude Sonnet 4.5",
                    capabilities: [.text],
                    isDefault: true
                )
            ],
            apiKey: "relay-key",
            apiKeyPreview: "relay...",
            baseURLText: "https://relay.example.com",
            customName: "Claude Relay"
        )
        relayProvider.relayRequested = RelayRequestedConfig(
            transport: .anthropicMessages,
            authMode: .auto,
            modelID: "claude-sonnet-4-5"
        )
        state.providers = [relayProvider]
        state.setActiveModel(providerID: relayProvider.id, modelID: "claude-sonnet-4-5")

        let conversationID = try #require(await state.sendMessage("Hello", in: nil))

        try await waitUntil {
            guard let conversation = state.conversation(for: conversationID),
                  let assistant = conversation.messages.last(where: { $0.role == .assistant }) else {
                return false
            }
            return assistant.state != .generating
        }
        try await waitForSendsToSettle(state)

        let request = try #require(capturedRequest)
        #expect(request.url?.path == "/v1/messages")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "relay-key")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test("Relay Gemini with an explicit transport uses generateContent and x-goog-api-key by default")
    func relayGeminiExplicitTransportUsesGenerateContentEndpoint() async throws {
        registerAppStateSendMessageMock()
        defer {
            AppStateSendMessageURLProtocol.requestHandler = nil
            unregisterAppStateSendMessageMock()
        }

        var capturedRequest: URLRequest?
        AppStateSendMessageURLProtocol.requestHandler = { request in
            let url = try #require(request.url)
            capturedRequest = request
            let responseBody = """
            data: {"candidates":[{"content":{"parts":[{"text":"hello"}]}}],"usageMetadata":{"promptTokenCount":7,"candidatesTokenCount":3}}

            """

            return (
                appStateSendMessageHTTPResponse(
                    url: url,
                    statusCode: 200,
                    headers: ["Content-Type": "text/event-stream"]
                ),
                Data(responseBody.utf8)
            )
        }

        let state = makeIsolatedAppState(prefix: "relay-gemini-stream-")
        var relayProvider = TestFactories.makeProvider(
            kind: .relay,
            models: [
                TestFactories.makeModel(
                    id: "gemini-2.5-pro",
                    name: "Gemini 2.5 Pro",
                    capabilities: [.text],
                    isDefault: true
                )
            ],
            catalogModels: [
                TestFactories.makeModel(
                    id: "gemini-2.5-pro",
                    name: "Gemini 2.5 Pro",
                    capabilities: [.text],
                    isDefault: true
                )
            ],
            apiKey: "goog-key",
            apiKeyPreview: "goog...",
            baseURLText: "https://relay.example.com",
            customName: "Gemini Relay"
        )
        relayProvider.relayRequested = RelayRequestedConfig(
            transport: .geminiGenerateContent,
            authMode: .auto,
            modelID: "gemini-2.5-pro"
        )
        state.providers = [relayProvider]
        state.setActiveModel(providerID: relayProvider.id, modelID: "gemini-2.5-pro")

        let conversationID = try #require(await state.sendMessage("Hello", in: nil))

        try await waitUntil {
            guard let conversation = state.conversation(for: conversationID),
                  let assistant = conversation.messages.last(where: { $0.role == .assistant }) else {
                return false
            }
            return assistant.state != .generating
        }
        try await waitForSendsToSettle(state)

        let request = try #require(capturedRequest)
        let url = try #require(request.url)
        #expect(url.path == "/v1beta/models/gemini-2.5-pro:streamGenerateContent")
        #expect(url.query?.contains("alt=sse") == true)
        #expect(url.query?.contains("key=") != true)
        #expect(request.value(forHTTPHeaderField: "x-goog-api-key") == "goog-key")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    // Phase 09 v3: RelayImageRoute is derived statically from the transport
    //  - openai_responses -> inline tool path (/responses + tools + automatically picks a chat driver)
    //  - openai_chat_completions -> the standalone /images/generations endpoint
    //  - anthropic_messages -> a friendly error (no request is sent)
    //  - gemini_generate_content -> native responseModalities (no standalone path)
    //
    // The three tests below plus the fixtures in RelayRuntimeRoutingTests cover the whole matrix.

    @Test("Relay + openai_chat_completions transport + imageGen → /v1/images/generations")
    func relayImageGenRoutesToImagesEndpointOnChatCompletions() async throws {
        registerAppStateSendMessageMock()
        defer {
            AppStateSendMessageURLProtocol.requestHandler = nil
            unregisterAppStateSendMessageMock()
        }

        var capturedRequest: URLRequest?
        AppStateSendMessageURLProtocol.requestHandler = { request in
            let url = try #require(request.url)
            capturedRequest = request
            return (
                appStateSendMessageHTTPResponse(
                    url: url,
                    statusCode: 200,
                    headers: ["Content-Type": "application/json"]
                ),
                Data(
                    """
                    {
                      "data": [ {"b64_json": "AAAACATIMG"} ],
                      "usage": {"input_tokens": 4, "output_tokens": 0}
                    }
                    """.utf8
                )
            )
        }

        let state = makeIsolatedAppState(prefix: "relay-imagegen-chat-")
        var relayProvider = TestFactories.makeProvider(
            kind: .relay,
            models: [
                TestFactories.makeModel(
                    id: "gpt-image-2",
                    name: "gpt-image-2",
                    capabilities: [.text, .imageGen],
                    isDefault: true
                )
            ],
            catalogModels: [
                TestFactories.makeModel(
                    id: "gpt-image-2",
                    name: "gpt-image-2",
                    capabilities: [.text, .imageGen],
                    isDefault: true
                )
            ],
            apiKey: "relay-key",
            apiKeyPreview: "relay...",
            baseURLText: "https://relay.example.com/v1",
            customName: "OpenAI Relay"
        )
        relayProvider.relayRequested = RelayRequestedConfig(
            transport: .openaiChatCompletions,
            authMode: .bearer,
            modelID: "gpt-image-2",
            stream: true
        )
        state.providers = [relayProvider]
        state.setActiveModel(providerID: relayProvider.id, modelID: "gpt-image-2")

        let conversationID = try #require(await state.sendMessage("Draw a cat", in: nil))

        try await waitUntil {
            guard let conversation = state.conversation(for: conversationID),
                  let assistant = conversation.messages.last(where: { $0.role == .assistant }) else {
                return false
            }
            return assistant.state != .generating
        }
        try await waitForSendsToSettle(state)

        let request = try #require(capturedRequest)
        let body = try #require(appStateSendMessageRequestBody(from: request))
        let payload = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])

        #expect(request.url?.path == "/v1/images/generations")
        #expect(payload["model"] as? String == "gpt-image-2")
        // OpenAI no longer accepts a response_format field for dedicated image models (gpt-image-* / chatgpt-image-*),
        // and returns b64_json by default. Sending it explicitly gets a 400 from direct OpenAI or a strict relay.
        // OpenAIService.buildImagesGenerationRequest deliberately omits response_format for these models.
        #expect(payload["response_format"] as? String == nil)

        let conversation = try #require(state.conversation(for: conversationID))
        let assistant = try #require(conversation.messages.last(where: { $0.role == .assistant }))
        #expect(assistant.attachments?.count == 1)
        #expect(assistant.attachments?.first?.kind == .image)
    }

    @Test("Relay + openai_responses transport + imageGen + dedicated image model -> /responses carries the inline tool, and the main model switches to a chat driver automatically")
    func relayImageGenOnResponsesUsesInlineToolWithChatDriver() async throws {
        registerAppStateSendMessageMock()
        defer {
            AppStateSendMessageURLProtocol.requestHandler = nil
            unregisterAppStateSendMessageMock()
        }

        var capturedRequest: URLRequest?
        AppStateSendMessageURLProtocol.requestHandler = { request in
            let url = try #require(request.url)
            capturedRequest = request
            // Reply with a trivial empty SSE so the stream finishes
            return (
                appStateSendMessageHTTPResponse(
                    url: url,
                    statusCode: 200,
                    headers: ["Content-Type": "text/event-stream"]
                ),
                Data("data: [DONE]\n\n".utf8)
            )
        }

        let state = makeIsolatedAppState(prefix: "relay-imagegen-responses-")
        var relayProvider = TestFactories.makeProvider(
            kind: .relay,
            models: [
                TestFactories.makeModel(
                    id: "gpt-5.4",
                    name: "gpt-5.4",
                    capabilities: [.text],
                    isDefault: true
                ),
                TestFactories.makeModel(
                    id: "gpt-image-2",
                    name: "gpt-image-2",
                    capabilities: [.text, .imageGen]
                )
            ],
            catalogModels: [],
            apiKey: "relay-key",
            apiKeyPreview: "relay...",
            baseURLText: "https://code.example.com/codex",
            customName: "Codex Relay"
        )
        relayProvider.relayRequested = RelayRequestedConfig(
            transport: .openaiResponses,
            authMode: .bearer,
            modelID: "gpt-5.4",
            stream: true
        )
        state.providers = [relayProvider]
        state.setActiveModel(providerID: relayProvider.id, modelID: "gpt-image-2")

        let conversationID = try #require(await state.sendMessage("Draw a cat", in: nil))

        try await waitUntil {
            guard let conversation = state.conversation(for: conversationID),
                  let assistant = conversation.messages.last(where: { $0.role == .assistant }) else {
                return false
            }
            return assistant.state != .generating
        }
        try await waitForSendsToSettle(state)

        let request = try #require(capturedRequest)
        #expect(request.url?.path.hasSuffix("/responses") == true)
        #expect(request.value(forHTTPHeaderField: "User-Agent")?.hasPrefix("codex_cli_rs/") == true)
        #expect(request.value(forHTTPHeaderField: "Originator") == "codex_cli_rs")

        let body = try #require(appStateSendMessageRequestBody(from: request))
        let payload = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        // The main model should be switched to the chat driver gpt-5.4, while tool.model keeps the currently selected gpt-image-2
        #expect(payload["model"] as? String == "gpt-5.4", "the main model should be the chat driver gpt-5.4")
        let tools = payload["tools"] as? [[String: Any]] ?? []
        // With memory on, the normal path appends propose_memory after the existing tools (existing tools are kept, the memory tool goes last).
        #expect(tools.count == 2)
        #expect(tools.first?["type"] as? String == "image_generation")
        #expect(tools.last?["name"] as? String == MemoryPropose.toolName, "The memory tool should be appended after the existing tools")
        #expect(tools.first?["model"] as? String == "gpt-image-2", "tool.model should be the user-selected gpt-image-2")
        #expect(payload["stream"] as? Bool == true, "Responses transport + imageGen should force stream=true")
    }

    @Test("Relay + anthropic_messages transport + imageGen -> throws a friendly configuration error")
    func relayImageGenOnAnthropicThrowsFriendlyError() async throws {
        registerAppStateSendMessageMock()
        defer {
            AppStateSendMessageURLProtocol.requestHandler = nil
            unregisterAppStateSendMessageMock()
        }

        var requestFired = false
        AppStateSendMessageURLProtocol.requestHandler = { request in
            requestFired = true
            return (
                appStateSendMessageHTTPResponse(url: request.url!, statusCode: 500),
                Data()
            )
        }

        let state = makeIsolatedAppState(prefix: "relay-imagegen-anthropic-")
        var relayProvider = TestFactories.makeProvider(
            kind: .relay,
            models: [
                TestFactories.makeModel(
                    id: "gpt-image-2",
                    name: "gpt-image-2",
                    capabilities: [.text, .imageGen],
                    isDefault: true
                )
            ],
            catalogModels: [],
            apiKey: "relay-key",
            apiKeyPreview: "relay...",
            baseURLText: "https://claude.example.com",
            customName: "Anthropic Relay"
        )
        relayProvider.relayRequested = RelayRequestedConfig(
            transport: .anthropicMessages,
            authMode: .xApiKey,
            modelID: "gpt-image-2",
            stream: true
        )
        state.providers = [relayProvider]
        state.setActiveModel(providerID: relayProvider.id, modelID: "gpt-image-2")

        let conversationID = try #require(await state.sendMessage("Draw", in: nil))

        try await waitUntil {
            guard let conversation = state.conversation(for: conversationID),
                  let assistant = conversation.messages.last(where: { $0.role == .assistant }) else {
                return false
            }
            return assistant.state != .generating
        }
        try await waitForSendsToSettle(state)

        let conversation = try #require(state.conversation(for: conversationID))
        let assistant = try #require(conversation.messages.last(where: { $0.role == .assistant }))
        #expect(assistant.state == .failed, "Anthropic transport + imageGen should fail up front")
        #expect(requestFired == false, "no network request should be sent (the friendly error comes first)")
    }

    @Test("Relay stream=false uses the non-streaming chat completions runtime")
    func relayStreamFalseUsesNonStreamingChatCompletionsRuntime() async throws {
        registerAppStateSendMessageMock()
        defer {
            AppStateSendMessageURLProtocol.requestHandler = nil
            unregisterAppStateSendMessageMock()
        }

        var capturedRequest: URLRequest?
        AppStateSendMessageURLProtocol.requestHandler = { request in
            let url = try #require(request.url)
            capturedRequest = request

            return (
                appStateSendMessageHTTPResponse(
                    url: url,
                    statusCode: 200,
                    headers: ["Content-Type": "application/json"]
                ),
                Data(
                    """
                    {
                      "choices": [
                        {
                          "message": {
                            "content": "non-stream ok"
                          }
                        }
                      ],
                      "usage": {
                        "prompt_tokens": 5,
                        "completion_tokens": 2
                      }
                    }
                    """.utf8
                )
            )
        }

        let state = makeIsolatedAppState(prefix: "relay-openai-non-stream-")
        var relayProvider = TestFactories.makeProvider(
            kind: .relay,
            models: [
                TestFactories.makeModel(
                    id: "gpt-4o",
                    name: "GPT-4o",
                    capabilities: [.text],
                    isDefault: true
                )
            ],
            catalogModels: [
                TestFactories.makeModel(
                    id: "gpt-4o",
                    name: "GPT-4o",
                    capabilities: [.text],
                    isDefault: true
                )
            ],
            apiKey: "relay-key",
            apiKeyPreview: "relay...",
            baseURLText: "https://relay.example.com/v1",
            customName: "OpenAI Relay"
        )
        relayProvider.relayRequested = RelayRequestedConfig(
            transport: .openaiChatCompletions,
            authMode: .bearer,
            modelID: "gpt-4o",
            stream: false
        )
        state.providers = [relayProvider]
        state.setActiveModel(providerID: relayProvider.id, modelID: "gpt-4o")

        let conversationID = try #require(await state.sendMessage("Hello", in: nil))

        try await waitUntil {
            guard let conversation = state.conversation(for: conversationID),
                  let assistant = conversation.messages.last(where: { $0.role == .assistant }) else {
                return false
            }
            return assistant.state != .generating
        }
        try await waitForSendsToSettle(state)

        let request = try #require(capturedRequest)
        let body = try #require(appStateSendMessageRequestBody(from: request))
        let payload = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let conversation = try #require(state.conversation(for: conversationID))
        let assistant = try #require(conversation.messages.last(where: { $0.role == .assistant }))

        #expect(request.url?.path == "/v1/chat/completions")
        #expect(payload["stream"] as? Bool != true)
        #expect(assistant.text == "non-stream ok")
    }

    /// Ruling: **silent parameter stripping / downgrade retries are removed**; a user setting rejected upstream becomes a user-visible recovery state.
    /// See the production implementation in `OpenAIService.executeRelayResponsesStreamRequestWithFallbacks`
    /// ("never silently drop tools, lower xhigh, or issue a second upstream request") and
    /// `BaseAPIService.performRawWithUnsupportedParamSelfHeal` ("sends the production body
    /// exactly once; never pre-strips or retries after a 400").
    ///
    /// This case used to lock "xhigh 4xx -> automatically rewritten to high and resent". That behavior made "the UI shows Max but
    /// the output and billing are actually High" happen with no notice at all, so it was removed and the assertions now read:
    /// one leg only, the wire carries exactly the xhigh the user chose, and the failure lands on the message unchanged.
    ///
    /// It also asserts that no recovery descriptor is produced: a relay has no errorRecovery locator rule delivered by the server,
    /// `CapabilityExecutionTracker` only accepts a reviewed structured locator; it must not hand the user a "resend without this setting"
    /// CTA based on a single error message (that would wrap a guess as an explicit recovery).
    @Test("When Relay OpenAI Responses rejects xhigh with a 4xx, only one leg is sent and there is no automatic downgrade to high")
    func relayOpenAIResponsesNeverDowngradesXhighAfterRejection() async throws {
        try await loadRelayReasoningEvidence()
        registerAppStateSendMessageMock()
        defer {
            AppStateSendMessageURLProtocol.requestHandler = nil
            unregisterAppStateSendMessageMock()
        }

        let lock = NSLock()
        var capturedEfforts: [String?] = []
        AppStateSendMessageURLProtocol.requestHandler = { request in
            let url = try #require(request.url)
            let body = try #require(appStateSendMessageRequestBody(from: request))
            let payload = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            let reasoning = payload["reasoning"] as? [String: Any]
            let effort = reasoning?["effort"] as? String
            lock.lock()
            capturedEfforts.append(effort)
            lock.unlock()

            return (
                appStateSendMessageHTTPResponse(
                    url: url,
                    statusCode: 400,
                    headers: ["Content-Type": "application/json"]
                ),
                Data(
                    """
                    {
                      "error": {
                        "message": "xhigh is not supported"
                      }
                    }
                    """.utf8
                )
            )
        }

        let state = makeIsolatedAppState(prefix: "relay-openai-xhigh-no-downgrade-")
        var relayProvider = TestFactories.makeProvider(
            kind: .relay,
            models: [relayReasoningRetryModel()],
            catalogModels: [relayReasoningRetryModel()],
            apiKey: "relay-key",
            apiKeyPreview: "relay...",
            baseURLText: "https://relay.example.com/v1",
            customName: "OpenAI Relay"
        )
        relayProvider.relayRequested = RelayRequestedConfig(
            transport: .openaiResponses,
            authMode: .bearer,
            modelID: "gpt-5.4",
            stream: false
        )
        state.providers = [relayProvider]
        state.setActiveModel(providerID: relayProvider.id, modelID: "gpt-5.4")

        let conversationID = try #require(await state.sendMessage(
            "Need max reasoning",
            in: nil,
            capabilitySelection: ChatCapabilitySelection(
                reasoningMode: .max,
                webSearchEnabled: false
            )
        ))

        try await waitUntil {
            guard let conversation = state.conversation(for: conversationID),
                  let assistant = conversation.messages.last(where: { $0.role == .assistant }) else {
                return false
            }
            return assistant.state != .generating
        }
        try await waitForSendsToSettle(state)

        let conversation = try #require(state.conversation(for: conversationID))
        let assistant = try #require(conversation.messages.last(where: { $0.role == .assistant }))

        await MetadataClient.shared.resetForTesting()
        // One leg, and the wire carries the level the user chose: neither pre-stripped nor rewritten to high.
        #expect(capturedEfforts == ["xhigh"])
        #expect(assistant.state == .failed)
        // The error reaches the user as is (the message body carries the upstream error text) instead of being hidden by an automatic downgrade.
        #expect(!assistant.text.isEmpty)
        #expect(assistant.capabilityExecution?.recoveryDescriptors == nil)
    }

    /// The negative counterpart of the same ruling: 429 has never been within the automatic retry surface
    /// (`RequestPreferenceResolver.retryPolicy.neverAutomatic` lists "429" explicitly),
    /// so once mapped to a rate-limit error it must not trigger "downgrade and send another leg" either.
    ///
    /// Why both exist: the 4xx case proves that even when the parameter can be located it is not changed automatically, and this one proves that
    /// a status code that cannot even be located will not either. The old assertion `["xhigh", "high"]` locked the removed behavior.
    @Test("When Relay OpenAI Responses rejects xhigh with a 429, only one leg is sent as well")
    func relayOpenAIResponsesNeverDowngradesXhighAfterRateLimitMapping() async throws {
        try await loadRelayReasoningEvidence()
        registerAppStateSendMessageMock()
        defer {
            AppStateSendMessageURLProtocol.requestHandler = nil
            unregisterAppStateSendMessageMock()
        }

        let lock = NSLock()
        var capturedEfforts: [String?] = []
        AppStateSendMessageURLProtocol.requestHandler = { request in
            let url = try #require(request.url)
            let body = try #require(appStateSendMessageRequestBody(from: request))
            let payload = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            let reasoning = payload["reasoning"] as? [String: Any]
            let effort = reasoning?["effort"] as? String
            lock.lock()
            capturedEfforts.append(effort)
            lock.unlock()

            return (
                appStateSendMessageHTTPResponse(
                    url: url,
                    statusCode: 429,
                    headers: ["Content-Type": "application/json"]
                ),
                Data(
                    """
                    {
                      "error": {
                        "message": "xhigh is not supported yet"
                      }
                    }
                    """.utf8
                )
            )
        }

        let state = makeIsolatedAppState(prefix: "relay-openai-xhigh-429-no-downgrade-")
        var relayProvider = TestFactories.makeProvider(
            kind: .relay,
            models: [relayReasoningRetryModel()],
            catalogModels: [relayReasoningRetryModel()],
            apiKey: "relay-key",
            apiKeyPreview: "relay...",
            baseURLText: "https://relay.example.com/v1",
            customName: "OpenAI Relay"
        )
        relayProvider.relayRequested = RelayRequestedConfig(
            transport: .openaiResponses,
            authMode: .bearer,
            modelID: "gpt-5.4",
            stream: false
        )
        state.providers = [relayProvider]
        state.setActiveModel(providerID: relayProvider.id, modelID: "gpt-5.4")

        let conversationID = try #require(await state.sendMessage(
            "Need max reasoning",
            in: nil,
            capabilitySelection: ChatCapabilitySelection(
                reasoningMode: .max,
                webSearchEnabled: false
            )
        ))

        try await waitUntil {
            guard let conversation = state.conversation(for: conversationID),
                  let assistant = conversation.messages.last(where: { $0.role == .assistant }) else {
                return false
            }
            return assistant.state != .generating
        }
        try await waitForSendsToSettle(state)

        let conversation = try #require(state.conversation(for: conversationID))
        let assistant = try #require(conversation.messages.last(where: { $0.role == .assistant }))

        await MetadataClient.shared.resetForTesting()
        #expect(capturedEfforts == ["xhigh"])
        #expect(assistant.state == .failed)
        // The error reaches the user as is (the message body carries the upstream error text) instead of being hidden by an automatic downgrade.
        #expect(!assistant.text.isEmpty)
        #expect(assistant.capabilityExecution?.recoveryDescriptors == nil)
    }

    /// End-to-end guard that a Relay's **local mapping** (fail-open, bypassing any catalog profile) makes it all the way to the wire.
    ///
    /// A relay's catalog comes from the user's own machine and has no official metadata authority, so it is a special exception:
    /// - on the wire side, `OpenAIService.relayOpenAIReasoningEffort` keeps the local level mapping explicitly chosen by the user;
    /// - on the verdict side it goes through the escape hatch in `CapabilityEvidenceFacade.resolve` (this key has no evidence at all
    ///   and the user explicitly expressed intent -> `allow_explicit_unverified`), rather than being treated as unsupported.
    ///
    /// The existing `MetadataClientTests` only cover the display surface and `GenerationParameterEmptyStateTests`
    /// only cover level constraints; neither asserts the request body. This case targets the defect class where the UI says it is on but the wire has nothing,
    /// and asserts on the body the production send chain really produces, not on intermediate variables.
    @Test("With no catalog profile on a Relay, the thinking level the user chose is still written into the final request body through the local mapping")
    func relayLocalReasoningMappingReachesTheWire() async throws {
        await MetadataClient.shared.resetForTesting()
        // Deliberately ship no reasoning profile: this is the normal state of a relay that does not hit the official catalog.
        try await MetadataClient.shared.loadForTesting(json: """
        {
          "version": 1,
          "updatedAt": "2026-08-09T00:00:00Z",
          "profiles": {
            "reasoning": {},
            "webSearch": {},
            "imageGen": {}
          },
          "providers": {}
        }
        """, metadataETag: "relay-local-mapping-etag")
        registerAppStateSendMessageMock()
        defer {
            AppStateSendMessageURLProtocol.requestHandler = nil
            unregisterAppStateSendMessageMock()
        }

        let lock = NSLock()
        var capturedPayloads: [[String: Any]] = []
        AppStateSendMessageURLProtocol.requestHandler = { request in
            let url = try #require(request.url)
            let body = try #require(appStateSendMessageRequestBody(from: request))
            let payload = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            lock.lock()
            capturedPayloads.append(payload)
            lock.unlock()

            return (
                appStateSendMessageHTTPResponse(
                    url: url,
                    statusCode: 200,
                    headers: ["Content-Type": "application/json"]
                ),
                Data(
                    """
                    {
                      "output_text": "local mapping ok",
                      "usage": { "input_tokens": 3, "output_tokens": 2 }
                    }
                    """.utf8
                )
            )
        }

        // Key point: reasoningProfile is nil, so the model has no catalog-side thinking recipe at all.
        let localModel = TestFactories.makeModel(
            id: "local-reasoner",
            name: "Local Reasoner",
            capabilities: [.text, .reasoning],
            reasoningModeAvailable: true,
            isDefault: true
        )
        let state = makeIsolatedAppState(prefix: "relay-local-reasoning-wire-")
        var relayProvider = TestFactories.makeProvider(
            kind: .relay,
            models: [localModel],
            catalogModels: [localModel],
            apiKey: "relay-key",
            apiKeyPreview: "relay...",
            baseURLText: "https://relay.example.com/v1",
            customName: "OpenAI Relay"
        )
        relayProvider.relayRequested = RelayRequestedConfig(
            transport: .openaiResponses,
            authMode: .bearer,
            modelID: "local-reasoner",
            stream: false
        )
        state.providers = [relayProvider]
        state.setActiveModel(providerID: relayProvider.id, modelID: "local-reasoner")

        let conversationID = try #require(await state.sendMessage(
            "Think deeply",
            in: nil,
            capabilitySelection: ChatCapabilitySelection(
                reasoningMode: .deep,
                webSearchEnabled: false
            )
        ))

        try await waitUntil {
            guard let conversation = state.conversation(for: conversationID),
                  let assistant = conversation.messages.last(where: { $0.role == .assistant }) else {
                return false
            }
            return assistant.state != .generating
        }
        try await waitForSendsToSettle(state)

        let conversation = try #require(state.conversation(for: conversationID))
        let assistant = try #require(conversation.messages.last(where: { $0.role == .assistant }))

        lock.lock()
        let payloads = capturedPayloads
        lock.unlock()
        await MetadataClient.shared.resetForTesting()

        #expect(payloads.count == 1)
        let payload = try #require(payloads.first)
        let reasoning = try #require(
            payload["reasoning"] as? [String: Any],
            "When the user picks Deep Thinking, the final request body must actually contain a reasoning section"
        )
        // ReasoningMode.deep -> relay local mapping "high" (`OpenAIService.relayOpenAIReasoningEffort`).
        #expect(reasoning["effort"] as? String == "high")
        #expect(assistant.text == "local mapping ok")
        #expect(assistant.state == .delivered)
    }
}

// MARK: - Pre-send attachment check in the composer

private final class ComposerPreflightTransportLog: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [AttachmentTransport] = []
    func record(_ transport: AttachmentTransport) { lock.lock(); seen.append(transport); lock.unlock() }
    var transports: Set<AttachmentTransport> { lock.lock(); defer { lock.unlock() }; return Set(seen) }
}

extension AppStateSendMessageTests {

    private func preflightTextFile(_ name: String, content: String = "x") -> Oriveo.Attachment {
        Oriveo.Attachment(
            id: UUID(), kind: .file, fileName: name, mimeType: "text/plain",
            base64Data: Data(content.utf8).base64EncodedString(),
            extractedSizeBytes: content.utf8.count
        )
    }

    @MainActor
    private func preflightRelayState(
        transport: RelayTransport,
        extraction: AttachmentExtractionLimits? = nil
    ) -> (state: AppState, provider: Provider, model: AIModel) {
        let state = makeIsolatedAppState(prefix: "composer-preflight-")
        var model = TestFactories.makeModel(id: "relay-model", name: "Relay Model", capabilities: [.text], isDefault: true)
        model.attachmentExtraction = extraction
        var provider = TestFactories.makeProvider(
            kind: .relay, models: [model], catalogModels: [model],
            apiKey: "relay-key", apiKeyPreview: "relay...",
            baseURLText: "https://relay.example.com", customName: "Preflight Relay"
        )
        provider.relayRequested = RelayRequestedConfig(transport: transport, authMode: .auto, modelID: "relay-model")
        state.providers = [provider]
        state.setActiveModel(providerID: provider.id, modelID: "relay-model")
        return (state, provider, model)
    }

    @Test("composer pre-send: too many files are blocked with no conversation and no request, and the notice is the count one")
    func composerPreflightBlocksOverFileCount() async throws {
        registerAppStateSendMessageMock()
        defer { unregisterAppStateSendMessageMock() }
        var requestCount = 0
        AppStateSendMessageURLProtocol.requestHandler = { request in
            requestCount += 1
            return (appStateSendMessageHTTPResponse(url: try #require(request.url), statusCode: 500), Data())
        }
        let (state, _, _) = preflightRelayState(transport: .openaiChatCompletions)
        let files = ["a.txt", "b.txt", "c.txt", "d.txt"].map { preflightTextFile($0) }

        let blocked = state.composerAttachmentOverLimit(
            text: "q", attachments: files, in: nil,
            generationParameterDraftSessionID: UUID(), capabilitySelection: ChatCapabilitySelection()
        )
        guard case let .attachmentTextOverLimit(fileNames, fileCountLimit)? = blocked else {
            Issue.record("over-count turn was not blocked before sending: \(String(describing: blocked))")
            return
        }
        #expect(fileNames.isEmpty)
        #expect(fileCountLimit == FileExtractionLimits.default.maxFiles)
        #expect(blocked?.message == String(
            format: L10n.tr("file_attachment_count_limit_reached", table: .chat), FileExtractionLimits.default.maxFiles
        ))
        // The check itself persists nothing: no conversation, no messages, no requests.
        #expect(state.conversations.isEmpty)
        #expect(requestCount == 0)

        // Anything that fits is not blocked; image-only attachments are not blocked either.
        #expect(state.composerAttachmentOverLimit(
            text: "q", attachments: Array(files.prefix(3)), in: nil,
            generationParameterDraftSessionID: UUID(), capabilitySelection: ChatCapabilitySelection()
        ) == nil)
        let image = Oriveo.Attachment(id: UUID(), kind: .image, fileName: "p.png", mimeType: "image/png", base64Data: "aGk=")
        #expect(state.composerAttachmentOverLimit(
            text: "q", attachments: [image], in: nil,
            generationParameterDraftSessionID: UUID(), capabilitySelection: ChatCapabilitySelection()
        ) == nil)
    }

    @Test("composer pre-send: an over-limit text total gets the text notice and is computed against the conversation's current model")
    func composerPreflightBlocksOverTextBudgetUsingTheConversationModel() async throws {
        let (state, provider, model) = preflightRelayState(
            transport: .openaiResponses, extraction: AttachmentExtractionLimits(totalCap: 32)
        )
        let conversation = TestFactories.makeConversation(providerID: provider.id, providerKind: provider.kind, modelID: model.id)
        state.upsertConversationProjection(conversation)
        let files = [preflightTextFile("a.txt", content: "aaaa"), preflightTextFile("b.txt", content: String(repeating: "b", count: 64))]

        let blocked = state.composerAttachmentOverLimit(
            text: "q", attachments: files, in: conversation.id,
            generationParameterDraftSessionID: nil, capabilitySelection: ChatCapabilitySelection()
        )
        guard case let .attachmentTextOverLimit(fileNames, fileCountLimit)? = blocked else {
            Issue.record("over-budget turn was not blocked before sending: \(String(describing: blocked))")
            return
        }
        #expect(fileNames == ["b.txt"])
        #expect(fileCountLimit == nil)
        #expect(blocked?.message == String(
            format: L10n.tr("file_extraction_send_blocked_text_budget", table: .chat), "b.txt"
        ))
        #expect(state.conversation(for: conversation.id)?.messages.isEmpty == true)
    }

    @Test("composer pre-send: image generation routes are not predicted and not blocked (left to the failure card at send time)")
    func composerPreflightDoesNotBlockWhenTheRouteIsNotPredictable() async throws {
        let state = makeIsolatedAppState(prefix: "composer-preflight-unresolved-")
        let model = TestFactories.makeModel(id: "image-model", name: "Image", capabilities: [.text, .imageGen], isDefault: true)
        var provider = TestFactories.makeProvider(
            kind: .relay, models: [model], catalogModels: [model],
            apiKey: "relay-key", apiKeyPreview: "relay...", baseURLText: "https://relay.example.com", customName: "Image Relay"
        )
        provider.relayRequested = RelayRequestedConfig(transport: .openaiResponses, authMode: .auto, modelID: "image-model")
        state.providers = [provider]
        state.setActiveModel(providerID: provider.id, modelID: "image-model")
        let files = ["a.txt", "b.txt", "c.txt", "d.txt"].map { preflightTextFile($0) }
        #expect(state.composerAttachmentOverLimit(
            text: "q", attachments: files, in: nil,
            generationParameterDraftSessionID: UUID(), capabilitySelection: ChatCapabilitySelection()
        ) == nil)
    }

    @Test("the five Relay routes: the route resolved before sending matches the one the build point reports in a real send, and so does the verdict")
    func composerPreflightMatchesRealRelaySend() async throws {
        registerAppStateSendMessageMock()
        defer { unregisterAppStateSendMessageMock() }
        var requestCount = 0
        AppStateSendMessageURLProtocol.requestHandler = { request in
            requestCount += 1
            return (appStateSendMessageHTTPResponse(url: try #require(request.url), statusCode: 500), Data())
        }
        let files = ["a.txt", "b.txt", "c.txt", "d.txt"].map { preflightTextFile($0) }
        let expected: [(RelayTransport, AttachmentTransport)] = [
            (.openaiChatCompletions, .relayOpenAIChat),
            (.openaiResponses, .relayOpenAIResponses),
            (.llamacppNative, .relayLlamaCppNative),
            (.anthropicMessages, .relayAnthropicMessages),
            (.geminiGenerateContent, .relayGeminiGenerateContent),
        ]
        for (relayTransport, transport) in expected {
            let (state, provider, model) = preflightRelayState(transport: relayTransport)
            #expect(AttachmentTransportResolver.resolve(provider: provider, model: model, request: .init()) == transport)
            #expect(state.composerAttachmentOverLimit(
                text: "q", attachments: files, in: nil,
                generationParameterDraftSessionID: UUID(), capabilitySelection: ChatCapabilitySelection()
            ) != nil, "\(relayTransport)")

            // Bypass the composer and send for real: the build point reports exactly this route, and it likewise sends no request because the files do not fit.
            requestCount = 0
            let log = ComposerPreflightTransportLog()
            let sent = await AttachmentDeliveryObservation.$onDeliver.withValue({ log.record($0) }) {
                await state.sendMessage("q", attachments: files, in: nil)
            }
            let conversationID = try #require(sent)
            try await waitUntil {
                guard let assistant = state.conversation(for: conversationID)?.messages.last(where: { $0.role == .assistant }) else {
                    return false
                }
                return assistant.state != .generating
            }
            try await waitForSendsToSettle(state)
            #expect(log.transports == [transport], "\(relayTransport) built on \(log.transports)")
            #expect(state.conversation(for: conversationID)?.messages.last?.state == .failed, "\(relayTransport)")
            #expect(requestCount == 0, "\(relayTransport)")
        }
    }
}


// MARK: - Sending is blocked for a retired / missing conversation model

extension AppStateSendMessageTests {
    private static let retirementMetadataJSON = """
    {
      "version": 1,
      "updatedAt": "2026-10-01T00:00:00Z",
      "providers": {
        "openAI": {
          "displayName": "OpenAI",
          "defaultModelId": "gpt-5.4",
          "resolveMap": { "gpt-5.4": "gpt-5.4", "gpt-5.4-2026-03-05": "gpt-5.4" },
          "models": {
            "gpt-5.4": { "canonicalModelId": "gpt-5.4", "displayName": "GPT-5.4", "capabilities": ["text"] }
          },
          "retiredModels": [
            { "id": "gpt-4-legacy", "displayName": "GPT-4 Legacy", "retiredAt": "2026-07-01T00:00:00Z", "routedTo": "gpt-5.4" }
          ]
        }
      }
    }
    """

    /// An official conversation that already has one round of Q&A (not a new conversation), used for sending / regenerating.
    private func retirementFixture(
        prefix: String,
        modelID: String
    ) -> (state: AppState, provider: Provider, conversation: Conversation, assistantID: UUID) {
        let state = makeIsolatedAppState(prefix: prefix)
        let enabled = TestFactories.makeModel(id: "gpt-5.4", name: "GPT-5.4", isDefault: true, canonicalModelId: "gpt-5.4")
        let provider = TestFactories.makeProvider(kind: .openAI, models: [enabled], catalogModels: [enabled])
        let assistantID = UUID()
        let conversation = TestFactories.makeConversation(
            providerID: provider.id,
            providerKind: .openAI,
            modelID: modelID,
            messages: [
                TestFactories.makeMessage(role: .user, text: "Hi", providerID: provider.id, modelID: modelID),
                TestFactories.makeMessage(id: assistantID, role: .assistant, text: "Hello", providerID: provider.id, modelID: modelID),
            ]
        )
        state.providers = [provider]
        state.upsertConversationProjection(conversation)
        return (state, provider, conversation, assistantID)
    }

    private func installChatRequestCounter() -> () -> Int {
        let counter = AppStateSendRequestCounter()
        AppStateSendMessageURLProtocol.requestHandler = { request in
            if request.url?.path.contains("/api/metadata") != true { counter.increment() }
            return (appStateSendMessageHTTPResponse(url: request.url!, statusCode: 503), Data())
        }
        return { counter.value }
    }

    @Test("A tombstoned conversation refuses send / regenerate: zero requests, modelID unchanged")
    func retiredConversationRefusesSendAndRegenerate() async throws {
        defer { AppStateSendMessageURLProtocol.requestHandler = nil }
        let requestCount = installChatRequestCounter()
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(json: Self.retirementMetadataJSON)
        let fixture = retirementFixture(prefix: "retired-send-", modelID: "gpt-4-legacy")

        #expect(fixture.state.conversationModelState(for: fixture.conversation)
            == .retired(displayName: "GPT-4 Legacy", successorId: "gpt-5.4"))

        let outcome = await fixture.state.sendMessageOutcome("Hello again", in: fixture.conversation.id)
        #expect(outcome == .refused)

        await fixture.state.chatManager.regenerateMessage(messageID: fixture.assistantID, in: fixture.conversation.id)

        let after = try #require(fixture.state.conversation(for: fixture.conversation.id))
        #expect(after.modelID == "gpt-4-legacy")
        #expect(after.messages.map(\.id) == fixture.conversation.messages.map(\.id))
        #expect(after.messages.last?.text == "Hello")
        #expect(requestCount() == 0)
        await MetadataClient.shared.resetForTesting()
    }

    @Test("A conversation model confirmed absent from the catalog (missing) is refused, modelID unchanged")
    func missingConversationRefusesSend() async throws {
        defer { AppStateSendMessageURLProtocol.requestHandler = nil }
        let requestCount = installChatRequestCounter()
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(json: Self.retirementMetadataJSON)
        let fixture = retirementFixture(prefix: "missing-send-", modelID: "removed-model")

        #expect(fixture.state.conversationModelState(for: fixture.conversation) == .missing(displayName: "removed-model"))
        let outcome = await fixture.state.sendMessageOutcome("Hello again", in: fixture.conversation.id)
        #expect(outcome == .refused)
        #expect(fixture.state.conversation(for: fixture.conversation.id)?.modelID == "removed-model")
        #expect(requestCount() == 0)
        await MetadataClient.shared.resetForTesting()
    }

    @Test("A conversation on a canonical alias can send: this turn uses the canonical id, the conversation modelID is unchanged")
    func datedAliasConversationSendsCanonicalWithoutRewrite() async throws {
        defer { AppStateSendMessageURLProtocol.requestHandler = nil }
        let requestCount = installChatRequestCounter()
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(json: Self.retirementMetadataJSON)
        let fixture = retirementFixture(prefix: "alias-send-", modelID: "gpt-5.4-2026-03-05")

        let outcome = await fixture.state.sendMessageOutcome("Hello again", in: fixture.conversation.id)
        #expect(outcome == .sent(fixture.conversation.id))
        let after = try #require(fixture.state.conversation(for: fixture.conversation.id))
        #expect(after.modelID == "gpt-5.4-2026-03-05")
        #expect(after.messages.last(where: { $0.role == .user })?.modelID == "gpt-5.4")
        try await waitUntil { requestCount() > 0 }
        try await waitForSendsToSettle(fixture.state)
        await MetadataClient.shared.resetForTesting()
    }

    @Test("Regenerate on a canonical-alias conversation: this turn is sent with the canonical id, the conversation modelID is unchanged")
    func datedAliasConversationRegenerateKeepsModelID() async throws {
        defer { AppStateSendMessageURLProtocol.requestHandler = nil }
        let requestCount = installChatRequestCounter()
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(json: Self.retirementMetadataJSON)
        let fixture = retirementFixture(prefix: "alias-regenerate-", modelID: "gpt-5.4-2026-03-05")

        await fixture.state.chatManager.regenerateMessage(messageID: fixture.assistantID, in: fixture.conversation.id)

        try await waitUntil { requestCount() > 0 }
        let after = try #require(fixture.state.conversation(for: fixture.conversation.id))
        #expect(after.modelID == "gpt-5.4-2026-03-05")
        #expect(after.messages.last?.role == .assistant)
        #expect(after.messages.last?.id != fixture.assistantID, "regenerating replaced the assistant message with a new one")
        #expect(after.messages.last?.modelID == "gpt-5.4")
        try await waitForSendsToSettle(fixture.state)
        #expect(fixture.state.conversation(for: fixture.conversation.id)?.modelID == "gpt-5.4-2026-03-05")
        await MetadataClient.shared.resetForTesting()
    }

    @Test("While the catalog is pending the model counts as available: sending works, the conversation modelID is unchanged")
    func pendingCatalogAllowsSend() async throws {
        defer { AppStateSendMessageURLProtocol.requestHandler = nil }
        let requestCount = installChatRequestCounter()
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadSplitForTesting(
            indexJSON: #"{"version":42,"view":"index","contractVersion":1,"providers":{"openAI":{"displayName":"OpenAI","catalogRevision":"sha256:pending-openai"}}}"#,
            indexETag: "etag-pending-openai",
            catalogJSONs: [:]
        )
        #expect(MetadataClient.shared.syncIsCatalogPending(providerKind: .openAI), "Precondition: the openAI catalog is not loaded")
        let fixture = retirementFixture(prefix: "pending-send-", modelID: "removed-model")

        #expect(fixture.state.conversationModelState(for: fixture.conversation) == .resolved)
        let outcome = await fixture.state.sendMessageOutcome("Hello again", in: fixture.conversation.id)
        #expect(outcome == .sent(fixture.conversation.id))
        #expect(fixture.state.conversation(for: fixture.conversation.id)?.modelID == "removed-model")
        try await waitUntil { requestCount() > 0 }
        try await waitForSendsToSettle(fixture.state)
        await MetadataClient.shared.resetForTesting()
    }

    @Test("With the catalog pending and the stored value unresolvable, the request model field is the stored id, not the default model")
    func pendingCatalogSendsStoredModelIDVerbatim() async throws {
        defer { AppStateSendMessageURLProtocol.requestHandler = nil }
        let captured = AppStateSendCapturedModels()
        AppStateSendMessageURLProtocol.requestHandler = { request in
            if request.url?.path.contains("/api/metadata") != true,
               let body = appStateSendMessageRequestBody(from: request),
               let json = try JSONSerialization.jsonObject(with: body) as? [String: Any] {
                captured.append(json["model"] as? String)
            }
            return (appStateSendMessageHTTPResponse(url: request.url!, statusCode: 503), Data())
        }
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadSplitForTesting(
            indexJSON: #"{"version":42,"view":"index","contractVersion":1,"providers":{"openAI":{"displayName":"OpenAI","catalogRevision":"sha256:pending-openai"}}}"#,
            indexETag: "etag-pending-openai",
            catalogJSONs: [:]
        )
        #expect(MetadataClient.shared.syncIsCatalogPending(providerKind: .openAI), "Precondition: the openAI catalog is not loaded")
        let fixture = retirementFixture(prefix: "pending-verbatim-", modelID: "removed-model")

        let outcome = await fixture.state.sendMessageOutcome("Hello again", in: fixture.conversation.id)
        #expect(outcome == .sent(fixture.conversation.id))
        try await waitUntil { !captured.values.isEmpty }
        #expect(captured.values.first == "removed-model")
        #expect(!captured.values.contains("gpt-5.4"), "must not silently switch to the default model")
        try await waitForSendsToSettle(fixture.state)
        await MetadataClient.shared.resetForTesting()
    }

    @Test("Sending again in an existing conversation after its messages were cleared: the conversation modelID is unchanged")
    func clearedConversationSendKeepsModelID() async throws {
        defer { AppStateSendMessageURLProtocol.requestHandler = nil }
        let requestCount = installChatRequestCounter()
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(json: Self.retirementMetadataJSON)
        let fixture = retirementFixture(prefix: "cleared-send-", modelID: "gpt-5.4-2026-03-05")
        var cleared = fixture.conversation
        cleared.messages = []
        fixture.state.upsertConversationProjection(cleared)

        let outcome = await fixture.state.sendMessageOutcome("Hello again", in: fixture.conversation.id)
        #expect(outcome == .sent(fixture.conversation.id))
        let after = try #require(fixture.state.conversation(for: fixture.conversation.id))
        #expect(after.messages.last(where: { $0.role == .user })?.modelID == "gpt-5.4")
        #expect(after.modelID == "gpt-5.4-2026-03-05")
        try await waitUntil { requestCount() > 0 }
        try await waitForSendsToSettle(fixture.state)
        await MetadataClient.shared.resetForTesting()
    }
}

private final class AppStateSendCapturedModels: @unchecked Sendable {
    private let lock = NSLock()
    private var models: [String?] = []
    var values: [String?] { lock.lock(); defer { lock.unlock() }; return models }
    func append(_ model: String?) { lock.lock(); models.append(model); lock.unlock() }
}

private final class AppStateSendRequestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func increment() { lock.lock(); count += 1; lock.unlock() }
}
