import Foundation
import SwiftUI
import Testing
@testable import Oriveo

/// Model > Advanced: asserts the page structure produced by `RelayModelAdvancedBoard`,
/// the four write functions of `ProviderManager`, and the effect of overrides at the three production consumers: attachment routing, image-generation dispatch and thinking controls.
@Suite("Relay 2.0 · model advanced page", .serialized)
@MainActor
struct RelayModelAdvancedBoardTests {
    typealias Board = RelayModelAdvancedBoard

    private static let partitionID = "relay-model-advanced-tests"
    private static var retainedStates: [AppState] = []

    // MARK: - Construction

    private static func model(
        _ id: String,
        capabilities: [ModelCapability] = [.text],
        transport: RelayTransport? = nil,
        source: RelayTransportSource? = nil,
        isDefault: Bool = false
    ) -> AIModel {
        var model = TestFactories.makeModel(id: id, capabilities: capabilities, isDefault: isDefault)
        model.relayTransport = transport
        model.relayTransportSource = transport == nil ? nil : (source ?? .observed)
        return model
    }

    private static func relayProvider(
        transport: RelayTransport = .auto,
        models: [AIModel],
        engineProfile: String? = nil
    ) -> Provider {
        var provider = TestFactories.makeProvider(
            kind: .relay,
            models: models,
            catalogModels: models,
            apiKey: engineProfile == nil ? "sk-test" : "",
            apiKeyPreview: engineProfile == nil ? "sk-…test" : "",
            baseURLText: engineProfile == nil ? "https://api.myrelay.dev" : "http://127.0.0.1:11434"
        )
        provider.relayRequested = RelayRequestedConfig(
            transport: transport,
            authMode: engineProfile == nil ? .bearer : RelayAuthMode.none,
            securityMode: engineProfile == nil ? .remoteHTTPS : .localHTTP,
            engineProfile: engineProfile
        )
        return provider
    }

    private static func board(
        _ provider: Provider,
        _ modelID: String,
        probe: Board.Probe? = nil,
        now: Date = Date()
    ) throws -> Board {
        let model = try #require(provider.models.first { $0.id == modelID })
        return Board.make(provider: provider, model: model, partitionID: partitionID, now: now, probe: probe)
    }

    private static func row(_ board: Board, _ capability: Board.Capability) throws -> Board.CapabilityRow {
        try #require(board.capabilityRows.first { $0.capability == capability })
    }

    private static func makeState(_ provider: Provider) -> AppState {
        let state = AppState(seedDemoData: false, sessionUID: "relay-advanced-\(UUID().uuidString)")
        state.providers = [provider]
        retainedStates.append(state)
        return state
    }

    /// The stored object after a production Codable round trip.
    private static func stored(_ state: AppState, _ providerID: UUID) throws -> Provider {
        let current = try #require(state.provider(for: providerID))
        return try JSONDecoder().decode(Provider.self, from: JSONEncoder().encode(current))
    }

