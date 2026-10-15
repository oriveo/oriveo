import Foundation
import Testing
@testable import Oriveo

/// Fake local engine: replays the recorded raw text of `engine-declarations.v1.json` by path (the same replay convention as LocalEngineDeclarationContractTests).
private final class CatalogBoardEngineRecording: URLProtocol, @unchecked Sendable {
    struct Reply {
        let status: Int
        let contentType: String
        let body: Data
    }

    nonisolated(unsafe) static var routes: [String: Reply] = [:]
    nonisolated(unsafe) static var showReplies: [String: Reply] = [:]

    static func reset() {
        routes = [:]
        showReplies = [:]
    }

    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let method = request.httpMethod ?? "GET"
        let path = request.url?.path ?? ""
        var reply = Self.routes["\(method) \(path)"]
        if method == "POST", path == "/api/show",
           let body = Self.bodyData(of: request),
           let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
           let model = object["model"] as? String {
            reply = Self.showReplies[model]
        }
        // The connector's 1-token generation verification is not in the recording: return a minimal successful generation.
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

/// Model library board: asserts the sections, chips, row states and the three-state values of the five capabilities produced by `RelayCatalogBoardModel`.
@Suite("Relay 2.0 · model library board structure", .serialized)
@MainActor
struct RelayCatalogBoardStructureTests {
    typealias Board = RelayCatalogBoardModel

    private static let partitionID = "relay-catalog-board-tests"
    private static var retainedStates: [AppState] = []

    // MARK: - Construction

    private static func model(
        _ id: String,
        transport: RelayTransport? = nil,
        source: RelayTransportSource? = nil,
        isDefault: Bool = false,
        isManual: Bool = false,
        isAvailable: Bool = true
    ) -> AIModel {
        var model = TestFactories.makeModel(
            id: id, capabilities: [.text], isAvailable: isAvailable, isDefault: isDefault, isManual: isManual
        )
        model.relayTransport = transport
        model.relayTransportSource = transport == nil ? nil : (source ?? .observed)
        return model
    }

    private static func relayProvider(
        transport: RelayTransport = .auto,
        enabled: [AIModel],
        catalog: [AIModel],
        engineProfile: String? = nil
    ) -> Provider {
        var provider = TestFactories.makeProvider(
            kind: .relay,
            models: enabled,
            catalogModels: catalog,
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
        filter: Board.Filter = .all,
        now: Date = Date()
    ) -> Board {
        Board.make(
            provider: provider,
            enabledModels: provider.models,
            catalogModels: provider.catalogModels,
            filter: filter,
            partitionID: partitionID,
            now: now
        )
    }

    private static func rows(_ board: Board, _ section: Board.SectionID) -> [Board.Row] {
        board.sections.first { $0.id == section }?.rows ?? []
    }

    private static func row(_ board: Board, _ id: String) throws -> Board.Row {
        try #require(board.sections.flatMap(\.rows).first { $0.id == id }, "missing row \(id)")
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

    /// Shared Relay metadata fixture: every envelope accepts images, so the three states of image recognition are decided only by overrides / declarations / negative cache.
    private static func loadRelayMetadata() async throws {
        let json = try String(contentsOf: fixtureURL("shared/test-fixtures/relay/metadata-fixture.json"), encoding: .utf8)
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(json: json)
    }

    // MARK: - BOARD-CATALOG-01

    @Test("BOARD-CATALOG-01 section header counts + three legend items + footnote + no source badge on rows")
    func board01SectionsLegendFootnote() throws {
        let enabled = [Self.model("claude-sonnet-4.5", isDefault: true), Self.model("gpt-4o-mini")]
        let catalog = enabled + ["gemini-2.5-pro", "deepseek-v3", "qwen3-235b"].map { Self.model($0) }
        let board = Self.board(Self.relayProvider(enabled: enabled, catalog: catalog))

        #expect(board.sections.map(\.id) == [.enabled, .library])
        #expect(board.sections.map(\.titleKey) == ["Enabled · %lld", "Model library · %lld"])
        // Enabled count / catalog minus enabled.
        #expect(board.sections.map(\.count) == [2, 3])
        #expect(Self.rows(board, .enabled).map(\.id) == ["claude-sonnet-4.5", "gpt-4o-mini"])
        #expect(Self.rows(board, .library).map(\.id) == ["gemini-2.5-pro", "deepseek-v3", "qwen3-235b"])

        #expect(Board.legend.map(\.support) == [.supported, .unknown, .unsupported])
        #expect(Board.legend.map(\.key) == ["Two-tone = supported", "Gray = unknown", "Dim = not supported"])
        #expect(Board.footnoteKey == "Sources are shown only in Advanced")

        // The source badge is not on the row: the row's fields carry no source at all (the key chip shown when there are 2 or more keys is a separate matter).
        let labels = Set(Mirror(reflecting: Self.rows(board, .enabled)[0]).children.compactMap(\.label))
        #expect(labels == [
            "id", "name", "protocolTransport", "caps", "status", "tapTarget", "trailing", "removeItem", "keyChip",
        ])
        #expect(Board.Capability.allCases == [.image, .file, .thinking, .tool, .web])
        #expect(Board.Capability.allCases.map(\.icon) == [.eye, .paperclip, .brain, .wrench, .globe])
    }

    // MARK: - BOARD-CATALOG-02

    @Test("BOARD-CATALOG-02 filter chips: fixed order, hidden with fewer than two kinds, hidden for local, and once selected both sections filter together")
    func board02FilterChips() throws {
        let enabled = [
            Self.model("gemini-3-pro", transport: .geminiGenerateContent),
            Self.model("claude-opus", transport: .anthropicMessages),
            Self.model("plain-enabled"),
        ]
        let catalog = enabled + [
            Self.model("gpt-5", transport: .openaiResponses, source: .reachable),
            Self.model("plain-catalog"),
            Self.model("claude-haiku", transport: .anthropicMessages),
        ]
        let provider = Self.relayProvider(transport: .openaiChatCompletions, enabled: enabled, catalog: catalog)

        let all = Self.board(provider)
        #expect(all.filters == [
            .all,
            .transport(.openaiChatCompletions),
            .transport(.openaiResponses),
            .transport(.anthropicMessages),
            .transport(.geminiGenerateContent),
        ])
        #expect(all.selectedFilter == .all)

        let messages = Self.board(provider, filter: .transport(.anthropicMessages))
        #expect(messages.selectedFilter == .transport(.anthropicMessages))
        #expect(Self.rows(messages, .enabled).map(\.id) == ["claude-opus"])
        #expect(Self.rows(messages, .library).map(\.id) == ["claude-haiku"])
        // Counts remain those of the whole section (enabled count / catalog minus enabled) and do not change with the filter.
        #expect(messages.sections.map(\.count) == [3, 3])

        let chat = Self.board(provider, filter: .transport(.openaiChatCompletions))
        #expect(Self.rows(chat, .enabled).map(\.id) == ["plain-enabled"])
        #expect(Self.rows(chat, .library).map(\.id) == ["plain-catalog"])

        // Only one protocol: the whole row is hidden and filtering is inactive.
        let single = Self.relayProvider(
            transport: .openaiChatCompletions,
            enabled: [Self.model("a")],
            catalog: [Self.model("a"), Self.model("b"), Self.model("c", transport: .openaiChatCompletions)]
        )
        let singleBoard = Self.board(single, filter: .transport(.anthropicMessages))
        #expect(singleBoard.filters.isEmpty)
        #expect(singleBoard.selectedFilter == .all)
        #expect(Self.rows(singleBoard, .library).map(\.id) == ["b", "c"])

