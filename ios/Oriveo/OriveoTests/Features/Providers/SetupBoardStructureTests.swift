import Foundation
import Testing
@testable import Oriveo

/// A fake local engine: replays the recorded raw text of `engine-declarations.v1.json` by path; the 1-token generation gets a minimal success.
private final class SetupBoardEngineProtocol: URLProtocol, @unchecked Sendable {
    struct Reply {
        let status: Int
        let contentType: String
        let body: Data
    }

    nonisolated(unsafe) static var routes: [String: Reply] = [:]
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
        if method == "POST", path.hasSuffix("/chat/completions") {
            reply = Reply(
                status: 200,
                contentType: "application/json",
                body: Data(#"{"id":"x","object":"chat.completion","choices":[{"index":0,"message":{"role":"assistant","content":"ok"},"finish_reason":"length"}]}"#.utf8)
            )
        }
        // The 1-token generation on the llama.cpp native channel.
        if method == "POST", path == "/completion" {
            reply = Reply(
                status: 200,
                contentType: "application/json",
                body: Data(#"{"content":"ok","stop":true}"#.utf8)
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

/// Structure snapshot of the two boards on the add page (contract cards BOARD-SETUP-01 to 07): asserts the text keys, slot order,
/// detection-card states and button states produced by the view model; the inputs for the ratio-bar grouping and the three local cells come from production functions / the production connector.
@Suite("Add page board structure · BOARD-SETUP", .serialized)
@MainActor
struct SetupBoardStructureTests {
    // MARK: - Fixtures

    private func sharedFixture(_ components: String...) throws -> Any {
        var cursor = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while cursor.path != "/" {
            var candidate = cursor.appendingPathComponent("shared").appendingPathComponent("test-fixtures")
            for component in components { candidate.appendPathComponent(component) }
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try JSONSerialization.jsonObject(with: Data(contentsOf: candidate))
            }
            cursor.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }

    private func recordedEngine(_ engine: String) throws -> [String: Any] {
        let root = try #require(try sharedFixture("local-engine", "engine-declarations.v1.json") as? [String: Any])
        let engines = try #require(root["engines"] as? [String: Any])
        return try #require(engines[engine] as? [String: Any])
    }

    private func install(engine: String, instance: String?, path: String?) throws {
        let recorded = try recordedEngine(engine)
        let records: [[String: Any]]
        if let instance {
            let instances = try #require(recorded["instances"] as? [String: Any])
            records = try #require((instances[instance] as? [String: Any])?["records"] as? [[String: Any]])
        } else {
            records = try #require(recorded["records"] as? [[String: Any]])
        }
        for record in records {
            let request = try #require(record["request"] as? [String: Any])
            let method = try #require(request["method"] as? String)
            let recordedPath = try #require(request["path"] as? String)
            if let path, path != recordedPath { continue }
            let response = try #require(record["response"] as? [String: Any])
            let body: Data = if let json = response["body"] {
                try JSONSerialization.data(withJSONObject: json)
            } else {
                Data((response["text"] as? String ?? "").utf8)
            }
            let reply = SetupBoardEngineProtocol.Reply(
                status: try #require(response["status"] as? Int),
                contentType: response["contentType"] as? String ?? "",
                body: body
            )
            if method == "POST", recordedPath == "/api/show",
               let model = (request["body"] as? [String: Any])?["model"] as? String {
                SetupBoardEngineProtocol.showReplies[model] = reply
            } else {
                SetupBoardEngineProtocol.routes["\(method) \(recordedPath)"] = reply
            }
        }
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SetupBoardEngineProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func connect(
        engine: String,
        instance: String? = nil,
        modelHint: String? = nil,
        session: URLSession
    ) async throws -> LocalEngineConnection {
        SetupBoardEngineProtocol.reset()
        try install(engine: engine, instance: instance, path: nil)
        return try await LocalEngineConnector.connect(
            engine: try #require(LocalEngineKind(rawValue: engine)),
            endpoint: try #require(try recordedEngine(engine)["endpoint"] as? String),
            securityMode: .localHTTP,
            modelHint: modelHint,
            session: session
        )
    }

    private func providersCatalog() throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Oriveo/Providers.xcstrings")
        let root = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        return try #require(root["strings"] as? [String: Any])
    }

    private func source(_ relativePath: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func expectKeysShipIn16Locales(_ keys: [String]) throws {
        let strings = try providersCatalog()
        for key in keys {
            let entry = try #require(strings[key] as? [String: Any], "Providers.xcstrings is missing \(key)")
            let localizations = try #require(entry["localizations"] as? [String: Any])
            #expect(localizations.count == 16, "\(key) has only \(localizations.count) languages")
        }
    }

    // MARK: - BOARD-SETUP-01

    @Test("BOARD-SETUP-01 relay step 1: three Hero buttons, slot order address -> key -> name -> add another, no default model, preview row")
    func board01RelayStructure() async throws {
        #expect(RelaySetupBoardModel.heroLabelKey == "Custom LLM · Custom Relay")
        #expect(RelaySetupBoardModel.heroTitleKey == "Connect a Custom Relay")
        #expect(RelaySetupBoardModel.heroSubtitleKey
            == "Enter the address and key, then choose models in the next step. Protocol and capabilities are checked per model.")
        // With only one key the name is not shown (a single key does not persist relayKeys, so a typed name would be lost); after a second key is added every key has a name.
        #expect(RelaySetupBoardModel.slots(keyCount: 1) == [.address, .apiKey, .addKey])
        #expect(RelaySetupBoardModel.slots(keyCount: 2) == [.address, .apiKey, .keyName, .addKey])
        #expect(RelaySetupBoardModel.secondaryActionKey == "Set up protocol manually")
        try expectKeysShipIn16Locales([
            RelaySetupBoardModel.heroLabelKey,
            RelaySetupBoardModel.heroTitleKey,
            RelaySetupBoardModel.heroSubtitleKey,
            RelaySetupBoardModel.willRequestKey,
            RelaySetupBoardModel.keyNameKey,
            RelaySetupBoardModel.addKeyKey,
            RelaySetupBoardModel.removeKeyKey,
            RelaySetupBoardModel.keysLocalKey,
            RelaySetupBoardModel.nextKey,
            RelaySetupBoardModel.stepOfKey,
            RelaySetupBoardModel.secondaryActionKey,
        ])

        // Preview row: the root address already obtained by detection takes priority, otherwise previewAPIRoot(input); with neither it is not shown.
        #expect(RelaySetupBoardModel.previewLine(detectedRoot: nil, input: "api.myrelay.dev") == "https://api.myrelay.dev/v1/…")
        #expect(RelaySetupBoardModel.previewLine(detectedRoot: nil, input: "https://api.myrelay.dev/v1/chat/completions")
            == "https://api.myrelay.dev/v1/…")
        #expect(RelaySetupBoardModel.previewLine(detectedRoot: "https://api.myrelay.dev/openai/v1", input: "api.myrelay.dev")
            == "https://api.myrelay.dev/openai/v1/…")
        #expect(RelaySetupBoardModel.previewLine(detectedRoot: nil, input: "") == nil)
        #expect(RelaySetupBoardModel.previewLine(detectedRoot: nil, input: "https://api.myrelay.dev/v1?key=1") == nil)

        // Production flow: after detection the preview row switches to the root address measured by the discovery service.
        let stub = RelaySetupHTTPStub()
        stub.catalog(secret: "sk-main", modelIDs: ["gpt-6"])
        let state = AppState(seedDemoData: false, sessionUID: "rd2-\(UUID().uuidString)", providerSession: RelaySetupHTTPStub.session())
        let flow = RelayQuickSetupFlow.stubbed(stub)
        flow.setEndpoint(stub.host)
        #expect(flow.previewLine == "https://\(stub.host)/v1/…")
        flow.setSecret("sk-main", for: RelayKeyBinding.implicitKeyID)
        await flow.next(appState: state)?.value
        #expect(flow.previewLine == "https://\(stub.host)/v1/…")
        #expect(flow.detectedRoot == "https://\(stub.host)/v1")

        // Each key = key + optional name, removable; the primary key cannot be removed. Names appear only with 2 or more keys.
        #expect(!flow.showsKeyNames)
        let extra = flow.addKey()
        #expect(flow.showsKeyNames)
        #expect(flow.keys.map(\.id) == [RelayKeyBinding.implicitKeyID, extra])
        flow.removeKey(extra)
        flow.removeKey(RelayKeyBinding.implicitKeyID)
        #expect(flow.keys.map(\.id) == [RelayKeyBinding.implicitKeyID])
        #expect(!flow.showsKeyNames)

        let setup = try source("Oriveo/Features/Providers/RelaySetupView.swift")
        let stepOne = try source("Oriveo/Features/Providers/RelaySetupStepViews.swift")
        #expect(setup.contains("SetupBoardHero("))
        #expect(setup.contains("RelaySetupBoardModel.heroTitleKey"))
        #expect(setup.contains("RelaySetupBoardModel.secondaryActionKey"))
        #expect(stepOne.contains("RelaySetupBoardModel.willRequestKey"))
        #expect(stepOne.contains("RelaySetupBoardModel.keysLocalKey"))
        #expect(stepOne.contains("showsKeyNames: flow.showsKeyNames"))
        #expect(stepOne.contains("if showsKeyNames"))
        // When step 1 fails, below the one-sentence message keep "what was tried" and the upstream's own words (existing text is reused).
        #expect(stepOne.contains("L10n.tr(\"What Oriveo tried\", table: .providers)"))
        // The quick path no longer has a default model slot.
        #expect(!setup.contains("discoveredModelIDs:"))
        #expect(!setup.contains("RelayDiscoveredModelField("))
        #expect(!stepOne.contains("Default Model"))
        let components = try source("Oriveo/Features/Providers/SetupBoardComponents.swift")
        #expect(components.contains(".accessibilityAddTraits(.isHeader)"))
        // The page title is only the Hero title, and the topBar keeps only back.
        #expect(!setup.contains("setupCoordinator.method == .local ? \"Local compute\" : \"Custom Relay\""))
    }

    // MARK: - BOARD-SETUP-02

    @Test("BOARD-SETUP-02 detection card has three items (connectivity / fetch catalog one row per key / identify protocol) + n / 3 + cancellable while running, and step 1 sends zero chat requests")
    func board02RelayDetectionCard() async throws {
        #expect(RelaySetupBoardModel.make(.init()).card == nil)
        #expect(RelaySetupBoardModel.detectionTitleKey == "Detection")
        #expect(RelaySetupBoardModel.cancelDetectionKey == "Cancel detection")
        try expectKeysShipIn16Locales([
            RelaySetupBoardModel.detectionTitleKey,
            RelaySetupBoardModel.detectionSubtitleKey,
            RelaySetupBoardModel.detectionNoteKey,
            RelaySetupBoardModel.cancelDetectionKey,
            RelaySetupBoardModel.connectionCheckKey,
            RelaySetupBoardModel.catalogCheckKey,
            RelaySetupBoardModel.protocolsCheckKey,
            RelaySetupBoardModel.reachableKey,
            RelaySetupBoardModel.catalogCountKey,
            RelaySetupBoardModel.protocolsRunningKey,
            RelaySetupBoardModel.protocolsDoneKey,
            RelaySetupBoardModel.skippedKey,
        ])
        #expect(RelaySetupBoardModel.connectionCheckKey == "relay_setup_check_connection")

        // Running: item 1 is running -> 0 / 3, cancel is shown, and the primary button is disabled.
        var running = RelaySetupDetection(keys: [.init(id: RelayKeyBinding.implicitKeyID, label: "sk-…")])
        running.connection.status = .running
        running.connection.startedAt = Date(timeIntervalSince1970: 0)
        let runningBoard = RelaySetupBoardModel.make(.init(detection: running, canAct: true))
        let runningCard = try #require(runningBoard.card)
        #expect(runningCard.completedCount == 0)
        #expect(runningCard.totalCount == 3)
        #expect(runningCard.showsCancel)
        #expect(!runningBoard.isPrimaryEnabled)
        #expect(abs((running.connection.elapsed(now: Date(timeIntervalSince1970: 0.44)) ?? 0) - 0.44) < 0.001)
        // Elapsed time with one decimal place, in the language's number format (the same output path as MCP step durations).
        #expect(RelaySetupBoardModel.elapsedText(seconds: 0.44) == McpStepDetailSheet.durationText(milliseconds: 440))

        // Production flow: two keys, the second returns 401.
        let stub = RelaySetupHTTPStub()
        stub.catalog(secret: "sk-main", modelIDs: ["gpt-6", "claude-sonnet-4-5", "deepseek-chat"])
        stub.catalog(secret: "sk-bad", status: 401)
        let state = AppState(seedDemoData: false, sessionUID: "rd2-\(UUID().uuidString)", providerSession: RelaySetupHTTPStub.session())
        let flow = RelayQuickSetupFlow.stubbed(stub)
        flow.setEndpoint(stub.endpoint)
        flow.setSecret("sk-main", for: RelayKeyBinding.implicitKeyID)
        let bad = flow.addKey()
        flow.setSecret("sk-bad", for: bad)
        flow.setName("Backup", for: bad)
        await flow.next(appState: state)?.value

        let detection = try #require(flow.detection)
        #expect(detection.connection.status == .done)
        #expect(detection.reachablePath == "/v1/models")
        #expect(detection.catalog.status == .done)
        #expect(detection.protocols.status == .done)
        #expect(detection.keyCatalogs.map(\.keyID) == [RelayKeyBinding.implicitKeyID, bad])
        #expect(detection.keyCatalogs[0].modelCount == 3)
        #expect(detection.keyCatalogs[0].status == .done)
        #expect(detection.keyCatalogs[1].label == "Backup")
        #expect(detection.keyCatalogs[1].status == .failed)
        #expect(detection.keyCatalogs[1].failure == .invalidKey)
        for check in [detection.connection, detection.catalog, detection.protocols] {
            #expect(check.elapsed(now: Date()) != nil)
        }
        // The relay detection card is a container: the "What Oriveo tried" collapsible list under a failed item is separately operable by VoiceOver; the local card shell is still merged by default.
        let stepViews = try source("Oriveo/Features/Providers/RelaySetupStepViews.swift")
        #expect(stepViews.contains("accessibilityChildren: .contain"))
        #expect(!stepViews.contains(".accessibilityElement(children: .combine)"))
        let components = try source("Oriveo/Features/Providers/SetupBoardComponents.swift")
        #expect(components.contains("var accessibilityChildren: AccessibilityChildBehavior = .combine"))
        let card = try #require(flow.connectionBoard(canAct: true).card)
        #expect(card.completedCount == 3)
        #expect(!card.showsCancel)
        // Protocol identification ranks candidates locally: zero chat requests.
        #expect(stub.generationModels.isEmpty)
        #expect(flow.protocols["claude-sonnet-4-5"] == .openaiChatCompletions)

        // Cancel: the card disappears and it can be re-detected.
        flow.cancelDetection()
        #expect(flow.detection == nil)
        #expect(flow.connectionBoard(canAct: true).nextAction == .detect)
    }

    // MARK: - BOARD-SETUP-03

    @Test("BOARD-SETUP-03 the primary button is always Next: not yet detected -> detect; not tappable while detecting; success auto-enters step 2; failure stays with one sentence, and tapping again enters manual add")
    func board03RelayPrimaryButton() async throws {
        let idle = RelaySetupBoardModel.make(.init(canAct: true))
        #expect(idle.primaryTitleKey == "Next")
        #expect(idle.nextAction == .detect)
        #expect(idle.isPrimaryEnabled)
        #expect(!RelaySetupBoardModel.make(.init(canAct: false)).isPrimaryEnabled)

        // Four kinds of one-sentence messages + other cases reuse the existing reasons.
        #expect(RelaySetupFailure.address.textKey == "The address may point to a web page. Check whether /v1 is missing.")
        #expect(RelaySetupFailure.invalidKey.textKey == "The key is invalid.")
        #expect(RelaySetupFailure.cannotListModels.textKey == "This key can’t list models. You can add models manually.")
        #expect(RelaySetupFailure.cannotConnect.textKey == "Can’t connect. Check your network or proxy.")
        #expect(RelaySetupFailure.classify(discoveryFailure: .routeUnavailable, statusCodes: [404]) == .address)
        #expect(RelaySetupFailure.classify(discoveryFailure: .invalidResponse, statusCodes: [200]) == .address)
        #expect(RelaySetupFailure.classify(discoveryFailure: .authenticationRejected, statusCodes: [401]) == .invalidKey)
        #expect(RelaySetupFailure.classify(discoveryFailure: .authenticationRejected, statusCodes: [403]) == .cannotListModels)
        #expect(RelaySetupFailure.classify(discoveryFailure: .network, statusCodes: []) == .cannotConnect)
        #expect(RelaySetupFailure.classify(discoveryFailure: .temporaryFailure, statusCodes: [503]) == .cannotConnect)
        #expect(RelaySetupFailure.classify(discoveryFailure: .rateLimited, statusCodes: [429])
            == .other(textKey: "The service at this address is rate limiting requests. Wait a moment and try again; Oriveo didn't switch to another key or protocol."))

        // Success: auto-enters step 2; when returning to step 1, Next goes directly to step 2.
        let stub = RelaySetupHTTPStub()
        stub.catalog(secret: "sk-main", modelIDs: ["gpt-6"])
        stub.catalog(secret: "sk-403", status: 403)
        let state = AppState(seedDemoData: false, sessionUID: "rd2-\(UUID().uuidString)", providerSession: RelaySetupHTTPStub.session())
        let flow = RelayQuickSetupFlow.stubbed(stub)
        flow.setEndpoint(stub.endpoint)
        flow.setSecret("sk-main", for: RelayKeyBinding.implicitKeyID)
        let detecting = flow.next(appState: state)
        #expect(flow.connectionBoard(canAct: true).nextAction == .wait)
        #expect(!flow.connectionBoard(canAct: true).isPrimaryEnabled)
        await detecting?.value
        #expect(flow.step == .models)
        flow.backToConnection()
        #expect(flow.connectionBoard(canAct: true).nextAction == .models(manualAdd: false))

        // Changing the key voids this round: the card disappears and Next goes back to detect.
        flow.setSecret("sk-403", for: RelayKeyBinding.implicitKeyID)
        #expect(flow.detection == nil)
        #expect(flow.connectionBoard(canAct: true).nextAction == .detect)

        // 403: stay on step 1, the connectivity item gives the "no permission to list models" sentence; tapping Next again enters the manual-add state.
        await flow.next(appState: state)?.value
        #expect(flow.step == .connection)
        #expect(flow.detection?.connection.status == .failed)
        #expect(flow.detection?.catalog.status == .skipped)
        #expect(flow.detection?.protocols.status == .skipped)
        #expect(flow.detection?.failure == .cannotListModels)
        #expect(flow.detection?.attemptLines.contains("GET /v1/models → 403") == true)
        #expect(flow.detection?.upstreamMessage?.isEmpty == false)
        #expect(flow.connectionBoard(canAct: true).nextAction == .models(manualAdd: true))
        await flow.next(appState: state)?.value
        #expect(flow.step == .models)
        #expect(flow.modelsBoard.showsEmptyNote)
        #expect(stub.generationModels.isEmpty)
    }

    // MARK: - BOARD-SETUP-04

    @Test("BOARD-SETUP-04 local structure: three Hero buttons, two slots (no default model), LAN row, secondary row key")
    func board04LocalStructure() throws {
        #expect(LocalSetupBoardModel.heroLabelKey == "Custom LLM · Local & LAN")
        #expect(LocalSetupBoardModel.heroTitleKey == "Connect a local or LAN engine")
        #expect(LocalSetupBoardModel.heroSubtitleKey == "Just the address. Engine, channel and models are detected for you.")
        #expect(LocalSetupBoardModel.slots == [.address, .apiKey])
        #expect(LocalSetupBoardModel.secondaryActionKey == "Choose engine and channel manually")
        #expect(LocalSetupBoardModel.networkRowTitleKey == "Found on your network")
        try expectKeysShipIn16Locales([
            LocalSetupBoardModel.heroLabelKey,
            LocalSetupBoardModel.heroTitleKey,
            LocalSetupBoardModel.heroSubtitleKey,
            LocalSetupBoardModel.networkRowTitleKey,
            LocalSetupBoardModel.recognizedKey,
            LocalSetupBoardModel.unrecognizedTitleKey,
            LocalSetupBoardModel.unrecognizedBodyKey,
            LocalSetupBoardModel.channelTileKey,
            LocalSetupBoardModel.contextTileKey,
            LocalSetupBoardModel.thinkingTileKey,
            LocalSetupBoardModel.contextUnavailableKey,
            LocalSetupBoardModel.secondaryActionKey,
            "Chat template", "Set by the model", "Not supported",
        ])

        // Without results the LAN row is not shown; with results, chips follow discovery order.
        #expect(LocalSetupBoardModel.make(.init()).networkChips.isEmpty)
        #expect(LocalSetupBoardModel.make(.init(discoveredAddresses: ["http://192.168.1.20:8080"])).networkChips
            == ["http://192.168.1.20:8080"])
        // The llama.cpp channel picker appears only when manually expanded.
        #expect(LocalSetupBoardModel.make(.init(engine: .llamacpp, showsManualPicker: true)).showsChannelPicker)
        #expect(!LocalSetupBoardModel.make(.init(engine: .ollama, showsManualPicker: true)).showsChannelPicker)
        #expect(!LocalSetupBoardModel.make(.init(engine: .llamacpp)).showsChannelPicker)

        let local = try source("Oriveo/Features/Providers/LocalComputeSetupView.swift")
        // The default model slot and picker are removed; sample = the connector takes the first catalog item (the model hint is always empty).
        #expect(!local.contains("local_compute_model_option"))
        #expect(!local.contains("Model (optional)"))
        #expect(!local.contains("SetupDefaultModelBadge("))
        #expect(local.contains("modelHint: nil"))
        #expect(local.contains("LocalSetupBoardModel.heroTitleKey"))
        #expect(local.contains("LocalSetupBoardModel.secondaryActionKey"))
        #expect(local.contains("SetupNetworkChipRow(addresses: board.networkChips)"))
        let components = try source("Oriveo/Features/Providers/SetupBoardComponents.swift")
        #expect(components.contains("LocalSetupBoardModel.networkRowTitleKey"))
        #expect(local.contains("board.primaryButton.titleKey"))
        let model = try source("Oriveo/Features/Providers/SetupBoardModel.swift")
        #expect(!model.contains("defaultModelChannel"))
        #expect(!model.contains("hasModelPicker"))
    }
    // MARK: - BOARD-SETUP-05

    @Test("BOARD-SETUP-05 local detection card has three states: the three cells come from the production connector, with three thinking values")
    func board05LocalDetectionCard() async throws {
        #expect(LocalSetupBoardModel.make(.init()).card == .hidden)
        #expect(LocalSetupBoardModel.make(.init(isDetecting: true)).card == .detecting)
        let connectionFailure = LocalSetupBoardModel.make(.init(failure: .connection))
        #expect(connectionFailure.card == .failed)
        #expect(!connectionFailure.showsManualPicker)

        let session = makeSession()

        // llama.cpp Chat: writable -> follows the chat template; context takes n_ctx from /props.
        let llama = LocalSetupBoardModel.Summary.make(try await connect(engine: "llamacpp", instance: "text_only", session: session))
        #expect(llama.engine == .llamacpp)
        #expect(llama.channel == .openaiChatCompletions)
        #expect(llama.contextLength == 2048)
        #expect(llama.thinking == .chatTemplate)
        #expect(llama.thinking.valueKey == "Chat template")
        #expect(LocalSetupBoardModel.contextValue(llama.contextLength).text == "2K")

        // LM Studio: not writable -> decided by the model; context takes max_context_length from the default model row.
        let lmConnection = try await connect(engine: "lmstudio", session: session)
        let lm = LocalSetupBoardModel.Summary.make(lmConnection)
        #expect(lm.thinking == .setByModel)
        #expect(lm.thinking.valueKey == "Set by the model")
        #expect(lm.contextLength == 8192)
        #expect(lm.modelCount == lmConnection.modelIDs.count)

        // Ollama declares this model has no thinking -> unsupported; context cannot be measured -> unavailable, not 0.
        let ollama = LocalSetupBoardModel.Summary.make(try await connect(engine: "ollama", modelHint: "tinyllama:latest", session: session))
        #expect(ollama.thinking == .unsupported)
        #expect(ollama.thinking.valueKey == "Not supported")
        #expect(ollama.contextLength == nil)
        #expect(LocalSetupBoardModel.contextValue(ollama.contextLength).key == "Not available")
        #expect(LocalSetupBoardModel.contextValue(0).key == "Not available")

        let succeeded = LocalSetupBoardModel.make(.init(summary: llama, engine: .llamacpp, canAct: true))
        #expect(succeeded.card == .succeeded)
        #expect(succeeded.summary == llama)

        // llama.cpp native channel (manually selected): the channel is reported as is, and thinking is not writable.
        SetupBoardEngineProtocol.reset()
        try install(engine: "llamacpp", instance: "text_only", path: nil)
        let nativeRequested = try await LocalEngineConnector.connect(
            engine: .llamacpp,
            endpoint: "http://127.0.0.1:8080",
            securityMode: .localHTTP,
            channel: .llamacppNative,
            session: session
        ).requested
        #expect(nativeRequested.transport == .llamacppNative)
        #expect(SetupBoardEngineProtocol.requested.contains("POST /completion"))
    }

    // MARK: - BOARD-SETUP-06

    @Test("BOARD-SETUP-06 local fingerprint drives the engine: engine -> use that engine's connection; generic / manual -> expand manual selection")
    func board06FingerprintDrivesEngine() async throws {
        let expectations = try #require(try sharedFixture("local-engine", "engine-expectations.v1.json") as? [String: Any])
        let fingerprint = try #require(expectations["fingerprint"] as? [String: Any])
        let cases = try #require(fingerprint["cases"] as? [[String: Any]])
        let session = makeSession()
        var exercised = 0

        for item in cases where item["status"] as? String != "pending" {
            let caseId = item["caseId"] as? String ?? "<no id>"
            SetupBoardEngineProtocol.reset()
            SetupBoardEngineProtocol.unreachable = item["unreachable"] as? Bool == true
            for response in try #require(item["responses"] as? [[String: Any]]) {
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
            let route = LocalSetupDetectRoute.route(for: outcome)
            let expect = try #require(item["expect"] as? [String: Any])
            switch try #require(expect["outcome"] as? String) {
            case "engine":
                let profile = try #require(expect["engineProfile"] as? String)
                let engine = try #require(LocalEngineKind(rawValue: profile))
                #expect(route == .connect(engine, channel: .openaiChatCompletions), "\(caseId)")
            default:
                #expect(route == .unrecognized, "\(caseId)")
                let board = LocalSetupBoardModel.make(.init(failure: .unrecognized, canAct: true))
                #expect(board.card == .failed, "\(caseId)")
                #expect(board.failure == .unrecognized, "\(caseId)")
                #expect(board.showsManualPicker, "\(caseId)")
                #expect(board.primaryButton == .detect, "\(caseId)")
            }
            exercised += 1
        }
        #expect(exercised >= 8)
        #expect(LocalSetupBoardModel.unrecognizedTitleKey == "Couldn't recognize this engine")
        #expect(LocalSetupBoardModel.unrecognizedBodyKey == "Choose the engine and channel below.")
        // The user has expanded manual selection and chosen an engine: skip the fingerprint.
        #expect(LocalSetupDetectRoute.skipsFingerprint(showsManualPicker: true))
        #expect(!LocalSetupDetectRoute.skipsFingerprint(showsManualPicker: false))

        let local = try source("Oriveo/Features/Providers/LocalComputeSetupView.swift")
        #expect(local.contains("LocalEngineConnector.fingerprint("))
        #expect(local.contains("LocalSetupDetectRoute.route(for:"))
    }