    private static func fixtureURL(_ relative: String) throws -> URL {
        var cursor = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while cursor.path != "/" {
            let candidate = cursor.appendingPathComponent(relative)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            cursor.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }

    /// Shared Relay metadata fixture: the Chat envelope does not accept native files, while Messages / Responses / Gemini do.
    private static func loadRelayMetadata() async throws {
        let json = try String(contentsOf: fixtureURL("shared/test-fixtures/relay/metadata-fixture.json"), encoding: .utf8)
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(json: json)
    }

    /// Makes the production `CapabilityControlResolution.resolve` produce thinking levels for a Relay model:
    /// the snapshot carries a v2 runtime envelope plus the model's reasoning control (availableIntents keep the canonical ladder order).
    private static func loadRelayThinkingMetadata(modelID: String, intents: [String]) async throws {
        let runtime = try CapabilityRuntimeFixtures.runtimeEnvelopeJSON()
        let controls = try CapabilityRuntimeFixtures.controlsJSON(
            .init(capability: "reasoning", availableIntents: intents)
        )
        let json = """
        {
          "version": 1,
          "contractVersion": 1,
          "capabilityRuntime": \(runtime),
          "providers": {
            "relay": {
              "resolveMap": {"\(modelID)": "\(modelID)"},
              "models": {
                "\(modelID)": {
                  "canonicalModelId": "\(modelID)",
                  "transport": "openai_chat_completions",
                  "capabilities": ["text", "reasoning"],
                  "capabilityControls": \(controls)
                }
              }
            }
          }
        }
        """
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(json: json)
    }

    private static func textPdf() -> Oriveo.Attachment {
        Oriveo.Attachment(
            id: UUID(), kind: .file, fileName: "report.pdf", mimeType: "application/pdf",
            base64Data: Data("EXTRACTED-PDF-BODY".utf8).base64EncodedString(),
            extractedSizeBytes: 5_000, originalBase64Data: "JVBERi0xLjQ="
        )
    }

    /// The same chain of production calls as the `ChatManager` pre-send decision: route -> delivery model -> Relay negative-cache scope -> delivery plan.
    private static func plannedNativeCount(_ provider: Provider, _ model: AIModel, _ attachment: Oriveo.Attachment) throws -> Int {
        let transport = try #require(AttachmentTransportResolver.resolve(provider: provider, model: model, request: .init()))
        let deliveryModel = AttachmentTransportResolver.deliveryModel(provider: provider, model: model, transport: transport)
        let scope = NativeFileFallback.Scope.relayScope(
            RelayEndpointResolver.effectiveTransport(provider: provider, model: model),
            connectionID: provider.id, modelID: model.id,
            fileOverride: model.relayCapabilityOverrides?.file
        )
        let plan = NativeFileFallback.withKnownConnectionState(connectionID: provider.id, transport: transport, relay: scope) {
            AttachmentDelivery.plan(userText: "read", attachments: [attachment], transport: transport.profile, model: deliveryModel)
        }
        return plan.native.count
    }

    // MARK: - BOARD-ADVANCED-01

    @Test("BOARD-ADVANCED-01 page structure: Relay has five sections and five rows (web search added), the footer states that changes apply immediately and are stored on this device only, and the legend follows the connection; a local Channel is read-only, and only llama.cpp has a footnote")
    func advanced01Structure() throws {
        let relay = Self.relayProvider(models: [Self.model("gpt-4o-mini", isDefault: true)])
        let board = try Self.board(relay, "gpt-4o-mini")

        #expect(Board.segments == [.auto, .openaiChatCompletions, .openaiResponses, .anthropicMessages, .geminiGenerateContent])
        guard case let .relay(selected, _, _, _) = board.protocolRow else {
            Issue.record("A Relay connection should show the protocol segment: \(board.protocolRow)")
            return
        }
        #expect(selected == .auto)
        #expect(board.capabilityRows.map(\.capability) == [.image, .file, .imageGeneration, .toolCall, .web])
        #expect(Board.footerKey == "Changes apply right away and are saved only on this device.")
        #expect(board.legend == [.catalog, .detected, .tested, .user])
        #expect(board.modelName == "gpt-4o-mini")
        #expect(board.host == "api.myrelay.dev")

        let ollama = Self.relayProvider(models: [Self.model("llama3", isDefault: true)], engineProfile: "ollama")
        let ollamaBoard = try Self.board(ollama, "llama3")
        #expect(ollamaBoard.protocolRow == .local(channel: .openaiChatCompletions, showsChannelHint: false))
        #expect(ollamaBoard.legend == [.engine, .user])
        #expect(ollamaBoard.thinking == nil, "A local engine shows no thinking section")
        #expect(ollamaBoard.capabilityRows.count == 5)

        let llama = Self.relayProvider(
            transport: .llamacppNative, models: [Self.model("qwen-local", isDefault: true)], engineProfile: "llamacpp"
        )
        #expect(try Self.board(llama, "qwen-local").protocolRow == .local(channel: .llamacppNative, showsChannelHint: true))
    }

    // MARK: - BOARD-ADVANCED-02

    @Test("BOARD-ADVANCED-02 protocol description row: a non-user source selects Auto + \"Auto = effectiveTransport\"; four status words; the root address takes the path of effectiveAPIRoot")
    func advanced02ProtocolExplain() throws {
        let models = [
            Self.model("reachable", transport: .anthropicMessages, source: .reachable, isDefault: true),
            Self.model("observed", transport: .openaiResponses, source: .observed),
            Self.model("follows"),
            Self.model("pinned", transport: .geminiGenerateContent, source: .user),
        ]
        let provider = Self.relayProvider(models: models)

        func explain(_ id: String) throws -> (RelayTransport, Board.AutoMeaning?, Board.ProtocolStatus, String) {
            guard case let .relay(selected, auto, status, apiRootPath) = try Self.board(provider, id).protocolRow else {
                throw CocoaError(.featureUnsupported)
            }
            return (selected, auto, status, apiRootPath)
        }

        for (id, expected, status) in [
            ("reachable", RelayTransport.anthropicMessages, Board.ProtocolStatus.reachable),
            ("observed", .openaiResponses, .verified),
            ("follows", .openaiChatCompletions, .unknownUntilSent),
        ] {
            let model = try #require(provider.models.first { $0.id == id })
            #expect(RelayEndpointResolver.effectiveTransport(provider: provider, model: model) == expected)
            let (selected, auto, actualStatus, apiRootPath) = try explain(id)
            #expect(selected == .auto, "\(id)")
            #expect(auto == .detected(expected), "\(id)")
            #expect(actualStatus == status, "\(id)")
            let root = RelayEndpointResolver.effectiveAPIRoot(provider: provider, model: model)
            #expect(apiRootPath == URL(string: root)?.path, "\(id) \(root)")
            #expect(apiRootPath.hasPrefix("/"), "\(id)")
        }

        let (selected, auto, status, _) = try explain("pinned")
        #expect(selected == .geminiGenerateContent)
        #expect(auto == nil, "\"Auto = …\" appears only when Auto is selected")
        #expect(status == .setByYou)
        #expect(Board.ProtocolStatus.notReachable.key == "Not reachable")
        #expect(Board.ProtocolStatus.unknownUntilSent.key == "Unknown · remembered after sending")
    }

    // MARK: - BOARD-ADVANCED-03

    @Test("BOARD-ADVANCED-03 protocol write: choosing Chat writes both user tables; only this one protocol is probed, and the result is displayed without changing the source; choosing Auto clears it")
    func advanced03ProtocolWrite() async throws {
        let provider = Self.relayProvider(models: [Self.model("m1", transport: .anthropicMessages, source: .reachable, isDefault: true)])
        let state = Self.makeState(provider)
        let manager = state.providerManager

        manager.setRelayModelTransport(providerID: provider.id, modelID: "m1", transport: .openaiChatCompletions)
        var stored = try Self.stored(state, provider.id)
        #expect(stored.models.first?.relayTransport == .openaiChatCompletions)
        #expect(stored.models.first?.relayTransportSource == .user)
        #expect(stored.catalogModels.first?.relayTransport == .openaiChatCompletions)
        #expect(stored.catalogModels.first?.relayTransportSource == .user)

        // Fake probe service: records the route used by each 1-token request.
        var pinged: [RelayTransport?] = []
        let passed = await manager.probeRelayModelTransportOnce(
            providerID: provider.id, modelID: "m1", transport: .openaiChatCompletions
        ) { routed, modelID in
            #expect(modelID == "m1")
            pinged.append(routed?.transport)
        }
        #expect(passed == true)
        #expect(pinged.count == 1, "Only the one protocol the user chose is probed")
        stored = try Self.stored(state, provider.id)
        #expect(stored.models.first?.relayTransportSource == .user, "A passing probe does not rewrite the source")
        let reachable = try Self.board(stored, "m1", probe: .init(transport: .openaiChatCompletions, state: .reachable))
        guard case let .relay(_, _, reachableStatus, _) = reachable.protocolRow else { throw CocoaError(.featureUnsupported) }
        #expect(reachableStatus == .reachable)

        let failed = await manager.probeRelayModelTransportOnce(
            providerID: provider.id, modelID: "m1", transport: .openaiChatCompletions
        ) { _, _ in
            throw URLError(.badServerResponse)
        }
        #expect(failed == false)
        stored = try Self.stored(state, provider.id)
        #expect(stored.models.first?.relayTransport == .openaiChatCompletions)
        #expect(stored.models.first?.relayTransportSource == .user, "A failure keeps the user value")
        let notReachable = try Self.board(stored, "m1", probe: .init(transport: .openaiChatCompletions, state: .notReachable))
        guard case let .relay(_, _, failedStatus, _) = notReachable.protocolRow else { throw CocoaError(.featureUnsupported) }
        #expect(failedStatus == .notReachable)
        let testing = try Self.board(stored, "m1", probe: .init(transport: .openaiChatCompletions, state: .testing))
        guard case let .relay(_, _, testingStatus, _) = testing.protocolRow else { throw CocoaError(.featureUnsupported) }
        #expect(testingStatus == .testing)
        // A result that belongs to another protocol (the user has since picked a different one) is not shown.
        let stale = try Self.board(stored, "m1", probe: .init(transport: .anthropicMessages, state: .notReachable))
        guard case let .relay(_, _, staleStatus, _) = stale.protocolRow else { throw CocoaError(.featureUnsupported) }
        #expect(staleStatus == .setByYou)

        manager.setRelayModelTransport(providerID: provider.id, modelID: "m1", transport: nil)
        stored = try Self.stored(state, provider.id)
        #expect(stored.models.first?.relayTransport == nil)
        #expect(stored.models.first?.relayTransportSource == nil)
        #expect(stored.catalogModels.first?.relayTransport == nil)
    }

    // MARK: - BOARD-ADVANCED-04

    @Test("BOARD-ADVANCED-04 four-row status and source order: user > tested > engine declaration > negative cache > official catalog > none; unknown image generation uses Unknown")
    func advanced04StateAndSource() async throws {
        try await Self.loadRelayMetadata()
        let cache = RelayNegativeCache.shared

        var userImage = Self.model("user-image", isDefault: true)
        userImage.relayCapabilityOverrides = RelayCapabilityOverrides(image: true, source: .user)
        var testedTool = Self.model("tested-tool")
        testedTool.relayCapabilityOverrides = RelayCapabilityOverrides(toolCall: false, source: .tested)
        testedTool.toolCall = true
        let rejected = Self.model("rejected")
        var catalog = Self.model("catalog", capabilities: [.text, .image, .imageGen])
        catalog.nativeFileMimes = ["application/pdf"]
        catalog.toolCall = true
        var declared = Self.model("declared")
        declared.engineDeclaration = EngineDeclaration(image: true, toolCall: false)
        let bare = Self.model("bare")

        let provider = Self.relayProvider(models: [userImage, testedTool, rejected, catalog, declared, bare])
        let connectionID = provider.id.uuidString
        defer { cache.clearConnection(connectionID) }
        let chat = RelayTransport.openaiChatCompletions.rawValue
        cache.record(connectionID: connectionID, modelID: "user-image", transport: chat, kind: .image)
        for kind in RelayNegativeCache.Kind.allCases {
            cache.record(connectionID: connectionID, modelID: "rejected", transport: chat, kind: kind)
        }

        let user = try Self.row(Self.board(provider, "user-image"), .image)
        #expect(user.source == .user)
        #expect(user.state == .supported)
        #expect(user.control == .on)

        let tested = try Self.row(Self.board(provider, "tested-tool"), .toolCall)
        #expect(tested.source == .tested, "tested overrides the tool declaration carried by the model")
        #expect(tested.state == .unsupported)
        #expect(tested.control == .off)

        let rejectedBoard = try Self.board(provider, "rejected")
        for capability in [Board.Capability.image, .file, .toolCall] {
            #expect(try Self.row(rejectedBoard, capability).source == .detected, "\(capability)")
            #expect(try Self.row(rejectedBoard, capability).state == .unsupported, "\(capability)")
            #expect(try Self.row(rejectedBoard, capability).control == .auto, "\(capability)")
        }
        // Once the negative cache expires it is no longer Detected.
        let later = Date().addingTimeInterval(RelayNegativeCache.ttl + 60)
        #expect(try Self.row(Self.board(provider, "rejected", now: later), .image).source == nil)

        let catalogBoard = try Self.board(provider, "catalog")
        // The web row does not inherit from the catalog (only overrides and probe records count).
        for capability in Board.Capability.allCases where capability != .web {
            #expect(try Self.row(catalogBoard, capability).source == .catalog, "\(capability)")
        }
        #expect(try Self.row(catalogBoard, .imageGeneration).state == .supported)
        #expect(try Self.row(catalogBoard, .file).state == .supported)

        // An engine declaration counts as a source only when the connection has an engineProfile.
        let remoteDeclared = try Self.board(provider, "declared")
        #expect(try Self.row(remoteDeclared, .image).source == nil)
        let local = Self.relayProvider(models: [declared], engineProfile: "ollama")
        let localBoard = try Self.board(local, "declared")
        #expect(try Self.row(localBoard, .image).source == .engine)
        #expect(try Self.row(localBoard, .image).state == .supported)
        #expect(try Self.row(localBoard, .toolCall).source == .engine)
        #expect(try Self.row(localBoard, .toolCall).state == .unsupported)
        // A local connection draws only engine declaration / manual / tested sources; inheritance from the official catalog draws no source.
        var localInherited = Self.model("local-inherited")
        localInherited.capabilities.append(.image)
        localInherited.nativeFileMimes = ["application/pdf"]
        let localInheritedBoard = try Self.board(
            Self.relayProvider(models: [localInherited], engineProfile: "ollama"), "local-inherited"
        )
        #expect(try Self.row(localInheritedBoard, .file).source == nil)
        #expect(try Self.row(localInheritedBoard, .imageGeneration).source == nil)

        let bareBoard = try Self.board(provider, "bare")
        for capability in Board.Capability.allCases {
            #expect(try Self.row(bareBoard, capability).source == nil, "\(capability)")
            #expect(try Self.row(bareBoard, capability).control == .auto, "\(capability)")
        }
        #expect(try Self.row(bareBoard, .imageGeneration).state == .unknown)
        #expect(Board.Capability.imageGeneration.unknownKey == "Unknown", "Image generation has no remember-after-send mechanism")
    }

    // MARK: - BOARD-ADVANCED-05

    @Test("BOARD-ADVANCED-05 override write: On / Off write both user tables and clear the negative cache of the same kind; Auto deletes the key (both tested and user entries)")
    func advanced05OverrideWrite() throws {
        var model = Self.model("m1", isDefault: true)
        model.relayCapabilityOverrides = RelayCapabilityOverrides(toolCall: true, source: .tested)
        let provider = Self.relayProvider(models: [model])
        let state = Self.makeState(provider)
        let manager = state.providerManager
        let cache = RelayNegativeCache.shared
        let connectionID = provider.id.uuidString
        defer { cache.clearConnection(connectionID) }
        let chat = RelayTransport.openaiChatCompletions.rawValue
        for kind in RelayNegativeCache.Kind.allCases {
            cache.record(connectionID: connectionID, modelID: "m1", transport: chat, kind: kind)
        }
        func rejected(_ kind: RelayNegativeCache.Kind) -> Bool {
            cache.isRejected(connectionID: connectionID, modelID: "m1", transport: chat, kind: kind)
        }

        manager.setRelayCapabilityOverride(providerID: provider.id, modelID: "m1", key: .image, value: true)
        var stored = try Self.stored(state, provider.id)
        for models in [stored.models, stored.catalogModels] {
            #expect(models.first?.relayCapabilityOverrides?.image == true)
            #expect(models.first?.relayCapabilityOverrides?.sources[.image] == .user)
        }
        #expect(!rejected(.image))
        #expect(rejected(.file) && rejected(.toolCall), "Only the same kind is cleared")

        manager.setRelayCapabilityOverride(providerID: provider.id, modelID: "m1", key: .file, value: false)
        manager.setRelayCapabilityOverride(providerID: provider.id, modelID: "m1", key: .imageGeneration, value: true)
        stored = try Self.stored(state, provider.id)
        #expect(stored.models.first?.relayCapabilityOverrides?.file == false)
        #expect(stored.models.first?.relayCapabilityOverrides?.sources[.file] == .user)
        #expect(stored.catalogModels.first?.relayCapabilityOverrides?.imageGeneration == true)
        #expect(!rejected(.file))
        #expect(rejected(.toolCall))
        let board = try Self.board(stored, "m1")
        #expect(try Self.row(board, .file).control == .off)
        #expect(try Self.row(board, .imageGeneration).control == .on)
        #expect(try Self.row(board, .imageGeneration).source == .user)

        // Auto deletes the key: tested entries are deleted too.
        manager.setRelayCapabilityOverride(providerID: provider.id, modelID: "m1", key: .toolCall, value: nil)
        manager.setRelayCapabilityOverride(providerID: provider.id, modelID: "m1", key: .image, value: nil)
        stored = try Self.stored(state, provider.id)
        let overrides = stored.models.first?.relayCapabilityOverrides
        #expect(overrides?.toolCall == nil)
        #expect(overrides?.sources[.toolCall] == nil)
        #expect(overrides?.image == nil)
        #expect(stored.catalogModels.first?.relayCapabilityOverrides?.toolCall == nil)
        #expect(rejected(.toolCall), "Choosing Auto does not clear the negative cache")

        manager.setRelayCapabilityOverride(providerID: provider.id, modelID: "m1", key: .file, value: nil)
        manager.setRelayCapabilityOverride(providerID: provider.id, modelID: "m1", key: .imageGeneration, value: nil)
        #expect(try Self.stored(state, provider.id).models.first?.relayCapabilityOverrides == nil, "The field is omitted once emptied")
    }

    // MARK: - BOARD-ADVANCED-06

    @Test("BOARD-ADVANCED-06 five thinking cells: levels outside the automatic set are struck through, overrides only narrow, the last cell cannot be deselected, choosing the full set deletes the override, a local engine shows no section, and an empty set shows no card")
    func advanced06Thinking() async throws {
        try await Self.loadRelayThinkingMetadata(modelID: "thinker", intents: ["off", "low", "balanced", "deep"])
        let provider = Self.relayProvider(models: [Self.model("thinker", isDefault: true), Self.model("plain")])
        let state = Self.makeState(provider)
        let manager = state.providerManager

        let thinker = try #require(provider.models.first)
        #expect(RelayReasoningLevelOverride.automaticModes(provider: provider, model: thinker) == [.fast, .balanced, .deep])
        guard case let .cells(cells)? = try Self.board(provider, "thinker").thinking else {
            Issue.record("Five cells are expected when automatic levels exist")
            return
        }
        #expect(cells.map(\.mode) == [.automatic, .fast, .balanced, .deep, .max])
        #expect(cells.map(\.isAvailable) == [false, true, true, true, false])
        #expect(cells.map(\.isSelected) == [false, true, true, true, false])
        #expect(cells.map(\.isToggleable) == [false, true, true, true, false], "A struck-through cell is not tappable")
        #expect(Board.levelsAfterToggling(.max, cells: cells) == nil)

        let narrowed = try #require(Board.levelsAfterToggling(.deep, cells: cells))
        #expect(narrowed == ["fast", "balanced"])
        manager.setRelayReasoningLevels(providerID: provider.id, modelID: "thinker", levels: narrowed)
        var stored = try Self.stored(state, provider.id)
        #expect(stored.models.first?.relayCapabilityOverrides?.reasoningLevels == ["fast", "balanced"])
        #expect(stored.catalogModels.first?.relayCapabilityOverrides?.reasoningLevels == ["fast", "balanced"])
        #expect(stored.models.first?.relayCapabilityOverrides?.sources[.reasoningLevels] == .user)

        // Narrow only: levels written outside the automatic set are dropped.
        manager.setRelayReasoningLevels(providerID: provider.id, modelID: "thinker", levels: ["fast", "max"])
        stored = try Self.stored(state, provider.id)
        #expect(stored.models.first?.relayCapabilityOverrides?.reasoningLevels == ["fast"])

        guard case let .cells(single)? = try Self.board(stored, "thinker").thinking else {
            Issue.record("Five cells are expected")
            return
        }
        #expect(single.map(\.isSelected) == [false, true, false, false, false])
        #expect(single.first { $0.mode == .fast }?.isToggleable == false, "The last selected cell cannot be deselected")
        #expect(Board.levelsAfterToggling(.fast, cells: single) == nil)

        // Selecting back to the automatic set deletes the override.
        manager.setRelayReasoningLevels(providerID: provider.id, modelID: "thinker", levels: ["deep", "balanced", "fast"])
        stored = try Self.stored(state, provider.id)
        #expect(stored.models.first?.relayCapabilityOverrides == nil)

        #expect(try Self.board(provider, "plain").thinking == nil, "An empty automatic set hides the whole card")
        let local = Self.relayProvider(models: [Self.model("thinker", isDefault: true)], engineProfile: "ollama")
        #expect(try Self.board(local, "thinker").thinking == nil)
    }

    // MARK: - BOARD-ADVANCED-07

    @Test("BOARD-ADVANCED-07 restore all to automatic: clears all overrides and the user protocol, keeps the negative cache, is not tappable when there is nothing to clear; capability testing lives on this page and the row menu no longer has test / restore")
    func advanced07RestoreAll() throws {
        var full = Self.model("full", transport: .anthropicMessages, source: .user, isDefault: true)
        var overrides = RelayCapabilityOverrides(image: true, file: false, reasoningLevels: ["fast"], source: .user)
        overrides.toolCall = false
        overrides.sources[.toolCall] = .tested
        full.relayCapabilityOverrides = overrides
        var testedOnly = Self.model("tested-only", transport: .openaiResponses, source: .reachable)
        testedOnly.relayCapabilityOverrides = RelayCapabilityOverrides(image: false, source: .tested)
        let clean = Self.model("clean", transport: .openaiResponses, source: .observed)
        let provider = Self.relayProvider(models: [full, testedOnly, clean])
        let state = Self.makeState(provider)
        let manager = state.providerManager
        let cache = RelayNegativeCache.shared
        let connectionID = provider.id.uuidString
        defer { cache.clearConnection(connectionID) }
        let messages = RelayTransport.anthropicMessages.rawValue
        cache.record(connectionID: connectionID, modelID: "full", transport: messages, kind: .image)

        #expect(try Self.board(provider, "full").restoreAllEnabled)
        #expect(try Self.board(provider, "tested-only").restoreAllEnabled)
        #expect(try Self.board(provider, "clean").restoreAllEnabled == false)
        #expect(try Self.board(provider, "full").showsTestEntry == RelayCapabilityTest.showsEntry(provider: provider, model: full))
        #expect(try Self.board(provider, "clean").showsTestEntry)

        manager.restoreRelayModelAllAutomatic(providerID: provider.id, modelID: "full")
        manager.restoreRelayModelAllAutomatic(providerID: provider.id, modelID: "tested-only")
        let stored = try Self.stored(state, provider.id)
        for models in [stored.models, stored.catalogModels] {
            let restored = try #require(models.first { $0.id == "full" })
            #expect(restored.relayCapabilityOverrides == nil)
            #expect(restored.relayTransport == nil)
            #expect(restored.relayTransportSource == nil)
            let kept = try #require(models.first { $0.id == "tested-only" })
            #expect(kept.relayCapabilityOverrides == nil)
            #expect(kept.relayTransport == .openaiResponses, "A protocol from a non-user source is not cleared")
            #expect(kept.relayTransportSource == .reachable)
        }
        #expect(cache.isRejected(connectionID: connectionID, modelID: "full", transport: messages, kind: .image), "The negative cache is not cleared")
        #expect(try Self.board(stored, "full").restoreAllEnabled == false)

        #expect(ProviderEnabledModelRow.menuItems(canSetDefault: true, canRemove: true) == [.setDefault, .remove])
        #expect(ProviderEnabledModelRow.menuItems(canSetDefault: false, canRemove: true) == [.remove])
    }

    // MARK: - BOARD-ADVANCED-08

    @Test("BOARD-ADVANCED-08 file override through the production attachment route: On -> native, Off -> text, envelope does not accept -> text, On overrides the file negative cache")
    func advanced08FileOverride() async throws {
        try await Self.loadRelayMetadata()
        let cache = RelayNegativeCache.shared

        let automatic = Self.model("auto-file", transport: .anthropicMessages, source: .user, isDefault: true)
        var on = Self.model("on-file", transport: .anthropicMessages, source: .user)
        on.relayCapabilityOverrides = RelayCapabilityOverrides(file: true, source: .user)
        var offAuto = Self.model("off-auto", transport: .anthropicMessages, source: .user)
        offAuto.nativeFileMimes = ["application/pdf"]
        offAuto.pdfNativeDefault = true
        var off = Self.model("off-file", transport: .anthropicMessages, source: .user)
        off.nativeFileMimes = ["application/pdf"]
        off.pdfNativeDefault = true
        off.relayCapabilityOverrides = RelayCapabilityOverrides(file: false, source: .user)
        var chatOn = Self.model("chat-on", transport: .openaiChatCompletions, source: .user)
        chatOn.relayCapabilityOverrides = RelayCapabilityOverrides(file: true, source: .user)

        let provider = Self.relayProvider(models: [automatic, on, off, offAuto, chatOn])
        let connectionID = provider.id.uuidString
        defer { cache.clearConnection(connectionID) }
        let pdf = Self.textPdf()

        #expect(try Self.plannedNativeCount(provider, automatic, pdf) == 0, "Automatic with an empty allowlist -> text")
        #expect(try Self.plannedNativeCount(provider, on, pdf) == 1, "On -> native")
        let deliveryOn = AttachmentTransportResolver.deliveryModel(provider: provider, model: on, transport: .relayAnthropicMessages)
        #expect(deliveryOn.nativeFileMimes.contains("application/pdf"))
        #expect(deliveryOn.pdfNativeDefault)
        #expect(try Self.plannedNativeCount(provider, offAuto, pdf) == 1, "Control: native when inheriting the allowlist")
        #expect(try Self.plannedNativeCount(provider, off, pdf) == 0, "Off -> text")
        #expect(try Self.plannedNativeCount(provider, chatOn, pdf) == 0, "The envelope does not accept file blocks -> still text")

        let messages = RelayTransport.anthropicMessages.rawValue
        cache.record(connectionID: connectionID, modelID: "on-file", transport: messages, kind: .file)
        cache.record(connectionID: connectionID, modelID: "off-auto", transport: messages, kind: .file)
        #expect(try Self.plannedNativeCount(provider, offAuto, pdf) == 0, "Control: automatic with a file negative cache -> text")
        #expect(try Self.plannedNativeCount(provider, on, pdf) == 1, "On overrides the file negative cache")
    }

    // MARK: - BOARD-ADVANCED-09

    @Test("BOARD-ADVANCED-09 image-generation override through the production dispatch decision: true -> image generation, false -> not (even if the capabilities include it)")
    func advanced09ImageGenerationOverride() throws {
        var forcedOn = Self.model("forced-on", transport: .openaiResponses, source: .user, isDefault: true)
        forcedOn.relayCapabilityOverrides = RelayCapabilityOverrides(imageGeneration: true, source: .user)
        var forcedOff = Self.model("forced-off", capabilities: [.text, .imageGen], transport: .openaiResponses, source: .user)
        forcedOff.relayCapabilityOverrides = RelayCapabilityOverrides(imageGeneration: false, source: .user)
        let inherited = Self.model("inherited", capabilities: [.text, .imageGen], transport: .openaiResponses, source: .user)
        let plain = Self.model("plain", transport: .openaiResponses, source: .user)
        let provider = Self.relayProvider(models: [forcedOn, forcedOff, inherited, plain])

        #expect(RelayRuntimeSupport.dispatchesImageGeneration(model: forcedOn))
        #expect(RelayRuntimeSupport.dispatchesImageGeneration(model: forcedOff) == false)
        #expect(RelayRuntimeSupport.dispatchesImageGeneration(model: inherited))
        #expect(RelayRuntimeSupport.dispatchesImageGeneration(model: plain) == false)

        // Attachment route prediction uses the same decision as image dispatch: no chat route is predicted when image generation is used.
        #expect(AttachmentTransportResolver.resolve(provider: provider, model: forcedOn, request: .init()) == nil)
        #expect(AttachmentTransportResolver.resolve(provider: provider, model: forcedOff, request: .init()) == .relayOpenAIResponses)
        #expect(AttachmentTransportResolver.resolve(provider: provider, model: inherited, request: .init()) == nil)
        #expect(AttachmentTransportResolver.resolve(provider: provider, model: plain, request: .init()) == .relayOpenAIResponses)
    }

    // MARK: - BOARD-ADVANCED-10

    @Test("BOARD-ADVANCED-10 thinking override through the production CapabilityControlResolution.resolve: available levels = automatic ∩ override, and the off switch is unaffected")
    func advanced10ReasoningLevelsConsumption() async throws {
        try await Self.loadRelayThinkingMetadata(modelID: "thinker", intents: ["off", "low", "balanced", "deep", "max"])
        var model = Self.model("thinker", isDefault: true)
        let provider = Self.relayProvider(models: [model])

        #expect(CapabilityControlResolution.resolve(provider: provider, model: model, capability: "reasoning").intents
            == ["off", "low", "balanced", "deep", "max"])

        model.relayCapabilityOverrides = RelayCapabilityOverrides(reasoningLevels: ["fast", "deep"], source: .user)
        let verdict = CapabilityControlResolution.resolve(provider: provider, model: model, capability: "reasoning")
        #expect(verdict.intents == ["off", "low", "deep"])
        #expect(verdict.state == .autoAvailable)
        // The automatic set (the criterion for strike-through on the page) is not affected by the override.
        #expect(RelayReasoningLevelOverride.automaticModes(provider: provider, model: model) == [.fast, .balanced, .deep, .max])
        // The override affects thinking only and never touches web search.
        #expect(CapabilityControlResolution.resolve(provider: provider, model: model, capability: "web").intents.isEmpty)
    }

