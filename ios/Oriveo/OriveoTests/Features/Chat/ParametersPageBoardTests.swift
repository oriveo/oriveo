import Foundation
import Testing
@testable import Oriveo

/// Board comparison for the `AdvancedSettings` / `ModelOptions` parameter cards (cases of the same name on all three platforms, BOARD-PARAMS-01 to 05).
///
/// Maintenance item placement is decided by the production layout function `GenerationParameterMaintenanceBlock.visible`, and assertions read its output directly;
/// only facts a SwiftUI `body` cannot expose, such as which block comes before which on the page, fall back to source order.
@Suite("Parameters page board comparison")
struct ParametersPageBoardTests {
    private static let supportedLocales: Set<String> = [
        "ar", "de", "en", "es", "fr", "hi", "id", "ja",
        "ko", "pt-BR", "ru", "th", "tr", "vi", "zh-Hans", "zh-Hant",
    ]

    // MARK: - BOARD-PARAMS-01

    @Test("BOARD-PARAMS-01 the parameters page title and every entry are named Parameters; production code no longer references the old key")
    func test_BOARD_PARAMS_01_titleAndEntriesShareParametersName() throws {
        let providers = try Self.catalog("Providers")
        #expect(providers["Parameters"]?["en"] == "Parameters")

        let parametersCall = "L10n.tr(\"Parameters\", table: .providers)"
        // Both forms of the parameters page: title, parameter-card entry row, missing-model fallback row, provider settings row, and the capability page's back-link title.
        let consumers: [(path: [String], count: Int)] = [
            (["Features", "Chat", "ModelControls", "AdvancedSettingsPage.swift"], 1),
            (["Features", "Providers", "GenerationParameterDefaultsSheet.swift"], 1),
            (["Features", "Chat", "ModelControls", "ModelControlsSheet.swift"], 2),
            (["Features", "Chat", "ModelControls", "CapabilitySupportedModelsPage.swift"], 1),
            (["Features", "Providers", "ProviderSettingsSection.swift"], 1),
        ]
        for consumer in consumers {
            let source = try Self.source(consumer.path)
            let name = consumer.path.last ?? ""
            #expect(
                source.components(separatedBy: parametersCall).count - 1 >= consumer.count,
                "\(name) parameters page entry was not switched to Parameters"
            )
            #expect(!source.contains("L10n.tr(\"Advanced Settings\")"), "\(name) still references the old title")
            #expect(!source.contains("\"Go to Advanced Settings\""), "\(name) still references the old jump text")
        }
        // The skill editor's "Advanced settings" is a different thing and stays.
        #expect(try Self.source(["Features", "Skills", "SkillEditView.swift"]).contains("L10n.tr(\"Advanced Settings\")"))

        // The link in the capability description that jumps to the parameters page.
        let chat = try Self.catalog("Chat")
        #expect(chat["Go to Parameters"]?["en"] == "Go to Parameters")
        #expect(chat["Go to Advanced Settings"] == nil, "Once no call sites remain, the old jump text should be removed from all 16 languages")
        let sheet = try Self.source(["Features", "Chat", "ModelControls", "ModelControlsSheet.swift"])
        #expect(sheet.contains("L10n.tr(\"Go to Parameters\", table: .chat)"))

