import Foundation
import OriveoProviderKit
import Testing
@testable import Oriveo

/// The four groups of pure functions (cap choice / commit / panel / settings) match the context-cap-presentation.v1 fixture;
/// Settings > Context default cap read/write and the root row's composed value; the settings group, option words and the four custom-input keys can all be found in the compiled output of the 16 languages.
@Suite("Context cap settings presentation", .serialized, .sharedProcessState)
@MainActor
struct ContextCapSettingsPresentationTests {

    private static let locales = [
        "ar", "de", "en", "es", "fr", "hi", "id", "ja", "ko", "pt-BR", "ru", "th", "tr", "vi", "zh-Hans", "zh-Hant",
    ]

    static let capSettingsKeys = [
        "settings_context_cap_header",
        "settings_context_cap_footer",
        "settings_context_row_value",
        "settings_context_mode_fallback_hint",
    ]

    static let capOptionChatKeys = [
        "context_cap_auto",
        "context_cap_unlimited",
        "context_cap_custom",
        "context_cap_input_label",
        "context_cap_input_unit",
        "context_cap_input_echo",
        "context_cap_adjusted",
    ]

    /// Panel: this conversation's cap row, the window row, the multiplier sentence and the ring's price line.
    static let capPanelChatKeys = [
        "context_cap_title",
        "context_cap_row_limited",
        "context_cap_window_line",
        "context_cap_window_line_price",
        "context_cap_window_line_price_plain",
        "context_cap_above_line",
        "context_cap_mult_both",
        "context_cap_mult_input",
        "context_cap_mult_output",
        "context_cap_mult_split",
        "context_usage_legend_price_line",
        "context_usage_measured_price_line",
        "context_usage_estimated_price_line",
        "context_usage_measured_price_line_crossed",
        "context_usage_estimated_price_line_crossed",
    ]

    /// Picker page: the follow item, header row, descriptions of each option, custom hint, tick labels, footnote and VoiceOver.
    static let capPickerChatKeys = [
        "context_cap_follow",
        "context_cap_follow_hint",
        "context_cap_head",
        "context_cap_head_price_line",
        "context_cap_head_unknown",
        "context_cap_auto_hint_price_line",
        "context_cap_auto_hint_default",
        "context_cap_auto_hint_default_below_line",
        "context_cap_auto_hint_window",
        "context_cap_hint_window_unknown",
        "context_cap_unlimited_hint",
        "context_cap_unlimited_hint_price_line",
        "context_cap_price_line_tick",
        "context_cap_custom_over",
        "context_cap_custom_over_plain",
        "context_cap_custom_at",
        "context_cap_custom_under",
        "context_cap_footer",
        "context_cap_slider_a11y",
    ]

    // MARK: Fixtures

