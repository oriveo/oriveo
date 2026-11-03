import Foundation
import Testing
@testable import Oriveo

@MainActor
@Suite("RecognitionLanguageSheet")
struct RecognitionLanguageSheetTests {
    private func makeSettings() -> VoiceEngineSettings {
        VoiceEngineSettings(defaults: UserDefaults(suiteName: "RecognitionLanguageSheetTests-\(UUID().uuidString)")!)
    }

    @Test("Rows match the settings option list; only the current item is checked")
    func rowsMatchSettingsOptionsAndCheckCurrent() throws {
        let options = VoiceSettingsModel.recognitionLanguageOptions()
        let current = try #require(options.last?.code)
        let model = RecognitionLanguageSheetModel(current: current, settings: makeSettings())
        #expect(model.rows.map(\.option) == options)
        #expect(model.rows.filter(\.isSelected).map(\.option.code) == [current])

        let automatic = RecognitionLanguageSheetModel(current: nil, settings: makeSettings())
        #expect(automatic.rows.filter(\.isSelected).map(\.option.code) == [nil])
        #expect(automatic.rows.first?.isSelected == true)
    }

    @Test("Selecting another language writes VoiceEngineSettings and reports changed; selecting the current item writes nothing and reports unchanged")
    func selectWritesSettingsAndReportsChanged() {
        let settings = makeSettings()
        settings.recognitionLanguage = "fr-FR"
        let model = RecognitionLanguageSheetModel(current: settings.recognitionLanguage, settings: settings)

        #expect(model.select("fr-FR") == false)
        #expect(settings.recognitionLanguage == "fr-FR")

        #expect(model.select("ja-JP") == true)
        #expect(settings.recognitionLanguage == "ja-JP")

        let back = RecognitionLanguageSheetModel(current: settings.recognitionLanguage, settings: settings)
        #expect(back.select(nil) == true)
        #expect(settings.recognitionLanguage == nil)
    }

    @Test("Pill language name uses the same lookup as the settings page: option title, nil = automatic; a region code outside the options gets the system language name in the UI language, and falls back to the raw code only when unrecognized")
    func displayNameUsesSettingsTitles() throws {
        let options = VoiceSettingsModel.recognitionLanguageOptions()
        for option in options {
            #expect(RecognitionLanguageSheetModel.displayName(option.code) == option.title)
        }
        #expect(RecognitionLanguageSheetModel.displayName(nil) == L10n.tr("Automatic", table: .voice))
        // Options contain only "en", not "en-US": the pill shows the system language name in the UI language (capitalized), not the raw code.
        #expect(!options.contains { $0.code == "en-US" })
        let locale = AppLocalization.currentLocale
        let system = try #require(locale.localizedString(forIdentifier: "en-US"))
        let expected = system.prefix(1).uppercased(with: locale) + system.dropFirst()
        #expect(RecognitionLanguageSheetModel.displayName("en-US") == expected)
        #expect(RecognitionLanguageSheetModel.displayName("en-US") != "en-US")
        #expect(RecognitionLanguageSheetModel.displayName("xx-YY") == "xx-YY")
    }
}
