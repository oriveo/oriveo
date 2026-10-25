import CryptoKit
import Foundation
import Testing
@testable import Oriveo

/// Relay 2.0: per-model protocol selection (RL2-RESOLVE-03), official providers dispatching by the delivered apiProtocol (E2-DISPATCH-01),
/// and the trusted host table read from delivered values (E2-TRUST-01 / 02). Requests are always built through the production entry point `ProviderServiceRouter`,
/// and the URLProtocol seam of HTTP captures the url / headers / body actually sent.
@Suite("Relay 2.0 · per-model dispatch and the trusted host table", .serialized, .sharedProcessState)
struct RelayDispatchTrustTests {

    // MARK: - Outbound capture

    private struct Captured {
        let url: String
        let headers: [String: String]
        let body: [String: Any]
    }

    private static func capture(
        _ make: (URLSession) -> AsyncThrowingStream<StreamEvent, Error>
    ) async throws -> Captured {
        DispatchCaptureProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DispatchCaptureProtocol.self]
        for try await _ in make(URLSession(configuration: config)) {}
        let request = try #require(DispatchCaptureProtocol.captured.first)
        var headers: [String: String] = [:]
        for (name, value) in request.allHTTPHeaderFields ?? [:] { headers[name.lowercased()] = value }
        let data = request.httpBody ?? DispatchCaptureProtocol.readBody(request.httpBodyStream) ?? Data()
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return Captured(url: request.url?.absoluteString ?? "", headers: headers, body: body)
    }

    private static func send(
        provider: Provider, model: AIModel, session: URLSession
    ) throws -> AsyncThrowingStream<StreamEvent, Error> {
        guard case .byProtocol(let route) = ProviderServiceRouter.route(provider: provider, model: model) else {
            throw CocoaError(.featureUnsupported)
        }
        var options = ChatRequestOptions()
        options.systemPrompt = "Be brief."
        return ProviderServiceRouter.Services(session: session).protocolStream(
            route, apiKey: provider.apiKey, modelID: model.id,
            messages: [TestFactories.makeMessage(role: .user, text: "hi")],
            reasoningMode: .automatic, webSearchEnabled: false, supportsImageGen: false,
            requestOptions: options
        )
    }

    // MARK: - metadata

    private static func providerConfigsJSON(_ configs: String) -> String {
        """
        {
          "version": 1,
          "updatedAt": "2026-10-10T00:00:00Z",
          "providers": {},
          "providerConfigs": [\(configs)]
        }
        """
    }

    private static func miniMaxConfig(apiProtocol: String, trustedHosts: String?) -> String {
        let trusted = trustedHosts.map { ", \"trustedHosts\": \($0)" } ?? ""
        return """
        {
          "kind": "miniMax",
          "displayName": "MiniMax",
          "defaultBaseURL": "https://api.minimax.io/anthropic",
          "apiProtocol": "\(apiProtocol)",
          "regionOptions": [
            {"id": "global", "label": "Global", "baseURL": "https://api.minimax.io/v1"},
            {"id": "cn", "label": "China", "baseURL": "https://api.minimaxi.com/v1"}
          ]\(trusted)
        }
        """
    }

    private static func decodeConfigs(_ configs: String) throws -> [MetadataClient.PublicProviderConfig] {
        try JSONDecoder().decode([MetadataClient.PublicProviderConfig].self, from: Data("[\(configs)]".utf8))
    }

    // MARK: - RL2-RESOLVE-03

    @Test("RL2_RESOLVE_03 Under one connection, a Messages model and a Chat model produce request bodies of two different protocols through the production builder")
    func RL2_RESOLVE_03_sameConnectionTwoProtocols() async throws {
        await MetadataClient.shared.resetForTesting()
        var messagesModel = TestFactories.makeModel(id: "claude-relay", capabilities: [.text])
        messagesModel.relayTransport = .anthropicMessages
        messagesModel.relayTransportSource = .reachable
        let chatModel = TestFactories.makeModel(id: "gpt-relay", capabilities: [.text], isDefault: true)
        var provider = TestFactories.makeProvider(
            kind: .relay, models: [chatModel, messagesModel],
            apiKey: "sk-relay", baseURLText: "https://relay.example.com"
        )
        provider.relayRequested = RelayRequestedConfig(
            transport: .openaiChatCompletions, authMode: .bearer,
            resolvedAPIBaseURLs: ["anthropic_messages": "https://relay.example.com/claude/v1"]
        )
        let before = provider

        let messages = try await Self.capture { try! Self.send(provider: provider, model: messagesModel, session: $0) }
        let chat = try await Self.capture { try! Self.send(provider: provider, model: chatModel, session: $0) }

        #expect(messages.url == "https://relay.example.com/claude/v1/messages")
        #expect(messages.body["max_tokens"] != nil)
        #expect(messages.body["system"] as? String == "Be brief.")
        #expect(messages.body["model"] as? String == "claude-relay")

        #expect(chat.url == "https://relay.example.com/v1/chat/completions")
        #expect(chat.body["max_tokens"] == nil)
        let chatTurns = try #require(chat.body["messages"] as? [[String: Any]])
        #expect(chatTurns.first?["role"] as? String == "system")
        #expect(chat.body["model"] as? String == "gpt-relay")

        // What is injected is a copy: the connection configuration is not rewritten.
        #expect(provider == before)
    }

    // MARK: - Partition keys of stored connections stay byte-for-byte identical

    /// The original form of the endpoint segment of `GenerationParameterProfileFingerprint` before per-model dispatch: `resolvedAPIBaseURL ?? baseURLText ?? ""`,
    /// with credentials / query / fragment / trailing slash stripped, then the first 16 hex characters of the SHA-256. It is copied here so a production change cannot alter it along the way.
    private static func legacyEndpointHash(_ provider: Provider) -> String {
        let raw = provider.relayRequested?.resolvedAPIBaseURL ?? provider.baseURLText ?? ""
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        var value = trimmed.components(separatedBy: CharacterSet(charactersIn: "?#")).first ?? trimmed
        if var components = URLComponents(string: trimmed) {
            components.user = nil
            components.password = nil
            components.query = nil
            components.fragment = nil
            let path = components.path.replacingOccurrences(of: #"/+$"#, with: "", options: .regularExpression)
            components.path = path.isEmpty ? "/" : path
            if let string = components.string { value = string }
        }
        return "ep_" + String(SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined().prefix(16))
    }

    /// The original form of a relay's final transport before per-model dispatch: the connection protocol, and `auto` builds no identity.
    private static func legacyFinalTransport(_ provider: Provider) -> String? {
        guard let transport = provider.relayRequested?.transport, transport != .auto else { return nil }
        return transport.rawValue
    }

    @Test("LEGACY_PARTITION For a stored connection without model-level fields, the parameter fingerprint and capability-preference partition keys are byte-for-byte the same as before, and values stored earlier can still be read afterwards")
    func LEGACY_PARTITION_storedKeysStillMatch() throws {
        let model = TestFactories.makeModel(id: "legacy-model", capabilities: [.text], isDefault: true)
        func relay(_ base: String, _ requested: RelayRequestedConfig) -> Provider {
            var provider = TestFactories.makeProvider(kind: .relay, models: [model], baseURLText: base)
            provider.relayRequested = requested
            return provider
        }
        let cases: [(String, Provider)] = [
            ("bare host, no probed root", relay("https://relay.example.com", .init(transport: .openaiChatCompletions))),
            ("auto, bare host", relay("https://relay.example.com", .init(transport: .auto))),
            ("auto, probed root", relay("https://relay.example.com", .init(transport: .auto, resolvedAPIBaseURL: "https://relay.example.com/gw/v1"))),
            ("messages, probed root", relay("https://relay.example.com", .init(transport: .anthropicMessages, resolvedAPIBaseURL: "https://relay.example.com/custom/v1"))),
            ("blank probed root", relay("https://relay.example.com/v2", .init(transport: .openaiResponses, resolvedAPIBaseURL: ""))),
            ("version in base", relay("https://relay.example.com/v1beta", .init(transport: .openaiChatCompletions))),
        ]
        let suiteName = "u5-legacy-partition-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = GenerationParameterSettingsStore(defaults: defaults)

        for (name, provider) in cases {
            #expect(RelayEndpointResolver.routedRequested(provider: provider, model: model) == provider.relayRequested, "\(name)")
            let fingerprint = GenerationParameterProfileFingerprint.make(provider: provider, model: model)
            #expect(fingerprint.split(separator: "|", omittingEmptySubsequences: false).first.map(String.init)
                    == Self.legacyEndpointHash(provider), "\(name)")

            let newTransport = CapabilityPreferenceRuntimeIdentity.relayFinalTransport(
                provider: provider, model: model, resolvedFinalTransport: nil
            )
            #expect(newTransport == Self.legacyFinalTransport(provider), "\(name)")
            guard let oldTransport = Self.legacyFinalTransport(provider), let newTransport else { continue }
            let oldWire = CapabilityPreferenceRuntimeIdentity(
                canonicalModelID: model.id, finalTransport: oldTransport, runtimeRevision: "rev-1"
            ).wireValue
            let newWire = CapabilityPreferenceRuntimeIdentity(
                canonicalModelID: model.id, finalTransport: newTransport, runtimeRevision: "rev-1"
            ).wireValue
            store.setCapabilityPreferences(
                .init(web: .off, reasoningIntent: "high"), providerID: provider.id, modelID: model.id,
                conversationID: nil, transportIdentity: oldWire
            )
            #expect(store.capabilityPreferences(
                providerID: provider.id, modelID: model.id, conversationID: nil, transportIdentity: newWire
            )?.reasoningIntent == "high", "\(name)")
        }
    }

    // MARK: - Cross-checks go through the same entry point

    @Test("CROSSCHECK_ROUTE The cross-check goes through ProviderServiceRouter: a relay connection gets the per-model injected protocol and root address")
    func CROSSCHECK_ROUTE_relayUsesInjectedTransport() async throws {
        await MetadataClient.shared.resetForTesting()
        var messagesModel = TestFactories.makeModel(id: "claude-relay", capabilities: [.text])
        messagesModel.relayTransport = .anthropicMessages
        messagesModel.relayTransportSource = .user
        var provider = TestFactories.makeProvider(
            kind: .relay, models: [messagesModel], apiKey: "sk-relay", baseURLText: "https://relay.example.com"
        )
        provider.relayRequested = RelayRequestedConfig(transport: .openaiChatCompletions, authMode: .bearer)

        let option = CrosscheckModelOption(
            providerID: provider.id, providerKind: .relay, logoProviderKind: .relay, relayKind: nil,
            providerName: "Relay", model: messagesModel, apiKey: "sk-relay", baseURL: nil
        )
        let transport = NoteCrosscheckBuilder.request(prompt: "check this", answer: "ok", model: option)
            .transportInput(ChatRequestOptions())
        let sent = try await Self.capture { session in
            try! NoteAIManager.crosscheckEventStream(
                provider: provider, model: messagesModel,
                transport: transport,
                services: ProviderServiceRouter.Services(session: session),
                nativeService: { _ in nil }
            )
        }
        #expect(sent.url == "https://relay.example.com/v1/messages")
        #expect(sent.body["max_tokens"] != nil)
        #expect(sent.headers["authorization"] == "Bearer sk-relay")
    }

    // MARK: - E2-DISPATCH-01

    @Test("E2_DISPATCH_01 When miniMax is delivered apiProtocol=anthropic, it takes the Messages shape with MiniMax authentication")
    func E2_DISPATCH_01_miniMaxAnthropicProtocol() async throws {
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(json: Self.providerConfigsJSON(
            Self.miniMaxConfig(apiProtocol: "anthropic", trustedHosts: #"["minimax.io", "minimaxi.com"]"#)
        ))
        let model = TestFactories.makeModel(id: "MiniMax-M2", capabilities: [.text], isDefault: true)
        let provider = TestFactories.makeProvider(kind: .miniMax, models: [model], apiKey: "mm-key")

        guard case .byProtocol(let route) = ProviderServiceRouter.route(provider: provider, model: model) else {
            Issue.record("apiProtocol=anthropic should dispatch by protocol")
            return
        }
        #expect(route.transport == .anthropicMessages)

        let sent = try await Self.capture { try! Self.send(provider: provider, model: model, session: $0) }
        #expect(sent.url == "https://api.minimax.io/anthropic/v1/messages")
        #expect(sent.headers["authorization"] == "Bearer mm-key")
        #expect(sent.headers["x-api-key"] == nil)
        #expect(sent.body["max_tokens"] != nil)
        #expect(sent.body["system"] as? String == "Be brief.")

        // Native family, missing, or unrecognized: all take the original path.
        for apiProtocol in ["openai", "openai_compatible", "bogus"] {
            let config = try #require(Self.decodeConfigs(Self.miniMaxConfig(apiProtocol: apiProtocol, trustedHosts: nil)).first)
            #expect(ProviderServiceRouter.officialProtocolRoute(provider: provider, config: config) == nil)
        }
        // A base URL outside the trusted table is not adopted; fall back to the original path.
        let untrusted = try #require(Self.decodeConfigs(
            Self.miniMaxConfig(apiProtocol: "anthropic", trustedHosts: nil)
                .replacingOccurrences(of: "https://api.minimax.io/anthropic", with: "https://evil.example/anthropic")
        ).first)
        #expect(ProviderServiceRouter.officialProtocolRoute(provider: provider, config: untrusted) == nil)
        // The official Anthropic provider delivered with anthropic = the native family.
        #expect(ProviderServiceRouter.foreignTransport(apiProtocol: "anthropic", providerKind: .anthropic) == nil)
    }

    // MARK: - E2-TRUST-01

    @Test("E2_TRUST_01 Trusted table: delivered values allow / reject; with a missing field or an empty table only the last two labels of the fallback host are trusted; malformed entries are dropped one by one")
    func E2_TRUST_01_trustedHosts() async throws {
        let delivered = ["minimax.io", "minimaxi.com"]
        #expect(OfficialTrustedHosts.isTrustedURL("https://api.minimax.io/v1", providerKind: .miniMax, delivered: delivered))
        #expect(OfficialTrustedHosts.isTrustedURL("https://api.minimaxi.com/v1", providerKind: .miniMax, delivered: delivered))
        #expect(!OfficialTrustedHosts.isTrustedURL("http://api.minimax.io/v1", providerKind: .miniMax, delivered: delivered))
        #expect(!OfficialTrustedHosts.isTrustedURL("https://api.minimax.io.evil.com/v1", providerKind: .miniMax, delivered: delivered))
        #expect(!OfficialTrustedHosts.isTrustedURL("https://notminimax.io/v1", providerKind: .miniMax, delivered: delivered))

        for missing in [nil, [String]()] {
            #expect(OfficialTrustedHosts.isTrustedURL("https://api.minimax.io/v1", providerKind: .miniMax, delivered: missing))
            #expect(!OfficialTrustedHosts.isTrustedURL("https://api.minimaxi.com/v1", providerKind: .miniMax, delivered: missing))
        }
        #expect(OfficialTrustedHosts.effective(providerKind: .siliconFlow, delivered: nil) == ["siliconflow.cn"])
        #expect(OfficialTrustedHosts.effective(providerKind: .qwen, delivered: nil) == ["aliyuncs.com"])
        #expect(OfficialTrustedHosts.effective(providerKind: .relay, delivered: ["x.ai"]).isEmpty)

        #expect(OfficialTrustedHosts.sanitized(["*.x.ai", "X.AI", "1.2.3.4", "x.ai:443", "com", "https://x.ai"]) == nil)
        #expect(OfficialTrustedHosts.sanitized(["x.ai", "bad*", "x.ai", "googleapis.com"]) == ["x.ai", "googleapis.com"])

        // Decoding layer: a malformed field counts as missing and must not fail decoding of the whole providerConfigs group.
        let malformed = try Self.decodeConfigs(
            Self.miniMaxConfig(apiProtocol: "openai", trustedHosts: #""minimax.io""#)
        )
        #expect(malformed.first?.trustedHosts?.hosts == nil)

        // Official base URL: the delivered table takes effect and hosts outside it are rejected (EndpointResolver no longer hardcodes an allowlist).
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(json: Self.providerConfigsJSON("""
            {"kind": "openAI", "displayName": "OpenAI", "defaultBaseURL": "https://api.openai.com/v1",
             "apiProtocol": "openai", "trustedHosts": ["openai.com", "openai-proxy.example"]}
            """))
        func resolvedBase(_ baseURL: String) throws -> String {
            try EndpointResolver.resolve(
                providerKind: .openAI, kind: .chat,
                metadataTransport: .init(
                    baseUrl: baseURL,
                    endpoints: .init(chat: "/v1/chat/completions", responses: nil, images: nil, embeddings: nil, files: nil)
                )
            ).baseURL
        }
        #expect(try resolvedBase("https://gw.openai-proxy.example") == "https://gw.openai-proxy.example")
        #expect(try resolvedBase("https://evil.example") == "https://api.openai.com/v1")
    }

    // MARK: - E2-TRUST-02

    @Test("E2_TRUST_02 When minimaxi.com is delivered, the China site region is kept; when the field is missing, it is filtered out")
    func E2_TRUST_02_regionOptionsFilteredByTrustedHosts() throws {
        let trusted = ProviderSetupCatalog.fromProviderConfigs(try Self.decodeConfigs(
            Self.miniMaxConfig(apiProtocol: "openai", trustedHosts: #"["minimax.io", "minimaxi.com"]"#)
        ))
        #expect(trusted.setupEndpointOptions(for: .miniMax).map(\.id) == ["global", "cn"])

        let missing = ProviderSetupCatalog.fromProviderConfigs(try Self.decodeConfigs(
            Self.miniMaxConfig(apiProtocol: "openai", trustedHosts: nil)
        ))
        #expect(missing.setupEndpointOptions(for: .miniMax).map(\.id) == ["global"])

        let empty = ProviderSetupCatalog.fromProviderConfigs(try Self.decodeConfigs(
            Self.miniMaxConfig(apiProtocol: "openai", trustedHosts: "[]")
        ))
        #expect(empty.setupEndpointOptions(for: .miniMax).map(\.id) == ["global"])
    }

    @Test("E2_TRUST_03 Falling back to the local region table also goes through the trusted table: with metadata missing / delivered empty / everything filtered out, no host outside the trusted table appears")
    func E2_TRUST_03_localFallbackRegionsFilteredByTrustedHosts() throws {
        func hosts(_ options: [ProviderEndpointOption]) -> [String] {
            options.compactMap { URLComponents(string: "https://\($0.baseURLText)")?.host }
        }
        // Metadata missing: the whole local table is the fallback, leaving per provider only hosts within the last two labels of the fallback host.
        let missing = ProviderSetupCatalog.fromProviderConfigs(nil)
        #expect(missing.setupEndpointOptions(for: .miniMax).map(\.id) == ["global"])
        for kind in ProviderKind.allCases {
            let trusted = OfficialTrustedHosts.effective(providerKind: kind, delivered: nil)
            for host in hosts(missing.setupEndpointOptions(for: kind)) {
                #expect(OfficialTrustedHosts.hostMatches(host, trusted: trusted), "\(kind) fell back to a host outside the table: \(host)")
            }
        }

        // regionOptions were delivered but all filtered out (only the China site, no trustedHosts): the fallback local table is filtered all the same.
        let filteredOut = ProviderSetupCatalog.fromProviderConfigs(try Self.decodeConfigs("""
            {"kind": "miniMax", "displayName": "MiniMax", "defaultBaseURL": "https://api.minimax.io/v1",
             "regionOptions": [{"id": "cn", "label": "China", "baseURL": "https://api.minimaxi.com/v1"}]}
            """))
        #expect(filteredOut.setupEndpointOptions(for: .miniMax).map(\.id) == ["global"])

        // Delivered empty but the trusted table has minimaxi.com: the fallback China site is kept according to the delivered table.
        let emptyButTrusted = ProviderSetupCatalog.fromProviderConfigs(try Self.decodeConfigs("""
            {"kind": "miniMax", "displayName": "MiniMax", "defaultBaseURL": "https://api.minimax.io/v1",
             "regionOptions": [], "trustedHosts": ["minimax.io", "minimaxi.com"]}
            """))
        #expect(emptyButTrusted.setupEndpointOptions(for: .miniMax).map(\.id) == ["global", "cn"])
    }

    @Test("E2_TRUST_04 With no delivered table, a stored China-site connection shows China Mainland, the picker still lists it but it cannot be newly chosen, and baseURLText is unchanged after saving without changes")
    func E2_TRUST_04_storedRegionSurvivesTrustFilter() throws {
        let catalog = ProviderSetupCatalog.fromProviderConfigs(nil)
        let stored = "api.minimaxi.com/v1"
        let current = try #require(ProviderEndpointEditPolicy.currentOption(
            catalog: catalog, kind: .miniMax, baseURLText: stored
        ))
        #expect(current.id == "cn")
        #expect(ProviderKind.miniMax.localizedSetupEndpointLabel(for: current).contains("China Mainland"))

        let picker = ProviderEndpointEditPolicy.pickerOptions(catalog: catalog, kind: .miniMax, current: current)
        #expect(picker.options.map(\.id) == ["global", "cn"])
        #expect(picker.lockedIDs == ["cn"])

        // Open edit and save without changes: the address stays verbatim (including the form the user stored it in).
        for storedText in [stored, "https://api.minimaxi.com/v1/"] {
            let currentForStored = ProviderEndpointEditPolicy.currentOption(
                catalog: catalog, kind: .miniMax, baseURLText: storedText
            )
            #expect(ProviderEndpointEditPolicy.baseURLTextToSave(
                catalog: catalog, kind: .miniMax, selectedOptionID: "cn",
                current: currentForStored, storedBaseURLText: storedText
            ) == storedText)
        }
        // Only choosing a selectable option writes a new address.
        #expect(ProviderEndpointEditPolicy.baseURLTextToSave(
            catalog: catalog, kind: .miniMax, selectedOptionID: "global",
            current: current, storedBaseURLText: stored
        ) == "api.minimax.io/v1")
    }
}

/// Captures only the requests and returns a minimal stream that lets every protocol parser finish normally.
private final class DispatchCaptureProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var storage: [URLRequest] = []

    static var captured: [URLRequest] { lock.withLock { storage } }
    static func reset() { lock.withLock { storage = [] } }

    static func readBody(_ stream: InputStream?) -> Data? {
        guard let stream else { return nil }
        stream.open()
        defer { stream.close() }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            result.append(buffer, count: count)
        }
        return result.isEmpty ? nil : result
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var copy = request
        if copy.httpBody == nil, let body = Self.readBody(request.httpBodyStream) { copy.httpBody = body }
        Self.lock.withLock { Self.storage.append(copy) }
        let url = request.url?.absoluteString ?? ""
        let payload: String
        if url.contains("/messages") {
            payload = """
            event: content_block_start
            data: {"index":0,"content_block":{"type":"text","text":""}}

            event: content_block_delta
            data: {"index":0,"delta":{"type":"text_delta","text":"ok"}}

            event: message_stop
            data: {}


            """
        } else {
            payload = """
            data: {"choices":[{"delta":{"content":"ok"}}]}

            data: {"choices":[{"delta":{},"finish_reason":"stop"}]}

            data: [DONE]


            """
        }
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
