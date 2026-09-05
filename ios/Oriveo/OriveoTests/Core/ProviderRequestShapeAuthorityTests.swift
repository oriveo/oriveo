import Foundation
import OriveoProviderKit
import Testing
@testable import Oriveo

final class ProviderAuthorityMockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            client?.urlProtocolDidFinishLoading(self)
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

private func makeAuthorityMockSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [ProviderAuthorityMockURLProtocol.self]
    return URLSession(configuration: config)
}

private func authorityHTTPResponse(url: URL, statusCode: Int = 200) -> HTTPURLResponse {
    HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: nil, headerFields: [
        "Content-Type": "application/json"
    ])!
}

private final class AuthorityBodyRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var bodies: [[String: Any]] = []
    func append(_ body: [String: Any]) { lock.withLock { bodies.append(body) } }
    func snapshot() -> [[String: Any]] { lock.withLock { bodies } }
}

private func authorityRequestBody(_ request: URLRequest) throws -> [String: Any] {
    let data: Data
    if let body = request.httpBody {
        data = body
    } else if let stream = request.httpBodyStream {
        stream.open()
        defer { stream.close() }
        var buffer = [UInt8](repeating: 0, count: 4096)
        var collected = Data()
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            collected.append(buffer, count: count)
        }
        data = collected
    } else {
        data = Data()
    }
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private func authorityUserMessage(provider: ProviderKind, modelID: String) -> ChatMessage {
    ChatMessage(
        id: UUID(),
        role: .user,
        text: "hello",
        providerKind: provider,
        providerName: provider.displayName,
        modelID: modelID,
        modelName: modelID,
        state: .delivered
    )
}

private let authorityEvidenceRevision = "authority-fixture-v1"

private func loadAuthorityMetadata(json: String) async throws {
    var root = try #require(
        JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
    )
    var providers = try #require(root["providers"] as? [String: Any])
    for (providerKey, rawProvider) in providers {
        guard var provider = rawProvider as? [String: Any],
              var models = provider["models"] as? [String: Any],
              let kind = ProviderKind(rawValue: providerKey) else { continue }
        for (modelID, rawModel) in models {
            guard var model = rawModel as? [String: Any],
                  let transport = model["transport"] as? String,
                  CapabilityEvidenceFacade.isConcreteTransport(transport) else { continue }
            let profiles = model["profiles"] as? [String: Any]
            let controls = model["capabilityControls"] as? [String: Any]
            func control(_ capability: String) -> [String: Any]? {
                guard let entry = controls?[capability] as? [String: Any],
                      entry["state"] as? String == "auto_available" else { return nil }
                return entry
            }
            var keys: Set<String> = []
            if profiles?["reasoning"] != nil {
                keys.formUnion(ReasoningMode.allCases.filter { $0 != .automatic }.map {
                    "reasoning_level/\($0.rawValue)"
                })
            }
            if let reasoningControl = control("reasoning") {
                let intents = reasoningControl["availableIntents"] as? [String]
                    ?? ReasoningMode.allCases.filter { $0 != .automatic }.map(\.rawValue)
                keys.formUnion(intents.map { "reasoning_level/\($0)" })
            }
            if profiles?["webSearch"] != nil { keys.insert("web_search") }
            if control("web") != nil { keys.insert("web_search") }
            if model["toolCall"] as? Bool == true { keys.insert("tool_call") }
            let candidates = keys.sorted().map { key in
                [
                    "key": key, "support": "supported", "source": "server_profile",
                    "grade": "effect_verified", "scope": "provider_model_transport",
                    "providerKind": kind.rawValue, "modelId": modelID, "transport": transport,
                ] as [String: Any]
            }
            model["capabilityEvidenceView"] = [
                "schema": "capability-evidence-view/v1", "candidates": candidates,
            ]
            models[modelID] = model
        }
        provider["models"] = models
        providers[providerKey] = provider
    }
    root["providers"] = providers
    let data = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    try await MetadataClient.shared.loadForTesting(
        json: try #require(String(data: data, encoding: .utf8)),
        metadataETag: authorityEvidenceRevision
    )
}

private func authorityContext(
    providerKind: ProviderKind,
    modelID: String
) -> (identity: CapabilityEvidenceRequestIdentity, options: ChatRequestOptions) {
    let model = MetadataClient.shared.syncCurrentCapabilityEvidenceModel(
        TestFactories.makeModel(id: modelID), providerKind: providerKind
    )
    let provider = TestFactories.makeProvider(kind: providerKind, models: [model])
    var options = ChatRequestOptions()
    options.capabilityEvidenceModel = model
    return (
        CapabilityEvidenceRequestIdentity.make(
            provider: provider, model: model, partitionID: "authority-user",
            hasExplicitValue: true, metadataETag: authorityEvidenceRevision
        ),
        options
    )
}

