import Foundation
import Testing
@testable import Oriveo

@Suite("generation wire hardening (D33)", .serialized, .sharedProcessState)
struct GenerationWireHardeningTests {

    @Test("Wire Hardening Cases")
    func wireHardeningCases() async throws {
        let contract = try Self.loadContract()
        #expect(contract.wireHardening.segmentPattern == "^[A-Za-z_][A-Za-z0-9_]*$")
        #expect(contract.wireHardening.blockedSegments == ["__proto__", "prototype", "constructor"])
        #expect(contract.wireHardening.maxSegments == 4)
        #expect(contract.wireHardening.builderOwnedRootFields == [
            "model", "messages", "input", "contents", "prompt", "attachments", "instructions", "system",
            "stream", "stream_options", "tools", "tool_choice", "plugins",
        ])
        #expect(contract.wireHardening.jsonSchemaLimits.maxBytes == 65536)
        #expect(contract.wireHardening.jsonSchemaLimits.maxDepth == 32)
        #expect(contract.wireHardeningCases.count >= 15)

        defer { GenerationWireDiagnostics.reset() }

        for item in contract.wireHardeningCases {
            await MetadataClient.shared.resetForTesting()
            try await MetadataClient.shared.loadForTesting(
                json: try Self.hostileMetadataJSON(wire: item.wire),
                metadataETag: "wire-hardening-etag"
            )
            let resolved = await MetadataClient.shared.resolveCatalogModel(
                modelID: "fixture-chat",
                providerKind: .openRouter
            )
            let profile = try #require(resolved?.generationProfile, "\(item.caseId) did not get a generation profile")
            #expect(profile.wire?["temperature"] == item.wire)

            GenerationWireDiagnostics.reset()
            var body: [String: Any] = [
                "model": "fixture-chat",
                "messages": [["role": "user", "content": "hello"]],
                "stream": true,
                "stream_options": ["include_usage": true],
            ]
            let options = ChatRequestOptions(
                generationParameters: GenerationParameterOverrides(
                    values: ["temperature": GenerationParameterOverride(state: .value, value: .number(item.value))]
                )
            )
            let provider = TestFactories.makeProvider(id: UUID(), kind: .openRouter)
            var model = TestFactories.makeModel(id: "fixture-chat")
            model.canonicalModelId = resolved?.canonicalModelId
            let identity = CapabilityEvidenceRequestIdentity.make(
                provider: provider,
                model: model,
                partitionID: "wire-hardening-user",
                hasExplicitValue: true,
                metadataETag: "wire-hardening-etag"
            )
            let finalRequest = URLRequest(
                url: try #require(URL(string: "https://openrouter.test/api/v1/chat/completions"))
            )
            let data = try CapabilityEvidenceRequestContext.$current.withValue(identity) {
                try BaseAPIService().encodeChatBody(
                    &body,
                    options: options,
                    resolved: resolved,
                    finalRequest: finalRequest
                )
            }
            let encoded = try #require(
                try JSONSerialization.jsonObject(with: data) as? [String: Any],
                "\(item.caseId) request body must still be a valid JSON object"
            )

            let written = Self.value(in: encoded, path: item.wire) as? Double
            let diagnostics = GenerationWireDiagnostics.read()
            if item.expect.applied {
                #expect(written == item.value)
                #expect(diagnostics.isEmpty)
            } else {
                #expect(written != item.value)
                let reason = try #require(
                    ProfileParamsResolver.WireRejectionReason(rawValue: item.expect.reason ?? ""),
                    "\(item.caseId) contract reason is not in the in-app enum"
                )
                let expected = [
                    GenerationWireDiagnostics.Entry(
                        parameterID: "temperature",
                        wirePath: item.wire,
                        reason: reason
                    ),
                ]
                #expect(diagnostics == expected)
            }
            #expect(encoded["model"] as? String == "fixture-chat")
            #expect(encoded["messages"] is [Any])
        }

        await MetadataClient.shared.resetForTesting()
    }

    @Test("Relay Synthesized Wire Stays In Constant Table")
    func relaySynthesizedWireStaysInConstantTable() throws {
        let engines: [String?] = ["llamacpp", "ollama", "lmstudio", "vllm", "openwebui", nil, "unknown-engine"]
        let transports: [RelayTransport?] = [
            nil, .auto, .openaiResponses, .openaiChatCompletions,
            .llamacppNative, .anthropicMessages, .geminiGenerateContent,
        ]
        var checked = 0

        for engine in engines {
            for transport in transports {
                guard let profile = LocalEngineGenerationProfiles.profile(for: engine, transport: transport) else {
                    continue
                }
                let declared = Set((profile.parameters ?? []).compactMap(\.id))
                for (id, path) in profile.wire ?? [:] {
                    checked += 1
                    #expect(declared.contains(id))
                    #expect(
                        ProfileParamsResolver.wireRejectionReason(path) == nil,
                        "relay synthesized wire \(id)=\(path) has an illegal structure"
                    )
                }
            }
        }
        #expect(checked > 0)
    }

    @Test("Oversized JSONSchema Is Rejected")
    func oversizedJSONSchemaIsRejected() throws {
        let parameter = GenerationParameterRef(
            id: "json_schema",
            support: "supported",
            source: "relay_declared",
            valueSchema: "json-schema"
        )
        let small = GenerationParameterValue.object(["type": .string("object")])
        let oversized = GenerationParameterValue.object([
            "type": .string("object"),
            "title": .string(String(repeating: "x", count: 64 * 1024)),
        ])
        #expect(ProfileParamsResolver.isValidGenerationValue(small, for: parameter))
        #expect(!ProfileParamsResolver.isValidGenerationValue(oversized, for: parameter))
    }

    // MARK: - Official parameter gate

    /// Production metadata -> `BaseAPIService.encodeChatBody`: builder default temperature 1.0, explicit user value 0.5.
    /// Returns the temperature in the final request body (nil = not sent).
    private static func encodeOfficialTemperature(
        parameterSupport: String?,
        negativeCacheState: String? = nil,
        relay: Bool = false
    ) async throws -> Double? {
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(
            json: try Self.gatedMetadataJSON(parameterSupport: parameterSupport),
            metadataETag: "param-gate-etag"
        )
        let resolved = try #require(await MetadataClient.shared.resolveCatalogModel(
            modelID: "fixture-chat", providerKind: .openRouter
        ))
        var body: [String: Any] = [
            "model": "fixture-chat",
            "messages": [["role": "user", "content": "hello"]],
            "temperature": 1.0,
        ]
        let options = ChatRequestOptions(
            generationParameters: GenerationParameterOverrides(
                values: ["temperature": GenerationParameterOverride(state: .value, value: .number(0.5))]
            )
        )
        let provider = TestFactories.makeProvider(id: UUID(), kind: relay ? .relay : .openRouter)
        var model = TestFactories.makeModel(id: "fixture-chat")
        model.canonicalModelId = resolved.canonicalModelId
        let identity = CapabilityEvidenceRequestIdentity.make(
            provider: provider, model: model, partitionID: "param-gate-user",
            hasExplicitValue: true, metadataETag: "param-gate-etag"
        )
        let cache = CapabilityNegativeCache.shared
        defer { cache.clearConnection(provider.id.uuidString) }
        if let negativeCacheState {
            cache.record(
                connectionId: provider.id.uuidString, modelId: identity.query.effectiveModelID,
                wireFamily: "openai_chat", capabilityKey: "param:temperature",
                signatureId: "fixture.temperature_rejected",
                verdictRevision: CapabilityNegativeCache.verdictRevision(.init(state: negativeCacheState))
            )
        }
        if relay {
            // Relay only passes the builder-default gate: parameterSupport "unavailable" does not strip it either.
            CapabilityEvidenceRequestContext.$current.withValue(identity) {
                ProfileParamsResolver.applyTemperatureGate(to: &body, resolved: resolved)
            }
            return (body["temperature"] as? NSNumber)?.doubleValue
        }
        let finalRequest = URLRequest(url: try #require(URL(string: "https://openrouter.test/api/v1/chat/completions")))
        let data = try CapabilityEvidenceRequestContext.$current.withValue(identity) {
            try BaseAPIService().encodeChatBody(&body, options: options, resolved: resolved, finalRequest: finalRequest)
        }
        let encoded = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return (encoded["temperature"] as? NSNumber)?.doubleValue
    }

    @Test("Official parameterSupport temperature unavailable: neither builder default nor explicit value is sent")
    func officialTemperatureUnavailableIsNotSent() async throws {
        let sent = try await Self.encodeOfficialTemperature(
            parameterSupport: #"{"temperature": {"state": "unavailable", "reasonCode": "official_doc"}}"#
        )
        #expect(sent == nil)
    }

    @Test("Official parameterSupport temperature unknown, auto_available or missing: explicit value is sent")
    func officialTemperatureUnknownOrAutoIsSent() async throws {
        for support in [
            #"{"temperature": {"state": "unknown", "reasonCode": "catalog_silent"}}"#,
            #"{"temperature": {"state": "auto_available"}}"#,
            nil,
        ] {
            let sent = try await Self.encodeOfficialTemperature(parameterSupport: support)
            #expect(sent == 0.5, "parameterSupport=\(support ?? "nil")")
        }
    }

    @Test("Official v2 param:temperature negative cache hit with a matching revision is not sent; a stale revision is sent")
    func officialTemperatureNegativeCacheHitIsNotSent() async throws {
        let support = #"{"temperature": {"state": "auto_available"}}"#
        #expect(try await Self.encodeOfficialTemperature(parameterSupport: support, negativeCacheState: "auto_available") == nil)
        #expect(try await Self.encodeOfficialTemperature(parameterSupport: support, negativeCacheState: "unknown") == 0.5)
    }

    @Test("Relay ignores the official parameter gate")
    func relayIgnoresOfficialParameterGate() async throws {
        let sent = try await Self.encodeOfficialTemperature(
            parameterSupport: #"{"temperature": {"state": "unavailable"}}"#, relay: true
        )
        #expect(sent == 1.0)
    }

    @Test("Official Anthropic thinking rejected by signature records param:thinking; reasoning fields are then omitted entirely, Relay unaffected")
    func officialThinkingRejectionOmitsReasoningFields() throws {
        let provider = TestFactories.makeProvider(id: UUID(), kind: .anthropic)
        let model = TestFactories.makeModel(id: "claude-param-gate-fixture")
        let identity = CapabilityEvidenceRequestIdentity.make(
            provider: provider, model: model, partitionID: "param-gate-user",
            hasExplicitValue: false, effectiveTransport: TransportKind.anthropicMessages.rawValue
        )
        let cache = CapabilityNegativeCache.shared
        defer { cache.clearConnection(provider.id.uuidString) }
        func guarded(_ thinking: [String: Any], identity: CapabilityEvidenceRequestIdentity) -> [String: Any] {
            var body: [String: Any] = [
                "model": model.id, "max_tokens": 8192, "thinking": thinking, "output_config": ["effort": "high"],
            ]
            CapabilityEvidenceRequestContext.$current.withValue(identity) {
                ProfileParamsResolver.applyAnthropicThinkingGuard(
                    to: &body, application: GenerationParameterApplication(), builderDefaultMaxTokens: 8192
                )
            }
            return body
        }
        // Not rejected yet: the thinking field is written as usual.
        #expect(guarded(["type": "disabled"], identity: identity)["thinking"] != nil)

        let rejection = try #require(InputRejectionFlow.record(
            .init(
                form: .official,
                connectionId: provider.id.uuidString, modelId: identity.query.effectiveModelID,
                outputStarted: false, carriedCapabilityKeys: [],
                httpStatus: 400,
                rawBody: #"{"type":"error","error":{"type":"invalid_request_error","message":"\"thinking.type.disabled\" is not supported for this model"}}"#,
                controls: nil, transport: TransportKind.anthropicMessages.rawValue
            )
        ))
        #expect(rejection.capabilityKey == "param:thinking")
        #expect(rejection.wireFamily == "anthropic")
        #expect(rejection.signatureId == "anthropic.thinking_type_not_supported")

        for thinking: [String: Any] in [["type": "disabled"], ["type": "enabled", "budget_tokens": 2048]] {
            let body = guarded(thinking, identity: identity)
            #expect(body["thinking"] == nil, "\(thinking)")
            #expect(body["output_config"] == nil, "\(thinking)")
        }

        // Same model id on Relay: the official gate does not apply, the thinking field is untouched.
        var relay = TestFactories.makeProvider(id: provider.id, kind: .relay)
        relay.models = [model]
        let relayIdentity = CapabilityEvidenceRequestIdentity.make(
            provider: relay, model: model, partitionID: "param-gate-user",
            hasExplicitValue: false, effectiveTransport: TransportKind.anthropicMessages.rawValue
        )
        #expect(guarded(["type": "disabled"], identity: relayIdentity)["thinking"] != nil)
    }

    // MARK: - Fixtures

    private static func hostileMetadataJSON(wire: String) throws -> String {
        let encodedWire = String(
            data: try JSONSerialization.data(withJSONObject: [wire], options: []),
            encoding: .utf8
        )!.dropFirst().dropLast()
        let runtime = try CapabilityRuntimeFixtures.runtimeEnvelopeJSON()
        let controls = try CapabilityRuntimeFixtures.controlsJSON(
            .init(capability: "generation", recipeRef: "openrouter.chat.generation.v1")
        )
        return """
        {
          "version": 1,
          "contractVersion": 1,
          "capabilityRuntime": \(runtime),
          "profiles": {
            "generation": {
              "version": 1,
              "parameters": {"temperature": {"group": "sampling", "valueSchema": "number"}},
              "templates": {
                "openai_chat_completions": {
                  "transport": "openai_chat_completions",
                  "wire": {"temperature": \(encodedWire)}
                }
              }
            }
          },
          "providers": {
            "openRouter": {
              "resolveMap": {"fixture-chat": "fixture-chat"},
              "models": {
                "fixture-chat": {
                  "canonicalModelId": "fixture-chat",
                  "transport": "openai_chat",
                  "supportsTemperature": true,
                  "capabilityControls": \(controls),
                  "profiles": {
                    "generation": {
                      "template": "openai_chat_completions",
                      "revision": "wire-hardening-generation-v1",
                      "parameters": [
                        {"id": "temperature", "support": "supported", "source": "authoritative_metadata"}
                      ]
                    }
                  }
                }
              }
            }
          }
        }
        """
    }

    private static func gatedMetadataJSON(parameterSupport: String?) throws -> String {
        let base = try hostileMetadataJSON(wire: "temperature")
        guard let parameterSupport else { return base }
        let marker = #""supportsTemperature": true,"#
        precondition(base.contains(marker))
        return base.replacingOccurrences(of: marker, with: marker + "\n\"parameterSupport\": " + parameterSupport + ",")
    }

    private static func value(in body: [String: Any], path: String) -> Any? {
        var cursor: Any? = body
        for segment in path.components(separatedBy: ".") {
            guard let object = cursor as? [String: Any] else { return nil }
            cursor = object[segment]
        }
        return cursor
    }

    private static func loadContract() throws -> WireHardeningContract {
        var folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while folder.path != "/" {
            let directory = folder
                .appendingPathComponent("shared")
                .appendingPathComponent("model-contracts")
            let candidate = directory.appendingPathComponent("generation_parameter_contract.v1.json")
            if FileManager.default.fileExists(atPath: candidate.path) {
                // Rules live in the contract file, cases in the sibling .cases.json.
                struct RulesFile: Decodable { let wireHardening: WireHardeningContract.Rules }
                struct CasesFile: Decodable { let wireHardeningCases: [WireHardeningContract.Case] }
                let cases = directory.appendingPathComponent("generation_parameter_contract.v1.cases.json")
                return WireHardeningContract(
                    wireHardening: try JSONDecoder().decode(RulesFile.self, from: Data(contentsOf: candidate)).wireHardening,
                    wireHardeningCases: try JSONDecoder().decode(CasesFile.self, from: Data(contentsOf: cases)).wireHardeningCases
                )
            }
            folder.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }

    struct WireHardeningContract: Decodable {
        let wireHardening: Rules
        let wireHardeningCases: [Case]

        struct Rules: Decodable {
            let segmentPattern: String
            let blockedSegments: [String]
            let maxSegments: Int
            let builderOwnedRootFields: [String]
            let jsonSchemaLimits: Limits
        }

        struct Limits: Decodable {
            let maxBytes: Int
            let maxDepth: Int
        }

        struct Case: Decodable {
            let caseId: String
            let wire: String
            let value: Double
            let expect: Expectation
        }

        struct Expectation: Decodable {
            let applied: Bool
            let reason: String?
        }
    }
}
