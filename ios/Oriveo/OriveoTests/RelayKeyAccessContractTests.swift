import Foundation
import Testing
@testable import Oriveo

/// Cross-platform contract for the relay "is this the key" access decision.
///
/// Fixture `shared/test-fixtures/relay/key-access.v1.json`: classifyCases drive the pure function,
/// and two sendCases go through the production `AppState.sendMessage` to assert request count, negative-cache writes, model fields and key status.
@Suite("Relay multi-key · access-denied classification", .serialized)
@MainActor
struct RelayKeyAccessContractTests {

    // MARK: - Fixtures

    private static func fixture() throws -> [String: Any] {
        var cursor = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while cursor.path != "/" {
            let candidate = cursor.appendingPathComponent("shared/test-fixtures/relay/key-access.v1.json")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: candidate)) as? [String: Any])
            }
            cursor.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }

    private static func metadataFixture() throws -> String {
        var cursor = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while cursor.path != "/" {
            let candidate = cursor.appendingPathComponent("shared/test-fixtures/relay/metadata-fixture.json")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return String(decoding: try Data(contentsOf: candidate), as: UTF8.self)
            }
            cursor.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }

    private static func classifyCase(_ caseId: String) throws -> [String: Any] {
        let cases = try #require(try fixture()["classifyCases"] as? [[String: Any]])
        return try #require(cases.first { $0["caseId"] as? String == caseId }, "Fixture is missing classifyCases/\(caseId)")
    }

    private static func sendCase(_ caseId: String) throws -> [String: Any] {
        let cases = try #require(try fixture()["sendCases"] as? [[String: Any]])
        return try #require(cases.first { $0["caseId"] as? String == caseId }, "Fixture is missing sendCases/\(caseId)")
    }

    // MARK: - classifyCases

    private func runClassify(_ caseId: String) throws {
        let item = try Self.classifyCase(caseId)
        let status = try #require(item["status"] as? Int)
        let body = try #require(item["body"] as? String)
        let outcome = RelayKeyAccess.classify(status: status, body: Data(body.utf8))
        #expect(outcome.rawValue == item["expect"] as? String, "\(caseId)")
    }

    @Test("KEY-ACCESS-new_api_token_model_forbidden_403") func c01() throws { try runClassify("new_api_token_model_forbidden_403") }
    @Test("KEY-ACCESS-one_api_token_model_forbidden_403") func c02() throws { try runClassify("one_api_token_model_forbidden_403") }
    @Test("KEY-ACCESS-one_hub_model_not_supported_for_token_404") func c03() throws { try runClassify("one_hub_model_not_supported_for_token_404") }
    @Test("KEY-ACCESS-sub2api_group_allowlist_openai_404") func c04() throws { try runClassify("sub2api_group_allowlist_openai_404") }
    @Test("KEY-ACCESS-sub2api_group_allowlist_anthropic_404") func c05() throws { try runClassify("sub2api_group_allowlist_anthropic_404") }
    @Test("KEY-ACCESS-done_hub_group_permission_403") func c06() throws { try runClassify("done_hub_group_permission_403") }
    @Test("KEY-ACCESS-cliproxy_unknown_model_400") func c07() throws { try runClassify("cliproxy_unknown_model_400") }
    @Test("KEY-ACCESS-litellm_key_model_access_denied_403") func c08() throws { try runClassify("litellm_key_model_access_denied_403") }
    @Test("KEY-ACCESS-openai_model_not_found_404") func c09() throws { try runClassify("openai_model_not_found_404") }
    @Test("KEY-ACCESS-done_hub_folded_503_is_none") func c10() throws { try runClassify("done_hub_folded_503_is_none") }
    @Test("KEY-ACCESS-new_api_no_channel_503_is_none") func c11() throws { try runClassify("new_api_no_channel_503_is_none") }
    @Test("KEY-ACCESS-capability_rejection_400_is_none") func c12() throws { try runClassify("capability_rejection_400_is_none") }
    @Test("KEY-ACCESS-route_not_found_404_is_none") func c13() throws { try runClassify("route_not_found_404_is_none") }
    @Test("KEY-ACCESS-anthropic_route_not_found_404_is_none") func c14() throws { try runClassify("anthropic_route_not_found_404_is_none") }
    @Test("KEY-ACCESS-sub2api_messages_dispatch_403_is_none") func c15() throws { try runClassify("sub2api_messages_dispatch_403_is_none") }
    @Test("KEY-ACCESS-litellm_route_not_allowed_403_is_none") func c16() throws { try runClassify("litellm_route_not_allowed_403_is_none") }
    @Test("KEY-ACCESS-invalid_key_401") func c17() throws { try runClassify("invalid_key_401") }
    @Test("KEY-ACCESS-invalid_key_plain_string_401") func c18() throws { try runClassify("invalid_key_plain_string_401") }
    @Test("KEY-ACCESS-sub2api_key_expired_403") func c19() throws { try runClassify("sub2api_key_expired_403") }
    @Test("KEY-ACCESS-sub2api_insufficient_balance_403") func c20() throws { try runClassify("sub2api_insufficient_balance_403") }
    @Test("KEY-ACCESS-new_api_insufficient_user_quota_403") func c21() throws { try runClassify("new_api_insufficient_user_quota_403") }
    @Test("KEY-ACCESS-openrouter_payment_required_402") func c22() throws { try runClassify("openrouter_payment_required_402") }
    @Test("KEY-ACCESS-quota_exhausted_429") func c23() throws { try runClassify("quota_exhausted_429") }
    @Test("KEY-ACCESS-litellm_budget_exceeded_422_is_none") func c24() throws { try runClassify("litellm_budget_exceeded_422_is_none") }
    @Test("KEY-ACCESS-official_claude_cli_gate_403_is_none") func c28() throws { try runClassify("official_claude_cli_gate_403_is_none") }
    @Test("KEY-ACCESS-plain_403_without_signal_is_none") func c25() throws { try runClassify("plain_403_without_signal_is_none") }
    @Test("KEY-ACCESS-server_error_500_is_none") func c26() throws { try runClassify("server_error_500_is_none") }
    @Test("KEY-ACCESS-empty_body_404_is_none") func c27() throws { try runClassify("empty_body_404_is_none") }

    @Test("KEY-ACCESS fixture signals / outcomes match the production vocabulary, and every caseId has a test of the same name")
    func signalsMatchFixture() throws {
        let root = try Self.fixture()
        #expect(root["outcomes"] as? [String] == RelayKeyAccess.Outcome.allCases.map(\.rawValue))
        let signals = try #require(root["signals"] as? [String: Any])
        let denied = try #require(signals["modelAccessDenied"] as? [String: Any])
        #expect(Set(denied["statuses"] as? [Int] ?? []) == RelayKeyAccess.modelAccessDeniedStatuses)
        #expect(denied["codes"] as? [String] == RelayKeyAccess.modelAccessDeniedCodes)
        #expect(denied["phrases"] as? [String] == RelayKeyAccess.modelAccessDeniedPhrases)
        let invalid = try #require(signals["keyInvalid"] as? [String: Any])
        #expect(Set(invalid["statuses"] as? [Int] ?? []) == RelayKeyAccess.keyInvalidStatuses)
        #expect(invalid["codes403"] as? [String] == RelayKeyAccess.keyInvalidCodes403)
        let limited = try #require(signals["keyLimited"] as? [String: Any])
        #expect(Set(limited["statuses"] as? [Int] ?? []) == RelayKeyAccess.keyLimitedStatuses)
        #expect(limited["codes403"] as? [String] == RelayKeyAccess.keyLimitedCodes403)

        let classifyIDs = Set((root["classifyCases"] as? [[String: Any]] ?? []).compactMap { $0["caseId"] as? String })
        #expect(classifyIDs.count == 28)
        let sendIDs = Set((root["sendCases"] as? [[String: Any]] ?? []).compactMap { $0["caseId"] as? String })
        #expect(sendIDs == [
            "SEND-denied_404_skips_negative_cache_and_protocol_fallback",
            "SEND-invalid_401_marks_key_status",
            "SEND-delivered_single_key_materializes_ok",
            "SEND-invalid_401_single_key_materializes",
        ])
        let generation = try #require(root["generationCases"] as? [String: Any])
        let generationIDs = Set((generation["cases"] as? [[String: Any]] ?? []).compactMap { $0["caseId"] as? String })
        #expect(generationIDs == [
            "success_200_is_ok", "invalid_key_401_is_invalid", "insufficient_balance_403_is_limited",
            "quota_exhausted_429_is_limited", "model_denied_404_leaves_key", "client_gate_403_leaves_key",
            "plain_403_leaves_key", "route_404_leaves_key", "capability_400_leaves_key", "server_503_leaves_key",
            "network_leaves_key",
        ])
    }

    // MARK: - generationCases

    private func runGeneration(_ caseId: String) throws {
        let generation = try #require(try Self.fixture()["generationCases"] as? [String: Any])
        let cases = try #require(generation["cases"] as? [[String: Any]])
        let item = try #require(cases.first { $0["caseId"] as? String == caseId }, "Fixture is missing generationCases/\(caseId)")
        let body = try #require(item["body"] as? String)
        let state = RelayKeyAccess.generationStatus(status: item["status"] as? Int, body: body)
        #expect(state?.rawValue == item["expect"] as? String, "\(caseId)")
    }

    @Test("KEY-ACCESS-GEN-success_200_is_ok") func g01() throws { try runGeneration("success_200_is_ok") }
    @Test("KEY-ACCESS-GEN-invalid_key_401_is_invalid") func g02() throws { try runGeneration("invalid_key_401_is_invalid") }
    @Test("KEY-ACCESS-GEN-insufficient_balance_403_is_limited") func g03() throws { try runGeneration("insufficient_balance_403_is_limited") }
    @Test("KEY-ACCESS-GEN-quota_exhausted_429_is_limited") func g04() throws { try runGeneration("quota_exhausted_429_is_limited") }
    @Test("KEY-ACCESS-GEN-model_denied_404_leaves_key") func g05() throws { try runGeneration("model_denied_404_leaves_key") }
    @Test("KEY-ACCESS-GEN-client_gate_403_leaves_key") func g06() throws { try runGeneration("client_gate_403_leaves_key") }
    @Test("KEY-ACCESS-GEN-plain_403_leaves_key") func g07() throws { try runGeneration("plain_403_leaves_key") }
    @Test("KEY-ACCESS-GEN-route_404_leaves_key") func g08() throws { try runGeneration("route_404_leaves_key") }
    @Test("KEY-ACCESS-GEN-capability_400_leaves_key") func g09() throws { try runGeneration("capability_400_leaves_key") }
    @Test("KEY-ACCESS-GEN-server_503_leaves_key") func g10() throws { try runGeneration("server_503_leaves_key") }
    @Test("KEY-ACCESS-GEN-network_leaves_key") func g11() throws { try runGeneration("network_leaves_key") }

    // MARK: - sendCases (production send path)

    private static var retainedStates: [AppState] = []

    private static func boundModel() -> AIModel {
        // The model's own protocol comes from a probe (reachable): a 404 would normally trigger a protocol-level fallback, which proves access-denied does not fall back.
        var model = AIModel(
            id: "gpt-5", name: "gpt-5", capabilities: [.text],
            reasoningModeAvailable: false, isAvailable: true, isDefault: false, priceTier: ""
        )
        model.relayTransport = .openaiResponses
        model.relayTransportSource = .reachable
        model.relayKeyID = "k-claude"
        return model
    }

    private static func multiKeyProvider(models: [AIModel]) -> Provider {
        var provider = Provider(
            id: UUID(),
            kind: .relay,
            status: .connected,
            models: models,
            catalogModels: [],
            apiKey: "sk-primary",
            apiKeyPreview: "...mary",
            baseURLText: "https://relay.test/v1",
            relayRequested: RelayRequestedConfig(transport: .openaiChatCompletions)
        )
        provider.relayKeys = [RelayKey(id: "initial", name: "OpenAI"), RelayKey(id: "k-claude", name: "Claude", apiKey: "sk-claude")]
        return provider
    }

    private static func imageAttachment() -> Oriveo.Attachment {
        Oriveo.Attachment(
            id: UUID(), kind: .image, fileName: "p.png", mimeType: "image/png",
            base64Data: RelayCapabilityTest.imagePNGBase64
        )
    }

    private static func anyNegativeCacheEntry(connection: UUID, modelID: String) -> Bool {
        RelayTransport.allCases.contains { transport in
            RelayNegativeCache.Kind.allCases.contains { kind in
                RelayNegativeCache.shared.isRejected(
                    connectionID: connection.uuidString, modelID: modelID,
                    transport: transport.rawValue, kind: kind
                )
            }
        }
    }

    /// Sends one message through the production `AppState.sendMessage` and waits until the assistant message reaches a terminal state.
    private static func send(
        provider: Provider,
        modelID: String,
        attachments: [Oriveo.Attachment]
    ) async throws -> (state: AppState, message: ChatMessage) {
        let state = AppState(
            seedDemoData: false,
            sessionUID: "relay-key-access-\(UUID().uuidString)",
            providerSession: RelayKeyAccessScriptedProtocol.session()
        )
        retainedStates.append(state)
        let conversation = TestFactories.makeConversation(
            providerID: provider.id, providerKind: .relay, modelID: modelID
        )
        state.providers = [provider]
        state.upsertConversationProjection(conversation)
        _ = await state.sendMessage("Describe it", attachments: attachments, in: conversation.id)

        let deadline = ContinuousClock.now + .seconds(8)
        while ContinuousClock.now < deadline {
            if let message = state.conversation(for: conversation.id)?.messages.last,
               message.role == .assistant,
               message.state == .failed || message.state == .delivered {
                try await Task.sleep(nanoseconds: 300_000_000)
                return (state, state.conversation(for: conversation.id)?.messages.last ?? message)
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw CancellationError()
    }

    @Test("KEY-ACCESS-SEND-denied_404_skips_negative_cache_and_protocol_fallback")
    func sendDeniedSkipsNegativeCacheAndFallback() async throws {
        let item = try Self.sendCase("SEND-denied_404_skips_negative_cache_and_protocol_fallback")
        let expect = try #require(item["expect"] as? [String: Any])
        ProviderAPIKeyStore.useInMemoryBackendForTesting(true)
        defer { ProviderAPIKeyStore.useInMemoryBackendForTesting(false) }
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(json: try Self.metadataFixture())

        let model = Self.boundModel()
        #expect(model.relayKeyID == item["boundKeyID"] as? String)
        let provider = Self.multiKeyProvider(models: [model])
        defer { RelayNegativeCache.shared.clearConnection(provider.id.uuidString) }
        RelayKeyAccessScriptedProtocol.reset([
            .json(status: try #require(item["status"] as? Int), body: try #require(item["body"] as? String)),
            .sse(body: RelayKeyAccessScriptedProtocol.chatOK),
        ])

        let (state, message) = try await Self.send(
            provider: provider, modelID: model.id, attachments: [Self.imageAttachment()]
        )
        #expect(message.state == .failed, "\(message.errorDetail ?? "")")
        let requests = RelayKeyAccessScriptedProtocol.requests
        #expect(requests.count == expect["requestsSent"] as? Int, "\(requests.map { $0.url?.path ?? "" })")
        #expect(requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer sk-claude", "The request is sent with the bound key")
        #expect(expect["negativeCacheWrites"] as? Int == 0)
        #expect(!Self.anyNegativeCacheEntry(connection: provider.id, modelID: model.id))
        let stored = try #require(state.provider(for: provider.id)?.models.first { $0.id == model.id })
        #expect(stored.relayDeniedKeyID == expect["deniedKeyID"] as? String)
        #expect(stored.relayTransport == .openaiResponses, "No protocol-level fallback and no observed write")
        #expect(stored.relayKeyID == "k-claude", "The key is not switched automatically")
        #expect(message.recoveryPrimaryAction != relayImageUnsupportedRecoveryAction)
    }

    @Test("KEY-ACCESS-SEND-invalid_401_marks_key_status")
    func sendInvalidMarksKeyStatus() async throws {
        let item = try Self.sendCase("SEND-invalid_401_marks_key_status")
        let expect = try #require(item["expect"] as? [String: Any])
        ProviderAPIKeyStore.useInMemoryBackendForTesting(true)
        defer { ProviderAPIKeyStore.useInMemoryBackendForTesting(false) }
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(json: try Self.metadataFixture())

        let model = Self.boundModel()
        let provider = Self.multiKeyProvider(models: [model])
        defer { RelayNegativeCache.shared.clearConnection(provider.id.uuidString) }
        RelayKeyAccessScriptedProtocol.reset([
            .json(status: try #require(item["status"] as? Int), body: try #require(item["body"] as? String)),
        ])
        let before = Date()

        let (state, message) = try await Self.send(provider: provider, modelID: model.id, attachments: [])
        #expect(message.state == .failed)
        #expect(RelayKeyAccessScriptedProtocol.requests.count == 1)
        let saved = try #require(state.provider(for: provider.id))
        let key = try #require(saved.relayKeys?.first { $0.id == item["boundKeyID"] as? String })
        #expect(key.status?.state.rawValue == expect["keyStatus"] as? String)
        #expect(key.status?.httpStatus == expect["keyHTTPStatus"] as? Int)
        #expect((key.status?.checkedAt ?? .distantPast) >= before)
        #expect(saved.relayKeys?.first?.status == nil, "The primary key status is untouched")
        #expect(expect["deniedKeyID"] is NSNull)
        #expect(saved.models.first { $0.id == model.id }?.relayDeniedKeyID == nil)
        #expect(expect["negativeCacheWrites"] as? Int == 0)
        #expect(!Self.anyNegativeCacheEntry(connection: provider.id, modelID: model.id))
    }

    // MARK: - Single-key sending

    private static func singleKeyModel() -> AIModel {
        var model = AIModel(
            id: "gpt-5", name: "gpt-5", capabilities: [.text],
            reasoningModeAvailable: false, isAvailable: true, isDefault: false, priceTier: ""
        )
        model.relayTransport = .openaiChatCompletions
        model.relayTransportSource = .user
        return model
    }

    private func runSingleKeySend(_ caseId: String) async throws {
        let item = try Self.sendCase(caseId)
        let expect = try #require(item["expect"] as? [String: Any])
        #expect(item["provider"] as? String == "single_key")
        ProviderAPIKeyStore.useInMemoryBackendForTesting(true)
        defer { ProviderAPIKeyStore.useInMemoryBackendForTesting(false) }
        await MetadataClient.shared.resetForTesting()

        let model = Self.singleKeyModel()
        var provider = Self.multiKeyProvider(models: [model])
        provider.relayKeys = nil
        defer { RelayNegativeCache.shared.clearConnection(provider.id.uuidString) }
        let status = try #require(item["status"] as? Int)
        let body = try #require(item["body"] as? String)
        RelayKeyAccessScriptedProtocol.reset([
            status == 200 ? .sse(body: RelayKeyAccessScriptedProtocol.chatOK) : .json(status: status, body: body),
        ])
        let before = Date()

        let (state, message) = try await Self.send(provider: provider, modelID: model.id, attachments: [])
        #expect(message.state == (status == 200 ? .delivered : .failed), "\(message.errorDetail ?? "")")
        #expect(RelayKeyAccessScriptedProtocol.requests.count == 1)
        #expect(RelayKeyAccessScriptedProtocol.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer sk-primary")
        let saved = try #require(state.provider(for: provider.id))
        let expectedKeys = try #require(expect["relayKeys"] as? [[String: Any]])
        #expect(saved.relayKeys?.map(\.id) == expectedKeys.compactMap { $0["id"] as? String })
        #expect(saved.relayKeys?.map(\.apiKey) == expectedKeys.compactMap { $0["apiKey"] as? String })
        let key = try #require(saved.relayKeys?.first { $0.id == item["boundKeyID"] as? String })
        #expect(key.status?.state.rawValue == expect["keyStatus"] as? String)
        #expect(key.status?.httpStatus == expect["keyHTTPStatus"] as? Int)
        #expect((key.status?.checkedAt ?? .distantPast) >= before)
        #expect(saved.apiKey == "sk-primary", "The primary key value stays in provider.apiKey")
        let storedModel = try #require(saved.models.first { $0.id == model.id })
        #expect(storedModel.relayKeyID == nil, "The model key field is not written")
        #expect(storedModel.relayDeniedKeyID == nil)
        #expect(expect["deniedKeyID"] is NSNull)
        #expect(expect["negativeCacheWrites"] as? Int == 0)
        #expect(!Self.anyNegativeCacheEntry(connection: provider.id, modelID: model.id))
    }

    @Test("KEY-ACCESS-SEND-delivered_single_key_materializes_ok")
    func sendSingleKeyDeliveredMaterializesOK() async throws {
        try await runSingleKeySend("SEND-delivered_single_key_materializes_ok")
    }

    @Test("KEY-ACCESS-SEND-invalid_401_single_key_materializes")
    func sendSingleKeyInvalidMaterializes() async throws {
        try await runSingleKeySend("SEND-invalid_401_single_key_materializes")
    }

    @Test("KEY-ACCESS access-denied does not fall back from file to text: a native PDF judged access-denied is sent once and writes no file negative cache")
    func deniedSkipsNativeFileTextFallback() async throws {
        ProviderAPIKeyStore.useInMemoryBackendForTesting(true)
        defer { ProviderAPIKeyStore.useInMemoryBackendForTesting(false) }
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(json: try Self.metadataFixture())
        var model = AIModel(
            id: "gpt-5", name: "gpt-5", capabilities: [.text, .file],
            reasoningModeAvailable: false, isAvailable: true, isDefault: false, priceTier: "",
            nativeFileMimes: ["application/pdf"], pdfNativeDefault: true
        )
        model.relayTransport = .openaiResponses
        model.relayTransportSource = .reachable
        model.relayKeyID = "k-claude"
        let provider = Self.multiKeyProvider(models: [model])
        defer { RelayNegativeCache.shared.clearConnection(provider.id.uuidString) }
        let pdf = Oriveo.Attachment(
            id: UUID(), kind: .file, fileName: "report.pdf", mimeType: "application/pdf",
            base64Data: Data("EXTRACTED-PDF-BODY".utf8).base64EncodedString(),
            extractedSizeBytes: 5_000, originalBase64Data: "JVBERi0xLjQ="
        )
        let denied = try #require(try Self.sendCase("SEND-denied_404_skips_negative_cache_and_protocol_fallback")["body"] as? String)
        RelayKeyAccessScriptedProtocol.reset([
            .json(status: 404, body: denied),
            .sse(body: RelayKeyAccessScriptedProtocol.chatOK),
        ])

        let (state, message) = try await Self.send(provider: provider, modelID: model.id, attachments: [pdf])
        #expect(message.state == .failed)
        let requests = RelayKeyAccessScriptedProtocol.requests
        #expect(requests.count == 1, "\(requests.map { $0.url?.path ?? "" })")
        #expect(!Self.anyNegativeCacheEntry(connection: provider.id, modelID: model.id))
        #expect(state.provider(for: provider.id)?.models.first?.relayDeniedKeyID == "k-claude")
        #expect(message.recoveryPrimaryAction != relayFileUnsupportedRecoveryAction)
    }

    @Test("KEY-ACCESS access-denied does not resend without tools: a tools rejection promoted by the production annotate is classified as access-denied on a relay")
    func deniedToolsRejectionIsNotResent() throws {
        // A 404 matching both the tools criterion and the access-denied criterion: annotate promotes it to a tools rejection (which would resend without tools and write a toolCall negative cache).
        let body = #"{"error":{"message":"tools not available: Model \"gpt-5\" is not available for this group","code":"model_not_found"}}"#
        let annotated = ToolUnsupportedErrorMatcher.annotate(
            .upstream(statusCode: 404, detail: "tools not available"), statusCode: 404, rawBody: Data(body.utf8)
        )
        let rejected = try #require(annotated as? ToolsRejectedByUpstreamError)
        #expect(rejected.qualifiesAsConnectionUnsupported, "Precondition: without the guard it would resend without tools")
        #expect(ChatManager.relayToolsRejectionKeyDeniedStatus(rejected, providerKind: .relay) == 404)
        #expect(ChatManager.relayToolsRejectionKeyDeniedStatus(rejected, providerKind: .openAI) == nil, "Relay only")
        let plain = ToolUnsupportedErrorMatcher.annotate(
            .upstream(statusCode: 400, detail: "tools are not supported"), statusCode: 400,
            rawBody: Data(#"{"error":{"message":"tools are not supported"}}"#.utf8)
        )
        #expect(ChatManager.relayToolsRejectionKeyDeniedStatus(plain, providerKind: .relay) == nil, "A genuine tools rejection behaves as before")
    }

    @Test("KEY-ACCESS a successful send clears the access-denied mark on the effective key and writes that key's status back as ok")
    func sendSuccessClearsDenialAndMarksOK() async throws {
        ProviderAPIKeyStore.useInMemoryBackendForTesting(true)
        defer { ProviderAPIKeyStore.useInMemoryBackendForTesting(false) }
        await MetadataClient.shared.resetForTesting()
        var model = Self.boundModel()
        model.relayTransport = .openaiChatCompletions
        model.relayTransportSource = .user
        model.relayDeniedKeyID = "k-claude"
        var provider = Self.multiKeyProvider(models: [model])
        provider.relayKeys?[1].status = RelayKey.Status(state: .invalid, httpStatus: 401, checkedAt: nil)
        RelayKeyAccessScriptedProtocol.reset([.sse(body: RelayKeyAccessScriptedProtocol.chatOK)])

        let (state, message) = try await Self.send(provider: provider, modelID: model.id, attachments: [])
        #expect(message.state == .delivered, "\(message.errorDetail ?? "")")
        let saved = try #require(state.provider(for: provider.id))
        #expect(saved.models.first { $0.id == model.id }?.relayDeniedKeyID == nil)
        #expect(saved.relayKeys?[1].status?.state == .ok)
        #expect(saved.relayKeys?[0].status == nil)
    }
}

/// Fake upstream for the production send chain: replays the script in order and records every request.
private final class RelayKeyAccessScriptedProtocol: URLProtocol, @unchecked Sendable {
    enum Reply {
        case json(status: Int, body: String)
        case sse(body: String)
    }

    static let chatOK = """
    data: {"choices":[{"delta":{"content":"ok"}}]}

    data: {"choices":[{"delta":{},"finish_reason":"stop"}]}

    data: [DONE]

    """

    nonisolated(unsafe) private static var script: [Reply] = []
    nonisolated(unsafe) private static var _requests: [URLRequest] = []
    private static let lock = NSLock()

    static func reset(_ replies: [Reply]) {
        lock.lock(); defer { lock.unlock() }
        script = replies
        _requests = []
    }

    static var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return _requests }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RelayKeyAccessScriptedProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url ?? URL(string: "https://relay.invalid")!
        let reply: Reply = {
            Self.lock.lock(); defer { Self.lock.unlock() }
            Self._requests.append(request)
            let index = Self._requests.count - 1
            return index < Self.script.count ? Self.script[index] : .json(status: 500, body: #"{"error":{"message":"unscripted"}}"#)
        }()
        let status: Int
        let contentType: String
        let data: Data
        switch reply {
        case let .json(code, text):
            status = code; contentType = "application/json"; data = Data(text.utf8)
        case let .sse(text):
            status = 200; contentType = "text/event-stream"; data = Data(text.utf8)
        }
        let response = HTTPURLResponse(
            url: url, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": contentType]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