@Suite("Provider request shape authority", .serialized)
struct ProviderRequestShapeAuthorityTests {
    @Test("Anthropic reasoning body comes from the server capability recipe and no control injects nothing")
    func anthropicReasoningUsesCapabilityRecipe() async throws {
        await MetadataClient.shared.resetForTesting()
        ProviderAuthorityMockURLProtocol.requestHandler = nil
        defer {
            ProviderAuthorityMockURLProtocol.requestHandler = nil
        }

        let runtime = try CapabilityRuntimeFixtures.runtimeEnvelopeJSON()
        let controls = try CapabilityRuntimeFixtures.controlsJSON(
            .init(
                capability: "reasoning",
                recipeRef: "anthropic.messages.reasoning.v1",
                availableIntents: try CapabilityRuntimeFixtures.reasoningIntents(
                    ofRecipe: "anthropic.messages.reasoning.v1"
                )
            )
        )
        try await loadAuthorityMetadata(json: """
        {
          "version": 1,
          "updatedAt": "2026-07-04T00:00:00Z",
          "capabilityRuntime": \(runtime),
          "providers": {
            "anthropic": {
              "transport": { "baseUrl": "https://api.anthropic.com/v1", "endpoints": { "chat": "/messages" } },
              "resolveMap": {
                "claude-fixture": "claude-fixture",
                "claude-no-profile": "claude-no-profile"
              },
              "models": {
                "claude-fixture": {
                  "canonicalModelId": "claude-fixture",
                  "capabilities": ["text", "reasoning"],
                  "transport": "anthropic_messages",
                  "capabilityControls": \(controls)
                },
                "claude-no-profile": {
                  "canonicalModelId": "claude-no-profile",
                  "capabilities": ["text", "reasoning"],
                  "transport": "anthropic_messages"
                }
              }
            }
          }
        }
        """)

        var bodies: [[String: Any]] = []
        ProviderAuthorityMockURLProtocol.requestHandler = { request in
            bodies.append(try authorityRequestBody(request))
            return (
                authorityHTTPResponse(url: try #require(request.url)),
                Data(#"{"content":[{"type":"text","text":"hi"}],"usage":{"input_tokens":1,"output_tokens":1}}"#.utf8)
            )
        }

        let service = AnthropicService(session: makeAuthorityMockSession())
        let profileContext = authorityContext(providerKind: .anthropic, modelID: "claude-fixture")
        _ = try await CapabilityEvidenceRequestContext.$current.withValue(profileContext.identity) {
            try await service.sendMessage(
                apiKey: "sk-ant", modelID: "claude-fixture",
                messages: [authorityUserMessage(provider: .anthropic, modelID: "claude-fixture")],
                reasoningMode: .deep, requestOptions: profileContext.options
            )
        }
        let noProfileContext = authorityContext(providerKind: .anthropic, modelID: "claude-no-profile")
        _ = try await CapabilityEvidenceRequestContext.$current.withValue(noProfileContext.identity) {
            try await service.sendMessage(
                apiKey: "sk-ant", modelID: "claude-no-profile",
                messages: [authorityUserMessage(provider: .anthropic, modelID: "claude-no-profile")],
                reasoningMode: .deep, requestOptions: noProfileContext.options
            )
        }

        let profileBody = try #require(bodies.first)
        let expectedThinking = try #require(
            try CapabilityRuntimeFixtures.recipeValue(
                recipeRef: "anthropic.messages.reasoning.v1", intent: "deep", pointer: "/thinking"
            ) as? [String: Any]
        )
        let thinking = try #require(profileBody["thinking"] as? [String: Any])
        #expect(thinking["type"] as? String == expectedThinking["type"] as? String)
        #expect(
            (thinking["budget_tokens"] as? NSNumber)?.intValue
                == (expectedThinking["budget_tokens"] as? NSNumber)?.intValue
        )
        #expect((profileBody["max_tokens"] as? NSNumber)?.intValue == 8192)

        let noProfileBody = try #require(bodies.last)
        #expect(noProfileBody["thinking"] == nil)
        #expect(noProfileBody["output_config"] == nil)
    }

    @Test("Anthropic Max Tokens Comes From Catalog And Exceeds Thinking Budget")
    func anthropicMaxTokensComesFromCatalogAndExceedsThinkingBudget() async throws {
        await MetadataClient.shared.resetForTesting()
        ProviderAuthorityMockURLProtocol.requestHandler = nil
        defer {
            ProviderAuthorityMockURLProtocol.requestHandler = nil
        }

        let runtime = try CapabilityRuntimeFixtures.runtimeEnvelopeJSON()
        let controls = try CapabilityRuntimeFixtures.controlsJSON(
            .init(
                capability: "reasoning",
                recipeRef: "anthropic.messages.reasoning.v1",
                availableIntents: try CapabilityRuntimeFixtures.reasoningIntents(
                    ofRecipe: "anthropic.messages.reasoning.v1"
                )
            )
        )
        try await loadAuthorityMetadata(json: """
        {
          "version": 1,
          "updatedAt": "2026-07-04T00:00:00Z",
          "capabilityRuntime": \(runtime),
          "providers": {
            "anthropic": {
              "transport": { "baseUrl": "https://api.anthropic.com/v1", "endpoints": { "chat": "/messages" } },
              "resolveMap": { "claude-sonnet-4-5": "claude-sonnet-4-5" },
              "models": {
                "claude-sonnet-4-5": {
                  "canonicalModelId": "claude-sonnet-4-5",
                  "capabilities": ["text", "reasoning"],
                  "transport": "anthropic_messages",
                  "maxOutputTokens": 64000,
                  "capabilityControls": \(controls)
                }
              }
            }
          }
        }
        """)

        var body: [String: Any] = [:]
        ProviderAuthorityMockURLProtocol.requestHandler = { request in
            body = try authorityRequestBody(request)
            return (
                authorityHTTPResponse(url: try #require(request.url)),
                Data(#"{"content":[{"type":"text","text":"hi"}],"usage":{"input_tokens":1,"output_tokens":1}}"#.utf8)
            )
        }

        let service = AnthropicService(session: makeAuthorityMockSession())
        let context = authorityContext(providerKind: .anthropic, modelID: "claude-sonnet-4-5")
        _ = try await CapabilityEvidenceRequestContext.$current.withValue(context.identity) {
            try await service.sendMessage(
                apiKey: "sk-ant", modelID: "claude-sonnet-4-5",
                messages: [authorityUserMessage(provider: .anthropic, modelID: "claude-sonnet-4-5")],
                reasoningMode: .deep, requestOptions: context.options
            )
        }

        let recipeThinking = try #require(
            try CapabilityRuntimeFixtures.recipeValue(
                recipeRef: "anthropic.messages.reasoning.v1", intent: "deep", pointer: "/thinking"
            ) as? [String: Any]
        )
        let budgetTokens = try #require((recipeThinking["budget_tokens"] as? NSNumber)?.intValue)
        let catalogMaxOutput = try #require(
            MetadataClient.shared.syncResolveCatalogModel(
                modelID: "claude-sonnet-4-5", providerKind: .anthropic
            )?.maxOutputTokens
        )
        let maxTokens = try #require((body["max_tokens"] as? NSNumber)?.intValue)
        let sentBudget = try #require(
            ((body["thinking"] as? [String: Any])?["budget_tokens"] as? NSNumber)?.intValue
        )

