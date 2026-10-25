import Foundation
import Testing
@testable import Oriveo

/// Entry point for reading the shared contract `capability_truth_contract.v1.json`.
/// The official catalog only trusts the production recording in the contract: tests do not hand-write metadata,
/// hand-build catalogs, or hand-build models that are "supported".
enum CapabilityTruthContractFixture {
    struct OfficialExpectation {
        let kind: ProviderKind
        let modelID: String
        let visionInput: String
        let fileInput: String
        let webSearch: String
        let toolCall: String
        let reasoningTiers: [String]
        var label: String { "\(kind.rawValue)/\(modelID)" }
    }

    struct OfficialMetadata {
        /// The `data` text of the recorded envelope: the `MetadataClient` decode entry takes the layer inside the envelope.
        let json: String
        let etag: String
        /// Recording time in milliseconds. Typed candidates carry `expiresAt`, so the verdict clock is pinned to the snapshot's own time.
        let recordedAt: Int64
        let selection: Set<String>
    }

    struct WireCase {
        let kind: ProviderKind
        let modelID: String
        let web: CapabilityWebPreference
        let mustContain: [String]
        let mustNotContain: [String]
    }

    /// The recorded `GET /api/metadata?view=lean` envelope -> `data` text, ETag and recording time.
    static func officialMetadata() throws -> OfficialMetadata {
        let fixtures = try #require(root["fixtures"] as? [String: Any])
        let recorded = try #require(fixtures["official_metadata"] as? [String: Any])
        let envelope = try #require(recorded["response"] as? [String: Any])
        #expect(envelope["code"] != nil && envelope["message"] != nil)
        let payload = try #require(envelope["data"])
        let data = try JSONSerialization.data(withJSONObject: payload)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let recordedAtText = try #require(recorded["recorded_at"] as? String)
        let recordedAt = try #require(formatter.date(from: recordedAtText))
        let selection = try #require(recorded["selection"] as? [[String: String]])
        var labels: Set<String> = []
        for item in selection {
            let kind = try #require(item["providerKind"])
            let modelID = try #require(item["modelId"])
            labels.insert("\(kind)/\(modelID)")
        }
        return OfficialMetadata(
            json: String(decoding: data, as: UTF8.self),
            etag: try #require(recorded["etag"] as? String),
            recordedAt: Int64(recordedAt.timeIntervalSince1970 * 1_000),
            selection: labels
        )
    }

