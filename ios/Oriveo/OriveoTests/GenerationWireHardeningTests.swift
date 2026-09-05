import Foundation
import Testing
@testable import Oriveo

@Suite("generation wire hardening (D33)", .serialized)
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
            let candidate = folder
                .appendingPathComponent("shared")
                .appendingPathComponent("model-contracts")
                .appendingPathComponent("generation_parameter_contract.v1.json")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try JSONDecoder().decode(WireHardeningContract.self, from: Data(contentsOf: candidate))
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
