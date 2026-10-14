import Foundation
import Testing
@testable import Oriveo

/// Structure tests for the "Edit connection" modal (the "Edit connection (EditConnection)" section of the UI spec card).
/// The assertions target what the production row model `RelayEditBoardModel` and the save policy `RelayEditSavePolicy` actually produce; there are no image snapshots.
@Suite("Relay 2.0 · Edit connection board structure")
@MainActor
struct RelayEditBoardStructureTests {
    typealias Board = RelayEditBoardModel
    typealias Editor = RelayEditView.Editor

    private static func model(_ id: String) -> AIModel {
        TestFactories.makeModel(id: id, capabilities: [.text])
    }

    private static func relayProvider(
        transport: RelayTransport = .auto,
        authMode: RelayAuthMode = .bearer,
        relayKind: RelayKind? = nil
    ) -> Provider {
        var provider = TestFactories.makeProvider(
            kind: .relay,
            models: [model("claude-sonnet-4.5"), model("gpt-4o-mini")],
            catalogModels: [model("claude-sonnet-4.5"), model("gpt-4o-mini"), model("gemini-2.5-pro")],
            apiKey: "sk-test-7f2a",
            apiKeyPreview: "sk-…7f2a",
            baseURLText: "https://api.myrelay.dev"
        )
        provider.relayKind = relayKind
        provider.relayRequested = RelayRequestedConfig(transport: transport, authMode: authMode)
        return provider
    }

    private static func localProvider(
        engine: String = "ollama",
        securityMode: RelayConnectionSecurityMode = .localHTTP
    ) -> Provider {
        let isCleartext = securityMode == .localHTTP || securityMode == .privateVPN
        var provider = TestFactories.makeProvider(
            kind: .relay,
            models: [model("qwen3-8b-q4")],
            catalogModels: [model("qwen3-8b-q4")],
            apiKey: isCleartext ? "" : "engine-token",
            apiKeyPreview: "",
            baseURLText: isCleartext ? "http://192.168.1.20:8080" : "https://engine.example.com"
        )
        provider.relayKind = .openaiCompatible
        provider.relayRequested = RelayRequestedConfig(
            transport: .openaiChatCompletions,
            authMode: isCleartext ? .none : .bearer,
            securityMode: securityMode,
            engineProfile: engine
        )
        return provider
    }

    private static func board(_ provider: Provider, _ mutate: (inout Editor) -> Void = { _ in }) -> Board {
        var editor = Editor(from: provider)
        mutate(&editor)
        return Board.make(provider: provider, editor: editor)
    }

    private static func group(_ board: Board, _ id: Board.GroupID) throws -> Board.Group {
        try #require(board.groups.first { $0.id == id }, "missing group \(id.rawValue)")
    }

    private static func row(_ board: Board, _ group: Board.GroupID, _ id: Board.RowID) throws -> Board.Row {
        try #require(try Self.group(board, group).rows.first { $0.id == id }, "missing row \(id.rawValue)")
    }

    private static func providerSource(_ filename: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Oriveo/Features/Providers")
            .appendingPathComponent(filename)
    }

    // MARK: - BOARD-EDIT-01