    /// Key `"<providerKind>/<modelId>"`: split only at the first `/`, since the model id itself may contain `/`.
    private static func officialModelRef(_ label: String) throws -> (ProviderKind, String) {
        let parts = label.split(separator: "/", maxSplits: 1).map(String.init)
        #expect(parts.count == 2, "Official expectation key \(label)")
        let kind = try #require(ProviderKind(rawValue: parts[0]), "Unknown kind \(label)")
        return (kind, try #require(parts.last))
    }

    static func officialExpectations() throws -> [OfficialExpectation] {
        let expected = try #require(root["expected"] as? [String: Any])
        let official = try #require(expected["official"] as? [String: [String: Any]])
        return try official.keys.sorted().map { label in
            let raw = try #require(official[label])
            let (kind, modelID) = try officialModelRef(label)
            return OfficialExpectation(
                kind: kind, modelID: modelID,
                visionInput: try #require(raw["vision_input"] as? String),
                fileInput: try #require(raw["file_input"] as? String),
                webSearch: try #require(raw["web_search"] as? String),
                toolCall: try #require(raw["tool_call"] as? String),
                reasoningTiers: try #require(raw["reasoning_tiers"] as? [String])
            )
        }
    }

    static func officialSources() throws -> [String: (source: String, grade: String)] {
        let expected = try #require(root["expected"] as? [String: Any])
        let sources = try #require(expected["official_sources"] as? [String: Any])
        var result: [String: (source: String, grade: String)] = [:]
        for (key, value) in sources where !key.hasPrefix("$") {
            let raw = try #require(value as? [String: String], "official_sources.\(key)")
            let source = try #require(raw["source"])
            result[key] = (source, try #require(raw["grade"]))
        }
        return result
    }

    static func officialWire() throws -> [WireCase] {
        let expected = try #require(root["expected"] as? [String: Any])
        let wire = try #require(expected["official_wire"] as? [[String: Any]])
        return try wire.map { raw in
            let modelLabel = try #require(raw["model"] as? String)
            let (kind, modelID) = try officialModelRef(modelLabel)
            let web = try #require(raw["web"] as? String)
            return WireCase(
                kind: kind, modelID: modelID,
                web: try #require(CapabilityWebPreference(rawValue: web), "Unknown web intent \(web)"),
                mustContain: raw["body_must_contain"] as? [String] ?? [],
                mustNotContain: raw["body_must_not_contain"] as? [String] ?? []
            )
        }
    }

    static let root: [String: Any] = {
        let data = try! Data(contentsOf: findContractURL())
        return try! JSONSerialization.jsonObject(with: data) as! [String: Any]
    }()

    struct FormCase {
        let kind: String
        let authMode: String
        let form: String
    }

    private static func forms() throws -> [String: Any] {
        try #require(root["forms"] as? [String: Any])
    }

    static func formOrder() throws -> [String] {
        try #require(try forms()["order"] as? [String])
    }

    static func formCases() throws -> [FormCase] {
        let cases = try #require(try forms()["cases"] as? [[String: Any]])
        return try cases.map {
            FormCase(
                kind: try #require($0["kind"] as? String),
                authMode: try #require($0["authMode"] as? String),
                form: try #require($0["form"] as? String)
            )
        }
    }

    static func formAdapters() throws -> [String: String] {
        try #require(try forms()["adapters"] as? [String: String])
    }

    private static func findContractURL() -> URL {
        let startURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let relativeComponents = ["shared", "model-contracts", "capability_truth_contract.v1.json"]

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

        preconditionFailure("Unable to locate capability_truth_contract.v1.json from \(startURL.path)")
    }
}

/// Official cases capture the request body sent by the production Service; they only record and never rewrite.
private final class CapabilityTruthURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var bodies: [String] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let body = request.httpBody ?? Self.readBody(from: request.httpBodyStream) ?? Data()
        Self.bodies.append(String(decoding: body, as: UTF8.self))
        let url = request.url?.absoluteString ?? ""
        let payload: String
        if url.contains("generativelanguage") {
            payload = #"{"candidates":[{"content":{"parts":[{"text":"ok"}]}}]}"#
        } else if url.contains("anthropic") {
            payload = #"{"content":[{"type":"text","text":"ok"}],"usage":{"input_tokens":1,"output_tokens":1}}"#
        } else if url.contains("/responses") {
            payload = #"{"output_text":"ok","usage":{"input_tokens":1,"output_tokens":1}}"#
        } else {
            payload = #"{"choices":[{"message":{"content":"ok"}}],"usage":{"prompt_tokens":1,"completion_tokens":1}}"#
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(payload.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}

    private static func readBody(from stream: InputStream?) -> Data? {
        guard let stream else { return nil }
        stream.open()
        defer { stream.close() }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 1_024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            result.append(buffer, count: count)
        }
        return result.isEmpty ? nil : result
    }
}

// Official cases load snapshots into `MetadataClient.shared`, so the suite must run serially.
@Suite("CapabilityTruthContract", .serialized, .sharedProcessState)
struct CapabilityTruthContractTests {
    private typealias Fixture = CapabilityTruthContractFixture

    /// Every tier of the v2 intent vocabulary; the `reasoning_level/*` keys use this set.
    private static let reasoningIntents = ["low", "balanced", "deep", "max"]
    private static let governedKeys: Set<String> = Set(
        ["vision_input", "web_search"] + reasoningIntents.map { "reasoning_level/\($0)" }
    )

