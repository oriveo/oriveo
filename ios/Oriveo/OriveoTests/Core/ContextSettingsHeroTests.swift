import Foundation
import OriveoProviderKit
import Testing
@testable import Oriveo

/// Overview card at the top of Settings > Context: `ContextDefaultCapSetting.hero(cap:)` matches the shared fixture case by case
/// `shared/ui-contracts/context-settings-hero.v1.json` (same 6 cases as Android); the 11 new string keys resolve in all 16 languages.
@Suite("Context settings hero", .serialized)
@MainActor
struct ContextSettingsHeroTests {

    private static let locales = [
        "ar", "de", "en", "es", "fr", "hi", "id", "ja", "ko", "pt-BR", "ru", "th", "tr", "vi", "zh-Hans", "zh-Hant",
    ]

    static let heroSettingsKeys = [
        "settings_context_hero_label",
        "settings_context_hero_caption_auto",
        "settings_context_hero_caption_unlimited",
        "settings_context_hero_caption_custom",
        "settings_context_hero_full_window",
        "settings_context_scale_price_line",
        "settings_context_scale_window",
        "settings_context_cost_none",
        "settings_context_cost_extra",
        "settings_context_custom_min",
        "settings_context_per_chat",
    ]

    // MARK: Fixtures

    private static func fixture() throws -> [String: Any] {
        var cursor = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while cursor.path != "/" {
            let candidate = cursor.appendingPathComponent("shared/ui-contracts/context-settings-hero.v1.json")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: candidate)) as? [String: Any])
            }
            cursor.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }

    private static func fixtureCase(_ name: String) throws -> [String: Any] {
        let cases = try #require(try fixture()["cases"] as? [[String: Any]])
        return try #require(cases.first { $0["name"] as? String == name }, "fixture is missing case \(name)")
    }

    private static func cap(_ raw: [String: Any]) throws -> ContextBudgetCap {
        switch try #require(raw["kind"] as? String) {
        case "auto": return .auto
        case "unlimited": return .unlimited
        case "custom": return .custom(try #require(raw["tokens"] as? Int))
        case let other: throw CocoaError(.coderInvalidValue, userInfo: [NSDebugDescriptionErrorKey: other])
        }
    }

    /// The overview card produced by the production function matches the fixture field by field: value, unit presence, caption key, fill ratio (+/-0.001).
    private static func expectCase(_ name: String) throws {
        let testCase = try fixtureCase(name)
        let hero = ContextDefaultCapSetting.hero(cap: try cap(try #require(testCase["cap"] as? [String: Any])))

        switch try #require(testCase["valueKind"] as? String) {
        case "count":
            let tokens = try #require(testCase["valueTokens"] as? Int)
            #expect(hero.valueTokens == tokens, "\(name).valueTokens")
            #expect(hero.valueText == ContextDefaultCapSetting.isolatedCount(tokens), "\(name).valueText")
        case "fullWindow":
            #expect(hero.valueTokens == nil, "\(name).valueTokens")
            #expect(hero.valueText == L10n.tr("settings_context_hero_full_window", table: .settings), "\(name).valueText")
        default:
            Issue.record("\(name): unknown valueKind")
        }
        #expect(hero.showsUnit == (try #require(testCase["hasUnit"] as? Bool)), "\(name).hasUnit")
        #expect(hero.captionKey == (try #require(testCase["captionKey"] as? String)), "\(name).captionKey")
        let fill = try #require(testCase["fill"] as? Double)
        #expect(abs(hero.fill - fill) <= 0.001, "\(name).fill: actual \(hero.fill) expected \(fill)")
        // The caption resolves to real text through the production path, not the key itself
        #expect(hero.caption != hero.captionKey, "\(name).caption is unresolved")
    }

    @Test func fixture_constants_match_production() throws {
        let constants = try #require(try Self.fixture()["constants"] as? [String: Any])
        #expect(constants["autoCapDefault"] as? Int == ContextBudget.autoCapDefault)
        #expect(constants["autoFill"] as? Double == ContextDefaultCapSetting.heroAutoFill)
        #expect(constants["priceLineMarker"] as? Double == ContextDefaultCapSetting.heroPriceLineMarker)
        #expect(constants["minFill"] as? Double == ContextDefaultCapSetting.heroMinFill)
        #expect(constants["maxFill"] as? Double == ContextDefaultCapSetting.heroMaxFill)
        let cases = try #require(try Self.fixture()["cases"] as? [[String: Any]])
        #expect(cases.count == 6)
    }

    @Test func hero_auto() throws { try Self.expectCase("auto") }
    @Test func hero_unlimited() throws { try Self.expectCase("unlimited") }
    @Test func hero_custom_min_clamps_up() throws { try Self.expectCase("custom_min_clamps_up") }
    @Test func hero_custom_half_default() throws { try Self.expectCase("custom_half_default") }
    @Test func hero_custom_equals_auto_default() throws { try Self.expectCase("custom_equals_auto_default") }
    @Test func hero_custom_huge_clamps_down() throws { try Self.expectCase("custom_huge_clamps_down") }

    /// While the custom input is uncommitted, the overview card and the echo read the same preview: 21000 is clamped to the 32000 floor; an unparsable input falls back to the saved value; auto / unlimited are unaffected by the input.
    @Test func hero_follows_custom_preview() throws {
        let typing = ContextDefaultCapSetting.heroCap(stored: .custom(216_000), customText: "21000", previous: 216_000)
        #expect(typing == .custom(32_000))
        let hero = ContextDefaultCapSetting.hero(cap: typing)
        #expect(hero.valueTokens == 32_000)
        #expect(hero.captionKey == "settings_context_hero_caption_custom")
        #expect(ContextDefaultCapSetting.heroCap(stored: .custom(216_000), customText: "abc", previous: 216_000) == .custom(216_000))
        #expect(ContextDefaultCapSetting.heroCap(stored: .auto, customText: "21000", previous: 256_000) == .auto)
        #expect(ContextDefaultCapSetting.heroCap(stored: .unlimited, customText: "21000", previous: 256_000) == .unlimited)
    }

    @Test func hero_strings_present_in_16_locales() throws {
        for locale in Self.locales {
            let path = try #require(Bundle.main.path(forResource: locale, ofType: "lproj"), "App bundle is missing \(locale).lproj")
            let bundle = try #require(Bundle(path: path))
            for key in Self.heroSettingsKeys {
                let resolved = bundle.localizedString(forKey: key, value: key, table: "Settings")
                #expect(resolved != key, "\(locale) · \(key) not found")
                #expect(!resolved.isEmpty, "\(locale) · \(key) is empty")
            }
        }
    }
}