    // MARK: - BOARD-ADVANCED-11

    /// On the manage-models page, tapping the whole row opens "Model > Advanced", and starting a new chat moves to an explicit button at the end of the row.
    @Test("BOARD-ADVANCED-11 enabled row: tapping the whole row opens the advanced page, and the trailing button starts a new chat")
    func advanced11RowActions() {
        let model = Self.model("m1", isDefault: true)
        let provider = Self.relayProvider(models: [model])
        var opened: [String] = []
        let row = ProviderEnabledModelRow(
            model: model,
            provider: provider,
            capabilityEvidenceRevision: 1,
            isHighlighted: false,
            isMissingFromCatalog: false,
            isLast: true,
            canSetDefault: false,
            canRemove: true,
            setDefaultAction: { opened.append("default") },
            chatAction: { opened.append("chat") },
            removeAction: { opened.append("remove") },
            advancedAction: { opened.append("advanced") },
            catalogBoard: RelayCatalogBoardContext(partitionID: Self.partitionID, filter: .all)
        )
        // The row model supplies the destination and the trailing order, and the view's two tap areas dispatch accordingly.
        let boardRow = RelayCatalogBoardModel.row(
            provider: provider, model: model, section: .enabled, isMissingFromCatalog: false, partitionID: Self.partitionID
        )
        #expect(boardRow.tapTarget == .advanced)
        #expect(boardRow.trailing == [.newChat, .more])
        row.perform(.row)
        row.perform(.trailing)
        #expect(opened == ["advanced", "chat"])
    }

