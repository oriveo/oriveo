import Foundation
import Testing
@testable import Oriveo

/// Cross-platform contract for Relay 2.0 model-level fields and the single resolver functions (`shared/test-fixtures/relay/portable-config.v1.json`
/// `modelFields` / `modelCases` / `resolveCases`).
///
/// Inputs are always overlaid from the fixture onto the baseline JSON produced by the production encoder and then fed through the production decoder; the assertion subjects are the actual outputs of the production decoder /
/// encoder / resolver functions / `providerToFirestore` / `BackupProvider`, never hand-built final objects.
@Suite("Relay 2.0 · model-level fields and the single resolver functions", .serialized)
struct RelayModelContractTests {

    // MARK: - Fixtures

    private func loadContract() throws -> [String: Any] {
        var cursor = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while cursor.path != "/" {
            let candidate = cursor
                .appendingPathComponent("shared")
                .appendingPathComponent("test-fixtures")
                .appendingPathComponent("relay")
                .appendingPathComponent("portable-config.v1.json")
            if FileManager.default.fileExists(atPath: candidate.path) {
                let object = try JSONSerialization.jsonObject(with: Data(contentsOf: candidate))
                return try #require(object as? [String: Any])
            }
            cursor.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }

    private func strings(_ value: Any?) -> [String] {
        value as? [String] ?? []
    }

    /// Baseline model JSON produced by the production encoder (without Relay 2.0 model-level fields).
    private func baselineModelJSON() throws -> [String: Any] {
        let data = try JSONEncoder().encode(TestFactories.makeModel(id: "relay-model", isManual: true))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// Overlays the fixture's Relay 2.0 keys onto the baseline and decodes with the production decoder.
    private func decodeModel(overlaying overlay: [String: Any]) throws -> AIModel {
        var json = try baselineModelJSON()
        for (key, value) in overlay { json[key] = value }
        return try JSONDecoder().decode(AIModel.self, from: JSONSerialization.data(withJSONObject: json))
    }

    private func encodedJSON<T: Encodable>(_ value: T, encoder: JSONEncoder = JSONEncoder()) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: encoder.encode(value)) as? [String: Any])
    }

    private func sameJSON(_ lhs: Any?, _ rhs: Any?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case let (lhs?, rhs?): return (lhs as AnyObject).isEqual(rhs as AnyObject)
        default: return false
        }
    }

    /// Provider for resolveCases: `relayRequested` goes through the production decoder, and the connection address is placed as-is into `baseURLText`.
    private func makeProvider(from json: [String: Any], models: [AIModel] = []) throws -> Provider {
        var provider = TestFactories.makeProvider(
            kind: .relay,
            models: models,
            baseURLText: json["baseURL"] as? String
        )
        if let requested = json["relayRequested"] {
            provider.relayRequested = try JSONDecoder().decode(
                RelayRequestedConfig.self,
                from: JSONSerialization.data(withJSONObject: requested)
            )
        } else {
            provider.relayRequested = nil
        }
        return provider
    }

    /// The model in resolveCases only specifies the protocol; a missing source makes the decoder drop the whole pair leniently, so `user` is added here before the production decoder runs.
    private func makeResolveModel(from json: [String: Any]) throws -> AIModel {
        var overlay = json
        if overlay["relayTransport"] != nil, overlay["relayTransportSource"] == nil {
            overlay["relayTransportSource"] = "user"
        }
        return try decodeModel(overlaying: overlay)
    }

    private func resolveCases() throws -> [[String: Any]] {
        let cases = try #require(try loadContract()["resolveCases"] as? [[String: Any]])
        #expect(cases.count == 13)
        return cases
    }

    // MARK: - RL2-DATA-01

    @Test("RL2-DATA-01 the enum of the four model-level fields equals the fixture, and every modelCases entry round-trips through the production codec")
    func rl2Data01ModelFieldsMatchContractAndRoundTrip() throws {
        let contract = try loadContract()
        let fields = try #require(contract["modelFields"] as? [String: Any])
        let all = strings(fields["all"])

        #expect(AIModel.RelayFieldKey.allCases.map(\.rawValue) == all)
        #expect(AIModel.relayPortableFieldNames == Set(strings(fields["portable"])))
        #expect(Set(all).subtracting(AIModel.relayPortableFieldNames) == Set(strings(fields["localOnly"])))
        #expect(Set(RelayTransportSource.allCases.map(\.rawValue)) == Set(strings(fields["transportSources"])))
        #expect(
            Set(RelayCapabilityOverrides.Source.allCases.map(\.rawValue))
                == Set(strings(fields["capabilityOverrideSources"]))
        )
        #expect(
            Set(RelayCapabilityOverrides.Key.allCases.map(\.rawValue))
                == Set(strings(fields["capabilityOverrideKeys"]))
        )
        #expect(
            Set(EngineDeclaration.Key.allCases.map(\.rawValue)) == Set(strings(fields["engineDeclarationKeys"]))
        )
        #expect(
            Set(RelayRequestedConfig.CodingKeys.allCases.map(\.rawValue)) == Set(strings(contract["allFields"]))
        )
        #expect(RelayRequestedConfig.portableFieldNames == Set(strings(contract["portableFields"])))

        let baseline = try baselineModelJSON()
        for key in all {
            #expect(baseline[key] == nil, "the baseline model should not carry \(key)")
        }

        let cases = try #require(contract["modelCases"] as? [[String: Any]])
        #expect(cases.count == 13)
        for item in cases {
            let caseId = item["caseId"] as? String ?? "<no id>"
            let overlay = try #require(item["model"] as? [String: Any])
            let expect = try #require(item["expect"] as? [String: Any])

            // No entry may make the whole model fail to decode.
            let decoded = try decodeModel(overlaying: overlay)
            #expect(decoded.id == "relay-model", "\(caseId): the model's other fields must survive")
            #expect(decoded.relayTransport?.rawValue == expect["relayTransport"] as? String, "\(caseId)")
            #expect(
                decoded.relayTransportSource?.rawValue == expect["relayTransportSource"] as? String,
                "\(caseId)"
            )
            #expect(
                (decoded.relayCapabilityOverrides == nil) == (expect["relayCapabilityOverrides"] == nil),
                "\(caseId)"
            )
            #expect(
                (decoded.engineDeclaration == nil) == (expect["engineDeclaration"] == nil),
                "\(caseId)"
            )

            let reencoded = try encodedJSON(decoded)
            for key in all {
                #expect(
                    sameJSON(reencoded[key], expect[key]),
                    "\(caseId): \(key) re-encoded as \(reencoded[key] ?? "<missing>")"
                )
            }
            // Keys outside the model-level fields are identical to the baseline: leniency must not alter other fields along the way.
            #expect(Set(reencoded.keys).subtracting(all) == Set(baseline.keys), "\(caseId)")
        }
    }

    // MARK: - RL2-RESOLVE-01 / 02

    @Test("RL2-RESOLVE-01 effectiveTransport per resolveCases entry: the model protocol wins; auto / no config falls back to chat completions")
    func rl2Resolve01EffectiveTransport() throws {
        for item in try resolveCases() {
            let caseId = item["caseId"] as? String ?? "<no id>"
            let provider = try makeProvider(from: try #require(item["provider"] as? [String: Any]))
            let model = try makeResolveModel(from: try #require(item["model"] as? [String: Any]))
            let expect = try #require(item["expect"] as? [String: Any])

            #expect(
                RelayEndpointResolver.effectiveTransport(provider: provider, model: model).rawValue
                    == expect["effectiveTransport"] as? String,
                "\(caseId)"
            )
        }

        // A connection without relayRequested also falls back to chat completions.
        let bare = try makeProvider(from: ["baseURL": "https://relay.example.com"])
        #expect(bare.relayRequested == nil)
        #expect(
            RelayEndpointResolver.effectiveTransport(provider: bare, model: try makeResolveModel(from: [:]))
                == .openaiChatCompletions
        )
    }

    @Test("RL2-RESOLVE-02 effectiveAPIRoot per resolveCases entry: protocol table -> legacy single value (default protocol only) -> connection address with a version appended")
    func rl2Resolve02EffectiveAPIRoot() throws {
        for item in try resolveCases() {
            let caseId = item["caseId"] as? String ?? "<no id>"
            let provider = try makeProvider(from: try #require(item["provider"] as? [String: Any]))
            let model = try makeResolveModel(from: try #require(item["model"] as? [String: Any]))
            let expect = try #require(item["expect"] as? [String: Any])

            #expect(
                RelayEndpointResolver.effectiveAPIRoot(provider: provider, model: model)
                    == expect["effectiveAPIRoot"] as? String,
                "\(caseId)"
            )
        }
    }

    // MARK: - RL2-MIGRATE-02

    @Test("RL2-MIGRATE-02 the four model-level fields do not enter the Firestore document; local storage and backup carry them as they are")
    func rl2Migrate02FieldsStayLocalAndInBackup() throws {
        let contract = try loadContract()
        let all = strings((contract["modelFields"] as? [String: Any])?["all"])
        // Since RK-2 the fixture registers seven local-only fields; the three newer ones do not appear in either fixture used by this case.
        #expect(all.count == 7)
        let cases = try #require(contract["modelCases"] as? [[String: Any]])
        let full = try #require(cases.first { $0["caseId"] as? String == "all_three_fields_round_trip" })
        let declared = try #require(cases.first { $0["caseId"] as? String == "engine_declaration_round_trips" })
        // The two fixtures are overlaid onto one model: all four local fields are present at once.
        var overlay = try #require(full["model"] as? [String: Any])
        var expect = try #require(full["expect"] as? [String: Any])
        for (key, value) in try #require(declared["model"] as? [String: Any]) { overlay[key] = value }
        for (key, value) in try #require(declared["expect"] as? [String: Any]) { expect[key] = value }

        let model = try decodeModel(overlaying: overlay)
        #expect(model.engineDeclaration == EngineDeclaration(image: true, toolCall: false, thinking: true))
        #expect(model.relayTransport == .anthropicMessages)
        let provider = try makeProvider(
            from: [
                "baseURL": "https://relay.example.com",
                "relayRequested": [
                    "transport": "openai_chat_completions",
                    "resolvedAPIBaseURLs": ["anthropic_messages": "https://relay.example.com/claude/v1"],
                ],
            ],
            // The second model uses a different literal ID: enabled models with the same literal key on a relay are deduplicated when decoded, and the same ID would be merged into one.
            models: [model, try decodeModel(overlaying: ["id": "relay-model-plain"])]
        )

        // Local storage (the same iso8601 JSONEncoder / JSONDecoder as AppSessionStore): the four fields are unchanged after a round trip.
        let storeEncoder = JSONEncoder()
        storeEncoder.dateEncodingStrategy = .iso8601
        let storeDecoder = JSONDecoder()
        storeDecoder.dateDecodingStrategy = .iso8601
        let storedData = try storeEncoder.encode(provider)
        let storedJSON = try #require(try JSONSerialization.jsonObject(with: storedData) as? [String: Any])
        let storedModels = try #require(storedJSON["models"] as? [[String: Any]])
        let restored = try storeDecoder.decode(Provider.self, from: storedData)
        for key in all {
            #expect(sameJSON(storedModels[0][key], expect[key]), "local storage \(key)")
            #expect(storedModels[1][key] == nil, "a model that never set it must not gain \(key)")
        }
        #expect(restored.models[0].relayTransport == model.relayTransport)
        #expect(restored.models[0].relayTransportSource == model.relayTransportSource)
        #expect(restored.models[0].relayCapabilityOverrides == model.relayCapabilityOverrides)
        #expect(restored.models[0].relayCapabilityOverrides != nil)
        #expect(restored.models[0].engineDeclaration == model.engineDeclaration)
        #expect(restored.models[1].engineDeclaration == nil)
        #expect(restored.models[1].relayTransport == nil)
        #expect(
            restored.relayRequested?.resolvedAPIBaseURLs
                == ["anthropic_messages": "https://relay.example.com/claude/v1"]
        )

        // 3) Backup: the BackupProvider used for export also carries the four fields, and they are unchanged after decoding.
        let backupEncoder = JSONEncoder()
        backupEncoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        backupEncoder.dateEncodingStrategy = .iso8601
        let backupData = try backupEncoder.encode(BackupProvider(from: provider))
        let backupJSON = try #require(try JSONSerialization.jsonObject(with: backupData) as? [String: Any])
        let backupModels = try #require(backupJSON["models"] as? [[String: Any]])
        for key in all {
            #expect(sameJSON(backupModels[0][key], expect[key]), "backup \(key)")
        }
        let backupRestored = try storeDecoder.decode(BackupProvider.self, from: backupData)
        #expect(backupRestored.models[0].relayTransport == model.relayTransport)
        #expect(backupRestored.models[0].relayTransportSource == model.relayTransportSource)
        #expect(backupRestored.models[0].relayCapabilityOverrides == model.relayCapabilityOverrides)
        #expect(backupRestored.models[0].engineDeclaration == model.engineDeclaration)
    }
}
