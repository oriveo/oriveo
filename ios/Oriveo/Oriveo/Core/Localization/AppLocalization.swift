import Foundation
import SwiftUI


enum AppLanguage: String, Hashable {
    case english = "en"
    case chineseSimplified = "zh-Hans"
    case chineseTraditional = "zh-Hant"
    case japanese = "ja"
    case korean = "ko"
    case spanish = "es"
    case french = "fr"
    case german = "de"
    case portuguese = "pt-BR"
    case arabic = "ar"
    case hindi = "hi"
    case indonesian = "id"
    case vietnamese = "vi"
    case thai = "th"
    case turkish = "tr"
    case russian = "ru"

    static var systemPreferred: AppLanguage {
        let preferred = (UserDefaults.standard.array(forKey: "AppleLanguages") as? [String]) ?? []
        let candidates = preferred.isEmpty ? [Locale.autoupdatingCurrent.identifier] : preferred
        return resolve(fromPreferredIdentifiers: candidates)
    }

    static func resolve(fromPreferredIdentifiers identifiers: [String]) -> AppLanguage {
        for identifier in identifiers {
            if let matched = match(identifier) { return matched }
        }
        return .english
    }

    private static func match(_ identifier: String) -> AppLanguage? {
        let id = identifier.lowercased().replacingOccurrences(of: "_", with: "-")

        if id.hasPrefix("zh-hant") || id.hasPrefix("zh-tw") || id.hasPrefix("zh-hk") {
            return .chineseTraditional
        }
        if id.hasPrefix("zh") { return .chineseSimplified }
        if id.hasPrefix("ja") { return .japanese }
        if id.hasPrefix("ko") { return .korean }
        if id.hasPrefix("es") { return .spanish }
        if id.hasPrefix("fr") { return .french }
        if id.hasPrefix("de") { return .german }
        if id.hasPrefix("pt") { return .portuguese }
        if id.hasPrefix("ar") { return .arabic }
        if id.hasPrefix("hi") { return .hindi }
        if id.hasPrefix("id") { return .indonesian }
        if id.hasPrefix("vi") { return .vietnamese }
        if id.hasPrefix("th") { return .thai }
        if id.hasPrefix("tr") { return .turkish }
        if id.hasPrefix("ru") { return .russian }
        if id.hasPrefix("en") { return .english }

        return nil
    }

    var locale: Locale {
        Locale(identifier: rawValue)
    }
}


enum AppPreferencesStore {
    private enum Key {
        static let theme = "oriveo.preferences.theme"
        static let language = "oriveo.preferences.language"
        static let memoryText = "oriveo.preferences.memoryText"
        static let memoryAntiForgetEnabled = "oriveo.preferences.memoryAntiForgetEnabled"
        static let memoryAntiForgetText = "oriveo.preferences.memoryAntiForgetText"
        static let memoryUpdatedAt = "oriveo.preferences.memoryUpdatedAt"
        static let memoryUsageCount = "oriveo.preferences.memoryUsageCount"
        static let memoryUsageConversationIDs = "oriveo.preferences.memoryUsageConversationIDs"
        static let memoryHasSeen = "oriveo.preferences.memoryHasSeen"
        static let pinnedConversationIDs = "oriveo.preferences.pinnedConversationIDs"
        static let pinnedConversationIDsUpdatedAt = "oriveo.preferences.pinnedConversationIDsUpdatedAt"
    }

    private static let lock = NSLock()
    private static var cachedThemeRawValue = UserDefaults.standard.string(forKey: Key.theme)
    private static var cachedLanguageRawValue = UserDefaults.standard.string(forKey: Key.language)

    private static let accountScopedKeys: [String] = [
        Key.memoryText,
        Key.memoryAntiForgetEnabled,
        Key.memoryAntiForgetText,
        Key.memoryUpdatedAt,
        Key.memoryUsageCount,
        Key.memoryUsageConversationIDs,
        Key.memoryHasSeen,
        Key.pinnedConversationIDs,
        Key.pinnedConversationIDsUpdatedAt,
    ]

    private static func scopedKey(_ key: String, uid: String = AppSessionStore.activeUID) -> String {
        "\(key).\(uid)"
    }

    private static func shouldFallbackToLegacyKey(for uid: String) -> Bool {
        uid != "guest"
    }

    private static func accountString(_ key: String, uid: String = AppSessionStore.activeUID) -> String? {
        let defaults = UserDefaults.standard
        if let value = defaults.string(forKey: scopedKey(key, uid: uid)) {
            return value
        }
        if shouldFallbackToLegacyKey(for: uid) {
            return defaults.string(forKey: key)
        }
        return nil
    }