        // The enum case that points at the parameters page is renamed to parameters (contract item 4).
        #expect(ProviderSettingsRow.allCases.contains(.parameters))
        #expect(!ProviderSettingsRow.allCases.map(\.rawValue).contains("modelBehavior"))
        #expect(sheet.contains("case parameters\n    case additionalRequestBody"))
    }

    // MARK: - BOARD-PARAMS-02

    @Test("BOARD-PARAMS-02 connection scope: the five maintenance blocks are folded into a More group at the page end, appearing after Developer in order")
    func test_BOARD_PARAMS_02_maintenanceBlocksFoldUnderTrailingMore() throws {
        // Production layout function: the order when all five blocks are visible.
        let all = GenerationParameterMaintenanceBlock.visible(
            showsConnectionTools: true,
            hasProfileFingerprint: true,
            isConnectionScope: true,
            canViewDiagnosticsHistory: true,
            hasCompatibilityConflicts: true,
            isCustomLLMRelay: true
        )
        #expect(all == [.presets, .connection, .diagnosticRecords, .compatibility, .clearLearnedCapabilities])

        // Each block keeps its own visibility condition: when only diagnostics is visible, it is the only block.
        let onlyDiagnostics = GenerationParameterMaintenanceBlock.visible(
            showsConnectionTools: true,
            hasProfileFingerprint: false,
            isConnectionScope: false,
            canViewDiagnosticsHistory: true,
            hasCompatibilityConflicts: false,
            isCustomLLMRelay: false
        )
        #expect(onlyDiagnostics == [.diagnosticRecords])

        // Session scope (no connection-level tools) with a conflict: there is no More row.
        let sessionScope = GenerationParameterMaintenanceBlock.visible(
            showsConnectionTools: false,
            hasProfileFingerprint: true,
            isConnectionScope: false,
            canViewDiagnosticsHistory: true,
            hasCompatibilityConflicts: true,
            isCustomLLMRelay: true
        )
        #expect(sessionScope.isEmpty)
        // sheetEditor renders only in the `.sheet` form; `.embeddedPage` (session scope) is handed to an AdvancedSettingsPage that has no maintenance items.
        let sheetSource = try Self.source(["Features", "Providers", "GenerationParameterDefaultsSheet.swift"])
        #expect(sheetSource.contains("if presentation == .embeddedPage {\n            AdvancedSettingsPage("))

        // None of the five blocks visible -> no More row.
        let none = GenerationParameterMaintenanceBlock.visible(
            showsConnectionTools: true,
            hasProfileFingerprint: false,
            isConnectionScope: false,
            canViewDiagnosticsHistory: false,
            hasCompatibilityConflicts: false,
            isCustomLLMRelay: false
        )
        #expect(none.isEmpty)

        // Page order: parameter group -> reset -> Developer -> More row -> five blocks.
        let sheet = try Self.source(["Features", "Providers", "GenerationParameterDefaultsSheet.swift"])
        let editor = try #require(Self.slice(sheet, from: "private var sheetEditor: some View {", to: "// MARK: - Developer group"))
        let markers = [
            "AdvancedSettingsLayout.sections(parameters:",
            "Button(resetScope.confirmButtonTitle, role: .destructive)",
            "Text(L10n.tr(\"Developer\", table: .providers))",
            "if !maintenanceBlocks.isEmpty {",
            "L10n.tr(\"More\", table: .chat)",
            "if maintenanceExpanded {",
            "Section(L10n.tr(\"Presets\", table: .providers))",
            "Section(L10n.tr(\"Connection\", table: .providers))",
            "if maintenanceBlocks.contains(.compatibility) {\n                            compatibilitySection",
            "L10n.tr(\"Clear learned capabilities\", table: .providers)",
        ]
        let positions = try markers.map { marker in
            try #require(editor.range(of: marker), "\(marker) not found in sheetEditor").lowerBound
        }
        #expect(positions == positions.sorted(), "The parameters page order deviates from the board")
        // Each block appears only once: no old copy may remain before the parameter group.
        for marker in markers.dropFirst(6) {
            #expect(editor.components(separatedBy: marker).count == 2, "\(marker) appears more than once")
        }
        #expect(editor.components(separatedBy: "compatibilitySection\n").count - 1 == 1, "The compatibility group appears only once, inside More")
        #expect(sheet.components(separatedBy: "Section(L10n.tr(\"Compatibility\", table: .providers))").count == 2)
        // Collapsed by default, not persisted.
        #expect(sheet.contains("@State private var maintenanceExpanded = false"))
        #expect(!sheet.contains("@AppStorage(\"generation_params_more"))
    }

    // MARK: - BOARD-PARAMS-03

    @Test("BOARD-PARAMS-03 the chat-scope parameters page has no More maintenance row; group order is Basic -> More -> Write your own")
    func test_BOARD_PARAMS_03_chatScopeHasNoMaintenanceRow() throws {
        let sections = AdvancedSettingsLayout.sections(parameters: [
            Self.parameter("temperature"),
            Self.parameter("max_output_tokens", group: "budget"),
            Self.parameter("seed", group: "reproducibility"),
        ])
        #expect(sections.map(\.title) == [
            L10n.tr("Basic Settings", table: .providers),
            L10n.tr("More", table: .chat),
        ])

        let page = try Self.source(["Features", "Chat", "ModelControls", "AdvancedSettingsPage.swift"])
        let groups = try #require(page.range(of: "ForEach(AdvancedSettingsLayout.sections(parameters: catalog.parameters))"))
        let writeYourOwn = try #require(page.range(of: "                    additionalBodySection\n"))
        #expect(groups.lowerBound < writeYourOwn.lowerBound)
        #expect(page.contains("AdvancedSectionLabel(title: L10n.tr(\"Write your own\", table: .chat))"))
        for gone in [
            "GenerationParameterMaintenanceBlock",
            "maintenanceExpanded",
            "L10n.tr(\"Presets\", table: .providers)",
            "L10n.tr(\"Diagnostic records\")",
            "L10n.tr(\"Clear learned capabilities\", table: .providers)",
        ] {
            #expect(!page.contains(gone), "The chat-scope parameters page contains a maintenance item: \(gone)")
        }
    }

    // MARK: - BOARD-PARAMS-04

    @Test("BOARD-PARAMS-04 the edit-connection page's request header section title = Headers & query params")
    func test_BOARD_PARAMS_04_headersSectionTitle() throws {
        let providers = try Self.catalog("Providers")
        #expect(providers["Headers & query params"]?["en"] == "Headers & query params")
        #expect(Set(providers["Headers & query params"].map { Array($0.keys) } ?? []) == Self.supportedLocales)
        #expect(providers["Advanced HTTP"] == nil, "Once no call sites remain, the old section title should be removed from all 16 languages")

        // Only the edit-connection board still renders this group (the manual-settings collapsible group reuses the same rows).
        #expect(RelayEditBoardModel.headersGroupKey == "Headers & query params")
        var relay = TestFactories.makeProvider(kind: .relay, apiKey: "sk-test", baseURLText: "https://api.myrelay.dev")
        relay.relayRequested = RelayRequestedConfig(transport: .auto, authMode: .bearer)
        let board = RelayEditBoardModel.make(provider: relay, editor: RelayEditView.Editor(from: relay))
        #expect(board.groups.first { $0.id == .headers }?.titleKey == "Headers & query params")
    }

    // MARK: - BOARD-PARAMS-05

    @Test("BOARD-PARAMS-05 the two parameter-card rows are prefixed with a 22pt two-tone icon: thermometer-simple / sliders-horizontal")
    func test_BOARD_PARAMS_05_parametersCardLeadingIcons() throws {
        #expect(ModelOptionParametersLeadingIcon.temperature == .thermometerSimple)
        #expect(ModelOptionParametersLeadingIcon.parameters == .slidersHorizontal)
        #expect(ModelOptionParametersLeadingIcon.temperature.rawValue == "thermometer-simple")
        #expect(ModelOptionParametersLeadingIcon.parameters.rawValue == "sliders-horizontal")
        #expect(ModelOptionParametersLeadingIcon.weight == .duotone)
        #expect(ModelOptionParametersLeadingIcon.size == 22)
        #expect(ModelOptionParametersLeadingIcon.temperature.assetName(ModelOptionParametersLeadingIcon.weight)
            == "Phosphor/thermometer-simple-duotone")

        let sheet = try Self.source(["Features", "Chat", "ModelControls", "ModelControlsSheet.swift"])
        let card = try #require(Self.slice(sheet, from: "private var advancedCard: some View {", to: "// MARK: - Route"))
        let temperatureIcon = try #require(card.range(of: "ModelOptionParametersLeadingIcon(icon: ModelOptionParametersLeadingIcon.temperature)"))
        let temperatureTitle = try #require(card.range(of: "ModelOptionRowTitle(text: temperature.title)"))
        let parametersIcon = try #require(card.range(of: "ModelOptionParametersLeadingIcon(icon: ModelOptionParametersLeadingIcon.parameters)"))
        let parametersTitle = try #require(card.range(of: "ModelOptionRowTitle(text: L10n.tr(\"Parameters\", table: .providers))"))
        #expect(temperatureIcon.lowerBound < temperatureTitle.lowerBound)
        #expect(temperatureTitle.lowerBound < parametersIcon.lowerBound)
        #expect(parametersIcon.lowerBound < parametersTitle.lowerBound)

        // Neutral secondary color, not a capability color.
        let components = try Self.source(["Features", "Chat", "ModelControls", "ModelControlsComponents.swift"])
        let icon = try #require(Self.slice(components, from: "struct ModelOptionParametersLeadingIcon: View {", to: "\n}\n"))
        #expect(icon.contains(".foregroundStyle(OriveoTheme.Palette.textSecondary)"))
    }

    // MARK: - Helpers

    private static func parameter(_ id: String, group: String = "sampling") -> GenerationParameterRef {
        GenerationParameterRef(
            id: id, support: "supported", source: "authoritative_metadata", group: group, valueSchema: "number"
        )
    }

    private static func slice(_ source: String, from start: String, to end: String) -> String? {
        guard let lower = source.range(of: start),
              let upper = source.range(of: end, range: lower.upperBound..<source.endIndex)
        else { return nil }
        return String(source[lower.lowerBound..<upper.lowerBound])
    }

    private static var appRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Chat
            .deletingLastPathComponent() // Features
            .deletingLastPathComponent() // OriveoTests
            .deletingLastPathComponent() // Oriveo (project directory)
            .appendingPathComponent("Oriveo")
    }

    private static func source(_ components: [String]) throws -> String {
        try String(contentsOf: components.reduce(appRoot) { $0.appendingPathComponent($1) }, encoding: .utf8)
    }

    private static func catalog(_ table: String) throws -> [String: [String: String]] {
        let data = try Data(contentsOf: appRoot.appendingPathComponent("\(table).xcstrings"))
        let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try #require(root["strings"] as? [String: Any])
        return strings.reduce(into: [:]) { result, item in
            guard let localizations = (item.value as? [String: Any])?["localizations"] as? [String: Any] else {
                result[item.key] = [:]
                return
            }
            result[item.key] = localizations.reduce(into: [:]) { values, locale in
                if let unit = (locale.value as? [String: Any])?["stringUnit"] as? [String: Any],
                   let value = unit["value"] as? String {
                    values[locale.key] = value
                }
            }
        }
    }
}