        #expect(sentBudget == budgetTokens)
        #expect(maxTokens == catalogMaxOutput)
        #expect(maxTokens > sentBudget)
        #expect(8192 <= budgetTokens)
    }

    @Test("Gemini reasoning and web params come from the server capability recipes")
    func geminiReasoningAndWebUseCapabilityRecipes() async throws {
        await MetadataClient.shared.resetForTesting()
        ProviderAuthorityMockURLProtocol.requestHandler = nil
        defer {
            ProviderAuthorityMockURLProtocol.requestHandler = nil
        }

        let runtime = try CapabilityRuntimeFixtures.runtimeEnvelopeJSON()
        let controls = try CapabilityRuntimeFixtures.controlsJSON(
            .init(
                capability: "reasoning",
                recipeRef: "gemini.generate_content.reasoning.v1",
                availableIntents: try CapabilityRuntimeFixtures.reasoningIntents(
                    ofRecipe: "gemini.generate_content.reasoning.v1"
                )
            ),
            .init(capability: "web", recipeRef: "gemini.generate_content.web.v2")
        )
        try await loadAuthorityMetadata(json: """
        {
          "version": 1,
          "updatedAt": "2026-07-04T00:00:00Z",
          "capabilityRuntime": \(runtime),
          "providers": {
            "gemini": {
              "transport": { "baseUrl": "https://generativelanguage.googleapis.com/v1beta", "endpoints": { "chat": "/models" } },
              "resolveMap": { "gemini-fixture": "gemini-fixture" },
              "models": {
                "gemini-fixture": {
                  "canonicalModelId": "gemini-fixture",
                  "capabilities": ["text", "reasoning", "web"],
                  "transport": "gemini_generate",
                  "capabilityControls": \(controls)
                }
              }
            }
          }
        }
        """)

        var body: [String: Any] = [:]
        ProviderAuthorityMockURLProtocol.requestHandler = { request in
            body = try authorityRequestBody(request)
            return (
                authorityHTTPResponse(url: try #require(request.url)),
                Data(#"{"candidates":[{"content":{"parts":[{"text":"hi"}]}}],"usageMetadata":{"promptTokenCount":1,"candidatesTokenCount":1}}"#.utf8)
            )
        }

        let service = GeminiService(session: makeAuthorityMockSession())
        let context = authorityContext(providerKind: .gemini, modelID: "gemini-fixture")
        _ = try await CapabilityEvidenceRequestContext.$current.withValue(context.identity) {
            try await service.sendMessage(
                apiKey: "gem-key", modelID: "gemini-fixture",
                messages: [authorityUserMessage(provider: .gemini, modelID: "gemini-fixture")],
                reasoningMode: .deep, webSearchEnabled: true,
                requestOptions: context.options
            )
        }

        let generationConfig = try #require(body["generationConfig"] as? [String: Any])
        let thinkingConfig = try #require(generationConfig["thinkingConfig"] as? [String: Any])
        let expectedBudget = try #require(
            try CapabilityRuntimeFixtures.recipeValue(
                recipeRef: "gemini.generate_content.reasoning.v1",
                intent: "deep",
                pointer: "/generationConfig/thinkingConfig/thinkingBudget"
            ) as? NSNumber
        )
        #expect((thinkingConfig["thinkingBudget"] as? NSNumber)?.intValue == expectedBudget.intValue)
        let tools = try #require(body["tools"] as? [[String: Any]])
        #expect(tools.first?["google_search_retrieval"] != nil)
        #expect(tools.first?["google_search"] == nil)
    }

    @Test("Gemini image generation merge params come from metadata image profile")
    func geminiImageGenerationUsesMetadataProfile() async throws {
        await MetadataClient.shared.resetForTesting()
        ProviderAuthorityMockURLProtocol.requestHandler = nil
        defer {
            ProviderAuthorityMockURLProtocol.requestHandler = nil
        }

        try await loadAuthorityMetadata(json: """
        {
          "version": 1,
          "updatedAt": "2026-07-04T00:00:00Z",
          "profiles": {
            "imageGen": {
              "gem_image_fixture": {
                "mergeParams": {
                  "generationConfig": {
                    "responseModalities": ["TEXT", "IMAGE"],
                    "serverImageProfile": true
                  }
                }
              }
            }
          },
          "providers": {
            "gemini": {
              "transport": { "baseUrl": "https://generativelanguage.googleapis.com/v1beta", "endpoints": { "chat": "/models" } },
              "resolveMap": { "gemini-image-fixture": "gemini-image-fixture" },
              "models": {
                "gemini-image-fixture": {
                  "canonicalModelId": "gemini-image-fixture",
                  "capabilities": ["text", "imageGeneration"],
                  "transport": "gemini_content",
                  "profiles": { "imageGen": "gem_image_fixture" }
                }
              }
            }
          }
        }
        """)

        var body: [String: Any] = [:]
        ProviderAuthorityMockURLProtocol.requestHandler = { request in
            body = try authorityRequestBody(request)
            return (
                authorityHTTPResponse(url: try #require(request.url)),
                Data(#"{"candidates":[{"content":{"parts":[{"text":"hi"}]}}],"usageMetadata":{"promptTokenCount":1,"candidatesTokenCount":1}}"#.utf8)
            )
        }

        let service = GeminiService(session: makeAuthorityMockSession())
        _ = try await service.sendMessage(
            apiKey: "gem-key",
            modelID: "gemini-image-fixture",
            messages: [authorityUserMessage(provider: .gemini, modelID: "gemini-image-fixture")],
            supportsImageGen: true
        )

        let generationConfig = try #require(body["generationConfig"] as? [String: Any])
        #expect(generationConfig["serverImageProfile"] as? Bool == true)
        #expect(generationConfig["responseModalities"] as? [String] == ["TEXT", "IMAGE"])
    }

    @Test("Qwen chat endpoint and hybrid thinking switch come from the capability recipe")
    func qwenUsesMetadataTransportAndCapabilityRecipe() async throws {
        await MetadataClient.shared.resetForTesting()
        ProviderAuthorityMockURLProtocol.requestHandler = nil
        defer {
            ProviderAuthorityMockURLProtocol.requestHandler = nil
        }

        let runtime = try CapabilityRuntimeFixtures.runtimeEnvelopeJSON()
        let controls = try CapabilityRuntimeFixtures.controlsJSON(
            .init(
                capability: "reasoning",
                recipeRef: "qwen.chat.reasoning.v1",
                availableIntents: try CapabilityRuntimeFixtures.reasoningIntents(
                    ofRecipe: "qwen.chat.reasoning.v1"
                )
            )
        )
        try await loadAuthorityMetadata(json: """
        {
          "version": 1,
          "updatedAt": "2026-07-04T00:00:00Z",
          "capabilityRuntime": \(runtime),
          "providers": {
            "qwen": {
              "transport": {
                "baseUrl": "https://dashscope-intl.aliyuncs.com/compatible-mode/v1",
                "endpoints": { "chat": "/chat/completions" }
              },
              "resolveMap": { "qwen-fixture": "qwen-fixture" },
              "models": {
                "qwen-fixture": {
                  "canonicalModelId": "qwen-fixture",
                  "capabilities": ["text", "reasoning"],
                  "transport": "openai_chat",
                  "capabilityControls": \(controls)
                }
              }
            }
          }
        }
        """)

        var requestedURL: URL?
        var body: [String: Any] = [:]
        ProviderAuthorityMockURLProtocol.requestHandler = { request in
            requestedURL = request.url
            body = try authorityRequestBody(request)
            return (
                authorityHTTPResponse(url: try #require(request.url)),
                Data(#"{"choices":[{"message":{"content":"hi"}}],"usage":{"prompt_tokens":1,"completion_tokens":1}}"#.utf8)
            )
        }

        let service = QwenService(session: makeAuthorityMockSession())
        let context = authorityContext(providerKind: .qwen, modelID: "qwen-fixture")
        _ = try await CapabilityEvidenceRequestContext.$current.withValue(context.identity) {
            try await service.sendMessage(
                apiKey: "sk-qwen", modelID: "qwen-fixture",
                messages: [authorityUserMessage(provider: .qwen, modelID: "qwen-fixture")],
                reasoningMode: .balanced, requestOptions: context.options
            )
        }

        #expect(requestedURL?.absoluteString == "https://dashscope-intl.aliyuncs.com/compatible-mode/v1/chat/completions")
        let expectedEnable = try #require(
            try CapabilityRuntimeFixtures.recipeValue(
                recipeRef: "qwen.chat.reasoning.v1", intent: "balanced", pointer: "/enable_thinking"
            ) as? Bool
        )
        #expect(body["enable_thinking"] as? Bool == expectedEnable)
        #expect(body["thinking_budget"] == nil)
    }

    @Test("OpenAI official openai_chat transport uses chat endpoint and routes web by model, not by tools")
    func openAIUsesMetadataTransportForChatModel() async throws {
        await MetadataClient.shared.resetForTesting()
        ProviderAuthorityMockURLProtocol.requestHandler = nil
        defer {
            ProviderAuthorityMockURLProtocol.requestHandler = nil
        }

        let runtime = try CapabilityRuntimeFixtures.runtimeEnvelopeJSON()
        let controls = try CapabilityRuntimeFixtures.controlsJSON(
            .init(
                capability: "reasoning",
                recipeRef: "openai.chat.reasoning.v1",
                availableIntents: try CapabilityRuntimeFixtures.reasoningIntents(
                    ofRecipe: "openai.chat.reasoning.v1"
                )
            ),
            .init(capability: "web", recipeRef: "openai.chat.web_model.v1")
        )
        try await loadAuthorityMetadata(json: """
        {
          "version": 1,
          "updatedAt": "2026-07-04T00:00:00Z",
          "capabilityRuntime": \(runtime),
          "providers": {
            "openAI": {
              "transport": {
                "baseUrl": "https://api.openai.com/v1",
                "endpoints": {
                  "chat": "/chat/completions",
                  "responses": "/responses"
                }
              },
              "resolveMap": { "gpt-chat-fixture": "gpt-chat-fixture" },
              "models": {
                "gpt-chat-fixture": {
                  "canonicalModelId": "gpt-chat-fixture",
                  "capabilities": ["text", "reasoning", "web"],
                  "transport": "openai_chat",
                  "capabilityControls": \(controls)
                }
              }
            }
          }
        }
        """)

        var requestedURL: URL?
        var body: [String: Any] = [:]
        ProviderAuthorityMockURLProtocol.requestHandler = { request in
            requestedURL = request.url
            body = try authorityRequestBody(request)
            return (
                authorityHTTPResponse(url: try #require(request.url)),
                Data(#"{"choices":[{"message":{"role":"assistant","content":"hi"}}],"usage":{"prompt_tokens":1,"completion_tokens":1}}"#.utf8)
            )
        }

        let service = OpenAIService(session: makeAuthorityMockSession())
        let context = authorityContext(providerKind: .openAI, modelID: "gpt-chat-fixture")
        _ = try await CapabilityEvidenceRequestContext.$current.withValue(context.identity) {
            try await service.sendMessage(
                apiKey: "sk-oai", modelID: "gpt-chat-fixture",
                messages: [authorityUserMessage(provider: .openAI, modelID: "gpt-chat-fixture")],
                reasoningMode: .deep, webSearchEnabled: true,
                requestOptions: context.options
            )
        }

        #expect(requestedURL?.absoluteString == "https://api.openai.com/v1/chat/completions")
        let expectedEffort = try #require(
            try CapabilityRuntimeFixtures.recipeValue(
                recipeRef: "openai.chat.reasoning.v1", intent: "deep", pointer: "/reasoning_effort"
            ) as? String
        )
        #expect(body["reasoning_effort"] as? String == expectedEffort)
        #expect(body["tools"] == nil)
        #expect(body["input"] == nil)
    }

    @Test("OpenRouter reasoning comes from the capability recipe and max_tokens from metadata maxOutputTokens")
    func openRouterUsesCapabilityRecipeAndMaxOutputTokens() async throws {
        await MetadataClient.shared.resetForTesting()
        ProviderAuthorityMockURLProtocol.requestHandler = nil
        defer {
            ProviderAuthorityMockURLProtocol.requestHandler = nil
        }

        let runtime = try CapabilityRuntimeFixtures.runtimeEnvelopeJSON()
        let controls = try CapabilityRuntimeFixtures.controlsJSON(
            .init(
                capability: "reasoning",
                recipeRef: "openrouter.chat.reasoning.v1",
                availableIntents: try CapabilityRuntimeFixtures.reasoningIntents(
                    ofRecipe: "openrouter.chat.reasoning.v1"
                )
            )
        )
        try await loadAuthorityMetadata(json: """
        {
          "version": 1,
          "updatedAt": "2026-07-04T00:00:00Z",
          "capabilityRuntime": \(runtime),
          "providers": {
            "openRouter": {
              "transport": { "baseUrl": "https://openrouter.ai/api/v1", "endpoints": { "chat": "/chat/completions" } },
              "resolveMap": { "minimax/minimax-m2.5:free": "minimax/minimax-m2.5:free" },
              "models": {
                "minimax/minimax-m2.5:free": {
                  "canonicalModelId": "minimax/minimax-m2.5:free",
                  "capabilities": ["text", "reasoning"],
                  "transport": "openai_chat",
                  "maxOutputTokens": 2222,
                  "capabilityControls": \(controls)
                }
              }
            }
          }
        }
        """)

        var body: [String: Any] = [:]
        ProviderAuthorityMockURLProtocol.requestHandler = { request in
            body = try authorityRequestBody(request)
            return (
                authorityHTTPResponse(url: try #require(request.url)),
                Data(#"{"choices":[{"message":{"role":"assistant","content":"hi"}}],"usage":{"prompt_tokens":1,"completion_tokens":1}}"#.utf8)
            )
        }

        let service = OpenRouterService(session: makeAuthorityMockSession())
        let context = authorityContext(providerKind: .openRouter, modelID: "minimax/minimax-m2.5:free")
        _ = try await CapabilityEvidenceRequestContext.$current.withValue(context.identity) {
            try await service.sendMessage(
                apiKey: "sk-or", modelID: "minimax/minimax-m2.5:free",
                messages: [authorityUserMessage(provider: .openRouter, modelID: "minimax/minimax-m2.5:free")],
                reasoningMode: .max, requestOptions: context.options
            )
        }

        #expect((body["max_tokens"] as? NSNumber)?.intValue == 2222)
        let reasoning = try #require(body["reasoning"] as? [String: Any])
        let expectedEffort = try #require(
            try CapabilityRuntimeFixtures.recipeValue(
                recipeRef: "openrouter.chat.reasoning.v1", intent: "max", pointer: "/reasoning/effort"
            ) as? String
        )
        #expect(reasoning["effort"] as? String == expectedEffort)
    }

    @Test("OpenRouter web search tools come from the capability recipe without local profile whitelist")
    func openRouterWebSearchUsesCapabilityRecipe() async throws {
        await MetadataClient.shared.resetForTesting()
        ProviderAuthorityMockURLProtocol.requestHandler = nil
        defer {
            ProviderAuthorityMockURLProtocol.requestHandler = nil
        }

        let runtime = try CapabilityRuntimeFixtures.runtimeEnvelopeJSON()
        let controls = try CapabilityRuntimeFixtures.controlsJSON(
            .init(capability: "web", recipeRef: "openrouter.chat.web.v1")
        )
        try await loadAuthorityMetadata(json: """
        {
          "version": 1,
          "updatedAt": "2026-07-04T00:00:00Z",
          "capabilityRuntime": \(runtime),
          "providers": {
            "openRouter": {
              "transport": { "baseUrl": "https://openrouter.ai/api/v1", "endpoints": { "chat": "/chat/completions" } },
              "resolveMap": { "future/web": "future/web" },
              "models": {
                "future/web": {
                  "canonicalModelId": "future/web",
                  "capabilities": ["text", "web"],
                  "transport": "openai_chat",
                  "capabilityControls": \(controls)
                }
              }
            }
          }
        }
        """)

        var body: [String: Any] = [:]
        ProviderAuthorityMockURLProtocol.requestHandler = { request in
            body = try authorityRequestBody(request)
            return (
                authorityHTTPResponse(url: try #require(request.url)),
                Data(#"{"choices":[{"message":{"role":"assistant","content":"hi"}}],"usage":{"prompt_tokens":1,"completion_tokens":1}}"#.utf8)
            )
        }

        let service = OpenRouterService(session: makeAuthorityMockSession())
        let context = authorityContext(providerKind: .openRouter, modelID: "future/web")
        _ = try await CapabilityEvidenceRequestContext.$current.withValue(context.identity) {
            try await service.sendMessage(
                apiKey: "sk-or", modelID: "future/web",
                messages: [authorityUserMessage(provider: .openRouter, modelID: "future/web")],
                webSearchEnabled: true, requestOptions: context.options
            )
        }

        let tools = try #require(body["tools"] as? [[String: Any]])
        let expectedTool = try #require(
            try CapabilityRuntimeFixtures.recipeValue(
                recipeRef: "openrouter.chat.web.v1", pointer: "/tools/-"
            ) as? [String: Any]
        )
        #expect(tools.first?["type"] as? String == expectedTool["type"] as? String)
    }

    @Test("DeepSeek thinking params come from the capability recipe and no control injects nothing")
    func deepSeekReasoningUsesCapabilityRecipe() async throws {
        await MetadataClient.shared.resetForTesting()
        ProviderAuthorityMockURLProtocol.requestHandler = nil
        defer {
            ProviderAuthorityMockURLProtocol.requestHandler = nil
        }

        let runtime = try CapabilityRuntimeFixtures.runtimeEnvelopeJSON()
        let controls = try CapabilityRuntimeFixtures.controlsJSON(
            .init(
                capability: "reasoning",
                recipeRef: "deepseek.chat.reasoning.v1",
                availableIntents: try CapabilityRuntimeFixtures.reasoningIntents(
                    ofRecipe: "deepseek.chat.reasoning.v1"
                )
            )
        )
        try await loadAuthorityMetadata(json: """
        {
          "version": 1,
          "updatedAt": "2026-07-04T00:00:00Z",
          "capabilityRuntime": \(runtime),
          "providers": {
            "deepseek": {
              "resolveMap": {
                "deepseek-fixture": "deepseek-fixture",
                "deepseek-no-profile": "deepseek-no-profile"
              },
              "models": {
                "deepseek-fixture": {
                  "canonicalModelId": "deepseek-fixture",
                  "capabilities": ["text", "reasoning"],
                  "transport": "openai_chat",
                  "capabilityControls": \(controls)
                },
                "deepseek-no-profile": {
                  "canonicalModelId": "deepseek-no-profile",
                  "capabilities": ["text", "reasoning"],
                  "transport": "openai_chat"
                }
              }
            }
          }
        }
        """)

        var bodies: [[String: Any]] = []
        ProviderAuthorityMockURLProtocol.requestHandler = { request in
            bodies.append(try authorityRequestBody(request))
            return (
                authorityHTTPResponse(url: try #require(request.url)),
                Data(#"{"choices":[{"message":{"content":"hi"}}],"usage":{"prompt_tokens":1,"completion_tokens":1}}"#.utf8)
            )
        }

        let service = DeepSeekService(session: makeAuthorityMockSession())
        let profileContext = authorityContext(providerKind: .deepseek, modelID: "deepseek-fixture")
        _ = try await CapabilityEvidenceRequestContext.$current.withValue(profileContext.identity) {
            try await service.sendMessage(
                apiKey: "sk-ds", modelID: "deepseek-fixture",
                messages: [authorityUserMessage(provider: .deepseek, modelID: "deepseek-fixture")],
                reasoningMode: .deep, requestOptions: profileContext.options
            )
        }
        let noProfileContext = authorityContext(providerKind: .deepseek, modelID: "deepseek-no-profile")
        _ = try await CapabilityEvidenceRequestContext.$current.withValue(noProfileContext.identity) {
            try await service.sendMessage(
                apiKey: "sk-ds", modelID: "deepseek-no-profile",
                messages: [authorityUserMessage(provider: .deepseek, modelID: "deepseek-no-profile")],
                reasoningMode: .deep, requestOptions: noProfileContext.options
            )
        }

        let profileBody = try #require(bodies.first)
        let expectedEffort = try #require(
            try CapabilityRuntimeFixtures.recipeValue(
                recipeRef: "deepseek.chat.reasoning.v1", intent: "deep", pointer: "/reasoning_effort"
            ) as? String
        )
        #expect(profileBody["reasoning_effort"] as? String == expectedEffort)
        #expect(profileBody["thinking"] == nil)

        let noProfileBody = try #require(bodies.last)
        #expect(noProfileBody["thinking"] == nil)
        #expect(noProfileBody["reasoning_effort"] == nil)
    }

    @Test("Moonshot web search tool loop limit comes from metadata profile (no throw, final leg uses tool_choice=none)")
    func moonshotToolLoopLimitUsesMetadataProfile() async throws {
        await MetadataClient.shared.resetForTesting()
        ProviderAuthorityMockURLProtocol.requestHandler = nil
        defer {
            ProviderAuthorityMockURLProtocol.requestHandler = nil
        }

        try await loadAuthorityMetadata(json: """
        {
          "version": 1,
          "updatedAt": "2026-07-04T00:00:00Z",
          "profiles": {
            "webSearch": {
              "kimi_limited_web": {
                "maxToolLoops": 1,
                "mergeParams": {
                  "tools": [
                    { "type": "builtin_function", "function": { "name": "$web_search" } }
                  ]
                }
              }
            }
          },
          "providers": {
            "moonshot": {
              "transport": { "baseUrl": "https://api.moonshot.ai/v1", "endpoints": { "chat": "/chat/completions" } },
              "resolveMap": { "kimi-fixture": "kimi-fixture" },
              "models": {
                "kimi-fixture": {
                  "canonicalModelId": "kimi-fixture",
                  "capabilities": ["text", "web"],
                  "transport": "openai_chat",
                  "profiles": { "webSearch": "kimi_limited_web" }
                }
              }
            }
          }
        }
        """)

        let loopingLeg = """
        data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"t-1","type":"builtin_function","function":{"name":"$web_search","arguments":"{}"}}]}}],"usage":null}

        data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":1,"completion_tokens":1}}

        data: [DONE]
        """

        let recorder = AuthorityBodyRecorder()
        ProviderAuthorityMockURLProtocol.requestHandler = { request in
            recorder.append(try authorityRequestBody(request))
            return (
                authorityHTTPResponse(url: try #require(request.url), statusCode: 200),
                Data(loopingLeg.utf8)
            )
        }

        let service = MoonshotService(session: makeAuthorityMockSession())
        var unhandled: [ProviderToolCall] = []
        var doneText: String?
        for try await event in service.sendMessageStream(
            apiKey: "sk-kimi",
            modelID: "kimi-fixture",
            messages: [authorityUserMessage(provider: .moonshot, modelID: "kimi-fixture")],
            reasoningMode: .automatic,
            webSearchEnabled: true
        ) {
            switch event {
            case let .toolCallDeltas(calls): unhandled.append(contentsOf: calls)
            case let .done(result): doneText = result.text
            default: break
            }
        }

        let bodies = recorder.snapshot()
        #expect(bodies.count == 2)
        let finalBody = try #require(bodies.last)
        #expect((finalBody["tools"] != nil) == (finalBody["tool_choice"] as? String == "none"))
        let messages = try #require(finalBody["messages"] as? [[String: Any]])
        let assistantToolCall = try #require(messages.first { $0["role"] as? String == "assistant" && $0["tool_calls"] != nil })
        let toolCalls = try #require(assistantToolCall["tool_calls"] as? [[String: Any]])
        #expect(toolCalls.first?["type"] as? String == "builtin_function")
        #expect(toolCalls.first?["id"] as? String == "t-1")
        #expect(assistantToolCall["reasoning_content"] as? String == "")
        let toolMessage = try #require(messages.first { $0["role"] as? String == "tool" })
        #expect(toolMessage["tool_call_id"] as? String == "t-1")
        #expect(toolMessage["name"] as? String == "$web_search")
        #expect(toolMessage["content"] as? String == "{}")
        #expect(messages.contains { ($0["role"] as? String) == "system" && (($0["content"] as? String) ?? "").contains("limit was reached") })
        #expect(unhandled.map(\.name) == ["$web_search"])
        #expect(doneText == "")
    }

    @Test("Moonshot Tools Rejected Bare Resend")
    func moonshotToolsRejectedBareResend() async throws {
        await MetadataClient.shared.resetForTesting()
        ProviderAuthorityMockURLProtocol.requestHandler = nil
        defer { ProviderAuthorityMockURLProtocol.requestHandler = nil }
        try await loadAuthorityMetadata(json: """
        {
          "version": 1,
          "updatedAt": "2026-07-04T00:00:00Z",
          "profiles": { "webSearch": { "kimi_limited_web": { "maxToolLoops": 2, "mergeParams": { "tools": [ { "type": "builtin_function", "function": { "name": "$web_search" } } ] } } } },
          "providers": {
            "moonshot": {
              "transport": { "baseUrl": "https://api.moonshot.ai/v1", "endpoints": { "chat": "/chat/completions" } },
              "resolveMap": { "kimi-fixture": "kimi-fixture" },
              "models": { "kimi-fixture": { "canonicalModelId": "kimi-fixture", "capabilities": ["text", "web"], "transport": "openai_chat", "profiles": { "webSearch": "kimi_limited_web" } } }
            }
          }
        }
        """)
        let recorder = AuthorityBodyRecorder()
        ProviderAuthorityMockURLProtocol.requestHandler = { request in
            let body = try authorityRequestBody(request)
            recorder.append(body)
            if recorder.snapshot().count == 1 {
                return (
                    authorityHTTPResponse(url: try #require(request.url), statusCode: 400),
                    Data(#"{"error":{"message":"This model does not support tools.","type":"invalid_request_error"}}"#.utf8)
                )
            }
            return (
                authorityHTTPResponse(url: try #require(request.url), statusCode: 200),
                Data("data: {\"choices\":[{\"delta\":{\"content\":\"Plain answer\"}}]}\n\ndata: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n".utf8)
            )
        }
        let tracker = CapabilityExecutionTracker()
        let service = MoonshotService(session: makeAuthorityMockSession())
        var doneText: String?
        try await CapabilityExecutionRuntime.$current.withValue(tracker) {
            for try await event in service.sendMessageStream(
                apiKey: "sk-kimi", modelID: "kimi-fixture",
                messages: [authorityUserMessage(provider: .moonshot, modelID: "kimi-fixture")],
                reasoningMode: .automatic, webSearchEnabled: true
            ) {
                if case let .done(result) = event { doneText = result.text }
            }
        }
        let bodies = recorder.snapshot()
        #expect(bodies.count == 2)
        #expect(bodies.last?["tools"] == nil)
        #expect(bodies.last?["tool_choice"] == nil)
        #expect(doneText == "Plain answer")
        #expect(tracker.terminalResult().states["web"] == .recovered)
    }

    @Test("Moonshot Unhandled Tool Call Without Web Search Ends After One Leg")
    func moonshotUnhandledToolCallWithoutWebSearchEndsAfterOneLeg() async throws {
        await MetadataClient.shared.resetForTesting()
        ProviderAuthorityMockURLProtocol.requestHandler = nil
        defer { ProviderAuthorityMockURLProtocol.requestHandler = nil }
        try await loadAuthorityMetadata(json: """
        {
          "version": 1,
          "updatedAt": "2026-07-04T00:00:00Z",
          "providers": {
            "moonshot": {
              "transport": { "baseUrl": "https://api.moonshot.ai/v1", "endpoints": { "chat": "/chat/completions" } },
              "resolveMap": { "kimi-fixture": "kimi-fixture" },
              "models": { "kimi-fixture": { "canonicalModelId": "kimi-fixture", "capabilities": ["text"], "transport": "openai_chat" } }
            }
          }
        }
        """)
        let leg = """
        data: {"choices":[{"delta":{"content":"Let me check."}}],"usage":null}

        data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"w-1","type":"function","function":{"name":"get_weather","arguments":"{\\"city\\":\\"Melbourne\\"}"}}]}}],"usage":null}

        data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":1,"completion_tokens":1}}

        data: [DONE]
        """
        var calls = 0
        ProviderAuthorityMockURLProtocol.requestHandler = { request in
            calls += 1
            return (authorityHTTPResponse(url: try #require(request.url), statusCode: 200), Data(leg.utf8))
        }
        let service = MoonshotService(session: makeAuthorityMockSession())
        var unhandled: [ProviderToolCall] = []
        var doneText: String?
        for try await event in service.sendMessageStream(
            apiKey: "sk-kimi", modelID: "kimi-fixture",
            messages: [authorityUserMessage(provider: .moonshot, modelID: "kimi-fixture")],
            reasoningMode: .automatic, webSearchEnabled: false
        ) {
            switch event {
            case let .toolCallDeltas(calls): unhandled.append(contentsOf: calls)
            case let .done(result): doneText = result.text
            default: break
            }
        }
        #expect(calls == 1)
        #expect(unhandled.map(\.name) == ["get_weather"])
        #expect(unhandled.first?.rawArguments == #"{"city":"Melbourne"}"#)
        #expect(doneText == "Let me check.")
    }

    @Test("SiliconFlow thinking params come from the capability recipe and no control injects nothing")
    func siliconFlowReasoningUsesCapabilityRecipe() async throws {
        await MetadataClient.shared.resetForTesting()
        ProviderAuthorityMockURLProtocol.requestHandler = nil
        defer {
            ProviderAuthorityMockURLProtocol.requestHandler = nil
        }

        let runtime = try CapabilityRuntimeFixtures.runtimeEnvelopeJSON()
        let controls = try CapabilityRuntimeFixtures.controlsJSON(
            .init(
                capability: "reasoning",
                recipeRef: "siliconflow.chat.reasoning.v1",
                availableIntents: try CapabilityRuntimeFixtures.reasoningIntents(
                    ofRecipe: "siliconflow.chat.reasoning.v1"
                )
            )
        )
        try await loadAuthorityMetadata(json: """
        {
          "version": 1,
          "updatedAt": "2026-07-04T00:00:00Z",
          "capabilityRuntime": \(runtime),
          "providers": {
            "siliconFlow": {
              "resolveMap": {
                "sf-fixture": "sf-fixture",
                "sf-no-profile": "sf-no-profile"
              },
              "models": {
                "sf-fixture": {
                  "canonicalModelId": "sf-fixture",
                  "capabilities": ["text", "reasoning"],
                  "transport": "openai_chat",
                  "capabilityControls": \(controls)
                },
                "sf-no-profile": {
                  "canonicalModelId": "sf-no-profile",
                  "capabilities": ["text", "reasoning"],
                  "transport": "openai_chat"
                }
              }
            }
          }
        }
        """)

        var bodies: [[String: Any]] = []
        ProviderAuthorityMockURLProtocol.requestHandler = { request in
            bodies.append(try authorityRequestBody(request))
            return (
                authorityHTTPResponse(url: try #require(request.url)),
                Data(#"{"choices":[{"message":{"role":"assistant","content":"hi"}}],"usage":{"prompt_tokens":1,"completion_tokens":1}}"#.utf8)
            )
        }

        let service = SiliconFlowService(session: makeAuthorityMockSession())
        let profileContext = authorityContext(providerKind: .siliconFlow, modelID: "sf-fixture")
        _ = try await CapabilityEvidenceRequestContext.$current.withValue(profileContext.identity) {
            try await service.sendMessage(
                apiKey: "sk-sf", modelID: "sf-fixture",
                messages: [authorityUserMessage(provider: .siliconFlow, modelID: "sf-fixture")],
                reasoningMode: .deep, requestOptions: profileContext.options
            )
        }
        let noProfileContext = authorityContext(providerKind: .siliconFlow, modelID: "sf-no-profile")
        _ = try await CapabilityEvidenceRequestContext.$current.withValue(noProfileContext.identity) {
            try await service.sendMessage(
                apiKey: "sk-sf", modelID: "sf-no-profile",
                messages: [authorityUserMessage(provider: .siliconFlow, modelID: "sf-no-profile")],
                reasoningMode: .deep, requestOptions: noProfileContext.options
            )
        }

        let profileBody = try #require(bodies.first)
        let expectedEnable = try #require(
            try CapabilityRuntimeFixtures.recipeValue(
                recipeRef: "siliconflow.chat.reasoning.v1", intent: "deep", pointer: "/enable_thinking"
            ) as? Bool
        )
        let expectedBudget = try #require(
            try CapabilityRuntimeFixtures.recipeValue(
                recipeRef: "siliconflow.chat.reasoning.v1", intent: "deep", pointer: "/thinking_budget"
            ) as? NSNumber
        )
        #expect(profileBody["enable_thinking"] as? Bool == expectedEnable)
        #expect((profileBody["thinking_budget"] as? NSNumber)?.intValue == expectedBudget.intValue)

        let noProfileBody = try #require(bodies.last)
        #expect(noProfileBody["enable_thinking"] == nil)
        #expect(noProfileBody["thinking_budget"] == nil)
    }

    @Test("MiniMax image-looking model id stays on chat route without imageGen profile")
    func miniMaxImageRouteRequiresMetadataImageProfile() async throws {
        await MetadataClient.shared.resetForTesting()
        ProviderAuthorityMockURLProtocol.requestHandler = nil
        defer {
            ProviderAuthorityMockURLProtocol.requestHandler = nil
        }

        try await loadAuthorityMetadata(json: """
        {
          "version": 1,
          "updatedAt": "2026-07-04T00:00:00Z",
          "providers": {
            "miniMax": {
              "transport": {
                "baseUrl": "https://api.minimax.io/v1",
                "endpoints": { "chat": "/chat/completions" }
              },
              "resolveMap": { "image-local-chat": "image-local-chat" },
              "models": {
                "image-local-chat": {
                  "canonicalModelId": "image-local-chat",
                  "capabilities": ["text"],
                  "transport": "openai_chat"
                }
              }
            }
          }
        }
        """)

        var requestedURL: URL?
        ProviderAuthorityMockURLProtocol.requestHandler = { request in
            requestedURL = request.url
            return (
                authorityHTTPResponse(url: try #require(request.url)),
                Data(#"{"choices":[{"message":{"content":"hi"}}],"usage":{"prompt_tokens":1,"completion_tokens":1}}"#.utf8)
            )
        }

        let service = MiniMaxService(session: makeAuthorityMockSession())
        _ = try await service.sendMessage(
            apiKey: "sk-mm",
            modelID: "image-local-chat",
            messages: [authorityUserMessage(provider: .miniMax, modelID: "image-local-chat")]
        )

        #expect(requestedURL?.path == "/v1/chat/completions")
    }

    @Test("Qwen image-looking model id stays on chat route unless transport is qwen_image")
    func qwenImageRouteRequiresMetadataTransport() async throws {
        await MetadataClient.shared.resetForTesting()
        ProviderAuthorityMockURLProtocol.requestHandler = nil
        defer {
            ProviderAuthorityMockURLProtocol.requestHandler = nil
        }

        try await loadAuthorityMetadata(json: """
        {
          "version": 1,
          "updatedAt": "2026-07-04T00:00:00Z",
          "providers": {
            "qwen": {
              "transport": {
                "baseUrl": "https://dashscope-intl.aliyuncs.com/compatible-mode/v1",
                "endpoints": { "chat": "/chat/completions" }
              },
              "resolveMap": { "qwen-image-chat": "qwen-image-chat" },
              "models": {
                "qwen-image-chat": {
                  "canonicalModelId": "qwen-image-chat",
                  "capabilities": ["text"],
                  "transport": "openai_chat"
                }
              }
            }
          }
        }
        """)

        var requestedURL: URL?
        ProviderAuthorityMockURLProtocol.requestHandler = { request in
            requestedURL = request.url
            return (
                authorityHTTPResponse(url: try #require(request.url)),
                Data(#"{"choices":[{"message":{"content":"hi"}}],"usage":{"prompt_tokens":1,"completion_tokens":1}}"#.utf8)
            )
        }

        let service = QwenService(session: makeAuthorityMockSession())
        _ = try await service.sendMessage(
            apiKey: "sk-qwen",
            modelID: "qwen-image-chat",
            messages: [authorityUserMessage(provider: .qwen, modelID: "qwen-image-chat")]
        )

        #expect(requestedURL?.path == "/compatible-mode/v1/chat/completions")
    }

    @Test("Zhipu image-looking model id stays on chat route unless transport is zhipu_image")
    func zhipuImageRouteRequiresMetadataTransport() async throws {
        await MetadataClient.shared.resetForTesting()
        ProviderAuthorityMockURLProtocol.requestHandler = nil
        defer {
            ProviderAuthorityMockURLProtocol.requestHandler = nil
        }

        try await loadAuthorityMetadata(json: """
        {
          "version": 1,
          "updatedAt": "2026-07-04T00:00:00Z",
          "providers": {
            "zhipu": {
              "transport": {
                "baseUrl": "https://open.bigmodel.cn/api/paas/v4",
                "endpoints": { "chat": "/chat/completions" }
              },
              "resolveMap": { "cogview-chat": "cogview-chat" },
              "models": {
                "cogview-chat": {
                  "canonicalModelId": "cogview-chat",
                  "capabilities": ["text"],
                  "transport": "openai_chat"
                }
              }
            }
          }
        }
        """)

        var requestedURL: URL?
        ProviderAuthorityMockURLProtocol.requestHandler = { request in
            requestedURL = request.url
            return (
                authorityHTTPResponse(url: try #require(request.url)),
                Data(#"{"choices":[{"message":{"content":"hi"}}],"usage":{"prompt_tokens":1,"completion_tokens":1}}"#.utf8)
            )
        }

        let service = ZhipuService(session: makeAuthorityMockSession())
        _ = try await service.sendMessage(
            apiKey: "sk-zhipu",
            modelID: "cogview-chat",
            messages: [authorityUserMessage(provider: .zhipu, modelID: "cogview-chat")]
        )

        #expect(requestedURL?.path == "/api/paas/v4/chat/completions")
    }
}
