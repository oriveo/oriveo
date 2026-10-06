import Foundation
import Testing
@testable import Oriveo

/// Engines that run a model on the user's own hardware: transports and parameter tables. Source of
/// truth is `localEngineRules` / `localEngineProfiles` / `localEngineCases` /
/// `llamacppMigrationCases` in the shared contract `generation_parameter_contract.v1.json`.
@Suite("local engine profile contract", .serialized)
@MainActor
struct LocalEngineProfileContractTests {

    @Test("engine parameter tables match the contract row by row: order, wire, type, range, default, group")
    func tablesMatchContract() throws {
        let contract = try GenerationOutboundPerItemContractTests.loadContract()
        let profiles = try #require(contract["localEngineProfiles"] as? [String: [String: [String: Any]]])
        #expect(Set(profiles.keys) == ["llamacpp", "ollama", "lmstudio", "vllm"])
        var rows = 0
        for (engine, transports) in profiles {
            for (transportName, expected) in transports {
                let transport = try #require(RelayTransport(rawValue: transportName))
                let profile = try #require(
                    LocalEngineGenerationProfiles.profile(for: engine, transport: transport),
                    "\(engine)/\(transportName) has no profile"
                )
                let label = "\(engine)/\(transportName)"
                #expect(profile.template == expected["template"] as? String, "\(label) template")
                let expectedRows = try #require(expected["parameters"] as? [[String: Any]])
                let parameters = profile.parameters ?? []
                #expect(parameters.compactMap(\.id) == expectedRows.compactMap { $0["id"] as? String }, "\(label) parameter order")
                for (parameter, row) in zip(parameters, expectedRows) {
                    let id = parameter.id ?? "?"
                    #expect(profile.wire?[id] == row["wire"] as? String, "\(label).\(id) wire")
                    #expect(parameter.valueSchema == row["valueSchema"] as? String, "\(label).\(id) valueSchema")
                    #expect(parameter.group == row["group"] as? String, "\(label).\(id) group")
                    #expect(parameter.group != "engine_runtime", "\(label).\(id) must not use the engine_runtime group")
                    #expect(parameter.support == "accepted_unverified")
                    #expect(parameter.source == "user_declared")
                    let range = row["range"] as? [String: Any]
                    #expect(parameter.range?.min == (range?["min"] as? NSNumber)?.doubleValue, "\(label).\(id) range.min")
                    #expect(parameter.range?.max == (range?["max"] as? NSNumber)?.doubleValue, "\(label).\(id) range.max")
                    #expect(
                        parameter.range?.minExclusive == (range?["minExclusive"] as? NSNumber)?.doubleValue,
                        "\(label).\(id) range.minExclusive"
                    )
                    let expectedDefault = try row["default"].map {
                        try JSONDecoder().decode(
                            [GenerationParameterValue].self, from: JSONSerialization.data(withJSONObject: [$0])
                        )[0]
                    }
                    #expect(parameter.defaultDescription == expectedDefault, "\(label).\(id) default")
                    let expectedEnum = (row["enumValues"] as? [String])?.map(GenerationParameterValue.string)
                    #expect(parameter.enumValues == expectedEnum, "\(label).\(id) enumValues")
                    rows += 1
                }
            }
        }
        #expect(rows >= 100, "unexpected number of reconciled rows: \(rows)")
    }

    @Test("default transport and API base of a new connection match the contract; llama.cpp defaults to chat")
    func channelsMatchContract() throws {
        let contract = try GenerationOutboundPerItemContractTests.loadContract()
        let rules = try #require(contract["localEngineRules"] as? [String: Any])
        let channels = try #require(rules["channels"] as? [String: [String: Any]])
        for (engineName, channel) in channels {
            let engine = try #require(LocalEngineKind(rawValue: engineName))
            let defaultTransport = try #require(channel["defaultTransport"] as? String)
            #expect(engine.defaultTransport.rawValue == defaultTransport, "\(engineName) default transport")
            let bases = try #require(channel["apiBaseURL"] as? [String: String])
            let baseTemplate = try #require(bases[defaultTransport])
            let expectedBase = baseTemplate.replacingOccurrences(of: "{origin}", with: "http://127.0.0.1:9000")
            #expect(
                LocalEngineConnector.apiBaseURL(for: "http://127.0.0.1:9000/", engine: engine) == expectedBase,
                "\(engineName) API base"
            )
            let selectableTransports = try #require(channel["selectableTransports"] as? [String])
            for selectable in selectableTransports {
                let transport = try #require(RelayTransport(rawValue: selectable))
                #expect(LocalEngineGenerationProfiles.profile(for: engineName, transport: transport) != nil)
            }
        }
    }

    /// Every case runs through the full production send path (AppState → ChatManager →
    /// OpenAIService builder → URLSession) and asserts on the URLRequest actually sent.
    @Test("localEngineCases: numbers go out as numbers, vLLM extensions sit at the top level, undeclared parameters are not sent")
    func casesHoldOnProductionRequests() async throws {
        let contract = try GenerationOutboundPerItemContractTests.loadContract()
        let cases = try #require(contract["localEngineCases"] as? [[String: Any]])
        #expect(cases.count >= 8)
        for item in cases {
            let caseID = try #require(item["caseId"] as? String)
            let engine = try #require(item["engine"] as? String)
            let transportName = try #require(item["transport"] as? String)
            let transport = try #require(RelayTransport(rawValue: transportName))
            let overrides = try JSONDecoder().decode(
                [String: GenerationParameterOverride].self,
                from: JSONSerialization.data(withJSONObject: try #require(item["overrides"]))
            )
            let native = transport == .llamacppNative
            let captured = try await GenerationOutboundProductionRequestTests.send(
                transport: transport,
                baseURL: "https://engine.test",
                engineProfile: engine,
                resolvedAPIBaseURL: native ? "https://engine.test" : "https://engine.test/v1",
                connectionDefaults: overrides
            )
            #expect(
                captured.url.path == (native ? "/completion" : "/v1/chat/completions"),
                "\(caseID) was sent to \(captured.url.path)"
            )
            if !native {
                #expect(captured.body["messages"] is [Any], "\(caseID) the chat transport must carry messages")
            }
            let expect = try #require(item["expect"] as? [String: Any])
            for (key, value) in try #require(expect["bodyIncludes"] as? [String: Any]) {
                let actual = try #require(captured.body[key], "\(caseID) is missing \(key)")
                #expect((actual as AnyObject).isEqual(value), "\(caseID).\(key): \(actual) != \(value)")
            }
            for key in try #require(expect["numericFields"] as? [String]) {
                let number = try #require(captured.body[key] as? NSNumber, "\(caseID).\(key) is not a JSON number")
                #expect(!(captured.body[key] is String), "\(caseID).\(key) was sent as a string")
                #expect(CFGetTypeID(number) != CFBooleanGetTypeID(), "\(caseID).\(key) was sent as a boolean")
            }
            for key in try #require(expect["bodyExcludes"] as? [String]) {
                #expect(captured.body[key] == nil, "\(caseID) must not carry \(key)")
            }
        }
    }

    @Test("llamacppMigrationCases: existing native connections move to chat; a hand-picked native transport and other engines stay")
    func migrationCases() throws {
        let contract = try GenerationOutboundPerItemContractTests.loadContract()
        let cases = try #require(contract["llamacppMigrationCases"] as? [[String: Any]])
        #expect(cases.count >= 5)
        for item in cases {
            let caseID = try #require(item["caseId"] as? String)
            let before = try #require(item["before"] as? [String: Any])
            let transportName = try #require(before["transport"] as? String)
            var requested = RelayRequestedConfig(transport: try #require(RelayTransport(rawValue: transportName)))
            requested.engineProfile = before["engineProfile"] as? String
            requested.resolvedAPIBaseURL = before["resolvedAPIBaseURL"] as? String
            let migrated = LlamaCppChannelMigration.migrated(
                requested, alreadyMigrated: try #require(item["alreadyMigrated"] as? Bool)
            )
            let expect = try #require(item["expect"] as? [String: Any])
            #expect((migrated != nil) == (expect["changed"] as? Bool), "\(caseID) changed")
            let result = migrated ?? requested
            #expect(result.transport.rawValue == expect["transport"] as? String, "\(caseID) transport")
            #expect(result.resolvedAPIBaseURL == expect["resolvedAPIBaseURL"] as? String, "\(caseID) API base")
            #expect(result.engineProfile == requested.engineProfile, "\(caseID) the engine identity must not change")
        }
    }

    @Test("migration runs once: the first load after upgrading switches transport, a later hand-picked native transport is kept, stored parameters stay")
    func migrationRunsOncePerAccount() throws {
        let suiteName = "llamacpp-channel-migration-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let providerID = UUID()
        defer { GenerationParameterSettingsStore.shared.setConnectionDefaults(nil, providerID: providerID) }
        var requested = RelayRequestedConfig(transport: .llamacppNative)
        requested.engineProfile = "llamacpp"
        requested.resolvedAPIBaseURL = "http://127.0.0.1:8080"
        let provider = Provider(
            id: providerID, kind: .relay, status: .connected,
            models: [TestFactories.makeModel(id: "relay-model", capabilities: [.text], isDefault: true)],
            catalogModels: [], apiKey: "", apiKeyPreview: "",
            baseURLText: "http://127.0.0.1:8080", relayRequested: requested
        )
        let stored = GenerationParameterOverrides(values: [
            "max_output_tokens": .init(state: .value, value: .number(256)),
            "n_probs": .init(state: .value, value: .number(3)),
        ])
        GenerationParameterSettingsStore.shared.setConnectionDefaults(stored, providerID: providerID)

        let state = AppState(seedDemoData: false, sessionUID: "llamacpp-migration-\(UUID().uuidString)")
        state.providers = [provider]
        state.migrateLlamaCppConnectionsToChatChannelIfNeeded(uid: "account-a", defaults: defaults)
        let migrated = try #require(state.providers.first?.relayRequested)
        #expect(migrated.transport == .openaiChatCompletions)
        #expect(migrated.resolvedAPIBaseURL == "http://127.0.0.1:8080/v1")
        #expect(GenerationParameterSettingsStore.shared.connectionDefaults(providerID: providerID) == stored)

        // The user later picks the native transport again: the next load must not rewrite it.
        var handPicked = try #require(state.providers.first)
        handPicked.relayRequested?.transport = .llamacppNative
        handPicked.relayRequested?.resolvedAPIBaseURL = "http://127.0.0.1:8080"
        state.providers = [handPicked]
        state.migrateLlamaCppConnectionsToChatChannelIfNeeded(uid: "account-a", defaults: defaults)
        #expect(state.providers.first?.relayRequested?.transport == .llamacppNative)

        // Another account partition has its own flag.
        state.migrateLlamaCppConnectionsToChatChannelIfNeeded(uid: "account-b", defaults: defaults)
        #expect(state.providers.first?.relayRequested?.transport == .openaiChatCompletions)
    }
}