        // Local connection: no chips even when models carry different protocols.
        let local = Self.relayProvider(
            transport: .openaiChatCompletions,
            enabled: [Self.model("qwen3:0.6b", transport: .anthropicMessages)],
            catalog: [Self.model("qwen3:0.6b", transport: .anthropicMessages), Self.model("llama3")],
            engineProfile: "ollama"
        )
        #expect(Self.board(local).filters.isEmpty)
    }

    // MARK: - BOARD-CATALOG-03

    @Test("BOARD-CATALOG-03 protocol chip = effectiveTransport: model-level > connection default, auto -> Chat; catalog rows do not draw candidates; local is nil")
    func board03ProtocolChip() throws {
        let enabled = [
            Self.model("own-messages", transport: .anthropicMessages),
            Self.model("follows-connection"),
        ]
        let responsesConnection = Self.relayProvider(
            transport: .openaiResponses,
            enabled: enabled,
            catalog: enabled + [Self.model("catalog-plain")]
        )
        let board = Self.board(responsesConnection)
        #expect(try Self.row(board, "own-messages").protocolTransport == .anthropicMessages)
        #expect(try Self.row(board, "follows-connection").protocolTransport == .openaiResponses)
        #expect(try Self.row(board, "catalog-plain").protocolTransport == .openaiResponses)

        // Auto connection: models without a model-level protocol land on Chat; the candidate for Claude-family catalog rows (Messages is tried first) is not drawn.
        #expect(RelayProbeCandidates.fromFamily("anthropic").first == .anthropicMessages)
        let auto = Self.relayProvider(
            transport: .auto,
            enabled: [Self.model("gpt-4o-mini")],
            catalog: [Self.model("gpt-4o-mini"), Self.model("claude-sonnet-4.5")]
        )
        let autoBoard = Self.board(auto)
        #expect(try Self.row(autoBoard, "gpt-4o-mini").protocolTransport == .openaiChatCompletions)
        #expect(try Self.row(autoBoard, "claude-sonnet-4.5").protocolTransport == .openaiChatCompletions)
        // The same value as the production resolver.
        let claude = try #require(auto.catalogModels.last)
        #expect(
            try Self.row(autoBoard, "claude-sonnet-4.5").protocolTransport
                == RelayEndpointResolver.effectiveTransport(provider: auto, model: claude)
        )

        let local = Self.relayProvider(
            transport: .openaiChatCompletions,
            enabled: [Self.model("qwen3:0.6b")],
            catalog: [Self.model("qwen3:0.6b"), Self.model("llama3")],
            engineProfile: "ollama"
        )
        let localBoard = Self.board(local)
        #expect(localBoard.sections.flatMap(\.rows).allSatisfy { $0.protocolTransport == nil })
    }

    // MARK: - BOARD-CATALOG-04

    @Test("BOARD-CATALOG-04 five states of enabled rows + catalog-gone takes priority + manual rows are not marked")
    func board04EnabledStatus() throws {
        let enabled = [
            Self.model("observed", transport: .openaiResponses, source: .observed),
            Self.model("reachable", transport: .anthropicMessages, source: .reachable),
            Self.model("user", transport: .geminiGenerateContent, source: .user),
            Self.model("no-protocol"),
            Self.model("gone", transport: .openaiResponses, source: .observed),
            Self.model("manual-gone", isManual: true),
        ]
        // The catalog was confirmed successfully and is non-empty, but there is no gone / manual-gone.
        let catalog = enabled.filter { !$0.id.hasSuffix("gone") } + [Self.model("extra")]
        // Connection protocol is auto: only models without their own protocol have the "unknown" level (user-chosen connection protocols are covered by the next case).
        let board = Self.board(Self.relayProvider(transport: .auto, enabled: enabled, catalog: catalog))

        #expect(try Self.row(board, "observed").status == .verified)
        #expect(try Self.row(board, "reachable").status == .reachable)
        #expect(try Self.row(board, "user").status == .setByYou)
        #expect(try Self.row(board, "no-protocol").status == .unknownUntilSent)
        #expect(try Self.row(board, "gone").status == .missingFromCatalog)
        #expect(try Self.row(board, "manual-gone").status == .unknownUntilSent)

        #expect(Board.Status.verified.key == "Verified")
        #expect(Board.Status.reachable.key == "Reachable")
        #expect(Board.Status.setByYou.key == "Set by you")
        #expect(Board.Status.unknownUntilSent.key == "Unknown · remembered after sending")
        #expect(Board.Status.unknownUntilSent.table == .chat)
        #expect(Board.Status.missingFromCatalog.key == "No longer in the catalog")
        #expect(Board.Status.missingFromCatalog.table == .providers)

        // The same conclusion as the production predicate.
        let provider = Self.relayProvider(transport: .auto, enabled: enabled, catalog: catalog)
        let index = RelayCatalogMembership.Index(provider: provider)
        for model in enabled {
            #expect((try Self.row(board, model.id).status == .missingFromCatalog) == index.isMissingEnabledModel(model), "\(model.id)")
        }
    }

    @Test("BOARD-CATALOG-04 on an explicit connection protocol, a model row state is user-set: this holds for models without their own protocol in both areas, while models with their own protocol stay as before")
    func board04UserChosenConnectionRowsAreSetByYou() async throws {
        try await Self.loadRelayMetadata()
        var withFiles = Self.model("library-with-files")
        withFiles.nativeFileMimes = ["application/pdf"]
        let enabled = [
            Self.model("follows"),
            Self.model("observed", transport: .openaiResponses, source: .observed),
            Self.model("reachable", transport: .anthropicMessages, source: .reachable),
            Self.model("user", transport: .geminiGenerateContent, source: .user),
            Self.model("gone"),
        ]
        let catalog = enabled.filter { $0.id != "gone" } + [withFiles, Self.model("library-plain")]
        for transport in [RelayTransport.openaiChatCompletions, .openaiResponses, .anthropicMessages, .geminiGenerateContent] {
            let board = Self.board(Self.relayProvider(transport: transport, enabled: enabled, catalog: catalog))
            #expect(try Self.row(board, "follows").status == .setByYou, "\(transport.rawValue)")
            #expect(try Self.row(board, "library-with-files").status == .setByYou, "\(transport.rawValue)")
            #expect(try Self.row(board, "library-plain").status == .setByYou, "\(transport.rawValue)")
            // The model's own protocol and catalog-gone stay as before.
            #expect(try Self.row(board, "observed").status == .verified)
            #expect(try Self.row(board, "reachable").status == .reachable)
            #expect(try Self.row(board, "user").status == .setByYou)
            #expect(try Self.row(board, "gone").status == .missingFromCatalog)
        }
        // States on auto connections do not change.
        let auto = Self.board(Self.relayProvider(transport: .auto, enabled: enabled, catalog: catalog))
        #expect(try Self.row(auto, "follows").status == .unknownUntilSent)
        #expect(try Self.row(auto, "library-with-files").status == .verifyOnEnable)
        #expect(try Self.row(auto, "library-plain").status == .unknownUntilSent)
        // Local engine connections are unaffected: no status word.
        let local = Self.board(Self.relayProvider(
            transport: .openaiChatCompletions, enabled: [Self.model("follows")],
            catalog: [Self.model("follows"), Self.model("library-plain")], engineProfile: "ollama"
        ))
        #expect(try Self.row(local, "follows").status == nil)
        #expect(try Self.row(local, "library-plain").status == nil)
    }

    // MARK: - BOARD-CATALOG-05

    @Test("BOARD-CATALOG-05 two states of catalog rows + local only has catalog-gone")
    func board05LibraryStatus() async throws {
        try await Self.loadRelayMetadata()

        var withFiles = Self.model("with-files")
        withFiles.nativeFileMimes = ["application/pdf"]
        let plain = Self.model("plain")
        let enabled = [Self.model("enabled")]
        let board = Self.board(Self.relayProvider(transport: .auto, enabled: enabled, catalog: enabled + [withFiles, plain]))

        let filesRow = try Self.row(board, "with-files")
        #expect(filesRow.caps.contains { $0 != .unknown })
        #expect(filesRow.status == .verifyOnEnable)
        #expect(Board.Status.verifyOnEnable.key == "Verified when enabled")

        let plainRow = try Self.row(board, "plain")
        #expect(plainRow.caps == Array(repeating: .unknown, count: 5))
        #expect(plainRow.status == .unknownUntilSent)

        // Local: neither catalog rows nor enabled rows have a status word, except catalog-gone.
        let localEnabled = [Self.model("qwen3:0.6b"), Self.model("gone:latest")]
        let local = Self.relayProvider(
            transport: .openaiChatCompletions,
            enabled: localEnabled,
            catalog: [Self.model("qwen3:0.6b"), withFiles, plain],
            engineProfile: "ollama"
        )
        let localBoard = Self.board(local)
        #expect(try Self.row(localBoard, "qwen3:0.6b").status == nil)
        #expect(try Self.row(localBoard, "gone:latest").status == .missingFromCatalog)
        #expect(Self.rows(localBoard, .library).allSatisfy { $0.status == nil })

        await MetadataClient.shared.resetForTesting()
    }

    // MARK: - BOARD-CATALOG-06

    @Test("BOARD-CATALOG-06 Relay five-capability three states: image override / negative cache / no evidence, tool negative cache, file allowlist / negative cache")
    func board06RelayCapabilities() async throws {
        try await Self.loadRelayMetadata()
        let cache = RelayNegativeCache.shared

        var imageOverride = Self.model("image-override")
        imageOverride.relayCapabilityOverrides = RelayCapabilityOverrides(image: true, source: .user)
        let imageRejected = Self.model("image-rejected")
        let noEvidence = Self.model("no-evidence")
        let toolRejected = Self.model("tool-rejected")
        var fileAllowed = Self.model("file-allowed")
        fileAllowed.nativeFileMimes = ["application/pdf"]
        var fileRejected = Self.model("file-rejected")
        fileRejected.nativeFileMimes = ["application/pdf"]
        // The file format looks at the override value first, giving the same answer as the file row on the Advanced page.
        var fileForcedOn = Self.model("file-forced-on")
        fileForcedOn.relayCapabilityOverrides = RelayCapabilityOverrides(file: true, source: .user)
        var fileForcedOff = Self.model("file-forced-off")
        fileForcedOff.nativeFileMimes = ["application/pdf"]
        fileForcedOff.relayCapabilityOverrides = RelayCapabilityOverrides(file: false, source: .user)

        let enabled = [imageOverride, imageRejected, noEvidence, toolRejected, fileAllowed, fileRejected, fileForcedOn, fileForcedOff]
        let provider = Self.relayProvider(transport: .auto, enabled: enabled, catalog: enabled)
        let connectionID = provider.id.uuidString
        defer { cache.clearConnection(connectionID) }
        let chat = RelayTransport.openaiChatCompletions.rawValue
        // Override true beats the image negative cache.
        cache.record(connectionID: connectionID, modelID: "image-override", transport: chat, kind: .image)
        cache.record(connectionID: connectionID, modelID: "image-rejected", transport: chat, kind: .image)
        cache.record(connectionID: connectionID, modelID: "tool-rejected", transport: chat, kind: .toolCall)
        cache.record(connectionID: connectionID, modelID: "file-rejected", transport: chat, kind: .file)
        cache.record(connectionID: connectionID, modelID: "file-forced-on", transport: chat, kind: .file)

        let board = Self.board(provider)
        func cap(_ id: String, _ capability: Board.Capability) throws -> Board.Support {
            try Self.row(board, id).caps[try #require(Board.Capability.allCases.firstIndex(of: capability))]
        }

        #expect(try cap("image-override", .image) == .supported)
        #expect(try cap("image-rejected", .image) == .unsupported)
        #expect(try cap("no-evidence", .image) == .unknown)
        #expect(try cap("tool-rejected", .tool) == .unsupported)
        #expect(try cap("no-evidence", .tool) == .unknown)
        #expect(try cap("file-allowed", .file) == .supported)
        #expect(try cap("file-rejected", .file) == .unsupported)
        #expect(try cap("no-evidence", .file) == .unknown)
        #expect(try cap("file-forced-on", .file) == .supported)
        #expect(try cap("file-forced-off", .file) == .unsupported)

        // Image recognition matches the same facts as the production composer photo-picker entry.
        #expect(ChatView.photoPickerVisible(provider: provider, model: imageRejected, partitionID: Self.partitionID) == false)
        #expect(ChatView.photoPickerVisible(provider: provider, model: noEvidence, partitionID: Self.partitionID))
        // Tools match the production Relay tool decision.
        #expect(ToolCallCapabilityPolicy.decide(provider: provider, model: toolRejected).verdict == false)

        // After the negative cache expires (now is past 7 days), files return to the allowlist decision.
        let later = Date().addingTimeInterval(RelayNegativeCache.ttl + 60)
        let expired = Self.board(provider, now: later)
        let fileIndex = try #require(Board.Capability.allCases.firstIndex(of: .file))
        #expect(try Self.row(expired, "file-rejected").caps[fileIndex] == .supported)

        await MetadataClient.shared.resetForTesting()
    }

    // MARK: - BOARD-CATALOG-07 (RL2-ENGINE-02 consumer side)

    private func expectations() throws -> [String: Any] {
        let url = try Self.fixtureURL("shared/test-fixtures/local-engine/engine-expectations.v1.json")
        return try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private func recordedEngine(_ engine: String) throws -> [String: Any] {
        let url = try Self.fixtureURL("shared/test-fixtures/local-engine/engine-declarations.v1.json")
        let root = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let engines = try #require(root["engines"] as? [String: Any])
        return try #require(engines[engine] as? [String: Any])
    }

    private func installRecording(engine: String) throws {
        CatalogBoardEngineRecording.reset()
        let records = try #require(try recordedEngine(engine)["records"] as? [[String: Any]])
        for record in records {
            let request = try #require(record["request"] as? [String: Any])
            let method = try #require(request["method"] as? String)
            let path = try #require(request["path"] as? String)
            let response = try #require(record["response"] as? [String: Any])
            let body: Data
            if let json = response["body"] {
                body = try JSONSerialization.data(withJSONObject: json)
            } else {
                body = Data((response["text"] as? String ?? "").utf8)
            }
            let reply = CatalogBoardEngineRecording.Reply(
                status: try #require(response["status"] as? Int),
                contentType: response["contentType"] as? String ?? "",
                body: body
            )
            if method == "POST", path == "/api/show",
               let model = (request["body"] as? [String: Any])?["model"] as? String {
                CatalogBoardEngineRecording.showReplies[model] = reply
            } else {
                CatalogBoardEngineRecording.routes["\(method) \(path)"] = reply
            }
        }
    }

    @Test("BOARD-CATALOG-07 RL2-ENGINE-02: the Ollama recording through the production connector; rows that declare vision / tools / thinking support them and undeclared ones do not")
    func board07EngineDeclarations() async throws {
        try await Self.loadRelayMetadata()

        try installRecording(engine: "ollama")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CatalogBoardEngineRecording.self]
        let session = URLSession(configuration: configuration)
        let endpoint = try #require(try recordedEngine("ollama")["endpoint"] as? String)
        let connection = try await LocalEngineConnector.connect(
            engine: .ollama, endpoint: endpoint, securityMode: .localHTTP, session: session
        )
        let state = AppState(sessionUID: "relay-catalog-board-\(UUID().uuidString)", providerSession: session)
        state.providers = []
        state.conversations = []
        Self.retainedStates.append(state)
        let provider = state.providerManager.registerRelay(
            name: "Local ollama",
            endpoint: connection.endpoint,
            apiKey: "",
            relayRequested: connection.requested,
            catalogModelIDs: connection.modelIDs,
            preferredModelID: connection.selectedModelID,
            runtimeMetadata: connection.runtimeMetadata
        )
        let board = Self.board(provider)
        let rows = board.sections.flatMap(\.rows)

        let declarations = try #require(try expectations()["declarations"] as? [String: Any])
        let cases = try #require(declarations["cases"] as? [[String: Any]]).filter {
            $0["engine"] as? String == "ollama" && $0["inChatCatalog"] as? Bool == true
        }
        #expect(cases.count == 4)
        let index: (Board.Capability) throws -> Int = { capability in
            try #require(Board.Capability.allCases.firstIndex(of: capability))
        }
        for item in cases {
            let caseId = item["caseId"] as? String ?? "<no id>"
            let modelID = try #require(item["modelId"] as? String)
            let row = try #require(rows.first { $0.id == modelID }, "\(caseId)")
            let expect = try #require(item["expect"] as? [String: Any])
            for (key, capability) in [("image", Board.Capability.image), ("toolCall", .tool), ("thinking", .thinking)] {
                let declared = try #require(expect[key] as? Bool, "\(caseId) \(key)")
                #expect(row.caps[try index(capability)] == (declared ? .supported : .unsupported), "\(caseId) \(key)")
            }
            // Local connection: no protocol drawn, no filter, no status word.
            #expect(row.protocolTransport == nil, "\(caseId)")
            #expect(row.status == nil, "\(caseId)")
        }
        #expect(board.filters.isEmpty)

        await MetadataClient.shared.resetForTesting()
    }

    // MARK: - BOARD-CATALOG-08

    @Test("BOARD-CATALOG-08 trailing: enabled rows show new chat + the \"...\" menu, catalog rows show plus / unavailable; a relay has no default model, so no Default badge")
    func board08Trailing() throws {
        let enabled = [Self.model("legacy-default", isDefault: true), Self.model("other")]
        let catalog = enabled + [Self.model("addable"), Self.model("offline", isAvailable: false)]
        let board = Self.board(Self.relayProvider(enabled: enabled, catalog: catalog))

        // It used to be a trailing chevron; now the whole row goes to Advanced and the trailing part became new chat + the "..." menu.
        #expect(Self.rows(board, .enabled).map(\.trailing) == [[.newChat, .more], [.newChat, .more]])
        #expect(try Self.row(board, "addable").trailing == [.add])
        #expect(try Self.row(board, "offline").trailing == [.unavailable])
        // The enabled section keeps the enabling order, and the old isDefault does not move a model to the front.
        #expect(Self.rows(board, .enabled).map(\.id) == ["legacy-default", "other"])

        // The old isDefault on the later model is not read either: the representative model = the first enabled one.
        let unmarked = [Self.model("first"), Self.model("second", isDefault: true)]
        let unmarkedProvider = Self.relayProvider(enabled: unmarked, catalog: unmarked)
        #expect(unmarkedProvider.defaultModel?.id == "first")
    }

    @Test("BOARD-CATALOG-02/08 the combination used by production views (filters / matches / row / libraryCount) matches the output of make")
    func boardViewCompositionMatchesMake() throws {
        let enabled = [Self.model("claude-opus", transport: .anthropicMessages), Self.model("plain")]
        let catalog = enabled + [Self.model("gpt-5", transport: .openaiResponses), Self.model("other")]
        let provider = Self.relayProvider(transport: .openaiChatCompletions, enabled: enabled, catalog: catalog)
        let filter = Board.Filter.transport(.anthropicMessages)
        let board = Self.board(provider, filter: filter)

        // The chips and the effective filter of ProviderDetailView.modelsContent.
        let viewFilters = Board.filters(provider: provider, models: provider.models + provider.catalogModels)
        #expect(viewFilters == board.filters)
        #expect(Board.effectiveFilter(filter, available: viewFilters) == board.selectedFilter)
        // The section header count of ProviderModelLibrarySection.
        #expect(Board.libraryCount(enabledModels: provider.models, catalogModels: provider.catalogModels)
            == board.sections.first { $0.id == .library }?.count)
        // The per-row calls of ProviderEnabledModelsSection / ProviderCatalogModelRow.
        let membership = RelayCatalogMembership.Index(provider: provider)
        let viewEnabled = provider.models
            .filter { Board.matches(board.selectedFilter, provider: provider, model: $0) }
            .map {
                Board.row(
                    provider: provider, model: $0, section: .enabled,
                    isMissingFromCatalog: membership.isMissingEnabledModel($0), partitionID: Self.partitionID
                )
            }
        #expect(viewEnabled == Self.rows(board, .enabled))
        let enabledIDs = Set(provider.models.map(\.id))
        let viewLibrary = provider.catalogModels
            .filter { !enabledIDs.contains($0.id) && Board.matches(board.selectedFilter, provider: provider, model: $0) }
            .map {
                Board.row(
                    provider: provider, model: $0, section: .library,
                    isMissingFromCatalog: false, partitionID: Self.partitionID
                )
            }
        #expect(viewLibrary == Self.rows(board, .library))
    }

    // MARK: - RD-3 construction

    private static func keyed(_ id: String, keyID: String? = nil, listedBy: [String]? = nil, transport: RelayTransport? = nil) -> AIModel {
        var model = Self.model(id, transport: transport)
        model.relayKeyID = keyID
        model.relayListedByKeyIDs = listedBy
        return model
    }

    /// Two keys: the primary key "Main" lists 2 models normally; the second key has no name, is denied with 403 and lists 1.
    private static func twoKeyProvider() -> Provider {
        let checked = Date(timeIntervalSince1970: 1_700_000_000)
        var provider = Self.relayProvider(
            transport: .openaiChatCompletions,
            enabled: [Self.keyed("gpt-5"), Self.keyed("claude-opus-4", keyID: "k-claude")],
            catalog: [
                Self.keyed("gpt-5", listedBy: ["initial"]),
                Self.keyed("gpt-4.1", listedBy: ["initial"]),
                Self.keyed("claude-opus-4", listedBy: ["k-claude"]),
            ]
        )
        provider.relayKeys = [
            RelayKey(id: "initial", name: "Main", status: .init(state: .ok, httpStatus: 200, checkedAt: checked)),
            RelayKey(id: "k-claude", apiKey: "sk-claude-2222-3333", status: .init(state: .denied, httpStatus: 403, checkedAt: checked)),
        ]
        return provider
    }

    private static func makeState(_ provider: Provider) -> AppState {
        let state = AppState(
            seedDemoData: false,
            sessionUID: "relay-catalog-board-\(UUID().uuidString)",
            providerSession: RelaySetupHTTPStub.session()
        )
        state.providers = [provider]
        retainedStates.append(state)
        return state
    }

    // MARK: - BOARD-CATALOG-10

    @Test("BOARD-CATALOG-10 with 2 or more keys: the key chip on an enabled row = the bound key's name or mask; the top of the catalog area shows a per-key status bar (catalog count + check mark / <code> <status word> + Retry); with 1 key neither appears")
    func board10KeyChipsAndKeyStatusBar() throws {
        let provider = Self.twoKeyProvider()
        let board = Self.board(provider)
        let keyRows = RelayKeysBoardModel.make(provider).rows

        // The chip takes modelState.boundKeyID, and the text uses the same read model as the key page.
        #expect(try Self.row(board, "gpt-5").keyChip == "Main")
        #expect(try Self.row(board, "claude-opus-4").keyChip == keyRows[1].title)
        #expect(keyRows[1].title != "Main")
        #expect(Self.rows(board, .library).allSatisfy { $0.keyChip == nil })

        let bar = try #require(Board.keyStatusBar(provider))
        #expect(bar.map(\.id) == ["initial", "k-claude"])
        #expect(bar.map(\.title) == ["Main", keyRows[1].title])
        #expect(bar.map(\.catalogCount) == [2, 1])
        #expect(bar[0].state == .ok)
        #expect(bar[1].state == .failed(httpStatus: 403, statusKey: "No access"))
        #expect(bar.map(\.showsRetry) == [false, true])

        // 1 key (implicit): no chip and no status bar.
        var single = provider
        single.relayKeys = nil
        let singleBoard = Self.board(single)
        #expect(singleBoard.sections.flatMap(\.rows).allSatisfy { $0.keyChip == nil })
        #expect(Board.keyStatusBar(single) == nil)
    }

    // MARK: - BOARD-CATALOG-11

    @Test("BOARD-CATALOG-11 enabled row states: denied > verifying > unreachable > original; unreachable is written into this session's memory by the production lazy verify (reason + status code), is cleared on rebind / success, and is not persisted")
    func board11SessionStatuses() async throws {
        var denied = Self.model("denied", transport: .openaiResponses, source: .observed)
        denied.relayDeniedKeyID = RelayKeyBinding.implicitKeyID
        let plain = Self.model("plain", transport: .openaiResponses, source: .observed)
        let provider = Self.relayProvider(enabled: [denied, plain], catalog: [denied, plain])
        let failure = RelayModelProbeFailure(summary: "Upstream said no", httpStatus: 404)
        func status(_ model: AIModel, _ state: RelayModelProbeState?) -> Board.Status? {
            Board.row(
                provider: provider, model: model, section: .enabled, isMissingFromCatalog: false,
                partitionID: Self.partitionID, probeState: state
            ).status
        }
        #expect(status(denied, nil) == .deniedOnCurrentKey)
        #expect(status(denied, .inFlight) == .deniedOnCurrentKey)
        #expect(status(denied, .failed(failure)) == .deniedOnCurrentKey)
        #expect(status(plain, .inFlight) == .verifying)
        #expect(status(plain, .failed(failure)) == .unreachable(failure))
        #expect(status(plain, nil) == .verified)
        #expect(Board.Status.deniedOnCurrentKey.key == "Current key has no access")
        #expect(Board.Status.verifying.key == "Verifying…")
        #expect(Board.Status.unreachable(failure).key == "Not reachable · See why")
        #expect(Board.unreachableTitleKey == "Why it isn’t reachable")
        // make and the view call the same in-memory table row by row.
        let board = Board.make(
            provider: provider, enabledModels: provider.models, catalogModels: provider.catalogModels,
            filter: .all, partitionID: Self.partitionID, now: Date(), probeStates: ["plain": .inFlight]
        )
        #expect(try Self.row(board, "plain").status == .verifying)

        // Production lazy verify: the fake relay answers 404 to every generation request.
        let failing = RelaySetupHTTPStub()
        failing.failGeneration(status: 404)
        var live = Self.twoKeyProvider()
        live.baseURLText = failing.endpoint + "/v1"
        // Lazy verify only happens when the connection protocol is auto; models on a user-chosen connection protocol follow the connection and are not probed.
        live.relayRequested?.transport = .auto
        live.models.append(Self.keyed("my-model"))
        live.catalogModels.append(Self.keyed("my-model", listedBy: ["initial", "k-claude"]))
        let state = Self.makeState(live)
        await state.providerManager.probeRelayModelTransport(providerID: live.id, modelID: "my-model")
        let recorded = try #require(state.relayModelProbeStates[live.id]?["my-model"])
        guard case let .failed(reason) = recorded else {
            Issue.record("a lazy-verify failure should be recorded as unreachable, got \(recorded)")
            return
        }
        #expect(reason.httpStatus == 404)
        #expect(!reason.summary.isEmpty)
        #expect(!failing.generationModels.isEmpty)
        let liveRow = Board.row(
            provider: try #require(state.provider(for: live.id)),
            model: try #require(state.provider(for: live.id)?.models.first { $0.id == "my-model" }),
            section: .enabled, isMissingFromCatalog: false, partitionID: Self.partitionID,
            probeState: state.relayModelProbeStates[live.id]?["my-model"]
        )
        #expect(liveRow.status == .unreachable(reason))
        // Not persisted: the persisted object still has no protocol on this model, and no "unreachable" field of any kind.
        let stored = try JSONDecoder().decode(Provider.self, from: JSONEncoder().encode(try #require(state.provider(for: live.id))))
        #expect(stored.models.first { $0.id == "my-model" }?.relayTransport == nil)
        #expect(!String(decoding: try JSONEncoder().encode(stored), as: UTF8.self).contains("Upstream"))

        // Rebind: cleared on the spot (a lazy verify then runs once as usual).
        #expect(await state.providerManager.applyRelayKeyOperation(
            providerID: live.id, .rebind(modelID: "my-model", keyID: "k-claude")
        ))
        let afterRebind = state.relayModelProbeStates[live.id]?["my-model"]
        #expect(afterRebind == nil || afterRebind == .inFlight)
        await state.providerManager.waitForRelayModelProbeForTesting(providerID: live.id)

        // Success: cleared and the protocol is written back.
        let passing = RelaySetupHTTPStub()
        var moved = try #require(state.provider(for: live.id))
        moved.baseURLText = passing.endpoint + "/v1"
        state.providers = [moved]
        await state.providerManager.probeRelayModelTransport(providerID: live.id, modelID: "my-model")
        #expect(state.relayModelProbeStates[live.id]?["my-model"] == nil)
        #expect(state.provider(for: live.id)?.models.first { $0.id == "my-model" }?.relayTransport != nil)
    }

    // MARK: - BOARD-CATALOG-12

    @Test("BOARD-CATALOG-12 catalog area: a single-key failure = a full-width failure card (title + reason + only Retry) with the old catalog below it; success but empty draws no catalog area; with 2 or more keys only the status bar appears and no failure card")
    func board12CatalogArea() throws {
        let catalog = [Self.model("gpt-5"), Self.model("gpt-4.1")]
        var failedWithOld = Self.relayProvider(enabled: [catalog[0]], catalog: catalog)
        failedWithOld.lastError = ProviderIssueMessage.catalogUnavailableKey
        #expect(Board.libraryBlocks(provider: failedWithOld, isRefreshing: false) == [.failureCard, .catalog])

        var failedEmpty = failedWithOld
        failedEmpty.catalogModels = []
        #expect(Board.libraryBlocks(provider: failedEmpty, isRefreshing: false) == [.failureCard])

        var emptyOK = failedEmpty
        emptyOK.lastError = nil
        #expect(Board.libraryBlocks(provider: emptyOK, isRefreshing: false) == [])

        let ok = Self.relayProvider(enabled: [catalog[0]], catalog: catalog)
        #expect(Board.libraryBlocks(provider: ok, isRefreshing: false) == [.catalog])
        #expect(Board.libraryBlocks(provider: ok, isRefreshing: true) == [.loading])

        var multi = Self.twoKeyProvider()
        multi.lastError = ProviderIssueMessage.catalogUnavailableKey
        // 2 or more keys: failures are expressed only by the per-key status bar and no failure card is stacked on top.
        #expect(Board.libraryBlocks(provider: multi, isRefreshing: false) == [.keyStatusBar, .catalog])
        #expect(!Board.libraryBlocks(provider: multi, isRefreshing: false).contains(.failureCard))

        // Failure card: new title, one reason sentence reusing the existing classification, and only the Retry action (manual add exists in one place at the page foot).
        #expect(Board.failureCardTitleKey == "Couldn’t get the model list")
        #expect(Board.failureCardActions == [.retry])
        #expect(RelayCatalogPresentationState.resolve(for: failedWithOld, isRefreshing: false) == .failed)
    }

    // MARK: - BOARD-CATALOG-13

    @Test("BOARD-CATALOG-13 catalog row: tapping the row opens read-only Advanced (does not enable, sends no request); only the trailing plus enables; the enabling hint sits below the group")
    func board13CatalogRowTaps() throws {
        let model = Self.model("gpt-5")
        let provider = Self.relayProvider(enabled: [Self.model("anchor")], catalog: [Self.model("anchor"), model])
        let state = Self.makeState(provider)
        var taps: [String] = []
        let row = ProviderCatalogModelRow(
            model: model,
            provider: provider,
            capabilityEvidenceRevision: 1,
            nested: true,
            catalogBoard: RelayCatalogBoardContext(partitionID: Self.partitionID, filter: .all),
            openAdvancedAction: { taps.append("advanced") },
            addAction: { taps.append("add") }
        )
        row.perform(.row)
        #expect(taps == ["advanced"])
        #expect(state.provider(for: provider.id)?.models.map(\.id) == ["anchor"], "tapping the row does not enable")
        row.perform(.trailing)
        #expect(taps == ["advanced", "add"])
        #expect(Board.enableHintKey == "Enabling sends 1 tiny request to confirm the model works. Tap a model in the catalog to view Advanced first. No request is sent.")
        // This connection is auto: the hint carries the "sends 1 very small request" sentence (three states are covered by BOARD-CATALOG-16).
        #expect(Board.enableHint(for: provider) == Board.enableHintKey)

        // Production wiring: the model library page connects a tap on a catalog row to read-only Advanced (for navigation levels see NAV-RELAY-03).
        let detail = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Oriveo/Features/Providers/ProviderDetailView.swift"),
            encoding: .utf8
        )
        #expect(detail.contains("openRelayModelAdvanced(providerID: provider.id, modelID: model.id, readOnly: true)"))
    }

    // MARK: - BOARD-CATALOG-14

    private static func productionSource(_ relative: String) throws -> String {
        try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Oriveo/\(relative)"),
            encoding: .utf8
        )
    }

    private static func enabledRowView(
        _ model: AIModel,
        provider: Provider,
        record: @escaping (String) -> Void
    ) -> ProviderEnabledModelRow {
        ProviderEnabledModelRow(
            model: model,
            provider: provider,
            capabilityEvidenceRevision: 1,
            isHighlighted: false,
            isMissingFromCatalog: false,
            isLast: true,
            canSetDefault: false,
            canRemove: provider.models.count > 1,
            setDefaultAction: { record("default") },
            chatAction: { record("chat") },
            removeAction: { record("remove") },
            advancedAction: { record("advanced") },
            catalogBoard: RelayCatalogBoardContext(partitionID: partitionID, filter: .all)
        )
    }

    @Test("BOARD-CATALOG-14 enabled row: tapping the whole row goes to 'Model > Advanced', trailing = new chat + the '...' menu; catalog rows are still read-only Advanced + plus; official provider rows are unchanged")
    func board14EnabledRowTapsOpenAdvanced() throws {
        let enabled = [Self.model("m1"), Self.model("offline", isAvailable: false)]
        let provider = Self.relayProvider(enabled: enabled, catalog: enabled + [Self.model("lib")])
        let board = Self.board(provider)

        // Row model: even an unavailable enabled model can enter Advanced (a management action should not be blocked by availability).
        for row in Self.rows(board, .enabled) {
            #expect(row.tapTarget == .advanced, "\(row.id)")
            #expect(row.trailing == [.newChat, .more], "\(row.id)")
        }
        #expect(try Self.row(board, "lib").tapTarget == .readOnlyAdvanced)
        #expect(try Self.row(board, "lib").trailing == [.add])

        // The two tap areas of the production view. This used to lock "tap opens chat, trailing chevron opens Advanced",
        // which was overturned: on a page for managing models, jumping to chat from the whole row is not what users expect.
        var taps: [String] = []
        let view = Self.enabledRowView(enabled[0], provider: provider) { taps.append($0) }
        view.perform(.row)
        #expect(taps == ["advanced"])
        view.perform(.trailing)
        #expect(taps == ["advanced", "chat"])

        // Production wiring: an enabled row enters the editable Advanced (for the read-only catalog row see BOARD-CATALOG-13).
        let detail = try Self.productionSource("Features/Providers/ProviderDetailView.swift")
        #expect(detail.contains("openRelayModelAdvanced(providerID: provider.id, modelID: model.id, readOnly: false)"))

        // Official provider enabled rows are unchanged: the whole row still opens chat, and the chat button is the same one as the board row.
        let rowSource = try Self.productionSource("Features/Providers/ProviderEnabledModels.swift")
        #expect(rowSource.contains("Button(action: chatAction)"))
        #expect(!rowSource.contains("PhosphorIcon.caretRight"), "the trailing chevron is gone: the whole row goes to Advanced")
    }

    // MARK: - BOARD-CATALOG-14b

    @Test("BOARD-CATALOG-14b a production row tap dispatches on the row model's tapTarget: board rows go to Advanced, non-board rows (no row model) stay as before - catalog rows enable, enabled rows open chat")
    func board14bRowTapsDispatchByTapTarget() throws {
        let enabled = [Self.model("m1"), Self.model("m2")]
        let provider = Self.relayProvider(enabled: enabled, catalog: enabled + [Self.model("lib")])
        var taps: [String] = []

        // Enabled row: without board context the whole row opens chat.
        let plainEnabled = ProviderEnabledModelRow(
            model: enabled[0],
            provider: provider,
            capabilityEvidenceRevision: 1,
            isHighlighted: false,
            isMissingFromCatalog: false,
            isLast: true,
            canSetDefault: false,
            canRemove: true,
            setDefaultAction: { taps.append("default") },
            chatAction: { taps.append("chat") },
            removeAction: { taps.append("remove") },
            advancedAction: { taps.append("advanced") }
        )
        plainEnabled.perform(.row)
        #expect(taps == ["chat"])

        // Catalog row: without board context the whole row enables.
        taps = []
        let plainCatalog = ProviderCatalogModelRow(
            model: Self.model("lib"),
            provider: provider,
            capabilityEvidenceRevision: 1,
            openAdvancedAction: { taps.append("advanced") },
            addAction: { taps.append("add") }
        )
        plainCatalog.perform(.row)
        #expect(taps == ["add"])

        // The view no longer decides the destination itself; it asks the row model.
        for file in ["ProviderModelLibrary.swift", "ProviderEnabledModels.swift"] {
            let source = try Self.productionSource("Features/Providers/\(file)")
            #expect(source.contains("boardRowModel($0).tapTarget"), "\(file)")
        }
        let library = try Self.productionSource("Features/Providers/ProviderModelLibrary.swift")
        #expect(!library.contains("catalogBoard == nil ? addAction() : openAdvancedAction()"))
    }

    // MARK: - BOARD-CATALOG-15

    @Test("BOARD-CATALOG-15 removal in \"...\": with only one model the menu stays and removal is greyed out with a reason; with two or more it can be removed; catalog rows have none; same criterion as production removal")
    func board15RemoveItemDisabledOnLastModel() throws {
        let only = [Self.model("only")]
        let single = Self.relayProvider(enabled: only, catalog: only + [Self.model("lib")])
        let singleBoard = Self.board(single)
        let onlyRow = try Self.row(singleBoard, "only")
        #expect(onlyRow.trailing.contains(.more), "the \"...\" stays when only one model remains")
        #expect(onlyRow.removeItem == Board.RemoveItem(isEnabled: false, disabledReasonKey: Board.removeDisabledReasonKey))
        #expect(Board.removeDisabledReasonKey == "This connection needs at least one model.")
        #expect(try Self.row(singleBoard, "lib").removeItem == nil)

        let pair = [Self.model("a"), Self.model("b")]
        let two = Self.relayProvider(enabled: pair, catalog: pair)
        for row in Self.rows(Self.board(two), .enabled) {
            #expect(row.removeItem == Board.RemoveItem(isEnabled: true, disabledReasonKey: nil), "\(row.id)")
        }

        // Local connections use the same rule.
        let local = Self.relayProvider(enabled: only, catalog: only, engineProfile: "ollama")
        #expect(try Self.row(Self.board(local), "only").removeItem?.isEnabled == false)

        // Production removal path: after removing one of two, the remaining row becomes greyed out; removing again is rejected and the model stays.
        let state = Self.makeState(two)
        state.providerManager.disableModel(modelID: "a", for: two.id)
        let afterOne = try #require(state.provider(for: two.id))
        #expect(afterOne.models.map(\.id) == ["b"])
        #expect(Board.removeItem(afterOne).isEnabled == false)
        state.providerManager.disableModel(modelID: "b", for: two.id)
        #expect(state.provider(for: two.id)?.models.map(\.id) == ["b"])
    }

    // MARK: - BOARD-CATALOG-16

    @Test("BOARD-CATALOG-16 three states of the enabling hint: auto says it sends 1 very small request; a chosen connection protocol keeps only the second half; local shows none")
    func board16EnableHintFollowsConnectionProtocol() throws {
        let plain = Self.model("plain")
        let auto = Self.relayProvider(transport: .auto, enabled: [Self.model("anchor")], catalog: [Self.model("anchor"), plain])
        #expect(Board.enableHint(for: auto) == Board.enableHintKey)
        #expect(Board.enableHintKey.hasPrefix("Enabling sends 1 tiny request"))

        #expect(Board.enableHintChosenProtocolKey == "Tap a model in the catalog to view Advanced first. No request is sent.")
        #expect(Board.enableHintKey.hasSuffix(Board.enableHintChosenProtocolKey), "the chosen state just drops the first half")
        for transport in Board.filterOrder {
            let chosen = Self.relayProvider(transport: transport, enabled: [Self.model("anchor")], catalog: [Self.model("anchor"), plain])
            let hint = try #require(Board.enableHint(for: chosen), "\(transport.rawValue)")
            #expect(hint == Board.enableHintChosenProtocolKey, "\(transport.rawValue)")
            #expect(!hint.contains("Enabling sends"), "\(transport.rawValue)")
            // The same conclusion as the production probe criterion: on this kind of connection, enabling a model without its own protocol does not probe (see the user-chosen connection protocol case).
            #expect(RelayProbeCandidates.followsUserChosenConnection(provider: chosen, model: plain), "\(transport.rawValue)")
        }
        #expect(!RelayProbeCandidates.followsUserChosenConnection(provider: auto, model: plain))

        // Local connection: nothing shows whether or not a protocol is chosen.
        for transport in [RelayTransport.auto, .openaiChatCompletions] {
            let local = Self.relayProvider(transport: transport, enabled: [], catalog: [], engineProfile: "ollama")
            #expect(Board.enableHint(for: local) == nil)
        }
    }

    // MARK: - BOARD-CATALOG-17

    @Test("BOARD-CATALOG-17 row screen-reader value: five capabilities each read 'capability name + status word' in icon order, reusing existing keys")
    func board17RowAccessibilityValue() throws {
        var fileOn = Self.model("file-on")
        fileOn.relayCapabilityOverrides = RelayCapabilityOverrides(file: true, source: .user)
        var fileOff = Self.model("file-off")
        fileOff.relayCapabilityOverrides = RelayCapabilityOverrides(file: false, source: .user)
        let enabled = [fileOn, fileOff]
        let board = Self.board(Self.relayProvider(enabled: enabled, catalog: enabled + [Self.model("lib")]))

        #expect(Board.Capability.allCases.map(\.titleKey) == ["Vision", "Files", "Thinking", "Tool calls", "Web Search"])
        #expect(Board.Capability.allCases.map(\.titleTable) == [.chat, .providers, .providers, .providers, .chat])
        #expect([Board.Support.supported, .unknown, .unsupported].map(\.key) == ["Supported", "Unknown", "Not supported"])
        #expect([Board.Support.supported, .unknown, .unsupported].map(\.table) == [.providers, .localizable, .providers])

        for id in ["file-on", "file-off", "lib"] {
            let row = try Self.row(board, id)
            let parts = RelayCatalogRowContent.accessibilityValue(row).components(separatedBy: ", ")
            let expected = zip(Board.Capability.allCases, row.caps).map { capability, support in
                "\(L10n.tr(capability.titleKey, table: capability.titleTable)) \(L10n.tr(support.key, table: support.table))"
            }
            #expect(parts == expected, "\(id)")
            #expect(parts.count == 5, "\(id)")
        }
        // State follows the row model: the same capability reads differently when the override is on vs off.
        let files = L10n.tr("Files", table: .providers)
        let onValue = RelayCatalogRowContent.accessibilityValue(try Self.row(board, "file-on"))
        let offValue = RelayCatalogRowContent.accessibilityValue(try Self.row(board, "file-off"))
        #expect(onValue.contains("\(files) \(L10n.tr("Supported", table: .providers))"))
        #expect(offValue.contains("\(files) \(L10n.tr("Not supported", table: .providers))"))

        // The production view attaches this value to the tap element of both row kinds.
        let enabledSource = try Self.productionSource("Features/Providers/ProviderEnabledModels.swift")
        let librarySource = try Self.productionSource("Features/Providers/ProviderModelLibrary.swift")
        #expect(enabledSource.contains(".accessibilityValue(RelayCatalogRowContent.accessibilityValue(boardRow))"))
        #expect(librarySource.contains(".accessibilityValue(RelayCatalogRowContent.accessibilityValue(row))"))
    }

    // MARK: - BOARD-CATALOG-18

    @Test("BOARD-CATALOG-18 when the group header 'Enable all' appears: with partial enabling it collects only the rest; fully enabled / only non-enableable rows left shows nothing; denied-key landings are not counted; official providers do not get it")
    func board18EnableAllAvailability() throws {
        let claude = ["claude-opus-4", "claude-sonnet-4-5", "claude-haiku-4-5"].map { Self.model($0) }
        let offline = Self.model("claude-offline", isAvailable: false)

        // Partially enabled: in the production group projection the Anthropic group only has the not-yet-enabled ones, and the action collects the enableable ones among them in the same order as the group rows.
        let partial = Self.relayProvider(enabled: [claude[0]], catalog: claude + [offline, Self.model("gpt-5")])
        let group = try #require(buildProviderCatalogGroups(for: partial, searchText: "").first { $0.id == "anthropic" })
        #expect(group.models.map(\.id) == ["claude-sonnet-4-5", "claude-haiku-4-5", "claude-offline"])
        #expect(Board.enableAllModelIDs(provider: partial, groupModels: group.models) == ["claude-sonnet-4-5", "claude-haiku-4-5"])
        // Same criterion as the row model: exactly the rows with a plus at the trailing end are the ones that will be enabled.
        let board = Self.board(partial)
        #expect(
            try group.models.filter { try Self.row(board, $0.id).trailing == [.add] }.map(\.id)
                == Board.enableAllModelIDs(provider: partial, groupModels: group.models)
        )

        // Fully enabled: even passing the whole group in yields empty (the button does not appear).
        let all = Self.relayProvider(enabled: claude, catalog: claude + [offline])
        #expect(Board.enableAllModelIDs(provider: all, groupModels: claude).isEmpty)
        // Only non-enableable rows left: not shown.
        #expect(Board.enableAllModelIDs(provider: all, groupModels: [offline]).isEmpty)

        // Denied access: ones that would land on a key already judged denied are not counted; ones marked on other keys are collected as usual.
        var deniedOnMain = Self.model("claude-denied")
        deniedOnMain.relayDeniedKeyID = RelayKeyBinding.implicitKeyID
        var deniedElsewhere = Self.model("claude-other-key")
        deniedElsewhere.relayDeniedKeyID = "k-gone"
        let singleKey = Self.relayProvider(enabled: [claude[0]], catalog: claude + [deniedOnMain, deniedElsewhere])
        #expect(
            Board.enableAllModelIDs(provider: singleKey, groupModels: [claude[1], deniedOnMain, deniedElsewhere])
                == ["claude-sonnet-4-5", "claude-other-key"]
        )

        #expect(Board.enableAllKey == "Add All")
        // Production wiring: only the board branch hands the action to the group list; the home "Add model" and official providers do not pass it.
        let library = try Self.productionSource("Features/Providers/ProviderModelLibrary.swift")
        #expect(library.contains("onEnableAllInGroup: catalogBoard == nil ? nil : { group in"))
        let picker = try Self.productionSource("Features/Home/HomeModelPickerSheet.swift")
        #expect(!picker.contains("onEnableAllInGroup"))
    }

    // MARK: - BOARD-CATALOG-19

    @Test("BOARD-CATALOG-19 'Enable all' goes through the production enabling path: all enableable models of the group become enabled, written back once, key ownership same as single enabling, and not a single probe request is sent (contrast: single enabling does probe)")
    func board19EnableAllSendsNoProbe() async throws {
        let stub = RelaySetupHTTPStub()
        var provider = Self.twoKeyProvider()
        provider.baseURLText = stub.endpoint + "/v1"
        // Connection protocol auto: single enabling probes on this kind of connection, so the batch not probing is meaningful.
        provider.relayRequested?.transport = .auto
        let extra = ["claude-sonnet-4-5", "claude-haiku-4-5"].map { Self.keyed($0, listedBy: ["k-claude"]) }
        let offline: AIModel = {
            var model = Self.keyed("claude-offline", listedBy: ["k-claude"])
            model.isAvailable = false
            return model
        }()
        provider.catalogModels += extra + [offline]
        let state = Self.makeState(provider)

        let current = try #require(state.provider(for: provider.id))
        let group = try #require(
            buildProviderCatalogGroups(for: current, searchText: "").first { $0.id == "anthropic" }
        )
        let expected = Board.enableAllModelIDs(provider: provider, groupModels: group.models)
        #expect(expected == ["claude-sonnet-4-5", "claude-haiku-4-5"])
        // The key a single enable would land on (production bindCases rule), matched one by one after the batch.
        let expectedKeys = expected.map { ProviderManager.relayBoundKeyID(for: $0, in: provider) }
        #expect(expectedKeys == ["k-claude", "k-claude"])
        let before = stub.requests.count

        let versionBefore = state.providersVersion
        let added = RelayCatalogEnableAll.perform(groupModels: group.models, providerID: provider.id, appState: state)
        // Written only once: the whole group is written back in one go, not one full overwrite per model (sync and background wrap-up both follow the write-back count).
        #expect(state.providersVersion == versionBefore + 1)
        await state.providerManager.waitForRelayModelProbeForTesting(providerID: provider.id)

        #expect(added == 2)
        #expect(RelayCatalogEnableAll.feedbackMessage(added: added) == String(format: L10n.tr("Added %lld models", table: .providers), 2))
        #expect(RelayCatalogEnableAll.feedbackMessage(added: 0) == nil)
        let after = try #require(state.provider(for: provider.id))
        #expect(after.models.map(\.id) == ["gpt-5", "claude-opus-4", "claude-sonnet-4-5", "claude-haiku-4-5"])
        #expect(!after.models.contains { $0.id == "claude-offline" }, "non-enableable rows are not counted")
        // Key ownership: lands on the key that lists it, not always the primary key.
        for (id, keyID) in zip(expected, expectedKeys) {
            #expect(after.models.first { $0.id == id }?.relayKeyID == keyID, "\(id)")
            #expect(RelayKeyBinding.modelState(after, modelID: id)?.boundKeyID == "k-claude", "\(id)")
        }
        // Zero probes: no request goes out, there is no lazy-verify state, and no protocol is written on the models.
        #expect(stub.requests.count == before)
        #expect(stub.generationModels.isEmpty)
        #expect(state.relayModelProbeStates[provider.id]?.isEmpty ?? true)
        for id in expected {
            #expect(after.models.first { $0.id == id }?.relayTransport == nil, "\(id)")
        }
        // This group has nothing left to enable: the button does not appear.
        let remaining = buildProviderCatalogGroups(for: after, searchText: "").first { $0.id == "anthropic" }?.models ?? []
        #expect(Board.enableAllModelIDs(provider: after, groupModels: remaining).isEmpty)

        // Contrast: single enabling on the same connection (the plus entry at the end of a model library row) does probe, so the zero requests above are not because a stub was left unwired.
        state.enableModel(modelID: "gpt-4.1", for: provider.id, lazilyVerifiesRelayTransport: true)
        await state.providerManager.waitForRelayModelProbeForTesting(providerID: provider.id)
        #expect(stub.generationModels.contains("gpt-4.1"))
    }

    // MARK: - BOARD-CATALOG-20

    /// Three keys: the primary key lists gpt-5 / gpt-4.1 / gpt-legacy (whose lister is the default); k-claude lists claude-opus-4 and the shared claude-haiku; k-empty lists none.
    private static func keyFilterProvider() -> Provider {
        var provider = Self.twoKeyProvider()
        provider.catalogModels += [
            Self.keyed("claude-haiku", listedBy: ["initial", "k-claude"], transport: .anthropicMessages),
            Self.keyed("gpt-legacy", transport: .openaiResponses),
        ]
        provider.relayKeys?.append(RelayKey(id: "k-empty", apiKey: "sk-empty-4444-5555"))
        return provider
    }

    @Test("BOARD-CATALOG-20 key(id) filter: the lister criterion matches listingKeyIDs and enabled rows filter by the same criterion; the chip only appears while effective, sits after All, and its text matches the key row title; tapping another leaves; a missing key / empty catalog falls back to All")
    func board20KeyFilter() throws {
        let provider = Self.keyFilterProvider()
        let ids = RelayKeyBinding.keyIDs(provider)
        let enabledIDs = Set(provider.models.map(\.id))
        func listed(by keyID: String, _ models: [AIModel]) -> [String] {
            models.filter { RelayKeyBinding.listingKeyIDs($0, keyIDs: ids).contains(keyID) }.map(\.id)
        }

        // Criterion: the entry's listers contain the key; a missing lister = the primary key.
        let claude = Self.board(provider, filter: .key("k-claude"))
        #expect(claude.selectedFilter == .key("k-claude"))
        #expect(Self.rows(claude, .library).map(\.id) == listed(by: "k-claude", provider.catalogModels.filter { !enabledIDs.contains($0.id) }))
        #expect(Self.rows(claude, .library).map(\.id) == ["claude-haiku"])
        #expect(Self.rows(claude, .enabled).map(\.id) == ["claude-opus-4"])
        let primary = Self.board(provider, filter: .key("initial"))
        #expect(Self.rows(primary, .library).map(\.id) == ["gpt-4.1", "claude-haiku", "gpt-legacy"])
        #expect(Self.rows(primary, .enabled).map(\.id) == ["gpt-5"])
        // Enabled models outside the catalog (added manually) do not appear under a key filter, even for the primary key.
        var withManual = provider
        withManual.models.append(Self.model("manual-only", isManual: true))
        let manualBoard = Self.board(withManual, filter: .key("initial"))
        #expect(manualBoard.selectedFilter == .key("initial"))
        #expect(!Self.rows(manualBoard, .enabled).map(\.id).contains("manual-only"))
        #expect(Self.rows(Self.board(withManual), .enabled).map(\.id).contains("manual-only"))
        #expect(Board.matches(.key("k-claude"), provider: provider, model: try #require(provider.catalogModels.first { $0.id == "claude-haiku" })))
        #expect(!Board.matches(.key("k-claude"), provider: provider, model: try #require(provider.catalogModels.first { $0.id == "gpt-legacy" })))

        // Chip: appears only while effective, after All and before the protocol chips.
        let transports = Self.board(provider).filters
        #expect(transports.first == .all)
        #expect(!transports.contains(.key("k-claude")))
        #expect(claude.filters == [.all, .key("k-claude")] + transports.dropFirst())
        #expect(Board.filters(provider: provider, models: provider.models + provider.catalogModels, current: .key("k-claude")) == claude.filters)
        #expect(Board.keyFilterTitle(provider: provider, keyID: "k-claude")
            == RelayKeysBoardModel.make(provider).rows.first { $0.id == "k-claude" }?.title)
        #expect(Board.keyFilterTitle(provider: provider, keyID: "initial") == "Main")

        // Tapping another chip: leaves the key filter and the chip disappears.
        let toTransport = Self.board(provider, filter: .transport(.anthropicMessages))
        #expect(toTransport.selectedFilter == .transport(.anthropicMessages))
        #expect(!toTransport.filters.contains { if case .key = $0 { true } else { false } })
        #expect(!Self.board(provider, filter: .all).filters.contains(.key("k-claude")))

        // A single-protocol connection normally shows no chips: while the key filter is effective it shows [All, Key], and the whole row disappears after leaving.
        let single = Self.twoKeyProvider()
        #expect(Self.board(single).filters.isEmpty)
        #expect(Self.board(single, filter: .key("k-claude")).filters == [.all, .key("k-claude")])

        // Fall back to All: the key no longer exists / its catalog is 0.
        for gone in ["ghost", "k-empty"] {
            let fallback = Self.board(provider, filter: .key(gone))
            #expect(fallback.selectedFilter == .all, "\(gone)")
            #expect(fallback.filters == transports, "\(gone)")
            #expect(Self.rows(fallback, .library).count == provider.catalogModels.count - enabledIDs.count)
        }

        // Single key (implicit): the same criterion.
        var implicit = provider
        implicit.relayKeys = nil
        #expect(Self.board(implicit, filter: .key(RelayKeyBinding.implicitKeyID)).selectedFilter == .key(RelayKeyBinding.implicitKeyID))
    }

    // MARK: - BOARD-CATALOG-21

    @Test("BOARD-CATALOG-21 entering the model library via key(id): the route carries keyID (not by default) and is pushed above the detail; the detail page's initial value is key(id) and the first board frame has it selected")
    func board21OpensLibraryWithKeyFilter() throws {
        let provider = Self.keyFilterProvider()
        let state = Self.makeState(provider)
        state.navigation.reset(to: [.providerDetail(providerID: provider.id), .relayKeys(providerID: provider.id)])
        state.openRelayModelLibrary(providerID: provider.id, keyID: "k-claude")
        #expect(state.navigation.path == [
            .providerDetail(providerID: provider.id),
            .relayKeys(providerID: provider.id),
            .relayModelLibrary(providerID: provider.id, keyID: "k-claude"),
        ])
        state.pop()
        #expect(state.navigation.path.last == .relayKeys(providerID: provider.id), "back returns to the key page")
        state.openRelayModelLibrary(providerID: provider.id)
        #expect(state.navigation.path.last == .relayModelLibrary(providerID: provider.id, keyID: nil))

        // The route branch (in AppRouteDestination, shared by the outer stack and the wide-screen right column) hands keyID to the detail page; the page's initial filter is that, so the very first board frame already shows that filter.
        let root = try Self.productionSource("Features/App/AppRouteDestination.swift")
        #expect(root.contains("case let .relayModelLibrary(providerID, keyID):"))
        #expect(root.contains("ProviderDetailView(providerID: providerID, page: .modelLibrary, keyFilter: keyID)"))
        let view = ProviderDetailView(providerID: provider.id, page: .modelLibrary, keyFilter: "k-claude")
        #expect(view.initialCatalogFilter == .key("k-claude"))
        #expect(ProviderDetailView(providerID: provider.id, page: .modelLibrary).initialCatalogFilter == .all)
        let firstFrame = Self.board(provider, filter: view.initialCatalogFilter)
        #expect(firstFrame.selectedFilter == .key("k-claude"))
        #expect(firstFrame.filters.contains(.key("k-claude")))
    }

    // MARK: - RL2-PROBESTATE ("unreachable" is invalidated when a key is confirmed usable / a send succeeds)

    private static let unreachable = RelayModelProbeState.failed(RelayModelProbeFailure(summary: "Upstream said no", httpStatus: 404))
    private static let claudeSecret = "sk-claude-2222-3333"

    /// Two keys + connection protocol auto (lazy verify only happens on auto); the second key additionally binds claude-sonnet-4-5, to look at "another model on the same key".
    private static func probeStateProvider(_ stub: RelaySetupHTTPStub) -> Provider {
        var provider = Self.twoKeyProvider()
        provider.baseURLText = stub.endpoint + "/v1"
        provider.relayRequested?.transport = .auto
        provider.models.append(Self.keyed("claude-sonnet-4-5", keyID: "k-claude"))
        provider.catalogModels.append(Self.keyed("claude-sonnet-4-5", listedBy: ["k-claude"]))
        return provider
    }

    private static func probeStateAppState(_ provider: Provider, _ states: [String: RelayModelProbeState]) -> AppState {
        let state = Self.makeState(provider)
        state.relayModelProbeStates[provider.id] = states
        return state
    }

    @Test("RL2-PROBESTATE-01 several keys: replacing the value of K clears 'unreachable' for models bound to K and reprobes once; those bound to J are untouched")
    func probeState01ReplaceSecretClearsBoundModels() async throws {
        ProviderAPIKeyStore.useInMemoryBackendForTesting(true)
        defer { ProviderAPIKeyStore.useInMemoryBackendForTesting(false) }
        let stub = RelaySetupHTTPStub()
        let provider = Self.probeStateProvider(stub)
        let state = Self.probeStateAppState(provider, ["claude-opus-4": Self.unreachable, "gpt-5": Self.unreachable])

        #expect(await state.providerManager.applyRelayKeyOperation(
            providerID: provider.id, .replaceSecret(id: "k-claude", apiKey: "sk-claude-new-4444")
        ))
        await state.providerManager.waitForRelayModelProbeForTesting(providerID: provider.id)

        #expect(state.relayModelProbeStates[provider.id]?["claude-opus-4"] == nil)
        #expect(stub.generationModels == ["claude-opus-4"], "only the model bound to K without a protocol is reprobed, once")
        #expect(state.provider(for: provider.id)?.models.first { $0.id == "claude-opus-4" }?.relayTransport != nil)
        #expect(state.relayModelProbeStates[provider.id]?["gpt-5"] == Self.unreachable, "those bound to other keys are untouched")
    }

    @Test("RL2-PROBESTATE-02 several keys: the catalog fetch for K succeeds and its status becomes ok -> 'unreachable' is kept with 0 lazy-verify requests (a gate 403 must not be erased)")
    func probeState02CatalogSuccessKeepsState() async throws {
        ProviderAPIKeyStore.useInMemoryBackendForTesting(true)
        defer { ProviderAPIKeyStore.useInMemoryBackendForTesting(false) }
        let stub = RelaySetupHTTPStub()
        stub.catalog(secret: Self.claudeSecret, modelIDs: ["claude-opus-4", "claude-sonnet-4-5"])
        let provider = Self.probeStateProvider(stub)
        let state = Self.probeStateAppState(provider, ["claude-opus-4": Self.unreachable])

        #expect(await state.providerManager.refreshRelayCatalog(providerID: provider.id, onlyKeyID: "k-claude"))
        await state.providerManager.waitForRelayModelProbeForTesting(providerID: provider.id)

        #expect(state.provider(for: provider.id)?.relayKeys?[1].status?.state == .ok, "precondition: K goes from denied to ok")
        #expect(state.relayModelProbeStates[provider.id]?["claude-opus-4"] == Self.unreachable)
        #expect(stub.generationModels.isEmpty)
    }

    @Test("RL2-PROBESTATE-03 single key: replacing the primary key value clears all 'unreachable' entries, and models with a model-level protocol are not reprobed; saving the same value / changing to empty does not count as replacing")
    func probeState03SingleKeyReplaceClearsAll() async throws {
        ProviderAPIKeyStore.useInMemoryBackendForTesting(true)
        defer { ProviderAPIKeyStore.useInMemoryBackendForTesting(false) }
        let stub = RelaySetupHTTPStub()
        let bare = Self.model("bare-model")
        let pinned = Self.model("pinned-model", transport: .openaiResponses, source: .observed)
        var provider = Self.relayProvider(enabled: [bare, pinned], catalog: [bare, pinned])
        provider.baseURLText = stub.endpoint + "/v1"
        let seeded: [String: RelayModelProbeState] = ["bare-model": Self.unreachable, "pinned-model": Self.unreachable]
        let state = Self.probeStateAppState(provider, seeded)
        // The same write entry point used by saving an edited connection.
        func save(_ mutate: (inout Provider) -> Void) async throws {
            var edited = try #require(state.provider(for: provider.id))
            mutate(&edited)
            state.providerManager.updateProvider(edited)
            await state.providerManager.waitForRelayModelProbeForTesting(providerID: provider.id)
        }

        // Saving the same value (only the name changed): nothing cleared, nothing probed.
        try await save { $0.customName = "Renamed" }
        #expect(state.relayModelProbeStates[provider.id] == seeded)
        // Changing to an empty value: does not count as replacing.
        try await save { $0.apiKey = ""; $0.apiKeyPreview = APIKeyMask.masked("") }
        #expect(state.relayModelProbeStates[provider.id] == seeded)
        #expect(stub.generationModels.isEmpty)

        try await save { $0.apiKey = "sk-replaced"; $0.apiKeyPreview = APIKeyMask.masked("sk-replaced") }
        #expect(state.relayModelProbeStates[provider.id]?.isEmpty ?? true)
        #expect(stub.generationModels == ["bare-model"], "only the one without a protocol gets a lazy verify")
    }

    @Test("RL2-PROBESTATE-04 a successful send (K was already ok) -> that model is cleared with 0 lazy verifies; another 'unreachable' on the same connection is untouched")
    func probeState04SendSuccessClearsOnlyThatModel() async throws {
        let stub = RelaySetupHTTPStub()
        var provider = Self.probeStateProvider(stub)
        provider.models.append(Self.keyed("gpt-4.1"))
        let state = Self.probeStateAppState(provider, ["gpt-5": Self.unreachable, "gpt-4.1": Self.unreachable])

        state.providerManager.recordRelayKeyAccessSuccess(providerID: provider.id, modelID: "gpt-5", keyID: "initial")
        await state.providerManager.waitForRelayModelProbeForTesting(providerID: provider.id)

        #expect(state.relayModelProbeStates[provider.id]?["gpt-5"] == nil)
        #expect(state.relayModelProbeStates[provider.id]?["gpt-4.1"] == Self.unreachable)
        #expect(stub.generationModels.isEmpty)
    }

    @Test("RL2-PROBESTATE-05 a successful send that turns K from not-ok to ok -> that model is cleared, another 'unreachable' on the same key is kept, 0 lazy verifies")
    func probeState05SendSuccessRestoringKeyKeepsSiblings() async throws {
        let stub = RelaySetupHTTPStub()
        let provider = Self.probeStateProvider(stub)
        let state = Self.probeStateAppState(provider, ["claude-opus-4": Self.unreachable, "claude-sonnet-4-5": Self.unreachable])

        state.providerManager.recordRelayKeyAccessSuccess(providerID: provider.id, modelID: "claude-opus-4", keyID: "k-claude")
        await state.providerManager.waitForRelayModelProbeForTesting(providerID: provider.id)

        #expect(state.provider(for: provider.id)?.relayKeys?[1].status?.state == .ok, "precondition: K goes from denied to ok")
        #expect(state.relayModelProbeStates[provider.id]?["claude-opus-4"] == nil)
        #expect(state.relayModelProbeStates[provider.id]?["claude-sonnet-4-5"] == Self.unreachable)
        #expect(stub.generationModels.isEmpty)
    }

    @Test("RL2-PROBESTATE-06 'verifying': neither value replacement (T1) nor a successful send (T2) clears it")
    func probeState06InFlightSurvivesBothTriggers() async throws {
        ProviderAPIKeyStore.useInMemoryBackendForTesting(true)
        defer { ProviderAPIKeyStore.useInMemoryBackendForTesting(false) }
        let stub = RelaySetupHTTPStub()
        let provider = Self.probeStateProvider(stub)
        let state = Self.probeStateAppState(provider, ["claude-opus-4": .inFlight])

        #expect(await state.providerManager.applyRelayKeyOperation(
            providerID: provider.id, .replaceSecret(id: "k-claude", apiKey: "sk-claude-new-4444")
        ))
        #expect(state.relayModelProbeStates[provider.id]?["claude-opus-4"] == .inFlight)
        state.providerManager.recordRelayKeyAccessSuccess(providerID: provider.id, modelID: "claude-opus-4", keyID: "k-claude")
        await state.providerManager.waitForRelayModelProbeForTesting(providerID: provider.id)

        #expect(state.relayModelProbeStates[provider.id]?["claude-opus-4"] == .inFlight)
        #expect(stub.generationModels.isEmpty)
    }

    @Test("RL2-PROBESTATE-07 replacing the value of the effective key K while a probe is in flight: the old result failing later is not recorded as 'unreachable', and 'verifying' is cleared")
    func probeState07ReplaceDuringInFlightProbeDiscardsStaleFailure() async throws {
        ProviderAPIKeyStore.useInMemoryBackendForTesting(true)
        defer { ProviderAPIKeyStore.useInMemoryBackendForTesting(false) }
        let stub = RelaySetupHTTPStub()
        stub.failGeneration(status: 404)
        let provider = Self.probeStateProvider(stub)
        let state = Self.probeStateAppState(provider, [:])

        let probe = Task { await state.providerManager.probeRelayModelTransport(providerID: provider.id, modelID: "claude-opus-4") }
        // Wait until the probe has recorded "verifying" and suspended: before it returns to the main actor, the synchronous store write of the replacement below has already happened.
        var spins = 0
        while state.relayModelProbeStates[provider.id]?["claude-opus-4"] != .inFlight, spins < 10_000 {
            await Task.yield()
            spins += 1
        }
        #expect(state.relayModelProbeStates[provider.id]?["claude-opus-4"] == .inFlight, "precondition: probe in flight")
        #expect(await state.providerManager.applyRelayKeyOperation(
            providerID: provider.id, .replaceSecret(id: "k-claude", apiKey: "sk-claude-new-4444")
        ))
        await probe.value
        await state.providerManager.waitForRelayModelProbeForTesting(providerID: provider.id)

        #expect(stub.generationModels.contains("claude-opus-4"), "the old key's probe request was indeed sent and failed")
        #expect(state.relayModelProbeStates[provider.id]?["claude-opus-4"] == nil, "result discarded: not recorded as unreachable, and verifying is cleared")
        #expect(state.provider(for: provider.id)?.models.first { $0.id == "claude-opus-4" }?.relayTransport == nil)
    }

    @Test("RL2-PROBESTATE-08 edit-connection save: when the primary key is replaced via the key page while verification is in flight -> the stored value is the new one, and this page's save does not trigger another 'replacement' clearing")
    func probeState08EditSaveKeepsLiveSecretReplacedDuringVerification() async throws {
        ProviderAPIKeyStore.useInMemoryBackendForTesting(true)
        defer { ProviderAPIKeyStore.useInMemoryBackendForTesting(false) }
        let stub = RelaySetupHTTPStub()
        let bare = Self.model("bare-model")
        var provider = Self.relayProvider(enabled: [bare], catalog: [bare])
        provider.baseURLText = stub.endpoint + "/v1"
        let state = Self.probeStateAppState(provider, [:])

        // Snapshot at the moment of tapping save (the argument of save(provider:)); the draft only changed the name.
        let snapshot = try #require(state.provider(for: provider.id))
        var candidate = snapshot
        candidate.customName = "Edited"
        candidate = RelayEditSavePolicy.recordingVerification(candidate, verified: true)

        // Verification in flight: the key page replaces the value (the same write entry point).
        var replaced = try #require(state.provider(for: provider.id))
        replaced.apiKey = "sk-replaced-on-key-page"
        replaced.apiKeyPreview = APIKeyMask.masked("sk-replaced-on-key-page")
        state.providerManager.updateProvider(replaced)
        await state.providerManager.waitForRelayModelProbeForTesting(providerID: provider.id)
        // The clearing and reprobe from that replacement have already happened; an "unreachable" appearing afterwards must not be cleared by this page's save.
        let seeded: [String: RelayModelProbeState] = ["bare-model": Self.unreachable]
        state.relayModelProbeStates[provider.id] = seeded
        let probesBeforeSave = stub.generationModels.count

        // Persist after verification succeeds (the same step as RelayEditView.save).
        let merged = RelayEditSavePolicy.mergingLiveSecrets(
            candidate, base: snapshot, live: state.provider(for: provider.id)
        )
        state.providerManager.updateProvider(merged)
        await state.providerManager.waitForRelayModelProbeForTesting(providerID: provider.id)

        let stored = try #require(state.provider(for: provider.id))
        #expect(stored.apiKey == "sk-replaced-on-key-page", "the pre-verification snapshot must not overwrite the key page's new value with the old one")
        #expect(stored.customName == "Edited", "fields changed in the draft follow the draft")
        #expect(state.relayModelProbeStates[provider.id] == seeded, "this page did not replace the value: unreachable is not cleared")
        #expect(stub.generationModels.count == probesBeforeSave, "this page did not replace the value: no reprobe")
    }

    // MARK: - RL2-PROBESTATE-09 to 11 (an edit save that collides with changes elsewhere merges per field)

    private static let seededLiveStatus = ProviderConnectionState.issue(ProviderIssueMessage.unverifiedConnectionKey)

    /// The connection when the edit page was opened: protocol pinned to Chat, the verification sample is bare-model from the catalog, and the status is first recorded as unverified so that "whether the verification status was written" can be told apart.
    private static func editSaveProvider(_ stub: RelaySetupHTTPStub) -> Provider {
        let bare = Self.model("bare-model")
        var provider = Self.relayProvider(transport: .openaiChatCompletions, enabled: [bare], catalog: [bare])
        provider.baseURLText = stub.endpoint + "/v1"
        provider.customName = "Opened"
        provider.status = Self.seededLiveStatus
        return provider
    }

    /// The same coordinator entry as the edit page save (RelayEditView.save -> RelayEditSaveCommit.run), persisting through the production store write entry point.
    private static func runEditSave(
        _ state: AppState,
        providerID: UUID,
        draft: RelayEditView.Editor,
        baseline: RelayEditView.Editor,
        verify: (Provider) async throws -> Void
    ) async throws -> RelayEditSaveCommit.Outcome {
        let normalized = try #require(RelayEditSavePolicy.normalizedEndpoint(draft.endpoint, securityMode: draft.securityMode))
        let outcome = await RelayEditSaveCommit.run(
            draft: RelayEditSavePolicy.normalizedDraft(draft, normalizedEndpoint: normalized),
            baseline: baseline,
            normalizedEndpoint: normalized,
            live: { state.provider(for: providerID) },
            verify: verify,
            isCurrent: { true },
            persist: { state.providerManager.updateProvider($0) }
        )
        await state.providerManager.waitForRelayModelProbeForTesting(providerID: providerID)
        return outcome
    }

    private static func isPersisted(_ outcome: RelayEditSaveCommit.Outcome) -> Bool {
        if case .persisted = outcome { return true }
        return false
    }

    /// Simulates a cloud sync write: takes the connection currently in the store, changes a few fields and goes through the same write entry point.
    private static func sync(_ state: AppState, _ providerID: UUID, _ mutate: (inout Provider) -> Void) throws {
        var live = try #require(state.provider(for: providerID))
        mutate(&live)
        state.providerManager.updateProvider(live)
    }

    @Test("RL2-PROBESTATE-09 sync changed the name / models during verification -> the saved record contains the user's fields + the synced fields, the verification status is written, and the page closes")
    func probeState09SyncRenameDuringVerificationMerges() async throws {
        let stub = RelaySetupHTTPStub()
        let provider = Self.editSaveProvider(stub)
        let state = Self.makeState(provider)
        let baseline = RelayEditView.Editor(from: provider)
        var draft = baseline
        draft.endpoint = stub.endpoint + "/v2"

        var verified: [Provider] = []
        let outcome = try await Self.runEditSave(state, providerID: provider.id, draft: draft, baseline: baseline) { candidate in
            verified.append(candidate)
            try await state.providerManager.verifyRelayGeneration(candidate)
            if verified.count == 1 {
                try Self.sync(state, provider.id) {
                    $0.customName = "Synced"
                    $0.models.append(Self.model("synced-model"))
                }
            }
        }

        let stored = try #require(state.provider(for: provider.id))
        #expect(Self.isPersisted(outcome), "the page closes as usual")
        #expect(verified.count == 1, "only non-verification fields collided: no re-verification")
        #expect(stored.baseURLText == stub.endpoint + "/v2", "the address the user changed")
        #expect(stored.customName == "Synced", "the synced name is not overwritten by the snapshot taken when the page opened")
        #expect(stored.models.map(\.id).contains("synced-model"), "the model added by sync is kept")
        #expect(stored.status == .connected, "this verification result is written")
    }

    @Test("RL2-KEYSTATUS-11 edit save: when only the key status changed or a single key materialized into one list during verification -> this is not a verification-relevant change, no extra verification, and the save proceeds as usual")
    func keyStatus11StatusChangeIsNotVerificationInput() async throws {
        let stub = RelaySetupHTTPStub()
        let provider = Self.editSaveProvider(stub)
        let state = Self.makeState(provider)
        let baseline = RelayEditView.Editor(from: provider)
        var draft = baseline
        draft.endpoint = stub.endpoint + "/v2"

        // Pure function: the verification-relevant fields are the same before and after a single-entry materialization / status change; only replacing the value of a non-primary key counts.
        var materialized = provider
        materialized.relayKeys = [RelayKey(id: "initial", status: .init(state: .ok, httpStatus: nil, checkedAt: Date()))]
        #expect(RelayEditSavePolicy.verificationInputs(of: materialized) == RelayEditSavePolicy.verificationInputs(of: provider))
        var twoKeys = materialized
        twoKeys.relayKeys?.append(RelayKey(id: "k-b", apiKey: "sk-b"))
        var twoKeysReplaced = twoKeys
        twoKeysReplaced.relayKeys?[1].apiKey = "sk-b2"
        #expect(RelayEditSavePolicy.verificationInputs(of: twoKeys) != RelayEditSavePolicy.verificationInputs(of: twoKeysReplaced))

        var verified: [Provider] = []
        let outcome = try await Self.runEditSave(state, providerID: provider.id, draft: draft, baseline: baseline) { candidate in
            verified.append(candidate)
            try await state.providerManager.verifyRelayGeneration(candidate)
            if verified.count == 1 {
                // A real send succeeds in the meantime: the first status write on a single key materializes one list entry.
                state.providerManager.recordRelayKeyAccessSuccess(providerID: provider.id, modelID: "bare-model", keyID: "initial")
            }
        }

        let stored = try #require(state.provider(for: provider.id))
        #expect(state.provider(for: provider.id)?.relayKeys?.first?.status?.state == .ok, "precondition: a list entry with a status was indeed materialized in the meantime")
        #expect(Self.isPersisted(outcome), "the page closes as usual")
        #expect(verified.count == 1, "a status change is not a verification-relevant change: no re-verification")
        #expect(stub.generationModels.count == 1)
        #expect(stored.baseURLText == stub.endpoint + "/v2")
        #expect(stored.status == .connected, "this verification result is written")
    }

    @Test("RL2-PROBESTATE-10 sync changed the auth mode / headers the user did not change during verification -> the second probe is sent with the merged values and both sides are saved; if the second also collides -> save the merge without writing the verification status")
    func probeState10SyncVerificationFieldTriggersReverify() async throws {
        let stub = RelaySetupHTTPStub()
        let provider = Self.editSaveProvider(stub)
        let state = Self.makeState(provider)
        let baseline = RelayEditView.Editor(from: provider)
        var draft = baseline
        draft.endpoint = stub.endpoint + "/v2"
        let syncedHeaders = [RelayKeyValue(key: "X-Synced", value: "1")]

        // 1) Collides only during the first verification: the second goes out with the merged values and writes the verification status after passing.
        var verified: [Provider] = []
        let outcome = try await Self.runEditSave(state, providerID: provider.id, draft: draft, baseline: baseline) { candidate in
            verified.append(candidate)
            try await state.providerManager.verifyRelayGeneration(candidate)
            if verified.count == 1 {
                try Self.sync(state, provider.id) { $0.relayRequested?.headers = syncedHeaders }
            }
        }
        #expect(Self.isPersisted(outcome))
        #expect(verified.count == 2, "this verification result does not count: verify once more")
        #expect(verified.last?.relayRequested?.headers == syncedHeaders, "the second probe carries the synced headers")
        #expect(verified.last?.baseURLText == stub.endpoint + "/v2", "the second probe carries the user's address")
        var stored = try #require(state.provider(for: provider.id))
        #expect(stored.relayRequested?.headers == syncedHeaders)
        #expect(stored.baseURLText == stub.endpoint + "/v2")
        #expect(stored.status == .connected)

        // 2) Collides during both verifications: save the merge and do not write the verification status (keep the live status).
        try Self.sync(state, provider.id) { $0.status = Self.seededLiveStatus }
        let reopened = try #require(state.provider(for: provider.id))
        let baseline2 = RelayEditView.Editor(from: reopened)
        var draft2 = baseline2
        draft2.endpoint = stub.endpoint + "/v3"
        verified = []
        let outcome2 = try await Self.runEditSave(state, providerID: provider.id, draft: draft2, baseline: baseline2) { candidate in
            verified.append(candidate)
            try await state.providerManager.verifyRelayGeneration(candidate)
            if verified.count == 1 {
                try Self.sync(state, provider.id) { $0.relayRequested?.authMode = .xApiKey }
            } else {
                try Self.sync(state, provider.id) { $0.relayRequested?.customUserAgent = "SyncedUA/2" }
            }
        }
        #expect(Self.isPersisted(outcome2), "the page closes as usual")
        #expect(verified.count == 2, "verify at most once more")
        #expect(verified.last?.relayRequested?.authMode == .xApiKey)
        stored = try #require(state.provider(for: provider.id))
        #expect(stored.baseURLText == stub.endpoint + "/v3")
        #expect(stored.relayRequested?.authMode == .xApiKey)
        #expect(stored.relayRequested?.customUserAgent == "SyncedUA/2")
        #expect(stored.relayRequested?.headers == syncedHeaders)
        #expect(stored.status == Self.seededLiveStatus, "collided again the second time: the verification status is not written")
    }

    @Test("RL2-PROBESTATE-11 sync changed fields the user did not change after the page opened and before tapping save -> the save keeps the synced values")
    func probeState11SyncBeforeSaveKeepsLiveValues() async throws {
        let stub = RelaySetupHTTPStub()
        let provider = Self.editSaveProvider(stub)
        let state = Self.makeState(provider)
        let baseline = RelayEditView.Editor(from: provider)
        let syncedHeaders = [RelayKeyValue(key: "X-Synced", value: "1")]
        try Self.sync(state, provider.id) {
            $0.customName = "Synced"
            $0.relayRequested?.headers = syncedHeaders
        }

        // Zero-network save: the user only changed the service tier.
        var draft = baseline
        draft.serviceTier = "flex"
        var verifyCount = 0
        let outcome = try await Self.runEditSave(state, providerID: provider.id, draft: draft, baseline: baseline) { _ in
            verifyCount += 1
        }
        #expect(Self.isPersisted(outcome))
        #expect(verifyCount == 0, "zero network")
        var stored = try #require(state.provider(for: provider.id))
        #expect(stored.relayRequested?.serviceTier == "flex")
        #expect(stored.relayRequested?.headers == syncedHeaders, "headers the user did not change take the live value")
        #expect(stored.customName == "Synced")

        // Verification path: sync changes User-Agent again before tapping save, and both the probe and the save carry it.
        try Self.sync(state, provider.id) { $0.relayRequested?.customUserAgent = "SyncedUA/1" }
        var draft2 = baseline
        draft2.endpoint = stub.endpoint + "/v2"
        var verified: [Provider] = []
        let outcome2 = try await Self.runEditSave(state, providerID: provider.id, draft: draft2, baseline: baseline) { candidate in
            verified.append(candidate)
            try await state.providerManager.verifyRelayGeneration(candidate)
        }
        #expect(Self.isPersisted(outcome2))
        #expect(verified.count == 1)
        #expect(verified.first?.relayRequested?.customUserAgent == "SyncedUA/1")
        stored = try #require(state.provider(for: provider.id))
        #expect(stored.relayRequested?.customUserAgent == "SyncedUA/1")
        #expect(stored.relayRequested?.headers == syncedHeaders)
        #expect(stored.relayRequested?.serviceTier == "flex")
        #expect(stored.baseURLText == stub.endpoint + "/v2")
        #expect(stored.status == .connected)
    }

    @Test("RL2-PROBESTATE-11b sync changed verification-relevant fields the user did not change before tapping save, while the user only changed a non-verification field -> the primary button is 'Save', no probe, saved as merged")
    func probeState11bSyncedVerificationFieldDoesNotTriggerProbe() async throws {
        let stub = RelaySetupHTTPStub()
        let provider = Self.editSaveProvider(stub)
        let state = Self.makeState(provider)
        let baseline = RelayEditView.Editor(from: provider)
        try Self.sync(state, provider.id) { $0.relayRequested?.authMode = .xApiKey }

        // The iOS edit page has no name field: the user only changed the service tier (also a zero-network field).
        var draft = baseline
        draft.serviceTier = "flex"
        let live = try #require(state.provider(for: provider.id))
        let board = RelayEditBoardModel.make(provider: live, editor: draft, baseline: baseline)
        #expect(board.actionBar.primary == .save, "the merged values carry no connection identity change relative to the live record: the primary button is Save")
        #expect(RelayEditSavePolicy.primaryAction(from: live, editor: draft) == .validateAndSave, "contrast: comparing the draft against the live record would wrongly require verification")

        var verifyCount = 0
        let outcome = try await Self.runEditSave(state, providerID: provider.id, draft: draft, baseline: baseline) { _ in
            verifyCount += 1
        }
        guard case .persisted(_, let refreshesCatalog) = outcome else {
            Issue.record("should save and close the page as usual")
            return
        }
        #expect(!refreshesCatalog, "connection identity unchanged: the catalog is not refreshed")
        #expect(verifyCount == 0, "zero network")
        let stored = try #require(state.provider(for: provider.id))
        #expect(stored.relayRequested?.authMode == .xApiKey, "the auth mode changed by sync is kept")
        #expect(stored.relayRequested?.serviceTier == "flex")
        #expect(stored.catalogModels.map(\.id) == ["bare-model"], "the catalog is not cleared")
        #expect(stored.status == Self.seededLiveStatus, "the verification status is not written")
    }

    private struct ProbeFailed: Error {}

    @Test("RL2-PROBESTATE-12 first verification fails while verification-relevant fields the user did not change are modified elsewhere -> a second probe goes out with the merged values, and saving / the failure card follow the second result")
    func probeState12FailedVerificationWithCollisionReprobes() async throws {
        let syncedHeaders = [RelayKeyValue(key: "X-Synced", value: "1")]

        // 1) The second passes: save the merged values and write the verification status.
        let stub = RelaySetupHTTPStub()
        let provider = Self.editSaveProvider(stub)
        let state = Self.makeState(provider)
        let baseline = RelayEditView.Editor(from: provider)
        var draft = baseline
        draft.endpoint = stub.endpoint + "/v2"
        var verified: [Provider] = []
        let outcome = try await Self.runEditSave(state, providerID: provider.id, draft: draft, baseline: baseline) { candidate in
            verified.append(candidate)
            if verified.count == 1 {
                try Self.sync(state, provider.id) { $0.relayRequested?.headers = syncedHeaders }
                throw ProbeFailed()
            }
            try await state.providerManager.verifyRelayGeneration(candidate)
        }
        #expect(verified.count == 2, "the failed result does not count: probe once more with the merged values")
        #expect(verified.last?.relayRequested?.headers == syncedHeaders)
        #expect(Self.isPersisted(outcome), "the second passes: the page closes as usual")
        let stored = try #require(state.provider(for: provider.id))
        #expect(stored.status == .connected)
        #expect(stored.relayRequested?.headers == syncedHeaders)
        #expect(stored.baseURLText == stub.endpoint + "/v2")

        // 2) The second also fails: the failure card's candidate is the merged values and the store is untouched.
        let failing = RelaySetupHTTPStub()
        failing.failGeneration(status: 404)
        let provider2 = Self.editSaveProvider(failing)
        let state2 = Self.makeState(provider2)
        let baseline2 = RelayEditView.Editor(from: provider2)
        var draft2 = baseline2
        draft2.endpoint = failing.endpoint + "/v2"
        var probes = 0
        let outcome2 = try await Self.runEditSave(state2, providerID: provider2.id, draft: draft2, baseline: baseline2) { candidate in
            probes += 1
            if probes == 1 {
                try Self.sync(state2, provider2.id) { $0.relayRequested?.headers = syncedHeaders }
            }
            try await state2.providerManager.verifyRelayGeneration(candidate)
        }
        #expect(probes == 2)
        guard case .verificationFailed(_, let candidate) = outcome2 else {
            Issue.record("the second failure should show the failure card")
            return
        }
        #expect(candidate.relayRequested?.headers == syncedHeaders, "the failure card candidate is the merged values")
        #expect(candidate.baseURLText == failing.endpoint + "/v2")
        let stored2 = try #require(state2.provider(for: provider2.id))
        #expect(stored2.baseURLText == failing.endpoint + "/v1", "the store is untouched until the failure is confirmed")
        #expect(stored2.status == Self.seededLiveStatus)
    }

    @Test("RL2-PROBESTATE-13 the second probe fails and collides with changes elsewhere again -> save the merge, do not write the verification status, close the page as usual, show no failure card, 2 probes")
    func probeState13SecondFailedProbeCollidingAgainPersistsMerged() async throws {
        let stub = RelaySetupHTTPStub()
        stub.failGeneration(status: 404)
        let provider = Self.editSaveProvider(stub)
        let state = Self.makeState(provider)
        let baseline = RelayEditView.Editor(from: provider)
        var draft = baseline
        draft.endpoint = stub.endpoint + "/v2"
        let syncedHeaders = [RelayKeyValue(key: "X-Synced", value: "1")]

        var probes = 0
        let outcome = try await Self.runEditSave(state, providerID: provider.id, draft: draft, baseline: baseline) { candidate in
            probes += 1
            if probes == 1 {
                try Self.sync(state, provider.id) { $0.relayRequested?.headers = syncedHeaders }
            } else {
                try Self.sync(state, provider.id) { $0.relayRequested?.customUserAgent = "SyncedUA/3" }
            }
            try await state.providerManager.verifyRelayGeneration(candidate)
        }

        #expect(probes == 2, "verify at most once more")
        #expect(Self.isPersisted(outcome), "the page closes as usual with no failure card")
        let stored = try #require(state.provider(for: provider.id))
        #expect(stored.baseURLText == stub.endpoint + "/v2")
        #expect(stored.relayRequested?.headers == syncedHeaders)
        #expect(stored.relayRequested?.customUserAgent == "SyncedUA/3")
        #expect(stored.status == Self.seededLiveStatus, "the verification status is not written")
    }

    @Test("RL2-PROBESTATE-11c 'Save anyway (unverified)': clearing / refreshing the catalog is decided at the moment of saving, by the merged values against the live record")
    func probeState11cUnverifiedSaveDecidesCatalogAtCommit() throws {
        let stub = RelaySetupHTTPStub()
        let provider = Self.editSaveProvider(stub)
        let baseline = RelayEditView.Editor(from: provider)
        var draft = baseline
        draft.endpoint = stub.endpoint + "/v2"

        // The store did not change while the failure card stayed: the address the user changed is a connection identity change -> clear the catalog and refetch.
        let changed = RelayEditSaveCommit.unverified(
            draft: draft, baseline: baseline, normalizedEndpoint: draft.endpoint, onto: provider
        )
        #expect(changed.refreshesCatalog)
        #expect(changed.provider.catalogModels.isEmpty)
        #expect(changed.provider.status == .issue(ProviderIssueMessage.unverifiedConnectionKey))

        // Sync has already changed the address to the same value while the failure card stayed: the merged values are unchanged relative to the live record -> neither clear nor fetch.
        var live = provider
        live.baseURLText = stub.endpoint + "/v2"
        let same = RelayEditSaveCommit.unverified(
            draft: draft, baseline: baseline, normalizedEndpoint: draft.endpoint, onto: live
        )
        #expect(!same.refreshesCatalog)
        #expect(same.provider.catalogModels.map(\.id) == ["bare-model"])
    }
}