    @Test("BOARD-EDIT-01 Relay: the four groups in order, the row order within each group, the leading icon and the row color")
    func boardEdit01RelayGroupsRowsIconsTints() throws {
        let provider = Self.relayProvider()
        let board = Self.board(provider)

        #expect(Board.titleKey == "Edit connection")
        #expect(board.form == .relay)
        #expect(board.subtitle == provider.displayName)
        #expect(board.groups.map(\.id) == [.connection, .protocolAuth, .headers, .compatibility])
        #expect(board.groups.map(\.titleKey) == [
            "Connection", "Protocol & authentication", "Headers & query params", "Compatibility",
        ])

        let connection = try Self.group(board, .connection)
        #expect(connection.rows.map(\.id) == [.requestURL, .connectionSecurity])
        #expect(connection.rows.map(\.titleKey) == ["Request URL", "Connection security"])
        #expect(connection.rows.map(\.control) == [.addressInput, .change])
        #expect(!connection.isCollapsible)

        let protocolAuth = try Self.group(board, .protocolAuth)
        #expect(protocolAuth.rows.map(\.id) == [.defaultProtocol, .authentication])
        #expect(protocolAuth.rows.map(\.titleKey) == ["Default protocol", "Auth Mode"])
        #expect(protocolAuth.rows.map(\.control) == [.menu, .menu])
        #expect(!protocolAuth.isCollapsible)

        // Leading icon and row color: the address and default protocol rows share the detail page's color for the same row; connection security and authentication are the two rows unique to this page.
        let address = connection.rows[0]
        #expect(address.icon == .link)
        #expect(address.tint == .cyan)
        #expect(address.tint == RelayDetailBoardModel.iconTint(for: .requestURL))
        let security = connection.rows[1]
        #expect(security.icon == .shieldCheck)
        #expect(security.tint == .teal)
        let defaultProtocol = protocolAuth.rows[0]
        #expect(defaultProtocol.icon == .hardDrives)
        #expect(defaultProtocol.tint == .indigo)
        #expect(defaultProtocol.tint == RelayDetailBoardModel.iconTint(for: .defaultProtocol))
        let auth = protocolAuth.rows[1]
        #expect(auth.icon == .key)
        #expect(auth.tint == .orange)
        #expect([address, security, defaultProtocol, auth].compactMap { $0.icon?.rawValue }
            == ["link", "shield-check", "hard-drives", "key"])

        // The row under the address row is "Will request ..." computed by the same function as the add page; the connection security row carries a "takes effect immediately" note.
        let preview = try #require(RelaySetupBoardModel.previewLine(detectedRoot: nil, input: "https://api.myrelay.dev"))
        #expect(address.footnote == .format("Will request %@", preview))
        #expect(security.value == .verbatim(RelaySecurityModeSummaryRow.title(for: .remoteHTTPS)))
        #expect(security.footnote == .key("Changes apply right away and the connection is verified again."))
        // The default protocol and authentication rows expose their current values.
        #expect(defaultProtocol.value == .transport(.auto))
        #expect(auth.value == .verbatim(relayAuthLabel(.bearer)))

        // Both the headers group and the compatibility group are collapsible and collapsed by default.
        let headers = try Self.group(board, .headers)
        #expect(headers.isCollapsible)
        #expect(!headers.startsExpanded)
        #expect(headers.rows.map(\.id) == [.userAgent, .addEntry])
        #expect(headers.rows.map(\.control) == [.valueInput, .add])
        let compatibility = try Self.group(board, .compatibility)
        #expect(compatibility.isCollapsible)
        #expect(!compatibility.startsExpanded)

        // Key-value rows: each row = category + name slot + value slot; header values are masked by default and query values are not; the last row is Add.
        let filled = Self.board(provider) {
            $0.headers = [RelayKeyValue(key: "X-Tenant", value: "secret")]
            $0.queryParams = [RelayKeyValue(key: "api-version", value: "2025-01-01")]
        }
        let filledRows = try Self.group(filled, .headers).rows
        #expect(filledRows.map(\.id) == [.userAgent, .header, .queryParam, .addEntry])
        #expect(filledRows.map(\.titleKey) == ["User-Agent", "Headers", "Query params", "Add"])
        #expect(filledRows.map(\.control) == [.valueInput, .keyValue(masked: true), .keyValue(masked: false), .add])
        #expect(filledRows.map(\.index) == [nil, 0, 0, nil])
    }

    // MARK: - BOARD-EDIT-02

    @Test("RL2-WILLREQ-01 The address slot footnote on the edit page is the same sentence as on the add page, \"Will request <root>/…\"; no such line when the address can't be resolved")
    func editAddressFootnoteMatchesSetupPreview() throws {
        let provider = Self.relayProvider()
        let board = Self.board(provider) { $0.endpoint = "https://api.myrelay.dev/v1" }
        let address = try Self.row(board, .connection, .requestURL)
        let root = try #require(RelayEndpointResolver.previewAPIRoot("https://api.myrelay.dev/v1"))
        #expect(address.footnote == .format("Will request %@", root + "/…"))
        #expect(address.footnote == RelaySetupBoardModel.previewLine(detectedRoot: nil, input: "https://api.myrelay.dev/v1").map { .format("Will request %@", $0) })

        let empty = try Self.row(Self.board(provider) { $0.endpoint = "  " }, .connection, .requestURL)
        #expect(empty.footnote == nil)
    }

    @Test("BOARD-EDIT-02 Local: connection + channel; with plaintext there is no authentication row and no headers group; with encryption both appear; there is never a compatibility group")
    func boardEdit02LocalGroups() throws {
        let cleartext = Self.board(Self.localProvider(engine: "ollama", securityMode: .localHTTP))
        #expect(cleartext.form == .local)
        #expect(cleartext.groups.map(\.id) == [.connection, .channel])
        #expect(cleartext.groups.map(\.titleKey) == ["Connection", "Channel"])
        let connection = try Self.group(cleartext, .connection)
        #expect(connection.rows.map(\.id) == [.engineAddress, .connectionSecurity])
        #expect(connection.rows.map(\.titleKey) == ["Engine address", "Connection security"])
        #expect(connection.rows[0].icon == .link)
        #expect(connection.rows[0].tint == RelayDetailBoardModel.iconTint(for: .engineAddress))
        #expect(connection.rows[1].value == .verbatim(RelaySecurityModeSummaryRow.title(for: .localHTTP)))
        let channel = try Self.row(cleartext, .channel, .channel)
        #expect(try Self.group(cleartext, .channel).rows.map(\.id) == [.channel])
        #expect(channel.icon == .hardDrives)
        #expect(channel.tint == RelayDetailBoardModel.iconTint(for: .channel))
        #expect(channel.titleKey == "Channel")
        #expect(channel.value == .transport(.openaiChatCompletions))
        // Only one channel: read-only, no menu chevron.
        #expect(channel.control == .readOnly)

        // llama.cpp has two selectable channels: with a menu chevron.
        let llama = Self.board(Self.localProvider(engine: "llamacpp", securityMode: .localHTTP))
        #expect(try Self.row(llama, .channel, .channel).control == .menu)

        // A private VPN is plaintext as well.
        let vpn = Self.board(Self.localProvider(securityMode: .privateVPN))
        #expect(vpn.groups.map(\.id) == [.connection, .channel])

        // Encrypted connection: the channel card gains an authentication row, and there is one more group for headers and query params; there is still no compatibility group.
        for mode in [RelayConnectionSecurityMode.remoteHTTPS, .tofuHTTPS] {
            let encrypted = Self.board(Self.localProvider(securityMode: mode))
            #expect(encrypted.groups.map(\.id) == [.connection, .channel, .headers], "\(mode.rawValue)")
            #expect(try Self.group(encrypted, .channel).rows.map(\.id) == [.channel, .authentication], "\(mode.rawValue)")
            let auth = try Self.row(encrypted, .channel, .authentication)
            #expect(auth.icon == .key)
            #expect(auth.tint == .orange)
            #expect(auth.control == .menu)
        }
        // "Encrypted" and "a plaintext connection can't carry a key" use the same criterion.
        for mode in [RelayConnectionSecurityMode.remoteHTTPS, .tofuHTTPS, .localHTTP, .privateVPN] {
            let hasAuth = Self.board(Self.localProvider(securityMode: mode))
                .groups.flatMap(\.rows).contains { $0.id == .authentication }
            #expect(hasAuth == !RelayCredentialPolicy.isCleartext(mode), "\(mode.rawValue)")
        }
    }

    // MARK: - BOARD-EDIT-03

    @Test("BOARD-EDIT-03 Default protocol footnote in two states (auto / a chosen protocol with its name) and the authentication footnote")
    func boardEdit03Footnotes() throws {
        let provider = Self.relayProvider()
        let auto = try Self.row(Self.board(provider), .protocolAuth, .defaultProtocol)
        #expect(auto.footnote == .key(
            "Each model's protocol is detected on its own. Models that can't be detected use Chat Completions."
        ))

        for transport in [RelayTransport.openaiResponses, .openaiChatCompletions, .anthropicMessages, .geminiGenerateContent] {
            let fixed = try Self.row(Self.board(provider) { $0.transport = transport }, .protocolAuth, .defaultProtocol)
            #expect(fixed.value == .transport(transport))
            #expect(fixed.footnote == .format(
                "Every model uses %@ unless you set a protocol on that model.",
                relayTransportLabel(transport)
            ), "\(transport.rawValue)")
        }

        // The %@ of the authentication footnote = the title of the key row on the detail page, taken from that row's own key.
        let detail = try #require(RelayDetailBoardModel.make(provider))
        let keyRow = try #require(detail.connectionRows.first { $0.id == .apiKey })
        let auth = try Self.row(Self.board(provider), .protocolAuth, .authentication)
        #expect(auth.footnote == .format(
            "Manage keys under “%@” on the connection page.",
            L10n.tr(keyRow.titleKey, table: .providers)
        ))
    }

    // MARK: - BOARD-EDIT-04

    @Test("BOARD-EDIT-04 Compatibility items are trimmed by the default protocol (auto / Responses / Chat / Messages / Gemini)")
    func boardEdit04CompatibilityByProtocol() throws {
        let provider = Self.relayProvider()
        let expected: [(RelayTransport, [Board.RowID])] = [
            (.auto, [.stream, .serviceTier, .disableResponseStorage]),
            (.openaiResponses, [.stream, .serviceTier, .disableResponseStorage]),
            (.openaiChatCompletions, [.stream, .serviceTier]),
            (.anthropicMessages, [.stream]),
            (.geminiGenerateContent, [.stream]),
        ]
        for (transport, rows) in expected {
            let board = Self.board(provider) { $0.transport = transport }
            #expect(try Self.group(board, .compatibility).rows.map(\.id) == rows, "\(transport.rawValue)")
            #expect(Board.compatibilityRows(for: transport) == rows, "\(transport.rawValue)")
        }
        let rows = try Self.group(Self.board(provider), .compatibility).rows
        #expect(rows.map(\.titleKey) == ["Stream", "Service Tier", "Don't keep responses in the cloud"])
        #expect(rows.map(\.control) == [.toggle, .valueInput, .toggle])
    }

    // MARK: - BOARD-EDIT-05

    @Test("BOARD-EDIT-05 Headers group title count (the filled count of User-Agent + headers + query params; nothing is written at 0)")
    func boardEdit05HeadersCount() throws {
        let provider = Self.relayProvider()
        #expect(try Self.group(Self.board(provider), .headers).trailing == nil)

        let filled = Self.board(provider) {
            $0.customUserAgent = "MyClient/1.0"
            $0.headers = [RelayKeyValue(key: "X-Tenant", value: "a"), RelayKeyValue(key: " ", value: "ignored")]
            $0.queryParams = [RelayKeyValue(key: "api-version", value: "2025-01-01")]
        }
        #expect(try Self.group(filled, .headers).trailing == .count("%lld set", 3))
        // Collapsed by default, and the same however many are filled: the count sits on the group header so it is visible while collapsed; the same goes for the same group of a local encrypted connection.
        #expect(try !Self.group(filled, .headers).startsExpanded)
        #expect(try !Self.group(Self.board(provider), .headers).startsExpanded)
        #expect(try !Self.group(Self.board(Self.localProvider(securityMode: .remoteHTTPS)), .headers).startsExpanded)

        // Only empty rows added, or a User-Agent of pure whitespace: still 0, no count is written.
        let blank = Self.board(provider) {
            $0.customUserAgent = "  "
            $0.headers = [RelayKeyValue(key: "", value: "")]
        }
        #expect(try Self.group(blank, .headers).trailing == nil)
        #expect(try Self.group(Self.board(provider) { $0.customUserAgent = "UA" }, .headers).trailing == .count("%lld set", 1))
    }

    // MARK: - BOARD-EDIT-06

    @Test("BOARD-EDIT-06 Bottom action bar: Test connection + the primary button in two states")
    func boardEdit06ActionBar() throws {
        var provider = Self.relayProvider(transport: .openaiChatCompletions)
        provider.relayKind = .openaiCompatible

        let untouched = Self.board(provider)
        #expect(untouched.actionBar.secondaryKey == "Test connection")
        #expect(untouched.actionBar.primary == .save)
        #expect(untouched.actionBar.primary.titleKey == "Save")

        // Only header-type fields changed: still "Save".
        let headersOnly = Self.board(provider) {
            $0.customUserAgent = "Oriveo/Test"
            $0.headers = [RelayKeyValue(key: "X-Trace", value: "1")]
            $0.queryParams = [RelayKeyValue(key: "debug", value: "true")]
        }
        #expect(headersOnly.actionBar.primary == .save)

        // Address / default protocol / authentication changed: "Validate and save".
        let changes: [(String, (inout Editor) -> Void)] = [
            ("endpoint", { $0.endpoint = "https://relay-2.example.com/v1" }),
            ("transport", { $0.transport = .openaiResponses }),
            ("auth", { $0.authMode = .xApiKey }),
        ]
        for (name, change) in changes {
            let board = Self.board(provider, change)
            #expect(board.actionBar.primary == .validateAndSave, "\(name)")
            #expect(board.actionBar.primary.titleKey == "Validate and save", "\(name)")
        }

        // Tappability: normally both are tappable; while a connection-security reconnect is in flight both are disabled; while a save is in flight both are disabled;
        // while a test is in flight only Test connection is disabled; when the form has issues only the primary button is disabled; with an empty address only Test connection is disabled.
        let editor = Editor(from: provider)
        func enabled(
            status: Board.Status? = nil, isSaving: Bool = false, hasFormIssues: Bool = false,
            _ mutate: (inout Editor) -> Void = { _ in }
        ) -> [Bool] {
            var draft = editor
            mutate(&draft)
            let bar = Board.make(
                provider: provider, editor: draft, status: status, isSaving: isSaving, hasFormIssues: hasFormIssues
            ).actionBar
            return [bar.isSecondaryEnabled, bar.isPrimaryEnabled]
        }
        #expect(enabled() == [true, true])
        #expect(enabled(status: .reconnecting) == [false, false])
        #expect(enabled(isSaving: true) == [false, false])
        #expect(enabled(status: .testing) == [false, true])
        #expect(enabled(status: .verified) == [true, true])
        #expect(enabled(status: .failed("x")) == [true, true])
        #expect(enabled(hasFormIssues: true) == [true, false])
        #expect(enabled { $0.endpoint = "  " } == [false, true])

        // There is no type layer: a stored relayKind that disagrees with the kind implied by the default protocol does not mean the connection changed.
        let legacy = Self.relayProvider(transport: .auto, relayKind: .openaiCompatible)
        #expect(Self.board(legacy).actionBar.primary == .save)
        #expect(Self.board(legacy) { $0.customUserAgent = "UA" }.actionBar.primary == .save)
    }

    // MARK: - BOARD-EDIT-07

    @Test("BOARD-EDIT-07 There is no type layer: a quick-setup (auto) connection and stored connections of every relayKind produce the same set of rows; the model has no Hero / presets / banner / reasoning row")
    func boardEdit07NoKindLayer() throws {
        // A quick-setup (auto) connection and stored connections of every relayKind: the same set of groups and rows.
        let quick = Self.board(Self.relayProvider(transport: .auto, relayKind: nil))
        #expect(quick.groups.map(\.id) == [.connection, .protocolAuth, .headers, .compatibility])
        for kind in RelayKind.allCases {
            #expect(Self.board(Self.relayProvider(transport: .auto, relayKind: kind)) == quick, "\(kind.rawValue)")
        }
        // A stored connection with a chosen protocol: whatever the relayKind, the rows don't change (protocol / authentication / headers are always present and not taken over by a preset).
        for transport in [RelayTransport.openaiResponses, .openaiChatCompletions, .anthropicMessages, .geminiGenerateContent] {
            let baseline = Self.board(Self.relayProvider(transport: transport, relayKind: nil))
            #expect(try Self.group(baseline, .protocolAuth).rows.map(\.id) == [.defaultProtocol, .authentication])
            for kind in RelayKind.allCases {
                #expect(Self.board(Self.relayProvider(transport: transport, relayKind: kind)) == baseline,
                        "\(transport.rawValue) × \(kind.rawValue)")
            }
        }

        // The model has only these rows: no Hero / type pill / preset card / suggestion banner / connection-level reasoning.
        let allowed: Set<Board.RowID> = [
            .requestURL, .engineAddress, .connectionSecurity, .defaultProtocol, .channel, .authentication,
            .userAgent, .header, .queryParam, .addEntry, .stream, .serviceTier, .disableResponseStorage,
        ]
        let boards = [quick, Self.board(Self.localProvider()), Self.board(Self.localProvider(securityMode: .remoteHTTPS))]
        for board in boards {
            #expect(Set(board.groups.flatMap(\.rows).map(\.id)).isSubset(of: allowed))
            #expect(!board.groups.flatMap(\.rows).contains { $0.titleKey == "Reasoning" })
        }

        // View layer: every entry point of the old design is gone.
        #expect(!FileManager.default.fileExists(atPath: Self.providerSource("RelayEditorHeroCard.swift").path))
        let source = try String(contentsOf: Self.providerSource("RelayEditView.swift"), encoding: .utf8)
        for marker in [
            "RelayEditorHeroCard", "RelayKindPickerView", "presetModeInfoCard", "modelFamilyBanner",
            "suggestedRelayKindForCurrentModel", "applyKindReset", "resettingKind", "pendingRelayKind",
            "reasoningEffortSentryTag", "\"Reasoning\"", "RelayAdvancedFieldsView(", "RelayDefaultModelPresentation",
            // This page doesn't use the system navigation bar, and leaves no SF Symbols trailing chevrons or status icons.
            "NavigationStack", "\"chevron.right\"", "\"chevron.left\"",
            "checkmark.circle", "exclamationmark.triangle", "Image(systemName",
        ] {
            #expect(!source.contains(marker), "RelayEditView.swift still contains \(marker)")
        }
        let boardSource = try String(contentsOf: Self.providerSource("RelayEditBoardView.swift"), encoding: .utf8)
        #expect(!boardSource.contains("Image(systemName"))
        // The view renders from the row model.
        #expect(source.contains("RelayEditBoardModel.make("))
        #expect(source.contains("phosphorIcon: row.icon"))
    }

    // MARK: - BOARD-EDIT-08

    @Test("BOARD-EDIT-08 Saving: relayKind is derived from the default protocol, auto is not pinned to Chat, a stored reasoningEffort is cleared, codexCompatIdentity is kept as is, and other fields such as engineProfile are unchanged")
    func boardEdit08Save() throws {
        // relayKind is derived from the default protocol; auto → custom, and transport is still stored as auto.
        for transport in RelayTransport.allUICases {
            var provider = Self.relayProvider(transport: .openaiChatCompletions, relayKind: .openaiCompatible)
            provider.relayRequested?.transport = .openaiChatCompletions
            var editor = Editor(from: provider)
            editor.transport = transport
            #expect(RelayEditSavePolicy.savedRelayKind(editor: editor) == RelayKind(transport: transport), "\(transport.rawValue)")
            let saved = RelayEditSavePolicy.savedRequested(
                editor: editor, provider: provider, normalizedEndpoint: "https://api.myrelay.dev"
            )
            #expect(saved.transport == transport, "\(transport.rawValue)")
        }
        var quick = Self.relayProvider(transport: .auto, relayKind: .openaiCompatible)
        quick.relayRequested?.reasoningEffort = .high
        let quickEditor = Editor(from: quick)
        #expect(RelayEditSavePolicy.savedRelayKind(editor: quickEditor) == .custom)
        let quickSaved = RelayEditSavePolicy.savedRequested(
            editor: quickEditor, provider: quick, normalizedEndpoint: "https://api.myrelay.dev"
        )
        #expect(quickSaved.transport == .auto, "auto is not pinned to Chat")
        // A stored connection-level effort is cleared by this save.
        #expect(quickSaved.reasoningEffort == nil)

        // codexCompatIdentity keeps the stored value as is: it is neither set to nil nor to true by the type.
        let identityCases: [(RelayTransport, RelayKind, Bool?)] = [
            (.anthropicMessages, .anthropicCompatible, true),
            (.openaiChatCompletions, .openaiCompatible, false),
            (.openaiResponses, .codexStyle, nil),
            (.openaiResponses, .codexStyle, false),
            (.auto, .custom, true),
        ]
        for (transport, kind, identity) in identityCases {
            var provider = Self.relayProvider(transport: transport, relayKind: kind)
            provider.relayRequested?.codexCompatIdentity = identity
            let saved = RelayEditSavePolicy.savedRequested(
                editor: Editor(from: provider), provider: provider, normalizedEndpoint: "https://api.myrelay.dev"
            )
            #expect(saved.codexCompatIdentity == identity, "\(transport.rawValue) × \(kind.rawValue) × \(String(describing: identity))")
        }

        // A save that changes no field: apart from reasoningEffort being cleared, the stored request configuration is unchanged field by field.
        var full = Self.relayProvider(transport: .openaiResponses, relayKind: .codexStyle)
        full.relayRequested = RelayRequestedConfig(
            transport: .openaiResponses,
            authMode: .bearer,
            securityMode: .remoteHTTPS,
            reasoningEffort: .xhigh,
            serviceTier: "priority",
            stream: false,
            disableResponseStorage: true,
            headers: [RelayKeyValue(key: "X-Tenant", value: "a")],
            queryParams: [RelayKeyValue(key: "api-version", value: "1")],
            codexCompatIdentity: false,
            customUserAgent: "MyClient/1.0",
            imageSize: "1024x1024",
            resolvedAPIBaseURL: "https://api.myrelay.dev/v1",
            resolvedAPIBaseURLs: [RelayTransport.openaiResponses.rawValue: "https://api.myrelay.dev/v1"]
        )
        let untouched = RelayEditSavePolicy.savedRequested(
            editor: Editor(from: full), provider: full, normalizedEndpoint: "https://api.myrelay.dev"
        )
        var expected = try #require(full.relayRequested)
        expected.reasoningEffort = nil
        #expect(untouched == expected)

        // Local: engineProfile / certificate fingerprint / connection security are kept as is.
        var local = Self.localProvider(engine: "llamacpp", securityMode: .tofuHTTPS)
        local.relayRequested?.certificateFingerprint = "sha256:abc"
        var localEditor = Editor(from: local)
        localEditor.transport = .llamacppNative
        let localSaved = RelayEditSavePolicy.savedRequested(
            editor: localEditor, provider: local, normalizedEndpoint: "https://engine.example.com"
        )
        #expect(localSaved.engineProfile == "llamacpp")
        #expect(localSaved.certificateFingerprint == "sha256:abc")
        #expect(localSaved.securityMode == .tofuHTTPS)
        #expect(localSaved.transport == .llamacppNative)
        #expect(RelayEditSavePolicy.savedRelayKind(editor: localEditor) == RelayKind(transport: .llamacppNative))
    }

    // MARK: - BOARD-EDIT-09

    @Test("BOARD-EDIT-09 A connection-security switch in progress shows the in-progress style, not a failure; a verification failure shows only the failure card, with no confirmation-dialog state any more")
    func boardEdit09StatusAndFailureCard() throws {
        let reconnecting = Board.statusRow(.reconnecting)
        #expect(reconnecting.tone == .progress)
        #expect(reconnecting.showsProgress)
        #expect(reconnecting.message == .key("Validating connection and syncing models..."))

        let testing = Board.statusRow(.testing)
        #expect(testing.tone == .progress)
        #expect(testing.showsProgress)
        #expect(testing.message == .key("Testing..."))

        let verified = Board.statusRow(.verified)
        #expect(verified.tone == .success)
        #expect(!verified.showsProgress)
        #expect(verified.message == .key("Connection verified."))

        // The status icon is a Phosphor icon registered in the icon set; the in-progress spinner shows no icon.
        #expect(verified.icon == .checkCircle)
        #expect(verified.icon?.rawValue == "check-circle")
        #expect(reconnecting.icon == nil)
        #expect(testing.icon == nil)

        let failed = Board.statusRow(.failed("upstream said no"))
        #expect(failed.icon == .warning)
        #expect(failed.tone == .warning)
        #expect(!failed.showsProgress)
        #expect(failed.message == .verbatim("upstream said no"))

        // Failure card: reason + technical details + "Save anyway (unverified)".
        let provider = Self.relayProvider()
        let card = RelayEditFailurePresentation.error(
            from: ProviderServiceError.network(detail: "connection reset"),
            provider: provider
        )
        #expect(!card.message.isEmpty)
        #expect(!card.detail.isEmpty)
        #expect(card.actionTitle == L10n.tr("Save anyway (unverified)", table: .providers))

        // View layer: reconnect progress no longer borrows the failure slot; the confirmation dialog and its state are gone.
        let source = try String(contentsOf: Self.providerSource("RelayEditView.swift"), encoding: .utf8)
        #expect(source.contains("status = .reconnecting"))
        for marker in [
            "showsUnverifiedSaveConfirmation", "\"Connection has not been verified.\"",
            "relay_settings_save_unverified_keep_editing_button", "TestConnectionResult",
        ] {
            #expect(!source.contains(marker), "RelayEditView.swift still contains \(marker)")
        }
    }

    // MARK: - BOARD-EDIT-10

    private static let locales = [
        "ar", "de", "en", "es", "fr", "hi", "id", "ja", "ko", "pt-BR", "ru", "th", "tr", "vi", "zh-Hans", "zh-Hant",
    ]

    /// Production copy resources: the key of `<Table>.xcstrings` → the set of languages that already have a non-empty value.
    private static func catalog(_ table: L10n.Table) throws -> [String: Set<String>] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Oriveo/\(table.rawValue).xcstrings")
        let root = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let strings = try #require(root["strings"] as? [String: Any])
        return strings.mapValues { entry in
            let localizations = (entry as? [String: Any])?["localizations"] as? [String: Any] ?? [:]
            return Set(localizations.compactMap { locale, value -> String? in
                let unit = value as? [String: Any]
                if let text = (unit?["stringUnit"] as? [String: Any])?["value"] as? String, !text.isEmpty { return locale }
                if let plural = (unit?["variations"] as? [String: Any])?["plural"] as? [String: Any], !plural.isEmpty { return locale }
                return nil
            })
        }
    }

    private static func keys(in text: Board.Text?) -> [String] {
        switch text {
        case let .key(key), let .format(key, _), let .count(key, _), let .counts(key, _, _): [key]
        case .verbatim, .transport, nil: []
        }
    }

    @Test("BOARD-EDIT-10 Every copy key produced by this page's row model and action bar has all 16 languages in the table the view actually looks it up in")
    func boardEdit10EveryCopyKeyResolvesInItsTable() throws {
        var used: [(key: String, table: L10n.Table)] = []
        func use(_ keys: [String], _ table: L10n.Table) {
            for key in keys { used.append((key: key, table: table)) }
        }
        use([Board.titleKey, Board.discardMessageKey], .providers)
        let relay = Self.relayProvider()
        let boards = [
            Self.board(relay) {
                $0.customUserAgent = "UA"
                $0.headers = [RelayKeyValue(key: "X-Tenant", value: "a")]
                $0.queryParams = [RelayKeyValue(key: "v", value: "1")]
            },
            Self.board(relay) { $0.transport = .anthropicMessages },
            Self.board(Self.localProvider(engine: "llamacpp", securityMode: .localHTTP)),
            Self.board(Self.localProvider(securityMode: .remoteHTTPS)),
        ]
        for board in boards {
            use([board.actionBar.secondaryKey], .providers)
            for group in board.groups {
                use([group.titleKey] + Self.keys(in: group.trailing), .providers)
                for row in group.rows {
                    use([row.titleKey], Board.titleTable(for: row))
                    use(Self.keys(in: row.value) + Self.keys(in: row.footnote), .providers)
                }
            }
        }
        // The primary button in two states: the title key and the table it actually lives in.
        for action in [RelayEditPrimaryAction.save, .validateAndSave] {
            use([action.titleKey], action.titleTable)
        }
        for status in [Board.Status.testing, .reconnecting, .verified] {
            use(Self.keys(in: Board.statusRow(status).message), .providers)
        }

        var catalogs: [String: [String: Set<String>]] = [:]
        for (key, table) in used {
            if catalogs[table.rawValue] == nil { catalogs[table.rawValue] = try Self.catalog(table) }
            let translated = try #require(catalogs[table.rawValue]?[key], "the \(table.rawValue) table has no key \"\(key)\", so the UI would fall back to English")
            // en may be omitted (the key is the English source text); the other 15 languages must have a value.
            let missing = Set(Self.locales).subtracting(["en"]).subtracting(translated)
            #expect(missing.isEmpty, "\(table.rawValue) \"\(key)\" is missing \(missing.sorted())")
        }
        #expect(used.contains { $0.key == "Save" && $0.table == .localizable })
    }

    // MARK: - BOARD-EDIT-11

    @Test("BOARD-EDIT-11 The primary button and the save path give the same answer to \"did the address change\": a difference only in scheme / leading or trailing whitespace / trailing slash sends no verification, a real change does")
    func boardEdit11PrimaryActionMatchesSavePath() throws {
        // The save path's criterion: `RelayEditView.save` first normalizes the address, then asks the normalized draft whether verification is needed.
        func savePathVerifies(_ provider: Provider, _ editor: Editor) throws -> Bool {
            let normalized = try RelayEndpointPolicy.requireConfigured(
                editor.endpoint.trimmingCharacters(in: .whitespacesAndNewlines),
                securityMode: editor.securityMode
            )
            return RelayEditSavePolicy.clearsCatalogBeforeVerification(
                from: provider,
                editor: RelayEditSavePolicy.normalizedDraft(editor, normalizedEndpoint: normalized)
            )
        }

        // Stored: https://api.myrelay.dev
        let provider = Self.relayProvider(transport: .openaiChatCompletions)
        let cases: [(String, String, RelayEditPrimaryAction)] = [
            ("only the scheme differs", "api.myrelay.dev", .save),
            ("only leading/trailing whitespace differs", "  https://api.myrelay.dev \n", .save),
            ("only the trailing slash differs", "https://api.myrelay.dev/", .save),
            ("the host really changed", "https://relay-2.example.com", .validateAndSave),
            ("the path changed", "api.myrelay.dev/v1", .validateAndSave),
        ]
        for (name, endpoint, expected) in cases {
            var editor = Editor(from: provider)
            editor.endpoint = endpoint
            // Primary button: the row model is asked with the raw text on screen.
            let button = Board.make(provider: provider, editor: editor).actionBar.primary
            let savePath = try savePathVerifies(provider, editor)
            #expect(button == expected, "\(name): primary button")
            #expect(savePath == (expected == .validateAndSave), "\(name): save path")
        }

        // The other direction: the stored address has a trailing slash and the user changed nothing — the button says "Save", and the save path must not send a verification either.
        var legacy = provider
        legacy.baseURLText = "https://api.myrelay.dev/"
        let untouched = Editor(from: legacy)
        #expect(Board.make(provider: legacy, editor: untouched).actionBar.primary == .save)
        #expect(try savePathVerifies(legacy, untouched) == false)

        // A local plaintext connection gets its scheme filled in by its own connection security: omitting http:// likewise does not count as changing the address.
        let local = Self.localProvider()
        var localEditor = Editor(from: local)
        localEditor.endpoint = "192.168.1.20:8080"
        #expect(Board.make(provider: local, editor: localEditor).actionBar.primary == .save)
        #expect(try savePathVerifies(local, localEditor) == false)
    }

    // MARK: - BOARD-EDIT-12

    @Test("BOARD-EDIT-12 Validation notes for headers / query params appear under the matching row in the headers group and expand a collapsed group; the other notes stay under the connection card")
    func boardEdit12HeaderIssuesLiveInTheirGroup() throws {
        // Plaintext connection with no key, yet a header carrying credentials is filled in: shared validation attributes the problem to the headers.
        var provider = TestFactories.makeProvider(
            kind: .relay,
            models: [Self.model("qwen3-8b-q4")],
            catalogModels: [Self.model("qwen3-8b-q4")],
            apiKey: "",
            apiKeyPreview: "",
            baseURLText: "http://192.168.1.20:8080"
        )
        provider.relayRequested = RelayRequestedConfig(
            transport: .openaiChatCompletions,
            authMode: RelayAuthMode.none,
            securityMode: .localHTTP
        )
        func make(_ mutate: (inout Editor) -> Void) -> (Board, [RelayFormValidation.FieldIssue]) {
            var editor = Editor(from: provider)
            mutate(&editor)
            // The same function the page uses to get the validation result.
            let issues = RelayEditView.formIssues(for: provider, editor: editor)
            return (Board.make(provider: provider, editor: editor, hasFormIssues: !issues.isEmpty, issues: issues), issues)
        }

        // No problem: the headers group stays collapsed by default and expands only when the user opens it.
        let (clean, cleanIssues) = make { $0.headers = [RelayKeyValue(key: "X-Trace", value: "1")] }
        #expect(cleanIssues.isEmpty)
        let cleanHeaders = try Self.group(clean, .headers)
        #expect(cleanHeaders.issues.isEmpty)
        #expect(!cleanHeaders.isExpanded(userChoice: nil))
        #expect(cleanHeaders.isExpanded(userChoice: true))
        #expect(clean.connectionIssues.isEmpty)

        // A header carries credentials: the note goes into the headers group, under the last header row; the group is forced open and the user can't collapse it.
        let (header, headerIssues) = make {
            $0.headers = [RelayKeyValue(key: "X-Trace", value: "1"), RelayKeyValue(key: "Authorization", value: "Bearer x")]
            $0.queryParams = [RelayKeyValue(key: "v", value: "1")]
        }
        #expect(headerIssues == [RelayFormValidation.FieldIssue(
            field: .headers, code: .cleartextCredentials, detail: "cleartext_credentials"
        )])
        let headerGroup = try Self.group(header, .headers)
        #expect(headerGroup.startsExpanded == false)
        #expect(headerGroup.issues == headerIssues)
        #expect(headerGroup.isExpanded(userChoice: nil))
        #expect(headerGroup.isExpanded(userChoice: false))
        #expect(headerGroup.rows.map(\.id) == [.userAgent, .header, .header, .queryParam, .addEntry])
        #expect(headerGroup.rows.indices.map { headerGroup.notes(belowRowAt: $0).count } == [0, 0, 1, 0, 0])
        #expect(header.connectionIssues.isEmpty)
        #expect(!header.actionBar.isPrimaryEnabled)

        // A query param carries credentials: it appears under the last query param row.
        let (query, queryIssues) = make {
            $0.headers = [RelayKeyValue(key: "X-Trace", value: "1")]
            $0.queryParams = [RelayKeyValue(key: "v", value: "1"), RelayKeyValue(key: "api_key", value: "k")]
        }
        #expect(queryIssues.map(\.field) == [.queryParams])
        let queryGroup = try Self.group(query, .headers)
        #expect(queryGroup.rows.map(\.id) == [.userAgent, .header, .queryParam, .queryParam, .addEntry])
        #expect(queryGroup.rows.indices.map { queryGroup.notes(belowRowAt: $0).count } == [0, 0, 0, 1, 0])
        #expect(queryGroup.isExpanded(userChoice: false))

        // Address-type problems don't go into the headers group and don't force it open.
        let (address, addressIssues) = make { $0.endpoint = "ftp://192.168.1.20" }
        #expect(addressIssues.map(\.field) == [.endpoint])
        #expect(address.connectionIssues == addressIssues)
        #expect(try Self.group(address, .headers).issues.isEmpty)
        #expect(try Self.group(address, .headers).isExpanded(userChoice: nil) == false)

        // The local plaintext connection page has no headers group: the same note stays under the connection card and can't disappear along with the group.
        let local = Self.localProvider()
        var localEditor = Editor(from: local)
        localEditor.headers = [RelayKeyValue(key: "Authorization", value: "Bearer x")]
        let localIssues = RelayEditView.formIssues(for: local, editor: localEditor)
        #expect(localIssues.map(\.field) == [.headers])
        let localBoard = Board.make(provider: local, editor: localEditor, hasFormIssues: true, issues: localIssues)
        #expect(!localBoard.groups.contains { $0.id == .headers })
        #expect(localBoard.connectionIssues == localIssues)

        // The view renders from the row model: whether a group is expanded and the notes under rows are asked of the group; under the connection card only the notes outside the group appear.
        let view = try String(contentsOf: Self.providerSource("RelayEditBoardView.swift"), encoding: .utf8)
        #expect(view.contains("group.isExpanded(userChoice: expansion[group.id])"))
        #expect(view.contains("group.notes(belowRowAt: index)"))
        let page = try String(contentsOf: Self.providerSource("RelayEditView.swift"), encoding: .utf8)
        #expect(page.contains("issues: board.connectionIssues"))
    }

    // MARK: - BOARD-EDIT-13

    @Test("BOARD-EDIT-13 The root address probed before saving: kept if the address didn't change, including when a local connection uses a hostname (localhost / *.local); invalidated only when the address really changed")
    func boardEdit13DiscoveredRootSurvivesSaveWhenAddressUnchanged() throws {
        let tablesKey = RelayTransport.openaiChatCompletions.rawValue
        // (stored address, how the user wrote it in the address slot): the latter are all just another way of writing the same address.
        let unchanged: [(String, String)] = [
            ("http://192.168.1.20:8080", "http://192.168.1.20:8080"),
            ("http://localhost:11434", "http://localhost:11434"),
            ("http://localhost:11434", "  localhost:11434/ "),
            ("http://my-mac.local:11434", "http://my-mac.local:11434"),
        ]
        for (stored, typed) in unchanged {
            var provider = Self.localProvider()
            provider.baseURLText = stored
            provider.relayRequested?.resolvedAPIBaseURL = "\(stored)/v1"
            provider.relayRequested?.resolvedAPIBaseURLs = [tablesKey: "\(stored)/v1"]
            var editor = Editor(from: provider)
            editor.endpoint = typed
            // Save path: first normalize the address, then `savedRequested` decides whether to keep the root address.
            let normalized = try RelayEndpointPolicy.requireConfigured(
                typed.trimmingCharacters(in: .whitespacesAndNewlines),
                securityMode: editor.securityMode
            )
            #expect(normalized == stored, "\(typed)")
            let saved = RelayEditSavePolicy.savedRequested(editor: editor, provider: provider, normalizedEndpoint: normalized)
            #expect(saved.resolvedAPIBaseURL == "\(stored)/v1", "\(stored) ← \(typed)")
            #expect(saved.resolvedAPIBaseURLs == [tablesKey: "\(stored)/v1"], "\(stored) ← \(typed)")
            // The same answer as the primary button / save classification: unchanged.
            #expect(!RelayEditSavePolicy.endpointChanged(from: provider, editor: editor), "\(stored) ← \(typed)")
        }

        // The address really changed: the root probed on the old address no longer holds.
        var provider = Self.localProvider()
        provider.baseURLText = "http://localhost:11434"
        provider.relayRequested?.resolvedAPIBaseURL = "http://localhost:11434/v1"
        provider.relayRequested?.resolvedAPIBaseURLs = [tablesKey: "http://localhost:11434/v1"]
        var editor = Editor(from: provider)
        editor.endpoint = "http://localhost:8080"
        let saved = RelayEditSavePolicy.savedRequested(
            editor: editor, provider: provider, normalizedEndpoint: "http://localhost:8080"
        )
        #expect(saved.resolvedAPIBaseURL == nil)
        #expect(saved.resolvedAPIBaseURLs == nil)
        #expect(RelayEditSavePolicy.endpointChanged(from: provider, editor: editor))
    }

    // MARK: - BOARD-EDIT-14

    @Test("BOARD-EDIT-14 The status row and the failure card for Test connection / reconnect use the same reveal behavior: dismiss the keyboard and scroll only when one appears or its result changes")
    func boardEdit14StatusRowReveal() throws {
        typealias Reveal = RelayFailureCardReveal
        // Test connection tapped: the in-progress row appears → reveal; when the result comes back and replaces it with another → reveal again.
        #expect(Reveal.shouldReveal(previous: nil, current: Board.Status.testing))
        #expect(Reveal.shouldReveal(previous: Board.Status.testing, current: Board.Status.verified))
        #expect(Reveal.shouldReveal(previous: Board.Status.testing, current: Board.Status.failed("x")))
        // The same status doesn't scroll again; after the address changes, the status row is dismissed and doesn't scroll.
        #expect(!Reveal.shouldReveal(previous: Board.Status.verified, current: Board.Status.verified))
        #expect(!Reveal.shouldReveal(previous: Board.Status.failed("x"), current: Optional<Board.Status>.none))
        #expect(Reveal.statusAnchorID != Reveal.anchorID)

        let page = try String(contentsOf: Self.providerSource("RelayEditView.swift"), encoding: .utf8)
        #expect(page.contains(".id(RelayFailureCardReveal.statusAnchorID)"))
        #expect(page.contains(".onChange(of: status)"))
        #expect(page.contains("anchor: RelayFailureCardReveal.statusAnchorID"))
    }

    // MARK: - BOARD-EDIT-15

    @Test("BOARD-EDIT-15 Compatibility group: items that are in effect still show — when the default protocol is not auto / Responses, the \"don't keep responses\" switch that is on in storage or in the draft, and a filled service tier, remain visible and can be turned off")
    func boardEdit15CompatibilityKeepsSettingsInEffect() throws {
        func rows(_ provider: Provider, _ mutate: (inout Editor) -> Void = { _ in }) throws -> [Board.RowID] {
            try Self.group(Self.board(provider, mutate), .compatibility).rows.map(\.id)
        }

        // Stored: the connection was originally built with auto / Responses (both items are stored), and the default protocol was later changed to something else.
        // Models on this connection that use Responses themselves still go out with store:false and service_tier.
        for transport in [RelayTransport.anthropicMessages, .geminiGenerateContent] {
            var stored = Self.relayProvider(transport: transport)
            stored.relayRequested?.disableResponseStorage = true
            stored.relayRequested?.serviceTier = "flex"
            #expect(try rows(stored) == [.stream, .serviceTier, .disableResponseStorage], "\(transport.rawValue)")
            // After turning off / clearing and before saving, the row stays (the stored value is still in effect), so the user doesn't tap once and lose the row.
            #expect(try rows(stored) {
                $0.disableResponseStorage = false
                $0.serviceTier = ""
            } == [.stream, .serviceTier, .disableResponseStorage], "\(transport.rawValue)")
            // Turn off and save: the stored value is cleared, and next time the page opens, the rows are trimmed by the default protocol.
            var draft = Editor(from: stored)
            draft.disableResponseStorage = false
            draft.serviceTier = " "
            var saved = stored
            saved.relayRequested = RelayEditSavePolicy.savedRequested(
                editor: draft, provider: stored, normalizedEndpoint: stored.baseURLText ?? ""
            )
            #expect(saved.relayRequested?.disableResponseStorage == nil)
            #expect(saved.relayRequested?.serviceTier == nil)
            #expect(try rows(saved) == [.stream], "\(transport.rawValue)")
        }

        // Chat default: the service tier is shown anyway; when "don't keep responses" is on in storage, this row shows too.
        var chat = Self.relayProvider(transport: .openaiChatCompletions)
        chat.relayRequested?.disableResponseStorage = true
        #expect(try rows(chat) == [.stream, .serviceTier, .disableResponseStorage])

        // Draft: turned on under auto, then the default protocol is switched to Messages — this row must not silently vanish while still "on" and then get saved.
        let auto = Self.relayProvider(transport: .auto)
        #expect(try rows(auto) {
            $0.disableResponseStorage = true
            $0.serviceTier = "priority"
            $0.transport = .anthropicMessages
        } == [.stream, .serviceTier, .disableResponseStorage])

        // No value in effect: the trimming rule works as before.
        #expect(try rows(auto) { $0.transport = .anthropicMessages } == [.stream])
        #expect(try rows(auto) { $0.transport = .openaiChatCompletions } == [.stream, .serviceTier])
        #expect(Board.compatibilityRows(for: .anthropicMessages, serviceTierInEffect: true) == [.stream, .serviceTier])
        #expect(Board.compatibilityRows(for: .anthropicMessages, responseStorageDisabled: true) == [.stream, .disableResponseStorage])
    }

    // MARK: - BOARD-EDIT-16

    @Test("BOARD-EDIT-16 A Test connection result arriving late: when the in-flight one is replaced in place by the result, neither dismiss the keyboard nor scroll; one that appears only after a tap is revealed as before")
    func boardEdit16LateResultKeepsFocus() throws {
        // Result lands: the user may be typing in another slot, so the keyboard must not be dismissed.
        #expect(!Board.revealsStatusRow(previous: .testing, current: .verified))
        #expect(!Board.revealsStatusRow(previous: .testing, current: .failed("x")))
        #expect(!Board.revealsStatusRow(previous: .reconnecting, current: .verified))
        #expect(!Board.revealsStatusRow(previous: .reconnecting, current: .failed("x")))
        // Test connection tapped / test again / a failure judged right on tap: reveal as before.
        #expect(Board.revealsStatusRow(previous: nil, current: .testing))
        #expect(Board.revealsStatusRow(previous: .verified, current: .testing))
        #expect(Board.revealsStatusRow(previous: .failed("x"), current: .testing))
        #expect(Board.revealsStatusRow(previous: nil, current: .failed("x")))
        #expect(Board.revealsStatusRow(previous: nil, current: .reconnecting))
        // Dismissed / unchanged: no scroll.
        #expect(!Board.revealsStatusRow(previous: .verified, current: nil))
        #expect(!Board.revealsStatusRow(previous: .testing, current: .testing))

        let page = try String(contentsOf: Self.providerSource("RelayEditView.swift"), encoding: .utf8)
        #expect(page.contains("guard RelayEditBoardModel.revealsStatusRow(previous: previous, current: current) else { return }"))
    }

    // MARK: - BOARD-EDIT-17

    @Test("BOARD-EDIT-17 A collapsible group forced open by a validation note: tapping the group header during that time isn't recorded as collapsing, it stays open after the fix; with no note, tapping the header toggles as usual")
    func boardEdit17TapWhileIssuesDoesNotCollapseAfterFix() throws {
        let issue = RelayFormValidation.FieldIssue(field: .headers, code: .cleartextCredentials, detail: "cleartext_credentials")
        let held = Board.Group(
            id: .headers, titleKey: Board.headersGroupKey, isCollapsible: true, startsExpanded: false,
            rows: [], issues: [issue]
        )
        let fixed = Board.Group(
            id: .headers, titleKey: Board.headersGroupKey, isCollapsible: true, startsExpanded: false, rows: []
        )
        // Tapping the header while forced open (the view used to record !expanded = false): what is recorded is still expanded.
        #expect(held.userChoiceAfterTap(nil))
        #expect(held.userChoiceAfterTap(true))
        let choice = held.userChoiceAfterTap(nil)
        #expect(fixed.isExpanded(userChoice: choice), "must not collapse in front of the user after the fix")
        // No note: toggles as usual.
        #expect(fixed.userChoiceAfterTap(nil))
        #expect(!fixed.userChoiceAfterTap(true))

        let view = try String(contentsOf: Self.providerSource("RelayEditBoardView.swift"), encoding: .utf8)
        #expect(view.contains("group.userChoiceAfterTap(expansion[group.id])"))
        #expect(!view.contains("expansion[group.id] = !expanded"))
    }

    // MARK: - BOARD-EDIT-18

    @Test("BOARD-EDIT-18 Compatibility group: a row that appeared during this edit stays after the draft turns it off / clears it, until the user leaves the page")
    func boardEdit18CompatibilityRowsStayForTheSession() throws {
        // Under auto, turn on "don't keep responses" and fill the service tier, then switch the default protocol to Messages: both rows show because the draft has them on.
        let auto = Self.relayProvider(transport: .auto)
        var editor = Editor(from: auto)
        editor.disableResponseStorage = true
        editor.serviceTier = "priority"
        editor.transport = .anthropicMessages
        #expect(try Self.group(Board.make(provider: auto, editor: editor), .compatibility).rows.map(\.id)
            == [.stream, .serviceTier, .disableResponseStorage])
        let shown = Board.draftCompatibilityRows(editor)
        #expect(shown == [.serviceTier, .disableResponseStorage])

        // The user turns them off / clears them on this page: the page brings back the items the draft has turned on as an argument, and the rows don't disappear.
        editor.disableResponseStorage = false
        editor.serviceTier = ""
        #expect(Board.draftCompatibilityRows(editor).isEmpty)
        let kept = Board.make(provider: auto, editor: editor, shownCompatibilityRows: shown)
        #expect(try Self.group(kept, .compatibility).rows.map(\.id) == [.stream, .serviceTier, .disableResponseStorage])
        // Newly entered page (no row has appeared): trimmed by the default protocol.
        #expect(try Self.group(Board.make(provider: auto, editor: editor), .compatibility).rows.map(\.id) == [.stream])
        #expect(Board.compatibilityRows(for: .anthropicMessages, alreadyShown: [.serviceTier]) == [.stream, .serviceTier])
        // Only seen under auto and never turned on: switching to Messages still trims them (a draft that never had them on doesn't enter the argument).
        #expect(Board.draftCompatibilityRows(Editor(from: auto)).isEmpty)

        let page = try String(contentsOf: Self.providerSource("RelayEditView.swift"), encoding: .utf8)
        #expect(page.contains("shownCompatibilityRows: shownCompatibilityRows"))
        #expect(page.contains("shownCompatibilityRows.formUnion(shown)"))
    }

    // MARK: - Fix regressions (save path)

    @Test("Address needs normalizing + verification fails + tap \"Save anyway (unverified)\" → persisted")
    func unverifiedSavePersistsWhenEndpointWasNormalized() throws {
        let provider = Self.relayProvider(transport: .openaiChatCompletions)
        var draft = Editor(from: provider)
        // The user wrote no scheme: it is normalized on save and written back to the address slot on screen.
        draft.endpoint = "relay-2.example.com/v1"
        let normalized = try #require(RelayEndpointPolicy.normalize(draft.endpoint, securityMode: draft.securityMode))
        #expect(normalized != draft.endpoint)

        let normalizedDraft = RelayEditSavePolicy.normalizedDraft(draft, normalizedEndpoint: normalized)
        var candidate = provider
        candidate.baseURLText = normalized
        candidate.relayRequested = RelayEditSavePolicy.savedRequested(
            editor: normalizedDraft, provider: provider, normalizedEndpoint: normalized
        )
        let pending = RelayEditSavePolicy.unverifiedCandidate(candidate, base: provider, draft: normalizedDraft)

        // The editor on screen right now: the address slot was written back with the normalized address, and the other fields are untouched.
        var onScreen = draft
        onScreen.endpoint = normalized
        #expect(RelayEditUnverifiedSavePolicy.mayPersist(
            candidateProviderID: pending.provider.id,
            editorSnapshot: pending.editorSnapshot,
            currentEditor: onScreen,
            currentProviderID: provider.id,
            targetProviderID: provider.id
        ))
        // Root cause: if the snapshot took the draft from before normalization, the commit gate would judge it unequal, the failure card would vanish and nothing would be stored.
        #expect(!RelayEditUnverifiedSavePolicy.mayPersist(
            candidateProviderID: pending.provider.id,
            editorSnapshot: draft,
            currentEditor: onScreen,
            currentProviderID: provider.id,
            targetProviderID: provider.id
        ))

        // Persisted: the address is the normalized one, and the status is "unverified".
        let state = AppState(seedDemoData: false, sessionUID: "relay-edit-unverified-\(UUID().uuidString)")
        state.providers = [provider]
        state.providerManager.updateProvider(pending.provider)
        let stored = try #require(state.provider(for: provider.id))
        #expect(stored.baseURLText == normalized)
        #expect(stored.status == .issue(ProviderIssueMessage.unverifiedConnectionKey))
        #expect(stored.lastCheckedAt == nil)
    }

    @Test("BOARD-EDIT-19 Save verification in flight: after continuing to edit / closing to discard / saving again / the connection being deleted, the old result must neither be persisted nor show a failure card")
    func inFlightVerificationResultIsDroppedWhenStale() {
        let provider = Self.relayProvider(transport: .openaiChatCompletions)
        var snapshot = Editor(from: provider)
        snapshot.endpoint = "https://relay-2.example.com/v1"
        func mayCommit(
            generation: Int = 3, current: Int = 3, editor: Editor?, providerID: UUID?
        ) -> Bool {
            RelayEditVerificationCommitPolicy.mayCommit(
                generation: generation,
                currentGeneration: current,
                snapshot: snapshot,
                currentEditor: editor,
                currentProviderID: providerID,
                targetProviderID: provider.id
            )
        }
        #expect(mayCommit(editor: snapshot, providerID: provider.id))

        // The user keeps editing while it is in flight: the draft on screen is no longer the one that started the verification.
        var edited = snapshot
        edited.headers = [RelayKeyValue(key: "X-Late", value: "1")]
        #expect(!mayCommit(editor: edited, providerID: provider.id))
        // Close to discard / save again: the generation has been invalidated.
        #expect(!mayCommit(generation: 3, current: 4, editor: snapshot, providerID: provider.id))
        // The connection was deleted or replaced.
        #expect(!mayCommit(editor: snapshot, providerID: nil))
        #expect(!mayCommit(editor: snapshot, providerID: UUID()))
        #expect(!mayCommit(editor: nil, providerID: provider.id))

        // View layer: the comparison target must be the state property, and the save path must not have a same-named local variable shadowing it.
        let source = (try? String(contentsOf: Self.providerSource("RelayEditView.swift"), encoding: .utf8)) ?? ""
        #expect(source.contains("RelayEditVerificationCommitPolicy.mayCommit("))
        #expect(!source.contains("guard let editor else { return }\n        isSaving = true"))
        #expect(!source.contains("editor == capturedEditor"))
    }

    @Test("A connection-security reconnect writes the root address back: it is recorded on the connection as stored right now, and changes persisted during the reconnect aren't overwritten by the old snapshot")
    func reconnectWritebackUsesLatestProvider() throws {
        // The snapshot from before the probe started.
        let snapshot = Self.relayProvider(transport: .openaiChatCompletions)
        // While the probe is in flight, the stored connection changed again (headers persisted elsewhere, a renamed name).
        var latest = snapshot
        latest.customName = "Renamed while reconnecting"
        latest.relayRequested?.headers = [RelayKeyValue(key: "X-Saved-Meanwhile", value: "1")]

        let written = try #require(RelayEditSavePolicy.recordingDiscoveredRoot(
            "https://api.myrelay.dev/v1", discovered: .openaiChatCompletions, onto: latest
        ))
        #expect(written.relayRequested?.resolvedAPIBaseURL == "https://api.myrelay.dev/v1")
        #expect(written.relayRequested?.headers == [RelayKeyValue(key: "X-Saved-Meanwhile", value: "1")])
        #expect(written.customName == "Renamed while reconnecting")
        // Field by field equal to what is stored right now, except for the root address.
        var expected = latest
        expected.relayRequested?.resolvedAPIBaseURL = "https://api.myrelay.dev/v1"
        #expect(written.relayRequested == expected.relayRequested)

        var noConfig = latest
        noConfig.relayRequested = nil
        #expect(RelayEditSavePolicy.recordingDiscoveredRoot("https://x/v1", discovered: .auto, onto: noConfig) == nil)

        // View layer: the write-back uses the connection fetched anew, and a reconnect in flight does not enter the save.
        let source = try String(contentsOf: Self.providerSource("RelayEditView.swift"), encoding: .utf8)
        #expect(source.contains("RelayEditSavePolicy.recordingDiscoveredRoot("))
        #expect(!source.contains("appState.providerManager.updateProvider(current)"))
        #expect(source.contains("status != .reconnecting else { return }"))
    }

    // MARK: - RL2-EDITFAIL-01 (same name on all three platforms; iOS is the golden reference)

    @Test("RL2-EDITFAIL-01 Failure card for a failed edit-connection verification: warning tone, title = the error kind's title, localized guidance body without the upstream raw text, and the primary button is still Save (unverified)")
    func editFailureCardFollowsErrorKind() {
        let upstream = "invalid_api_key | invalid_request_error | Invalid API key provided."
        let card = RelayEditFailurePresentation.error(
            from: ProviderServiceError.invalidAPIKey(detail: upstream),
            provider: Self.relayProvider()
        )
        #expect(card.severity == .warning)
        #expect(card.title == ProviderServiceError.invalidAPIKey(detail: upstream).title)
        #expect(!card.message.contains("invalid_request_error"))
        #expect(card.actionTitle == L10n.tr("Save anyway (unverified)", table: .providers))
        #expect(card.detail.contains("invalid_request_error"))
    }

    // MARK: - Fix regressions (accessibility and plurals)

    @Test("The address slot's VoiceOver value carries the scheme: the chip is a hidden decoration, and the value lets http / https be read out")
    func spokenAddressCarriesScheme() throws {
        #expect(Board.spokenAddress("api.myrelay.dev/v1", securityMode: .remoteHTTPS) == "https://api.myrelay.dev/v1")
        #expect(Board.spokenAddress("192.168.1.20:8080", securityMode: .localHTTP) == "http://192.168.1.20:8080")
        #expect(Board.spokenAddress("100.64.0.2:11434", securityMode: .privateVPN) == "http://100.64.0.2:11434")
        // The user wrote a scheme themselves: what the user wrote wins, and no default is prepended.
        #expect(Board.spokenAddress(" http://10.0.0.2:1234 ", securityMode: .remoteHTTPS) == "http://10.0.0.2:1234")
        #expect(Board.spokenAddress("   ", securityMode: .remoteHTTPS) == "")

        let source = try String(contentsOf: Self.providerSource("RelayEditBoardView.swift"), encoding: .utf8)
        #expect(source.contains(".accessibilityValue(Board.spokenAddress(endpoint, securityMode: securityMode))"))
    }

    @Test("The filled count takes the plural variant by quantity: the production approach (String(format:) + the format string in the table) is right for singular and plural in fr / es / hi")
    func filledCountResolvesPluralVariations() throws {
        // The same lookup as L10n.tr: the Providers table inside <locale>.lproj compiled into the app.
        func resolver(_ locale: String) throws -> (String, L10n.Table) -> String {
            let path = try #require(Bundle.main.path(forResource: locale, ofType: "lproj"), "the app bundle lacks \(locale).lproj")
            let bundle = try #require(Bundle(path: path))
            return { key, table in bundle.localizedString(forKey: key, value: key, table: table.rawValue) }
        }
        // Expected values come straight from the one / other variants in the production copy resources (translations get rewritten by native-speaker review, so none is copied here).
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Oriveo/Providers.xcstrings")
        let root = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let entry = try #require((root["strings"] as? [String: Any])?["%lld set"] as? [String: Any])
        let localizations = try #require(entry["localizations"] as? [String: Any])
        func variant(_ locale: String, _ category: String) throws -> String {
            let plural = ((localizations[locale] as? [String: Any])?["variations"] as? [String: Any])?["plural"] as? [String: Any]
            let unit = (plural?[category] as? [String: Any])?["stringUnit"] as? [String: Any]
            return try #require(unit?["value"] as? String, "\(locale) lacks the \(category) variant")
        }
        var distinctForms = 0
        // For these languages, 1 takes one and 3 takes other.
        for locale in ["fr", "es", "pt-BR", "hi", "de", "en"] {
            let tr = try resolver(locale)
            let one = try variant(locale, "one")
            let other = try variant(locale, "other")
            #expect(Board.string(.count("%lld set", 1), tr: tr) == one.replacingOccurrences(of: "%lld", with: "1"), "\(locale) × 1")
            #expect(Board.string(.count("%lld set", 3), tr: tr) == other.replacingOccurrences(of: "%lld", with: "3"), "\(locale) × 3")
            if one != other { distinctForms += 1 }
        }
        // At least one language must differ between singular and plural, otherwise the assertions above can't prove that "the variant was taken".
        #expect(distinctForms > 0)
        #expect(Board.string(.count("%lld set", 3), tr: try resolver("zh-Hans"))
            == (try variant("zh-Hans", "other")).replacingOccurrences(of: "%lld", with: "3"))
        // Other plural keys in the same table use the same approach, which also bears witness: in fr, "%lld more" differs between singular and plural.
        let fr = try resolver("fr")
        #expect(Board.string(.count("%lld more", 1), tr: fr) == "1 autre")
        #expect(Board.string(.count("%lld more", 2), tr: fr) == "2 autres")
    }
}
