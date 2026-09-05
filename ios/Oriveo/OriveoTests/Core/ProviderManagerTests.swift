import Foundation
import Testing
@testable import Oriveo

final class ProviderManagerSharedURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = ProviderManagerSharedURLProtocol.requestHandler else {
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

private func registerProviderManagerSharedMock() {
    ProviderManagerSharedURLProtocol.requestHandler = nil
}

private func unregisterProviderManagerSharedMock() {
    ProviderManagerSharedURLProtocol.requestHandler = nil
}

private func providerManagerTestSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ProviderManagerSharedURLProtocol.self]
    return URLSession(configuration: configuration)
}

private func providerManagerHTTPResponse(
    url: URL,
    statusCode: Int,
    headers: [String: String]? = nil
) -> HTTPURLResponse {
    HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: nil, headerFields: headers)!
}

private func providerManagerRequestBody(from request: URLRequest) -> Data? {
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

@Suite("ProviderManager", .serialized)
@MainActor
struct ProviderManagerTests {
    private static var retainedStates: [AppState] = []

    private func makeState() -> AppState {
        let sessionUID = "provider-manager-tests-\(UUID().uuidString)"
        let state = AppState(
            seedDemoData: true,
            sessionUID: sessionUID,
            providerSession: providerManagerTestSession()
        )
        state.providers = []
        state.conversations = []
        Self.retainedStates.append(state)
        return state
    }

    private func loadOpenAIMetadata() async throws {
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(json: """
        {
          "version": 1,
          "updatedAt": "2026-04-09T00:00:00Z",
          "providers": {
            "openAI": {
              "displayName": "OpenAI",
              "defaultModelId": "gpt-5.4",
              "resolveMap": {
                "gpt-5.4": "gpt-5.4",
                "gpt-5.4-2026-03-05": "gpt-5.4",
                "gpt-4.1": "gpt-4.1"
              },
              "models": {
                "gpt-5.4": {
                  "canonicalModelId": "gpt-5.4",
                  "displayName": "GPT-5.4",
                  "contextLength": 200000,
                  "pricing": {
                    "promptPerMToken": 2.0,
                    "completionPerMToken": 8.0
                  },
                  "capabilities": ["text", "reasoning"],
                  "profiles": {
                    "reasoning": "openai_reasoning"
                  },
                  "uiHints": {
                    "groupKey": "gpt-5",
                    "groupName": "GPT-5",
                    "rank": 200,
                    "recommended": true,
                    "badgeOrder": ["reasoning"]
                  }
                },
                "gpt-4.1": {
                  "canonicalModelId": "gpt-4.1",
                  "displayName": "GPT-4.1",
                  "contextLength": 128000,
                  "pricing": {
                    "promptPerMToken": 1.0,
                    "completionPerMToken": 4.0
                  },
                  "capabilities": ["text"],
                  "profiles": {},
                  "uiHints": {
                    "groupKey": "gpt-4.1",
                    "groupName": "GPT-4.1",
                    "rank": 150,
                    "recommended": false
                  }
                }
              }
            }
          }
        }
        """)
    }

    private func loadRelayFixtureMetadata() async throws {
        let testFileURL = URL(fileURLWithPath: #filePath)
        let repoRoot = testFileURL
            .deletingLastPathComponent() // Core/
            .deletingLastPathComponent() // OriveoTests/
            .deletingLastPathComponent() // Oriveo/
            .deletingLastPathComponent() // ios/
            .deletingLastPathComponent() // repository root
        let fixtureURL = repoRoot.appendingPathComponent(
            "shared/test-fixtures/relay/metadata-fixture.json"
        )
        let json = try String(contentsOf: fixtureURL, encoding: .utf8)
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(json: json)
    }

    private func loadOpenAICodexSubscriptionMetadata() async throws {
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(json: """
        {
          "version": 1,
          "updatedAt": "2026-08-20T00:00:00Z",
          "providers": {
            "openAI": {
              "displayName": "OpenAI",
              "defaultModelId": "gpt-5.4",
              "resolveMap": { "gpt-5.4": "gpt-5.4" },
              "models": {
                "gpt-5.4": {
                  "canonicalModelId": "gpt-5.4",
                  "displayName": "GPT-5.4",
                  "contextLength": 200000,
                  "pricing": { "promptPerMToken": 2.0, "completionPerMToken": 8.0 },
                  "capabilities": ["text"],
                  "profiles": {},
                  "uiHints": { "groupKey": "gpt-5", "groupName": "GPT-5", "rank": 200 }
                }
              }
            }
          },
          "providerConfigs": [
            {
              "kind": "openAI",
              "displayName": "OpenAI",
              "defaultBaseURL": "https://api.openai.com/v1",
              "protocolFeatures": {
                "authMethod": "bearer",
                "subscriptionAuth": {
                  "enabled": true,
                  "flow": "codex_device_code",
                  "clientId": "app_EMoamEEZ73f0CkXaXp7hrann",
                  "deviceAuthorizationEndpoint": "https://auth.openai.com/deviceauth/usercode",
                  "deviceTokenEndpoint": "https://auth.openai.com/deviceauth/token",
                  "tokenEndpoint": "https://auth.openai.com/oauth/token",
                  "verificationURL": "https://auth.openai.com/codex/device",
                  "redirectURI": "https://auth.openai.com/deviceauth/callback",
                  "trustedAuthHosts": ["auth.openai.com"],
                  "trustedVerificationHosts": ["auth.openai.com"],
                  "resourceBaseURL": "https://chatgpt.com/backend-api/codex",
                  "requiredHeaders": {
                    "originator": "oriveo",
                    "version": "0.148.0",
                    "OpenAI-Beta": "responses=experimental"
                  },
                  "chatPath": "/responses",
                  "modelsPath": "/models",
                  "pollIntervalSeconds": 5,
                  "pollTimeoutSeconds": 900
                }
              }
            }
          ]
        }
        """)
    }

    @Test("Register Open AISubscription Uses Caller Supplied Account ID")
    func registerOpenAISubscriptionUsesCallerSuppliedAccountID() async throws {
        try await loadOpenAICodexSubscriptionMetadata()
        registerProviderManagerSharedMock()
        defer {
            ProviderManagerSharedURLProtocol.requestHandler = nil
            unregisterProviderManagerSharedMock()
        }

        nonisolated(unsafe) var modelsRequests: [URLRequest] = []
        ProviderManagerSharedURLProtocol.requestHandler = { request in
            let url = try #require(request.url)
            if url.path == "/local-snapshot" {
                return (providerManagerHTTPResponse(url: url, statusCode: 304), Data())
            }
            if url.host == "chatgpt.com", url.path == "/backend-api/codex/models" {
                modelsRequests.append(request)
                return (providerManagerHTTPResponse(url: url, statusCode: 200), Data("""
                {"models":[
                  {"slug":"gpt-5.6-sol","visibility":"list","supported_in_api":true},
                  {"slug":"gpt-5.6-terra","visibility":"list","supported_in_api":true},
                  {"slug":"codex-auto-review","visibility":"hidden","supported_in_api":true},
                  {"slug":"gpt-5.3-codex-spark","visibility":"list","supported_in_api":false}
                ]}
                """.utf8))
            }
            Issue.record("Unexpected request: \(url.absoluteString)")
            return (providerManagerHTTPResponse(url: url, statusCode: 500), Data())
        }

        let state = makeState()
        let provider = try await state.providerManager.registerProvider(
            kind: .openAI,
            apiKey: "codex-access-token-that-is-not-a-jwt",
            authMode: .subscription,
            subscriptionAccountID: "acct-from-token-exchange"
        )

        #expect(modelsRequests.count == 1)
        let modelsRequest = try #require(modelsRequests.first)
        #expect(modelsRequest.value(forHTTPHeaderField: "chatgpt-account-id") == "acct-from-token-exchange")
        #expect(modelsRequest.url?.query?.contains("client_version=0.148.0") == true)
        #expect(modelsRequest.value(forHTTPHeaderField: "originator") == "oriveo")

        #expect(provider.lastError == nil)
        #expect(provider.models.map(\.id) == ["gpt-5.6-sol", "gpt-5.6-terra"])
        #expect(provider.defaultModel?.id == "gpt-5.6-sol")
    }

    @Test("Subscription Catalog Never Falls Back To Official Metadata")
    func subscriptionCatalogNeverFallsBackToOfficialMetadata() async throws {
        try await loadOpenAIMetadata()

        var subscription = TestFactories.makeProvider(
            id: UUID(),
            kind: .openAI,
            status: .connected,
            models: [],
            catalogModels: [TestFactories.makeModel(id: "gpt-5.6-sol", isDefault: true)],
            apiKey: "codex-access-token"
        )
        subscription.authMode = .subscription

        let resolved = ProviderCatalogResolver.resolve(provider: subscription)
        let ids = resolved.catalog.map(\.model.id)
        #expect(ids == ["gpt-5.6-sol"])
        #expect(!ids.contains("gpt-4.1"))
        #expect(!ids.contains("gpt-5.4"))

        let byok = TestFactories.makeProvider(
            id: UUID(), kind: .openAI, status: .connected,
            models: [], catalogModels: [], apiKey: "sk-byok"
        )
        let byokIDs = ProviderCatalogResolver.resolve(provider: byok).catalog.map(\.model.id)
        #expect(byokIDs.contains("gpt-5.4"))
    }

    @Test("Open AISubscription Catalog Failure Keeps Specific Reason")
    func openAISubscriptionCatalogFailureKeepsSpecificReason() async throws {
        try await loadOpenAICodexSubscriptionMetadata()
        registerProviderManagerSharedMock()
        defer {
            ProviderManagerSharedURLProtocol.requestHandler = nil
            unregisterProviderManagerSharedMock()
        }

        ProviderManagerSharedURLProtocol.requestHandler = { request in
            let url = try #require(request.url)
            if url.path == "/local-snapshot" {
                return (providerManagerHTTPResponse(url: url, statusCode: 304), Data())
            }
            if url.host == "chatgpt.com", url.path == "/backend-api/codex/models" {
                return (providerManagerHTTPResponse(url: url, statusCode: 403), Data(#"{"error":"usage_not_included"}"#.utf8))
            }
            Issue.record("Unexpected request: \(url.absoluteString)")
            return (providerManagerHTTPResponse(url: url, statusCode: 500), Data())
        }

        let state = makeState()
        let provider = try await state.providerManager.registerProvider(
            kind: .openAI,
            apiKey: "codex-access-token-that-is-not-a-jwt",
            authMode: .subscription,
            subscriptionAccountID: "acct-from-token-exchange"
        )

        #expect(provider.models.isEmpty)
        #expect(provider.lastError == OpenAISubscriptionError.subscriptionNotEligible.userFacingMessage)
        #expect(provider.lastError != OpenAISubscriptionError.quotaExhausted.userFacingMessage)
        #expect(provider.lastError != ProviderIssueMessage.catalogUnavailableKey)
    }

    @Test("Save Manual Model Persists Image Gen Capability")
    func saveManualModelPersistsImageGenCapability() async throws {
        let state = makeState()

        _ = state.providerManager.registerRelay(
            name: "ysl",
            endpoint: "https://ysl.example.com/v1",
            apiKey: "sk-test",
            relayRequested: RelayRequestedConfig(
                transport: .openaiResponses,
                authMode: .bearer
            )
        )
        let providerID = try #require(state.providers.first(where: { $0.kind == .relay })?.id)

        let didSave = state.saveManualModel(
            providerID: providerID,
            modelID: "gpt-image-2",
            context: .providerDetail,
            capabilities: [.imageGen]
        )

        #expect(didSave == true)
        let provider = try #require(state.provider(for: providerID))
        let manualModel = try #require(provider.allModels.first(where: { $0.id.hasSuffix("gpt-image-2") }))
        #expect(manualModel.capabilities.contains(.imageGen))
        #expect(manualModel.capabilities.contains(.text))
        #expect(manualModel.imageGenProfile == "default")
    }

    @Test("Save Manual Model Defaults To Text Only")
    func saveManualModelDefaultsToTextOnly() async throws {
        let state = makeState()

        _ = state.providerManager.registerRelay(
            name: "ysl",
            endpoint: "https://ysl.example.com/v1",
            apiKey: "sk-test",
            relayRequested: RelayRequestedConfig(transport: .openaiResponses)
        )
        let providerID = try #require(state.providers.first(where: { $0.kind == .relay })?.id)

        let didSave = state.saveManualModel(
            providerID: providerID,
            modelID: "claude-4-sonnet",
            context: .providerDetail
        )

        #expect(didSave == true)
        let provider = try #require(state.provider(for: providerID))
        let manualModel = try #require(provider.allModels.first(where: { $0.id.hasSuffix("claude-4-sonnet") }))
        let caps = Set(manualModel.capabilities)
        #expect(caps == [.text])
        #expect(!caps.contains(.imageGen))
        #expect(manualModel.imageGenProfile == nil)
        #expect(manualModel.reasoningModeAvailable == false)
    }

    @Test("Save Manual Model On Anthropic Transport Omits Image Gen")
    func saveManualModelOnAnthropicTransportOmitsImageGen() async throws {
        let state = makeState()

        _ = state.providerManager.registerRelay(
            name: "packy-claude",
            endpoint: "https://www.packyapi.com",
            apiKey: "sk-test",
            relayRequested: RelayRequestedConfig(transport: .anthropicMessages)
        )
        let providerID = try #require(state.providers.first(where: { $0.kind == .relay })?.id)

        let didSave = state.saveManualModel(
            providerID: providerID,
            modelID: "claude-opus-4-6",
            context: .providerDetail
        )

        #expect(didSave == true)
        let provider = try #require(state.provider(for: providerID))
        let manualModel = try #require(provider.allModels.first(where: { $0.id.hasSuffix("claude-opus-4-6") }))
        #expect(!manualModel.capabilities.contains(.imageGen))
        #expect(manualModel.imageGenProfile == nil)
    }

    @Test("Relay Service Reuses Open AIService")
    func relayServiceReusesOpenAIService() {
        let appState = makeState()
        let manager = appState.providerManager

        let relayService = manager.service(for: .relay)
        let openAIService = manager.service(for: .openAI)

        #expect((relayService as AnyObject?) === (openAIService as AnyObject?))
    }

    @Test("Relay Responses Stream Uses Explicit Transport And Dedupes By Item ID")
    func relayResponsesStreamUsesExplicitTransportAndDedupesByItemID() async throws {
        registerProviderManagerSharedMock()
        defer {
            ProviderManagerSharedURLProtocol.requestHandler = nil
            unregisterProviderManagerSharedMock()
        }

        var capturedRequest: URLRequest?
        ProviderManagerSharedURLProtocol.requestHandler = { request in
            let url = try #require(request.url)
            capturedRequest = request
            #expect(url.host == "relay.example.com")
            return (
                providerManagerHTTPResponse(url: url, statusCode: 200, headers: [
                    "Content-Type": "text/event-stream"
                ]),
                Data(
                    """
                    event: response.output_text.delta
                    data: {"delta":"hello"}

                    event: response.output_item.done
                    data: {"item":{"id":"img-1","type":"image_generation_call","result":"AAAA"}}

                    event: response.output_image.done
                    data: {"item_id":"img-1","result":"BBBB"}

                    event: response.completed
                    data: {"response":{"usage":{"input_tokens":9,"output_tokens":4}}}
                    """.utf8
                )
            )
        }

        let service = OpenAIService(session: providerManagerTestSession())
        var events: [StreamEvent] = []
        let requestOptions = ChatRequestOptions(systemPrompt: "")
        let messages = [ChatMessage(
            id: UUID(),
            role: .user,
            text: "Generate a cat",
            providerID: UUID(),
            providerKind: .relay,
            providerName: "Relay",
            modelID: "gpt-5.4",
            modelName: "gpt-5.4",
            state: .delivered
        )]

        for try await event in service.sendMessageStream(
            apiKey: "sk-relay",
            modelID: "gpt-5.4",
            messages: messages,
            baseURL: "https://relay.example.com/v1",
            reasoningMode: .automatic,
            requestOptions: requestOptions,
            relayRequested: RelayRequestedConfig(
                transport: .openaiResponses,
                authMode: .bearer,
                modelID: "gpt-5.4",
                reasoningEffort: .xhigh,
                serviceTier: "fast",
                stream: true,
                disableResponseStorage: true
            )
        ) {
            events.append(event)
        }

        let request = try #require(capturedRequest)
        let body = try #require(providerManagerRequestBody(from: request))
        let payload = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])

        #expect(request.url?.path == "/v1/responses")
        #expect((payload["service_tier"] as? String) == "fast")
        let tools = try #require(payload["tools"] as? [[String: Any]])
        #expect(tools.count == 1)
        #expect(tools.first?["type"] as? String == "image_generation")
        #expect(tools.first?["model"] == nil)

        let imageEvents = events.compactMap { event -> Oriveo.Attachment? in
            if case .imagePart(let attachment) = event { return attachment }
            return nil
        }
        #expect(imageEvents.count == 1)
        #expect(imageEvents.first?.base64Data == "AAAA")
    }

    @Test("Register Relay Persists Provider")
    func registerRelayPersistsProvider() {
        let appState = makeState()
        appState.providers = []

        let created = appState.providerManager.registerRelay(
            name: "My Relay",
            endpoint: "https://relay.example.com/v1",
            apiKey: "sk-relay-secret"
        )

        #expect(appState.providers.count == 1)
        let provider = try! #require(appState.providers.first)
        #expect(provider.id == created.id)
        #expect(provider.kind == .relay)
        #expect(provider.status == .connected)
        #expect(provider.customName == "My Relay")
        #expect(provider.baseURLText == "https://relay.example.com/v1")
        #expect(provider.apiKey == "sk-relay-secret")
    }

    @Test("Register Relay Uses Endpoint Domain Default Name")
    func registerRelayUsesEndpointDomainDefaultName() {
        let appState = makeState()
        appState.providers = []

        let first = appState.providerManager.registerRelay(
            name: "",
            endpoint: "https://aa.bb.cc/v1",
            apiKey: "sk-1"
        )
        let second = appState.providerManager.registerRelay(
            name: "  ",
            endpoint: "https://aa.bb.cc/v1",
            apiKey: "sk-2"
        )

        #expect(first.customName == "bb.cc")
        #expect(second.customName == "bb.cc 2")
    }

    @Test("Register Relay Persists Discovered Catalog")
    func registerRelayPersistsDiscoveredCatalog() throws {
        let appState = makeState()
        appState.providers = []

        let provider = appState.providerManager.registerRelay(
            name: "",
            endpoint: "https://relay.example.com",
            apiKey: "sk-test",
            relayRequested: RelayRequestedConfig(
                transport: .openaiResponses,
                authMode: .bearer,
                resolvedAPIBaseURL: "https://relay.example.com/v1"
            ),
            catalogModelIDs: ["gpt-a", "gpt-b", "gpt-a"],
            preferredModelID: "gpt-b"
        )

        #expect(provider.catalogModels.map(\.id) == ["gpt-a", "gpt-b"])
        #expect(provider.models.map(\.id) == ["gpt-b"])
        #expect(provider.defaultModel?.id == "gpt-b")
        #expect(provider.models.allSatisfy { $0.capabilities == [.text] })
    }

    @Test("Discovered Catalog Feeds The Model Library")
    func discoveredCatalogFeedsTheModelLibrary() throws {
        let appState = makeState()
        appState.providers = []
        let discovered = [
            "codex-auto-review", "gpt-5.3-codex-spark", "gpt-5.4", "gpt-5.4-mini",
            "gpt-5.4-openai-compact", "gpt-5.5", "gpt-5.5-openai-compact",
            "gpt-5.6-luna", "gpt-5.6-sol", "gpt-5.6-terra",
        ]

        var provider = appState.providerManager.registerRelay(
            name: "",
            endpoint: "https://www.micuapi.ai",
            apiKey: "sk-test",
            relayRequested: RelayRequestedConfig(transport: .openaiChatCompletions),
            catalogModelIDs: discovered,
            preferredModelID: "gpt-5.6-sol"
        )
        provider.relayKind = .openaiCompatible
        appState.providerManager.updateProvider(provider)

        let saved = try #require(appState.provider(for: provider.id))
        #expect(saved.catalogModels.map(\.id) == discovered)
        #expect(saved.models.map(\.id) == ["gpt-5.6-sol"])

        let libraryIDs = buildProviderCatalogGroups(for: saved, searchText: "")
            .flatMap { $0.models.map(\.id) }
            .sorted()
        #expect(libraryIDs == discovered.filter { $0 != "gpt-5.6-sol" }.sorted())
    }

    @Test("Relay Can Enable AModel From Its Catalog")
    func relayCanEnableAModelFromItsCatalog() throws {
        let appState = makeState()
        appState.providers = []
        let discovered = ["codex-auto-review", "gpt-5.4", "gpt-5.6-sol"]

        var provider = appState.providerManager.registerRelay(
            name: "",
            endpoint: "https://www.micuapi.ai",
            apiKey: "sk-test",
            relayRequested: RelayRequestedConfig(transport: .openaiChatCompletions),
            catalogModelIDs: discovered,
            preferredModelID: "gpt-5.6-sol"
        )
        provider.relayKind = .openaiCompatible
        appState.providerManager.updateProvider(provider)

        appState.enableModel(modelID: "gpt-5.4", for: provider.id)

        let updated = try #require(appState.provider(for: provider.id))
        #expect(updated.models.map(\.id).sorted() == ["gpt-5.4", "gpt-5.6-sol"])
        let libraryIDs = buildProviderCatalogGroups(for: updated, searchText: "")
            .flatMap { $0.models.map(\.id) }
        #expect(libraryIDs == ["codex-auto-review"])
    }

    @Test("Relay Duplicate Catalog IDs Do Not Trap During Enrichment")
    func relayDuplicateCatalogIDsDoNotTrapDuringEnrichment() throws {
        let appState = makeState()
        var provider = appState.providerManager.registerRelay(
            name: "Duplicate Relay",
            endpoint: "https://relay.example.com/v1",
            apiKey: "sk-test",
            relayRequested: RelayRequestedConfig(transport: .openaiChatCompletions),
            catalogModelIDs: ["duplicate-model"]
        )

        var first = try #require(provider.catalogModels.first)
        first.capabilities = [.text, .reasoning]
        var duplicate = first
        duplicate.capabilities = [.text, .image]
        provider.catalogModels = [first, duplicate]
        provider.models = [first]

        appState.providerManager.updateProvider(provider)

        let updated = try #require(appState.provider(for: provider.id))
        #expect(updated.models.first?.capabilities == [.text, .reasoning])
    }

    @Test("Register Relay Can Persist Unverified Issue State")
    func registerRelayCanPersistUnverifiedIssueState() {
        let appState = makeState()
        appState.providers = []

        let provider = appState.providerManager.registerRelay(
            name: "Relay",
            endpoint: "https://relay.example.com",
            apiKey: "sk-test",
            connectionState: .issue("probe failed")
        )

        #expect(provider.status == .issue("probe failed"))
        #expect(provider.lastError == "probe failed")
    }

    @Test("Register Relay Keeps Multiple Instances Independent")
    func registerRelayKeepsMultipleInstancesIndependent() {
        let appState = makeState()
        appState.providers = []

        let a = appState.providerManager.registerRelay(
            name: "Relay A",
            endpoint: "https://relay-a.example.com/v1",
            apiKey: "sk-a"
        )
        let b = appState.providerManager.registerRelay(
            name: "Relay B",
            endpoint: "https://relay-b.example.com/v1",
            apiKey: "sk-b"
        )

        #expect(a.id != b.id)
        let relays = appState.providers.filter { $0.kind == .relay }
        #expect(relays.count == 2)
        #expect(Set(relays.compactMap(\.customName)) == ["Relay A", "Relay B"])
        #expect(Set(relays.compactMap(\.baseURLText)) == [
            "https://relay-a.example.com/v1",
            "https://relay-b.example.com/v1",
        ])
        #expect(Set(relays.map(\.apiKey)) == ["sk-a", "sk-b"])
    }

    @Test("Register Provider Relay Does Not Reuse Existing")
    func registerProviderRelayDoesNotReuseExisting() async throws {
        await MetadataClient.shared.resetForTesting()
        registerProviderManagerSharedMock()
        defer {
            ProviderManagerSharedURLProtocol.requestHandler = nil
            unregisterProviderManagerSharedMock()
        }

        ProviderManagerSharedURLProtocol.requestHandler = { request in
            let url = try #require(request.url)
            if url.path == "/v1/models" {
                return (
                    providerManagerHTTPResponse(url: url, statusCode: 200),
                    Data(#"{"data":[{"id":"m1"}]}"#.utf8)
                )
            }
            if url.path.hasSuffix("/models") || url.path.hasSuffix("/key") {
                return (providerManagerHTTPResponse(url: url, statusCode: 200), Data(#"{"data":[]}"#.utf8))
            }
            Issue.record("Unexpected request: \(url.absoluteString)")
            return (providerManagerHTTPResponse(url: url, statusCode: 500), Data())
        }

        let state = makeState()
        let first = try await state.providerManager.registerProvider(
            kind: .relay,
            apiKey: "sk-1",
            baseURLText: "https://r1.example.com/v1",
            customName: "R1"
        )
        let second = try await state.providerManager.registerProvider(
            kind: .relay,
            apiKey: "sk-2",
            baseURLText: "https://r2.example.com/v1",
            customName: "R2"
        )

        #expect(first.id != second.id)
        #expect(state.providers.filter { $0.kind == .relay }.count == 2)
    }

    @Test("Register Provider Relay Preserves Custom Name")
    func registerProviderRelayPreservesCustomName() async throws {
        await MetadataClient.shared.resetForTesting()
        registerProviderManagerSharedMock()
        defer {
            ProviderManagerSharedURLProtocol.requestHandler = nil
            unregisterProviderManagerSharedMock()
        }

        ProviderManagerSharedURLProtocol.requestHandler = { request in
            let url = try #require(request.url)

            if url.host == "relay.example.com", url.path == "/v1/models" {
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-relay-live")
                return (
                    providerManagerHTTPResponse(url: url, statusCode: 200),
                    Data(#"{"data":[{"id":"gpt-4.1","created":1710000000}]}"#.utf8)
                )
            }

            if url.path.hasSuffix("/models") || url.path.hasSuffix("/key") {
                return (providerManagerHTTPResponse(url: url, statusCode: 200), Data(#"{"data":[]}"#.utf8))
            }
            Issue.record("Unexpected request during relay register: \(url.absoluteString)")
            return (providerManagerHTTPResponse(url: url, statusCode: 500), Data())
        }

        let state = makeState()
        let provider = try await state.providerManager.registerProvider(
            kind: .relay,
            apiKey: "sk-relay-live",
            baseURLText: "https://relay.example.com/v1",
            customName: "My Relay"
        )

        #expect(provider.customName == "My Relay")
        #expect(provider.baseURLText == "https://relay.example.com/v1")
        #expect(provider.catalogModels.contains(where: { $0.id == "gpt-4.1" }))
        #expect(state.providers.first?.customName == "My Relay")
    }

    @Test("Update Provider Name Deduplicates By ID")
    func updateProviderNameDeduplicatesByID() {
        let appState = makeState()
        appState.providers = []

        let first = appState.providerManager.registerRelay(
            name: "bb.cc",
            endpoint: "https://aa.bb.cc/v1",
            apiKey: "sk-1"
        )
        let second = appState.providerManager.registerRelay(
            name: "other",
            endpoint: "https://other.example.com/v1",
            apiKey: "sk-2"
        )

        appState.providerManager.updateProviderName(providerID: second.id, newName: " bb.cc ")
        appState.providerManager.updateProviderName(providerID: first.id, newName: "BB.CC")

        let renamedSecond = try! #require(appState.providerManager.provider(for: second.id))
        let renamedFirst = try! #require(appState.providerManager.provider(for: first.id))
        #expect(renamedSecond.customName == "bb.cc 2")
        #expect(renamedFirst.customName == "BB.CC")
    }

    @Test("Enable Model Adds Catalog Model")
    func enableModelAddsCatalogModel() {
        let appState = makeState()
        let providerID = UUID()
        let defaultModel = TestFactories.makeModel(
            id: "openAI-gpt-4o",
            name: "GPT-4o",
            isDefault: true
        )
        let catalogModel = TestFactories.makeModel(
            id: "openAI-gpt-4.1",
            name: "GPT-4.1",
            isDefault: false
        )
        appState.providers = [
            TestFactories.makeProvider(
                id: providerID,
                kind: .openAI,
                models: [defaultModel],
                catalogModels: [defaultModel, catalogModel]
            ),
        ]

        appState.providerManager.enableModel(modelID: "openAI-gpt-4.1", for: providerID)

        let provider = try! #require(appState.providers.first(where: { $0.id == providerID }))
        #expect(provider.models.count == 2)
        #expect(provider.models.contains(where: { $0.id == "openAI-gpt-4.1" }))
        #expect(provider.models.first(where: { $0.id == "openAI-gpt-4o" })?.isDefault == true)
    }

    @Test("Ensure Model Enabled As Default Promotes Relay Catalog Model")
    func ensureModelEnabledAsDefaultPromotesRelayCatalogModel() {
        let appState = makeState()
        let providerID = UUID()
        let catalogDefault = TestFactories.makeModel(id: "gpt-5.4", name: "gpt-5.4", isDefault: true)
        let requestedModel = TestFactories.makeModel(id: "gpt-5.5", name: "gpt-5.5", isDefault: false)
        appState.providers = [
            TestFactories.makeProvider(
                id: providerID,
                kind: .relay,
                models: [catalogDefault],
                catalogModels: [catalogDefault, requestedModel]
            ),
        ]

        let didApply = appState.providerManager.ensureModelEnabledAsDefault(
            providerID: providerID,
            modelID: "gpt-5.5"
        )

        #expect(didApply == true)
        let provider = try! #require(appState.providers.first(where: { $0.id == providerID }))
        #expect(provider.models.map(\.id).contains("gpt-5.5"))
        #expect(provider.defaultModel?.id == "gpt-5.5")
    }

    @Test("Relay Manual Official Model Writes Back Pricing")
    func relayManualOfficialModelWritesBackPricing() async throws {
        try await loadRelayFixtureMetadata()

        let appState = makeState()
        let providerID = UUID()
        let manualModel = TestFactories.makeModel(
            id: "relay-manual-gpt-5.4",
            name: "gpt-5.4 (manual)",
            capabilities: [.text, .image],
            isDefault: true,
            priceTier: ""
        )
        let provider = Provider(
            id: providerID,
            kind: .relay,
            status: .connected,
            models: [manualModel],
            catalogModels: [manualModel],
            apiKey: "sk-test",
            apiKeyPreview: "sk-...test",
            relayRequested: RelayRequestedConfig(transport: .openaiResponses)
        )
        appState.providers = [provider]

        appState.providerManager.updateProvider(provider)

        let updatedProvider = try #require(appState.providers.first(where: { $0.id == providerID }))
        let updatedModel = try #require(updatedProvider.models.first)
        #expect(updatedModel.name == "gpt-5.4 (manual)")
        #expect(updatedModel.capabilities == [.text, .image])
        #expect(updatedModel.canonicalModelId == "gpt-5.4")
        #expect(updatedModel.promptPrice == 0.000002)
        #expect(updatedModel.completionPrice == 0.000008)
        #expect(!updatedModel.priceTier.isEmpty)
    }

    @Test("Enable Model Adds Metadata Backed Official Model")
    func enableModelAddsMetadataBackedOfficialModel() async throws {
        try await loadOpenAIMetadata()
        let appState = makeState()
        let providerID = UUID()
        let defaultModel = TestFactories.makeModel(
            id: "gpt-5.4",
            name: "GPT-5.4",
            isDefault: true,
            canonicalModelId: "gpt-5.4"
        )
        appState.providers = [
            TestFactories.makeProvider(
                id: providerID,
                kind: .openAI,
                models: [defaultModel],
                catalogModels: []
            ),
        ]

        appState.providerManager.enableModel(modelID: "gpt-4.1", for: providerID)

        let provider = try #require(appState.providers.first(where: { $0.id == providerID }))
        #expect(provider.models.map(\.id) == ["gpt-5.4", "gpt-4.1"])
        #expect(provider.models.first(where: { $0.id == "gpt-5.4" })?.isDefault == true)
        #expect(provider.models.first(where: { $0.id == "gpt-4.1" })?.name == "GPT-4.1")
    }

    @Test("Disable Model Removes Target")
    func disableModelRemovesTarget() {
        let appState = makeState()
        let providerID = UUID()
        let m1 = TestFactories.makeModel(id: "openAI-gpt-4o", name: "GPT-4o", isDefault: true)
        let m2 = TestFactories.makeModel(id: "openAI-gpt-4.1", name: "GPT-4.1", isDefault: false)
        appState.providers = [
            TestFactories.makeProvider(
                id: providerID,
                kind: .openAI,
                models: [m1, m2],
                catalogModels: [m1, m2]
            ),
        ]

        appState.providerManager.disableModel(modelID: "openAI-gpt-4.1", for: providerID)

        let provider = try! #require(appState.providers.first(where: { $0.id == providerID }))
        #expect(provider.models.count == 1)
        #expect(provider.models[0].id == "openAI-gpt-4o")
        #expect(provider.models[0].isDefault == true)
    }

    @Test("Resync Provider Official Branch Aligns Metadata")
    func resyncProviderOfficialBranchAlignsMetadata() async throws {
        try await loadOpenAIMetadata()
        registerProviderManagerSharedMock()
        defer {
            ProviderManagerSharedURLProtocol.requestHandler = nil
            unregisterProviderManagerSharedMock()
        }

        ProviderManagerSharedURLProtocol.requestHandler = { request in
            let url = try #require(request.url)

            if url.path == "/local-snapshot" {
                return (providerManagerHTTPResponse(url: url, statusCode: 304), Data())
            }

            if url.path.hasSuffix("/models") || url.path.hasSuffix("/key") {
                return (providerManagerHTTPResponse(url: url, statusCode: 200), Data(#"{"data":[]}"#.utf8))
            }
            Issue.record("Unexpected request during official resync: \(url.absoluteString)")
            return (providerManagerHTTPResponse(url: url, statusCode: 500), Data())
        }

        let state = makeState()
        let providerID = UUID()
        let staleSnapshot = TestFactories.makeModel(
            id: "gpt-5.4-2026-03-05",
            name: "Old Snapshot",
            capabilities: [.text],
            reasoningModeAvailable: false,
            isDefault: true
        )
        state.providers = [
            TestFactories.makeProvider(
                id: providerID,
                kind: .openAI,
                status: .issue("stale"),
                models: [staleSnapshot],
                catalogModels: [staleSnapshot],
                lastCheckedAt: Date(timeIntervalSince1970: 1),
                apiKey: "sk-openai-updated",
                lastError: "stale"
            ),
        ]

        try await state.resyncProvider(providerID: providerID)

        let provider = try #require(state.providers.first(where: { $0.id == providerID }))
        let model = try #require(provider.models.first)
        #expect(provider.status == .connected)
        #expect(provider.lastError == nil)
        #expect(provider.catalogModels.isEmpty)
        #expect(provider.models.count == 1)
        #expect(model.name == "GPT-5.4")
        #expect(model.canonicalModelId == "gpt-5.4")
        #expect(model.reasoningModeAvailable)
    }

    @Test("Resync Provider Repairs Legacy Full Catalog Enabled State")
    func resyncProviderRepairsLegacyFullCatalogEnabledState() async throws {
        try await loadOpenAIMetadata()
        registerProviderManagerSharedMock()
        defer {
            ProviderManagerSharedURLProtocol.requestHandler = nil
            unregisterProviderManagerSharedMock()
        }

        ProviderManagerSharedURLProtocol.requestHandler = { request in
            let url = try #require(request.url)

            if url.path == "/local-snapshot" {
                return (providerManagerHTTPResponse(url: url, statusCode: 304), Data())
            }

            if url.path.hasSuffix("/models") || url.path.hasSuffix("/key") {
                return (providerManagerHTTPResponse(url: url, statusCode: 200), Data(#"{"data":[]}"#.utf8))
            }
            Issue.record("Unexpected request during legacy full-catalog repair: \(url.absoluteString)")
            return (providerManagerHTTPResponse(url: url, statusCode: 500), Data())
        }

        let state = makeState()
        let providerID = UUID()
        let gpt54 = TestFactories.makeModel(id: "gpt-5.4", name: "GPT-5.4", capabilities: [.text, .reasoning], reasoningModeAvailable: true, isDefault: true)
        let gpt41 = TestFactories.makeModel(id: "gpt-4.1", name: "GPT-4.1", capabilities: [.text], reasoningModeAvailable: false, isDefault: false)
        state.providers = [
            TestFactories.makeProvider(
                id: providerID,
                kind: .openAI,
                status: .connected,
                models: [gpt54, gpt41],
                catalogModels: [gpt54, gpt41],
                lastCheckedAt: Date(timeIntervalSince1970: 1),
                apiKey: "sk-openai-updated"
            ),
        ]

        try await state.resyncProvider(providerID: providerID)

        let provider = try #require(state.providers.first(where: { $0.id == providerID }))
        #expect(provider.models.map(\.id) == ["gpt-5.4"])
        #expect(provider.defaultModel?.id == "gpt-5.4")
    }

    @Test
    func refreshProviderMetadataRepairsLegacyFullCatalogEnabledStateOnAppReentry() async throws {
        try await loadOpenAIMetadata()

        let state = makeState()
        let providerID = UUID()
        let gpt54 = TestFactories.makeModel(id: "gpt-5.4", name: "GPT-5.4", capabilities: [.text, .reasoning], reasoningModeAvailable: true, isDefault: true)
        let gpt41 = TestFactories.makeModel(id: "gpt-4.1", name: "GPT-4.1", capabilities: [.text], reasoningModeAvailable: false, isDefault: false)
        state.providers = [
            TestFactories.makeProvider(
                id: providerID,
                kind: .openAI,
                status: .connected,
                models: [gpt54, gpt41],
                catalogModels: [gpt54, gpt41],
                lastCheckedAt: Date(timeIntervalSince1970: 1),
                apiKey: "sk-openai-updated"
            ),
        ]

        await state.refreshProviderMetadata()

        let provider = try #require(state.providers.first(where: { $0.id == providerID }))
        #expect(provider.models.map(\.id) == ["gpt-5.4"])
        #expect(provider.catalogModels.isEmpty)
        #expect(provider.defaultModel?.id == "gpt-5.4")
    }

    @Test("Resync Provider Relay Branch Preserves Manual Models")
    func resyncProviderRelayBranchPreservesManualModels() async throws {
        await MetadataClient.shared.resetForTesting()
        registerProviderManagerSharedMock()
        defer {
            ProviderManagerSharedURLProtocol.requestHandler = nil
            unregisterProviderManagerSharedMock()
        }

        var requestedURL: URL?
        ProviderManagerSharedURLProtocol.requestHandler = { request in
            let url = try #require(request.url)

            if url.path == "/local-snapshot" {
                return (providerManagerHTTPResponse(url: url, statusCode: 200), Data(#"{"version":1,"providers":{}}"#.utf8))
            }

            if url.host == "relay.example.com", url.path == "/v1/models" {
                requestedURL = url
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-relay-live")
                return (
                    providerManagerHTTPResponse(url: url, statusCode: 200),
                    Data(#"{"data":[{"id":"gpt-4.1","created":1710000000}]}"#.utf8)
                )
            }

            if url.path.hasSuffix("/models") || url.path.hasSuffix("/key") {
                return (providerManagerHTTPResponse(url: url, statusCode: 200), Data(#"{"data":[]}"#.utf8))
            }
            Issue.record("Unexpected request during relay resync: \(url.absoluteString)")
            return (providerManagerHTTPResponse(url: url, statusCode: 500), Data())
        }

        let state = makeState()
        let providerID = UUID()
        let manualModel = TestFactories.makeModel(
            id: "relay-manual-custom-model",
            name: "custom-model",
            isDefault: true
        )
        state.providers = [
            TestFactories.makeProvider(
                id: providerID,
                kind: .relay,
                models: [manualModel],
                catalogModels: [manualModel],
                lastCheckedAt: Date(timeIntervalSince1970: 1),
                apiKey: "sk-relay-live",
                baseURLText: "https://relay.example.com/v1"
            ),
        ]

        try await state.resyncProvider(providerID: providerID)

        let provider = try #require(state.providers.first(where: { $0.id == providerID }))
        #expect(requestedURL?.absoluteString == "https://relay.example.com/v1/models")
        #expect(provider.status == .connected)
        #expect(provider.catalogModels.contains(where: { $0.id == "relay-manual-custom-model" }))
        #expect(provider.catalogModels.contains(where: { $0.id == "gpt-4.1" }))
        #expect(provider.models.count == 1)
        #expect(provider.models.first?.id == "relay-manual-custom-model")
        #expect(provider.models.first?.isDefault == true)
    }

    @Test("Resync Provider Official Skips Upstream Rate Limit")
    func resyncProviderOfficialSkipsUpstreamRateLimit() async {
        do {
            try await loadOpenAIMetadata()
        } catch {
            Issue.record("Failed to load metadata fixture: \(error)")
            return
        }

        registerProviderManagerSharedMock()
        defer {
            ProviderManagerSharedURLProtocol.requestHandler = nil
            unregisterProviderManagerSharedMock()
        }

        ProviderManagerSharedURLProtocol.requestHandler = { request in
            let url = try #require(request.url)

            if url.path == "/local-snapshot" {
                return (providerManagerHTTPResponse(url: url, statusCode: 304), Data())
            }

            if url.path.hasSuffix("/models") {
                return (
                    providerManagerHTTPResponse(url: url, statusCode: 429),
                    Data(#"{"error":{"message":"rate limited"}}"#.utf8)
                )
            }

            Issue.record("Unexpected request during rate-limit resync: \(url.absoluteString)")
            return (providerManagerHTTPResponse(url: url, statusCode: 500), Data())
        }

        let state = makeState()
        let providerID = UUID()
        state.providers = [
            TestFactories.makeProvider(
                id: providerID,
                kind: .openAI,
                status: .connected,
                models: [TestFactories.makeModel(id: "gpt-5.4", isDefault: true)],
                catalogModels: [],
                lastCheckedAt: Date(timeIntervalSince1970: 1),
                apiKey: "sk-openai-live"
            ),
        ]

        try? await state.resyncProvider(providerID: providerID)

        let provider = try? #require(state.providers.first(where: { $0.id == providerID }))
        #expect(provider?.status == .connected)
        #expect(provider?.lastError == "We couldn't verify the connection. You can retry from the provider details.")
    }

    @Test("Update APIKey Triggers Resync")
    func updateAPIKeyTriggersResync() async throws {
        try await loadOpenAIMetadata()
        registerProviderManagerSharedMock()
        defer {
            ProviderManagerSharedURLProtocol.requestHandler = nil
            unregisterProviderManagerSharedMock()
        }

        ProviderManagerSharedURLProtocol.requestHandler = { request in
            let url = try #require(request.url)

            if url.path == "/local-snapshot" {
                return (providerManagerHTTPResponse(url: url, statusCode: 304), Data())
            }

            if url.path.hasSuffix("/models") {
                return (providerManagerHTTPResponse(url: url, statusCode: 200), Data(#"{"data":[]}"#.utf8))
            }

            Issue.record("Unexpected request during updateAPIKey: \(url.absoluteString)")
            return (providerManagerHTTPResponse(url: url, statusCode: 500), Data())
        }

        let state = makeState()
        let providerID = UUID()
        state.providers = [
            TestFactories.makeProvider(
                id: providerID,
                kind: .openAI,
                status: .issue("bad-key"),
                models: [TestFactories.makeModel(id: "gpt-5.4", isDefault: true)],
                catalogModels: [],
                lastCheckedAt: Date(timeIntervalSince1970: 1),
                apiKey: "sk-old-secret",
                lastError: "bad-key"
            ),
        ]

        try await state.updateAPIKey(providerID: providerID, newKey: "sk-new-secret")

        let provider = try #require(state.providers.first(where: { $0.id == providerID }))
        #expect(provider.apiKey == "sk-new-secret")
        #expect(provider.apiKeyPreview == "sk-n…cret")
        #expect(provider.status == .connected)
        #expect(provider.lastError == nil)
    }

    @Test("Update APIKey Official Skips Upstream Validation")
    func updateAPIKeyOfficialSkipsUpstreamValidation() async throws {
        try await loadOpenAIMetadata()
        registerProviderManagerSharedMock()
        defer {
            ProviderManagerSharedURLProtocol.requestHandler = nil
            unregisterProviderManagerSharedMock()
        }

        ProviderManagerSharedURLProtocol.requestHandler = { request in
            let url = try #require(request.url)

            if url.path == "/local-snapshot" {
                return (providerManagerHTTPResponse(url: url, statusCode: 304), Data())
            }

            if url.path.hasSuffix("/models") {
                return (providerManagerHTTPResponse(url: url, statusCode: 200), Data(#"{"data":[]}"#.utf8))
            }

            Issue.record("Unexpected request during official updateAPIKey: \(url.absoluteString)")
            return (providerManagerHTTPResponse(url: url, statusCode: 500), Data())
        }

        let state = makeState()
        let providerID = UUID()
        let originalCheckedAt = Date(timeIntervalSince1970: 123)
        let originalPreview = "sk-...12345"
        state.providers = [
            TestFactories.makeProvider(
                id: providerID,
                kind: .openAI,
                status: .connected,
                models: [TestFactories.makeModel(id: "gpt-5.4", isDefault: true)],
                catalogModels: [],
                lastCheckedAt: originalCheckedAt,
                apiKey: "sk-old-secret",
                apiKeyPreview: originalPreview,
                lastError: nil
            ),
        ]

        try await state.updateAPIKey(providerID: providerID, newKey: "sk-new-secret")

        let provider = try #require(state.providers.first(where: { $0.id == providerID }))
        #expect(provider.apiKey == "sk-new-secret")
        #expect(provider.apiKeyPreview == "sk-n…cret")
        #expect(provider.status == .connected)
        #expect(provider.lastError == nil)
        #expect(provider.lastCheckedAt != originalCheckedAt)
    }

    @Test("Update APIKey Relay Generation Failure Keeps New Key Fail Closed")
    func updateAPIKeyRelayGenerationFailureKeepsNewKeyFailClosed() async throws {
        await MetadataClient.shared.resetForTesting()
        registerProviderManagerSharedMock()
        defer {
            ProviderManagerSharedURLProtocol.requestHandler = nil
            unregisterProviderManagerSharedMock()
        }

        ProviderManagerSharedURLProtocol.requestHandler = { request in
            let url = try #require(request.url)

            if url.path == "/local-snapshot" {
                return (providerManagerHTTPResponse(url: url, statusCode: 200), Data(#"{"version":1,"providers":{}}"#.utf8))
            }

            if url.host == "relay.example.com", url.path == "/v1/chat/completions" {
                return (
                    providerManagerHTTPResponse(url: url, statusCode: 401),
                    Data(#"{"error":{"message":"bad relay key"}}"#.utf8)
                )
            }

            if url.path.hasSuffix("/models") || url.path.hasSuffix("/key") {
                return (providerManagerHTTPResponse(url: url, statusCode: 200), Data(#"{"data":[]}"#.utf8))
            }
            Issue.record("Unexpected request during relay updateAPIKey: \(url.absoluteString)")
            return (providerManagerHTTPResponse(url: url, statusCode: 500), Data())
        }

        let state = makeState()
        let providerID = UUID()
        let manualModel = TestFactories.makeModel(id: "relay-manual-model", name: "Manual Model", isDefault: true)
        state.providers = [
            TestFactories.makeProvider(
                id: providerID,
                kind: .relay,
                status: .connected,
                models: [manualModel],
                catalogModels: [manualModel],
                lastCheckedAt: Date(timeIntervalSince1970: 1),
                apiKey: "sk-old-relay",
                apiKeyPreview: "••••••••",
                baseURLText: "https://relay.example.com/v1"
            ),
        ]

        do {
            try await state.updateAPIKey(providerID: providerID, newKey: "sk-new-relay")
            Issue.record("Expected relay generation verification to fail")
        } catch {}

        let provider = try #require(state.providers.first(where: { $0.id == providerID }))
        #expect(provider.apiKey == "sk-new-relay")
        #expect(provider.apiKeyPreview == "••••••••")
        #expect(provider.models.contains(where: { $0.id == manualModel.id }))
        #expect(provider.catalogModels.isEmpty)
        #expect(provider.status != .connected)
        #expect(provider.lastCheckedAt == nil)
        #expect(provider.lastError?.contains("relay.example.com") == false)
    }

    @Test("Update APIKey Relay Generation Success Verifies Before Catalog Sync")
    func updateAPIKeyRelayGenerationSuccessVerifiesBeforeCatalogSync() async throws {
        await MetadataClient.shared.resetForTesting()
        registerProviderManagerSharedMock()
        defer {
            ProviderManagerSharedURLProtocol.requestHandler = nil
            unregisterProviderManagerSharedMock()
        }

        var requests: [URLRequest] = []
        ProviderManagerSharedURLProtocol.requestHandler = { request in
            let url = try #require(request.url)
            requests.append(request)
            if url.path == "/local-snapshot" {
                return (providerManagerHTTPResponse(url: url, statusCode: 200), Data(#"{"version":1,"providers":{}}"#.utf8))
            }
            if url.path == "/v1/chat/completions" {
                return (providerManagerHTTPResponse(url: url, statusCode: 200), Data(#"{"choices":[{"message":{"content":"ok"}}]}"#.utf8))
            }
            if url.path == "/v1/models" {
                return (providerManagerHTTPResponse(url: url, statusCode: 200), Data(#"{"data":[{"id":"catalog-model"}]}"#.utf8))
            }
            return (providerManagerHTTPResponse(url: url, statusCode: 500), Data())
        }

        let state = makeState()
        let providerID = UUID()
        let manualModel = TestFactories.makeModel(id: "relay-manual-model", name: "Manual Model", isDefault: true)
        var relayProvider = TestFactories.makeProvider(
            id: providerID,
            kind: .relay,
            status: .issue("old key"),
            models: [manualModel],
            catalogModels: [manualModel],
            lastCheckedAt: nil,
            apiKey: "sk-old-relay",
            baseURLText: "https://relay.example.com/v1"
        )
        relayProvider.relayRequested = RelayRequestedConfig(
            transport: .openaiChatCompletions,
            authMode: .bearer,
            modelID: manualModel.id
        )
        state.providers = [relayProvider]

        try await state.updateAPIKey(providerID: providerID, newKey: "sk-new-relay")

        let relayRequests = requests.filter { $0.url?.host == "relay.example.com" }
        let chatIndex = try #require(relayRequests.firstIndex { $0.url?.path == "/v1/chat/completions" })
        let modelsIndex = try #require(relayRequests.firstIndex { $0.url?.path == "/v1/models" })
        #expect(chatIndex < modelsIndex)
        #expect(relayRequests[chatIndex].value(forHTTPHeaderField: "Authorization") == "Bearer sk-new-relay")

        let provider = try #require(state.provider(for: providerID))
        #expect(provider.status == .connected)
        #expect(provider.lastCheckedAt != nil)
        #expect(provider.lastError == nil)
        #expect(provider.apiKey == "sk-new-relay")
        #expect(provider.models.contains(where: { $0.id == manualModel.id }))
        #expect(provider.catalogModels.contains(where: { $0.id == "catalog-model" }))
    }

    @Test("Update APIKey Relay Catalog Failure Does Not Undo Generation Success")
    func updateAPIKeyRelayCatalogFailureDoesNotUndoGenerationSuccess() async throws {
        await MetadataClient.shared.resetForTesting()
        registerProviderManagerSharedMock()
        defer {
            ProviderManagerSharedURLProtocol.requestHandler = nil
            unregisterProviderManagerSharedMock()
        }

        var requests: [URLRequest] = []
        ProviderManagerSharedURLProtocol.requestHandler = { request in
            let url = try #require(request.url)
            requests.append(request)
            if url.path == "/local-snapshot" {
                return (providerManagerHTTPResponse(url: url, statusCode: 200), Data(#"{"version":1,"providers":{}}"#.utf8))
            }
            if url.path == "/v1/chat/completions" {
                return (providerManagerHTTPResponse(url: url, statusCode: 200), Data(#"{"choices":[{"message":{"content":"ok"}}]}"#.utf8))
            }
            if url.path == "/v1/models" {
                return (providerManagerHTTPResponse(url: url, statusCode: 503), Data(#"{"error":"catalog unavailable"}"#.utf8))
            }
            return (providerManagerHTTPResponse(url: url, statusCode: 500), Data())
        }

        let state = makeState()
        let providerID = UUID()
        let enabled = TestFactories.makeModel(id: "still-sendable", isDefault: true)
        let staleCatalog = TestFactories.makeModel(id: "old-catalog")
        var relay = TestFactories.makeProvider(
            id: providerID,
            kind: .relay,
            status: .connected,
            models: [enabled],
            catalogModels: [staleCatalog],
            lastCheckedAt: Date(timeIntervalSince1970: 1),
            apiKey: "sk-old-relay",
            baseURLText: "https://relay.example.com/v1"
        )
        relay.relayRequested = RelayRequestedConfig(
            transport: .openaiChatCompletions,
            authMode: .bearer,
            modelID: enabled.id
        )
        state.providers = [relay]

        try await state.updateAPIKey(providerID: providerID, newKey: "sk-new-relay")

        let relayRequests = requests.filter { $0.url?.host == "relay.example.com" }
        #expect(relayRequests.filter { $0.url?.path == "/v1/chat/completions" }.count == 1)
        #expect(relayRequests.filter { $0.url?.path == "/v1/models" }.count == 1)
        let updated = try #require(state.provider(for: providerID))
        #expect(updated.status == .connected)
        #expect(updated.lastCheckedAt != nil)
        #expect(updated.lastError == ProviderIssueMessage.catalogUnavailableKey)
        #expect(updated.catalogModels.isEmpty)
        #expect(updated.models.contains(where: { $0.id == enabled.id }))
    }

    @Test("Relay Generation Verification Writer Uses Stable State Only")
    func relayGenerationVerificationWriterUsesStableStateOnly() {
        let state = makeState()
        let providerID = UUID()
        let endpoint = "https://raw-upstream.example.com/v1"
        state.providers = [TestFactories.makeProvider(
            id: providerID, kind: .relay, status: .issue("old"), lastCheckedAt: nil,
            apiKey: "sk-test", baseURLText: endpoint
        )]

        state.providerManager.recordRelayGenerationVerification(providerID: providerID, verified: true)
        let success = state.provider(for: providerID)
        #expect(success?.status == .connected)
        #expect(success?.lastCheckedAt != nil)
        #expect(success?.lastError == nil)

        state.providerManager.recordRelayGenerationVerification(
            providerID: providerID,
            verified: false,
            error: ProviderServiceError.upstream(statusCode: 502, detail: "echo \(endpoint)")
        )
        let failure = state.provider(for: providerID)
        #expect(failure?.status == .issue("The provider returned an error for this request. Please retry or switch models."))
        #expect(failure?.lastError == "The provider returned an error for this request. Please retry or switch models.")
        #expect(failure?.lastError?.contains(endpoint) == false)
    }

    @Test("Update Base URLTriggers Resync")
    func updateBaseURLTriggersResync() async throws {
        await MetadataClient.shared.resetForTesting()
        registerProviderManagerSharedMock()
        defer {
            ProviderManagerSharedURLProtocol.requestHandler = nil
            unregisterProviderManagerSharedMock()
        }

        var requestedURL: URL?
        ProviderManagerSharedURLProtocol.requestHandler = { request in
            let url = try #require(request.url)

            if url.path == "/local-snapshot" {
                return (providerManagerHTTPResponse(url: url, statusCode: 200), Data(#"{"version":1,"providers":{}}"#.utf8))
            }

            if url.host == "relay.changed.example.com", url.path == "/v1/models" {
                requestedURL = url
                return (
                    providerManagerHTTPResponse(url: url, statusCode: 200),
                    Data(#"{"data":[{"id":"gpt-4.1","created":1710000000}]}"#.utf8)
                )
            }

            if url.path.hasSuffix("/models") || url.path.hasSuffix("/key") {
                return (providerManagerHTTPResponse(url: url, statusCode: 200), Data(#"{"data":[]}"#.utf8))
            }
            Issue.record("Unexpected request during updateBaseURL: \(url.absoluteString)")
            return (providerManagerHTTPResponse(url: url, statusCode: 500), Data())
        }

        let state = makeState()
        let providerID = UUID()
        let manualModel = TestFactories.makeModel(id: "relay-manual-custom-model", name: "custom-model", isDefault: true)
        state.providers = [
            TestFactories.makeProvider(
                id: providerID,
                kind: .relay,
                models: [manualModel],
                catalogModels: [manualModel],
                lastCheckedAt: Date(timeIntervalSince1970: 1),
                apiKey: "sk-relay-secret",
                baseURLText: "https://relay.old.example.com/v1"
            ),
        ]

        try await state.updateBaseURL(
            providerID: providerID,
            baseURLText: " https://relay.changed.example.com/v1/ "
        )

        let provider = try #require(state.providers.first(where: { $0.id == providerID }))
        #expect(provider.baseURLText == "https://relay.changed.example.com/v1/")
        #expect(requestedURL?.absoluteString == "https://relay.changed.example.com/v1/models")
        #expect(provider.status == .connected)
    }

    @Test("Provider Update Normalizes Conversation Model To Canonical Identifier")
    func providerUpdateNormalizesConversationModelToCanonicalIdentifier() {
        let state = makeState()
        let providerID = UUID()
        let snapshotModel = TestFactories.makeModel(
            id: "gpt-5.4-2026-03-05",
            name: "GPT-5.4 Snapshot",
            isDefault: true,
            canonicalModelId: "gpt-5.4"
        )
        let conversation = TestFactories.makeConversation(
            providerID: providerID,
            modelID: "gpt-5.4-2026-03-05"
        )

        state.providers = [
            TestFactories.makeProvider(
                id: providerID,
                kind: .openAI,
                models: [snapshotModel],
                catalogModels: [snapshotModel]
            ),
        ]
        state.replaceConversationProjection([conversation])

        state.providerManager.updateProvider(
            TestFactories.makeProvider(
                id: providerID,
                kind: .openAI,
                models: [snapshotModel],
                catalogModels: []
            )
        )

        #expect(state.conversations.first?.modelID == "gpt-5.4")
    }

    private func loadPhase2OfficialMetadata() async throws {
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(json: """
        {
          "version": 42,
          "contractVersion": 1,
          "updatedAt": "2026-04-18T00:00:00Z",
          "providers": {
            "qwen": {
              "displayName": "Qwen",
              "defaultModelId": "qwen3.6-plus",
              "validationModelId": "qwen3.6-plus",
              "resolveMap": {
                "qwen3.6-plus": "qwen3.6-plus",
                "qwen3.6-plus-2026-04-02": "qwen3.6-plus",
                "qwen-turbo": "qwen-turbo",
                "qwen-image-2.0": "qwen-image-2.0"
              },
              "models": {
                "qwen3.6-plus": {
                  "canonicalModelId": "qwen3.6-plus",
                  "aliases": ["qwen3.6-plus-2026-04-02"],
                  "displayName": "Qwen 3.6 Plus",
                  "pricingStatus": "priced",
                  "pricing": { "promptPerMToken": 0.28, "completionPerMToken": 1.65 },
                  "capabilities": ["text", "reasoning"],
                  "profiles": { "reasoning": "qwen_hybrid" },
                  "uiHints": { "groupKey": "qwen3", "groupName": "Qwen 3", "rank": 120, "recommended": true }
                },
                "qwen-turbo": {
                  "canonicalModelId": "qwen-turbo",
                  "displayName": "Qwen Turbo",
                  "pricingStatus": "priced",
                  "pricing": { "promptPerMToken": 0.1, "completionPerMToken": 0.4 },
                  "capabilities": ["text"],
                  "profiles": {},
                  "uiHints": { "groupKey": "qwen-turbo", "groupName": "Qwen Turbo", "rank": 80 }
                },
                "qwen-image-2.0": {
                  "canonicalModelId": "qwen-image-2.0",
                  "displayName": "Qwen Image 2.0",
                  "pricingStatus": "priced",
                  "pricing": { "promptPerMToken": 0.5, "completionPerMToken": 2.0 },
                  "capabilities": ["imageGeneration"],
                  "profiles": {},
                  "uiHints": { "groupKey": "qwen-image", "groupName": "Qwen Image", "rank": 60 }
                }
              }
            },
            "miniMax": {
              "displayName": "MiniMax",
              "defaultModelId": "MiniMax-M2.7",
              "validationModelId": "MiniMax-M2.7",
              "resolveMap": {
                "MiniMax-M2.7": "MiniMax-M2.7",
                "image-01": "image-01"
              },
              "models": {
                "MiniMax-M2.7": {
                  "canonicalModelId": "MiniMax-M2.7",
                  "displayName": "MiniMax M2.7",
                  "pricingStatus": "priced",
                  "pricing": { "promptPerMToken": 1.0, "completionPerMToken": 4.0 },
                  "capabilities": ["text"],
                  "profiles": {},
                  "uiHints": { "groupKey": "minimax", "groupName": "MiniMax", "rank": 90 }
                },
                "image-01": {
                  "canonicalModelId": "image-01",
                  "displayName": "MiniMax Image 01",
                  "pricingStatus": "priced",
                  "pricing": { "promptPerMToken": 0.5, "completionPerMToken": 2.0 },
                  "capabilities": ["imageGeneration"],
                  "profiles": {},
                  "uiHints": { "groupKey": "minimax-image", "groupName": "MiniMax Image", "rank": 50 }
                }
              }
            },
            "siliconFlow": {
              "displayName": "SiliconFlow",
              "defaultModelId": "deepseek-ai/DeepSeek-V3",
              "validationModelId": "deepseek-ai/DeepSeek-V3",
              "resolveMap": {
                "deepseek-ai/DeepSeek-V3": "deepseek-ai/DeepSeek-V3",
                "Qwen/Qwen3-235B-A22B": "Qwen/Qwen3-235B-A22B"
              },
              "models": {
                "deepseek-ai/DeepSeek-V3": {
                  "canonicalModelId": "deepseek-ai/DeepSeek-V3",
                  "displayName": "DeepSeek V3",
                  "vendorKey": "deepseek-ai",
                  "vendorName": "DeepSeek",
                  "pricingStatus": "priced",
                  "pricing": { "promptPerMToken": 0.27, "completionPerMToken": 1.1 },
                  "capabilities": ["text", "reasoning"],
                  "profiles": {},
                  "uiHints": { "groupKey": "deepseek-ai", "groupName": "DeepSeek", "rank": 110 }
                },
                "Qwen/Qwen3-235B-A22B": {
                  "canonicalModelId": "Qwen/Qwen3-235B-A22B",
                  "displayName": "Qwen3 235B A22B",
                  "vendorKey": "qwen",
                  "vendorName": "Qwen",
                  "pricingStatus": "priced",
                  "pricing": { "promptPerMToken": 0.9, "completionPerMToken": 3.6 },
                  "capabilities": ["text"],
                  "profiles": {},
                  "uiHints": { "groupKey": "qwen", "groupName": "Qwen", "rank": 100 }
                }
              }
            },
            "zhipu": {
              "displayName": "Z.ai",
              "defaultModelId": "glm-4-plus",
              "validationModelId": "glm-4-plus",
              "resolveMap": {
                "glm-4-plus": "glm-4-plus",
                "cogview-4": "cogview-4"
              },
              "models": {
                "glm-4-plus": {
                  "canonicalModelId": "glm-4-plus",
                  "displayName": "GLM-4 Plus",
                  "pricingStatus": "priced",
                  "pricing": { "promptPerMToken": 0.6, "completionPerMToken": 2.4 },
                  "capabilities": ["text", "image"],
                  "profiles": {},
                  "uiHints": { "groupKey": "glm-4", "groupName": "GLM 4", "rank": 95 }
                },
                "cogview-4": {
                  "canonicalModelId": "cogview-4",
                  "displayName": "CogView 4",
                  "pricingStatus": "priced",
                  "pricing": { "promptPerMToken": 0.5, "completionPerMToken": 2.0 },
                  "capabilities": ["imageGeneration"],
                  "profiles": {},
                  "uiHints": { "groupKey": "cogview", "groupName": "CogView", "rank": 55 }
                }
              }
            }
          }
        }
        """)
    }

    @Test("Register Provider Qwen Uses Metadata Resolver Catalog")
    func registerProviderQwenUsesMetadataResolverCatalog() async throws {
        try await loadPhase2OfficialMetadata()
        registerProviderManagerSharedMock()
        defer {
            ProviderManagerSharedURLProtocol.requestHandler = nil
            unregisterProviderManagerSharedMock()
        }

        ProviderManagerSharedURLProtocol.requestHandler = { request in
            let url = try #require(request.url)
            if url.path == "/local-snapshot" {
                return (providerManagerHTTPResponse(url: url, statusCode: 304), Data())
            }
            if url.path.hasSuffix("/models") || url.path.hasSuffix("/key") {
                return (providerManagerHTTPResponse(url: url, statusCode: 200), Data(#"{"data":[]}"#.utf8))
            }
            Issue.record("Unexpected request: \(url.absoluteString)")
            return (providerManagerHTTPResponse(url: url, statusCode: 500), Data())
        }

        let state = makeState()
        let provider = try await state.providerManager.registerProvider(
            kind: .qwen,
            apiKey: "sk-qwen-test",
            baseURLText: nil
        )

        let catalog = ProviderCatalogResolver.resolve(provider: provider)
        #expect(catalog.catalog.count == 3)
        #expect(catalog.catalog.map(\.model.id).sorted() == ["qwen-image-2.0", "qwen-turbo", "qwen3.6-plus"])
        #expect(provider.catalogModels.isEmpty)
        #expect(provider.models.map(\.id) == ["qwen3.6-plus"])
        #expect(provider.defaultModel?.id == "qwen3.6-plus")
    }

    @Test("Register Provider Qwen Alias Maps To Canonical And Preserves Default")
    func registerProviderQwenAliasMapsToCanonicalAndPreservesDefault() async throws {
        try await loadPhase2OfficialMetadata()
        registerProviderManagerSharedMock()
        defer {
            ProviderManagerSharedURLProtocol.requestHandler = nil
            unregisterProviderManagerSharedMock()
        }

        ProviderManagerSharedURLProtocol.requestHandler = { request in
            let url = try #require(request.url)
            if url.path == "/local-snapshot" {
                return (providerManagerHTTPResponse(url: url, statusCode: 304), Data())
            }
            if url.host == "dashscope-intl.aliyuncs.com" {
                return (
                    providerManagerHTTPResponse(url: url, statusCode: 200),
                    Data(#"{"choices":[{"message":{"content":"pong"}}],"usage":{"prompt_tokens":1,"completion_tokens":1}}"#.utf8)
                )
            }
            if url.path.hasSuffix("/models") || url.path.hasSuffix("/key") {
                return (providerManagerHTTPResponse(url: url, statusCode: 200), Data(#"{"data":[]}"#.utf8))
            }
            Issue.record("Unexpected request: \(url.absoluteString)")
            return (providerManagerHTTPResponse(url: url, statusCode: 500), Data())
        }

        let state = makeState()
        let providerID = UUID()
        let aliasModel = TestFactories.makeModel(
            id: "qwen3.6-plus-2026-04-02",
            name: "Qwen old",
            isDefault: true,
            canonicalModelId: "qwen3.6-plus"
        )
        state.providers = [
            TestFactories.makeProvider(
                id: providerID,
                kind: .qwen,
                models: [aliasModel],
                catalogModels: [aliasModel],
                apiKey: "sk-qwen-old"
            ),
        ]

        _ = try await state.providerManager.registerProvider(
            kind: .qwen,
            apiKey: "sk-qwen-new",
            baseURLText: nil
        )

        let provider = try #require(state.providers.first(where: { $0.kind == .qwen }))
        #expect(provider.apiKey == "sk-qwen-new")
        let defaultModel = try #require(provider.defaultModel)
        #expect(defaultModel.canonicalModelId == "qwen3.6-plus" || defaultModel.id == "qwen3.6-plus")
    }

    @Test("Register Provider Mini Max Image Models From Metadata")
    func registerProviderMiniMaxImageModelsFromMetadata() async throws {
        try await loadPhase2OfficialMetadata()
        registerProviderManagerSharedMock()
        defer {
            ProviderManagerSharedURLProtocol.requestHandler = nil
            unregisterProviderManagerSharedMock()
        }

        ProviderManagerSharedURLProtocol.requestHandler = { request in
            let url = try #require(request.url)
            if url.path == "/local-snapshot" {
                return (providerManagerHTTPResponse(url: url, statusCode: 304), Data())
            }
            if url.path.hasSuffix("/models") || url.path.hasSuffix("/key") {
                return (providerManagerHTTPResponse(url: url, statusCode: 200), Data(#"{"data":[]}"#.utf8))
            }
            Issue.record("Unexpected request: \(url.absoluteString)")
            return (providerManagerHTTPResponse(url: url, statusCode: 500), Data())
        }

        let state = makeState()
        let provider = try await state.providerManager.registerProvider(
            kind: .miniMax,
            apiKey: "sk-api-test-minimax",
            baseURLText: nil
        )

        let catalog = ProviderCatalogResolver.resolve(provider: provider)
        #expect(catalog.catalog.count == 2)
        let imageModel = try #require(catalog.catalog.first(where: { $0.model.id == "image-01" }))
        #expect(imageModel.model.capabilities.contains(.imageGen))
    }

    @Test("Register Provider Silicon Flow Vendor From Metadata")
    func registerProviderSiliconFlowVendorFromMetadata() async throws {
        try await loadPhase2OfficialMetadata()
        registerProviderManagerSharedMock()
        defer {
            ProviderManagerSharedURLProtocol.requestHandler = nil
            unregisterProviderManagerSharedMock()
        }

        ProviderManagerSharedURLProtocol.requestHandler = { request in
            let url = try #require(request.url)
            if url.path == "/local-snapshot" {
                return (providerManagerHTTPResponse(url: url, statusCode: 304), Data())
            }
            if url.path.hasSuffix("/models") || url.path.hasSuffix("/key") {
                return (providerManagerHTTPResponse(url: url, statusCode: 200), Data(#"{"data":[]}"#.utf8))
            }
            Issue.record("Unexpected request: \(url.absoluteString)")
            return (providerManagerHTTPResponse(url: url, statusCode: 500), Data())
        }

        let state = makeState()
        let provider = try await state.providerManager.registerProvider(
            kind: .siliconFlow,
            apiKey: "sk-sf-test",
            baseURLText: nil
        )

        let catalog = ProviderCatalogResolver.resolve(provider: provider)
        let deepSeek = try #require(catalog.catalog.first(where: { $0.model.id == "deepseek-ai/DeepSeek-V3" }))
        #expect(deepSeek.model.groupKey == "deepseek-ai")
        #expect(deepSeek.model.groupName == "DeepSeek")
    }

    @Test("Register Provider Zhipu Uses Metadata Catalog")
    func registerProviderZhipuUsesMetadataCatalog() async throws {
        try await loadPhase2OfficialMetadata()
        registerProviderManagerSharedMock()
        defer {
            ProviderManagerSharedURLProtocol.requestHandler = nil
            unregisterProviderManagerSharedMock()
        }

        ProviderManagerSharedURLProtocol.requestHandler = { request in
            let url = try #require(request.url)
            if url.path == "/local-snapshot" {
                return (providerManagerHTTPResponse(url: url, statusCode: 304), Data())
            }
            if url.host == "open.bigmodel.cn" {
                return (
                    providerManagerHTTPResponse(url: url, statusCode: 200),
                    Data(#"{"choices":[{"message":{"content":"pong"}}],"usage":{"prompt_tokens":1,"completion_tokens":1}}"#.utf8)
                )
            }
            if url.path.hasSuffix("/models") || url.path.hasSuffix("/key") {
                return (providerManagerHTTPResponse(url: url, statusCode: 200), Data(#"{"data":[]}"#.utf8))
            }
            Issue.record("Unexpected request: \(url.absoluteString)")
            return (providerManagerHTTPResponse(url: url, statusCode: 500), Data())
        }

        let state = makeState()
        let provider = try await state.providerManager.registerProvider(
            kind: .zhipu,
            apiKey: "sk-zhipu-test",
            baseURLText: nil
        )

        let catalog = ProviderCatalogResolver.resolve(provider: provider)
        #expect(catalog.catalog.count == 2)
        #expect(catalog.catalog.map(\.model.id).sorted() == ["cogview-4", "glm-4-plus"])
        let cogview = try #require(catalog.catalog.first(where: { $0.model.id == "cogview-4" }))
        #expect(cogview.model.capabilities.contains(.imageGen))
    }

    @Test("Register And Resync Produce Identical Metadata Driven Catalog")
    func registerAndResyncProduceIdenticalMetadataDrivenCatalog() async throws {
        try await loadPhase2OfficialMetadata()
        registerProviderManagerSharedMock()
        defer {
            ProviderManagerSharedURLProtocol.requestHandler = nil
            unregisterProviderManagerSharedMock()
        }

        ProviderManagerSharedURLProtocol.requestHandler = { request in
            let url = try #require(request.url)
            if url.path == "/local-snapshot" {
                return (providerManagerHTTPResponse(url: url, statusCode: 304), Data())
            }
            if url.host == "dashscope-intl.aliyuncs.com" {
                return (
                    providerManagerHTTPResponse(url: url, statusCode: 200),
                    Data(#"{"choices":[{"message":{"content":"pong"}}],"usage":{"prompt_tokens":1,"completion_tokens":1}}"#.utf8)
                )
            }
            if url.path.hasSuffix("/models") || url.path.hasSuffix("/key") {
                return (providerManagerHTTPResponse(url: url, statusCode: 200), Data(#"{"data":[]}"#.utf8))
            }
            Issue.record("Unexpected request: \(url.absoluteString)")
            return (providerManagerHTTPResponse(url: url, statusCode: 500), Data())
        }

        let state = makeState()
        let registeredProvider = try await state.providerManager.registerProvider(
            kind: .qwen,
            apiKey: "sk-qwen-test",
            baseURLText: nil
        )
        let registeredCatalog = ProviderCatalogResolver.resolve(provider: registeredProvider).catalog.map(\.model.id).sorted()

        try await state.resyncProvider(providerID: registeredProvider.id)
        let resyncedProvider = try #require(state.providers.first(where: { $0.id == registeredProvider.id }))
        let resyncedCatalog = ProviderCatalogResolver.resolve(provider: resyncedProvider).catalog.map(\.model.id).sorted()

        #expect(registeredCatalog == resyncedCatalog)
        #expect(resyncedProvider.catalogModels.isEmpty)
    }


    @Test("Register Provider Prunes Manual Retained When Flag Enabled")
    func registerProviderPrunesManualRetainedWhenFlagEnabled() async throws {
        try await loadPhase2OfficialMetadata()
        registerProviderManagerSharedMock()
        defer {
            ProviderManagerSharedURLProtocol.requestHandler = nil
            unregisterProviderManagerSharedMock()
        }

        ProviderManagerSharedURLProtocol.requestHandler = { request in
            let url = try #require(request.url)
            if url.path == "/local-snapshot" {
                return (providerManagerHTTPResponse(url: url, statusCode: 304), Data())
            }
            if url.host == "dashscope-intl.aliyuncs.com" {
                return (
                    providerManagerHTTPResponse(url: url, statusCode: 200),
                    Data(#"{"choices":[{"message":{"content":"pong"}}],"usage":{"prompt_tokens":1,"completion_tokens":1}}"#.utf8)
                )
            }
            if url.path.hasSuffix("/models") || url.path.hasSuffix("/key") {
                return (providerManagerHTTPResponse(url: url, statusCode: 200), Data(#"{"data":[]}"#.utf8))
            }
            Issue.record("Unexpected request: \(url.absoluteString)")
            return (providerManagerHTTPResponse(url: url, statusCode: 500), Data())
        }

        let state = makeState()
        let providerID = UUID()
        let ghostModel = TestFactories.makeModel(
            id: "qwen-legacy-ghost",
            name: "Ghost",
            isDefault: true
        )
        let realModel = TestFactories.makeModel(
            id: "qwen3.6-plus",
            name: "Qwen 3.6 Plus",
            isDefault: false,
            canonicalModelId: "qwen3.6-plus"
        )
        state.providers = [
            TestFactories.makeProvider(
                id: providerID,
                kind: .qwen,
                models: [ghostModel, realModel],
                catalogModels: [],
                apiKey: "sk-qwen-old"
            ),
        ]

        ManualRetainedPruningPolicy.flagOverrideForTesting = true
        defer { ManualRetainedPruningPolicy.flagOverrideForTesting = nil }

        _ = try await state.providerManager.registerProvider(
            kind: .qwen,
            apiKey: "sk-qwen-new",
            baseURLText: nil
        )

        let provider = try #require(state.providers.first(where: { $0.kind == .qwen }))
        #expect(provider.models.contains(where: { $0.id == "qwen-legacy-ghost" }) == false)
        #expect(provider.models.contains(where: { $0.id == "qwen3.6-plus" }))
        let defaultModel = try #require(provider.defaultModel)
        #expect(defaultModel.id == "qwen3.6-plus" || defaultModel.canonicalModelId == "qwen3.6-plus")
    }

    @Test("Register Provider Creates Fresh Official Instance Without Manual Retained")
    func registerProviderCreatesFreshOfficialInstanceWithoutManualRetained() async throws {
        try await loadPhase2OfficialMetadata()
        registerProviderManagerSharedMock()
        defer {
            ProviderManagerSharedURLProtocol.requestHandler = nil
            unregisterProviderManagerSharedMock()
        }

        ProviderManagerSharedURLProtocol.requestHandler = { request in
            let url = try #require(request.url)
            if url.path == "/local-snapshot" {
                return (providerManagerHTTPResponse(url: url, statusCode: 304), Data())
            }
            if url.host == "dashscope-intl.aliyuncs.com" {
                return (
                    providerManagerHTTPResponse(url: url, statusCode: 200),
                    Data(#"{"choices":[{"message":{"content":"pong"}}],"usage":{"prompt_tokens":1,"completion_tokens":1}}"#.utf8)
                )
            }
            if url.path.hasSuffix("/models") || url.path.hasSuffix("/key") {
                return (providerManagerHTTPResponse(url: url, statusCode: 200), Data(#"{"data":[]}"#.utf8))
            }
            Issue.record("Unexpected request: \(url.absoluteString)")
            return (providerManagerHTTPResponse(url: url, statusCode: 500), Data())
        }

        let state = makeState()
        let providerID = UUID()
        let ghostModel = TestFactories.makeModel(
            id: "qwen-legacy-ghost",
            name: "Ghost",
            isDefault: true
        )
        state.providers = [
            TestFactories.makeProvider(
                id: providerID,
                kind: .qwen,
                models: [ghostModel],
                catalogModels: [],
                apiKey: "sk-qwen-old"
            ),
        ]

        ManualRetainedPruningPolicy.flagOverrideForTesting = false
        defer { ManualRetainedPruningPolicy.flagOverrideForTesting = nil }

        _ = try await state.providerManager.registerProvider(
            kind: .qwen,
            apiKey: "sk-qwen-new",
            baseURLText: nil
        )

        let newProvider = try #require(state.providers.first(where: { $0.kind == .qwen && $0.id != providerID }))
        #expect(newProvider.models.contains(where: { $0.id == "qwen-legacy-ghost" }) == false)
        #expect(newProvider.models.map(\.id) == ["qwen3.6-plus"])
    }

    @Test("Provider Update Falls Back Conversation Model To Default")
    func providerUpdateFallsBackConversationModelToDefault() {
        let state = makeState()
        let providerID = UUID()
        let defaultModel = TestFactories.makeModel(id: "gpt-4.1", name: "GPT-4.1", isDefault: true)
        let conversation = TestFactories.makeConversation(
            providerID: providerID,
            modelID: "removed-model"
        )

        state.providers = [
            TestFactories.makeProvider(
                id: providerID,
                kind: .openAI,
                models: [defaultModel],
                catalogModels: [defaultModel]
            ),
        ]
        state.replaceConversationProjection([conversation])

        state.providerManager.updateProvider(
            TestFactories.makeProvider(
                id: providerID,
                kind: .openAI,
                models: [defaultModel],
                catalogModels: []
            )
        )

        #expect(state.conversations.first?.modelID == "gpt-4.1")
    }

    private func openAIRegisterMock() -> @Sendable (URLRequest) throws -> (HTTPURLResponse, Data) {
        { request in
            let url = try #require(request.url)
            if url.path == "/local-snapshot" {
                return (providerManagerHTTPResponse(url: url, statusCode: 304), Data())
            }
            if url.path.hasSuffix("/models") || url.path.hasSuffix("/key") {
                return (providerManagerHTTPResponse(url: url, statusCode: 200), Data(#"{"data":[]}"#.utf8))
            }
            return (providerManagerHTTPResponse(url: url, statusCode: 200), Data(#"{"data":[]}"#.utf8))
        }
    }

    @Test("Default Instance Registers Deterministic ID")
    func defaultInstanceRegistersDeterministicID() async throws {
        try await loadOpenAIMetadata()
        registerProviderManagerSharedMock()
        defer {
            ProviderManagerSharedURLProtocol.requestHandler = nil
            unregisterProviderManagerSharedMock()
        }
        ProviderManagerSharedURLProtocol.requestHandler = openAIRegisterMock()

        let stateA = makeState()
        let providerA = try await stateA.providerManager.registerProvider(
            kind: .openAI,
            apiKey: "sk-a",
            baseURLText: nil
        )

        let stateB = makeState()
        let providerB = try await stateB.providerManager.registerProvider(
            kind: .openAI,
            apiKey: "sk-b",
            baseURLText: nil
        )

        let golden = "CEE693BC-01B3-5542-A639-D3263AF0D47A"
        #expect(providerA.id.uuidString == golden)
        #expect(providerB.id.uuidString == golden)
    }

    @Test("Additional Instance Uses Random ID")
    func additionalInstanceUsesRandomID() async throws {
        try await loadOpenAIMetadata()
        registerProviderManagerSharedMock()
        defer {
            ProviderManagerSharedURLProtocol.requestHandler = nil
            unregisterProviderManagerSharedMock()
        }
        ProviderManagerSharedURLProtocol.requestHandler = openAIRegisterMock()

        let state = makeState()
        let first = try await state.providerManager.registerProvider(
            kind: .openAI,
            apiKey: "sk-1",
            baseURLText: nil
        )
        let second = try await state.providerManager.registerProvider(
            kind: .openAI,
            apiKey: "sk-2",
            baseURLText: nil,
            isAdditionalInstance: true
        )

        let golden = "CEE693BC-01B3-5542-A639-D3263AF0D47A"
        #expect(first.id.uuidString == golden)
        #expect(second.id.uuidString != golden)
        #expect(second.id != first.id)
    }

    @Test("Different Region Different Deterministic ID")
    func differentRegionDifferentDeterministicID() async throws {
        try await loadPhase2OfficialMetadata()
        registerProviderManagerSharedMock()
        defer {
            ProviderManagerSharedURLProtocol.requestHandler = nil
            unregisterProviderManagerSharedMock()
        }
        ProviderManagerSharedURLProtocol.requestHandler = openAIRegisterMock()

        let stateGlobal = makeState()
        let global = try await stateGlobal.providerManager.registerProvider(
            kind: .miniMax,
            apiKey: "sk-mm",
            baseURLText: "api.minimax.io/v1"
        )

        let stateCN = makeState()
        let cn = try await stateCN.providerManager.registerProvider(
            kind: .miniMax,
            apiKey: "sk-mm",
            baseURLText: "api.minimaxi.com/v1"
        )

        #expect(global.id.uuidString == "C1F9299A-51D9-51ED-9B4F-853DEC6875A6")
        #expect(cn.id.uuidString == "53CA3FCB-2E5C-5B51-BDA0-61FC22339096")
        #expect(global.id != cn.id)
    }

    @Test("Migration Collapses Single Random Instance")
    func migrationCollapsesSingleRandomInstance() {
        let randomID = UUID()
        let legacy = TestFactories.makeProvider(
            id: randomID,
            kind: .openAI,
            apiKey: "sk-x"
        )
        let outcome = AppState.planDeterministicProviderMigration(
            providers: [legacy],
            setupCatalog: .fallback
        )
        let golden = UUID(uuidString: "CEE693BC-01B3-5542-A639-D3263AF0D47A")!
        #expect(outcome.providers.count == 1)
        #expect(outcome.providers.first?.id == golden)
        #expect(outcome.providers.first?.apiKey == "sk-x")
        #expect(outcome.idRemap[randomID] == golden)
    }

    @Test("Migration Collapses Same Key Duplicates")
    func migrationCollapsesSameKeyDuplicates() {
        let id1 = UUID()
        let id2 = UUID()
        let p1 = TestFactories.makeProvider(
            id: id1, kind: .openAI,
            models: [TestFactories.makeModel(id: "gpt-4.1")],
            apiKey: "sk-same"
        )
        let p2 = TestFactories.makeProvider(
            id: id2, kind: .openAI,
            models: [TestFactories.makeModel(id: "gpt-5.4")],
            apiKey: "sk-same"
        )
        let outcome = AppState.planDeterministicProviderMigration(
            providers: [p1, p2],
            setupCatalog: .fallback
        )
        let golden = UUID(uuidString: "CEE693BC-01B3-5542-A639-D3263AF0D47A")!
        #expect(outcome.providers.count == 1)
        let merged = try? #require(outcome.providers.first)
        #expect(merged?.id == golden)
        #expect(Set(merged?.models.map(\.id) ?? []) == ["gpt-4.1", "gpt-5.4"])
        #expect(outcome.removedProviderIDs.contains(id2))
        #expect(outcome.idRemap[id1] == golden)
        #expect(outcome.idRemap[id2] == golden)
    }

    @Test("Migration Keeps Different Key As Additional")
    func migrationKeepsDifferentKeyAsAdditional() {
        let id1 = UUID()
        let id2 = UUID()
        let p1 = TestFactories.makeProvider(id: id1, kind: .openAI, apiKey: "sk-a")
        let p2 = TestFactories.makeProvider(id: id2, kind: .openAI, apiKey: "sk-b")
        let outcome = AppState.planDeterministicProviderMigration(
            providers: [p1, p2],
            setupCatalog: .fallback
        )
        let golden = UUID(uuidString: "CEE693BC-01B3-5542-A639-D3263AF0D47A")!
        #expect(outcome.providers.count == 2)
        #expect(outcome.providers.contains(where: { $0.id == golden }))
        #expect(outcome.providers.contains(where: { $0.id == id2 }))
        #expect(outcome.idRemap[id2] == nil)
    }

    @Test("Migration Is Idempotent For Deterministic ID")
    func migrationIsIdempotentForDeterministicID() {
        let golden = UUID(uuidString: "CEE693BC-01B3-5542-A639-D3263AF0D47A")!
        let alreadyDeterministic = TestFactories.makeProvider(
            id: golden, kind: .openAI, apiKey: "sk-x"
        )
        let outcome = AppState.planDeterministicProviderMigration(
            providers: [alreadyDeterministic],
            setupCatalog: .fallback
        )
        #expect(outcome.providers.count == 1)
        #expect(outcome.providers.first?.id == golden)
        #expect(outcome.idRemap.isEmpty)
        #expect(outcome.removedProviderIDs.isEmpty)
    }

    @Test("deterministic migration leaves relay identities unchanged")
    func migrationSkipsRelay() {
        let relayID = UUID()
        let relay = TestFactories.makeProvider(
            id: relayID, kind: .relay, apiKey: "sk-relay",
            baseURLText: "https://relay.example.com/v1"
        )
        let outcome = AppState.planDeterministicProviderMigration(
            providers: [relay],
            setupCatalog: .fallback
        )
        #expect(outcome.idRemap.isEmpty)
        #expect(outcome.providers.map(\.id) == [relayID])
    }

    @Test("Removing Residual Relay Credential Preserves Connection Evidence")
    func removingResidualRelayCredentialPreservesConnectionEvidence() {
        let state = makeState()
        var provider = state.providerManager.registerRelay(
            name: "Local Relay",
            endpoint: "https://relay.example.com/v1",
            apiKey: "legacy-key",
            relayRequested: RelayRequestedConfig(authMode: .none)
        )
        let checkedAt = Date(timeIntervalSince1970: 1_700_000_000)
        provider.status = .connected
        provider.lastCheckedAt = checkedAt
        provider.lastError = nil
        state.providerManager.updateProvider(provider)

        state.providerManager.removeStoredRelayCredential(providerID: provider.id)

        let updated = state.providerManager.provider(for: provider.id)
        #expect(updated?.apiKey.isEmpty == true)
        #expect(updated?.apiKeyPreview.isEmpty == true)
        #expect(updated?.status == .connected)
        #expect(updated?.lastCheckedAt == checkedAt)
        #expect(updated?.lastError == nil)
    }
}
