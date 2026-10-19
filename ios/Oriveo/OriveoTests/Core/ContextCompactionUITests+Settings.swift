import Foundation
import Testing
@testable import Oriveo

/// The Settings > Context single choice writes contextAISummaryEnabled (stored on this device only, default false);
/// all 34 compaction strings can be found in the compiled output of the 16 languages.
extension ContextCompactionUITests {

    static let compactionChatKeys = [
        "context_compaction_summary_line1",
        "context_compaction_summary_line2",
        "context_compaction_fallback_line1",
        "context_compaction_fallback_line2",
        "context_compaction_detail_title",
        "context_compaction_detail_summary",
        "context_compaction_detail_kept",
        "context_compaction_detail_fallback_note",
        "context_compaction_detail_model",
        "context_compaction_detail_cost",
        "context_compaction_detail_cost_unavailable",
        "context_compaction_detail_no_extra_cost",
        "context_compaction_detail_time",
        "context_compaction_action_compact",
        "context_compaction_action_recompact",
        "context_compaction_action_clear",
        "context_compaction_action_new_chat_with_summary",
        "context_compaction_toast_noop",
        "context_compaction_toast_fallback",
        "context_compaction_toast_cleared",
        "context_compaction_in_progress",
        "context_compaction_cancel",
        "context_compaction_third_hint",
        "context_compaction_third_hint_new_chat",
        "context_compaction_third_hint_dismiss",
        "context_compaction_quote_label",
    ]

    static let compactionSettingsKeys = [
        "settings_context_title",
        "settings_context_overflow_header",
        "settings_context_mode_fallback",
        "settings_context_mode_fallback_hint",
        "settings_context_mode_ai",
        "settings_context_mode_ai_hint",
        "settings_context_overflow_footer",
        "settings_context_row_value_fallback",
    ]

    static let compactionLocales = [
        "en", "zh-Hans", "zh-Hant", "ja", "ko", "de", "fr", "es",
        "pt-BR", "ru", "tr", "id", "vi", "th", "hi", "ar",
    ]

    /// Same lookup as L10n.tr: the `<locale>.lproj` compiled into the app.
    private func compactionBundle(_ locale: String) throws -> Bundle {
        let path = try #require(Bundle.main.path(forResource: locale, ofType: "lproj"), "App bundle is missing \(locale).lproj")
        return try #require(Bundle(path: path))
    }

    @Test func strings_present_in_16_locales() throws {
        #expect(Self.compactionChatKeys.count + Self.compactionSettingsKeys.count == 34)
        for locale in Self.compactionLocales {
            let bundle = try compactionBundle(locale)
            for (keys, table) in [(Self.compactionChatKeys, L10n.Table.chat), (Self.compactionSettingsKeys, .settings)] {
                for key in keys {
                    let resolved = bundle.localizedString(forKey: key, value: key, table: table.rawValue)
                    #expect(resolved != key, "\(locale) · \(key) not found")
                    #expect(!resolved.isEmpty, "\(locale) · \(key) is empty")
                }
            }
        }

        // Spot check: concrete translations, plurals and positional arguments for en / zh-Hans / ar.
        let en = try compactionBundle("en")
        let zh = try compactionBundle("zh-Hans")
        let ar = try compactionBundle("ar")
        #expect(en.localizedString(forKey: "settings_context_title", value: nil, table: "Settings") == "Context")
        #expect(zh.localizedString(forKey: "settings_context_mode_ai", value: nil, table: "Settings") == "AI \u{6458}\u{8981}")
        #expect(zh.localizedString(forKey: "context_compaction_detail_cost_unavailable", value: nil, table: "Chat") == "\u{6682}\u{65E0}")

        let enLine1 = en.localizedString(forKey: "context_compaction_summary_line1", value: nil, table: "Chat")
        let enLocale = Locale(identifier: "en")
        #expect(String(format: enLine1, locale: enLocale, 1, "1.2k", "300")
            == "Condensed 1 earlier message · 1.2k → 300 tokens")
        #expect(String(format: enLine1, locale: enLocale, 4, "1.2k", "300")
            == "Condensed 4 earlier messages · 1.2k → 300 tokens")
        let zhLine1 = zh.localizedString(forKey: "context_compaction_summary_line1", value: nil, table: "Chat")
        #expect(String(format: zhLine1, locale: Locale(identifier: "zh-Hans"), 4, "1.2k", "300")
            == "\u{5DF2}\u{6574}\u{7406}\u{8F83}\u{65E9}\u{7684} 4 \u{6761}\u{6D88}\u{606F} · 1.2k → 300 token")
        let enLine2 = en.localizedString(forKey: "context_compaction_summary_line2", value: nil, table: "Chat")
        #expect(String(format: enLine2, "gpt-x") == "By gpt-x · View summary")

        let arKept = ar.localizedString(forKey: "context_compaction_detail_kept", value: nil, table: "Chat")
        let arFormatted = String(format: arKept, locale: L10n.formattingLocale(Locale(identifier: "ar")), 5)
        #expect(arFormatted != "context_compaction_detail_kept")
        #expect(!arFormatted.contains("%"))
    }

    @Test func settings_mode_roundtrip() throws {
        let previousUID = AppSessionStore.activeUID
        let uid = "context-settings-\(UUID().uuidString)"
        defer { AppSessionStore.switchToUser(previousUID) }
        AppSessionStore.switchToUser(uid)
        let state = AppState(seedDemoData: false, sessionUID: uid)

        // Default false = keep only the original words
        #expect(ContextSettingsMode.current(in: state) == .fallback)
        #expect(AppPreferencesStore.savedContextAISummaryEnabled == false)
        #expect(ContextSettingsMode.fallback.rowValue == L10n.tr("settings_context_row_value_fallback", table: .settings))

        ContextSettingsMode.aiSummary.apply(to: state)
        #expect(state.preferences.contextAISummaryEnabled)
        #expect(AppPreferencesStore.savedContextAISummaryEnabled)
        #expect(AppPreferencesStore.load().contextAISummaryEnabled)
        #expect(ContextSettingsMode.current(in: state) == .aiSummary)
        #expect(ContextSettingsMode.aiSummary.rowValue == L10n.tr("settings_context_mode_ai", table: .settings))

        ContextSettingsMode.fallback.apply(to: state)
        #expect(state.preferences.contextAISummaryEnabled == false)
        #expect(AppPreferencesStore.savedContextAISummaryEnabled == false)
        #expect(ContextSettingsMode.current(in: state) == .fallback)
    }
}
