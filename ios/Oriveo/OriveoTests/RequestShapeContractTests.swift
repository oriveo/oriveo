import Foundation
import Testing
@testable import Oriveo

final class RequestShapeContractURLProtocol: URLProtocol, @unchecked Sendable {
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

@Suite("request_shape_contract.v1 (iOS)", .serialized)
struct RequestShapeContractTests {
    private static let evidenceRevision = "request-shape-fixture-v1"

    @Test("shared request-shape fixture constrains iOS provider requests")
    func requestShapeContract() async throws {
        let contract = try Self.loadContract()
        #expect(contract.cases.count == 74, "fixture cases count")

        UnsupportedParamCache.shared.resetForTesting()
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(
            json: Self.metadataJSONString(contract), metadataETag: Self.evidenceRevision
        )
        defer {
            RequestShapeContractURLProtocol.requestHandler = nil
            UnsupportedParamCache.shared.resetForTesting()
        }

        for contractCase in contract.cases {
            guard let captured = await Self.captureRequest(for: contractCase) else { continue }
            let hasModelControlIntent = !contractCase.intent.imageGen
                && (contractCase.intent.webSearch
                    || contractCase.intent.generationOverrides?.isEmpty == false
                    || contractCase.intent.reasoningMode != nil)
            if !hasModelControlIntent {
                try Self.assertRequest(
                    captured, matches: contractCase.expect, caseId: contractCase.caseId
                )
                continue
            }
            let baseline = ContractCase(
                caseId: "\(contractCase.caseId).r3_baseline",
                intent: .init(
                    providerKind: contractCase.intent.providerKind,
                    modelId: contractCase.intent.modelId,
                    reasoningMode: "automatic",
                    webSearch: false,
                    imageGen: contractCase.intent.imageGen,
                    generationOverrides: nil
                ),
                expect: contractCase.expect
            )
            guard let baselineRequest = await Self.captureRequest(for: baseline) else { continue }
            try Self.assertTransportEnvelope(
                captured, matches: contractCase.expect, caseId: contractCase.caseId
            )
            try Self.assertSameTransportAndBody(
                captured, baselineRequest,
                caseId: contractCase.caseId
            )
        }
    }

    @Test("capability without profile hides UI gate")
    func uiGates() async throws {
        let contract = try Self.loadContract()
        #expect(contract.uiCases.count == 2, "fixture uiCases count")

        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(
            json: Self.metadataJSONString(contract), metadataETag: Self.evidenceRevision
        )

        for uiCase in contract.uiCases {
            guard let kind = Self.providerKind(uiCase.intent.providerKind) else {
                Issue.record("Unknown uiCase provider: \(uiCase.intent.providerKind)")
                continue
            }
            let model = await CatalogModelBuilder.buildCatalogModel(
                providerKind: kind,
                runtimeModelId: uiCase.intent.modelId,
                fallbackName: uiCase.intent.modelId
            )

            let visible: Bool
            switch uiCase.intent.capability {
            case "web":
                visible = model.supportsWebSearchControl
            case "reasoning":
                visible = model.capabilities.contains(.reasoning) && model.reasoningModeAvailable
            default:
                Issue.record("Unknown uiCase capability: \(uiCase.intent.capability)")
                continue
            }
            #expect(visible == uiCase.expect.visible, "\(uiCase.caseId) visible gate")
        }
    }

