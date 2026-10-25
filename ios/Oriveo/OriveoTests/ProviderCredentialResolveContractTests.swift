import Foundation
import Testing
@testable import Oriveo

/// The single entry point for picking a key by model.
///
/// The fixture `shared/test-fixtures/relay/credential-resolve.v1.json` drives it by id; the same cases have the same names on all three platforms.
@Suite("Provider key resolution entry (iOS)", .serialized, .sharedProcessState)
struct ProviderCredentialResolveContractTests {

    // MARK: - Fixture

    private struct FixtureError: Error { let detail: String }

    private static func fixtureURL(_ relativePath: String) throws -> URL {
        var cursor = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while cursor.path != "/" {
            let candidate = cursor.appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            cursor.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }

    private static func loadFixture() throws -> [String: Any] {
        let data = try Data(contentsOf: fixtureURL("shared/test-fixtures/relay/credential-resolve.v1.json"))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private static func string(_ value: Any?) throws -> String {
        guard let text = value as? String else { throw FixtureError(detail: "missing string: \(String(describing: value))") }
        return text
    }

    private static func provider(_ raw: Any?) throws -> Provider {
        let object = try #require(raw as? [String: Any])
        let kindRaw = try string(object["kind"])
        let kind = try #require(ProviderKind(rawValue: kindRaw), "unknown kind: \(kindRaw)")
        let modelIDs = try #require(object["models"] as? [String])
        let models = modelIDs.enumerated().map { index, id in
            TestFactories.makeModel(id: id, capabilities: [.text], isDefault: index == 0)
        }
        return TestFactories.makeProvider(
            kind: kind,
            models: models,
            apiKey: try string(object["apiKey"]),
            baseURLText: object["baseURL"] as? String
        )
    }

    /// The provider for multiKeyCases: models are `{id, relayKeyID?}`, and relayKeys go through the production decoder.
    private static func multiKeyProvider(_ raw: Any?) throws -> Provider {
        let object = try #require(raw as? [String: Any])
        let kindRaw = try string(object["kind"])
        let kind = try #require(ProviderKind(rawValue: kindRaw), "unknown kind: \(kindRaw)")
        let rawModels = try #require(object["models"] as? [[String: Any]])
        let models = try rawModels.enumerated().map { index, entry in
            var model = TestFactories.makeModel(id: try string(entry["id"]), capabilities: [.text], isDefault: index == 0)
            model.relayKeyID = entry["relayKeyID"] as? String
            return model
        }
        var provider = TestFactories.makeProvider(
            kind: kind,
            models: models,
            apiKey: try string(object["apiKey"]),
            baseURLText: object["baseURL"] as? String
        )
        if let keys = object["relayKeys"] {
            provider.relayKeys = try JSONDecoder().decode(
                [RelayKey].self, from: JSONSerialization.data(withJSONObject: keys)
            )
        }
        return provider
    }

    private static func resolveMultiKeyCase(_ id: String) throws {
        let root = try loadFixture()
        let cases = try #require(root["multiKeyCases"] as? [[String: Any]])
        let item = try #require(cases.first { $0["id"] as? String == id }, "fixture is missing case \(id)")
        let provider = try multiKeyProvider(item["provider"])
        let expect = try string(item["expect"])
        #expect(ProviderCredentialResolver.apiKey(provider: provider, modelID: item["modelId"] as? String) == expect)
    }

    private static func resolveCase(_ id: String) throws {
        let root = try loadFixture()
        let cases = try #require(root["cases"] as? [[String: Any]])
        let item = try #require(cases.first { $0["id"] as? String == id }, "fixture is missing case \(id)")
        let provider = try provider(item["provider"])
        let modelID = item["modelId"] as? String
        let expect = try string(item["expect"])
        #expect(ProviderCredentialResolver.apiKey(provider: provider, modelID: modelID) == expect)
    }

    // MARK: - cases

    @Test("CREDENTIAL-RESOLVE-single_key_no_model")
    func single_key_no_model() throws { try Self.resolveCase("single_key_no_model") }

    @Test("CREDENTIAL-RESOLVE-single_key_enabled_model")
    func single_key_enabled_model() throws { try Self.resolveCase("single_key_enabled_model") }

    @Test("CREDENTIAL-RESOLVE-single_key_unknown_model")
    func single_key_unknown_model() throws { try Self.resolveCase("single_key_unknown_model") }

    @Test("CREDENTIAL-RESOLVE-single_key_whitespace_preserved")
    func single_key_whitespace_preserved() throws { try Self.resolveCase("single_key_whitespace_preserved") }

    @Test("CREDENTIAL-RESOLVE-empty_key_stays_empty")
    func empty_key_stays_empty() throws { try Self.resolveCase("empty_key_stays_empty") }

    @Test("CREDENTIAL-RESOLVE-official_provider_same_key")
    func official_provider_same_key() throws { try Self.resolveCase("official_provider_same_key") }

    @Test("The fixture's cases correspond one to one with this class's cases")
    func fixtureCasesCovered() throws {
        let root = try Self.loadFixture()
        let ids = try #require(root["cases"] as? [[String: Any]]).compactMap { $0["id"] as? String }
        #expect(Set(ids) == [
            "single_key_no_model", "single_key_enabled_model", "single_key_unknown_model",
            "single_key_whitespace_preserved", "empty_key_stays_empty", "official_provider_same_key",
        ])
    }