    // MARK: - BOARD-ADVANCED-12

    /// Two keys: the primary key "Main" lists only gpt-*, and the second key "Claude only" lists only claude-*; when several keys in the catalog share a family, the rule looks at enabled models of that family.
    private static func twoKeyProvider(boundKeyID: String?) -> Provider {
        var enabled = Self.model("claude-opus-4")
        enabled.relayKeyID = boundKeyID
        var gpt = Self.model("gpt-5")
        gpt.relayListedByKeyIDs = ["initial"]
        var claudeCatalog = Self.model("claude-opus-4")
        claudeCatalog.relayListedByKeyIDs = ["k-claude"]
        var provider = Self.relayProvider(models: [enabled])
        provider.catalogModels = [gpt, claudeCatalog]
        provider.relayKeys = [
            RelayKey(id: "initial", name: "Main"),
            RelayKey(id: "k-claude", name: "Claude only", apiKey: "sk-claude-2222-3333"),
        ]
        return provider
    }

    @Test("BOARD-ADVANCED-12 Key section: shown only with 2 or more keys; current binding + a menu with Auto and every key; shows Auto when it equals the rule result; choosing a key / Auto writes back through rebind")
    func advanced12KeySection() async throws {
        // Currently bound to the primary key, but only the second key lists it in its catalog: the rule result is the second key, and the menu does not show Auto.
        let provider = Self.twoKeyProvider(boundKeyID: "initial")
        let board = try Self.board(provider, "claude-opus-4")
        let section = try #require(board.keySection)
        let keyRows = RelayKeysBoardModel.make(provider).rows
        #expect(section.options.map(\.id) == ["initial", "k-claude"])
        #expect(section.options.map(\.title) == ["Main", "Claude only"])
        #expect(section.options.map(\.maskedSecret) == keyRows.map(\.maskedSecret))
        #expect(section.current.id == "initial")
        #expect(section.autoKeyID == "k-claude")
        #expect(!section.isAuto)
        #expect(Board.keySectionKey == "Key")
        #expect(Board.keyAutoHintKey == "Auto = a key that lists this model")

        // Choosing Auto picks the rule's key; choosing a key picks that key; choosing the current key writes nothing.
        #expect(Board.keyOperation(.auto, section: section, modelID: "claude-opus-4") == .rebind(modelID: "claude-opus-4", keyID: "k-claude"))
        #expect(Board.keyOperation(.key("k-claude"), section: section, modelID: "claude-opus-4") == .rebind(modelID: "claude-opus-4", keyID: "k-claude"))
        #expect(Board.keyOperation(.key("initial"), section: section, modelID: "claude-opus-4") == nil)

        // Production write-back: after rebind, recompute; current = rule result -> shows Auto.
        let state = Self.makeState(provider)
        let operation = try #require(Board.keyOperation(.auto, section: section, modelID: "claude-opus-4"))
        #expect(await state.providerManager.applyRelayKeyOperation(providerID: provider.id, operation))
        let stored = try Self.stored(state, provider.id)
        #expect(stored.models.first { $0.id == "claude-opus-4" }?.relayKeyID == "k-claude")
        let rebound = try #require(try Self.board(stored, "claude-opus-4").keySection)
        #expect(rebound.current.id == "k-claude")
        #expect(rebound.isAuto)

        // One key: no Key section.
        var single = provider
        single.relayKeys = nil
        #expect(try Self.board(single, "claude-opus-4").keySection == nil)
    }

