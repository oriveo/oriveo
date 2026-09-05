import Foundation
import Testing
@testable import Oriveo

/// Integration asserts for the Codex identity headers Oriveo sends on relay requests
/// and the Responses inline tool body.
///
/// Intercepts the actual URLRequest via URLProtocol and asserts:
/// - transport == `.openaiResponses` → User-Agent=codex_cli_rs/*, Originator=codex_cli_rs
/// - transport == `.openaiChatCompletions` → keeps the Oriveo UA, no Originator
/// - imageGeneration tool appears in body `tools` with `tool.model`
/// - user-supplied headers can override the Codex UA (escape hatch)
/// - `/images/generations` 404 maps to copy that points at switching transport
/// - Codex UA 403 bodies are recognized and mapped to friendly copy
@Suite("OpenAIService Codex identity and inline image tool", .serialized)
struct OpenAIServiceCodexUserAgentTests {

    private func makeMessage(_ text: String) -> ChatMessage {
        ChatMessage(
            id: UUID(),
            role: .user,
            text: text,
            providerKind: .relay,
            providerName: "Relay",
            modelName: "test-model",
            state: .delivered
        )
    }

    private func makeMockSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CapturingProtocol.self]
        return URLSession(configuration: config)
    }

    private func relayWebCapabilityScope(
        modelID: String,
        baseURL: String,
        relay: RelayRequestedConfig
    ) -> (identity: CapabilityEvidenceRequestIdentity, options: ChatRequestOptions) {
        var model = TestFactories.makeModel(id: modelID, capabilities: [.web])
        model.webSearchProfile = "relay-declared-web"
        var provider = TestFactories.makeProvider(
            kind: .relay, models: [model], baseURLText: baseURL
        )
        provider.relayRequested = relay
        var options = ChatRequestOptions()
        options.capabilityEvidenceModel = model
        return (
            CapabilityEvidenceRequestIdentity.make(
                provider: provider, model: model, partitionID: "relay-test-user",
                hasExplicitValue: true, effectiveTransport: relay.transport.rawValue
            ),
            options
        )
    }

    /// Drain the stream (URLProtocol returns [DONE] immediately; a clean finish
    /// or a decode error are both fine — we only care about the captured URLRequest).
    private func drain(_ stream: AsyncThrowingStream<StreamEvent, Error>) async {
        do {
            for try await _ in stream {}
        } catch {
            // The service may throw while decoding SSE; that is irrelevant here.
        }
    }

    @Test("Responses transport sends the full Codex identity set: UA + Originator + session_id + OpenAI-Beta")
    func responsesInjectsCodexIdentity() async {
        CapturingProtocol.reset()
        let service = OpenAIService(session: makeMockSession())
        let relay = RelayRequestedConfig(transport: .openaiResponses, authMode: .bearer)

        let stream = service.sendMessageStream(
            apiKey: "test-key",
            modelID: "gpt-5.4",
            messages: [makeMessage("hi")],
            baseURL: "https://code.example.com/codex",
            reasoningMode: .automatic,
            requestOptions: ChatRequestOptions(),
            relayRequested: relay
        )
        await drain(stream)

        guard let req = CapturingProtocol.snapshot().requests.first else {
            Issue.record("expected at least one captured request")
            return
        }
        let ua = req.value(forHTTPHeaderField: "User-Agent") ?? ""
        let originator = req.value(forHTTPHeaderField: "Originator") ?? ""
        let sessionID = req.value(forHTTPHeaderField: "session_id") ?? ""
        let beta = req.value(forHTTPHeaderField: "OpenAI-Beta") ?? ""
        #expect(ua.hasPrefix("codex_cli_rs/"), "UA=\(ua)")
        #expect(originator == "codex_cli_rs")
        #expect(sessionID.count == 36 && sessionID.contains("-"), "session_id should be UUID-shaped, got: \(sessionID)")
        #expect(beta == "responses=experimental", "OpenAI-Beta=\(beta)")
        #expect(req.url?.path.hasSuffix("/responses") == true)
    }

    @Test("Codex subscription outbound includes web search and reasoning effort from upstream declarations")
    func codexSubscriptionSendsWebSearchAndReasoningEffort() async {
        // 2026-08-20 on-device report: "web search is on but it still doesn't work".
        // Root cause: the subscription body hard-coded tools and reasoning.effort
        // to nil, so the UI toggle never reached the wire — the same "decide in
        // one place, execute in another" split described in ChatModels. Capability
        // comes from per-model declarations on upstream /models.
        CapturingProtocol.reset()
        let service = OpenAIService(session: makeMockSession())

        var model = TestFactories.makeModel(id: "gpt-5.6-sol", capabilities: [.text, .web, .reasoning])
        model.reasoningModeAvailable = true
        // Upstream-declared effort table — effort may only be taken from this list.
        model.upstreamReasoningLevels = ["low", "medium", "high"]
        var options = ChatRequestOptions()
        options.capabilityEvidenceModel = model
        options.openAISubscription = OpenAISubscriptionRequestContext(
            responsesURL: URL(string: "https://chatgpt.com/backend-api/codex/responses")!,
            accountID: "acct-1",
            requiredHeaders: ["originator": "oriveo", "version": "0.148.0"]
        )

        let stream = service.sendMessageStream(
            apiKey: "codex-token",
            modelID: "gpt-5.6-sol",
            messages: [makeMessage("any news today")],
            reasoningMode: .deep,
            webSearchEnabled: true,
            requestOptions: options
        )
        await drain(stream)

        guard let body = CapturingProtocol.snapshot().bodies.first,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            Issue.record("expected a captured Codex subscription request body")
            return
        }

        let tools = json["tools"] as? [[String: Any]] ?? []
        #expect(tools.contains { $0["type"] as? String == "web_search" }, "web-search intent must go out as a web_search tool, got tools=\(tools)")

        // effort must land in an **upstream-declared** level: deep → high (upstream has high).
        let reasoning = json["reasoning"] as? [String: Any] ?? [:]
        #expect(reasoning["effort"] as? String == "high", "deep should map to upstream-recognized high, got \(reasoning)")

        // Hard constraints of the subscription path must not regress.
        #expect(json["store"] as? Bool == false)
        #expect(json["stream"] as? Bool == true)
    }

    @Test("Omits web_search when the model does not declare web capability, even if the toggle is on")
    func codexSubscriptionOmitsWebSearchWhenModelDoesNotDeclareIt() async {
        // No upstream declaration means unsupported: omit the tool rather than invent one the upstream does not recognize.
        CapturingProtocol.reset()
        let service = OpenAIService(session: makeMockSession())

        let model = TestFactories.makeModel(id: "gpt-5.4-mini", capabilities: [.text])
        var options = ChatRequestOptions()
        options.capabilityEvidenceModel = model
        options.openAISubscription = OpenAISubscriptionRequestContext(
            responsesURL: URL(string: "https://chatgpt.com/backend-api/codex/responses")!,
            accountID: "acct-1",
            requiredHeaders: [:]
        )

        let stream = service.sendMessageStream(
            apiKey: "codex-token",
            modelID: "gpt-5.4-mini",
            messages: [makeMessage("hi")],
            reasoningMode: .deep,
            webSearchEnabled: true,
            requestOptions: options
        )
        await drain(stream)

        guard let body = CapturingProtocol.snapshot().bodies.first,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            Issue.record("expected a captured request body")
            return
        }
        #expect(json["tools"] == nil, "a model that does not declare web must not emit web_search")
        let reasoning = json["reasoning"] as? [String: Any] ?? [:]
        #expect(reasoning["effort"] == nil, "a model that does not declare reasoning must not emit effort")
    }

    @Test("Chat Completions transport keeps the Oriveo UA and does not inject Originator")
    func chatCompletionsKeepsOriveoIdentity() async {
        CapturingProtocol.reset()
        let service = OpenAIService(session: makeMockSession())
        let relay = RelayRequestedConfig(transport: .openaiChatCompletions, authMode: .bearer)

        let stream = service.sendMessageStream(
            apiKey: "test-key",
            modelID: "gpt-5.4",
            messages: [makeMessage("hi")],
            baseURL: "https://gateway.example.com/v1",
            reasoningMode: .automatic,
            requestOptions: ChatRequestOptions(),
            relayRequested: relay
        )
        await drain(stream)

        guard let req = CapturingProtocol.snapshot().requests.first else {
            Issue.record("expected a captured request")
            return
        }
        let ua = req.value(forHTTPHeaderField: "User-Agent") ?? ""
        #expect(ua.hasPrefix("Oriveo/"), "chat_completions should keep the Oriveo UA, got: \(ua)")
        #expect(req.value(forHTTPHeaderField: "Originator") == nil)
        #expect(req.value(forHTTPHeaderField: "session_id") == nil, "non-Responses transport must not leak session_id")
        #expect(req.value(forHTTPHeaderField: "OpenAI-Beta") == nil, "non-Responses transport must not send OpenAI-Beta")
        #expect(req.url?.path.hasSuffix("/chat/completions") == true)
    }

    @Test("stored HTTP relay is rejected before stream reaches URLSession")
    func insecureRelayStreamIsRejectedBeforeNetwork() async {
        CapturingProtocol.reset()
        let service = OpenAIService(session: makeMockSession())
        let relay = RelayRequestedConfig(transport: .openaiChatCompletions, authMode: .bearer)

        let stream = service.sendMessageStream(
            apiKey: "test-key",
            modelID: "gpt-5.4",
            messages: [makeMessage("hi")],
            baseURL: "http://192.168.1.20:8080/v1",
            reasoningMode: .automatic,
            requestOptions: ChatRequestOptions(),
            relayRequested: relay
        )
        await drain(stream)

        #expect(CapturingProtocol.snapshot().requests.isEmpty)
    }

    @Test("stored HTTP relay is rejected before ping reaches URLSession")
    func insecureRelayPingIsRejectedBeforeNetwork() async {
        CapturingProtocol.reset()
        let service = OpenAIService(session: makeMockSession())
        let relay = RelayRequestedConfig(transport: .openaiChatCompletions, authMode: .bearer)

        do {
            _ = try await service.pingRelay(
                apiKey: "test-key",
                baseURL: "http://10.0.0.8:8080/v1",
                modelID: "gpt-5.4",
                relayRequested: relay
            )
            Issue.record("expected insecure relay configuration to be rejected")
        } catch let error as ProviderServiceError {
            guard case .invalidConfiguration = error else {
                Issue.record("expected invalidConfiguration, got \(error)")
                return
            }
        } catch {
            Issue.record("expected ProviderServiceError, got \(error)")
        }

        #expect(CapturingProtocol.snapshot().requests.isEmpty)
    }

    @Test("Chat Completions query_key auth writes the key into the URL and does not send Authorization")
    func chatCompletionsQueryKeyAuthUsesURLQuery() async {
        CapturingProtocol.reset()
        let service = OpenAIService(session: makeMockSession())
        let relay = RelayRequestedConfig(
            transport: .openaiChatCompletions,
            authMode: .queryKey,
            queryParams: [RelayKeyValue(key: "region", value: "us")]
        )

        let stream = service.sendMessageStream(
            apiKey: "sk-query",
            modelID: "gpt-5.4",
            messages: [makeMessage("hi")],
            baseURL: "https://gateway.example.com",
            reasoningMode: .automatic,
            requestOptions: ChatRequestOptions(),
            relayRequested: relay
        )
        await drain(stream)

        guard let req = CapturingProtocol.snapshot().requests.first else {
            Issue.record("expected a captured request")
            return
        }
        #expect(req.url?.path == "/v1/chat/completions")
        #expect(req.url?.query?.contains("key=sk-query") == true)
        #expect(req.url?.query?.contains("region=us") == true)
        #expect(req.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test("Relay ping uses Chat Completions when an OpenAI-compatible model is provided")
    func pingRelayChatCompletionsUsesChatWhenModelProvided() async throws {
        CapturingProtocol.reset()
        let service = OpenAIService(session: makeMockSession())
        let relay = RelayRequestedConfig(transport: .openaiChatCompletions, authMode: .bearer)

        let result = try await service.pingRelay(
            apiKey: "test-key",
            baseURL: "https://gateway.example.com/v1",
            modelID: "gpt-5.4",
            relayRequested: relay
        )

        guard let req = CapturingProtocol.snapshot().requests.first else {
            Issue.record("expected a captured request")
            return
        }
        let body = try #require(CapturingProtocol.snapshot().bodies.first)
        let bodyText = String(decoding: body, as: UTF8.self)
        #expect(req.httpMethod == "POST")
        #expect(req.url?.absoluteString == "https://gateway.example.com/v1/chat/completions")
        #expect(bodyText.contains(#""model":"gpt-5.4""#))
        #expect(bodyText.contains(#""max_tokens":1"#))
        #expect(bodyText.contains(#""content":"ping""#))
        #expect(result.probedEndpoint == "POST /chat/completions")
    }

    @Test("Relay ping rejects a 2xx HTML fallback page")
    func pingRelayRejectsHTMLSuccess() async {
        CapturingProtocol.reset()
        CapturingProtocol.setResponse(
            contentType: "text/html",
            body: Data("<!doctype html><html>relay console</html>".utf8)
        )
        defer { CapturingProtocol.reset() }
        let service = OpenAIService(session: makeMockSession())
        let relay = RelayRequestedConfig(transport: .openaiChatCompletions, authMode: .bearer)

        do {
            _ = try await service.pingRelay(
                apiKey: "test-key",
                baseURL: "https://gateway.example.com/v1",
                modelID: "gpt-5.4",
                relayRequested: relay
            )
            Issue.record("expected the HTML fallback page to fail validation")
        } catch let error as ProviderServiceError {
            guard case let .upstream(statusCode, detail) = error else {
                Issue.record("expected upstream error, got \(error)")
                return
            }
            #expect(statusCode == 200)
            #expect(detail.contains("HTML"))
        } catch {
            Issue.record("expected ProviderServiceError, got \(error)")
        }
    }

    @Test("Relay ping redacts echoed keys, sensitive headers, and query values from the upstream response")
    func pingRelayRedactsEchoedCredentialMaterial() async throws {
        let apiKey = "sk-live-123456789"
        let headerSecret = "header-secret-987654"
        let querySecret = "query-secret-987654"
        CapturingProtocol.reset()
        CapturingProtocol.setResponse(
            statusCode: 400,
            contentType: "application/json",
            body: try JSONSerialization.data(withJSONObject: [
                "error": ["message": "Denied \(apiKey) \(headerSecret) \(querySecret)"],
            ])
        )
        defer { CapturingProtocol.reset() }

        let service = OpenAIService(session: makeMockSession())
        let relay = RelayRequestedConfig(
            transport: .openaiChatCompletions,
            authMode: .bearer,
            headers: [RelayKeyValue(key: "X-API-Key", value: headerSecret)],
            queryParams: [RelayKeyValue(key: "api_key", value: querySecret)]
        )

        do {
            _ = try await service.pingRelay(
                apiKey: apiKey,
                baseURL: "https://gateway.example.com/v1",
                modelID: "gpt-5.4",
                relayRequested: relay
            )
            Issue.record("expected ping to surface the mocked HTTP error")
        } catch let error as ProviderServiceError {
            guard case let .upstream(_, detail) = error else {
                Issue.record("expected upstream error, got \(error)")
                return
            }
            #expect(detail.contains("***hidden"))
            #expect(!detail.contains(apiKey))
            #expect(!detail.contains(headerSecret))
            #expect(!detail.contains(querySecret))
        } catch {
            Issue.record("expected ProviderServiceError, got \(error)")
        }

        let request = CapturingProtocol.snapshot().requests.first
        #expect(request?.value(forHTTPHeaderField: "X-API-Key") == headerSecret)
        #expect(request?.url?.query?.contains("api_key=\(querySecret)") == true)
    }

    @Test("multi-turn image generation: assistant history image attachments must not be echoed into input (avoids 502 + protocol mix-up)")
    func multiTurnAssistantImageNotEchoedToInput() async throws {
        CapturingProtocol.reset()
        let service = OpenAIService(session: makeMockSession())
        let relay = RelayRequestedConfig(transport: .openaiResponses, authMode: .bearer)

        // User asked to draw a basketball last turn; assistant returned an image attachment; user asks for another.
        let userFirst = ChatMessage(
            id: UUID(),
            role: .user,
            text: "basketball",
            providerKind: .relay,
            providerName: "Relay",
            modelName: "gpt-image-2",
            state: .delivered
        )
        let assistantImage = ChatMessage(
            id: UUID(),
            role: .assistant,
            text: "",
            providerKind: .relay,
            providerName: "Relay",
            modelName: "gpt-image-2",
            state: .delivered,
            attachments: [
                Attachment(
                    id: UUID(),
                    kind: .image,
                    fileName: "generated.png",
                    mimeType: "image/png",
                    base64Data: String(repeating: "A", count: 2000) // non-empty base64 stand-in
                )
            ]
        )
        let userSecond = ChatMessage(
            id: UUID(),
            role: .user,
            text: "draw another one",
            providerKind: .relay,
            providerName: "Relay",
            modelName: "gpt-image-2",
            state: .delivered
        )

        let stream = service.sendMessageStream(
            apiKey: "test-key",
            modelID: "gpt-5.4",
            messages: [userFirst, assistantImage, userSecond],
            baseURL: "https://code.example.com/codex",
            reasoningMode: .automatic,
            requestOptions: ChatRequestOptions(),
            relayRequested: relay,
            supportsImageGeneration: true,
            imageToolModelID: "gpt-image-2"
        )
        await drain(stream)

        let snap = CapturingProtocol.snapshot()
        guard let body = snap.bodies.first,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let input = json["input"] as? [[String: Any]] else {
            Issue.record("expected request body with input array")
            return
        }

        // Size sentinel: echoing the assistant image would add at least 2KB of base64 plus a data-URI wrapper
        #expect(body.count < 4000, "body must not include the assistant history image, size=\(body.count) bytes")

        // Protocol: assistant-role content must be text, never an input_image part
        let assistantInputs = input.filter { ($0["role"] as? String) == "assistant" }
        for assistantMsg in assistantInputs {
            if let parts = assistantMsg["content"] as? [[String: Any]] {
                let hasInputImage = parts.contains { ($0["type"] as? String) == "input_image" }
                #expect(!hasInputImage, "assistant history must not contain an input_image part: \(parts)")
            }
            // string content is also fine
        }
    }

    @Test("Responses transport + webSearchEnabled=true → body.tools defaults to web_search (no _preview) + image_generation")
    func responsesBodyContainsWebSearchTool() async throws {
        CapturingProtocol.reset()
        let service = OpenAIService(session: makeMockSession())
        let relay = RelayRequestedConfig(transport: .openaiResponses, authMode: .bearer)
        let baseURL = "https://code.example.com/codex"
        let scope = relayWebCapabilityScope(modelID: "gpt-5.4", baseURL: baseURL, relay: relay)

        let stream = CapabilityEvidenceRequestContext.$current.withValue(scope.identity) {
            service.sendMessageStream(
                apiKey: "test-key",
                modelID: "gpt-5.4",
                messages: [makeMessage("what is the weather today")],
                baseURL: baseURL,
                reasoningMode: .automatic,
                requestOptions: scope.options,
                relayRequested: relay,
                webSearchEnabled: true
            )
        }
        await drain(stream)

        let snap = CapturingProtocol.snapshot()
        guard let body = snap.bodies.first,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            Issue.record("expected request body captured, got: \(snap.bodies.count) bodies")
            return
        }
        // `web_search` is the current protocol name; `web_search_preview` is the legacy one and
        // must not be sent by default.
        let tools = json["tools"] as? [[String: Any]] ?? []
        let types = tools.compactMap { $0["type"] as? String }
        #expect(types.contains("image_generation"), "default should include image_generation, got types=\(types)")
        #expect(types.contains("web_search"), "should include web_search (default protocol name), got types=\(types)")
        #expect(!types.contains("web_search_preview"), "default must not use legacy web_search_preview, got types=\(types)")
        #expect(tools.count == 2, "should mount 2 tools (image_generation + web_search), got \(tools.count)")
    }

    @Test("Responses transport + webSearchEnabled + supportsImageGeneration → body.tools contains both tools")
    func responsesBodyContainsBothTools() async throws {
        CapturingProtocol.reset()
        let service = OpenAIService(session: makeMockSession())
        let relay = RelayRequestedConfig(transport: .openaiResponses, authMode: .bearer)
        let baseURL = "https://code.example.com/codex"
        let scope = relayWebCapabilityScope(modelID: "gpt-5.4", baseURL: baseURL, relay: relay)

        let stream = CapabilityEvidenceRequestContext.$current.withValue(scope.identity) {
            service.sendMessageStream(
                apiKey: "test-key",
                modelID: "gpt-5.4",
                messages: [makeMessage("look up today news and draw an illustration")],
                baseURL: baseURL,
                reasoningMode: .automatic,
                requestOptions: scope.options,
                relayRequested: relay,
                webSearchEnabled: true,
                supportsImageGeneration: true,
                imageToolModelID: "gpt-image-2"
            )
        }
        await drain(stream)

        let snap = CapturingProtocol.snapshot()
        guard let body = snap.bodies.first,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            Issue.record("expected request body captured")
            return
        }
        let tools = json["tools"] as? [[String: Any]] ?? []
        let types = tools.compactMap { $0["type"] as? String }
        #expect(types.contains("image_generation"), "tools should include image_generation, got types=\(types)")
        #expect(types.contains("web_search"), "tools should include web_search (default protocol name), got types=\(types)")
        #expect(tools.count == 2, "should mount 2 tools, got \(tools.count)")
    }

    @Test("Responses transport + webSearchEnabled=false → body.tools contains only the default image_generation")
    func responsesBodyOmitsWebSearchToolWhenDisabled() async throws {
        CapturingProtocol.reset()
        let service = OpenAIService(session: makeMockSession())
        let relay = RelayRequestedConfig(transport: .openaiResponses, authMode: .bearer)

        let stream = service.sendMessageStream(
            apiKey: "test-key",
            modelID: "gpt-5.4",
            messages: [makeMessage("hi")],
            baseURL: "https://code.example.com/codex",
            reasoningMode: .automatic,
            requestOptions: ChatRequestOptions(),
            relayRequested: relay,
            webSearchEnabled: false
        )
        await drain(stream)

        let snap = CapturingProtocol.snapshot()
        guard let body = snap.bodies.first,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            Issue.record("expected request body captured")
            return
        }
        // Codex transport defaults to image_generation; no web_search variant
        let tools = json["tools"] as? [[String: Any]] ?? []
        let types = tools.compactMap { $0["type"] as? String }
        #expect(types.contains("image_generation"), "default should include image_generation, got types=\(types)")
        #expect(!types.contains("web_search"), "must not inject web_search when disabled, got types=\(types)")
        #expect(!types.contains("web_search_preview"), "must not inject web_search_preview when disabled, got types=\(types)")
    }

    @Test("Responses transport + webSearchToolName=.webSearchPreview → emit the legacy protocol name (old-relay compat)")
    func responsesBodyUsesLegacyWebSearchPreview() async throws {
        CapturingProtocol.reset()
        let service = OpenAIService(session: makeMockSession())
        let relay = RelayRequestedConfig(
            transport: .openaiResponses,
            authMode: .bearer,
            webSearchToolName: .webSearchPreview
        )
        let baseURL = "https://legacy-relay.example.com/v1"
        let scope = relayWebCapabilityScope(modelID: "gpt-5.4", baseURL: baseURL, relay: relay)

        let stream = CapabilityEvidenceRequestContext.$current.withValue(scope.identity) {
            service.sendMessageStream(
                apiKey: "test-key",
                modelID: "gpt-5.4",
                messages: [makeMessage("today weather")],
                baseURL: baseURL,
                reasoningMode: .automatic,
                requestOptions: scope.options,
                relayRequested: relay,
                webSearchEnabled: true
            )
        }
        await drain(stream)

        let snap = CapturingProtocol.snapshot()
        guard let body = snap.bodies.first,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            Issue.record("expected request body captured")
            return
        }
        let tools = json["tools"] as? [[String: Any]] ?? []
        let types = tools.compactMap { $0["type"] as? String }
        #expect(types.contains("web_search_preview"), "selecting .webSearchPreview should emit the legacy name, got types=\(types)")
        #expect(!types.contains("web_search"), "legacy selection must not emit the new protocol name, got types=\(types)")
    }

    @Test("Responses transport + webSearchToolName=.disabled → do not emit a web_search tool even if web search is on")
    func responsesBodyDisabledWebSearchTool() async throws {
        CapturingProtocol.reset()
        let service = OpenAIService(session: makeMockSession())
        let relay = RelayRequestedConfig(
            transport: .openaiResponses,
            authMode: .bearer,
            webSearchToolName: .disabled
        )

        let stream = service.sendMessageStream(
            apiKey: "test-key",
            modelID: "gpt-5.4",
            messages: [makeMessage("hi")],
            baseURL: "https://code.example.com/codex",
            reasoningMode: .automatic,
            requestOptions: ChatRequestOptions(),
            relayRequested: relay,
            webSearchEnabled: true
        )
        await drain(stream)

        let snap = CapturingProtocol.snapshot()
        guard let body = snap.bodies.first,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            Issue.record("expected request body captured")
            return
        }
        let tools = json["tools"] as? [[String: Any]] ?? []
        let types = tools.compactMap { $0["type"] as? String }
        #expect(types == ["image_generation"], "when disabled, only image_generation remains, got types=\(types)")
    }

    @Test("imageGeneration tool is forwarded into the Responses body with tool.model + stream=true")
    func responsesBodyContainsImageTool() async throws {
        CapturingProtocol.reset()
        let service = OpenAIService(session: makeMockSession())
        let relay = RelayRequestedConfig(transport: .openaiResponses, authMode: .bearer)

        let stream = service.sendMessageStream(
            apiKey: "test-key",
            modelID: "gpt-5.4",
            messages: [makeMessage("draw a cat")],
            baseURL: "https://code.example.com/codex",
            reasoningMode: .automatic,
            requestOptions: ChatRequestOptions(),
            relayRequested: relay,
            supportsImageGeneration: true,
            imageToolModelID: "gpt-image-2"
        )
        await drain(stream)

        let snap = CapturingProtocol.snapshot()
        guard let body = snap.bodies.first,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            Issue.record("expected request body captured, got: \(snap.bodies.count) bodies")
            return
        }
        let tools = json["tools"] as? [[String: Any]] ?? []
        #expect(tools.count == 1, "should mount 1 tool, got \(tools.count)")
        #expect(tools.first?["type"] as? String == "image_generation")
        #expect(tools.first?["model"] as? String == "gpt-image-2")
        #expect(json["stream"] as? Bool == true)
    }

    @Test("User headers can override the Codex UA (escape hatch for rare relays)")
    func userHeadersOverrideCodexUA() async {
        CapturingProtocol.reset()
        let service = OpenAIService(session: makeMockSession())
        let relay = RelayRequestedConfig(
            transport: .openaiResponses,
            authMode: .bearer,
            headers: [RelayKeyValue(key: "User-Agent", value: "CustomClient/9.9")]
        )

        let stream = service.sendMessageStream(
            apiKey: "test-key",
            modelID: "gpt-5.4",
            messages: [makeMessage("hi")],
            baseURL: "https://code.example.com/codex",
            reasoningMode: .automatic,
            requestOptions: ChatRequestOptions(),
            relayRequested: relay
        )
        await drain(stream)

        guard let req = CapturingProtocol.snapshot().requests.first else {
            Issue.record("expected request captured")
            return
        }
        let ua = req.value(forHTTPHeaderField: "User-Agent") ?? ""
        #expect(ua == "CustomClient/9.9", "user header should override the Codex UA, got: \(ua)")
    }

    @Test("mapHTTPError: /images/generations 404 → friendly copy that points at switching transport")
    func imagesEndpoint404Friendly() {
        final class ProbeService: BaseAPIService {}
        let probe = ProbeService()
        let url = URL(string: "https://code.example.com/codex/images/generations")!
        let err = probe.mapHTTPError(
            statusCode: 404,
            data: Data("{}".utf8),
            url: url,
            isRelay: true
        )
        if case let .upstream(_, detail) = err {
            #expect(
                detail.localizedCaseInsensitiveContains("OpenAI Responses")
                    || detail.localizedCaseInsensitiveContains("/images/generations")
                    || detail.contains("Codex")
                    || detail.contains("Inline"),
                "friendly copy should include guidance, got: \(detail)"
            )
        } else {
            Issue.record("expected .upstream error, got \(err)")
        }
    }

    @Test("mapHTTPError: Codex UA 403 body is recognized → friendly copy")
    func codexUA403Friendly() {
        final class ProbeService: BaseAPIService {}
        let probe = ProbeService()
        let body = #"{"error":{"message":"This account only allows Codex official clients","type":"forbidden_error"}}"#
        let err = probe.mapHTTPError(
            statusCode: 403,
            data: Data(body.utf8),
            url: URL(string: "https://code.example.com/codex/responses"),
            isRelay: true
        )
        if case let .upstream(code, detail) = err {
            #expect(code == 403)
            #expect(
                detail.localizedCaseInsensitiveContains("Codex")
                    || detail.contains("identity"),
                "friendly copy should mention Codex identity, got: \(detail)"
            )
        } else {
            Issue.record("expected .upstream error, got \(err)")
        }
    }

    @Test(
        "mapHTTPError: Codex UA 403 multilingual keyword fallback matching",
        // The relay may localize the upstream message; the keyword is escaped so this file
        // holds no ideographs.
        arguments: [
            "{\"error\":{\"message\":\"This account only allows Codex \u{5B98}\u{65B9}\u{5BA2}\u{6237}\u{7AEF}\"}}",
            "{\"error\":{\"message\":\"Only Codex \u{5B98}\u{65B9}\u{5BA2}\u{6236}\u{7AEF} may use this account\"}}",
            "{\"error\":{\"message\":\"Codex \u{516C}\u{5F0F}クライアントのみ\u{8A31}\u{53EF}されています\"}}"
        ]
    )
    func codexUA403MultilingualFallback(body: String) {
        final class ProbeService: BaseAPIService {}
        let probe = ProbeService()
        let err = probe.mapHTTPError(
            statusCode: 403,
            data: Data(body.utf8),
            url: URL(string: "https://code.example.com/codex/responses"),
            isRelay: true
        )
        if case let .upstream(code, detail) = err {
            #expect(code == 403)
            #expect(
                detail.localizedCaseInsensitiveContains("Codex")
                    || detail.contains("identity"),
                "localized relay error text should still hit the friendly copy, got: \(detail)"
            )
        } else {
            Issue.record("expected .upstream 403 mapping for body=\(body.prefix(60)), got \(err)")
        }
    }

    @Test(
        "mapHTTPError: 502 upstream_error is recognized → point at switching relays rather than making the user decode technical detail",
        arguments: [
            #"{"error":{"message":"Upstream authentication failed, please contact administrator","type":"upstream_error"}}"#,
            #"{"error":{"message":"Upstream timeout","type":"upstream_error"}}"#,
            #"{"error":{"message":"upstream service unavailable","type":"server_error"}}"#,
            #"{"error":{"message":"upstream authentication failed"}}"#
        ]
    )
    func upstreamError502Friendly(body: String) {
        final class ProbeService: BaseAPIService {}
        let probe = ProbeService()
        let err = probe.mapHTTPError(
            statusCode: 502,
            data: Data(body.utf8),
            url: URL(string: "https://code.example.com/codex/responses"),
            isRelay: true
        )
        if case let .upstream(code, detail) = err {
            #expect(code == 502)
            #expect(
                detail.localizedCaseInsensitiveContains("upstream")
                    || detail.contains("not your configuration"),
                "502 upstream_error should give 'not your problem → switch relays' copy, got: \(detail)"
            )
        } else {
            Issue.record("expected .upstream 502 mapping for body=\(body.prefix(60)), got \(err)")
        }
    }

    @Test("mapHTTPError: Relay upstream 5xx technical detail keeps the upstream error and labels it Upstream HTTP")
    func upstreamHTTPErrorPreservesRelayDetail() {
        final class ProbeService: BaseAPIService {}
        let probe = ProbeService()
        let body = #"{"error":"server error: insufficient balance"}"#
        let err = probe.mapHTTPError(
            statusCode: 500,
            data: Data(body.utf8),
            url: URL(string: "https://relay.example.com/v1/chat/completions")
        )

        #expect(err.technicalDetail == "Upstream HTTP 500: server error: insufficient balance")
    }

    @Test(
        "mapHTTPError: upstream rejects a specific model ID (404/400 body contains 'unsupported model' etc.) → point at the Relay edit page to change the primary model",
        arguments: [
            (404, "{\"code\":404,\"msg\":\"\u{4E0D}\u{652F}\u{6301}\u{7684}\u{6A21}\u{578B},\u{8BF7}\u{66F4}\u{6362}\u{6A21}\u{578B}!\"}"),
            (404, "{\"code\":404,\"msg\":\"\u{8ACB}\u{66F4}\u{63DB}\u{6A21}\u{578B}\"}"),
            (400, #"{"error":{"code":"model_not_found","message":"model not found"}}"#),
            (503, #"{"error":{"code":"model_not_found","message":"No available channel for model gpt-image-2 under group vip_2"}}"#)
        ]
    )
    func upstreamModelUnavailableFriendly(code: Int, body: String) {
        final class ProbeService: BaseAPIService {}
        let probe = ProbeService()
        // 503 is not in the new mapping branch; only 404/400 are mapped. Keep 503 as a sample — it should fall through to default .upstream.
        let expectedMap = (code == 404 || code == 400)
        let err = probe.mapHTTPError(
            statusCode: code,
            data: Data(body.utf8),
            url: URL(string: "https://code.example.com/codex/responses"),
            isRelay: true
        )
        if expectedMap {
            if case let .upstream(_, detail) = err {
                #expect(
                    detail.localizedCaseInsensitiveContains("Edit")
                        || detail.contains("upstream"),
                    "404/400 + unsupported-model body should give 'change the primary model' guidance, got: \(detail)"
                )
            } else {
                Issue.record("expected .upstream mapping for code=\(code), got \(err)")
            }
        } else {
            if case .upstream = err { /* OK, no specific assert */ } else {
                Issue.record("503 should be the default .upstream mapping, got: \(err)")
            }
        }
    }

    @Test("mapRelayStreamError: moderation_blocked → copyright/sensitive-content friendly copy")
    func streamErrorModerationFriendly() {
        let err = OpenAIService.mapRelayStreamError(
            code: "moderation_blocked",
            message: "Your request was rejected by the safety system."
        )
        if case let .upstream(_, detail) = err {
            #expect(
                detail.contains("safety")
                    || detail.contains("rephrase"),
                "moderation friendly copy should clearly ask for an original description, got: \(detail)"
            )
        } else {
            Issue.record("expected .upstream, got \(err)")
        }
    }

    @Test("mapRelayStreamError: image_generation_user_error → tool-failure friendly copy")
    func streamErrorImageToolFriendly() {
        let err = OpenAIService.mapRelayStreamError(
            code: "image_generation_user_error",
            message: "tool failed"
        )
        if case let .upstream(_, detail) = err {
            #expect(
                detail.contains("image")
                    || detail.contains("rephrase"),
                "image-tool failure friendly copy should give retry / change model ID guidance, got: \(detail)"
            )
        } else {
            Issue.record("expected .upstream, got \(err)")
        }
    }

    @Test("mapRelayStreamError: unknown code → pass through the upstream message as fallback")
    func streamErrorUnknownPassesThrough() {
        let err = OpenAIService.mapRelayStreamError(code: "weird_code", message: "very specific upstream blah")
        if case let .upstream(_, detail) = err {
            #expect(detail.contains("very specific upstream blah"))
        } else {
            Issue.record("expected .upstream, got \(err)")
        }
    }

    @Test("mapHTTPError: /images/generations 400 containing response_format → model-parameter friendly copy")
    func imagesEndpoint400ResponseFormatFriendly() {
        final class ProbeService: BaseAPIService {}
        let probe = ProbeService()
        let body = #"{"error":{"message":"Unknown parameter: 'response_format' is not supported for this model","code":"unknown_parameter"}}"#
        let url = URL(string: "https://api.example.com/v1/images/generations")!
        let err = probe.mapHTTPError(statusCode: 400, data: Data(body.utf8), url: url, isRelay: true)
        if case let .upstream(code, detail) = err {
            #expect(code == 400)
            #expect(
                detail.localizedCaseInsensitiveContains("response_format")
                    || detail.localizedCaseInsensitiveContains("gpt-image-")
                    || detail.contains("Rename"),
                "400 + response_format should give rename / switch image model ID guidance, got: \(detail)"
            )
        } else {
            Issue.record("expected .upstream 400 mapping, got \(err)")
        }
    }
}