    // MARK: - multiKeyCases

    @Test("CREDENTIAL-RESOLVE-multi_bound_second_key")
    func multi_bound_second_key() throws { try Self.resolveMultiKeyCase("multi_bound_second_key") }

    @Test("CREDENTIAL-RESOLVE-multi_bound_primary")
    func multi_bound_primary() throws { try Self.resolveMultiKeyCase("multi_bound_primary") }

    @Test("CREDENTIAL-RESOLVE-multi_no_key_id_uses_primary")
    func multi_no_key_id_uses_primary() throws { try Self.resolveMultiKeyCase("multi_no_key_id_uses_primary") }

    @Test("CREDENTIAL-RESOLVE-multi_dangling_key_id_uses_primary")
    func multi_dangling_key_id_uses_primary() throws { try Self.resolveMultiKeyCase("multi_dangling_key_id_uses_primary") }

    @Test("CREDENTIAL-RESOLVE-multi_unknown_model_uses_primary")
    func multi_unknown_model_uses_primary() throws { try Self.resolveMultiKeyCase("multi_unknown_model_uses_primary") }

    @Test("CREDENTIAL-RESOLVE-multi_null_model_uses_primary")
    func multi_null_model_uses_primary() throws { try Self.resolveMultiKeyCase("multi_null_model_uses_primary") }

    @Test("CREDENTIAL-RESOLVE-multi_primary_slot_secret_ignored")
    func multi_primary_slot_secret_ignored() throws { try Self.resolveMultiKeyCase("multi_primary_slot_secret_ignored") }

    @Test("CREDENTIAL-RESOLVE-multi_bound_secret_not_trimmed")
    func multi_bound_secret_not_trimmed() throws { try Self.resolveMultiKeyCase("multi_bound_secret_not_trimmed") }

    @Test("CREDENTIAL-RESOLVE-official_provider_ignores_relay_keys")
    func official_provider_ignores_relay_keys() throws { try Self.resolveMultiKeyCase("official_provider_ignores_relay_keys") }

