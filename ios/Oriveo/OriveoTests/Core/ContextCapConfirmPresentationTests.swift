import Foundation
import OriveoProviderKit
import Testing
@testable import Oriveo

/// The pre-send confirmation decision matches the context-cap-confirm.v1 fixture; the alert copy picks one of three variants, with zh expectations;
/// local state read/write; the Settings > Context price-line reminder switch; the compiled output for all 16 languages; the divider row shows the model name.
@Suite("Context cap confirm presentation", .serialized, .sharedProcessState)
@MainActor
struct ContextCapConfirmPresentationTests {

    private typealias Confirm = ContextCapConfirmPresentation

    private static let locales = [
        "ar", "de", "en", "es", "fr", "hi", "id", "ja", "ko", "pt-BR", "ru", "th", "tr", "vi", "zh-Hans", "zh-Hant",
    ]

    static let confirmChatKeys = [
        "context_confirm_over_cap_title",
        "context_confirm_over_cap_body",
        "context_confirm_price_line_title",
        "context_confirm_price_line_body_cost",
        "context_confirm_price_line_body_mult",
        "context_confirm_price_line_body",
        "context_confirm_also_price_line_cost",
        "context_confirm_also_price_line_mult",
        "context_confirm_also_price_line",
        "context_confirm_dont_ask",
        "context_confirm_send",
    ]

    static let confirmSettingsKeys = [
        "settings_context_price_line_reminder",
        "settings_context_price_line_reminder_footer",
    ]

    // MARK: Fixtures