    @Test("every imageGen profile has a case and every requestDefault is asserted")
    func imageGenProfileDefenseLines() throws {
        let contract = try Self.loadContract()
        let metadata = try #require(contract.metadata.foundationObject as? [String: Any])
        let profiles = (metadata["profiles"] as? [String: Any]) ?? [:]
        let imageGenProfiles = (profiles["imageGen"] as? [String: Any]) ?? [:]
        let providers = (metadata["providers"] as? [String: Any]) ?? [:]
        #expect(!imageGenProfiles.isEmpty, "fixture must define imageGen profiles")

        func imageGenProfileName(providerKind: String, modelId: String) -> String? {
            guard let provider = providers[providerKind] as? [String: Any],
                  let models = provider["models"] as? [String: Any],
                  let model = models[modelId] as? [String: Any],
                  let modelProfiles = model["profiles"] as? [String: Any] else { return nil }
            return modelProfiles["imageGen"] as? String
        }

        var casesByProfile: [String: [ContractCase]] = [:]
        for contractCase in contract.cases {
            guard let name = imageGenProfileName(
                providerKind: contractCase.intent.providerKind,
                modelId: contractCase.intent.modelId
            ) else { continue }
            casesByProfile[name, default: []].append(contractCase)
        }

        for (name, defAny) in imageGenProfiles {
            let cases = casesByProfile[name] ?? []
            #expect(!cases.isEmpty, "imageGen profile \(name) has no contract case")

            guard let def = defAny as? [String: Any],
                  let requestDefaults = def["requestDefaults"] as? [String: Any],
                  !requestDefaults.isEmpty else { continue }
            let prefix = (def["route"] as? String) == "dashscope_multimodal" ? "parameters." : ""
            for contractCase in cases {
                let includeKeys = Set(contractCase.expect.bodyIncludes.keys)
                for key in requestDefaults.keys {
                    #expect(
                        includeKeys.contains(prefix + key),
                        "\(contractCase.caseId): requestDefaults key \(prefix + key) not asserted in bodyIncludes"
                    )
                }
            }
        }
    }

