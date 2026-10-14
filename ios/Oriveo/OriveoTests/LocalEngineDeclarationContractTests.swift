import Foundation
import Testing
@testable import Oriveo

/// A fake local engine: replays the recorded raw text of `engine-declarations.v1.json`.
/// Any path not listed returns 404 text/plain, matching how Ollama answers unknown paths in the recordings.
private final class LocalEngineRecordingProtocol: URLProtocol, @unchecked Sendable {
    struct Reply {
        let status: Int
        let contentType: String
        let body: Data
    }

    nonisolated(unsafe) static var routes: [String: Reply] = [:]
    /// Ollama `POST /api/show` replays the recording for the model named in the request body.
    nonisolated(unsafe) static var showReplies: [String: Reply] = [:]
    nonisolated(unsafe) static var unreachable = false
    nonisolated(unsafe) static var requested: [String] = []

    static func reset() {
        routes = [:]
        showReplies = [:]
        unreachable = false
        requested = []
    }

    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let method = request.httpMethod ?? "GET"
        let path = request.url?.path ?? ""
        Self.requested.append("\(method) \(path)")
        if Self.unreachable {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        var reply = Self.routes["\(method) \(path)"]
        if method == "POST", path == "/api/show",
           let body = Self.bodyData(of: request),
           let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
           let model = object["model"] as? String {
            reply = Self.showReplies[model]
        }
        // The connector's 1-token generation check is not part of the engine declaration and is not in the recordings: return a minimal successful generation.
        if method == "POST", path.hasSuffix("/chat/completions") {
            reply = Reply(
                status: 200,
                contentType: "application/json",
                body: Data(#"{"id":"x","object":"chat.completion","choices":[{"index":0,"message":{"role":"assistant","content":"ok"},"finish_reason":"length"}]}"#.utf8)
            )
        }
        let resolved = reply ?? Reply(status: 404, contentType: "text/plain", body: Data("404 page not found".utf8))
        let response = HTTPURLResponse(
            url: request.url!, statusCode: resolved.status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": resolved.contentType]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: resolved.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func bodyData(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

/// Cross-platform contract for local engine fingerprinting and per-model capability declarations (`shared/test-fixtures/local-engine/engine-expectations.v1.json`,
/// with the raw recordings in `engine-declarations.v1.json`). Expectations are driven by caseId; the input is the raw recording sent through a fake HTTP layer into the production connector,
/// and assertions target the actual output of production functions / the connector / `registerRelay` / the capability evidence facade.
@Suite("Relay 2.0 · local engine fingerprint and capability declaration", .serialized)
@MainActor
struct LocalEngineDeclarationContractTests {
    private static var retainedStates: [AppState] = []

    // MARK: - Fixtures

    private func fixture(_ name: String) throws -> [String: Any] {
        var cursor = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while cursor.path != "/" {
            let candidate = cursor
                .appendingPathComponent("shared")
                .appendingPathComponent("test-fixtures")
                .appendingPathComponent("local-engine")
                .appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: candidate.path) {
                let object = try JSONSerialization.jsonObject(with: Data(contentsOf: candidate))
                return try #require(object as? [String: Any])
            }
            cursor.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }

    private func expectations() throws -> [String: Any] { try fixture("engine-expectations.v1.json") }

    private func recordedEngine(_ engine: String) throws -> [String: Any] {
        let engines = try #require(try fixture("engine-declarations.v1.json")["engines"] as? [String: Any])
        return try #require(engines[engine] as? [String: Any])
    }

    private func records(engine: String, instance: String?) throws -> [[String: Any]] {
        let recorded = try recordedEngine(engine)
        if let instance {
            let instances = try #require(recorded["instances"] as? [String: Any])
            let chosen = try #require(instances[instance] as? [String: Any])
            return try #require(chosen["records"] as? [[String: Any]])
        }
        return try #require(recorded["records"] as? [[String: Any]])
    }

    private func reply(from record: [String: Any]) throws -> LocalEngineRecordingProtocol.Reply {
        let response = try #require(record["response"] as? [String: Any])
        let body: Data
        if let json = response["body"] {
            body = try JSONSerialization.data(withJSONObject: json)
        } else {
            body = Data((response["text"] as? String ?? "").utf8)
        }
        return .init(
            status: try #require(response["status"] as? Int),
            contentType: response["contentType"] as? String ?? "",
            body: body
        )
    }

    /// Install a set of recordings into the fake server; a nil `path` means all recordings of that engine (instance).
    private func install(engine: String, instance: String?, path: String?) throws {
        for record in try records(engine: engine, instance: instance) {
            let request = try #require(record["request"] as? [String: Any])
            let method = try #require(request["method"] as? String)
            let recordedPath = try #require(request["path"] as? String)
            if let path, path != recordedPath { continue }
            let reply = try reply(from: record)
            if method == "POST", recordedPath == "/api/show",
               let model = (request["body"] as? [String: Any])?["model"] as? String {
                LocalEngineRecordingProtocol.showReplies[model] = reply
            } else {
                LocalEngineRecordingProtocol.routes["\(method) \(recordedPath)"] = reply
            }
        }
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LocalEngineRecordingProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func makeState(session: URLSession) -> AppState {
        let state = AppState(
            sessionUID: "local-engine-declaration-tests-\(UUID().uuidString)",
            providerSession: session
        )
        state.providers = []
        state.conversations = []
        Self.retainedStates.append(state)
        return state
    }

    /// A recorded local engine connects through the production connector and is then turned into a connection by production `registerRelay`.
    private func connectAndRegister(
        engine: String,
        instance: String?,
        session: URLSession
    ) async throws -> (connection: LocalEngineConnection, provider: Provider) {
        LocalEngineRecordingProtocol.reset()
        try install(engine: engine, instance: instance, path: nil)
        let kind = try #require(LocalEngineKind(rawValue: engine))
        let endpoint = try #require(try recordedEngine(engine)["endpoint"] as? String)
        let connection = try await LocalEngineConnector.connect(
            engine: kind,
            endpoint: endpoint,
            securityMode: .localHTTP,
            session: session
        )
        let state = makeState(session: session)
        let provider = state.providerManager.registerRelay(
            name: "Local \(engine)",
            endpoint: connection.endpoint,
            apiKey: "",
            relayRequested: connection.requested,
            catalogModelIDs: connection.modelIDs,
            preferredModelID: connection.selectedModelID,
            runtimeMetadata: connection.runtimeMetadata
        )
        return (connection, provider)
    }

    /// In the fixture, both `null` and a missing key mean unknown.
    private func expectedBool(_ value: Any?) -> Bool? {
        value is NSNull ? nil : value as? Bool
    }

    // MARK: - RL2-ENGINE-01

    @Test("RL2-ENGINE-01 fingerprint: each fingerprint.cases entry, five GETs go through production functions to decide engine / generic / manual")
    func rl2Engine01FingerprintCases() async throws {
        let fingerprint = try #require(try expectations()["fingerprint"] as? [String: Any])
        let requestPaths = try #require(fingerprint["requests"] as? [String])
        #expect(LocalEngineFingerprint.requestPaths == requestPaths)
        let cases = try #require(fingerprint["cases"] as? [[String: Any]])
        #expect(cases.count == 9)
        let session = makeSession()

        for item in cases {
            let caseId = item["caseId"] as? String ?? "<no id>"
            let responses = try #require(item["responses"] as? [[String: Any]])
            if item["status"] as? String == "pending" {
                // For an engine with no recording, do not hand-write a response: assert it is still pending and skip.
                for response in responses {
                    let engine = try #require(response["engine"] as? String)
                    #expect(try recordedEngine(engine)["status"] as? String == "pending", "\(caseId)")
                }
                continue
            }

            LocalEngineRecordingProtocol.reset()
            LocalEngineRecordingProtocol.unreachable = item["unreachable"] as? Bool == true
            for response in responses {
                try install(
                    engine: try #require(response["engine"] as? String),
                    instance: response["instance"] as? String,
                    path: response["all"] as? Bool == true ? nil : try #require(response["path"] as? String)
                )
            }

            let outcome = await LocalEngineConnector.fingerprint(
                endpoint: "http://127.0.0.1:8080",
                securityMode: .localHTTP,
                session: session
            )
            let expect = try #require(item["expect"] as? [String: Any])
            let expectedOutcome: LocalEngineFingerprintOutcome
            switch try #require(expect["outcome"] as? String) {
            case "engine":
                let profile = try #require(expect["engineProfile"] as? String)
                #expect(expect["channel"] as? String == "chat", "\(caseId)")
                expectedOutcome = .engine(try #require(LocalEngineKind(rawValue: profile)), channel: .openaiChatCompletions)
            case "generic":
                #expect(expect["channel"] as? String == "chat", "\(caseId)")
                expectedOutcome = .generic(channel: .openaiChatCompletions)
            default:
                expectedOutcome = .manual
            }
            #expect(outcome == expectedOutcome, "\(caseId): actual \(outcome)")
            if case .engine(let kind, _) = outcome {
                #expect(outcome.engineProfile == kind.rawValue, "\(caseId)")
            } else {
                #expect(outcome.engineProfile == nil, "\(caseId): generic / manual carry no engineProfile")
            }
            // All five read-only GETs are sent: a status code alone never decides the result.
            let sent = Set(LocalEngineRecordingProtocol.requested)
            for path in requestPaths {
                #expect(sent.contains("GET \(path)"), "\(caseId): GET \(path) was not sent")
            }
            #expect(!sent.contains { !$0.hasPrefix("GET ") }, "\(caseId): fingerprinting sends only read-only GETs")
        }
    }

    // MARK: - RL2-ENGINE-02

    @Test("RL2-ENGINE-02 declaration: the production connector reads the raw recording, and models from registerRelay carry engineDeclaration; embeddings do not enter the chat catalog")
    func rl2Engine02DeclarationsFromConnector() async throws {
        let declarations = try #require(try expectations()["declarations"] as? [String: Any])
        let cases = try #require(declarations["cases"] as? [[String: Any]])
        #expect(cases.count == 11)
        let session = makeSession()

        var groups: [String: [[String: Any]]] = [:]
        var order: [String] = []
        for item in cases {
            let engine = try #require(item["engine"] as? String)
            guard engine != "vllm" else { continue }
            let key = [engine, item["instance"] as? String ?? ""].joined(separator: "|")
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(item)
        }
        #expect(order.count == 4)

        for key in order {
            let parts = key.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            let engine = parts[0]
            let instance = parts[1].isEmpty ? nil : parts[1]
            let (connection, provider) = try await connectAndRegister(engine: engine, instance: instance, session: session)

            for item in groups[key] ?? [] {
                let caseId = item["caseId"] as? String ?? "<no id>"
                let modelID = try #require(item["modelId"] as? String)
                let model = provider.allModels.first { $0.id == modelID }
                guard item["inChatCatalog"] as? Bool == true else {
                    #expect(!connection.modelIDs.contains(modelID), "\(caseId): should not enter the chat catalog")
                    #expect(model == nil, "\(caseId): should not be registered as a chat model")
                    continue
                }
                #expect(connection.modelIDs.contains(modelID), "\(caseId): should enter the chat catalog")
                let registered = try #require(model, "\(caseId)")
                let expect = try #require(item["expect"] as? [String: Any])
                let declared = registered.engineDeclaration
                #expect(declared?.image == expectedBool(expect["image"]), "\(caseId) image")
                #expect(declared?.toolCall == expectedBool(expect["toolCall"]), "\(caseId) toolCall")
                #expect(declared?.thinking == expectedBool(expect["thinking"]), "\(caseId) thinking")
                // The connection result itself also carries the same declaration.
                #expect(connection.runtimeMetadata[modelID]?.engineDeclaration == declared, "\(caseId)")
            }
        }

        // vLLM / Open WebUI read no response body for declarations: every model has an empty declaration.
        let vllm = try #require(cases.first { $0["caseId"] as? String == "vllm_declares_nothing" })
        let anyModel = try #require(vllm["modelId"] as? String)
        for engine in [LocalEngineKind.vllm, .openwebui] {
            let parsed = LocalEngineDeclarations.parse(
                engine: engine,
                catalogJSON: ["data": [["id": anyModel, "type": "vlm", "capabilities": ["tool_use"]]]],
                introspectionJSON: ["modalities": ["vision": true]]
            )
            #expect(parsed.isEmpty, "\(engine.rawValue)")
        }
    }

    @Test("RL2-ENGINE-02 consumer: image true -> vision_input supported and the photo-library entry visible; false -> unsupported and hidden; toolCall likewise")
    func rl2Engine02FacadeAndPhotoEntry() async throws {
        let session = makeSession()
        let (_, provider) = try await connectAndRegister(engine: "ollama", instance: nil, session: session)
        // ollama_smolvlm_vision: image true / toolCall false; ollama_qwen3_tools_and_thinking: image false / toolCall true.
        let rows: [(modelID: String, image: Bool, toolCall: Bool)] = [
            ("oriveo-fixture-smolvlm:latest", true, false),
            ("qwen3:0.6b", false, true),
        ]
        for row in rows {
            let model = try #require(provider.allModels.first { $0.id == row.modelID })
            #expect(model.engineDeclaration?.image == row.image)
            let projection = projection(provider: provider, model: model)
            let vision = projection.resolution(for: "vision_input")
            #expect(vision?.support == (row.image ? .supported : .unsupported), "\(row.modelID) vision_input")
            #expect(photoEntryVisible(provider: provider, model: model, projection: projection) == row.image, "\(row.modelID) photo-library entry")
            let tool = projection.resolution(for: "tool_call")
            #expect(tool?.support == (row.toolCall ? .supported : .unsupported), "\(row.modelID) tool_call")
        }

        // Legacy protection: the same model on a Relay connection without engineProfile does not have its declaration consumed and follows the existing rules.
        var plain = provider
        plain.relayRequested?.engineProfile = nil
        let smolvlm = try #require(plain.allModels.first { $0.id == "oriveo-fixture-smolvlm:latest" })
        let plainProjection = projection(provider: plain, model: smolvlm)
        #expect(plainProjection.resolution(for: "vision_input")?.support != .supported)
        #expect(plainProjection.resolution(for: "tool_call")?.support != .supported)
        // Rewritten from "a plain Relay with no declaration -> photo-library entry hidden": a Relay with unknown image support still shows it, and only negative evidence or a negative cache hides it.
        #expect(photoEntryVisible(provider: plain, model: smolvlm, projection: plainProjection))

        // When the send path has no Provider (the service writer), the model's own declaration decides.
        let apiBaseURL = try #require(provider.relayRequested?.resolvedAPIBaseURL)
        let request = URLRequest(url: try #require(URL(string: apiBaseURL + "/chat/completions")))
        for row in rows {
            let model = try #require(provider.allModels.first { $0.id == row.modelID })
            let identity = try #require(CapabilityEvidenceProductionAdapter.uiDispatchIdentity(
                provider: provider, model: model, partitionID: "local-engine-declaration-tests"
            ))
            let dispatch = CapabilityEvidenceRequestContext.$current.withValue(identity) {
                CapabilityEvidenceProductionAdapter.finalDispatchIntent(
                    request: request,
                    effectiveTransport: RelayTransport.openaiChatCompletions.rawValue,
                    model: model,
                    keys: ["vision_input", "tool_call"],
                    explicitKeys: ["vision_input"]
                )
            }
            #expect(dispatch.resolution(for: "vision_input")?.support == (row.image ? .supported : .unsupported), "\(row.modelID) send path vision_input")
            #expect(dispatch.permitsOutbound("vision_input") == row.image, "\(row.modelID) whether the send path carries images")
            #expect(dispatch.resolution(for: "tool_call")?.support == (row.toolCall ? .supported : .unsupported), "\(row.modelID) send path tool_call")
        }
    }

    @Test("RL2-ENGINE-01 fingerprint: 401 / 403 / policy rejection counts only as that entry not matching, and does not throw")
    func rl2Engine01RejectionsAreMisses() async throws {
        let session = makeSession()
        let denied = LocalEngineRecordingProtocol.Reply(
            status: 401, contentType: "application/json", body: Data(#"{"error":"unauthorized"}"#.utf8)
        )
        let forbidden = LocalEngineRecordingProtocol.Reply(
            status: 403, contentType: "application/json", body: Data(#"{"modalities":{"vision":true}}"#.utf8)
        )
        LocalEngineRecordingProtocol.reset()
        for path in LocalEngineFingerprint.requestPaths { LocalEngineRecordingProtocol.routes["GET \(path)"] = denied }
        #expect(await LocalEngineConnector.fingerprint(endpoint: "http://127.0.0.1:8080", securityMode: .localHTTP, session: session) == .manual)

        LocalEngineRecordingProtocol.reset()
        LocalEngineRecordingProtocol.routes["GET /props"] = forbidden
        try install(engine: "ollama", instance: nil, path: "/v1/models")
        #expect(await LocalEngineConnector.fingerprint(endpoint: "http://127.0.0.1:8080", securityMode: .localHTTP, session: session) == .generic(channel: .openaiChatCompletions))

        // Connection policy rejection (a plaintext address configured in public HTTPS mode): nothing is sent, and it lands on manual.
        LocalEngineRecordingProtocol.reset()
        try install(engine: "ollama", instance: nil, path: nil)
        #expect(await LocalEngineConnector.fingerprint(endpoint: "http://127.0.0.1:11434", securityMode: .remoteHTTPS, session: session) == .manual)
        #expect(LocalEngineRecordingProtocol.requested.isEmpty)
    }

    @Test("RL2-ENGINE-02 catalog refresh: a new declaration given this time is used, and if none is given the old one is kept")
    func rl2Engine02RefreshKeepsDeclaration() async throws {
        let session = makeSession()
        let (_, registered) = try await connectAndRegister(engine: "ollama", instance: nil, session: session)
        let state = try #require(Self.retainedStates.last)
        var provider = try #require(state.providers.first { $0.id == registered.id })
        let before = try #require(provider.allModels.first { $0.id == "qwen3:0.6b" }?.engineDeclaration)

        var withoutDeclaration = TestFactories.makeModel(id: "qwen3:0.6b")
        withoutDeclaration.engineDeclaration = nil
        var withNewDeclaration = TestFactories.makeModel(id: "tinyllama:latest")
        withNewDeclaration.engineDeclaration = EngineDeclaration(image: true)
        state.providerManager.applyRelaySyncResult(
            ProviderSyncResult(models: [withoutDeclaration, withNewDeclaration]),
            to: &provider
        )
        #expect(provider.catalogModels.first { $0.id == "qwen3:0.6b" }?.engineDeclaration == before)
        // Enabled models likewise keep the old declaration by id.
        #expect(provider.models.first { $0.id == "qwen3:0.6b" }?.engineDeclaration == before)
        #expect(provider.catalogModels.first { $0.id == "tinyllama:latest" }?.engineDeclaration == EngineDeclaration(image: true))
    }

    @Test("RL2-ENGINE-02 re-detect: the production connector rereads declarations and replaces them by id, without touching relayCapabilityOverrides and without generation verification")
    func rl2Engine02RedetectRefreshesDeclarations() async throws {
        let session = makeSession()
        let (connection, registered) = try await connectAndRegister(engine: "ollama", instance: nil, session: session)
        let state = try #require(Self.retainedStates.last)
        let declared = connection.runtimeMetadata.compactMapValues(\.engineDeclaration)
        #expect(!declared.isEmpty)

        func flipped(_ value: Bool?) -> Bool? { value.map { !$0 } ?? true }
        func staled(_ models: [AIModel]) -> [AIModel] {
            models.map { model in
                var out = model
                guard let real = declared[model.id] else { return out }
                out.engineDeclaration = EngineDeclaration(
                    image: flipped(real.image), toolCall: flipped(real.toolCall), thinking: flipped(real.thinking)
                )
                out.relayCapabilityOverrides = RelayCapabilityOverrides(image: false, toolCall: false)
                return out
            }
        }
        var provider = try #require(state.provider(for: registered.id))
        provider.models = staled(provider.models)
        provider.catalogModels = staled(provider.catalogModels)
        state.providerManager.updateProvider(provider)

        LocalEngineRecordingProtocol.requested = []
        await state.providerManager.redetectRelayModels(providerID: registered.id)

        let refreshed = try #require(state.provider(for: registered.id))
        for model in refreshed.models + refreshed.catalogModels {
            guard let real = declared[model.id] else { continue }
            #expect(model.engineDeclaration == real, "\(model.id) declaration replaced by the connector's reread")
            #expect(model.relayCapabilityOverrides == RelayCapabilityOverrides(image: false, toolCall: false), "\(model.id) overrides untouched")
        }
        // Local connections only clear and do not re-probe: no 1-token generation.
        #expect(!LocalEngineRecordingProtocol.requested.contains { $0.hasPrefix("POST") && $0.hasSuffix("/chat/completions") })
    }

    @Test("RL2-ENGINE-02 tool calling: engineDeclaration.toolCall overrides the model's old toolCall; connections without an engineProfile still read model.toolCall")
    func rl2Engine02ToolDeclarationOverridesLegacyToolCall() async throws {
        let session = makeSession()
        let (_, provider) = try await connectAndRegister(engine: "ollama", instance: nil, session: session)
        // ollama_qwen3_tools_and_thinking: toolCall true; ollama_smolvlm_vision: toolCall false.
        let rows: [(modelID: String, toolCall: Bool)] = [
            ("qwen3:0.6b", true),
            ("oriveo-fixture-smolvlm:latest", false),
        ]
        for row in rows {
            var model = try #require(provider.allModels.first { $0.id == row.modelID })
            #expect(model.engineDeclaration?.toolCall == row.toolCall)
            // The old source gives the opposite conclusion, and the declaration must override it.
            model.toolCall = !row.toolCall
            let verdict = ToolCallCapabilityPolicy.catalogVerdict(provider: provider, model: model)
            #expect(verdict.verdict == row.toolCall, "\(row.modelID)")
            #expect(verdict.source == .relayDeclaration, "\(row.modelID)")

            var plain = provider
            plain.relayRequested?.engineProfile = nil
            #expect(ToolCallCapabilityPolicy.catalogVerdict(provider: plain, model: model).verdict == !row.toolCall,
                    "\(row.modelID) legacy Relay unchanged")
        }
    }

    // MARK: - Consumer projection

    /// Assembled the same way as ChatView: `uiDispatchIdentity` -> `capabilityProjection`.
    private func projection(provider: Provider, model: AIModel) -> CapabilityEvidenceProjection {
        CapabilityEvidenceProductionAdapter.capabilityProjection(
            provider: provider,
            model: model,
            identity: CapabilityEvidenceProductionAdapter.uiDispatchIdentity(
                provider: provider, model: model, partitionID: "local-engine-declaration-tests"
            ),
            keys: ["vision_input", "tool_call"]
        )
    }

    /// Photo-library entry: ChatView's visibility criterion -> ChatComposerBar's image-entry criterion; both are production static functions.
    private func photoEntryVisible(
        provider: Provider,
        model: AIModel,
        projection: CapabilityEvidenceProjection
    ) -> Bool {
        let visibleKeys = ChatView.visibleCapabilityKeys(
            provider: provider, model: model, projection: projection,
            negativeCache: RelayNegativeCache(defaults: UserDefaults(suiteName: "local-engine-\(UUID().uuidString)")!)
        )
        return ChatComposerBar.supportsImageAttachment(
            provider: provider, model: model, visibleCapabilityKeys: visibleKeys
        )
    }
}