    private func projection(
        provider: Provider,
        model: AIModel,
        keys: Set<String> = governedKeys,
        explicitKeys: Set<String> = [],
        now: Int64? = nil
    ) -> CapabilityEvidenceProjection {
        // The same construction path as the UI entry.
        var identity = CapabilityEvidenceRequestIdentity.make(
            provider: provider, model: model, partitionID: "truth-contract",
            hasExplicitValue: false
        )
        if let now {
            // Only the clock is swapped: the typed candidates in the recorded snapshot have `expiresAt`, and once the wall clock passes it the same snapshot would be judged expired.
            let made = identity.query
            identity = .init(query: .init(
                partitionID: made.partitionID, connectionInstanceID: made.connectionInstanceID,
                connectionGeneration: made.connectionGeneration, credentialEpoch: made.credentialEpoch,
                providerKind: made.providerKind, authMode: made.authMode, modelID: made.modelID,
                canonicalModelID: made.canonicalModelID, effectiveTransport: made.effectiveTransport,
                endpointFingerprint: made.endpointFingerprint, metadataRevision: made.metadataRevision,
                generationRevision: made.generationRevision, now: now,
                hasExplicitValue: made.hasExplicitValue
            ), runtimeRevision: identity.runtimeRevision)
        }
        return CapabilityEvidenceProductionAdapter.capabilityProjection(
            provider: provider, model: model, identity: identity,
            keys: keys, explicitKeys: explicitKeys
        )
    }

    @Test("Form derivation equals the contract table row by row, in the contract's order")
    func providerFormDerivationMatchesContractCases() throws {
        #expect(ProviderForm.allCases.map(\.rawValue) == (try CapabilityTruthContractFixture.formOrder()))

        let cases = try CapabilityTruthContractFixture.formCases()
        #expect(!cases.isEmpty)
        for item in cases {
            let kind = try #require(ProviderKind(rawValue: item.kind), "Unknown kind \(item.kind)")
            let authMode = try #require(ProviderAuthMode(rawValue: item.authMode), "Unknown authMode \(item.authMode)")
            #expect(
                ProviderForm.of(kind: kind, authMode: authMode).rawValue == item.form,
                "\(item.kind) + \(item.authMode)"
            )
        }
    }

    @Test("The authMode produced by the production identity constructor equals the connection's authMode, row by row of the contract forms.cases")
    func requestIdentityCarriesConnectionAuthMode() throws {
        let cases = try Fixture.formCases()
        #expect(!cases.isEmpty)
        for item in cases {
            let kind = try #require(ProviderKind(rawValue: item.kind), "Unknown kind \(item.kind)")
            let model = TestFactories.makeModel(id: "truth-contract-identity")
            var provider = TestFactories.makeProvider(kind: kind, models: [model])
            provider.authMode = try #require(ProviderAuthMode(rawValue: item.authMode), "Unknown authMode \(item.authMode)")
            let identity = CapabilityEvidenceRequestIdentity.make(
                provider: provider, model: model, partitionID: "truth-contract", hasExplicitValue: false
            )
            #expect(identity.query.authMode == item.authMode, "\(item.kind) + \(item.authMode)")
        }
    }