// MARK: - URLProtocol mock

/// Intercept and record the request, then immediately return an empty SSE response so the service stream can finish.
/// Recording uses an actor-safe static snapshot to avoid Swift 6 concurrency warnings.
private final class CapturingProtocol: URLProtocol, @unchecked Sendable {
    struct Snapshot {
        let requests: [URLRequest]
        let bodies: [Data]
    }

    nonisolated(unsafe) private static var _requests: [URLRequest] = []
    nonisolated(unsafe) private static var _bodies: [Data] = []
    nonisolated(unsafe) private static var _responseContentType = "text/event-stream"
    nonisolated(unsafe) private static var _responseBody = Data("data: [DONE]\n\n".utf8)
    nonisolated(unsafe) private static var _responseStatusCode = 200
    private static let lock = NSLock()

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        _requests = []
        _bodies = []
        _responseContentType = "text/event-stream"
        _responseBody = Data("data: [DONE]\n\n".utf8)
        _responseStatusCode = 200
    }

    static func setResponse(statusCode: Int = 200, contentType: String, body: Data) {
        lock.lock(); defer { lock.unlock() }
        _responseStatusCode = statusCode
        _responseContentType = contentType
        _responseBody = body
    }

    static func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        return Snapshot(requests: _requests, bodies: _bodies)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let captured = request
        var bodyData: Data?
        if let stream = captured.httpBodyStream {
            stream.open()
            var acc = Data()
            let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
            defer { buf.deallocate() }
            while stream.hasBytesAvailable {
                let n = stream.read(buf, maxLength: 4096)
                if n <= 0 { break }
                acc.append(buf, count: n)
            }
            stream.close()
            bodyData = acc
        } else if let body = captured.httpBody {
            bodyData = body
        }

        Self.lock.lock()
        Self._requests.append(captured)
        if let b = bodyData { Self._bodies.append(b) }
        let responseContentType = Self._responseContentType
        let responseBody = Self._responseBody
        let responseStatusCode = Self._responseStatusCode
        Self.lock.unlock()

        let resp = HTTPURLResponse(
            url: captured.url!,
            statusCode: responseStatusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": responseContentType]
        )!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: responseBody)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
