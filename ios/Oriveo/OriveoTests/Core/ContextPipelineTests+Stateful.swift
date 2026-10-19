import Foundation
import GRDB
import OriveoProviderKit
import Testing
@testable import Oriveo

/// Captures the Responses continuation request body (each case only takes the first request).
private final class StatefulResponsesURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var capturedBody: [String: Any]?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if Self.capturedBody == nil, let body = Self.bodyObject(of: request) {
            Self.capturedBody = body
        }
        let url = request.url ?? URL(string: "https://responses.invalid")!
        let response = HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "text/event-stream"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("data: [DONE]\n\n".utf8))
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

/// Responses continuation is decided by the recipe's continuationInstructionsMode and ContextContinuation,
/// which determine whether previous_response_id / instructions are sent; assertions read the request bodies the production Service actually emits.
extension ContextPipelineTests {

    private static let statefulPreviousID = "resp_k2_previous"
    private static let statefulSystem = "Answer in haiku."

    @Test func stateful_openai_resend_sends_instructions_and_previous_id() async throws {
        let body = try await Self.statefulBody(
            provider: .openAI, recipeRef: "openai.responses.web.v1", modelID: "gpt-5.6-terra",
            serverProviderKey: "openAI", mode: "resend", fingerprintMatches: true
        )
        #expect(body["previous_response_id"] as? String == Self.statefulPreviousID)
        #expect(body["instructions"] as? String == Self.statefulSystem)
        #expect((body["input"] as? [Any])?.count == 1, "stateful leg sends only the current user turn")
    }

    @Test func stateful_grok_omit_drops_instructions() async throws {
        let body = try await Self.statefulBody(
            provider: .grok, recipeRef: "grok.responses.web.v1", modelID: "grok-4.3",
            serverProviderKey: "grok", mode: "omit", fingerprintMatches: true
        )
        #expect(body["previous_response_id"] as? String == Self.statefulPreviousID)
        #expect(body["instructions"] == nil, "Grok rejects instructions together with previous_response_id")
        #expect((body["input"] as? [Any])?.count == 1, "stateful leg sends only the current user turn")
    }

    @Test func stateful_missing_mode_sends_full_plan() async throws {
        let body = try await Self.statefulBody(
            provider: .openAI, recipeRef: "openai.responses.web.v1", modelID: "gpt-5.6-terra",
            serverProviderKey: "openAI", mode: nil, fingerprintMatches: true
        )
        #expect(body["previous_response_id"] == nil)
        #expect(body["instructions"] as? String == Self.statefulSystem)
        #expect((body["input"] as? [Any])?.count == 3, "full plan replays the whole history")
    }

    @Test func stateful_fingerprint_mismatch_sends_full_plan() async throws {
        let body = try await Self.statefulBody(
            provider: .openAI, recipeRef: "openai.responses.web.v1", modelID: "gpt-5.6-terra",
            serverProviderKey: "openAI", mode: "resend", fingerprintMatches: false
        )
        #expect(body["previous_response_id"] == nil)
        #expect(body["instructions"] as? String == Self.statefulSystem)
        #expect((body["input"] as? [Any])?.count == 3, "full plan replays the whole history")
    }

    /// Stateful continuation is only used for an explicit "continue". Regenerate does not borrow the continuation record of the previous answer.
    @Test func regenerate_never_stateful() async throws {
        let bodies = try await Self.redoBodies(retry: false)
        let body = try #require(bodies.last)
        #expect(body["previous_response_id"] == nil)
        #expect(body["instructions"] as? String == bodies.first?["instructions"] as? String)
        let input = body["input"] as? [[String: Any]] ?? []
        #expect(input.count == 1, "full plan replays the history without the regenerated answer")
    }

    /// A failure retry is likewise always a full plan: a continuation record left on the failed message must not become previous_response_id.
    @Test func retry_never_stateful() async throws {
        let bodies = try await Self.redoBodies(retry: true)
        let body = try #require(bodies.last)
        #expect(body["previous_response_id"] == nil)
        #expect(body["instructions"] as? String == bodies.first?["instructions"] as? String)
        let input = body["input"] as? [[String: Any]] ?? []
        #expect(input.count == 1, "full plan replays the history without the retried answer")
    }

    // MARK: Fixtures