    @Test("The fixture's multiKeyCases correspond one to one with this class's cases")
    func multiKeyCasesCovered() throws {
        let root = try Self.loadFixture()
        let ids = try #require(root["multiKeyCases"] as? [[String: Any]]).compactMap { $0["id"] as? String }
        #expect(Set(ids) == [
            "multi_bound_second_key", "multi_bound_primary", "multi_no_key_id_uses_primary",
            "multi_dangling_key_id_uses_primary", "multi_unknown_model_uses_primary", "multi_null_model_uses_primary",
            "multi_primary_slot_secret_ignored", "multi_bound_secret_not_trimmed", "official_provider_ignores_relay_keys",
        ])
    }

    // MARK: - sendCase: outbound through the production chat send chain

    @Test("CREDENTIAL-RESOLVE-SEND-relay_single_key_authorization")
    @MainActor
    func send_relay_single_key_authorization() async throws {
        await MetadataClient.shared.resetForTesting()
        let root = try Self.loadFixture()
        let sendCase = try #require(root["sendCase"] as? [String: Any])
        #expect(sendCase["id"] as? String == "SEND-relay_single_key_authorization")
        var provider = try Self.provider(sendCase["provider"])
        provider.relayRequested = RelayRequestedConfig(transport: .openaiChatCompletions, authMode: .bearer)
        let modelID = try Self.string(sendCase["modelId"])
        let expectAuthorization = try Self.string(sendCase["expectAuthorization"])

        CredentialCaptureProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CredentialCaptureProtocol.self]
        let state = AppState(
            sessionUID: "credential-resolve-tests-\(UUID().uuidString)",
            providerSession: URLSession(configuration: config)
        )
        let conversationID = UUID()
        state.providers = [provider]
        state.conversations = [TestFactories.makeConversation(
            id: conversationID, providerID: provider.id, providerKind: .relay, modelID: modelID, messages: []
        )]

        let before = state.conversation(for: conversationID)?.messages.count ?? 0
        #expect(await state.chatManager.sendMessage("hi", in: conversationID) != nil)
        for _ in 0..<100 {
            let messages = state.conversation(for: conversationID)?.messages ?? []
            if messages.count > before,
               let assistant = messages.last(where: { $0.role == .assistant }),
               assistant.state != .generating { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        let chat = try #require(
            CredentialCaptureProtocol.captured.first { $0.url?.path.hasSuffix("/chat/completions") == true },
            "chat request was not sent: \(CredentialCaptureProtocol.captured.map { $0.url?.absoluteString ?? "" })"
        )
        #expect(chat.value(forHTTPHeaderField: "Authorization") == expectAuthorization)
        Self.retainedStates.append(state)
    }

    @Test("CREDENTIAL-RESOLVE-SEND-relay_bound_key_authorization")
    @MainActor
    func send_relay_bound_key_authorization() async throws {
        await MetadataClient.shared.resetForTesting()
        let root = try Self.loadFixture()
        let sendCase = try #require(root["multiKeySendCase"] as? [String: Any])
        #expect(sendCase["id"] as? String == "SEND-relay_bound_key_authorization")
        var provider = try Self.multiKeyProvider(sendCase["provider"])
        provider.relayRequested = RelayRequestedConfig(transport: .openaiChatCompletions, authMode: .bearer)
        let expect = try #require(sendCase["expect"] as? [String: String])

        CredentialCaptureProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CredentialCaptureProtocol.self]
        let state = AppState(
            sessionUID: "credential-resolve-tests-\(UUID().uuidString)",
            providerSession: URLSession(configuration: config)
        )
        state.providers = [provider]
        Self.retainedStates.append(state)

        for (modelID, expectAuthorization) in expect.sorted(by: { $0.key < $1.key }) {
            CredentialCaptureProtocol.reset()
            let conversationID = UUID()
            state.conversations = [TestFactories.makeConversation(
                id: conversationID, providerID: provider.id, providerKind: .relay, modelID: modelID, messages: []
            )]
            #expect(await state.chatManager.sendMessage("hi", in: conversationID) != nil)
            for _ in 0..<100 {
                let messages = state.conversation(for: conversationID)?.messages ?? []
                if let assistant = messages.last(where: { $0.role == .assistant }),
                   assistant.state != .generating { break }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            let chat = try #require(
                CredentialCaptureProtocol.captured.first { $0.url?.path.hasSuffix("/chat/completions") == true },
            "\(modelID) chat request was not sent"
            )
            #expect(chat.value(forHTTPHeaderField: "Authorization") == expectAuthorization, "\(modelID)")
        }
    }

    // Consistent with LocalEngineEditAndThinkingContractTests in the same repo: keep AppState alive for the duration of the test.
    @MainActor private static var retainedStates: [AppState] = []
}

private final class CredentialCaptureProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var storage: [URLRequest] = []

    static var captured: [URLRequest] { lock.withLock { storage } }
    static func reset() { lock.withLock { storage = [] } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.withLock { Self.storage.append(request) }
        let payload = """
        data: {"choices":[{"delta":{"content":"ok"}}]}

        data: {"choices":[{"delta":{},"finish_reason":"stop"}]}

        data: [DONE]


        """
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "text/event-stream"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(payload.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
