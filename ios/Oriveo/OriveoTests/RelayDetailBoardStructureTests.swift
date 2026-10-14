import Foundation
import Testing
@testable import Oriveo

/// A fake relay: GET …/models answers with a catalog, everything else is 404; every request is recorded.
private final class RelayDetailFakeServer: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var catalog = Data()
    nonisolated(unsafe) private static var requests: [URLRequest] = []

    static func install(catalogIDs: [String]) {
        let body = try? JSONSerialization.data(withJSONObject: [
            "object": "list",
            "data": catalogIDs.map { ["id": $0, "object": "model"] },
        ])
        lock.withLock {
            catalog = body ?? Data()
            requests = []
        }
    }

    static func catalogRequestCount() -> Int {
        lock.withLock { requests.filter { $0.httpMethod == "GET" && $0.url?.path.hasSuffix("/models") == true }.count }
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RelayDetailFakeServer.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let (code, data): (Int, Data) = Self.lock.withLock {
            Self.requests.append(request)
            if request.httpMethod == "GET", request.url?.path.hasSuffix("/models") == true {
                return (200, Self.catalog)
            }
            return (404, Data())
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: code,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Detail-page board (the behaviors of the detail page): asserts the row order, keys and button states that the board model produces.
@Suite("Relay 2.0 · Detail page board structure", .serialized)
@MainActor
struct RelayDetailBoardStructureTests {
    typealias Board = RelayDetailBoardModel

    // MARK: - Construction

    private static func model(_ id: String, isDefault: Bool = false) -> AIModel {
        TestFactories.makeModel(id: id, capabilities: [.text], isDefault: isDefault)
    }

    private static func relayProvider(
        transport: RelayTransport = .openaiChatCompletions,
        roots: [String: String]? = nil,
        legacyRoot: String? = nil,
        apiKey: String = "sk-test-7f2a",
        apiKeyPreview: String = "sk-…7f2a",
        authMode: RelayAuthMode = .bearer
    ) -> Provider {
        let enabled = [model("claude-sonnet-4.5", isDefault: true), model("gpt-4o-mini")]
        let catalog = enabled + (0..<40).map { model("catalog-\($0)") }
        var provider = TestFactories.makeProvider(
            kind: .relay,
            models: enabled,
            catalogModels: catalog,
            lastCheckedAt: nil,
            apiKey: apiKey,
            apiKeyPreview: apiKeyPreview,
            baseURLText: "https://api.myrelay.dev"
        )
        provider.relayRequested = RelayRequestedConfig(
            transport: transport,
            authMode: authMode,
            resolvedAPIBaseURL: legacyRoot,
            resolvedAPIBaseURLs: roots
        )
        return provider
    }

    private static func localProvider(
        engine: String,
        transport: RelayTransport = .openaiChatCompletions,
        declaredThinking: Bool? = nil
    ) -> Provider {
        var defaultModel = model("qwen3-8b-q4", isDefault: true)
        if let declaredThinking {
            defaultModel.engineDeclaration = EngineDeclaration(thinking: declaredThinking)
        }
        let catalog = [defaultModel, model("llama-3.2-3b"), model("gemma-2-2b")]
        var provider = TestFactories.makeProvider(
            kind: .relay,
            models: [defaultModel],
            catalogModels: catalog,
            apiKey: "",
            apiKeyPreview: "",
            baseURLText: "http://192.168.1.20:8080"
        )
        provider.relayRequested = RelayRequestedConfig(
            transport: transport,
            authMode: .none,
            securityMode: .localHTTP,
            engineProfile: engine
        )
        return provider
    }

    private static func expectations() throws -> [String: Any] {
        var cursor = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while cursor.path != "/" {
            let candidate = cursor
                .appendingPathComponent("shared")
                .appendingPathComponent("test-fixtures")
                .appendingPathComponent("local-engine")
                .appendingPathComponent("engine-expectations.v1.json")
            if FileManager.default.fileExists(atPath: candidate.path) {
                let object = try JSONSerialization.jsonObject(with: Data(contentsOf: candidate))
                return try #require(object as? [String: Any])
            }
            cursor.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }

    // MARK: - BOARD-DETAIL-01

    @Test("Detail row icons are colored per row")
    func detailRowIconTints() throws {
        let expected: [(Board.RowID, Board.RowIconTint?)] = [
            (.modelLibrary, .teal),
            (.requestURL, .cyan), (.engineAddress, .cyan),
            (.defaultProtocol, .indigo), (.channel, .indigo),
            (.apiKey, .orange),
            (.engine, .rose), (.parameters, .rose),
            // Web search / reasoning reuse the capability colors; no new ones are invented.
            (.webSearch, .capabilityWebSearch), (.thinking, .capabilityReasoning),
            // The root-address row draws no icon.
            (.basePaths, nil),
        ]
        for (id, tint) in expected {
            #expect(Board.iconTint(for: id) == tint, "\(id.rawValue)")
        }

        // Every row on the real board can get a color (except the root-address row); go through both the relay and the local form.
        let relay = try #require(Board.make(Self.relayProvider(roots: [
            "openai_chat_completions": "https://api.myrelay.dev/v1",
        ])))
        let local = try #require(Board.make(Self.localProvider(engine: "ollama")))
        for row in relay.connectionRows + relay.modelRows + local.connectionRows + local.modelRows {
            #expect((Board.iconTint(for: row.id) == nil) == (row.id == .basePaths), "\(row.id.rawValue)")
        }
    }

    @Test("BOARD-DETAIL-01 Relay connection card and models card row order + bottom button keys (with and without the root-address row)")
    func boardDetail01RelayRows() throws {
        let provider = Self.relayProvider(roots: [
            "anthropic_messages": "https://api.myrelay.dev/v1",
            "openai_chat_completions": "https://api.myrelay.dev/v1",
            "not_a_protocol_yet": "https://api.myrelay.dev/x",
        ], legacyRoot: nil)
        let board = try #require(Board.make(provider))

        #expect(board.form == .relay)
        #expect(board.connectionRows.map(\.id) == [.requestURL, .apiKey, .defaultProtocol, .basePaths])
        #expect(board.connectionRows.map(\.titleKey) == [
            "Request URL", "API Key", "Default protocol · used by models without their own", "Base paths",
        ])
        #expect(board.connectionRows.map(\.icon) == [.link, .key, .hardDrives, .hardDrives])
        let url = board.connectionRows[0]
        #expect(url.value == .verbatim("https://api.myrelay.dev"))
        #expect(url.destination == .editConnection)
        let key = board.connectionRows[1]
        #expect(key.value == .verbatim("sk-…7f2a"))
        #expect(key.trailingKey == Board.addMoreKeysKey)
        #expect(key.destination == .apiKeys)
        let protocolRow = board.connectionRows[2]
        #expect(protocolRow.value == .transport(.openaiChatCompletions))
        #expect(protocolRow.destination == .editConnection)
        #expect(board.connectionRows[3].basePaths == [
            .init(transport: .openaiChatCompletions, name: "Chat", path: "/v1"),
            .init(transport: .anthropicMessages, name: "Messages", path: "/v1"),
        ])
        #expect(board.connectionRows[3].destination == nil)

        // A relay has no default model: the detail page no longer has a default-model row; below the model library is the Web search row, and the last row is Parameters.
        #expect(board.modelRows.map(\.id) == [.modelLibrary, .webSearch, .parameters])
        #expect(board.modelRows.map(\.titleKey) == ["Model Library", "Web Search", "Parameters"])
        #expect(board.modelRows[0].value == .counts("%lld enabled · %lld more to add", 2, 40))
        #expect(board.modelRows[0].destination == .modelLibrary)

        // The model count on the status row = the number of distinct ids across enabled ∪ catalog (2 enabled + 40 addable).
        #expect(board.modelCount == 42)
        #expect(board.checkedAt == nil)
        #expect(board.deleteKey == "Delete Custom Relay")
        #expect(Board.detectButton(isRunning: false) == .init(titleKey: "Detect again", isEnabled: true))
        // This connection has Chat Completions chosen: the footnote does not say that every model's protocol will be refreshed (BOARD-DETAIL-13 covers the two states).
        #expect(board.footnoteKey == Board.footnoteFixedKey)

        // A legacy single-value root address goes to the connection's default protocol; with none at all the whole row is not shown.
        let legacyOnly = try #require(Board.make(Self.relayProvider(
            transport: .anthropicMessages,
            legacyRoot: "https://api.myrelay.dev/anthropic/v1"
        )))
        #expect(legacyOnly.connectionRows.last?.basePaths == [
            .init(transport: .anthropicMessages, name: "Messages", path: "/anthropic/v1"),
        ])
        let none = try #require(Board.make(Self.relayProvider()))
        #expect(none.connectionRows.map(\.id) == [.requestURL, .apiKey, .defaultProtocol])

        // Official providers don't use the board.
        #expect(Board.make(TestFactories.makeProvider(kind: .openAI)) == nil)
    }

    // MARK: - BOARD-DETAIL-02

    @Test("BOARD-DETAIL-02 Local connection card and models card row order + Delete connection")
    func boardDetail02LocalRows() throws {
        let board = try #require(Board.make(Self.localProvider(engine: "llamacpp")))

        #expect(board.form == .local)
        #expect(board.connectionRows.map(\.id) == [.engineAddress, .engine, .channel, .apiKey])
        #expect(board.connectionRows.map(\.titleKey) == [
            "Engine address", "Engine · detected", "Channel · same role as protocol", "API Key",
        ])
        #expect(board.connectionRows.map(\.icon) == [.link, .plug, .hardDrives, .key])
        #expect(board.connectionRows[0].value == .verbatim("http://192.168.1.20:8080"))
        #expect(board.connectionRows[1].value == .verbatim("llama.cpp"))
        #expect(board.connectionRows[1].destination == nil)
        #expect(board.connectionRows[2].value == .transport(.openaiChatCompletions))
        #expect(board.connectionRows[2].destination == .editConnection)
        let key = board.connectionRows[3]
        #expect(key.value == .key("No key needed"))
        #expect(key.trailingKey == nil)
        // S0 (no credentials needed and no key stored): shows "No key needed" and is not tappable — adding a key goes through the authentication mode in Edit connection.
        #expect(key.destination == nil)
        // Tappable ⇔ credentials are required or a key is stored (final on all three platforms): with no authentication but a stored key it is tappable and opens the keys page (replacing a key is still the existing change-key dialog, which includes remove / replace).
        var residual = Self.localProvider(engine: "llamacpp")
        residual.apiKey = "sk-left-over"
        residual.apiKeyPreview = "sk-…over"
        let residualKey = try #require(Board.make(residual)?.connectionRows.first { $0.id == .apiKey })
        #expect(residualKey.value == .verbatim("sk-…over"))
        #expect(residualKey.destination == .apiKeys)
        // A plaintext connection with a key (S3) is tappable likewise.
        var conflict = Self.relayProvider()
        conflict.relayRequested?.securityMode = .localHTTP
        #expect(try #require(Board.make(conflict)?.connectionRows.first { $0.id == .apiKey }).destination == .apiKeys)
        // Credentials required but no key stored (S1): keep the existing "Tap to set", tappable, and do not write "No key needed".
        let missing = try #require(Board.make(Self.relayProvider(apiKey: "", apiKeyPreview: ""))?.connectionRows.first { $0.id == .apiKey })
        #expect(missing.value == .key("Tap to set"))
        #expect(missing.trailingKey == nil)
        #expect(missing.destination == .apiKeys)

        #expect(board.modelRows.map(\.id) == [.modelLibrary, .thinking, .parameters])
        #expect(board.modelRows.map(\.titleKey) == ["Model Library", "Thinking", "Parameters"])
        #expect(board.modelRows.map(\.icon) == [.database, .brain, .thermometerSimple])
        #expect(board.modelRows[0].value == .counts("%lld enabled · %lld more on the engine", 1, 2))
        #expect(board.modelRows[1].trailingKey == "Read-only")
        #expect(board.modelRows[1].destination == nil)
        #expect(board.deleteKey == "Delete connection")

        // Only llama.cpp has a second channel to choose; the channel rows of the other engines have no chevron.
        let ollama = try #require(Board.make(Self.localProvider(engine: "ollama")))
        #expect(ollama.connectionRows[1].value == .verbatim("Ollama"))
        #expect(ollama.connectionRows[2].destination == nil)
    }

    // MARK: - BOARD-DETAIL-03

    @Test("BOARD-DETAIL-03 Three copy variants of the local reasoning row (engine-expectations write-path table; an unsupported placeholder falls back to the fallback model name)")
    func boardDetail03LocalThinking() throws {
        let fixture = try Self.expectations()
        let channels = try #require(fixture["channels"] as? [String: Any])
        let thinking = try #require(fixture["thinking"] as? [String: Any])
        let cases = try #require(thinking["cases"] as? [[String: Any]])
        let expectedKey: [String: String] = [
            "toggle": "Follows the chat template. Set it in Model Options in chat.",
            "unsupported": "The engine reports %@ doesn’t support thinking.",
            "usesModelDefaultNotice": "This engine’s current channel can’t adjust thinking. The model decides.",
            "nonChatNotice": "This engine’s current channel can’t adjust thinking. The model decides.",
        ]
        var seen = Set<String>()
        for item in cases {
            let caseId = item["caseId"] as? String ?? "<no id>"
            guard let engine = item["engineProfile"] as? String else { continue }
            let channel = try #require(item["channel"] as? String)
            let wire = try #require(channels[channel] as? String)
            let transport = try #require(RelayTransport(rawValue: wire))
            let board = try #require(Board.make(Self.localProvider(
                engine: engine,
                transport: transport,
                declaredThinking: item["declaredThinking"] as? Bool
            )), "\(caseId)")
            let row = try #require(board.modelRows.first { $0.id == .thinking }, "\(caseId)")
            let expect = try #require(item["expect"] as? String)
            let key = try #require(expectedKey[expect], "\(caseId) has an unmapped expectation \(expect)")
            // The display name of the model that an unsupported placeholder falls back to (lastUsed → the first enabled).
            let expected: Board.Text = expect == "unsupported" ? .format(key, "qwen3-8b-q4") : .key(key)
            #expect(row.value == expected, "\(caseId)")
            #expect(row.trailingKey == "Read-only", "\(caseId)")
            seen.insert(key)
        }
        #expect(seen.count == 3, "the fixtures should cover all three copy variants")
        // A relay has no reasoning row.
        #expect(try #require(Board.make(Self.relayProvider())).modelRows.contains { $0.id == .thinking } == false)
    }

    @Test("BOARD-DETAIL-03 The unsupported placeholder follows the fallback model: lastUsed first, then the first enabled")
    func boardDetail03UnsupportedNamesFallbackModel() throws {
        var provider = Self.localProvider(engine: "ollama", declaredThinking: false)
        var second = Self.model("llama-3.2-3b")
        second.name = "Llama 3.2 3B"
        second.engineDeclaration = EngineDeclaration(thinking: false)
        provider.models.append(second)
        let first = try #require(Board.make(provider)?.modelRows.first { $0.id == .thinking })
        if case let .format(key, name) = first.value {
            #expect(key == "The engine reports %@ doesn’t support thinking.")
            #expect(name == provider.models[0].name)
        } else {
            Issue.record("unsupported should show the fallback model name as a placeholder, got \(String(describing: first.value))")
        }
        let lastUsed = LastUsedModelRef(providerID: provider.id, modelID: "llama-3.2-3b")
        let row = try #require(Board.make(provider, lastUsedModelRef: lastUsed)?.modelRows.first { $0.id == .thinking })
        if case let .format(_, name) = row.value {
            #expect(name == "Llama 3.2 3B")
        } else {
            Issue.record("when lastUsed is unsupported it should show that model's display name as a placeholder, got \(String(describing: row.value))")
        }
    }

    // MARK: - BOARD-DETAIL-08

    @Test("BOARD-DETAIL-08 showsKeyUI false (implicit or 1 key): a single row, tapping opens the keys page; \"No key needed\" is still not tappable")
    func boardDetail08SingleKeyRow() throws {
        let implicitRow = try #require(Board.make(Self.relayProvider())?.connectionRows.first { $0.id == .apiKey })
        #expect(implicitRow.titleKey == "API Key")
        #expect(implicitRow.value == .verbatim("sk-…7f2a"))
        #expect(implicitRow.trailingKey == Board.addMoreKeysKey)
        #expect(implicitRow.destination == .apiKeys)
        #expect(implicitRow.keys.isEmpty)
        #expect(implicitRow.moreKeysCount == 0)

        // The list is materialized but only one key remains: likewise a single row.
        var single = Self.relayProvider()
        single.relayKeys = [RelayKey(id: "initial", name: "Main")]
        let singleRow = try #require(Board.make(single)?.connectionRows.first { $0.id == .apiKey })
        #expect(singleRow.titleKey == "API Key")
        #expect(singleRow.keys.isEmpty)
        #expect(singleRow.destination == .apiKeys)

        // authMode none and no stored key: not tappable.
        let none = try #require(Board.make(Self.relayProvider(apiKey: "", apiKeyPreview: "", authMode: .none))?
            .connectionRows.first { $0.id == .apiKey })
        #expect(none.value == .key("No key needed"))
        #expect(none.destination == nil)
    }

    // MARK: - BOARD-DETAIL-09

    @Test("BOARD-DETAIL-09 2 or more keys: a title row \"API Keys · N keys\" + the first 3 keys inline, and \"%lld more\" when there are more than 3")
    func boardDetail09MultiKeyRow() throws {
        var two = Self.relayProvider()
        two.relayKeys = [
            RelayKey(id: "initial", name: "Main", status: .init(state: .ok, httpStatus: 200, checkedAt: nil)),
            RelayKey(id: "k-b", apiKey: "sk-b-0000-1111-2222", status: .init(state: .invalid, httpStatus: 401, checkedAt: nil)),
        ]
        let twoRow = try #require(Board.make(two)?.connectionRows.first { $0.id == .apiKey })
        #expect(twoRow.titleKey == "API Keys")
        #expect(twoRow.value == .count("%lld keys", 2))
        #expect(twoRow.trailingKey == nil)
        #expect(twoRow.destination == .apiKeys)
        #expect(twoRow.keys == RelayKeysBoardModel.make(two).rows, "the inline rows come from the same read model as the keys page")
        #expect(twoRow.keys.map(\.title) == ["Main", APIKeyMask.masked("sk-b-0000-1111-2222")])
        #expect(twoRow.keys.map(\.statusKey) == ["Active", "Invalid"])
        #expect(twoRow.moreKeysCount == 0)

        var five = two
        five.relayKeys = (two.relayKeys ?? []) + (3...5).map { RelayKey(id: "k-\($0)", apiKey: "sk-extra-\($0)-0000-1111") }
        let fiveRow = try #require(Board.make(five)?.connectionRows.first { $0.id == .apiKey })
        #expect(fiveRow.value == .count("%lld keys", 5))
        #expect(fiveRow.keys.map(\.id) == ["initial", "k-b", "k-3"])
        #expect(fiveRow.moreKeysCount == 2)
        #expect(Board.moreKeysKey == "%lld more")
    }

    // MARK: - BOARD-DETAIL-10

    @Test("BOARD-DETAIL-10 Header: unified avatar, a pencil next to the name, model count = enabled ∪ distinct catalog ids + detection time; the local header is unchanged")
    func boardDetail10Header() throws {
        // Board convention: 5 enabled + 49 outside the catalog = 54 (3 of the enabled ones are also in the catalog).
        let enabled = (0..<5).map { Self.model("enabled-\($0)") }
        let catalog = Array(enabled.prefix(3)) + (0..<49).map { Self.model("catalog-\($0)") }
        var provider = TestFactories.makeProvider(
            kind: .relay,
            models: enabled,
            catalogModels: catalog,
            lastCheckedAt: Date(timeIntervalSince1970: 1_700_000_000),
            baseURLText: "https://openrouter.ai/api/v1",
            customName: "My backup"
        )
        provider.relayRequested = RelayRequestedConfig(transport: .openaiChatCompletions, authMode: .bearer)
        let board = try #require(Board.make(provider))
        #expect(board.modelCount == 54)
        #expect(Board.modelsCountKey == "%lld models")
        #expect(board.checkedAt == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(board.avatar == RelayAvatarResolver.avatar(for: provider))
        #expect(board.avatar == .brand("ProviderOpenRouter"))
        #expect(Board.renameIcon == .pencilSimple)
        #expect(board.actions.first == .rename)

        // Local: does not use the relay avatar.
        #expect(try #require(Board.make(Self.localProvider(engine: "ollama"))).avatar == nil)
    }

    // MARK: - BOARD-DETAIL-11

    @Test("RL2-PLURAL-01 \"%lld models\" pluralizes: en 1 → 1 model, 2 → 2 models; ru has three forms for 1 / 2 / 5")
    func modelsCountKeyIsPlural() throws {
        let path = try #require(Bundle.main.path(forResource: "en", ofType: "lproj"))
        let en = try #require(Bundle(path: path))
        let format = en.localizedString(forKey: Board.modelsCountKey, value: nil, table: "Localizable")
        #expect(String.localizedStringWithFormat(format, Int64(1)) == "1 model")
        #expect(String.localizedStringWithFormat(format, Int64(2)) == "2 models")

        // Russian has three plural forms one / few / many: the plural form follows the UI language (L10n.format), not the system Locale.current.
        let ruPath = try #require(Bundle.main.path(forResource: "ru", ofType: "lproj"))
        let ru = try #require(Bundle(path: ruPath))
        let ruFormat = ru.localizedString(forKey: Board.modelsCountKey, value: nil, table: "Localizable")
        let ruLocale = Locale(identifier: "ru")
        #expect(L10n.format(ruFormat, locale: ruLocale, Int64(1)) == "1 модель")
        #expect(L10n.format(ruFormat, locale: ruLocale, Int64(2)) == "2 модели")
        #expect(L10n.format(ruFormat, locale: ruLocale, Int64(5)) == "5 моделей")
        // App language differs from the system language: with a non-ru system Locale, the ru UI language still picks the many form (the old call gave "5 модели").
        #expect(!Locale.current.identifier.hasPrefix("ru"))
        #expect(L10n.format(ruFormat, locale: ruLocale, Int64(5)) != String.localizedStringWithFormat(ruFormat, Int64(5)))
        // Without a locale argument it follows the UI language (AppLocalization.currentLocale).
        #expect(L10n.format(format, Int64(1)) == String(format: format, locale: AppLocalization.currentLocale, Int64(1)))
    }

    @Test("BOARD-DETAIL-11 The parameters row is the third row of the models card (relay / local), its icon doesn't clash with Edit connection, and the detail page no longer has a Settings section")
    func boardDetail11ParametersRowInModelsCard() throws {
        for (provider, second) in [
            (Self.relayProvider(), Board.RowID.webSearch),
            (Self.localProvider(engine: "ollama"), .thinking),
        ] {
            let board = try #require(Board.make(provider))
            #expect(board.modelRows.map(\.id) == [.modelLibrary, second, .parameters])
            let row = try #require(board.modelRows.last)
            #expect(row.titleKey == "Parameters")
            #expect(row.destination == .parameters)
            // The top-right "Edit connection" is slidersHorizontal, and a second slider is not placed on the same screen.
            #expect(row.icon != .slidersHorizontal)
            #expect(row.icon == Board.parametersIcon)
            // The row accent color comes from DetailRowPalette, not borrowed from a capability color (parameters are not a capability).
            #expect(Board.iconTint(for: row.id) == .rose)
            #expect(row.value == nil)
            #expect(row.trailingKey == nil)
            // Whether it is listed is still decided only by the criterion of the settings section; the host moves to the board, and the bottom no longer shows a "Settings" section.
            #expect(ProviderSettingsRow.rows(for: provider, hasEndpointOptions: false).contains(.parameters))
            #expect(!ProviderSettingsRow.usesSettingsSection(for: provider))
        }
        // Official providers are unchanged: the parameters row stays in the settings section.
        #expect(ProviderSettingsRow.usesSettingsSection(for: TestFactories.makeProvider(kind: .openAI)))

        // The host's settings-section visibility goes through usesSettingsSection; a tap on the board row is wired to the parameters page.
        let detail = try String(contentsOf: Self.providerSource("ProviderDetailView.swift"), encoding: .utf8)
        #expect(detail.contains("ProviderSettingsRow.usesSettingsSection(for: provider)"))
        #expect(detail.contains("onOpenParameters: { showGenerationParameters = true }"))
    }

    // MARK: - BOARD-DETAIL-12

    private static func issue(_ provider: Provider, lastError: String?) -> Provider {
        var provider = provider
        provider.status = .issue("issue")
        provider.lastError = lastError
        return provider
    }

    @Test("BOARD-DETAIL-12 Connection-problem recovery card: Edit connection / Key (only when credentials are required) / Re-verify, and Key opens the keys page")
    func boardDetail12RecoveryCardActions() throws {
        typealias ActionID = Board.RecoveryCard.ActionID

        // Relay, credentials required.
        let relay = try #require(Board.recoveryCard(for: Self.issue(
            Self.relayProvider(),
            lastError: " \(ProviderIssueMessage.unverifiedConnectionKey) "
        )))
        #expect(relay.actions.map(\.id) == [ActionID.editConnection, .apiKeys, .reverify])
        #expect(relay.actions.map(\.titleKey) == ["Edit connection", "API Keys", "Verify again"])
        #expect(relay.actions.map(\.icon) == [.slidersHorizontal, .key, .arrowClockwise])
        #expect(relay.actions.map(\.opensPage) == [true, true, false])
        #expect(relay.icon == .warning)
        #expect(relay.headlineKey == "This connection needs attention")
        #expect(relay.detailMessageKey == ProviderIssueMessage.unverifiedConnectionKey)

        // Relay, no credentials required: no Key item.
        let open = try #require(Board.recoveryCard(for: Self.issue(
            Self.relayProvider(apiKey: "", apiKeyPreview: "", authMode: .none),
            lastError: nil
        )))
        #expect(open.actions.map(\.id) == [ActionID.editConnection, .reverify])
        #expect(open.detailMessageKey == nil)

        // Local (no authentication): likewise only Edit connection and Re-verify.
        let local = try #require(Board.recoveryCard(for: Self.issue(Self.localProvider(engine: "ollama"), lastError: "boom")))
        #expect(local.actions.map(\.id) == [ActionID.editConnection, .reverify])
        #expect(local.headlineKey == Board.recoveryIssueHeadlineKey)
        #expect(local.detailMessageKey == "boom")

        // Credentials required but no key stored on this device: the title says the key is missing, without the last error; the Key item is present.
        let missing = try #require(Board.recoveryCard(for: Self.relayProvider(apiKey: "", apiKeyPreview: "")))
        #expect(missing.icon == .key)
        #expect(missing.headlineKey == "API key not saved on this device. Tap to add it.")
        #expect(missing.detailMessageKey == nil)
        #expect(missing.actions.map(\.id) == [ActionID.editConnection, .apiKeys, .reverify])

        // The missing-key title reads "Tap to add": the first line is tappable and goes to the same destination as the Key action; in other states the first line is not tappable.
        #expect(missing.headlineDestination == .apiKeys)
        #expect(relay.headlineDestination == nil)
        #expect(local.headlineDestination == nil)

        // Local + with authentication: the same set of actions as a relay that requires credentials.
        var securedLocal = Self.localProvider(engine: "llamacpp")
        securedLocal.relayRequested?.authMode = .bearer
        securedLocal.apiKey = "sk-local-0000"
        let secured = try #require(Board.recoveryCard(for: Self.issue(securedLocal, lastError: "boom")))
        #expect(secured.actions.map(\.id) == [ActionID.editConnection, .apiKeys, .reverify])
        #expect(secured.headlineKey == Board.recoveryIssueHeadlineKey)

        // No card when the connection is healthy; official providers don't use this card.
        #expect(Board.recoveryCard(for: Self.relayProvider()) == nil)
        #expect(Board.recoveryCard(for: Self.localProvider(engine: "ollama")) == nil)
        #expect(Board.recoveryCard(for: Self.issue(TestFactories.makeProvider(kind: .openAI), lastError: "boom")) == nil)
    }

    @MainActor
    private final class RequestCounter {
        var value = 0
    }

    @Test("BOARD-DETAIL-12 While Re-verify is in progress: the row is disabled and marked in progress, tapping again sends no second request, and other actions are unaffected")
    func boardDetail12ReverifyInFlight() async throws {
        let provider = Self.issue(Self.relayProvider(), lastError: "boom")
        let idle = try #require(Board.recoveryCard(for: provider))
        #expect(idle.actions.map(\.isRunning) == [false, false, false])
        #expect(idle.actions.map(\.isEnabled) == [true, true, true])

        let runner = RelayRedetectRunner()
        let requests = RequestCounter()
        let first = try #require(runner.tap { requests.value += 1; return true })
        let running = try #require(Board.recoveryCard(for: provider, isReverifying: runner.isRunning))
        #expect(running.actions.map(\.isRunning) == [false, false, true])
        #expect(running.actions.map(\.isEnabled) == [true, true, false])
        #expect(runner.tap { requests.value += 1; return true } == nil, "tapping again while in progress must not send again")
        _ = await first.value
        #expect(requests.value == 1)
        #expect(try #require(Board.recoveryCard(for: provider, isReverifying: runner.isRunning)).actions.allSatisfy(\.isEnabled))
    }

    @Test("BOARD-DETAIL-12 While the one-time notice for an unverified save is showing, the recovery card does not repeat the same reason")
    func boardDetail12NoticeCoversDetail() throws {
        // The status and lastError persisted by manual setup's "Save anyway (unverified)" are both this one key, and the banner title is it too.
        let provider = Self.issue(Self.relayProvider(), lastError: ProviderIssueMessage.unverifiedConnectionKey)
        #expect(ProviderDetailNotice.Kind.unverifiedSaveTitleKey == ProviderIssueMessage.unverifiedConnectionKey)
        #expect(ProviderDetailView.noticeCoversRecoveryDetail(.unverifiedSave("timeout")))
        #expect(!ProviderDetailView.noticeCoversRecoveryDetail(.addedModels(3)))
        #expect(!ProviderDetailView.noticeCoversRecoveryDetail(nil))

        let alone = try #require(Board.recoveryCard(for: provider))
        #expect(alone.detailMessageKey == ProviderIssueMessage.unverifiedConnectionKey)
        let withNotice = try #require(Board.recoveryCard(for: provider, omitsDetail: true))
        #expect(withNotice.detailMessageKey == nil)
        // Only the reason row yields; the title and the actions stay.
        #expect(withNotice.headlineKey == alone.headlineKey)
        #expect(withNotice.actions == alone.actions)
    }

    @Test("BOARD-DETAIL-12 The mapping from recovery card action id to callback is not crossed")
    func boardDetail12HandlersMapByID() {
        var fired: [String] = []
        let handlers = RelayDetailRecoveryCard.Handlers(
            editConnection: { fired.append("edit") },
            apiKeys: { fired.append("keys") },
            reverify: { fired.append("reverify") }
        )
        handlers.handler(for: .editConnection)()
        handlers.handler(for: .apiKeys)()
        handlers.handler(for: .reverify)()
        #expect(fired == ["edit", "keys", "reverify"])
    }

    // MARK: - BOARD-DETAIL-13

    @Test("BOARD-DETAIL-13 auto vs a chosen protocol: the footnote and the default protocol value")
    func boardDetail13AutoVersusFixedProtocol() throws {
        let auto = try #require(Board.make(Self.relayProvider(transport: .auto)))
        #expect(auto.footnoteKey == "Detect again refreshes the catalog and each model’s protocol. Enabled models are kept.")
        #expect(auto.connectionRows.first { $0.id == .defaultProtocol }?.value == .key("Auto · detected per model"))

        // After a protocol is chosen, re-detection no longer probes each model: the footnote doesn't mention protocols, and the value slot is the protocol name.
        for transport in [RelayTransport.openaiChatCompletions, .openaiResponses, .anthropicMessages, .geminiGenerateContent] {
            let fixed = try #require(Board.make(Self.relayProvider(transport: transport)))
            #expect(fixed.footnoteKey == "Detect again refreshes the catalog. Enabled models are kept.", "\(transport.rawValue)")
            #expect(!fixed.footnoteKey.contains("protocol"), "\(transport.rawValue)")
            #expect(fixed.connectionRows.first { $0.id == .defaultProtocol }?.value == .transport(transport), "\(transport.rawValue)")
        }

        // The local channel is fixed: likewise no mention of refreshing protocols.
        #expect(try #require(Board.make(Self.localProvider(engine: "ollama"))).footnoteKey == Board.footnoteFixedKey)
    }

    // MARK: - BOARD-DETAIL-14

    @Test("BOARD-DETAIL-14 The request URL / engine address row is tappable, and like the protocol row in the same card opens Edit connection")
    func boardDetail14AddressRowOpensEditConnection() throws {
        let relay = try #require(Board.make(Self.relayProvider()))
        let requestURL = try #require(relay.connectionRows.first { $0.id == .requestURL })
        #expect(requestURL.destination == .editConnection)
        #expect(requestURL.destination == relay.connectionRows.first { $0.id == .defaultProtocol }?.destination)

        // Local: the address row is always tappable; the channel row is tappable only when llama.cpp has a second channel, and the two are not tied together.
        for engine in ["llamacpp", "ollama"] {
            let local = try #require(Board.make(Self.localProvider(engine: engine)))
            #expect(local.connectionRows.first { $0.id == .engineAddress }?.destination == .editConnection, "\(engine)")
        }
        // The engine can only be re-detected, not edited by hand: still not tappable.
        let ollama = try #require(Board.make(Self.localProvider(engine: "ollama")))
        #expect(ollama.connectionRows.first { $0.id == .engine }?.destination == nil)
    }

    // MARK: - BOARD-DETAIL-04

    @Test("BOARD-DETAIL-04 Single entry point for actions: Edit connection doesn't contain rename / change key / delete, the detail page does; a relay has no default-model action")
    func boardDetail04SingleEntry() throws {
        for (provider, expected) in [
            (Self.relayProvider(), [Board.Action.rename, .editAPIKey, .delete]),
            // Local S0: the key row isn't tappable, and changing the key is not an action of this connection.
            (Self.localProvider(engine: "ollama"), [.rename, .delete]),
        ] {
            let board = try #require(Board.make(provider))
            #expect(board.actions == expected)
            // All that is listed for Relay / local is the single parameters row (Edit connection and Delete became the header and bottom buttons), and it is drawn in the models card (BOARD-DETAIL-11).
            #expect(ProviderSettingsRow.rows(for: provider, hasEndpointOptions: false) == [.parameters])
            // The model row menu no longer has "Set as default".
            for model in provider.models + provider.catalogModels {
                #expect(!ProviderEnabledModelRow.allowsSetDefault(provider: provider, model: model))
            }
        }
        // "Set as default" has no effect on a relay: it neither marks a default nor writes relayRequested.modelID.
        let state = AppState(seedDemoData: false, sessionUID: "relay-detail-default-\(UUID().uuidString)")
        var relay = Self.relayProvider()
        relay.relayRequested?.modelID = "claude-sonnet-4.5"
        state.providers = [relay]
        state.setDefaultModel(modelID: "gpt-4o-mini", for: relay.id)
        let updated = try #require(state.provider(for: relay.id))
        #expect(updated.models.first { $0.id == "gpt-4o-mini" }?.isDefault == false)
        #expect(updated.defaultModel?.id == "claude-sonnet-4.5")
        // The model of Edit connection = the verification sample (fallback model → the first catalog model); neither a stored relayRequested.modelID nor the old isDefault is read.
        var legacy = Self.relayProvider()
        legacy.relayRequested?.modelID = "gpt-4o-mini"
        legacy.models = legacy.models.map { var m = $0; m.isDefault = m.id == "gpt-4o-mini"; return m }
        #expect(legacy.defaultModel?.id == "claude-sonnet-4.5")
        #expect(RelayEditView.Editor(from: legacy).modelID == "claude-sonnet-4.5")
        #expect(RelayEditView.Editor(
            from: legacy,
            lastUsedModelRef: LastUsedModelRef(providerID: legacy.id, modelID: "gpt-4o-mini")
        ).modelID == "gpt-4o-mini")

        let official = TestFactories.makeProvider(kind: .openAI, models: [Self.model("a", isDefault: true), Self.model("b")])
        #expect(ProviderEnabledModelRow.allowsSetDefault(provider: official, model: official.models[1]))
        #expect(ProviderSettingsRow.rows(for: official, hasEndpointOptions: false) == [.connection, .parameters, .delete])

        // The edit-connection page (RelayEditView and its own components) no longer renders an entry for these four actions.
        for file in ["RelayEditView.swift", "RelayEditBoardView.swift", "RelayEditBoardModel.swift"] {
            let source = try String(contentsOf: Self.providerSource(file), encoding: .utf8)
            for marker in [
                "relay_settings_edit_name_button", "RelayDraftNameSheet(", "relay_settings_api_key_row",
                "EditAPIKeySheet(", "defaultModelSection(", "relay_settings_delete_button",
            ] {
                #expect(!source.contains(marker), "\(file) still contains \(marker)")
            }
        }
    }

    private static func providerSource(_ filename: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Oriveo/Features/Providers")
            .appendingPathComponent(filename)
    }

    // MARK: - BOARD-DETAIL-05

    @Test("BOARD-DETAIL-05 Re-detect: tapping calls the production redetectRelayModels, it can't be tapped while in progress, and success updates the detection time")
    func boardDetail05RedetectButton() async throws {
        var provider = Self.relayProvider()
        // The default protocol has already been set by the user: re-detection does not probe protocols and only refreshes the catalog.
        provider.models[0].relayTransport = .anthropicMessages
        provider.models[0].relayTransportSource = .user
        RelayDetailFakeServer.install(catalogIDs: provider.catalogModels.map(\.id))
        let state = AppState(
            seedDemoData: false,
            sessionUID: "relay-detail-\(UUID().uuidString)",
            providerSession: RelayDetailFakeServer.session()
        )
        state.providers = [provider]
        let manager = state.providerManager
        let id = provider.id

        let runner = RelayRedetectRunner()
        let first = try #require(runner.tap { await manager.redetectRelayModels(providerID: id) })
        #expect(runner.isRunning)
        #expect(Board.detectButton(isRunning: runner.isRunning) == .init(titleKey: "Detecting...", isEnabled: false))
        #expect(runner.tap { await manager.redetectRelayModels(providerID: id) } == nil, "tapping again while in progress must not send again")

        #expect(await first.value)
        #expect(!runner.isRunning)
        #expect(Board.detectButton(isRunning: runner.isRunning).isEnabled)
        #expect(RelayDetailFakeServer.catalogRequestCount() == 1)

        let current = try #require(state.provider(for: id))
        let checkedAt = try #require(current.lastCheckedAt, "a successful re-detection must update the detection time")
        #expect(try #require(Board.make(current)).checkedAt == checkedAt)
    }

    // MARK: - BOARD-DETAIL-06

    @Test("BOARD-DETAIL-06 auto connection: the kind derived on save is fully custom, the protocol stays auto, and the default protocol row shows Auto")
    func boardDetail06AutoConnection() throws {
        let provider = Self.relayProvider(transport: .auto)
        #expect(RelayKind(requested: provider.relayRequested) == .custom)
        #expect(RelayEditSavePolicy.savedRelayKind(editor: RelayEditView.Editor(from: provider)) == .custom)
        // The edit page has no type layer: a stored relayKind says OpenAI-compatible while the protocol is auto,
        // opening the edit page still shows auto; on save the kind is derived from the protocol (auto → fully custom), and the connection is not pinned to Chat.
        var stored = provider
        stored.relayKind = .openaiCompatible
        let storedEditor = RelayEditView.Editor(from: stored)
        #expect(storedEditor.transport == .auto)
        #expect(RelayEditSavePolicy.savedRelayKind(editor: storedEditor) == .custom)
        #expect(stored.relayKind == .openaiCompatible)
        var explicit = Self.relayProvider(transport: .anthropicMessages)
        explicit.relayKind = .anthropicCompatible
        #expect(RelayEditSavePolicy.savedRelayKind(editor: RelayEditView.Editor(from: explicit)) == .anthropicCompatible)
        let board = try #require(Board.make(provider))
        let row = try #require(board.connectionRows.first { $0.id == .defaultProtocol })
        // The value slot no longer says just "Auto": it adds how it was decided (BOARD-DETAIL-13).
        #expect(row.value == .key(Board.autoProtocolValueKey))
    }

    // MARK: - BOARD-DETAIL-07

    @Test("BOARD-DETAIL-07 Local edit-connection channel: llama.cpp has two selectable options, the others have one read-only, independent of the stored kind")
    func boardDetail07LocalChannelSection() throws {
        let fixture = try Self.expectations()
        let channels = try #require(fixture["channels"] as? [String: Any])
        let byEngine = try #require(channels["byEngine"] as? [String: [String]])
        for (engine, names) in byEngine {
            let wires = try names.map { name -> RelayTransport in
                let wire = try #require(channels[name] as? String)
                return try #require(RelayTransport(rawValue: wire))
            }
            let expected: LocalEngineChannelCandidates.Section = wires.count > 1 ? .selectable(wires) : .readOnly(wires[0])
            #expect(LocalEngineChannelCandidates.section(engineProfile: engine) == expected, "\(engine)")
        }
        #expect(LocalEngineChannelCandidates.section(engineProfile: nil) == nil)

        // A local connection is saved by the add page as the OpenAI-compatible kind: the channel block is not hidden by the kind.
        var local = Self.localProvider(engine: "llamacpp")
        local.relayKind = .openaiCompatible
        let editor = RelayEditView.Editor(from: local)
        #expect(RelayEditSavePolicy.savedRelayKind(editor: editor) == .openaiCompatible)
        // Production path: the edit-connection board produces the Channel group from the engine profile, and a non-local connection has no such group.
        let localBoard = RelayEditBoardModel.make(provider: local, editor: editor)
        let channel = try #require(localBoard.groups.first { $0.id == .channel }?.rows.first { $0.id == .channel })
        #expect(channel.control == .menu)
        #expect(channel.value == .transport(editor.transport))
        let relay = Self.relayProvider()
        let relayBoard = RelayEditBoardModel.make(provider: relay, editor: RelayEditView.Editor(from: relay))
        #expect(!relayBoard.groups.contains { $0.id == .channel })
    }
}