    @Test("The adapter the registry gives each form matches the contract's registration")
    func registryAdaptersMatchContract() throws {
        let adapters = try CapabilityTruthContractFixture.formAdapters()
        #expect(Set(adapters.keys) == Set(ProviderForm.allCases.map(\.rawValue)))
        for form in ProviderForm.allCases {
            #expect(
                String(describing: CapabilityTruthRegistry.adapter(for: form)) == adapters[form.rawValue],
                "\(form.rawValue)"
            )
        }
    }

    // MARK: - Official (BYOK)

    /// Loads the recorded official metadata snapshot into the production `MetadataClient` and always clears it afterwards, even on a throw.
    private func withOfficialMetadata(
        _ body: (CapabilityTruthContractFixture.OfficialMetadata) async throws -> Void
    ) async throws {
        let recorded = try Fixture.officialMetadata()
        await MetadataClient.shared.resetForTesting()
        do {
            try await MetadataClient.shared.loadForTesting(json: recorded.json, metadataETag: recorded.etag)
            try await body(recorded)
        } catch {
            await MetadataClient.shared.resetForTesting()
            throw error
        }
        await MetadataClient.shared.resetForTesting()
    }

    /// The model the snapshot maps to through production, and the official connection that holds it.
    private func officialConnection(kind: ProviderKind, modelID: String) async -> (Provider, AIModel) {
        let model = await CatalogModelBuilder.buildCatalogModel(
            providerKind: kind, runtimeModelId: modelID, fallbackName: modelID
        )
        return (TestFactories.makeProvider(kind: kind, models: [model]), model)
    }

    @Test("For every model in the official metadata snapshot, the vision / web / tool / reasoning-tier projections equal the contract expectations cell by cell")
    func officialMetadataProjectionMatchesContract() async throws {
        let expectations = try Fixture.officialExpectations()
        let sources = try Fixture.officialSources()
        #expect(!expectations.isEmpty)

        try await withOfficialMetadata { recorded in
            #expect(Set(expectations.map(\.label)) == recorded.selection)
            for expected in expectations {
                let (provider, model) = await officialConnection(kind: expected.kind, modelID: expected.modelID)
                #expect(ProviderForm.of(provider) == .official, "\(expected.label)")
                let projection = projection(
                    provider: provider, model: model,
                    keys: Self.governedKeys.union(["tool_call"]), now: recorded.recordedAt
                )
                #expect(projection.identity?.query.metadataRevision == recorded.etag, "\(expected.label) revision")

                // Official vision only reads the recipe's `capabilityControls.vision_input`; when the snapshot
                // lacks that control the key is projected as unknown, and the legacy `capabilities` catalog bit
                // no longer yields supported (the fixture is unchanged).
                let hasVisionControl = MetadataClient.shared.syncCapabilityRecipeRuntime(
                    modelID: expected.modelID, providerKind: expected.kind
                ).controls?[CapabilityEvidenceFacade.visionInputKey] != nil
                let visionWant = hasVisionControl ? expected.visionInput : "unknown"
                for (key, want) in [
                    ("vision_input", visionWant), ("web_search", expected.webSearch),
                    ("tool_call", expected.toolCall),
                ] {
                    let resolution = try #require(projection.resolution(for: key), "\(expected.label) \(key)")
                    #expect(resolution.support.rawValue == want, "\(expected.label) \(key)")
                    if resolution.support != .unknown, let source = sources[key] {
                        #expect(resolution.source.rawValue == source.source, "\(expected.label) \(key) source")
                        #expect(resolution.grade.rawValue == source.grade, "\(expected.label) \(key) grade")
                    }
                }

                // Keys use the v2 intent vocabulary; the local fast tier lands on low through the production reverse mapping.
                let supportedTiers = Self.reasoningIntents.filter {
                    projection.resolution(for: "reasoning_level/\($0)")?.support == .supported
                }
                #expect(Set(supportedTiers) == Set(expected.reasoningTiers), "\(expected.label) reasoning tiers")
            }
        }
    }

    @Test("Official request bodies: a model without web does not get a web tool even when web is forced, and a model with web gets the tool the recipe gives")
    func officialWireBodiesMatchContract() async throws {
        let wire = try Fixture.officialWire()
        #expect(!wire.isEmpty)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CapabilityTruthURLProtocol.self]
        let session = URLSession(configuration: configuration)

        try await withOfficialMetadata { _ in
            for item in wire {
                let label = "\(item.kind.rawValue)/\(item.modelID)"
                let (provider, model) = await officialConnection(kind: item.kind, modelID: item.modelID)
                let resolved = try #require(MetadataClient.shared.syncResolveCatalogModel(
                    modelID: item.modelID, providerKind: item.kind
                ), "\(label) is not in the snapshot")
                var options = ChatRequestOptions(generationProfile: resolved.generationProfile)
                options.capabilityPreferences = .init(web: item.web, reasoningIntent: nil)
                options.capabilityEvidenceModel = model
                let message = ChatMessage(
                    id: UUID(), role: .user, text: "hello", providerKind: item.kind,
                    providerName: item.kind.displayName, modelID: item.modelID, modelName: item.modelID,
                    state: .delivered
                )
                let identity = CapabilityEvidenceRequestIdentity.make(
                    provider: provider, model: model, partitionID: "truth-contract", hasExplicitValue: true
                )

                CapabilityTruthURLProtocol.bodies = []
                _ = try await CapabilityEvidenceRequestContext.$current.withValue(identity) {
                    try await Self.sendNonstream(
                        kind: item.kind, session: session, modelID: item.modelID,
                        message: message, options: options
                    )
                }
                let bodies = CapabilityTruthURLProtocol.bodies.filter { !$0.isEmpty }
                #expect(!bodies.isEmpty, "\(label) sent no request body")
                for needle in item.mustContain {
                    #expect(bodies.contains { $0.contains(needle) }, "\(label) request body should contain \(needle)")
                }
                for needle in item.mustNotContain {
                    #expect(!bodies.contains { $0.contains(needle) }, "\(label) request body should not contain \(needle)")
                }
            }
        }
        CapabilityTruthURLProtocol.bodies = []
    }

    private static func sendNonstream(
        kind: ProviderKind, session: URLSession, modelID: String,
        message: ChatMessage, options: ChatRequestOptions
    ) async throws -> ProviderChatResult {
        switch kind {
        case .openAI:
            return try await OpenAIService(session: session).sendMessage(
                apiKey: "test-key", modelID: modelID, messages: [message],
                reasoningMode: .automatic, webSearchEnabled: true, requestOptions: options
            )
        case .anthropic:
            return try await AnthropicService(session: session).sendMessage(
                apiKey: "test-key", modelID: modelID, messages: [message],
                reasoningMode: .automatic, webSearchEnabled: true, requestOptions: options
            )
        case .gemini:
            return try await GeminiService(session: session).sendMessage(
                apiKey: "test-key", modelID: modelID, messages: [message],
                reasoningMode: .automatic, webSearchEnabled: true, requestOptions: options
            )
        default:
            throw CocoaError(.featureUnsupported, userInfo: [
                NSLocalizedDescriptionKey: "official_wire names a provider this test has no Service wired for: \(kind.rawValue)",
            ])
        }
    }

    @Test("Official file_input: whether a PDF takes the native file route matches the contract expectation")
    func officialNativeFileRouteMatchesContract() async throws {
        let expectations = try Fixture.officialExpectations()
        #expect(!expectations.isEmpty)
        // A PDF with no extractable text: the route is then decided only by whether the model accepts a native
        // PDF (a PDF with a text layer also stacks the provider's "native by default or not" preference on top,
        // which cannot measure the file_input cell).
        let pdf = Oriveo.Attachment(
            id: UUID(), kind: .file, fileName: "scan.pdf", mimeType: "application/pdf",
            extractionErrorCode: "scanned_pdf",
            originalBase64Data: Data("%PDF-1.4\n%%EOF\n".utf8).base64EncodedString()
        )

        try await withOfficialMetadata { _ in
            for expected in expectations {
                let (_, model) = await officialConnection(kind: expected.kind, modelID: expected.modelID)
                let route = AttachmentRouter.decide(attachment: pdf, provider: expected.kind, model: model)
                #expect(
                    (route == .native) == (expected.fileInput == "supported"),
                    "\(expected.label) file_input=\(expected.fileInput) route=\(route)"
                )
            }
        }
    }
}