    private static func statefulBody(
        provider: ProviderKind, recipeRef: String, modelID: String, serverProviderKey: String,
        mode: String?, fingerprintMatches: Bool
    ) async throws -> [String: Any] {
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(json: try statefulMetadata(
            recipeRef: recipeRef, modelID: modelID, serverProviderKey: serverProviderKey, mode: mode
        ))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("oriveo-k2-stateful-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let pool = try DatabasePool(path: directory.appendingPathComponent("sidecar.sqlite").path)
        let store = try RecipeContinuationStore(dbPool: pool)
        defer {
            try? pool.close()
            try? FileManager.default.removeItem(at: directory)
        }

        let assistantID = UUID()
        try store.save(
            messageID: assistantID, kind: "previous_id",
            state: ["previousResponseId": .string(statefulPreviousID)]
        )
        func message(_ role: ChatRole, _ text: String, id: UUID = UUID()) -> ChatMessage {
            ChatMessage(
                id: id, role: role, text: text, providerKind: provider, providerName: provider.displayName,
                modelID: modelID, modelName: modelID, state: .delivered
            )
        }
        let messages = [
            message(.user, "first question"),
            message(.assistant, "partial", id: assistantID),
            message(.user, "continue"),
        ]
        var options = ChatRequestOptions()
        options.systemPrompt = statefulSystem
        options.localExplicitContinuationMessageID = assistantID
        // These cases simulate an explicit "continue": the request carries the continuation sentence (written by ChatRequestBuilder for purpose continue).
        options.statefulLegText = ContextAssembler.continuePrompt
        options.continuationFingerprintMatches = fingerprintMatches

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StatefulResponsesURLProtocol.self]
        let session = URLSession(configuration: configuration)
        StatefulResponsesURLProtocol.capturedBody = nil
        defer { StatefulResponsesURLProtocol.capturedBody = nil }

        try await RecipeContinuationRuntime.withStore(store) {
            let stream: AsyncThrowingStream<StreamEvent, Error>
            switch provider {
            case .grok:
                stream = GrokService(session: session).sendMessageStream(
                    apiKey: "test-key", modelID: modelID, messages: messages,
                    reasoningMode: .automatic, webSearchEnabled: true, requestOptions: options
                )
            default:
                stream = OpenAIService(session: session).sendMessageStream(
                    apiKey: "test-key", modelID: modelID, messages: messages,
                    reasoningMode: .automatic, webSearchEnabled: true, requestOptions: options
                )
            }
            do { for try await _ in stream {} } catch {}
        }
        await MetadataClient.shared.resetForTesting()
        return try #require(StatefulResponsesURLProtocol.capturedBody, "service issued no request")
    }

