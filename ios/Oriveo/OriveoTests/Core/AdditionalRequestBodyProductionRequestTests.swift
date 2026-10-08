import Foundation
import Testing
@testable import Oriveo

/// Records every POST body the production send path really emits and answers with the status
/// codes the test supplies.
final class AdditionalRequestBodyCaptureURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var bodies: [[String: Any]] = []
    /// Status codes to answer with, in order; 200 once they run out.
    nonisolated(unsafe) private static var statuses: [Int] = []
    static let rejectionBody = #"{"error":{"message":"probe upstream says: unexpected field zz_unknown","type":"invalid_request_error"}}"#

    /// Stream bodies for 200 answers, in order; an empty stream with only [DONE] once they run out.
    nonisolated(unsafe) private static var streams: [String] = []
    /// Body of a non-200 answer; nil uses `rejectionBody`.
    nonisolated(unsafe) private static var failureBody: String?

    static func reset(statuses: [Int] = [], streams: [String] = [], failureBody: String? = nil) {
        lock.lock()
        bodies = []
        self.statuses = statuses
        self.streams = streams
        self.failureBody = failureBody
        lock.unlock()
    }

    static var captured: [[String: Any]] {
        lock.lock()
        defer { lock.unlock() }
        return bodies
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var status = 200
        var stream = "data: [DONE]\n\n"
        var failure = Self.rejectionBody
        if request.httpMethod == "POST" {
            Self.lock.lock()
            Self.bodies.append(Self.bodyObject(of: request) ?? [:])
            if !Self.statuses.isEmpty { status = Self.statuses.removeFirst() }
            if status == 200, !Self.streams.isEmpty { stream = Self.streams.removeFirst() }
            if let body = Self.failureBody { failure = body }
            Self.lock.unlock()
        }
        let failed = status != 200
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://relay.invalid")!, statusCode: status, httpVersion: nil,
            headerFields: ["Content-Type": failed ? "application/json" : "text/event-stream"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data((failed ? failure : stream).utf8))
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

/// End-to-end coverage for the additional request body. Assertions are made on the URLRequest the
/// production send path really emits (AppState -> ChatManager -> service builder -> URLSession);
/// content is read through the production store and no request body is assembled by hand.
@Suite("additional request body production requests", .serialized)
@MainActor
struct AdditionalRequestBodyProductionRequestTests {

    @Test("Panel parameters and the additional request body both reach the real request body; the additional request body wins for the same field")
    func coexistsWithPanelParametersAndWinsOnSameKey() async throws {
        let fixture = Fixture(
            connectionDefaults: [
                "temperature": .init(state: .value, value: .number(0.7)),
                "top_p": .init(state: .value, value: .number(0.9)),
                "stop": .init(state: .value, value: .stringList(["END"])),
            ],
            additionalBody: #"{"temperature": 0.2, "top_k": 40, "chat_template_kwargs": {"enable_thinking": false}}"#
        )
        defer { fixture.cleanUp() }
        let message = try await fixture.send()
        let body = try #require(AdditionalRequestBodyCaptureURLProtocol.captured.first, "the send path emitted no request")

        #expect((body["temperature"] as? NSNumber)?.doubleValue == 0.2, "the additional request body did not win for the same field")
        #expect((body["top_p"] as? NSNumber)?.doubleValue == 0.9, "panel parameters were cleared once an additional request body was set")
        #expect(body["stop"] as? [String] == ["END"])
        #expect((body["top_k"] as? NSNumber)?.intValue == 40)
        #expect((body["chat_template_kwargs"] as? [String: Any])?["enable_thinking"] as? Bool == false)
        #expect(body["model"] as? String == Fixture.modelID)
        #expect((body["messages"] as? [Any])?.isEmpty == false)
        #expect(message.errorTitle != AdditionalRequestBody.localRejectionTitleKey)
    }

    @Test("Send with requests switched off: content stays stored, the request omits it, panel parameters are unaffected")
    func switchedOffBodyStaysStoredButIsNotSent() async throws {
        let fixture = Fixture(
            connectionDefaults: ["top_p": .init(state: .value, value: .number(0.9))],
            additionalBody: #"{"top_k": 40}"#, sendsWithRequest: false
        )
        defer { fixture.cleanUp() }
        _ = try await fixture.send()
        let body = try #require(AdditionalRequestBodyCaptureURLProtocol.captured.first)
        #expect(body["top_k"] == nil)
        #expect((body["top_p"] as? NSNumber)?.doubleValue == 0.9)
        #expect(fixture.stored?.rawJSON == #"{"top_k": 40}"#)
    }

    @Test("A protected field in the additional request body is rejected locally: no request, connection not marked as failing, error names the field and line")
    func protectedFieldIsRejectedLocallyWithoutAnyRequest() async throws {
        let fixture = Fixture(
            connectionDefaults: ["top_p": .init(state: .value, value: .number(0.9))],
            additionalBody: "{\n  \"top_k\": 1,\n  \"messages\": []\n}"
        )
        defer { fixture.cleanUp() }
        let message = try await fixture.send()

        #expect(AdditionalRequestBodyCaptureURLProtocol.captured.isEmpty, "a request was still sent after the local rejection")
        #expect(message.state == .failed)
        #expect(message.errorTitle == AdditionalRequestBody.localRejectionTitleKey)
        #expect(message.errorDetail == "additional_request_body_rejected:protected_field:messages@3")
        #expect(message.text.contains("messages"), "the error message does not name the field: \(message.text)")
        #expect(fixture.state.provider(for: fixture.providerID)?.status == .connected, "a mistake in the additional request body marked the connection as failing")
        #expect(fixture.state.provider(for: fixture.providerID)?.lastError == nil)
        // A local rejection offers no retry without the additional request body: resending
        // unchanged content gives the same result.
        #expect(LocalCustomFragmentDisposition.forExplicitRetry(
            errorTitle: message.errorTitle, recoveryDescriptorCount: nil
        ) == .include)
    }

    @Test("Truncated JSON is rejected locally too: no request, connection not marked as failing")
    func invalidJSONIsRejectedLocally() async throws {
        let fixture = Fixture(connectionDefaults: [:], additionalBody: #"{"top_k": "#)
        defer { fixture.cleanUp() }
        let message = try await fixture.send()
        #expect(AdditionalRequestBodyCaptureURLProtocol.captured.isEmpty)
        #expect(message.errorTitle == AdditionalRequestBody.localRejectionTitleKey)
        #expect(message.errorDetail == "additional_request_body_rejected:invalid_json")
        #expect(fixture.state.provider(for: fixture.providerID)?.status == .connected)
    }

    @Test("Upstream 400 for a request carrying the additional request body offers a retry without it; the retry affects one request and leaves stored content alone")
    func upstreamRejectionOffersRetryWithoutAdditionalBody() async throws {
        let marker = "zz_unknown_\(UUID().uuidString.prefix(8).lowercased())"
        let raw = #"{"\#(marker)": {"deep": true}}"#
        let fixture = Fixture(
            connectionDefaults: ["top_p": .init(state: .value, value: .number(0.9))],
            additionalBody: raw
        )
        defer { fixture.cleanUp() }
        AdditionalRequestBodyCaptureURLProtocol.reset(statuses: [400])
        let failed = try await fixture.send(resetCapture: false)

        let first = try #require(AdditionalRequestBodyCaptureURLProtocol.captured.first)
        #expect(first[marker] != nil, "precondition: the first request really carried the additional request body")
        #expect(failed.state == .failed)
        #expect(failed.errorTitle == AdditionalRequestBody.upstreamRejectionTitleKey)
        #expect(failed.errorDetail?.contains("unexpected field zz_unknown") == true, "the upstream error did not reach the error presentation: \(failed.errorDetail ?? "nil")")
        #expect(fixture.state.provider(for: fixture.providerID)?.status == .connected)
        // Device-local: neither key names nor values of the additional request body reach any
        // persisted field of the failed message.
        #expect(!"\(failed.text)\(failed.errorTitle ?? "")\(failed.errorDetail ?? "")".contains(marker))

        // The user taps the primary button: the marker on the failed message decides the disposition.
        let disposition = LocalCustomFragmentDisposition.forExplicitRetry(
            errorTitle: failed.errorTitle, recoveryDescriptorCount: failed.capabilityExecution?.recoveryDescriptors?.count
        )
        #expect(disposition == .omitAdditionalBodyForExplicitRetry)
        await fixture.state.retryMessage(
            messageID: failed.id, in: fixture.conversationID, localCustomFragmentDisposition: disposition
        )
        let retried = try await fixture.waitForRequests(2)
        #expect(retried[1][marker] == nil, "the retried request still carried the additional request body")
        #expect((retried[1]["top_p"] as? NSNumber)?.doubleValue == 0.9, "the retry dropped the panel parameters too")
        #expect(fixture.stored == .init(rawJSON: raw, sendsWithRequest: true), "the retry changed stored content")

        // The next ordinary message carries it again: the one-off omission is not inherited.
        _ = try await fixture.send(resetCapture: false, text: "next-turn-probe")
        let later = AdditionalRequestBodyCaptureURLProtocol.captured.filter {
            (try? JSONSerialization.data(withJSONObject: $0)).map { String(decoding: $0, as: UTF8.self) }?
                .contains("next-turn-probe") == true
        }
        #expect(later.first?[marker] != nil, "the next message did not carry the additional request body")
    }

    @Test("A 400 without the additional request body and a 500 with it both offer no retry without it")
    func recoveryIsNotOfferedOutsideTheContractConditions() async throws {
        let without = Fixture(connectionDefaults: [:], additionalBody: nil)
        AdditionalRequestBodyCaptureURLProtocol.reset(statuses: [400])
        let plain = try await without.send(resetCapture: false)
        without.cleanUp()
        #expect(plain.state == .failed)
        #expect(plain.errorTitle != AdditionalRequestBody.upstreamRejectionTitleKey)

        let with = Fixture(connectionDefaults: [:], additionalBody: #"{"top_k": 40}"#)
        defer { with.cleanUp() }
        AdditionalRequestBodyCaptureURLProtocol.reset(statuses: [500])
        let serverError = try await with.send(resetCapture: false)
        #expect(serverError.state == .failed)
        #expect(serverError.errorTitle != AdditionalRequestBody.upstreamRejectionTitleKey)
    }

    /// What LM Studio 0.3 really answers when a known field has the wrong type (captured from a
    /// local instance with `temperature: "hot"` and `stream: true`): HTTP 200,
    /// `Content-Type: text/event-stream`, and this one frame in the stream. Copied byte for byte.
    static let lmStudioStreamError = #"""
    event: error
    data: {"error":{"message":"Field with key llm.prediction.temperature does not satisfy the schema:[\n  {\n    \"code\": \"invalid_type\",\n    \"expected\": \"number\",\n    \"received\": \"nan\",\n    \"path\": [],\n    \"message\": \"Expected number, received nan\"\n  }\n]"},"message":"Field with key llm.prediction.temperature does not satisfy the schema:[\n  {\n    \"code\": \"invalid_type\",\n    \"expected\": \"number\",\n    \"received\": \"nan\",\n    \"path\": [],\n    \"message\": \"Expected number, received nan\"\n  }\n]"}


    """#

    @Test("In-stream error event (HTTP 200): the message fails as an upstream error with the upstream text instead of ending as a completed empty answer")
    func streamErrorEventFailsTheMessageWithUpstreamText() async throws {
        let fixture = Fixture(connectionDefaults: [:], additionalBody: nil)
        defer { fixture.cleanUp() }
        AdditionalRequestBodyCaptureURLProtocol.reset(streams: [Self.lmStudioStreamError])
        let message = try await fixture.send(resetCapture: false)
        #expect(message.state == .failed, "the upstream reported an error in the stream but the message is \(message.state.rawValue)")
        #expect(message.errorDetail?.contains("llm.prediction.temperature does not satisfy the schema") == true, "the upstream text did not reach the error presentation: \(message.errorDetail ?? "nil")")
        #expect(message.errorTitle != AdditionalRequestBody.upstreamRejectionTitleKey, "no additional request body was sent, so that way out should not be offered")
        #expect(fixture.state.provider(for: fixture.providerID)?.status == .connected)
    }

    @Test("Relay Anthropic-compatible connection: the advanced-settings thinking prediction matches the thinking this connection actually sends")
    func relayAnthropicThinkingPredictionMatchesTheWire() async throws {
        // A relay's preference identity needs the metadata runtime revision (always present on a device).
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(json: """
        {"version": 1, "updatedAt": "2026-10-08T00:00:00Z",
         "capabilityRuntime": \(try CapabilityRuntimeFixtures.runtimeEnvelopeJSON()), "providers": {}}
        """)
        let fixture = Fixture(connectionDefaults: [:], additionalBody: nil, transport: .anthropicMessages)
        defer { fixture.cleanUp() }
        let store = GenerationParameterSettingsStore.shared
        let identity = try #require(CapabilityPreferenceRuntimeIdentity.make(provider: fixture.provider, model: fixture.model))
        let profile = GenerationProfileRef(
            template: "anthropic_messages",
            parameters: [
                GenerationParameterRef(id: "max_output_tokens", support: "supported", group: "budget", valueSchema: "integer"),
                GenerationParameterRef(id: "temperature", support: "supported", group: "sampling", valueSchema: "number"),
            ],
            wire: ["max_output_tokens": "max_tokens", "temperature": "temperature"],
            transport: "anthropic_messages"
        )
        func probe() -> GenerationParameterRowModel.ThinkingContext? {
            AdvancedSettingsThinkingProbe.activeThinking(
                provider: fixture.provider, model: fixture.model, conversationID: fixture.conversationID,
                profile: profile, store: store
            )
        }
        #expect(probe() == nil, "thinking was predicted on although no level was ever set")
        let off = try await fixture.send()
        #expect(AdditionalRequestBodyCaptureURLProtocol.captured.first?["thinking"] == nil, "precondition: no thinking is sent without a level")
        _ = off

        store.setCapabilityPreferences(
            .init(web: .inherit, reasoningIntent: "deep"),
            providerID: fixture.provider.id, modelID: identity.canonicalModelID,
            conversationID: fixture.conversationID, transportIdentity: identity.wireValue
        )
        _ = try await fixture.send(text: "deep-probe")
        let body = try #require(AdditionalRequestBodyCaptureURLProtocol.captured.last)
        let sent = AdvancedSettingsThinkingProbe.context(fromRequestFields: body)
        #expect(sent != nil, "precondition: with the Deep level stored, this connection does send thinking")
        #expect(probe() == sent, "predicted \(String(describing: probe())) but sent \(String(describing: sent))")

        // The criterion is the connection's protocol field alone: the same model name on the Chat Completions protocol is not predicted.
        var chat = fixture.provider
        chat.relayRequested = RelayRequestedConfig(transport: .openaiChatCompletions)
        #expect(AdvancedSettingsThinkingProbe.activeThinking(
            provider: chat, model: fixture.model, conversationID: fixture.conversationID, profile: profile, store: store
        ) == nil)
        await MetadataClient.shared.resetForTesting()
    }

    @Test("An error frame that arrives after some content was already streamed: the message fails, the received text stays, and no \"retry without the additional request body\" is offered")
    func streamErrorAfterContentKeepsTheTextAndFails() async throws {
        let fixture = Fixture(connectionDefaults: [:], additionalBody: #"{"top_k": 40}"#)
        defer { fixture.cleanUp() }
        AdditionalRequestBodyCaptureURLProtocol.reset(streams: [
            #"data: {"choices":[{"index":0,"delta":{"content":"Partial answer"}}]}"# + "\n\n"
                + #"data: {"error":{"code":"server_error","message":"Provider disconnected unexpectedly"},"choices":[{"index":0,"delta":{"content":""},"finish_reason":"error"}]}"# + "\n\n",
        ])
        let message = try await fixture.send(resetCapture: false)
        #expect(message.state == .failed, "the failure was recorded as \(message.state.rawValue)")
        #expect(message.text.contains("Partial answer"), "the received content was lost: \(message.text)")
        #expect(message.errorDetail?.contains("Provider disconnected unexpectedly") == true, "\(message.errorDetail ?? "nil")")
        // The upstream had already started answering, so this is not a rejection of the request body.
        #expect(message.errorTitle != AdditionalRequestBody.upstreamRejectionTitleKey)
        #expect(fixture.state.provider(for: fixture.providerID)?.status == .connected)
    }

    @Test("In-stream error before any content, with an additional request body: same as an upstream 400, offers retry without it")
    func streamErrorBeforeContentOffersRetryWithoutAdditionalBody() async throws {
        let fixture = Fixture(connectionDefaults: [:], additionalBody: #"{"temperature": "hot"}"#)
        defer { fixture.cleanUp() }
        AdditionalRequestBodyCaptureURLProtocol.reset(streams: [Self.lmStudioStreamError])
        let failed = try await fixture.send(resetCapture: false)
        #expect(AdditionalRequestBodyCaptureURLProtocol.captured.first?["temperature"] as? String == "hot")
        #expect(failed.state == .failed)
        #expect(failed.errorTitle == AdditionalRequestBody.upstreamRejectionTitleKey)
        #expect(failed.errorDetail?.contains("llm.prediction.temperature") == true)

        await fixture.state.retryMessage(
            messageID: failed.id, in: fixture.conversationID,
            localCustomFragmentDisposition: .forExplicitRetry(errorTitle: failed.errorTitle, recoveryDescriptorCount: nil)
        )
        let retried = try await fixture.waitForRequests(2)
        #expect(retried[1]["temperature"] == nil, "the retried request still carries the additional request body")
    }

    @Test("In-stream error after content arrived: reported as usual, without offering retry without the additional request body")
    func streamErrorAfterContentDoesNotOfferRetry() async throws {
        let fixture = Fixture(connectionDefaults: [:], additionalBody: #"{"top_k": 40}"#)
        defer { fixture.cleanUp() }
        let delta = "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"partial answer\"}}]}\n\n"
        AdditionalRequestBodyCaptureURLProtocol.reset(streams: [delta + Self.lmStudioStreamError])
        let message = try await fixture.send(resetCapture: false)
        #expect(message.state == .failed)
        #expect(message.text.contains("partial answer"), "content that had already arrived was dropped")
        #expect(message.errorTitle != AdditionalRequestBody.upstreamRejectionTitleKey)
    }

    @Test("Device-local: after a real send, sync envelopes, the parameter export and backups contain no additional request body")
    func nothingLeavesTheDeviceAfterARealSend() async throws {
        let marker = "zz_local_only_\(UUID().uuidString.prefix(8).lowercased())"
        let fixture = Fixture(
            connectionDefaults: ["top_p": .init(state: .value, value: .number(5))],
            additionalBody: #"{"\#(marker)": "\#(marker)-value"}"#
        )
        defer { fixture.cleanUp() }
        _ = try await fixture.send()
        #expect(AdditionalRequestBodyCaptureURLProtocol.captured.first?[marker] as? String == "\(marker)-value")

        let generationSync = String(decoding: try GenerationParameterSyncContract.exportJSON(), as: UTF8.self)
        #expect(generationSync.contains(fixture.providerID.uuidString.lowercased()), "the export did not read this connection, so the assertions below would be meaningless")
        #expect(!generationSync.contains(marker))
        let capabilitySync = String(
            decoding: try JSONEncoder().encode(CapabilityPreferenceSyncContract.exportPayload()), as: UTF8.self
        )
        #expect(!capabilitySync.contains(marker))

        let backup = try await BackupService.exportBackup(
            providers: fixture.state.providers,
            conversations: fixture.state.conversations,
            preferences: AppPreference(theme: .system, language: .english),
            lastUsedModelRef: nil, includeKeys: false, password: nil
        )
        let (parsed, _) = try BackupService.parseBackup(from: backup)
        #expect(parsed.data.conversations.contains { $0.id == fixture.conversationID })
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        #expect(!String(decoding: try encoder.encode(parsed.data), as: UTF8.self).contains(marker))
    }

    // MARK: - Fixture

    @MainActor
    final class Fixture {
        static let modelID = "relay-model"
        let providerID = UUID()
        let state: AppState
        let conversationID: UUID
        let provider: Provider
        let model: AIModel

        init(
            connectionDefaults: [String: GenerationParameterOverride],
            additionalBody: String?,
            sendsWithRequest: Bool = true,
            transport: RelayTransport = .openaiChatCompletions
        ) {
            AdditionalRequestBodyCaptureURLProtocol.reset()
            model = TestFactories.makeModel(id: Self.modelID, capabilities: [.text], isDefault: true)
            provider = Provider(
                id: providerID, kind: .relay, status: .connected,
                models: [model], catalogModels: [],
                apiKey: "relay-key", apiKeyPreview: "...key",
                baseURLText: "https://relay.test/v1",
                relayRequested: RelayRequestedConfig(transport: transport)
            )
            GenerationParameterSettingsStore.shared.setConnectionDefaults(
                GenerationParameterOverrides(values: connectionDefaults), providerID: providerID
            )
            if let additionalBody {
                // Written to the model-default scope, the same place the editor writes to when
                // opened from the provider detail page.
                GenerationParameterSettingsStore.shared.setAdditionalRequestBody(
                    .init(rawJSON: additionalBody, sendsWithRequest: sendsWithRequest),
                    providerID: providerID,
                    modelID: CapabilityPreferenceRuntimeIdentity.canonicalModelID(provider: provider, model: model),
                    conversationID: nil
                )
            }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [AdditionalRequestBodyCaptureURLProtocol.self]
            state = AppState(
                seedDemoData: false,
                sessionUID: "additional-request-body-\(UUID().uuidString)",
                providerSession: URLSession(configuration: configuration)
            )
            let conversation = TestFactories.makeConversation(
                providerID: providerID, providerKind: .relay, modelID: Self.modelID
            )
            conversationID = conversation.id
            state.providers = [provider]
            state.upsertConversationProjection(conversation)
        }

        var stored: AdditionalRequestBodyConfiguration? {
            GenerationParameterSettingsStore.shared.additionalRequestBody(
                providerID: providerID,
                modelID: CapabilityPreferenceRuntimeIdentity.canonicalModelID(provider: provider, model: model),
                conversationID: nil
            )
        }

        func cleanUp() {
            GenerationParameterSettingsStore.shared.setConnectionDefaults(nil, providerID: providerID)
            GenerationParameterSettingsStore.shared.removeCapabilityScopes(providerID: providerID)
            AdditionalRequestBodyCaptureURLProtocol.reset()
        }

        /// Sends one message and waits until its assistant message leaves the streaming state.
        func send(resetCapture: Bool = true, text: String = "Hello") async throws -> ChatMessage {
            if resetCapture { AdditionalRequestBodyCaptureURLProtocol.reset() }
            let before = state.conversation(for: conversationID)?.messages.count ?? 0
            _ = await state.sendMessage(
                text, in: conversationID,
                capabilitySelection: ChatCapabilitySelection(reasoningMode: .automatic, webSearchEnabled: false)
            )
            let deadline = ContinuousClock.now + .seconds(8)
            while ContinuousClock.now < deadline {
                if let messages = state.conversation(for: conversationID)?.messages, messages.count > before,
                   let last = messages.last, last.role == .assistant,
                   last.state == .failed || last.state == .delivered {
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    return try #require(state.conversation(for: conversationID)?.messages.last)
                }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            return try #require(state.conversation(for: conversationID)?.messages.last, "the send did not finish")
        }

        func waitForRequests(_ count: Int) async throws -> [[String: Any]] {
            let deadline = ContinuousClock.now + .seconds(8)
            while AdditionalRequestBodyCaptureURLProtocol.captured.count < count, ContinuousClock.now < deadline {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            let captured = AdditionalRequestBodyCaptureURLProtocol.captured
            try #require(captured.count >= count, "only \(captured.count) requests were sent, expected \(count)")
            try? await Task.sleep(nanoseconds: 300_000_000)
            return captured
        }
    }
}