    private static func accountBool(_ key: String, uid: String = AppSessionStore.activeUID) -> Bool {
        let defaults = UserDefaults.standard
        let scoped = scopedKey(key, uid: uid)
        if defaults.object(forKey: scoped) != nil {
            return defaults.bool(forKey: scoped)
        }
        if shouldFallbackToLegacyKey(for: uid), defaults.object(forKey: key) != nil {
            return defaults.bool(forKey: key)
        }
        return false
    }

    private static func accountDate(_ key: String, uid: String = AppSessionStore.activeUID) -> Date? {
        let defaults = UserDefaults.standard
        if let value = defaults.object(forKey: scopedKey(key, uid: uid)) as? Date {
            return value
        }
        if shouldFallbackToLegacyKey(for: uid) {
            return defaults.object(forKey: key) as? Date
        }
        return nil
    }

    private static func accountStringArray(_ key: String, uid: String = AppSessionStore.activeUID) -> [String] {
        let defaults = UserDefaults.standard
        if let value = defaults.stringArray(forKey: scopedKey(key, uid: uid)) {
            return value
        }
        if shouldFallbackToLegacyKey(for: uid) {
            return defaults.stringArray(forKey: key) ?? []
        }
        return []
    }

    static var savedTheme: ThemeOption? {
        lock.lock()
        let rawValue = cachedThemeRawValue
        lock.unlock()
        guard let rawValue else { return nil }
        return ThemeOption(rawValue: rawValue)
    }

    static var savedLanguage: LanguageOption? {
        lock.lock()
        let rawValue = cachedLanguageRawValue
        lock.unlock()
        guard let rawValue else { return nil }
        if rawValue == "chinese" { return .chineseSimplified }
        return LanguageOption(rawValue: rawValue)
    }

    // MARK: - Memory

    static var savedMemoryText: String {
        get { accountString(Key.memoryText) ?? "" }
        set {
            UserDefaults.standard.set(newValue, forKey: scopedKey(Key.memoryText))
        }
    }

    static var savedMemoryAntiForgetEnabled: Bool {
        get { accountBool(Key.memoryAntiForgetEnabled) }
        set { UserDefaults.standard.set(newValue, forKey: scopedKey(Key.memoryAntiForgetEnabled)) }
    }

    static var savedMemoryAntiForgetText: String {
        get { accountString(Key.memoryAntiForgetText) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: scopedKey(Key.memoryAntiForgetText)) }
    }

    static var savedMemoryUpdatedAt: Date? {
        get { accountDate(Key.memoryUpdatedAt) }
        set { UserDefaults.standard.set(newValue, forKey: scopedKey(Key.memoryUpdatedAt)) }
    }

    static var memoryUsageCount: Int {
        get {
            let defaults = UserDefaults.standard
            let scoped = scopedKey(Key.memoryUsageCount)
            if defaults.object(forKey: scoped) != nil {
                return defaults.integer(forKey: scoped)
            }
            if shouldFallbackToLegacyKey(for: AppSessionStore.activeUID), defaults.object(forKey: Key.memoryUsageCount) != nil {
                return defaults.integer(forKey: Key.memoryUsageCount)
            }
            return 0
        }
        set { UserDefaults.standard.set(newValue, forKey: scopedKey(Key.memoryUsageCount)) }
    }

    static var memoryUsageConversationIDs: [String] {
        get { accountStringArray(Key.memoryUsageConversationIDs) }
        set { UserDefaults.standard.set(newValue, forKey: scopedKey(Key.memoryUsageConversationIDs)) }
    }

    static var memoryHasSeen: Bool {
        get { accountBool(Key.memoryHasSeen) }
        set { UserDefaults.standard.set(newValue, forKey: scopedKey(Key.memoryHasSeen)) }
    }

    // MARK: - Pinned Conversations

    static var savedPinnedConversationIDs: [UUID] {
        get { accountStringArray(Key.pinnedConversationIDs).compactMap { UUID(uuidString: $0) } }
        set {
            UserDefaults.standard.set(
                newValue.map { $0.uuidString },
                forKey: scopedKey(Key.pinnedConversationIDs)
            )
        }
    }

    static var savedPinnedConversationIDsUpdatedAt: Date? {
        get { accountDate(Key.pinnedConversationIDsUpdatedAt) }
        set {
            let scoped = scopedKey(Key.pinnedConversationIDsUpdatedAt)
            if let newValue {
                UserDefaults.standard.set(newValue, forKey: scoped)
            } else {
                UserDefaults.standard.removeObject(forKey: scoped)
            }
        }
    }

    // MARK: - Load / Save

    static func load() -> AppPreference {
        let storedTheme = savedTheme
        return AppPreference(
            theme: storedTheme ?? .dark,
            themeSetByUser: storedTheme != nil,
            language: savedLanguage ?? .system,
            memoryText: savedMemoryText,
            memoryAntiForgetEnabled: savedMemoryAntiForgetEnabled,
            memoryAntiForgetText: savedMemoryAntiForgetText,
            memoryUpdatedAt: savedMemoryUpdatedAt,
            pinnedConversationIDs: savedPinnedConversationIDs,
            pinnedConversationIDsUpdatedAt: savedPinnedConversationIDsUpdatedAt
        )
    }

    static func save(_ preference: AppPreference) {
        lock.lock()
        cachedThemeRawValue = preference.themeSetByUser ? preference.theme.rawValue : nil
        cachedLanguageRawValue = preference.language.rawValue
        lock.unlock()

        let defaults = UserDefaults.standard
        if preference.themeSetByUser {
            defaults.set(preference.theme.rawValue, forKey: Key.theme)
        } else {
            defaults.removeObject(forKey: Key.theme)
        }
        defaults.set(preference.language.rawValue, forKey: Key.language)
        defaults.set(preference.memoryText, forKey: scopedKey(Key.memoryText))
        defaults.set(preference.memoryAntiForgetEnabled, forKey: scopedKey(Key.memoryAntiForgetEnabled))
        defaults.set(preference.memoryAntiForgetText, forKey: scopedKey(Key.memoryAntiForgetText))
        defaults.set(preference.memoryUpdatedAt, forKey: scopedKey(Key.memoryUpdatedAt))
        defaults.set(
            preference.pinnedConversationIDs.map { $0.uuidString },
            forKey: scopedKey(Key.pinnedConversationIDs)
        )
        let pinnedTsKey = scopedKey(Key.pinnedConversationIDsUpdatedAt)
        if let pinnedTs = preference.pinnedConversationIDsUpdatedAt {
            defaults.set(pinnedTs, forKey: pinnedTsKey)
        } else {
            defaults.removeObject(forKey: pinnedTsKey)
        }
        L10n.invalidateCache()
    }

    static func copyAccountData(from sourceUID: String, to targetUID: String) {
        let defaults = UserDefaults.standard
        for key in accountScopedKeys {
            let sourceKey = scopedKey(key, uid: sourceUID)
            let targetKey = scopedKey(key, uid: targetUID)
            if let value = defaults.object(forKey: sourceKey) {
                defaults.set(value, forKey: targetKey)
            }
        }
    }

    static func clearAccountData(for uid: String) {
        let defaults = UserDefaults.standard
        for key in accountScopedKeys {
            defaults.removeObject(forKey: scopedKey(key, uid: uid))
            defaults.removeObject(forKey: key)
        }
    }
}