    /// Grok Responses: send one message first (storing previousResponseId and the fingerprint on completion), then regenerate / retry after failure on that answer. Returns both request bodies.
    private static func redoBodies(retry: Bool) async throws -> [[String: Any]] {
        let modelID = "grok-4.3"
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(json: try statefulMetadata(
            recipeRef: "grok.responses.web.v1", modelID: modelID, serverProviderKey: "grok", mode: "omit"
        ))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("oriveo-a7-redo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let pool = try DatabasePool(path: directory.appendingPathComponent("sidecar.sqlite").path)
        let store = try RecipeContinuationStore(dbPool: pool)
        defer {
            try? pool.close()
            try? FileManager.default.removeItem(at: directory)
        }

        let providerID = UUID()
        let model = TestFactories.makeModel(id: modelID, capabilities: [.text], isDefault: true)
        let provider = Provider(
            id: providerID, kind: .grok, status: .connected, models: [model], catalogModels: [],
            apiKey: "grok-key", apiKeyPreview: "...key", baseURLText: ""
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OverflowURLProtocol.self]
        let state = AppState(
            seedDemoData: false,
            sessionUID: "context-pipeline-redo-\(UUID().uuidString)",
            providerSession: URLSession(configuration: configuration)
        )
        state.preferences.memoryText = "The user prefers green tea."
        var conversation = TestFactories.makeConversation(
            providerID: providerID, providerKind: .grok, modelID: modelID, messages: []
        )
        conversation.useMemory = true
        state.providers = [provider]
        state.upsertConversationProjection(conversation)

        var selection = ChatCapabilitySelection()
        selection.webSearchEnabled = true
        selection.typedPreferences = CapabilityPreferenceValues(web: .automatic)
        OverflowURLProtocol.reset([
            .init(status: 200, body: redoSSE(text: "First", responseID: "resp_a7_first")),
            .init(status: 200, body: redoSSE(text: "Second", responseID: "resp_a7_second")),
        ])
        defer { OverflowURLProtocol.reset([]) }

        await RecipeContinuationRuntime.$storeFactory.withValue({ store }) {
            _ = await state.sendMessage("Question", in: conversation.id, capabilitySelection: selection)
            try? await redoSettled(state, conversationID: conversation.id)
            guard let answerID = state.conversation(for: conversation.id)?.messages.last?.id else { return }
            let saved = RecipeContinuationRuntime.load(messageID: answerID)
            let savedID: String? = if case let .string(value)? = saved?.state["previousResponseId"] { value } else { nil }
            #expect(savedID == "resp_a7_first", "sidecar after first answer: \(String(describing: saved))")
            if retry {
                // The answer fails after a continuation record was stored (for example a later continue errors out): the record is still there, and the retry must not read it.
                guard var failed = state.conversation(for: conversation.id) else { return }
                failed.messages[failed.messages.count - 1].state = .failed
                state.upsertConversationProjection(failed)
                await state.chatManager.retryMessage(
                    messageID: answerID, in: conversation.id, capabilitySelection: selection
                )
            } else {
                await state.chatManager.regenerateMessage(
                    messageID: answerID, in: conversation.id, capabilitySelection: selection
                )
            }
            try? await redoSettled(state, conversationID: conversation.id)
        }
        await MetadataClient.shared.resetForTesting()
        let bodies = OverflowURLProtocol.bodies
        #expect(bodies.count == 2, "expected the first send and the redo request")
        return bodies
    }

    private static func redoSSE(text: String, responseID: String) -> String {
        let delta = #"{"type":"response.output_text.delta","delta":"\#(text)"}"#
        let completed = #"{"type":"response.completed","response":{"id":"\#(responseID)","status":"completed"}}"#
        return "event: response.output_text.delta\ndata: \(delta)\n\n"
            + "event: response.completed\ndata: \(completed)\n\n"
    }

    private static func redoSettled(_ state: AppState, conversationID: UUID) async throws {
        let deadline = ContinuousClock.now + .seconds(8)
        try await Task.sleep(nanoseconds: 50_000_000)
        while ContinuousClock.now < deadline {
            let last = state.conversation(for: conversationID)?.messages.last
            if last?.role == .assistant, last?.state != .generating { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        try? await Task.sleep(nanoseconds: 300_000_000)
    }

    /// Installs only one vetted recipe (from capability_runtime.v1.json) and fills in continuationInstructionsMode per case.
    static func statefulMetadata(
        recipeRef: String, modelID: String, serverProviderKey: String, mode: String?
    ) throws -> String {
        let root = try repositoryRoot()
        func object(_ path: String) throws -> [String: Any] {
            try #require(JSONSerialization.jsonObject(
                with: Data(contentsOf: root.appendingPathComponent(path))
            ) as? [String: Any])
        }
        let base = "shared/capabilityrecipe/"
        let registry = try object(base + "capability_runtime.v1.json")
        let definitions = try object(base + "capability_result_definitions.v1.json")
        var recipes = try #require(registry["recipes"] as? [String: Any])
        var recipe = try #require(recipes[recipeRef] as? [String: Any])
        if let binding = (definitions["recipeBindings"] as? [String: [String: Any]])?[recipeRef] {
            recipe["responseEvidenceRef"] = binding["responseEvidenceRef"]
            recipe["errorRecoveryRef"] = binding["errorRecoveryRef"]
        }
        recipe["continuationInstructionsMode"] = mode
        recipes[recipeRef] = recipe
        let capability = try #require(recipe["capability"] as? String)
        let document: [String: Any] = [
            "version": 1,
            "providers": [serverProviderKey: [
                "resolveMap": [modelID: modelID],
                "models": [modelID: [
                    "canonicalModelId": modelID,
                    "transport": "openai_responses",
                    "capabilityControls": [capability: ["state": "auto_available", "recipeRef": recipeRef]],
                ]],
            ]],
            "capabilityRuntime": [
                "schemaVersion": 2, "revision": "k2-stateful", "generatedAt": "2026-10-15T00:00:00Z",
                "recipes": recipes, "controlDefinitions": registry["controlDefinitions"] ?? [:],
                "sourceIndex": registry["sourceIndex"] ?? [:],
            ],
        ]
        return String(decoding: try JSONSerialization.data(withJSONObject: document), as: UTF8.self)
    }

    static func repositoryRoot() throws -> URL {
        var folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while folder.path != folder.deletingLastPathComponent().path {
            if FileManager.default.fileExists(atPath: folder.appendingPathComponent("shared").path) { return folder }
            folder.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }
}