    // MARK: - BOARD-ADVANCED-13

    @Test("BOARD-ADVANCED-13 read-only advanced reached from a catalog row: one line at the top, all controls inoperable, no capability test; opening makes zero network requests")
    func advanced13ReadOnly() async throws {
        let stub = RelaySetupHTTPStub()
        var provider = Self.twoKeyProvider(boundKeyID: nil)
        provider.baseURLText = stub.endpoint + "/v1"
        let catalogOnly = try #require(provider.catalogModels.first { $0.id == "gpt-5" })
        #expect(!provider.models.contains { $0.id == "gpt-5" })

        let board = Board.make(provider: provider, model: catalogOnly, partitionID: Self.partitionID, readOnly: true)
        #expect(board.isReadOnly)
        #expect(Board.readOnlyNoteKey == "Not enabled yet. View only. No request is sent.")
        #expect(!board.showsTestEntry)
        #expect(!board.restoreAllEnabled)
        #expect(!board.controlsEnabled)
        // Read-only also shows the Key section (inoperable), with current = the key the rule would pick, shown as Auto.
        let section = try #require(board.keySection)
        #expect(section.current.id == "initial")
        #expect(section.isAuto)
        #expect(Board.keyOperation(.key("k-claude"), section: section, modelID: "gpt-5", readOnly: true) == nil)
        #expect(Board.make(provider: provider, model: provider.models[0], partitionID: Self.partitionID).controlsEnabled)

        // Production page: mount it via the read-only advanced route, run a few layout passes, and the fake relay receives no request at all.
        let state = AppState(
            seedDemoData: false,
            sessionUID: "relay-advanced-ro-\(UUID().uuidString)",
            providerSession: RelaySetupHTTPStub.session()
        )
        state.providers = [provider]
        Self.retainedStates.append(state)
        state.navigation.reset(to: [.providerDetail(providerID: provider.id), .relayModelLibrary(providerID: provider.id)])
        state.openRelayModelAdvanced(providerID: provider.id, modelID: "gpt-5", readOnly: true)
        let root = NavigationStack {
            ProviderDetailView(providerID: provider.id, page: .modelAdvanced(modelID: "gpt-5", readOnly: true))
        }
        .environment(state)
        let host = UIHostingController(rootView: root)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.rootViewController = host
        window.isHidden = false
        for _ in 0..<6 {
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(50))
        }
        window.isHidden = true
        #expect(stub.requests.isEmpty, "Opening read-only advanced must not send requests: \(stub.requests)")
        #expect(state.provider(for: provider.id)?.models.map(\.id) == ["claude-opus-4"], "Read-only advanced does not enable the model")
    }

    // MARK: - BOARD-ADVANCED-14

    @Test("BOARD-ADVANCED-14 protocol card has two description lines: connection auto -> \"Auto = detected result\"; connection pinned -> \"Auto = this connection default protocol\"; model-level setting -> only the status line")
    func advanced14ProtocolExplainLines() throws {
        let models = [
            Self.model("detected", transport: .anthropicMessages, source: .reachable, isDefault: true),
            Self.model("follows"),
            Self.model("pinned", transport: .geminiGenerateContent, source: .user),
        ]
        func explain(_ provider: Provider, _ id: String) throws -> Board.ProtocolExplain {
            try #require(try Self.board(provider, id).protocolRow.explain, "\(id)")
        }
        func rootPart(_ provider: Provider, _ id: String) throws -> Board.ExplainPart {
            let model = try #require(provider.models.first { $0.id == id })
            let root = RelayEndpointResolver.effectiveAPIRoot(provider: provider, model: model)
            return Board.ExplainPart(key: "API root %@", table: .providers, argument: URL(string: root)?.path)
        }
        func name(_ transport: RelayTransport) -> String { RelayProtocolMix.legendName(transport) }

        // Connection protocol is auto: the first line is the protocol that was detected or fallen back to.
        let auto = Self.relayProvider(models: models)
        let detected = try explain(auto, "detected")
        #expect(detected.autoLine == Board.ExplainPart(key: "Auto = %@", table: .providers, argument: name(.anthropicMessages)))
        let detectedRoot = try rootPart(auto, "detected")
        #expect(detected.detailLine == [Board.ExplainPart(key: "Reachable", table: .providers), detectedRoot])
        let unknown = try explain(auto, "follows")
        #expect(unknown.autoLine == Board.ExplainPart(key: "Auto = %@", table: .providers, argument: name(.openaiChatCompletions)))
        let unknownRoot = try rootPart(auto, "follows")
        #expect(unknown.detailLine == [
            Board.ExplainPart(key: "Unknown · remembered after sending", table: .chat), unknownRoot,
        ])

        // Connection protocol pinned: a model without its own protocol follows the connection, and the first line no longer reads as the detected result.
        let fixed = Self.relayProvider(transport: .openaiResponses, models: models)
        let followsModel = try #require(fixed.models.first { $0.id == "follows" })
        #expect(RelayProbeCandidates.followsUserChosenConnection(provider: fixed, model: followsModel))
        let follows = try explain(fixed, "follows")
        #expect(follows.autoLine == Board.ExplainPart(
            key: "Auto = this connection's default protocol (%@)", table: .providers, argument: name(.openaiResponses)
        ))
        let followsRoot = try rootPart(fixed, "follows")
        #expect(follows.detailLine == [Board.ExplainPart(key: "Set by you", table: .providers), followsRoot])
        // A model whose protocol was detected before the connection was pinned does not follow the connection and still reads "Auto = detected result".
        let kept = try explain(fixed, "detected")
        #expect(kept.autoLine == Board.ExplainPart(key: "Auto = %@", table: .providers, argument: name(.anthropicMessages)))
        #expect(kept.detailLine.first == Board.ExplainPart(key: "Reachable", table: .providers))

        // The model sets its own protocol: there is no Auto line, the status and root address stay on one line, regardless of the connection protocol.
        for provider in [auto, fixed] {
            let pinned = try explain(provider, "pinned")
            #expect(pinned.autoLine == nil)
            let pinnedRoot = try rootPart(provider, "pinned")
            #expect(pinned.detailLine == [Board.ExplainPart(key: "Set by you", table: .providers), pinnedRoot])
        }
        // The single-probe result of a manually chosen protocol only changes the status word on the second line.
        let probed = try #require(
            try Self.board(auto, "pinned", probe: .init(transport: .geminiGenerateContent, state: .notReachable)).protocolRow.explain
        )
        #expect(probed.autoLine == nil)
        #expect(probed.detailLine.map(\.key) == ["Not reachable", "API root %@"])

        // The local channel card has no description line.
        let local = Self.relayProvider(models: [Self.model("llama3", isDefault: true)], engineProfile: "ollama")
        #expect(try Self.board(local, "llama3").protocolRow.explain == nil)
    }

    @Test("BOARD-ADVANCED-14b unverified Claude family (the first catalog endpoint type is anthropic): \"Auto =\" shows the protocol actually sent first, Messages, not Chat")
    func advanced14bAutoLineShowsFirstSendTransport() throws {
        let modelID = "claude-advanced-first-send"
        var provider = Self.relayProvider(models: [Self.model(modelID, isDefault: true)])
        // A connection address of its own: the catalog cache is keyed by address, so this test does not leak into others.
        provider.baseURLText = "https://first-send-\(UUID().uuidString.lowercased()).myrelay.dev"
        let endpoint = try #require(provider.baseURLText)
        RelayCatalogEndpointTypesCache.shared.record(endpoint: endpoint, endpointTypesByModel: [modelID: ["anthropic", "openai"]])
        defer { RelayCatalogEndpointTypesCache.shared.record(endpoint: endpoint, endpointTypesByModel: [:]) }
        let model = try #require(provider.models.first { $0.id == modelID })
        #expect(RelayEndpointResolver.effectiveTransport(provider: provider, model: model) == .openaiChatCompletions)

        let board = try Self.board(provider, modelID)
        #expect(board.protocolRow.explain?.autoLine == Board.ExplainPart(
            key: "Auto = %@", table: .providers, argument: RelayProtocolMix.legendName(.anthropicMessages)
        ))
    }

    // MARK: - BOARD-ADVANCED-15

    @Test("BOARD-ADVANCED-15 card list: an empty thinking set has no thinking card and a non-empty one has; the Key card exists only with 2 or more keys; a local engine has no thinking card; the thinking card title is plain language")
    func advanced15Cards() async throws {
        try await Self.loadRelayThinkingMetadata(modelID: "thinker", intents: ["off", "low", "balanced", "deep"])
        let provider = Self.relayProvider(models: [Self.model("thinker", isDefault: true), Self.model("plain")])

        let thinker = try Self.board(provider, "thinker")
        #expect(thinker.thinking != nil)
        #expect(thinker.cards == [.protocolOrChannel, .capabilities, .thinking])

        let plainModel = try #require(provider.models.first { $0.id == "plain" })
        #expect(RelayReasoningLevelOverride.automaticModes(provider: provider, model: plainModel).isEmpty)
        let plain = try Self.board(provider, "plain")
        #expect(plain.thinking == nil)
        #expect(plain.cards == [.protocolOrChannel, .capabilities], "No empty card when there are no adjustable levels")

        let twoKeys = try Self.board(Self.twoKeyProvider(boundKeyID: "initial"), "claude-opus-4")
        #expect(twoKeys.keySection != nil)
        #expect(twoKeys.cards.filter { $0 != .thinking } == [.protocolOrChannel, .key, .capabilities], "The Key card comes after the protocol card")

        let local = Self.relayProvider(models: [Self.model("thinker", isDefault: true)], engineProfile: "ollama")
        #expect(try Self.board(local, "thinker").cards == [.protocolOrChannel, .capabilities])

        #expect(Board.thinkingHeaderKey == "Thinking levels you can pick in chat")
    }

    // MARK: - BOARD-ADVANCED-16

    @Test("BOARD-ADVANCED-16 read-only state: no \"changes apply immediately\" footer, which appears only when writable; when the connection pins a protocol, Auto on the read-only page also reads as following the connection")
    func advanced16ReadOnlyFooterAndExplain() throws {
        var provider = Self.twoKeyProvider(boundKeyID: nil)
        provider.relayRequested?.transport = .anthropicMessages
        let catalogOnly = try #require(provider.catalogModels.first { $0.id == "gpt-5" })

        let readOnly = Board.make(provider: provider, model: catalogOnly, partitionID: Self.partitionID, readOnly: true)
        #expect(readOnly.isReadOnly)
        #expect(!readOnly.showsFooter, "A read-only page can change nothing, so it does not say \"changes apply immediately\"")
        let explain = try #require(readOnly.protocolRow.explain)
        #expect(explain.autoLine == Board.ExplainPart(
            key: "Auto = this connection's default protocol (%@)", table: .providers,
            argument: RelayProtocolMix.legendName(.anthropicMessages)
        ))
        #expect(explain.detailLine.last?.key == "API root %@")

        let writable = try Self.board(provider, "claude-opus-4")
        #expect(!writable.isReadOnly)
        #expect(writable.showsFooter)
    }

    // MARK: - RL2-WEBPROBE-15

    @Test("RL2-WEBPROBE-15 advanced page web row: after tool calling, globe, Web search; status follows the current record, source user > tested; Auto / On / Off write the web override (user), while Auto and restore-all-automatic clear it; a local engine is Unknown")
    func rl2WebProbe15AdvancedWebRow() throws {
        let model = Self.model("m-web", transport: .openaiChatCompletions, isDefault: true)
        let provider = Self.relayProvider(transport: .openaiChatCompletions, models: [model])
        defer {
            RelayWebFragmentStore.shared.deleteConnection(provider.id)
            RelayWebProbeStore.shared.clearConnection(provider.id.uuidString)
        }
        #expect(Board.Capability.web.icon == .globe)
        #expect(Board.Capability.web.titleKey == "Web search")
        #expect(Board.Capability.web.titleTable == .providers)

        // Never tested: untested, no source, Auto.
        let bare = try Self.row(Self.board(provider, "m-web"), .web)
        #expect(bare.webStatus == .untested)
        #expect(bare.source == nil)
        #expect(bare.control == .auto)
        #expect(bare.state == .unknown)

        // Searched under the template (the probe also mirrors tested web = true): Search confirmed · Tested, control On (same convention as the image / tool rows).
        let template = try #require(RelayWebFragments.template(for: .openaiChatCompletions))
        let templateObject = try #require(try JSONSerialization.jsonObject(with: Data(template.utf8)) as? [String: Any])
        RelayWebProbeStore.shared.record(
            connectionID: provider.id.uuidString, modelID: "m-web", transport: RelayTransport.openaiChatCompletions.rawValue,
            result: .searched, source: .tested, fragmentHash: RelayWebProbe.fragmentHash(templateObject)
        )
        #expect(try Self.row(Self.board(provider, "m-web"), .web).control == .auto, "a record without an override value = Auto")
        var mirrored = provider
        mirrored.models[0].relayCapabilityOverrides = RelayWebProbe.merged(nil, with: .searched)
        let searched = try Self.row(Self.board(mirrored, "m-web"), .web)
        #expect(searched.webStatus == .searched)
        #expect(searched.source == .tested)
        #expect(searched.state == .supported)
        #expect(searched.control == .on, "tested true -> On, same convention as the image / tool rows")
        var mirroredOff = provider
        mirroredOff.models[0].relayCapabilityOverrides = RelayWebProbe.merged(nil, with: .rejected)
        #expect(try Self.row(Self.board(mirroredOff, "m-web"), .web).control == .off, "tested false -> Off")

        // Off: writes user to both tables; status still follows the record, source is user; model options are greyed out and the badge shows unsupported.
        let state = Self.makeState(provider)
        let manager = state.providerManager
        manager.setRelayCapabilityOverride(providerID: provider.id, modelID: "m-web", key: .web, value: false)
        var stored = try Self.stored(state, provider.id)
        for models in [stored.models, stored.catalogModels] {
            #expect(models.first?.relayCapabilityOverrides?.web == false)
            #expect(models.first?.relayCapabilityOverrides?.sources[.web] == .user)
        }
        let off = try Self.row(Self.board(stored, "m-web"), .web)
        #expect(off.webStatus == .searched)
        #expect(off.source == .user)
        #expect(off.control == .off)
        #expect(off.state == .unsupported)
        #expect(try Self.board(stored, "m-web").restoreAllEnabled)
        let storedModel = try #require(stored.models.first)
        let fact = try #require(RelayWebProbe.fact(provider: stored, model: storedModel, preference: true))
        #expect(fact.statusId == .userOff)
        #expect(fact.row == .toggleDisabled)
        #expect(!fact.sendsFragment)

        // Auto: clears the key.
        manager.setRelayCapabilityOverride(providerID: provider.id, modelID: "m-web", key: .web, value: nil)
        stored = try Self.stored(state, provider.id)
        #expect(stored.models.first?.relayCapabilityOverrides?.web == nil)
        #expect(try Self.row(Self.board(stored, "m-web"), .web).source == .tested)
        #expect(try Self.row(Self.board(stored, "m-web"), .web).control == .auto)

        // On, then restore all to automatic: cleared.
        manager.setRelayCapabilityOverride(providerID: provider.id, modelID: "m-web", key: .web, value: true)
        stored = try Self.stored(state, provider.id)
        #expect(try Self.row(Self.board(stored, "m-web"), .web).control == .on)
        manager.restoreRelayModelAllAutomatic(providerID: provider.id, modelID: "m-web")
        stored = try Self.stored(state, provider.id)
        #expect(stored.models.first?.relayCapabilityOverrides?.web == nil)
        #expect(stored.catalogModels.first?.relayCapabilityOverrides?.web == nil)

        // Local engine: Unknown, no source.
        let local = Self.relayProvider(models: [Self.model("llama3", isDefault: true)], engineProfile: "ollama")
        let localRow = try Self.row(Self.board(local, "llama3"), .web)
        #expect(localRow.webStatus == nil)
        #expect(localRow.state == .unknown)
        #expect(localRow.source == nil)
        #expect(Board.Capability.web.unknownKey == "Unknown")
    }
}