enum AppLocalization {
    static var currentLanguage: AppLanguage {
        let languagePreference = AppPreferencesStore.savedLanguage ?? .system
        return languagePreference.effectiveLanguage
    }

    static var currentLocale: Locale {
        currentLanguage.locale
    }
}

// MARK: - iOS system language authority

enum AppLanguagePreferencePolicy {
    static func usesSystemLanguageSetting(storedPreference: LanguageOption?) -> Bool {
        storedPreference == nil || storedPreference == .system
    }

    static func shouldApplySyncedLanguage(storedPreference: LanguageOption?) -> Bool {
        !usesSystemLanguageSetting(storedPreference: storedPreference)
    }

    static func displayedLanguage(
        preference: LanguageOption,
        systemLanguage: AppLanguage
    ) -> LanguageOption {
        preference == .system ? LanguageOption(appLanguage: systemLanguage) : preference
    }
}


enum L10n {
    enum Table: String {
        case localizable = "Localizable"
        case backup = "Backup"
        case chat = "Chat"
        case home = "Home"
        case onboarding = "Onboarding"
        case providers = "Providers"
        case settings = "Settings"
        case skills = "Skills"
        case notes = "Notes"
    }

    private static let lock = NSLock()
    private static var cachedLanguageID: String?
    private static var cachedBundle: Bundle?

    private static var bundle: Bundle {
        let language = AppLocalization.currentLanguage.rawValue

        lock.lock()
        if cachedLanguageID == language, let cachedBundle {
            lock.unlock()
            return cachedBundle
        }
        lock.unlock()

        let resolvedBundle: Bundle
        if let path = Bundle.main.path(forResource: language, ofType: "lproj"),
           let bundle = Bundle(path: path) {
            resolvedBundle = bundle
        } else if let path = Bundle.main.path(forResource: "en", ofType: "lproj"),
                  let bundle = Bundle(path: path) {
            resolvedBundle = bundle
        } else {
            resolvedBundle = .main
        }

        lock.lock()
        cachedLanguageID = language
        cachedBundle = resolvedBundle
        lock.unlock()

        return resolvedBundle
    }

    static func invalidateCache() {
        lock.lock()
        cachedLanguageID = nil
        cachedBundle = nil
        lock.unlock()
    }

    static func tr(_ key: String) -> String {
        tr(key, table: .localizable)
    }

    static func tr(_ key: String, table: Table) -> String {
        bundle.localizedString(forKey: key, value: key, table: table.rawValue)
    }
}