    @Test("every ProviderKind either ships generation parameters or is explicitly exempt")
    func generationOutboundUniverse() throws {
        let contract = try Self.loadContract()
        let universe = contract.generationProviderKindUniverse
        #expect(!universe.isEmpty, "fixture must declare generationProviderKindUniverse")

        var mapped: Set<ProviderKind> = []
        for raw in universe {
            guard let kind = Self.providerKind(raw) else {
                Issue.record("generationProviderKindUniverse contains an iOS-unknown ProviderKind: \(raw)")
                continue
            }
            mapped.insert(kind)
        }
        #expect(mapped == Set(ProviderKind.allCases))
        #expect(mapped.count == universe.count)

        let covered = Set(
            contract.cases
                .filter { ($0.intent.generationOverrides?.isEmpty == false) }
                .map(\.intent.providerKind)
        )
        var exemptReasons: [String: String] = [:]
        for exemption in contract.generationOutboundExemptions {
            #expect(
                universe.contains(exemption.providerKind),
                "Exemption-list \(exemption.providerKind) is not in the ProviderKind universe"
            )
            #expect(
                !exemption.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "\(exemption.providerKind) exemption must include a reason"
            )
            exemptReasons[exemption.providerKind] = exemption.reason
        }

        for kind in universe {
            let hasCase = covered.contains(kind)
            let isExempt = exemptReasons[kind] != nil
            #expect(
                hasCase != isExempt,
                "\(kind): must satisfy exactly one — a case with generationOverrides, or an exemption (hasCase=\(hasCase) isExempt=\(isExempt))"
            )
        }

        for kind in covered {
            #expect(universe.contains(kind))
        }
    }

    @Test("every asserted generation parameter is actually shipped for that model")
    func generationCasesMatchShippedProfile() throws {
        let contract = try Self.loadContract()
        let metadata = try #require(contract.metadata.foundationObject as? [String: Any])
        let providers = (metadata["providers"] as? [String: Any]) ?? [:]
        let templates = ((metadata["profiles"] as? [String: Any])?["generation"] as? [String: Any])
            .flatMap { $0["templates"] as? [String: Any] } ?? [:]
        #expect(!templates.isEmpty, "fixture must define profiles.generation.templates")

        for contractCase in contract.cases {
            guard let overrides = contractCase.intent.generationOverrides, !overrides.isEmpty else { continue }
            let caseId = contractCase.caseId
            guard let provider = providers[contractCase.intent.providerKind] as? [String: Any],
                  let models = provider["models"] as? [String: Any],
                  let model = models[contractCase.intent.modelId] as? [String: Any],
                  let generation = (model["profiles"] as? [String: Any])?["generation"] as? [String: Any] else {
                Issue.record("\(caseId): fixture did not issue profiles.generation for this model")
                continue
            }
            guard let templateName = generation["template"] as? String,
                  let template = templates[templateName] as? [String: Any],
                  let wire = template["wire"] as? [String: Any] else {
                Issue.record("\(caseId): generation template is missing or has no wire table")
                continue
            }
            let shipped = Set(
                ((generation["parameters"] as? [[String: Any]]) ?? []).compactMap { $0["id"] as? String }
            )
            for id in overrides.keys {
                #expect(shipped.contains(id))
                #expect(
                    (wire[id] as? String)?.isEmpty == false,
                    "\(caseId): template \(templateName) has no wire path for \(id)"
                )
            }
        }
    }

    // MARK: - Capture

    private static func captureRequest(for contractCase: ContractCase) async -> URLRequest? {
        let session = makeSession()
        nonisolated(unsafe) var captured: URLRequest?
        RequestShapeContractURLProtocol.requestHandler = { request in
            if captured == nil {
                captured = request
            }
            let url = request.url ?? URL(string: "https://contract.invalid")!
            return (
                HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: [
                    "Content-Type": "text/event-stream"
                ])!,
                streamResponse(for: contractCase.intent.providerKind)
            )
        }
        defer { RequestShapeContractURLProtocol.requestHandler = nil }

        var driveError: Error?
        do {
            try await drive(contractCase, session: session)
        } catch {
            driveError = error
        }

        if captured == nil {
            let detail = driveError.map { " (error: \($0))" } ?? ""
            Issue.record("case \(contractCase.caseId) did not issue a request\(detail)")
        }
        return captured
    }

    private static func drive(_ contractCase: ContractCase, session: URLSession) async throws {
        let intent = contractCase.intent
        let message = makeMessage(providerKind: intent.providerKind, modelID: intent.modelId)
        let mode = reasoningMode(intent.reasoningMode)
        let key = "contract-test-key"
        var options = ChatRequestOptions()
        if let overrides = intent.generationOverrides, !overrides.isEmpty {
            options.generationParameters = GenerationParameterOverrides(values: overrides)
        }
        let kind = try #require(providerKind(intent.providerKind))
        let evidenceModel = MetadataClient.shared.syncCurrentCapabilityEvidenceModel(
            TestFactories.makeModel(id: intent.modelId), providerKind: kind
        )
        options.capabilityEvidenceModel = evidenceModel
        let provider = TestFactories.makeProvider(kind: kind, models: [evidenceModel])
        let identity = CapabilityEvidenceRequestIdentity.make(
            provider: provider, model: evidenceModel, partitionID: "request-shape-user",
            hasExplicitValue: true, metadataETag: evidenceRevision
        )
        return try await CapabilityEvidenceRequestContext.$current.withValue(identity) {
        let imageDispatch = try await BaseAPIService(session: session).dispatchOfficialImageGeneration(
            providerKind: kind,
            userBaseURL: nil,
            apiKey: key,
            modelID: intent.modelId,
            messages: [message],
            selectedModelSupportsImageGeneration: intent.imageGen
        )
        let providerSpecificImageRoute: ImageGenRoute?
        switch imageDispatch {
        case .handled:
            return
        case .notApplicable:
            providerSpecificImageRoute = nil
        case let .providerSpecific(route):
            providerSpecificImageRoute = route
        }

        switch intent.providerKind {
        case "grok":
            let service = GrokService(session: session)
            for try await _ in service.sendMessageStream(
                apiKey: key, modelID: intent.modelId, messages: [message],
                reasoningMode: mode, webSearchEnabled: intent.webSearch,
                requestOptions: options
            ) {}

        case "openAI":
            let service = OpenAIService(session: session)
            for try await _ in service.sendMessageStream(
                apiKey: key, modelID: intent.modelId, messages: [message],
                reasoningMode: mode,
                webSearchEnabled: intent.webSearch,
                supportsImageGeneration: intent.imageGen,
                requestOptions: options
            ) {}

        case "anthropic":
            let service = AnthropicService(session: session)
            for try await _ in service.sendMessageStream(
                apiKey: key, modelID: intent.modelId, messages: [message],
                reasoningMode: mode,
                webSearchEnabled: intent.webSearch,
                requestOptions: options
            ) {}

        case "gemini":
            let service = GeminiService(session: session)
            for try await _ in service.sendMessageStream(
                apiKey: key, modelID: intent.modelId, messages: [message],
                reasoningMode: mode,
                webSearchEnabled: intent.webSearch,
                supportsImageGen: intent.imageGen,
                requestOptions: options
            ) {}

        case "deepseek":
            let service = DeepSeekService(session: session)
            for try await _ in service.sendMessageStream(
                apiKey: key, modelID: intent.modelId, messages: [message],
                reasoningMode: mode, requestOptions: options
            ) {}

        case "moonshot":
            let service = MoonshotService(session: session)
            for try await _ in service.sendMessageStream(
                apiKey: key, modelID: intent.modelId, messages: [message],
                baseURL: nil,
                reasoningMode: mode,
                webSearchEnabled: intent.webSearch,
                requestOptions: options
            ) {}

        case "mistral":
            let service = MistralService(session: session)
            for try await _ in service.sendMessageStream(
                apiKey: key, modelID: intent.modelId, messages: [message],
                reasoningMode: mode, requestOptions: options
            ) {}

        case "qwen":
            let service = QwenService(session: session)
            if providerSpecificImageRoute == .dashscopeMultimodal {
                _ = try await service.sendMessage(
                    apiKey: key, modelID: intent.modelId, messages: [message],
                    baseURL: nil, reasoningMode: mode, requestOptions: options
                )
            } else {
                for try await _ in service.sendMessageStream(
                    apiKey: key, modelID: intent.modelId, messages: [message],
                    baseURL: nil, reasoningMode: mode,
                    webSearchEnabled: intent.webSearch,
                    requestOptions: options
                ) {}
            }

        case "zhipu":
            let service = ZhipuService(session: session)
            for try await _ in service.sendMessageStream(
                apiKey: key, modelID: intent.modelId, messages: [message],
                reasoningMode: mode,
                webSearchEnabled: intent.webSearch,
                requestOptions: options
            ) {}

        case "miniMax":
            let service = MiniMaxService(session: session)
            if providerSpecificImageRoute == .minimaxImageGeneration {
                _ = try await service.sendMessage(
                    apiKey: key, modelID: intent.modelId, messages: [message],
                    baseURL: nil, reasoningMode: mode, requestOptions: options
                )
            } else {
                for try await _ in service.sendMessageStream(
                    apiKey: key, modelID: intent.modelId, messages: [message],
                    baseURL: nil, reasoningMode: mode, requestOptions: options
                ) {}
            }

        case "siliconFlow":
            let service = SiliconFlowService(session: session)
            for try await _ in service.sendMessageStream(
                apiKey: key, modelID: intent.modelId, messages: [message],
                reasoningMode: mode, requestOptions: options
            ) {}

        case "openRouter":
            let service = OpenRouterService(session: session)
            for try await _ in service.sendMessageStream(
                apiKey: key, modelID: intent.modelId, messages: [message],
                reasoningMode: mode,
                webSearchEnabled: intent.webSearch,
                supportsImageGen: intent.imageGen,
                requestOptions: options
            ) {}

        case "groq":
            let service = GroqService(session: session)
            for try await _ in service.sendMessageStream(
                apiKey: key, modelID: intent.modelId, messages: [message],
                reasoningMode: mode, requestOptions: options
            ) {}

        case "togetherAI":
            let service = TogetherService(session: session)
            for try await _ in service.sendMessageStream(
                apiKey: key, modelID: intent.modelId, messages: [message],
                reasoningMode: mode, requestOptions: options
            ) {}

        case "fireworksAI":
            let service = FireworksService(session: session)
            for try await _ in service.sendMessageStream(
                apiKey: key, modelID: intent.modelId, messages: [message],
                reasoningMode: mode, requestOptions: options
            ) {}

        default:
            Issue.record("Unsupported request-shape contract provider: \(intent.providerKind)")
        }
        }
    }

    private static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RequestShapeContractURLProtocol.self]
        return URLSession(configuration: config)
    }

    private static func providerKind(_ raw: String) -> ProviderKind? {
        switch raw {
        case "togetherAI": return .together
        case "fireworksAI": return .fireworks
        default: return ProviderKind(rawValue: raw)
        }
    }

    private static func makeMessage(providerKind rawKind: String, modelID: String) -> ChatMessage {
        let kind = providerKind(rawKind) ?? .grok
        return ChatMessage(
            id: UUID(),
            role: .user,
            text: "hello",
            providerKind: kind,
            providerName: kind.displayName,
            modelName: modelID,
            state: .delivered
        )
    }

    private static func streamResponse(for providerKind: String) -> Data {
        let body: String
        switch providerKind {
        case "grok":
            body = """
            data: {"type":"response.output_text.delta","delta":"hi"}
            data: {"type":"response.completed","response":{"usage":{"input_tokens":1,"output_tokens":1}}}
            data: [DONE]

            """
        case "anthropic":
            body = """
            event: message_start
            data: {"type":"message_start","message":{"usage":{"input_tokens":1}}}

            event: content_block_delta
            data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"hi"}}

            event: message_delta
            data: {"type":"message_delta","usage":{"output_tokens":1}}

            event: message_stop
            data: {"type":"message_stop"}

            """
        case "gemini":
            body = """
            data: {"candidates":[{"content":{"parts":[{"text":"hi"}]},"finishReason":"STOP"}],"usageMetadata":{"promptTokenCount":1,"candidatesTokenCount":1}}

            """
        default:
            body = """
            data: {"choices":[{"delta":{"content":"hi"}}],"usage":{"prompt_tokens":1,"completion_tokens":1}}
            data: [DONE]

            """
        }
        return Data(body.utf8)
    }

    // MARK: - Assertions

    private static func assertRequest(
        _ request: URLRequest,
        matches expectation: Expectation,
        caseId: String
    ) throws {
        let url = try #require(request.url)
        #expect(url.path == expectation.endpointPath, "\(caseId) endpointPath")

        for (name, expected) in expectation.headersInclude {
            let actual = request.value(forHTTPHeaderField: name)
            if expected.isWildcard {
                #expect(actual?.isEmpty == false, "\(caseId) header \(name)")
            } else {
                #expect(actual == expected.stringValue, "\(caseId) header \(name)")
            }
        }

        let queryItems = Set(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.map(\.name) ?? [])
        for name in expectation.queryExcludes {
            #expect(!queryItems.contains(name), "\(caseId) query \(name) must be absent")
        }

        let maybeBodyObject = try requestBodyObject(request)
        let bodyObject = try #require(maybeBodyObject, "\(caseId) request body")
        for (path, expected) in expectation.bodyIncludes {
            let actual = value(at: path, in: bodyObject)
            if expected.isWildcard {
                #expect(actual != nil, "\(caseId) body \(path)")
            } else {
                #expect(
                    jsonValue(actual) == expected.canonicalValue,
                    "\(caseId) body \(path): actual=\(jsonValue(actual) ?? "<absent>") expected=\(expected.canonicalValue)"
                )
            }
        }
        for path in expectation.bodyExcludes {
            #expect(
                value(at: path, in: bodyObject) == nil,
                "\(caseId) body \(path) must be absent, actual=\(jsonValue(value(at: path, in: bodyObject)) ?? "<absent>")"
            )
        }
    }

    private static func assertTransportEnvelope(
        _ request: URLRequest,
        matches expectation: Expectation,
        caseId: String
    ) throws {
        let url = try #require(request.url)
        #expect(url.path == expectation.endpointPath, "\(caseId) endpointPath")
        for (name, expected) in expectation.headersInclude {
            let actual = request.value(forHTTPHeaderField: name)
            if expected.isWildcard {
                #expect(actual?.isEmpty == false, "\(caseId) header \(name)")
            } else {
                #expect(actual == expected.stringValue, "\(caseId) header \(name)")
            }
        }
        let queryItems = Set(URLComponents(
            url: url, resolvingAgainstBaseURL: false
        )?.queryItems?.map(\.name) ?? [])
        for name in expectation.queryExcludes {
            #expect(!queryItems.contains(name), "\(caseId) query \(name) must be absent")
        }
    }

    /// No exact runtime means every legacy reasoning/web/generation intent is inert. Comparing
    /// against a production-built baseline avoids a provider-specific field blacklist and catches
    /// any future legacy writer, including fields not yet named by this test.
    private static func assertSameTransportAndBody(
        _ requested: URLRequest,
        _ baseline: URLRequest,
        caseId: String
    ) throws {
        #expect(requested.url?.path == baseline.url?.path, "\(caseId) transport changed by legacy intent")
        let requestedBody = try #require(try requestBodyObject(requested), "\(caseId) requested body")
        let baselineBody = try #require(try requestBodyObject(baseline), "\(caseId) baseline body")
        #expect(
            jsonValue(requestedBody) == jsonValue(baselineBody),
            "\(caseId) legacy intent changed final body without an exact runtime"
        )
    }

    private static func requestBodyObject(_ request: URLRequest) throws -> Any? {
        let data: Data?
        if let body = request.httpBody {
            data = body
        } else if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = Data()
            let pointer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
            defer { pointer.deallocate() }
            while stream.hasBytesAvailable {
                let count = stream.read(pointer, maxLength: 4096)
                if count <= 0 { break }
                buffer.append(pointer, count: count)
            }
            data = buffer
        } else {
            data = nil
        }

        guard let data else { return nil }
        return try JSONSerialization.jsonObject(with: data)
    }

    private static func value(at path: String, in object: Any) -> Any? {
        var current: Any? = object
        for component in path.split(separator: ".").map(String.init) {
            if let dict = current as? [String: Any] {
                current = dict[component]
            } else if let array = current as? [Any], let index = Int(component), array.indices.contains(index) {
                current = array[index]
            } else {
                return nil
            }
        }
        return current
    }

    private static func jsonValue(_ value: Any?) -> String? {
        guard let value else { return nil }
        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) {
            return String(data: data, encoding: .utf8)
        }
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return String(describing: value)
    }

    // MARK: - Fixture loading

    private static func loadContract() throws -> ContractFile {
        let url = findContractURL()
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(ContractFile.self, from: data)
    }

    private static func findContractURL() -> URL {
        let startURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let relativeComponents = ["shared", "model-contracts", "request_shape_contract.v1.json"]

        var currentURL = startURL
        while true {
            let candidate = relativeComponents.reduce(currentURL) { partial, component in
                partial.appendingPathComponent(component)
            }
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            let parentURL = currentURL.deletingLastPathComponent()
            if parentURL.path == currentURL.path { break }
            currentURL = parentURL
        }

        preconditionFailure("Unable to locate request_shape_contract.v1.json from \(startURL.path)")
    }

    private static func metadataJSONString(_ contract: ContractFile) throws -> String {
        var root = try #require(contract.metadata.foundationObject as? [String: Any])
        var providers = try #require(root["providers"] as? [String: Any])
        let grouped = Dictionary(grouping: contract.cases) {
            "\($0.intent.providerKind)|\($0.intent.modelId)"
        }
        for (compoundKey, cases) in grouped {
            let parts = compoundKey.split(separator: "|", maxSplits: 1).map(String.init)
            guard parts.count == 2,
                  var provider = providers[parts[0]] as? [String: Any],
                  var models = provider["models"] as? [String: Any],
                  var model = models[parts[1]] as? [String: Any],
                  let kind = providerKind(parts[0]) else { continue }
            let transport = (model["transport"] as? String) ?? {
                switch kind {
                case .gemini: return "gemini_content"
                default: return ""
                }
            }()
            guard CapabilityEvidenceFacade.isConcreteTransport(transport) else { continue }
            model["transport"] = transport

            var keys: Set<String> = []
            if cases.contains(where: { $0.intent.webSearch }) { keys.insert("web_search") }
            if cases.contains(where: { $0.intent.reasoningMode != nil })
                || ((model["profiles"] as? [String: Any])?["reasoning"] != nil) {
                keys.formUnion(ReasoningMode.allCases.filter { $0 != .automatic }.map {
                    "reasoning_level/\($0.rawValue)"
                })
            }
            var generationIDs: Set<String> = []
            for item in cases {
                if let overrides = item.intent.generationOverrides {
                    generationIDs.formUnion(overrides.keys)
                }
            }
            keys.formUnion(generationIDs.map { "generation_parameter/\($0)" })

            if !generationIDs.isEmpty,
               var profiles = model["profiles"] as? [String: Any],
               var generation = profiles["generation"] as? [String: Any] {
                generation["revision"] = evidenceRevision
                profiles["generation"] = generation
                model["profiles"] = profiles
            }
            let candidates: [[String: Any]] = keys.sorted().map { key in
                var candidate: [String: Any] = [
                    "key": key,
                    "support": "supported",
                    "source": "server_profile",
                    "grade": "effect_verified",
                    "scope": "provider_model_transport",
                    "providerKind": kind.rawValue,
                    "modelId": parts[1],
                    "transport": transport,
                ]
                if key.hasPrefix("generation_parameter/") {
                    candidate["generationRevision"] = evidenceRevision
                }
                return candidate
            }
            model["capabilityEvidenceView"] = [
                "schema": "capability-evidence-view/v1",
                "candidates": candidates,
            ]
            models[parts[1]] = model
            provider["models"] = models
            providers[parts[0]] = provider
        }
        root["providers"] = providers
        let data = try JSONSerialization.data(
            withJSONObject: root,
            options: [.sortedKeys]
        )
        return String(data: data, encoding: .utf8)!
    }

    private static func reasoningMode(_ raw: String?) -> ReasoningMode {
        switch raw {
        case "fast": return .fast
        case "balanced": return .balanced
        case "deep": return .deep
        case "max": return .max
        default: return .automatic
        }
    }

    // MARK: - Decode schema

    fileprivate struct ContractFile: Decodable {
        let version: Int
        let metadata: JSONValue
        let cases: [ContractCase]
        let uiCases: [UIContractCase]
        let generationProviderKindUniverse: [String]
        let generationOutboundExemptions: [GenerationExemption]

        enum CodingKeys: String, CodingKey {
            case version, metadata, cases, uiCases
            case generationProviderKindUniverse, generationOutboundExemptions
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = try container.decode(Int.self, forKey: .version)
            metadata = try container.decode(JSONValue.self, forKey: .metadata)
            cases = try container.decode([ContractCase].self, forKey: .cases)
            uiCases = try container.decodeIfPresent([UIContractCase].self, forKey: .uiCases) ?? []
            generationProviderKindUniverse = try container.decodeIfPresent(
                [String].self,
                forKey: .generationProviderKindUniverse
            ) ?? []
            generationOutboundExemptions = try container.decodeIfPresent(
                [GenerationExemption].self,
                forKey: .generationOutboundExemptions
            ) ?? []
        }
    }

    fileprivate struct GenerationExemption: Decodable {
        let providerKind: String
        let reason: String
    }

    fileprivate struct ContractCase: Decodable {
        let caseId: String
        let intent: Intent
        let expect: Expectation

        init(caseId: String, intent: Intent, expect: Expectation) {
            self.caseId = caseId
            self.intent = intent
            self.expect = expect
        }
    }

    fileprivate struct Intent: Decodable {
        let providerKind: String
        let modelId: String
        let reasoningMode: String?
        let webSearch: Bool
        let imageGen: Bool
        let generationOverrides: [String: GenerationParameterOverride]?

        init(
            providerKind: String,
            modelId: String,
            reasoningMode: String?,
            webSearch: Bool,
            imageGen: Bool,
            generationOverrides: [String: GenerationParameterOverride]?
        ) {
            self.providerKind = providerKind
            self.modelId = modelId
            self.reasoningMode = reasoningMode
            self.webSearch = webSearch
            self.imageGen = imageGen
            self.generationOverrides = generationOverrides
        }
    }

    fileprivate struct UIContractCase: Decodable {
        let caseId: String
        let intent: UIIntent
        let expect: UIExpectation

        struct UIIntent: Decodable {
            let providerKind: String
            let modelId: String
            let capability: String
        }

        struct UIExpectation: Decodable {
            let visible: Bool
        }
    }

    fileprivate struct Expectation: Decodable {
        let endpointPath: String
        let headersInclude: [String: JSONValue]
        let queryExcludes: [String]
        let bodyIncludes: [String: JSONValue]
        let bodyExcludes: [String]

        enum CodingKeys: String, CodingKey {
            case endpointPath, headersInclude, queryExcludes, bodyIncludes, bodyExcludes
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            endpointPath = try container.decode(String.self, forKey: .endpointPath)
            headersInclude = try container.decodeIfPresent([String: JSONValue].self, forKey: .headersInclude) ?? [:]
            queryExcludes = try container.decodeIfPresent([String].self, forKey: .queryExcludes) ?? []
            bodyIncludes = try container.decodeIfPresent([String: JSONValue].self, forKey: .bodyIncludes) ?? [:]
            bodyExcludes = try container.decodeIfPresent([String].self, forKey: .bodyExcludes) ?? []
        }
    }

    fileprivate indirect enum JSONValue: Decodable {
        case null
        case bool(Bool)
        case int(Int)
        case double(Double)
        case string(String)
        case array([JSONValue])
        case object([String: JSONValue])

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() {
                self = .null
            } else if let bool = try? container.decode(Bool.self) {
                self = .bool(bool)
            } else if let int = try? container.decode(Int.self) {
                self = .int(int)
            } else if let double = try? container.decode(Double.self) {
                self = .double(double)
            } else if let string = try? container.decode(String.self) {
                self = .string(string)
            } else if let array = try? container.decode([JSONValue].self) {
                self = .array(array)
            } else {
                self = .object(try container.decode([String: JSONValue].self))
            }
        }

        var foundationObject: Any {
            switch self {
            case .null: return NSNull()
            case .bool(let value): return value
            case .int(let value): return value
            case .double(let value): return value
            case .string(let value): return value
            case .array(let values): return values.map(\.foundationObject)
            case .object(let values):
                return values.mapValues(\.foundationObject)
            }
        }

        var isWildcard: Bool {
            if case .string("*") = self { return true }
            return false
        }

        var stringValue: String? {
            if case .string(let value) = self { return value }
            return nil
        }

        var canonicalValue: String {
            switch self {
            case .null: return "<null>"
            case .bool(let value): return value ? "1" : "0"
            case .int(let value): return String(value)
            case .double(let value): return String(value)
            case .string(let value): return value
            case .array, .object:
                let data = try! JSONSerialization.data(withJSONObject: foundationObject, options: [.sortedKeys])
                return String(data: data, encoding: .utf8)!
            }
        }
    }
}