    private static func fixture() throws -> [String: Any] {
        var cursor = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while cursor.path != "/" {
            let candidate = cursor.appendingPathComponent("shared/context-contracts/context-cap-confirm.v1.json")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: candidate)) as? [String: Any])
            }
            cursor.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }

    private static func cases() throws -> [[String: Any]] {
        try #require(try fixture()["cases"] as? [[String: Any]])
    }

    private static func testCase(_ id: String) throws -> [String: Any] {
        try #require(try cases().first { $0["id"] as? String == id }, "fixture is missing \(id)")
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

    private static func acknowledgement(_ raw: Any?) throws -> Confirm.Acknowledgement? {
        guard let object = raw as? [String: Any] else { return nil }
        return Confirm.Acknowledgement(
            model: try #require(object["model"] as? String),
            T: try #require(object["T"] as? Int)
        )
    }

    /// Fixture input -> production Input.
    private static func input(_ raw: [String: Any]) throws -> Confirm.Input {
        let state = try #require(raw["conversationState"] as? [String: Any])
        let limitedBy = raw["limitedBy"] as? String
        return Confirm.Input(
            attempt: try #require(Confirm.Attempt(rawValue: raw["attempt"] as? String ?? "")),
            model: try #require(raw["model"] as? String),
            reminderEnabled: try #require(raw["reminderEnabled"] as? Bool),
            conversationState: Confirm.ConversationState(
                suppressed: try #require(state["suppressed"] as? Bool),
                acknowledged: try acknowledgement(state["acknowledged"])
            ),
            pricing: pricing(raw["pricing"]),
            estimatedInput: try #require(raw["estimatedInput"] as? Int),
            B: raw["B"] as? Int,
            limitedBy: try limitedBy.map { try #require(ContextBudgetLimit(rawValue: $0)) },
            priceLineTokens: raw["priceLineTokens"] as? Int
        )
    }

    private static func strip(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter { !(0x2066...0x2069).contains($0.value) }))
    }

    private func bundle(_ locale: String) throws -> Bundle {
        let path = try #require(Bundle.main.path(forResource: locale, ofType: "lproj"), "App bundle is missing \(locale).lproj")
        return try #require(Bundle(path: path))
    }

    private func withLanguage(_ language: LanguageOption, _ body: @MainActor () throws -> Void) rethrows {
        var preferences = AppPreferencesStore.load()
        let original = preferences.language
        preferences.language = language
        AppPreferencesStore.save(preferences)
        L10n.invalidateCache()
        defer {
            var restored = AppPreferencesStore.load()
            restored.language = original
            AppPreferencesStore.save(restored)
            L10n.invalidateCache()
        }
        try body()
    }

    // MARK: Decision against the fixture

    @Test func confirm_matches_fixture() throws {
        let cases = try Self.cases()
        #expect(cases.count == 37)
        for testCase in cases {
            let id = try #require(testCase["id"] as? String)
            let input = try Self.input(try #require(testCase["input"] as? [String: Any]))
            let expected = try #require(testCase["expected"] as? [String: Any])
            let decision = Confirm.decide(input)

            #expect(decision.kind.rawValue == expected["kind"] as? String, "\(id).kind: \(decision.kind)")
            #expect(decision.showDontAsk == expected["showDontAsk"] as? Bool, "\(id).showDontAsk")

            if let cost = expected["cost"] as? [String: Any] {
                let actual = try #require(decision.cost, "\(id).cost should have a value")
                #expect(abs(actual.long - (try #require(cost["long"] as? Double))) < 1e-9, "\(id).cost.long \(actual.long)")
                #expect(abs(actual.base - (try #require(cost["base"] as? Double))) < 1e-9, "\(id).cost.base \(actual.base)")
            } else {
                #expect(decision.cost == nil, "\(id).cost should be null")
            }

            if let multiplier = expected["multiplier"] as? [String: Any] {
                #expect(decision.multiplier == ContextCapPresentation.Multiplier(
                    input: multiplier["input"] as? Int,
                    output: multiplier["output"] as? Int
                ), "\(id).multiplier")
            } else {
                #expect(decision.multiplier == nil, "\(id).multiplier should be null")
            }

            #expect(decision.acknowledgeOnConfirm == (try Self.acknowledgement(expected["acknowledgeOnConfirm"])),
                    "\(id).acknowledgeOnConfirm")
        }
    }

    // MARK: Alert copy

    /// Fixture case -> alert copy (model name Grok 4.7).
    private func text(_ id: String, mutate: (inout Confirm.Input) -> Void = { _ in }) throws -> Confirm.Text? {
        var input = try Self.input(try #require(try Self.testCase(id)["input"] as? [String: Any]))
        mutate(&input)
        return Confirm.text(Confirm.decide(input), input: input, modelName: "Grok 4.7")
    }

    @Test func confirm_text_variants() throws {
        try withLanguage(.chineseSimplified) {
            // Over the line, with an amount
            let cross = try #require(try text("price_line_first_cross"))
            #expect(cross.title == L10n.tr("context_confirm_price_line_title", table: .chat))
            #expect(Self.strip(cross.body)
                == "\u{8FD9}\u{6B21}\u{7EA6} 21.3\u{4E07} token\u{FF0C}\u{8D85}\u{8FC7} Grok 4.7 \u{7684} 20\u{4E07} \u{52A0}\u{4EF7}\u{7EBF}\u{FF0C}\u{6574}\u{4E2A}\u{8BF7}\u{6C42}\u{6309}\u{957F}\u{4E0A}\u{4E0B}\u{6587}\u{4EF7}\u{8BA1}\u{8D39}\u{FF1A}\u{7EA6} $0.85\u{FF0C}\u{4E0D}\u{8D8A}\u{7EBF}\u{7EA6} $0.43\u{3002}")
            #expect(cross.showsDontAsk)
            #expect(cross.body.contains("\u{2068}"))

            // Over the cap
            let over = try #require(try text("over_cap_custom"))
            #expect(over.title == L10n.tr("context_confirm_over_cap_title", table: .chat))
            #expect(Self.strip(over.body) == "\u{8FD9}\u{6B21}\u{7EA6} 15.2\u{4E07} token\u{FF0C}\u{8D85}\u{8FC7}\u{6B64}\u{5BF9}\u{8BDD}\u{4E0A}\u{9650} 12.8\u{4E07}\u{3002}")
            #expect(!over.showsDontAsk)

            // Multiplier only
            let mult = try #require(try text("price_line_base_prompt_zero"))
            let multSentence = try #require(ContextUsagePanel.multiplierText(
                ContextCapPresentation.Multiplier(input: nil, output: 20)
            ))
            #expect(Self.strip(mult.body)
                == "\u{8FD9}\u{6B21}\u{7EA6} 21.3\u{4E07} token\u{FF0C}\u{8D85}\u{8FC7} Grok 4.7 \u{7684} 20\u{4E07} \u{52A0}\u{4EF7}\u{7EBF}\u{FF0C}\u{6574}\u{4E2A}\u{8BF7}\u{6C42}\u{6309}\u{957F}\u{4E0A}\u{4E0B}\u{6587}\u{4EF7}\u{8BA1}\u{8D39}\u{FF08}\(Self.strip(multSentence))\u{FF09}\u{3002}")

            // Neither amount nor multiplier
            let plain = try #require(try text("price_line_no_pricing"))
            #expect(Self.strip(plain.body) == "\u{8FD9}\u{6B21}\u{7EA6} 21.3\u{4E07} token\u{FF0C}\u{8D85}\u{8FC7} Grok 4.7 \u{7684} 20\u{4E07} \u{52A0}\u{4EF7}\u{7EBF}\u{FF0C}\u{6574}\u{4E2A}\u{8BF7}\u{6C42}\u{6309}\u{957F}\u{4E0A}\u{4E0B}\u{6587}\u{4EF7}\u{8BA1}\u{8D39}\u{3002}")
            #expect(try #require(try text("price_line_no_multiplier_above_one")).body == plain.body)

            // Both: the over-cap title, with the over-cap sentence followed by an also_* line after a line break
            let both = try #require(try text("over_cap_and_price_line"))
            #expect(both.title == L10n.tr("context_confirm_over_cap_title", table: .chat))
            #expect(Self.strip(both.body)
                == "\u{8FD9}\u{6B21}\u{7EA6} 26\u{4E07} token\u{FF0C}\u{8D85}\u{8FC7}\u{6B64}\u{5BF9}\u{8BDD}\u{4E0A}\u{9650} 24\u{4E07}\u{3002}\n\u{8FD9}\u{6B21}\u{8FD8}\u{4F1A}\u{8D8A}\u{8FC7} Grok 4.7 \u{7684} 20\u{4E07} \u{52A0}\u{4EF7}\u{7EBF}\u{FF0C}\u{6574}\u{4E2A}\u{8BF7}\u{6C42}\u{6309}\u{957F}\u{4E0A}\u{4E0B}\u{6587}\u{4EF7}\u{8BA1}\u{8D39}\u{FF1A}\u{7EA6} $1.04\u{FF0C}\u{4E0D}\u{8D8A}\u{7EBF}\u{7EA6} $0.52\u{3002}")
            #expect(both.showsDontAsk)
            let bothPlain = try #require(try text("over_cap_and_price_line") { $0.pricing = nil })
            #expect(Self.strip(bothPlain.body)
                == "\u{8FD9}\u{6B21}\u{7EA6} 26\u{4E07} token\u{FF0C}\u{8D85}\u{8FC7}\u{6B64}\u{5BF9}\u{8BDD}\u{4E0A}\u{9650} 24\u{4E07}\u{3002}\n\u{8FD9}\u{6B21}\u{8FD8}\u{4F1A}\u{8D8A}\u{8FC7} Grok 4.7 \u{7684} 20\u{4E07} \u{52A0}\u{4EF7}\u{7EBF}\u{FF0C}\u{6574}\u{4E2A}\u{8BF7}\u{6C42}\u{6309}\u{957F}\u{4E0A}\u{4E0B}\u{6587}\u{4EF7}\u{8BA1}\u{8D39}\u{3002}")
            let bothMult = try #require(try text("over_cap_and_price_line") {
                $0.pricing?.base?.prompt = 0
            })
            #expect(Self.strip(bothMult.body).hasSuffix("\u{6574}\u{4E2A}\u{8BF7}\u{6C42}\u{6309}\u{957F}\u{4E0A}\u{4E0B}\u{6587}\u{4EF7}\u{8BA1}\u{8D39}\u{FF08}\(Self.strip(multSentence))\u{FF09}\u{3002}"))
            #expect(Self.strip(bothMult.body).contains("\n\u{8FD9}\u{6B21}\u{8FD8}\u{4F1A}\u{8D8A}\u{8FC7} Grok 4.7 \u{7684} 20\u{4E07} \u{52A0}\u{4EF7}\u{7EBF}"))

            // No ask: no alert
            #expect(try text("none_under_auto_price_line") == nil)
            #expect(try text("price_line_retry_skips") == nil)

            // An empty model name falls back to the id
            let input = try Self.input(try #require(try Self.testCase("price_line_first_cross")["input"] as? [String: Any]))
            let unnamed = try #require(Confirm.text(Confirm.decide(input), input: input, modelName: " "))
            #expect(Self.strip(unnamed.body).contains("\u{8D85}\u{8FC7} grok-4.7 \u{7684} 20\u{4E07} \u{52A0}\u{4EF7}\u{7EBF}"))
        }
    }

    // MARK: Production metadata

    private static let grokModelID = "grok-4.7"
    private static let grokWindow = 2_000_000

    /// The same grok-4.7 as ContextCapSettingsPresentationTests: base price 2 / 6, long context 4 / 12, T = 200000.
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

    private static func isolatedDefaults() throws -> UserDefaults {
        let suite = "context-cap-confirm-\(UUID().uuidString)"
        return try #require(UserDefaults(suiteName: suite))
    }

    @Test func confirm_text_from_production_metadata() async throws {
        let (state, initial) = try await Self.grokConversation("context-cap-confirm")
        var conversation = initial
        let store = ContextPriceLineConfirmStore(defaults: try Self.isolatedDefaults())
        let en = Locale(identifier: "en_US")

        // Following the global auto: B = T = 200000, limitedBy priceLine -> only over the line
        let prompt = try #require(Confirm.prompt(
            in: state, conversationID: conversation.id, attempt: .send, estimatedInput: 213_000, store: store, locale: en
        ))
        #expect(prompt.input.priceLineTokens == 200_000)
        #expect(prompt.input.limitedBy == .priceLine)
        #expect(prompt.input.model == Self.grokModelID)
        #expect(prompt.input.reminderEnabled)
        #expect(prompt.decision.kind == .priceLine)
        let cost = try #require(prompt.decision.cost)
        #expect(abs(cost.long - 0.852) < 1e-9)
        #expect(abs(cost.base - 0.426) < 1e-9)
        #expect(prompt.text.body.contains("Grok 4.7"))
        #expect(prompt.text.body.contains(CostFormatter.format(0.852)))
        #expect(prompt.text.body.contains(CostFormatter.format(0.426)))
        #expect(prompt.text.body.contains(ContextCompactionSeparator.compactCount(200_000, locale: en)))
        #expect(!prompt.text.body.contains("%"))
        #expect(prompt.text.showsDontAsk)

        // Regenerate does not ask
        #expect(Confirm.prompt(
            in: state, conversationID: conversation.id, attempt: .regenerate, estimatedInput: 213_000, store: store
        ) == nil)

        // After confirming, {model, T} is recorded and the same line is not asked again
        store.confirm(prompt.decision, dontAsk: false, conversationID: conversation.id)
        #expect(store.state(for: conversation.id)
            == Confirm.ConversationState(suppressed: false, acknowledged: .init(model: Self.grokModelID, T: 200_000)))
        #expect(Confirm.prompt(
            in: state, conversationID: conversation.id, attempt: .send, estimatedInput: 213_000, store: store
        ) == nil)

        // Conversation custom 128000 (below T): over the cap asks every time, and confirming does not change state
        conversation.contextCap = .custom(128_000)
        state.upsertConversationProjection(conversation)
        let over = try #require(Confirm.prompt(
            in: state, conversationID: conversation.id, attempt: .edit, estimatedInput: 152_000, store: store, locale: en
        ))
        #expect(over.input.limitedBy == .custom)
        #expect(over.input.B == 128_000)
        #expect(over.decision.kind == .overCap)
        #expect(over.text.title == L10n.tr("context_confirm_over_cap_title", table: .chat))
        #expect(over.text.body.contains(ContextCompactionSeparator.compactCount(128_000, locale: en)))
        let before = store.state(for: conversation.id)
        store.confirm(over.decision, dontAsk: false, conversationID: conversation.id)
        #expect(store.state(for: conversation.id) == before)

        // Master switch off: no ask when over the line
        conversation.contextCap = nil
        state.upsertConversationProjection(conversation)
        let fresh = ContextPriceLineConfirmStore(defaults: try Self.isolatedDefaults())
        ContextPriceLineReminderSetting.apply(false, to: state)
        defer { ContextPriceLineReminderSetting.apply(true, to: state) }
        #expect(Confirm.prompt(
            in: state, conversationID: conversation.id, attempt: .send, estimatedInput: 213_000, store: fresh
        ) == nil)
    }

    // MARK: Alert

    /// The checkbox only appears when over the line (showDontAsk) and is unchecked by default; checking it only takes effect while it is shown; swipe-down dismissal = cancel.
    @Test func confirm_dialog_dont_ask_only_for_price_line() async throws {
        let (state, initial) = try await Self.grokConversation("context-cap-confirm-dialog")
        var conversation = initial
        let store = ContextPriceLineConfirmStore(defaults: try Self.isolatedDefaults())

        // Over the line only: there is a checkbox, unchecked by default
        let priceLine = try #require(Confirm.prompt(
            in: state, conversationID: conversation.id, attempt: .send, estimatedInput: 213_000, store: store
        ))
        #expect(priceLine.decision.kind == .priceLine)
        var dialog = ContextCapConfirmDialogModel(text: priceLine.text)
        #expect(dialog.showsDontAsk)
        #expect(!dialog.dontAsk)
        #expect(dialog.sendChoice() == .send(dontAsk: false))
        dialog.dontAsk = true
        #expect(dialog.sendChoice() == .send(dontAsk: true))
        #expect(ContextCapConfirmDialogModel.dismissChoice == .cancel)

        // Over the cap only: no checkbox, and the checked state is not carried out
        conversation.contextCap = .custom(128_000)
        state.upsertConversationProjection(conversation)
        let overCap = try #require(Confirm.prompt(
            in: state, conversationID: conversation.id, attempt: .send, estimatedInput: 152_000, store: store
        ))
        #expect(overCap.decision.kind == .overCap)
        var capDialog = ContextCapConfirmDialogModel(text: overCap.text)
        #expect(!capDialog.showsDontAsk)
        capDialog.dontAsk = true
        #expect(capDialog.sendChoice() == .send(dontAsk: false))

        // Both: the checkbox is still there
        let both = try #require(Confirm.prompt(
            in: state, conversationID: conversation.id, attempt: .send, estimatedInput: 260_000, store: store
        ))
        #expect(both.decision.kind == .overCapAndPriceLine)
        #expect(ContextCapConfirmDialogModel(text: both.text).showsDontAsk)
    }

    // MARK: Local state

    @Test func confirm_state_store_roundtrip() throws {
        let defaults = try Self.isolatedDefaults()
        let store = ContextPriceLineConfirmStore(defaults: defaults)
        let conversationID = UUID()
        let key = ContextPriceLineConfirmStore.key(conversationID)
        #expect(key == "context_price_line_confirm:\(conversationID.uuidString)")

        // Default {false, null}
        #expect(store.state(for: conversationID) == Confirm.ConversationState(suppressed: false, acknowledged: nil))
        #expect(defaults.object(forKey: key) == nil)

        let input = try Self.input(try #require(try Self.testCase("price_line_first_cross")["input"] as? [String: Any]))
        let decision = Confirm.decide(input)

        // Cancel changes nothing
        store.cancel(decision, conversationID: conversationID)
        #expect(defaults.object(forKey: key) == nil)

        // Confirm while over the line -> acknowledged; checked -> suppressed
        store.confirm(decision, dontAsk: true, conversationID: conversationID)
        let saved = Confirm.ConversationState(suppressed: true, acknowledged: .init(model: "grok-4.7", T: 200_000))
        #expect(store.state(for: conversationID) == saved)
        #expect(ContextPriceLineConfirmStore(defaults: defaults).state(for: conversationID) == saved)

        // What is stored is JSON {suppressed, acknowledged:{model,T}}
        let data = try #require(defaults.data(forKey: key))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["suppressed"] as? Bool == true)
        let acknowledged = try #require(object["acknowledged"] as? [String: Any])
        #expect(acknowledged["model"] as? String == "grok-4.7")
        #expect(acknowledged["T"] as? Int == 200_000)

        // The decision reads the state back: no longer prompting -> no ask
        var next = input
        next.conversationState = store.state(for: conversationID)
        #expect(Confirm.decide(next).kind == .none)

        // Another conversation is unaffected; bad data reads as the default
        let other = UUID()
        #expect(store.state(for: other) == Confirm.ConversationState(suppressed: false, acknowledged: nil))
        defaults.set(Data("x".utf8), forKey: ContextPriceLineConfirmStore.key(other))
        #expect(store.state(for: other) == Confirm.ConversationState(suppressed: false, acknowledged: nil))
    }

    // MARK: Settings switch

    @Test func settings_price_line_reminder_roundtrip() throws {
        let previousUID = AppSessionStore.activeUID
        let uid = "context-price-line-reminder-\(UUID().uuidString)"
        defer { AppSessionStore.switchToUser(previousUID) }
        AppSessionStore.switchToUser(uid)
        let state = AppState(seedDemoData: false, sessionUID: uid)

        // On by default
        #expect(ContextPriceLineReminderSetting.current(in: state))

        ContextPriceLineReminderSetting.apply(false, to: state)
        #expect(!state.preferences.contextPriceLineReminderEnabled)
        #expect(!AppPreferencesStore.savedContextPriceLineReminderEnabled)
        #expect(!AppPreferencesStore.load().contextPriceLineReminderEnabled)
        #expect(!ContextPriceLineReminderSetting.current(in: state))

        ContextPriceLineReminderSetting.apply(true, to: state)
        #expect(state.preferences.contextPriceLineReminderEnabled)
        #expect(AppPreferencesStore.savedContextPriceLineReminderEnabled)

        #expect(ContextPriceLineReminderSetting.title == L10n.tr("settings_context_price_line_reminder", table: .settings))
        #expect(ContextPriceLineReminderSetting.footer
            == L10n.tr("settings_context_price_line_reminder_footer", table: .settings))
    }

    // MARK: 16 languages

    @Test func confirm_strings_present_in_16_locales() throws {
        for locale in Self.locales {
            let bundle = try bundle(locale)
            for (keys, table) in [(Self.confirmChatKeys, L10n.Table.chat), (Self.confirmSettingsKeys, .settings)] {
                for key in keys {
                    let resolved = bundle.localizedString(forKey: key, value: key, table: table.rawValue)
                    #expect(resolved != key, "\(locale) · \(key) not found")
                    #expect(!resolved.isEmpty, "\(locale) · \(key) is empty")
                    #expect(!resolved.contains("{"), "\(locale) · \(key) placeholders were not converted to this platform's format")
                }
            }
            func formatted(_ key: String, _ args: [String]) -> String {
                String(format: bundle.localizedString(forKey: key, value: nil, table: "Chat"), arguments: args)
            }
            let cost = formatted("context_confirm_price_line_body_cost", ["EST", "MODEL", "LINE", "COST", "BASE"])
            #expect(["EST", "MODEL", "LINE", "COST", "BASE"].allSatisfy(cost.contains), "\(locale) · body_cost placeholders")
            let mult = formatted("context_confirm_price_line_body_mult", ["EST", "MODEL", "LINE", "MULT"])
            #expect(["EST", "MODEL", "LINE", "MULT"].allSatisfy(mult.contains), "\(locale) · body_mult placeholders")
            let alsoCost = formatted("context_confirm_also_price_line_cost", ["MODEL", "LINE", "COST", "BASE"])
            #expect(["MODEL", "LINE", "COST", "BASE"].allSatisfy(alsoCost.contains), "\(locale) · also_cost placeholders")
            let overCap = formatted("context_confirm_over_cap_body", ["EST", "CAP"])
            #expect(["EST", "CAP"].allSatisfy(overCap.contains), "\(locale) · over_cap_body placeholders")
        }

        let zh = try bundle("zh-Hans")
        let en = try bundle("en")
        #expect(zh.localizedString(forKey: "context_confirm_send", value: nil, table: "Chat") == "\u{4ECD}\u{7136}\u{53D1}\u{9001}")
        #expect(en.localizedString(forKey: "settings_context_price_line_reminder", value: nil, table: "Settings")
            == "Ask before long-context pricing")
        #expect(String(
            format: zh.localizedString(forKey: "context_confirm_over_cap_body", value: nil, table: "Chat"),
            "15.2\u{4E07}", "12.8\u{4E07}"
        ) == "\u{8FD9}\u{6B21}\u{7EA6} 15.2\u{4E07} token\u{FF0C}\u{8D85}\u{8FC7}\u{6B64}\u{5BF9}\u{8BDD}\u{4E0A}\u{9650} 12.8\u{4E07}\u{3002}")
    }

    // MARK: Divider row model name

    @Test func separator_summary_uses_model_display_name() async throws {
        let history = (0..<4).map { index in
            TestFactories.makeMessage(role: index.isMultiple(of: 2) ? .user : .assistant, text: "message \(index)")
        }
        let covered = history.map { ContextCheckpoint.CoveredMessage(id: $0.id.uuidString, text: $0.text) }
        let coversTo = history[1].id.uuidString
        let row = ContextCheckpointRecord(
            conversationId: "conversation",
            checkpointId: ContextCheckpoint.checkpointId(conversationId: "conversation", coversTo: coversTo),
            kind: .summary,
            coversFrom: covered[0].id,
            coversTo: coversTo,
            coversDigest: ContextCheckpoint.coversDigest(Array(covered[0...1])),
            messagesCovered: 2,
            userMessageIds: [history[0].id.uuidString],
            text: "<oriveo-context-checkpoint>\n## Goal\n</oriveo-context-checkpoint>",
            summary: "## Goal",
            language: "en",
            model: Self.grokModelID,
            packerVersion: ContextCheckpoint.packerVersion,
            createdAt: 1_700_000_000_123,
            cost: nil
        )

        let named = try #require(ContextCompactionSeparator.make(
            latest: row, messages: history, rhoHi: 0.5, modelName: { $0 == Self.grokModelID ? "Grok 4.7" : nil }
        ))
        #expect(named.model == "Grok 4.7")
        let missing = try #require(ContextCompactionSeparator.make(
            latest: row, messages: history, rhoHi: 0.5, modelName: { _ in nil }
        ))
        #expect(missing.model == Self.grokModelID)
        let blank = try #require(ContextCompactionSeparator.make(
            latest: row, messages: history, rhoHi: 0.5, modelName: { _ in "  " }
        ))
        #expect(blank.model == Self.grokModelID)

        // Production lookup: this platform's model catalog
        let (state, conversation) = try await Self.grokConversation("context-separator-name")
        let lookup = ContextCompactionSeparator.modelNameLookup(in: state, providerID: conversation.providerID)
        #expect(lookup(Self.grokModelID) == "Grok 4.7")
        #expect(lookup("no-such-model") == nil)
        let resolved = try #require(ContextCompactionSeparator.make(
            latest: row, messages: history, rhoHi: 0.5, modelName: lookup
        ))
        #expect(resolved.model == "Grok 4.7")
    }
}
