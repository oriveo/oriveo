import Foundation
import Testing
@testable import Oriveo

final class OfficialProviderMetadataOnlyURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = OfficialProviderMetadataOnlyURLProtocol.requestHandler else {
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

private func makeOfficialProviderMetadataOnlySession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [OfficialProviderMetadataOnlyURLProtocol.self]
    return URLSession(configuration: config)
}

private func officialProviderMetadataOnlyHTTPResponse(url: URL, statusCode: Int) -> HTTPURLResponse {
    HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
}

@Suite("Official Provider Service Metadata-only", .serialized)
struct OfficialProviderServiceMetadataOnlyTests {
    @Test("Open AIOfficial Paths Are Metadata Only")
    func openAIOfficialPathsAreMetadataOnly() async throws {
        try await loadOfficialProviderMetadataOnlyFixture()
        defer { resetOfficialProviderMetadataOnlyFixture() }

        var requestedURLs: [URL] = []
        OfficialProviderMetadataOnlyURLProtocol.requestHandler = { request in
            let url = try #require(request.url)
            requestedURLs.append(url)
            return (
                officialProviderMetadataOnlyHTTPResponse(url: url, statusCode: 500),
                Data(#"{"error":{"message":"unexpected upstream call"}}"#.utf8)
            )
        }

        let service = OpenAIService(session: makeOfficialProviderMetadataOnlySession())
        let result = try await service.syncProvider(apiKey: "sk-openai-test", preferredModelID: nil)

        #expect(result.models.isEmpty)
        #expect(requestedURLs.isEmpty)
    }

    @Test("Open AICustom Base URLStill Probes Models")
    func openAICustomBaseURLStillProbesModels() async throws {
        try await loadOfficialProviderMetadataOnlyFixture()
        defer { resetOfficialProviderMetadataOnlyFixture() }

        var requestedURL: URL?
        OfficialProviderMetadataOnlyURLProtocol.requestHandler = { request in
            let url = try #require(request.url)
            requestedURL = url
            return (
                officialProviderMetadataOnlyHTTPResponse(url: url, statusCode: 200),
                Data(#"{"data":[{"id":"relay-chat-model"}]}"#.utf8)
            )
        }

        let service = OpenAIService(session: makeOfficialProviderMetadataOnlySession())
        let result = try await service.syncProvider(
            apiKey: "sk-relay-test",
            preferredModelID: nil,
            baseURL: "https://relay.example.com/v1"
        )

        #expect(requestedURL?.absoluteString == "https://relay.example.com/v1/models")
        #expect(result.models.map(\.id) == ["relay-chat-model"])
    }

    @Test("Mini Max Official Paths Are Metadata Only")
    func miniMaxOfficialPathsAreMetadataOnly() async throws {
        try await loadOfficialProviderMetadataOnlyFixture()
        defer { resetOfficialProviderMetadataOnlyFixture() }

        var requestedURLs: [URL] = []
        OfficialProviderMetadataOnlyURLProtocol.requestHandler = { request in
            let url = try #require(request.url)
            requestedURLs.append(url)
            return (
                officialProviderMetadataOnlyHTTPResponse(url: url, statusCode: 500),
                Data(#"{"error":{"message":"unexpected upstream call"}}"#.utf8)
            )
        }

        let service = MiniMaxService(session: makeOfficialProviderMetadataOnlySession())
        let result = try await service.syncProvider(
            apiKey: "sk-minimax-test",
            preferredModelID: nil,
            baseURL: "https://api.minimax.io/v1"
        )
        #expect(result.models.isEmpty)
        #expect(requestedURLs.isEmpty)
    }

    @Test("Open Router Official Paths Are Metadata Only")
    func openRouterOfficialPathsAreMetadataOnly() async throws {
        try await loadOfficialProviderMetadataOnlyFixture()
        defer { resetOfficialProviderMetadataOnlyFixture() }

        var requestedURLs: [URL] = []
        OfficialProviderMetadataOnlyURLProtocol.requestHandler = { request in
            let url = try #require(request.url)
            requestedURLs.append(url)
            return (
                officialProviderMetadataOnlyHTTPResponse(url: url, statusCode: 500),
                Data(#"{"error":{"message":"unexpected upstream call"}}"#.utf8)
            )
        }

        let service = OpenRouterService(session: makeOfficialProviderMetadataOnlySession())
        let result = try await service.syncProvider(apiKey: "sk-openrouter-test", preferredModelID: nil)

        #expect(result.models.isEmpty)
        #expect(requestedURLs.isEmpty)
    }

    @Test("Anthropic Official Paths Are Metadata Only")
    func anthropicOfficialPathsAreMetadataOnly() async throws {
        try await loadOfficialProviderMetadataOnlyFixture()
        defer { resetOfficialProviderMetadataOnlyFixture() }

        var requestedURLs: [URL] = []
        OfficialProviderMetadataOnlyURLProtocol.requestHandler = { request in
            let url = try #require(request.url)
            requestedURLs.append(url)
            return (
                officialProviderMetadataOnlyHTTPResponse(url: url, statusCode: 500),
                Data(#"{"error":{"message":"unexpected upstream call"}}"#.utf8)
            )
        }

        let service = AnthropicService(session: makeOfficialProviderMetadataOnlySession())
        let result = try await service.syncProvider(apiKey: "sk-anthropic-test", preferredModelID: nil)

        #expect(result.models.isEmpty)
        #expect(requestedURLs.isEmpty)
    }

    @Test("Gemini Official Paths Are Metadata Only")
    func geminiOfficialPathsAreMetadataOnly() async throws {
        try await loadOfficialProviderMetadataOnlyFixture()
        defer { resetOfficialProviderMetadataOnlyFixture() }

        var requestedURLs: [URL] = []
        OfficialProviderMetadataOnlyURLProtocol.requestHandler = { request in
            let url = try #require(request.url)
            requestedURLs.append(url)
            return (
                officialProviderMetadataOnlyHTTPResponse(url: url, statusCode: 500),
                Data(#"{"error":{"message":"unexpected upstream call"}}"#.utf8)
            )
        }

        let service = GeminiService(session: makeOfficialProviderMetadataOnlySession())
        let result = try await service.syncProvider(apiKey: "sk-gemini-test", preferredModelID: nil)

        #expect(result.models.isEmpty)
        #expect(requestedURLs.isEmpty)
    }

    @Test("Grok Official Paths Are Metadata Only")
    func grokOfficialPathsAreMetadataOnly() async throws {
        try await loadOfficialProviderMetadataOnlyFixture()
        defer { resetOfficialProviderMetadataOnlyFixture() }

        var requestedURLs: [URL] = []
        OfficialProviderMetadataOnlyURLProtocol.requestHandler = { request in
            let url = try #require(request.url)
            requestedURLs.append(url)
            return (
                officialProviderMetadataOnlyHTTPResponse(url: url, statusCode: 500),
                Data(#"{"error":{"message":"unexpected upstream call"}}"#.utf8)
            )
        }

        let service = GrokService(session: makeOfficialProviderMetadataOnlySession())
        let result = try await service.syncProvider(apiKey: "sk-grok-test", preferredModelID: nil)

        #expect(result.models.isEmpty)
        #expect(requestedURLs.isEmpty)
    }

    @Test("Deep Seek Official Paths Are Metadata Only")
    func deepSeekOfficialPathsAreMetadataOnly() async throws {
        try await loadOfficialProviderMetadataOnlyFixture()
        defer { resetOfficialProviderMetadataOnlyFixture() }

        var requestedURLs: [URL] = []
        OfficialProviderMetadataOnlyURLProtocol.requestHandler = { request in
            let url = try #require(request.url)
            requestedURLs.append(url)
            return (
                officialProviderMetadataOnlyHTTPResponse(url: url, statusCode: 500),
                Data(#"{"error":{"message":"unexpected upstream call"}}"#.utf8)
            )
        }

        let service = DeepSeekService(session: makeOfficialProviderMetadataOnlySession())
        let result = try await service.syncProvider(apiKey: "sk-deepseek-test", preferredModelID: nil)

        #expect(result.models.isEmpty)
        #expect(requestedURLs.isEmpty)
    }

    @Test("Fireworks Official Paths Are Metadata Only")
    func fireworksOfficialPathsAreMetadataOnly() async throws {
        try await loadOfficialProviderMetadataOnlyFixture()
        defer { resetOfficialProviderMetadataOnlyFixture() }

        var requestedURLs: [URL] = []
        OfficialProviderMetadataOnlyURLProtocol.requestHandler = { request in
            let url = try #require(request.url)
            requestedURLs.append(url)
            return (
                officialProviderMetadataOnlyHTTPResponse(url: url, statusCode: 500),
                Data(#"{"error":{"message":"unexpected upstream call"}}"#.utf8)
            )
        }

        let service = FireworksService(session: makeOfficialProviderMetadataOnlySession())
        let result = try await service.syncProvider(apiKey: "sk-fireworks-test", preferredModelID: nil)

        #expect(result.models.isEmpty)
        #expect(requestedURLs.isEmpty)
    }

    @Test("Groq Official Paths Are Metadata Only")
    func groqOfficialPathsAreMetadataOnly() async throws {
        try await loadOfficialProviderMetadataOnlyFixture()
        defer { resetOfficialProviderMetadataOnlyFixture() }

        var requestedURLs: [URL] = []
        OfficialProviderMetadataOnlyURLProtocol.requestHandler = { request in
            let url = try #require(request.url)
            requestedURLs.append(url)
            return (
                officialProviderMetadataOnlyHTTPResponse(url: url, statusCode: 500),
                Data(#"{"error":{"message":"unexpected upstream call"}}"#.utf8)
            )
        }

        let service = GroqService(session: makeOfficialProviderMetadataOnlySession())
        let result = try await service.syncProvider(apiKey: "sk-groq-test", preferredModelID: nil)

        #expect(result.models.isEmpty)
        #expect(requestedURLs.isEmpty)
    }

    @Test("Moonshot Official Paths Are Metadata Only")
    func moonshotOfficialPathsAreMetadataOnly() async throws {
        try await loadOfficialProviderMetadataOnlyFixture()
        defer { resetOfficialProviderMetadataOnlyFixture() }

        var requestedURLs: [URL] = []
        OfficialProviderMetadataOnlyURLProtocol.requestHandler = { request in
            let url = try #require(request.url)
            requestedURLs.append(url)
            return (
                officialProviderMetadataOnlyHTTPResponse(url: url, statusCode: 500),
                Data(#"{"error":{"message":"unexpected upstream call"}}"#.utf8)
            )
        }

        let service = MoonshotService(session: makeOfficialProviderMetadataOnlySession())
        let result = try await service.syncProvider(apiKey: "sk-moonshot-test", preferredModelID: nil)

        #expect(result.models.isEmpty)
        #expect(requestedURLs.isEmpty)
    }

    @Test("Mistral Official Paths Are Metadata Only")
    func mistralOfficialPathsAreMetadataOnly() async throws {
        try await loadOfficialProviderMetadataOnlyFixture()
        defer { resetOfficialProviderMetadataOnlyFixture() }

        var requestedURLs: [URL] = []
        OfficialProviderMetadataOnlyURLProtocol.requestHandler = { request in
            let url = try #require(request.url)
            requestedURLs.append(url)
            return (
                officialProviderMetadataOnlyHTTPResponse(url: url, statusCode: 500),
                Data(#"{"error":{"message":"unexpected upstream call"}}"#.utf8)
            )
        }

        let service = MistralService(session: makeOfficialProviderMetadataOnlySession())
        let result = try await service.syncProvider(apiKey: "mistral-test-key", preferredModelID: nil)

        #expect(result.models.isEmpty)
        #expect(requestedURLs.isEmpty)
    }

    @Test("Qwen Official Paths Are Metadata Only")
    func qwenOfficialPathsAreMetadataOnly() async throws {
        try await loadOfficialProviderMetadataOnlyFixture()
        defer { resetOfficialProviderMetadataOnlyFixture() }

        var requestedURLs: [URL] = []
        OfficialProviderMetadataOnlyURLProtocol.requestHandler = { request in
            let url = try #require(request.url)
            requestedURLs.append(url)
            return (
                officialProviderMetadataOnlyHTTPResponse(url: url, statusCode: 500),
                Data(#"{"error":{"message":"unexpected upstream call"}}"#.utf8)
            )
        }

        let service = QwenService(session: makeOfficialProviderMetadataOnlySession())
        let result = try await service.syncProvider(apiKey: "sk-qwen-test", preferredModelID: nil)

        #expect(result.models.isEmpty)
        #expect(requestedURLs.isEmpty)
    }

    @Test("Silicon Flow Official Paths Are Metadata Only")
    func siliconFlowOfficialPathsAreMetadataOnly() async throws {
        try await loadOfficialProviderMetadataOnlyFixture()
        defer { resetOfficialProviderMetadataOnlyFixture() }

        var requestedURLs: [URL] = []
        OfficialProviderMetadataOnlyURLProtocol.requestHandler = { request in
            let url = try #require(request.url)
            requestedURLs.append(url)
            return (
                officialProviderMetadataOnlyHTTPResponse(url: url, statusCode: 500),
                Data(#"{"error":{"message":"unexpected upstream call"}}"#.utf8)
            )
        }

        let service = SiliconFlowService(session: makeOfficialProviderMetadataOnlySession())
        let result = try await service.syncProvider(apiKey: "sk-siliconflow-test", preferredModelID: nil)

        #expect(result.models.isEmpty)
        #expect(requestedURLs.isEmpty)
    }

    @Test("Zhipu Official Paths Are Metadata Only")
    func zhipuOfficialPathsAreMetadataOnly() async throws {
        try await loadOfficialProviderMetadataOnlyFixture()
        defer { resetOfficialProviderMetadataOnlyFixture() }

        var requestedURLs: [URL] = []
        OfficialProviderMetadataOnlyURLProtocol.requestHandler = { request in
            let url = try #require(request.url)
            requestedURLs.append(url)
            return (
                officialProviderMetadataOnlyHTTPResponse(url: url, statusCode: 500),
                Data(#"{"error":{"message":"unexpected upstream call"}}"#.utf8)
            )
        }

        let service = ZhipuService(session: makeOfficialProviderMetadataOnlySession())
        let result = try await service.syncProvider(apiKey: "sk-zhipu-test", preferredModelID: nil)

        #expect(result.models.isEmpty)
        #expect(requestedURLs.isEmpty)
    }

    @Test("Together Official Paths Are Metadata Only")
    func togetherOfficialPathsAreMetadataOnly() async throws {
        try await loadOfficialProviderMetadataOnlyFixture()
        defer { resetOfficialProviderMetadataOnlyFixture() }

        var requestedURLs: [URL] = []
        OfficialProviderMetadataOnlyURLProtocol.requestHandler = { request in
            let url = try #require(request.url)
            requestedURLs.append(url)
            return (
                officialProviderMetadataOnlyHTTPResponse(url: url, statusCode: 500),
                Data(#"{"error":{"message":"unexpected upstream call"}}"#.utf8)
            )
        }

        let service = TogetherService(session: makeOfficialProviderMetadataOnlySession())
        let result = try await service.syncProvider(apiKey: "sk-together-test", preferredModelID: nil)

        #expect(result.models.isEmpty)
        #expect(requestedURLs.isEmpty)
    }
}

private func resetOfficialProviderMetadataOnlyFixture() {
    OfficialProviderMetadataOnlyURLProtocol.requestHandler = nil
}

private func loadOfficialProviderMetadataOnlyFixture() async throws {
    await MetadataClient.shared.resetForTesting()
    OfficialProviderMetadataOnlyURLProtocol.requestHandler = nil
    try await MetadataClient.shared.loadForTesting(json: """
    {
      "version": 1,
      "updatedAt": "2026-05-11T00:00:00Z",
      "providers": {
        "openAI": {
          "displayName": "OpenAI",
          "defaultModelId": "gpt-4o-mini",
          "validationModelId": "gpt-4o-mini",
          "resolveMap": { "gpt-4o-mini": "gpt-4o-mini" },
          "models": {
            "gpt-4o-mini": {
              "canonicalModelId": "gpt-4o-mini",
              "displayName": "GPT-4o mini",
              "capabilities": ["text"]
            }
          }
        },
        "openRouter": {
          "displayName": "OpenRouter",
          "defaultModelId": "openai/gpt-4o-mini",
          "validationModelId": "openai/gpt-4o-mini",
          "resolveMap": { "openai/gpt-4o-mini": "openai/gpt-4o-mini" },
          "models": {
            "openai/gpt-4o-mini": {
              "canonicalModelId": "openai/gpt-4o-mini",
              "displayName": "GPT-4o mini",
              "capabilities": ["text"]
            }
          }
        },
        "miniMax": {
          "displayName": "MiniMax",
          "defaultModelId": "MiniMax-M2.5",
          "validationModelId": "MiniMax-M2.5",
          "resolveMap": { "MiniMax-M2.5": "MiniMax-M2.5" },
          "models": {
            "MiniMax-M2.5": {
              "canonicalModelId": "MiniMax-M2.5",
              "displayName": "MiniMax-M2.5",
              "capabilities": ["text"]
            }
          }
        },
        "anthropic": {
          "displayName": "Anthropic",
          "defaultModelId": "claude-sonnet-4-5",
          "validationModelId": "claude-sonnet-4-5",
          "resolveMap": { "claude-sonnet-4-5": "claude-sonnet-4-5" },
          "models": {
            "claude-sonnet-4-5": {
              "canonicalModelId": "claude-sonnet-4-5",
              "displayName": "Claude Sonnet 4.5",
              "capabilities": ["text"]
            }
          }
        },
        "gemini": {
          "displayName": "Gemini",
          "defaultModelId": "gemini-2.0-flash",
          "validationModelId": "gemini-2.0-flash",
          "resolveMap": { "gemini-2.0-flash": "gemini-2.0-flash" },
          "models": {
            "gemini-2.0-flash": {
              "canonicalModelId": "gemini-2.0-flash",
              "displayName": "Gemini 2.0 Flash",
              "capabilities": ["text"]
            }
          }
        },
        "grok": {
          "displayName": "Grok",
          "defaultModelId": "grok-4",
          "validationModelId": "grok-4",
          "resolveMap": { "grok-4": "grok-4" },
          "models": {
            "grok-4": {
              "canonicalModelId": "grok-4",
              "displayName": "Grok 4",
              "capabilities": ["text"]
            }
          }
        },
        "deepseek": {
          "displayName": "DeepSeek",
          "defaultModelId": "deepseek-chat",
          "validationModelId": "deepseek-chat",
          "resolveMap": { "deepseek-chat": "deepseek-chat" },
          "models": {
            "deepseek-chat": {
              "canonicalModelId": "deepseek-chat",
              "displayName": "DeepSeek Chat",
              "capabilities": ["text"]
            }
          }
        },
        "fireworksAI": {
          "displayName": "Fireworks AI",
          "defaultModelId": "fireworks-test-model",
          "validationModelId": "fireworks-test-model",
          "resolveMap": { "fireworks-test-model": "fireworks-test-model" },
          "models": {
            "fireworks-test-model": {
              "canonicalModelId": "fireworks-test-model",
              "displayName": "Fireworks Test Model",
              "capabilities": ["text"]
            }
          }
        },
        "groq": {
          "displayName": "Groq",
          "defaultModelId": "llama-3.3-70b",
          "validationModelId": "llama-3.3-70b",
          "resolveMap": { "llama-3.3-70b": "llama-3.3-70b" },
          "models": {
            "llama-3.3-70b": {
              "canonicalModelId": "llama-3.3-70b",
              "displayName": "Llama 3.3 70B",
              "capabilities": ["text"]
            }
          }
        },
        "moonshot": {
          "displayName": "Kimi",
          "defaultModelId": "kimi-k2",
          "validationModelId": "kimi-k2",
          "resolveMap": { "kimi-k2": "kimi-k2" },
          "models": {
            "kimi-k2": {
              "canonicalModelId": "kimi-k2",
              "displayName": "Kimi K2",
              "capabilities": ["text"]
            }
          }
        },
        "mistral": {
          "displayName": "Mistral",
          "defaultModelId": "magistral-medium-latest",
          "validationModelId": "magistral-medium-latest",
          "resolveMap": { "magistral-medium-latest": "magistral-medium-latest" },
          "models": {
            "magistral-medium-latest": {
              "canonicalModelId": "magistral-medium-latest",
              "displayName": "Magistral Medium",
              "capabilities": ["text"]
            }
          }
        },
        "qwen": {
          "displayName": "Qwen",
          "defaultModelId": "qwen3-plus",
          "validationModelId": "qwen3-plus",
          "resolveMap": { "qwen3-plus": "qwen3-plus" },
          "models": {
            "qwen3-plus": {
              "canonicalModelId": "qwen3-plus",
              "displayName": "Qwen3 Plus",
              "capabilities": ["text"]
            }
          }
        },
        "siliconFlow": {
          "displayName": "SiliconFlow",
          "defaultModelId": "Qwen/Qwen3-32B",
          "validationModelId": "Qwen/Qwen3-32B",
          "resolveMap": { "Qwen/Qwen3-32B": "Qwen/Qwen3-32B" },
          "models": {
            "Qwen/Qwen3-32B": {
              "canonicalModelId": "Qwen/Qwen3-32B",
              "displayName": "Qwen3 32B",
              "capabilities": ["text"]
            }
          }
        },
        "zhipu": {
          "displayName": "Z.ai",
          "defaultModelId": "glm-4-plus",
          "validationModelId": "glm-4-plus",
          "resolveMap": { "glm-4-plus": "glm-4-plus" },
          "models": {
            "glm-4-plus": {
              "canonicalModelId": "glm-4-plus",
              "displayName": "GLM-4 Plus",
              "capabilities": ["text"]
            }
          }
        },
        "togetherAI": {
          "displayName": "Together AI",
          "defaultModelId": "meta-llama/Llama-3.3-70B",
          "validationModelId": "meta-llama/Llama-3.3-70B",
          "resolveMap": { "meta-llama/Llama-3.3-70B": "meta-llama/Llama-3.3-70B" },
          "models": {
            "meta-llama/Llama-3.3-70B": {
              "canonicalModelId": "meta-llama/Llama-3.3-70B",
              "displayName": "Llama 3.3 70B",
              "capabilities": ["text"]
            }
          }
        }
      }
    }
    """)
}