    private static func capFixture() throws -> [String: Any] {
        var cursor = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while cursor.path != "/" {
            let candidate = cursor.appendingPathComponent("shared/context-contracts/context-cap-presentation.v1.json")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: candidate)) as? [String: Any])
            }
            cursor.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }

    private static func cases(_ name: String) throws -> [[String: Any]] {
        try #require(try capFixture()[name] as? [[String: Any]])
    }

    /// Fixture window key -> production ContextWindowInput (budgetCap is overridden by the function under test according to the tier).
    private static func windowInput(_ input: [String: Any]) throws -> ContextWindowInput {
        let maxOutput = input["maxOutput"] as? [String: Any] ?? [:]
        return ContextWindowInput(
            W: input["W"] as? Int,
            windowKind: try #require(ContextWindowKind(rawValue: input["windowKind"] as? String ?? "")),
            maxOutput: ContextMaxOutputSources(
                user: maxOutput["user"] as? Int,
                recipe: maxOutput["recipe"] as? Int,
                model: maxOutput["model"] as? Int
            ),
            priceLineTokens: input["priceLineTokens"] as? Int
        )
    }

    /// null = follow the global setting; every other value must be a valid tier.
    private static func conversationCap(_ raw: Any?) throws -> ContextBudgetCap? {
        guard let raw, !(raw is NSNull) else { return nil }
        return try #require(ContextBudgetCap.parse(raw))
    }

    private static func pricing(_ raw: Any?) -> ContextCapPresentation.Pricing? {
        guard let object = raw as? [String: Any] else { return nil }
        func side(_ key: String) -> ContextCapPresentation.Pricing.Side? {
            guard let side = object[key] as? [String: Any] else { return nil }
            return ContextCapPresentation.Pricing.Side(
                prompt: side["prompt"] as? Double,
                completion: side["completion"] as? Double
            )
        }
        return ContextCapPresentation.Pricing(base: side("base"), long: side("long"))
    }

    private static func value(_ optional: Any?) -> Any { optional ?? NSNull() }

    private static func shape(_ effective: ContextCapPresentation.Effective) -> [String: Any] {
        ["B": value(effective.B), "limitedBy": value(effective.limitedBy?.rawValue)]
    }

    private static func pickerShape(_ picker: ContextCapPresentation.PickerModel) -> [String: Any] {
        [
            "selected": picker.selected.rawValue,
            "effective": shape(picker.effective),
            "auto": shape(picker.auto),
            "unlimited": shape(picker.unlimited),
            "ticks": picker.ticks,
            "customStart": picker.customStart,
            "sliderIndex": picker.sliderIndex,
            "priceLineTickIndex": value(picker.priceLineTickIndex),
            "unlimitedCrossesPriceLine": picker.unlimitedCrossesPriceLine,
            "customHint": ["kind": picker.customHint.kind.rawValue, "gap": value(picker.customHint.gap)] as [String: Any],
        ]
    }

    private static func panelShape(_ panel: ContextCapPresentation.Panel) -> [String: Any] {
        [
            "capValue": value(panel.capValue),
            "limitedByModel": panel.limitedByModel,
            "actual": value(panel.actual),
            "windowLine": panel.windowLine.rawValue,
            "priceLineDistance": value(panel.priceLineDistance),
            "multiplier": value(panel.multiplier.map {
                ["input": value($0.input), "output": value($0.output)] as [String: Any]
            }),
        ]
    }

    private static func expectMatches(_ actual: [String: Any], _ expected: [String: Any], id: String) {
        for key in expected.keys.sorted() {
            let lhs = actual[key] as Any
            let rhs = expected[key] as Any
            #expect(
                NSDictionary(dictionary: ["v": lhs]).isEqual(to: ["v": rhs]),
                "\(id).\(key): actual \(lhs) expected \(rhs)"
            )
        }
        #expect(Set(actual.keys) == Set(expected.keys), "\(id): the field sets differ")
    }

    private func bundle(_ locale: String) throws -> Bundle {
        let path = try #require(Bundle.main.path(forResource: locale, ofType: "lproj"), "App bundle is missing \(locale).lproj")
        return try #require(Bundle(path: path))
    }

    // MARK: Choice, commit and panel against the fixture

    @Test func presentation_matches_fixture() throws {
        let pickerCases = try Self.cases("pickerCases")
        #expect(pickerCases.count == 19)
        for testCase in pickerCases {
            let id = try #require(testCase["id"] as? String)
            let input = try #require(testCase["input"] as? [String: Any])
            let expected = try #require(testCase["expected"] as? [String: Any])
            let picker = ContextCapPresentation.picker(
                window: try Self.windowInput(input),
                conversationCap: try Self.conversationCap(input["conversationCap"]),
                globalCap: try #require(ContextBudgetCap.parse(input["globalCap"]))
            )
            Self.expectMatches(Self.pickerShape(picker), expected, id: id)
        }

        let panelCases = try Self.cases("panelCases")
        #expect(panelCases.count == 13)
        for testCase in panelCases {
            let id = try #require(testCase["id"] as? String)
            let input = try #require(testCase["input"] as? [String: Any])
            let expected = try #require(testCase["expected"] as? [String: Any])
            let panel = ContextCapPresentation.panel(
                window: try Self.windowInput(input),
                conversationCap: try Self.conversationCap(input["conversationCap"]),
                globalCap: try #require(ContextBudgetCap.parse(input["globalCap"])),
                used: try #require(input["used"] as? Int),
                pricing: Self.pricing(input["pricing"])
            )
            Self.expectMatches(Self.panelShape(panel), expected, id: id)
        }

        let settingsCases = try Self.cases("settingsCases")
        #expect(settingsCases.count == 8)
        for testCase in settingsCases {
            let id = try #require(testCase["id"] as? String)
            let input = try #require(testCase["input"] as? [String: Any])
            let expected = try #require(testCase["expected"] as? [String: Any])
            let settings = ContextCapPresentation.settings(stored: input["stored"])
            Self.expectMatches(
                ["selected": settings.selected.rawValue, "customPrefill": settings.customPrefill],
                expected,
                id: id
            )
        }
    }

    // MARK: Settings against the fixture

    @Test func commit_matches_fixture() throws {
        let commitCases = try Self.cases("commitCases")
        #expect(commitCases.count == 25)
        for testCase in commitCases {
            let id = try #require(testCase["id"] as? String)
            let input = try #require(testCase["input"] as? [String: Any])
            let expected = try #require(testCase["expected"] as? [String: Any])
            let commit = ContextCapPresentation.commit(
                text: try #require(input["text"] as? String),
                U: input["U"] as? Int,
                previous: try #require(input["previous"] as? Int)
            )
            Self.expectMatches(
                ["value": commit.value, "adjusted": commit.adjusted, "restored": commit.restored],
                expected,
                id: id
            )
        }
    }

    // MARK: Settings > Context default cap

    @Test func settings_default_cap_roundtrip() throws {
        let previousUID = AppSessionStore.activeUID
        let uid = "context-cap-settings-\(UUID().uuidString)"
        defer { AppSessionStore.switchToUser(previousUID) }
        AppSessionStore.switchToUser(uid)
        let state = AppState(seedDemoData: false, sessionUID: uid)

        // Auto by default, custom is pre-filled with 256000
        #expect(ContextDefaultCapSetting.current(in: state) == .auto)
        #expect(ContextDefaultCapSetting.presentation(in: state).selected == .auto)
        #expect(ContextDefaultCapSetting.presentation(in: state).customPrefill == 256_000)

        let commit = ContextDefaultCapSetting.commitCustom(text: "190000", to: state)
        #expect(commit == ContextCapPresentation.Commit(value: 190_000, adjusted: false, restored: false))
        #expect(state.preferences.contextDefaultCap == .custom(190_000))
        #expect(AppPreferencesStore.savedContextDefaultCap == .custom(190_000))
        #expect(AppPreferencesStore.load().contextDefaultCap == .custom(190_000))
        #expect(ContextDefaultCapSetting.presentation(in: state).selected == .custom)
        #expect(ContextDefaultCapSetting.presentation(in: state).customPrefill == 190_000)

        // Cannot be parsed: restore the original value, write nothing
        let restored = ContextDefaultCapSetting.commitCustom(text: "abc", to: state)
        #expect(restored == ContextCapPresentation.Commit(value: 190_000, adjusted: false, restored: true))
        #expect(AppPreferencesStore.savedContextDefaultCap == .custom(190_000))

        // Below the lower bound: clamp to 32000 and mark as adjusted
        let adjusted = ContextDefaultCapSetting.commitCustom(text: "1000", to: state)
        #expect(adjusted == ContextCapPresentation.Commit(value: 32_000, adjusted: true, restored: false))
        #expect(AppPreferencesStore.savedContextDefaultCap == .custom(32_000))

        ContextDefaultCapSetting.apply(.unlimited, to: state)
        #expect(state.preferences.contextDefaultCap == .unlimited)
        #expect(AppPreferencesStore.savedContextDefaultCap == .unlimited)

        ContextDefaultCapSetting.apply(.auto, to: state)
        #expect(state.preferences.contextDefaultCap == .auto)
        #expect(AppPreferencesStore.load().contextDefaultCap == .auto)
    }

    @Test func settings_row_value_text() throws {
        let en = try bundle("en")
        let enFormat = en.localizedString(forKey: "settings_context_row_value", value: nil, table: "Settings")
        #expect(enFormat == "%1$@ · %2$@")
        #expect(String(format: enFormat, "Automatic", "Your messages only") == "Automatic · Your messages only")

        let auto = L10n.tr("context_cap_auto", table: .chat)
        let unlimited = L10n.tr("context_cap_unlimited", table: .chat)
        let fallback = ContextSettingsMode.fallback.rowValue
        let ai = ContextSettingsMode.aiSummary.rowValue

        let autoRow = ContextDefaultCapSetting.rowValue(cap: .auto, mode: .fallback)
        #expect(autoRow.hasPrefix(auto))
        #expect(autoRow.hasSuffix(fallback))
        #expect(!autoRow.contains("%"))
        let unlimitedRow = ContextDefaultCapSetting.rowValue(cap: .unlimited, mode: .aiSummary)
        #expect(unlimitedRow.hasPrefix(unlimited))
        #expect(unlimitedRow.hasSuffix(ai))

        // Custom shows a compact number, isolated with FSI...PDI
        let compact = ContextCompactionSeparator.compactCount(190_000)
        let customRow = ContextDefaultCapSetting.rowValue(cap: .custom(190_000), mode: .fallback)
        #expect(customRow.hasPrefix("\u{2068}\(compact)\u{2069}"))
        #expect(customRow.hasSuffix(fallback))

        // Production path: the root row value composed from AppState's current preferences
        let previousUID = AppSessionStore.activeUID
        let uid = "context-cap-row-\(UUID().uuidString)"
        defer { AppSessionStore.switchToUser(previousUID) }
        AppSessionStore.switchToUser(uid)
        let state = AppState(seedDemoData: false, sessionUID: uid)
        #expect(ContextDefaultCapSetting.rowValue(in: state) == autoRow)
        ContextDefaultCapSetting.apply(.custom(190_000), to: state)
        ContextSettingsMode.aiSummary.apply(to: state)
        #expect(ContextDefaultCapSetting.rowValue(in: state)
            == ContextDefaultCapSetting.rowValue(cap: .custom(190_000), mode: .aiSummary))

        // The footnote carries the compact numbers for 256000 and 32000
        let footer = ContextDefaultCapSetting.footer
        #expect(footer.contains(ContextCompactionSeparator.compactCount(256_000)))
        #expect(footer.contains(ContextCompactionSeparator.compactCount(32_000)))
        #expect(!footer.contains("%"))
    }

    // MARK: Localization (settings group, option words, four custom-input keys)

    @Test func cap_strings_present_in_16_locales() throws {
        for locale in Self.locales {
            let bundle = try bundle(locale)
            for (keys, table) in [(Self.capSettingsKeys, L10n.Table.settings), (Self.capOptionChatKeys, .chat), (Self.capPanelChatKeys, .chat), (Self.capPickerChatKeys, .chat)] {
                for key in keys {
                    let resolved = bundle.localizedString(forKey: key, value: key, table: table.rawValue)
                    #expect(resolved != key, "\(locale) · \(key) not found")
                    #expect(!resolved.isEmpty, "\(locale) · \(key) is empty")
                    #expect(!resolved.contains("{"), "\(locale) · \(key) placeholders were not converted to this platform's format")
                }
            }
            let footer = bundle.localizedString(forKey: "settings_context_cap_footer", value: nil, table: "Settings")
            let formatted = String(format: footer, "MAX", "MIN")
            #expect(formatted.contains("MAX") && formatted.contains("MIN"), "\(locale) · footnote placeholders")
        }

        let en = try bundle("en")
        let zh = try bundle("zh-Hans")
        #expect(en.localizedString(forKey: "settings_context_cap_header", value: nil, table: "Settings") == "Default limit")
        #expect(zh.localizedString(forKey: "context_cap_unlimited", value: nil, table: "Chat") == "\u{4E0D}\u{9650}")
        #expect(zh.localizedString(forKey: "settings_context_mode_fallback_hint", value: nil, table: "Settings")
            == "\u{4E0D}\u{989D}\u{5916}\u{82B1}\u{94B1}\u{3002}\u{8F83}\u{65E9}\u{7684} AI \u{56DE}\u{7B54}\u{4E0D}\u{518D}\u{53D1}\u{9001}\u{FF0C}\u{4F60}\u{8BF4}\u{8FC7}\u{7684}\u{8BDD}\u{7167}\u{5E38}\u{4FDD}\u{7559}\u{FF0C}\u{622A}\u{65AD}\u{5904}\u{505C}\u{5728}\u{53E5}\u{5B50}\u{7ED3}\u{5C3E}\u{3002}")
        let enFooter = en.localizedString(forKey: "settings_context_cap_footer", value: nil, table: "Settings")
        #expect(String(format: enFooter, "256K", "32K").hasPrefix("Automatic sizes to the model’s window, up to 256K,"))
        let enEcho = en.localizedString(forKey: "context_cap_input_echo", value: nil, table: "Chat")
        #expect(String(format: enEcho, "190K") == "= 190K tokens")
        let zhAdjusted = zh.localizedString(forKey: "context_cap_adjusted", value: nil, table: "Chat")
        #expect(String(format: zhAdjusted, "3.2\u{4E07}") == "\u{5DF2}\u{8C03}\u{6574}\u{4E3A} 3.2\u{4E07}")
        let enWindowPrice = en.localizedString(forKey: "context_cap_window_line_price", value: nil, table: "Chat")
        #expect(String(format: enWindowPrice, "2M", "200K", "input and output ×2")
            == "Model window 2M · past 200K, billed at long-context prices (input and output ×2)")
        let zhSplit = zh.localizedString(forKey: "context_cap_mult_split", value: nil, table: "Chat")
        #expect(String(format: zhSplit, "2", "1.5") == "\u{8F93}\u{5165} ×2\u{3001}\u{8F93}\u{51FA} ×1.5")
        #expect(zh.localizedString(forKey: "context_usage_effective_limit", value: "gone", table: "Chat") == "gone")
        let enHead = en.localizedString(forKey: "context_cap_head", value: nil, table: "Chat")
        #expect(String(format: enHead, "Grok 4.7", "2M", "1.9M") == "Grok 4.7 · 2M window · 1.9M usable")
        let zhHeadLine = zh.localizedString(forKey: "context_cap_head_price_line", value: nil, table: "Chat")
        #expect(String(format: zhHeadLine, "HEAD", "20\u{4E07}") == "HEAD · 20\u{4E07} \u{8D77}\u{52A0}\u{4EF7}")
        let enOver = en.localizedString(forKey: "context_cap_custom_over", value: nil, table: "Chat")
        #expect(String(format: enOver, "200K", "input and output ×2")
            == "Past 200K, the whole request is billed at long-context prices (input and output ×2). You’ll be asked before crossing it.")
        let enAutoDefault = en.localizedString(forKey: "context_cap_auto_hint_default", value: nil, table: "Chat")
        #expect(String(format: enAutoDefault, "256K", "256K") == "Now 256K: Automatic uses at most 256K")
    }

    // MARK: Panel cap row through production metadata

    private static let grokModelID = "grok-4.7"
    private static let grokWindow = 2_000_000

    /// The same grok-4.7 as ContextCapProductionPathTests: base price 2 / 6, long context 4 / 12 (both ×2), T = 200000.
    private static let grokMetadataJSON = """
    {
      "version": 1,
      "updatedAt": "2026-10-15T00:00:00Z",
      "providers": {
        "grok": {
          "displayName": "grok",
          "defaultModelId": "\(grokModelID)",
          "resolveMap": { "\(grokModelID)": "\(grokModelID)" },
          "models": {
            "\(grokModelID)": {
              "canonicalModelId": "\(grokModelID)",
              "displayName": "Grok 4.7",
              "contextLength": \(grokWindow),
              "pricing": {
                "promptPerMToken": 2,
                "completionPerMToken": 6,
                "longContext": {"thresholdTokens": 200000, "promptPerMToken": 4, "completionPerMToken": 12}
              },
              "capabilities": ["text"],
              "profiles": {}
            }
          }
        }
      }
    }
    """

    /// grok-4.7 is connected with one conversation following the global setting; metadata goes through the production decoder.
    private static func grokConversation(_ label: String) async throws -> (AppState, Conversation) {
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(json: grokMetadataJSON)

        let state = AppState(seedDemoData: false, sessionUID: "\(label)-\(UUID().uuidString)")
        var model = TestFactories.makeModel(id: Self.grokModelID, name: "Grok 4.7", capabilities: [.text], isDefault: true)
        model.contextLength = Self.grokWindow
        let provider = Provider(
            id: UUID(),
            kind: .grok,
            status: .connected,
            models: [model],
            catalogModels: [],
            apiKey: "grok-key",
            apiKeyPreview: "...key",
            baseURLText: nil
        )
        state.providers = [provider]
        let conversation = TestFactories.makeConversation(
            providerID: provider.id,
            providerKind: provider.kind,
            modelID: grokModelID,
            messages: []
        )
        state.upsertConversationProjection(conversation)
        return (state, conversation)
    }

    @Test func panel_cap_row_from_production_metadata() async throws {
        let (state, initial) = try await Self.grokConversation("context-cap-panel")
        var conversation = initial

        // Auto: B = T = 200000 -> windowPriceLine, ×2 on both sides
        let source = try #require(ContextCapPresentation.panelSource(in: state, conversationID: conversation.id))
        #expect(source.window.priceLineTokens == 200_000)
        #expect(source.window.W == Self.grokWindow)
        #expect(source.conversationCap == nil)
        #expect(source.globalCap == .auto)
        let rows = ContextUsagePanel.CapRows(source: source, used: 50_000)
        #expect(rows.panel.windowLine == .windowPriceLine)
        #expect(rows.panel.capValue == 200_000)
        #expect(rows.panel.multiplier == ContextCapPresentation.Multiplier(input: 20, output: 20))
        #expect(rows.panel.multiplier?.isUniform == true)
        #expect(rows.priceLineTick == nil)

        let en = Locale(identifier: "en_US")
        let both = try #require(ContextUsagePanel.multiplierText(rows.panel.multiplier, locale: en))
        #expect(both.contains("×2"))
        let windowLine = try #require(ContextUsagePanel.windowLineText(rows, locale: en))
        #expect(windowLine.contains("×2"))
        #expect(windowLine.contains(both))
        #expect(windowLine.contains(ContextCompactionSeparator.compactCount(200_000, locale: en)))
        #expect(windowLine.contains(ContextCompactionSeparator.compactCount(Self.grokWindow, locale: en)))
        #expect(!windowLine.contains("%"))
        #expect(ContextUsagePanel.capValueText(rows, locale: en).contains(ContextCompactionSeparator.compactCount(200_000, locale: en)))
        #expect(ContextUsagePanel.limitedText(rows, locale: en) == nil)

        // Conversation custom 500000 (T < B) -> aboveLine, 150000 from the price line; the ring ticks fall at T / B
        conversation.contextCap = .custom(500_000)
        state.upsertConversationProjection(conversation)
        let custom = ContextUsagePanel.CapRows(
            source: try #require(ContextCapPresentation.panelSource(in: state, conversationID: conversation.id)),
            used: 50_000
        )
        #expect(custom.panel.windowLine == .aboveLine)
        #expect(custom.panel.priceLineDistance == 150_000)
        #expect(custom.priceLineTick == 200_000)
        let above = try #require(ContextUsagePanel.windowLineText(custom, locale: en))
        #expect(above.contains(ContextCompactionSeparator.compactCount(200_000, locale: en)))
        #expect(above != windowLine)

        // Custom beyond U: limited by the model, the effective value is B
        conversation.contextCap = .custom(2_100_000_000)
        state.upsertConversationProjection(conversation)
        let limited = ContextUsagePanel.CapRows(
            source: try #require(ContextCapPresentation.panelSource(in: state, conversationID: conversation.id)),
            used: 0
        )
        #expect(limited.panel.limitedByModel)
        let actual = try #require(limited.panel.actual)
        #expect(try #require(ContextUsagePanel.limitedText(limited, locale: en))
            .contains(ContextCompactionSeparator.compactCount(actual, locale: en)))
    }

    // MARK: Picker page writes this conversation's cap

    @Test func picker_writes_conversation_cap() async throws {
        let (state, conversation) = try await Self.grokConversation("context-cap-picker")
        let write: (ContextBudgetCap?) -> Void = { cap in
            state.conversationManager.setContextCap(id: conversation.id, cap: cap)
        }
        func stored() -> ContextBudgetCap? { state.conversation(for: conversation.id)?.contextCap }
        func source() throws -> ContextCapPresentation.PanelSource {
            try #require(ContextCapPresentation.panelSource(in: state, conversationID: conversation.id))
        }

        var picker = ContextCapPickerState(source: try source())
        #expect(picker.model.selected == .follow)
        #expect(picker.customText == "200000")

        // Options write immediately: unlimited -> .unlimited, follow -> nil
        picker.select(.unlimited, write: write)
        #expect(stored() == .unlimited)
        #expect(picker.model.selected == .unlimited)
        picker.select(.follow, write: write)
        #expect(stored() == nil)
        #expect(picker.model.selected == .follow)

        // Custom: write the starting point first (auto B = T = 200000), then commit the input
        picker.select(.custom, write: write)
        #expect(stored() == .custom(200_000))
        picker.customText = "190000"
        #expect(picker.commitCustomText(write: write)
            == ContextCapPresentation.Commit(value: 190_000, adjusted: false, restored: false))
        #expect(stored() == .custom(190_000))
        #expect(picker.adjustedValue == nil)

        // Tapping the slider without dragging: the index equals the one at press time, so nothing is written (190000 is not snapped to the nearest tick)
        picker.beginSlide()
        picker.endSlide(write: write)
        #expect(stored() == .custom(190_000))
        #expect(picker.customText == "190000")

        // Below the lower bound: clamp to 32000 and show "Adjusted to" in place
        picker.customText = "1000"
        #expect(picker.commitCustomText(write: write).adjusted)
        #expect(stored() == .custom(32_000))
        #expect(picker.adjustedValue == 32_000)
        #expect(picker.customText == "32000")

        // Cannot be parsed: restore the original value, write nothing
        picker.customText = "abc"
        #expect(picker.commitCustomText(write: write).restored)
        #expect(stored() == .custom(32_000))
        #expect(picker.customText == "32000")

        // The slider is bound to the tick index and writes on release
        let lineIndex = try #require(picker.model.priceLineTickIndex)
        picker.beginSlide()
        picker.slide(to: Double(lineIndex))
        #expect(picker.customText == "200000")
        #expect(stored() == .custom(32_000))
        picker.endSlide(write: write)
        #expect(stored() == .custom(200_000))
        #expect(picker.model.customHint.kind == .at)

        // Reopening the picker reads the conversation cap back
        let reopened = ContextCapPickerState(source: try source())
        #expect(reopened.model.selected == .custom)
        #expect(reopened.customText == "200000")
        #expect(Int(reopened.sliderIndex) == lineIndex)

        // Header-row model name: if no display name is available it falls back to the model id, never an empty string
        #expect(ContextCapPickerView.modelName(in: state, conversationID: conversation.id) == "Grok 4.7")
        state.providers[0].models[0].name = " "
        #expect(ContextCapPickerView.modelName(in: state, conversationID: conversation.id) == Self.grokModelID)
    }
}
