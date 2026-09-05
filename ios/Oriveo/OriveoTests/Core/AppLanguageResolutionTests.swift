import Foundation
import Testing
@testable import Oriveo

@Suite("AppLanguageResolution")
@MainActor
struct AppLanguageResolutionTests {

    @Test("Falls Through To Next Supported Preference")
    func fallsThroughToNextSupportedPreference() {
        #expect(AppLanguage.resolve(fromPreferredIdentifiers: ["sv-SE", "zh-Hans-CN"]) == .chineseSimplified)
        #expect(AppLanguage.resolve(fromPreferredIdentifiers: ["nb-NO", "ja-JP"]) == .japanese)
        #expect(AppLanguage.resolve(fromPreferredIdentifiers: ["pl-PL", "uk-UA", "ru-RU"]) == .russian)
    }

    @Test("First Supported Preference Wins")
    func firstSupportedPreferenceWins() {
        #expect(AppLanguage.resolve(fromPreferredIdentifiers: ["ja-JP", "zh-Hans-CN"]) == .japanese)
        #expect(AppLanguage.resolve(fromPreferredIdentifiers: ["en-US", "zh-Hans-CN"]) == .english)
    }

    @Test("Falls Back To English When Nothing Matches")
    func fallsBackToEnglishWhenNothingMatches() {
        #expect(AppLanguage.resolve(fromPreferredIdentifiers: ["sv-SE", "nb-NO", "fi-FI"]) == .english)
    }

    @Test("Empty Preferences Fall Back To English")
    func emptyPreferencesFallBackToEnglish() {
        #expect(AppLanguage.resolve(fromPreferredIdentifiers: []) == .english)
    }

    @Test("Chinese Splits By Script And Region")
    func chineseSplitsByScriptAndRegion() {
        #expect(AppLanguage.resolve(fromPreferredIdentifiers: ["zh-Hans-CN"]) == .chineseSimplified)
        #expect(AppLanguage.resolve(fromPreferredIdentifiers: ["zh-CN"]) == .chineseSimplified)
        #expect(AppLanguage.resolve(fromPreferredIdentifiers: ["zh-Hant-TW"]) == .chineseTraditional)
        #expect(AppLanguage.resolve(fromPreferredIdentifiers: ["zh-Hant-HK"]) == .chineseTraditional)
        #expect(AppLanguage.resolve(fromPreferredIdentifiers: ["zh-TW"]) == .chineseTraditional)
        #expect(AppLanguage.resolve(fromPreferredIdentifiers: ["zh-HK"]) == .chineseTraditional)
    }

    @Test("Normalizes Case And Separator")
    func normalizesCaseAndSeparator() {
        #expect(AppLanguage.resolve(fromPreferredIdentifiers: ["ZH_HANT_TW"]) == .chineseTraditional)
        #expect(AppLanguage.resolve(fromPreferredIdentifiers: ["ID_ID"]) == .indonesian)
        #expect(AppLanguage.resolve(fromPreferredIdentifiers: ["PT_BR"]) == .portuguese)
    }

    @Test("Regional Variants Map To Shipped Locale")
    func regionalVariantsMapToShippedLocale() {
        #expect(AppLanguage.resolve(fromPreferredIdentifiers: ["pt-PT"]) == .portuguese)
        #expect(AppLanguage.resolve(fromPreferredIdentifiers: ["es-MX"]) == .spanish)
        #expect(AppLanguage.resolve(fromPreferredIdentifiers: ["ar-EG"]) == .arabic)
    }

    @Test("Every Shipped Language Is Reachable")
    func everyShippedLanguageIsReachable() {
        let expectations: [(String, AppLanguage)] = [
            ("en-US", .english),
            ("zh-Hans", .chineseSimplified),
            ("zh-Hant", .chineseTraditional),
            ("ja-JP", .japanese),
            ("ko-KR", .korean),
            ("es-ES", .spanish),
            ("fr-FR", .french),
            ("de-DE", .german),
            ("pt-BR", .portuguese),
            ("ar-SA", .arabic),
            ("hi-IN", .hindi),
            ("id-ID", .indonesian),
            ("vi-VN", .vietnamese),
            ("th-TH", .thai),
            ("tr-TR", .turkish),
            ("ru-RU", .russian)
        ]
        for (identifier, expected) in expectations {
            #expect(
                AppLanguage.resolve(fromPreferredIdentifiers: [identifier]) == expected,
                "\(identifier) should resolve to \(expected.rawValue)"
            )
        }
    }

    @Test("System Language Setting Remains Device Authority")
    func systemLanguageSettingRemainsDeviceAuthority() {
        #expect(AppLanguagePreferencePolicy.usesSystemLanguageSetting(storedPreference: nil))
        #expect(AppLanguagePreferencePolicy.usesSystemLanguageSetting(storedPreference: .system))
        #expect(!AppLanguagePreferencePolicy.shouldApplySyncedLanguage(storedPreference: nil))
        #expect(!AppLanguagePreferencePolicy.shouldApplySyncedLanguage(storedPreference: .system))

        #expect(AppLanguagePreferencePolicy.shouldApplySyncedLanguage(storedPreference: .chineseSimplified))
    }

    @Test("Displayed Language Uses System App Language")
    func displayedLanguageUsesSystemAppLanguage() {
        #expect(
            AppLanguagePreferencePolicy.displayedLanguage(
                preference: .system,
                systemLanguage: .chineseSimplified
            ) == .chineseSimplified
        )
        #expect(
            AppLanguagePreferencePolicy.displayedLanguage(
                preference: .japanese,
                systemLanguage: .english
            ) == .japanese
        )
    }
}