    // MARK: - BOARD-SETUP-07

    @Test("BOARD-SETUP-07 local button has three states, and loading while detecting is not tappable")
    func board07LocalPrimaryButton() throws {
        let idle = LocalSetupBoardModel.make(.init(canAct: true))
        #expect(idle.primaryButton.titleKey == "Detect connection settings")
        #expect(idle.isPrimaryEnabled)

        let detecting = LocalSetupBoardModel.make(.init(isDetecting: true, canAct: true))
        #expect(detecting.primaryButton.titleKey == "Detecting...")
        #expect(!detecting.isPrimaryEnabled)

        let summary = LocalSetupBoardModel.Summary(
            engine: .ollama, modelCount: 2, channel: .openaiChatCompletions, contextLength: nil, thinking: .setByModel
        )
        #expect(LocalSetupBoardModel.make(.init(summary: summary, canAct: true)).primaryButton.titleKey == "Connect and save")
        #expect(LocalSetupBoardModel.make(.init(failure: .unrecognized, canAct: true)).primaryButton.titleKey
            == "Detect connection settings")
    }

    @Test("BOARD-SETUP-08 the loading indicator in the add page's action bar primary button is white: the system default dark gray is hard to see on the primary-color gradient")
    func saveBarSpinnersAreTintedWhite() throws {
        let setup = try source("Oriveo/Features/Providers/RelaySetupView.swift")
        let spinners = setup.components(separatedBy: "\n").filter { $0.contains("ProgressView()") }
        #expect(spinners.count == 2)
        for line in spinners {
            #expect(line.contains(".tint(.white)"), "\(line)")
        }
    }
}
