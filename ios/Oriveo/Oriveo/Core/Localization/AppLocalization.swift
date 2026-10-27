import Foundation
import OriveoProviderKit
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

    private static let systemPreferredLock = NSLock()
    nonisolated(unsafe) private static var cachedSystemPreferred: AppLanguage?
    #if DEBUG
    nonisolated(unsafe) private static var debugSystemPreferredResolveStorage = 0

    /// DEBUG only: how many times the system preferred language was actually re-resolved
    /// (read AppleLanguages and matched each entry).
    static var debugSystemPreferredResolveCount: Int {
        get {
            systemPreferredLock.lock()
            defer { systemPreferredLock.unlock() }
            return debugSystemPreferredResolveStorage
        }
        set {
            systemPreferredLock.lock()
            defer { systemPreferredLock.unlock() }
            debugSystemPreferredResolveStorage = newValue
        }
    }
    #endif

    /// When following the system language, every `L10n.tr` call lands here. A list row carries a
    /// dozen strings and asks again on every layout pass, so reading AppleLanguages and matching it
    /// each time showed up as `replacingOccurrences` on the main thread in view bodies.
    /// Resolve once per process and let the locale change notification invalidate the cache.
    private static let localeChangeObserver: NSObjectProtocol = NotificationCenter.default.addObserver(
        forName: NSLocale.currentLocaleDidChangeNotification,
        object: nil,
        queue: nil
    ) { _ in
        AppLanguage.invalidateSystemPreferredCache()
    }

    static var systemPreferred: AppLanguage {
        _ = localeChangeObserver
        systemPreferredLock.lock()
        if let cachedSystemPreferred {
            systemPreferredLock.unlock()
            return cachedSystemPreferred
        }
        #if DEBUG
        debugSystemPreferredResolveStorage += 1
        #endif
        systemPreferredLock.unlock()

        let preferred = (UserDefaults.standard.array(forKey: "AppleLanguages") as? [String]) ?? []
        let candidates = preferred.isEmpty ? [Locale.autoupdatingCurrent.identifier] : preferred
        let resolved = resolve(fromPreferredIdentifiers: candidates)

        systemPreferredLock.lock()
        cachedSystemPreferred = resolved
        systemPreferredLock.unlock()
        return resolved
    }

    nonisolated static func invalidateSystemPreferredCache() {
        systemPreferredLock.lock()
        cachedSystemPreferred = nil
        systemPreferredLock.unlock()
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
        static let darkPalette = "oriveo.preferences.darkPalette"
        static let darkPaletteCustom = "oriveo.preferences.darkPaletteCustom"
        static let language = "oriveo.preferences.language"
        static let memoryText = "oriveo.preferences.memoryText"
        static let memoryAntiForgetEnabled = "oriveo.preferences.memoryAntiForgetEnabled"
        static let memoryAntiForgetText = "oriveo.preferences.memoryAntiForgetText"
        static let memoryUpdatedAt = "oriveo.preferences.memoryUpdatedAt"
        static let memoryHasSeen = "oriveo.preferences.memoryHasSeen"
        static let memoryTextDigest = "oriveo.preferences.memoryTextDigest"
        static let memoryItemsMigrated = "oriveo.preferences.memoryItemsMigrated"
        static let memoryDeviceId = "oriveo.preferences.memoryDeviceId"
        static let pinnedConversationIDs = "oriveo.preferences.pinnedConversationIDs"
        static let pinnedConversationIDsUpdatedAt = "oriveo.preferences.pinnedConversationIDsUpdatedAt"
        static let contextAISummaryEnabled = "oriveo.preferences.contextAISummaryEnabled"
        static let contextDefaultCap = "oriveo.preferences.contextDefaultCap"
        static let contextPriceLineReminderEnabled = "oriveo.preferences.contextPriceLineReminderEnabled"
        static let memoryAutoSuggestEnabled = "oriveo.preferences.memoryAutoSuggestEnabled"
    }

    private static let lock = NSLock()
    private static var cachedThemeRawValue = UserDefaults.standard.string(forKey: Key.theme)
    private static var cachedLanguageRawValue = UserDefaults.standard.string(forKey: Key.language)

    private static let accountScopedKeys: [String] = [
        Key.memoryText,
        Key.memoryAntiForgetEnabled,
        Key.memoryAntiForgetText,
        Key.memoryUpdatedAt,
        Key.memoryHasSeen,
        Key.memoryTextDigest,
        Key.pinnedConversationIDs,
        Key.pinnedConversationIDsUpdatedAt,
        Key.contextAISummaryEnabled,
        Key.contextDefaultCap,
        Key.contextPriceLineReminderEnabled,
        Key.memoryAutoSuggestEnabled,
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

    private static func accountBool(
        _ key: String,
        uid: String = AppSessionStore.activeUID,
        defaultValue: Bool = false
    ) -> Bool {
        let defaults = UserDefaults.standard
        let scoped = scopedKey(key, uid: uid)
        if defaults.object(forKey: scoped) != nil {
            return defaults.bool(forKey: scoped)
        }
        if shouldFallbackToLegacyKey(for: uid), defaults.object(forKey: key) != nil {
            return defaults.bool(forKey: key)
        }
        return defaultValue
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

    /// Raw dark palette string; a non-string value is treated as unset.
    static var savedDarkPalette: String? {
        UserDefaults.standard.object(forKey: Key.darkPalette) as? String
    }

    /// Raw string of the custom palette seed color; a non-string value counts as unset.
    static var savedDarkPaletteCustom: String? {
        UserDefaults.standard.object(forKey: Key.darkPaletteCustom) as? String
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

    static var memoryHasSeen: Bool {
        get { accountBool(Key.memoryHasSeen) }
        set { UserDefaults.standard.set(newValue, forKey: scopedKey(Key.memoryHasSeen)) }
    }

    static var savedMemoryTextDigest: String? {
        get { accountString(Key.memoryTextDigest) }
        set {
            let scoped = scopedKey(Key.memoryTextDigest)
            if let newValue {
                UserDefaults.standard.set(newValue, forKey: scoped)
            } else {
                UserDefaults.standard.removeObject(forKey: scoped)
            }
        }
    }

    /// Whether the partition's legacy fields have been migrated into memory items. Stored locally only, and not copied along with guest data (each partition migrates on its own).
    static func memoryItemsMigrated(uid: String) -> Bool {
        UserDefaults.standard.bool(forKey: scopedKey(Key.memoryItemsMigrated, uid: uid))
    }

    static func setMemoryItemsMigrated(_ migrated: Bool, uid: String) {
        UserDefaults.standard.set(migrated, forKey: scopedKey(Key.memoryItemsMigrated, uid: uid))
    }

    /// This device's memory item deviceId (a random lowercase UUID generated on first read); not partitioned.
    static var memoryDeviceId: String {
        lock.lock()
        defer { lock.unlock() }
        let defaults = UserDefaults.standard
        if let existing = defaults.string(forKey: Key.memoryDeviceId), !existing.isEmpty {
            return existing
        }
        let created = UUID().uuidString.lowercased()
        defaults.set(created, forKey: Key.memoryDeviceId)
        return created
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

    // MARK: - Context compaction

    /// Defaults to false (old data has no such key).
    static var savedContextAISummaryEnabled: Bool {
        get { accountBool(Key.contextAISummaryEnabled) }
        set { UserDefaults.standard.set(newValue, forKey: scopedKey(Key.contextAISummaryEnabled)) }
    }

    /// Global default context cap, stored as storageText; missing or undecodable falls back to .auto.
    static var savedContextDefaultCap: ContextBudgetCap {
        get { accountString(Key.contextDefaultCap).flatMap(ContextBudgetCap.init(storageText:)) ?? .auto }
        set { UserDefaults.standard.set(newValue.storageText, forKey: scopedKey(Key.contextDefaultCap)) }
    }

    /// Reminder when the price line is crossed; defaults to true (old data has no such key).
    static var savedContextPriceLineReminderEnabled: Bool {
        get { accountBool(Key.contextPriceLineReminderEnabled, defaultValue: true) }
        set { UserDefaults.standard.set(newValue, forKey: scopedKey(Key.contextPriceLineReminderEnabled)) }
    }

    // MARK: - Memory auto-suggest

    /// Memory auto-suggestion switch: a local preference scoped per partition, on by default; not included in backups (not part of AppPreference).
    static func memoryAutoSuggestEnabled(uid: String = AppSessionStore.activeUID) -> Bool {
        accountBool(Key.memoryAutoSuggestEnabled, uid: uid, defaultValue: true)
    }

    static func setMemoryAutoSuggestEnabled(_ enabled: Bool, uid: String = AppSessionStore.activeUID) {
        UserDefaults.standard.set(enabled, forKey: scopedKey(Key.memoryAutoSuggestEnabled, uid: uid))
    }

    // MARK: - Load / Save

    static func load() -> AppPreference {
        let storedTheme = savedTheme
        return AppPreference(
            theme: storedTheme ?? .dark,
            themeSetByUser: storedTheme != nil,
            darkPalette: savedDarkPalette,
            darkPaletteCustom: savedDarkPaletteCustom,
            language: savedLanguage ?? .system,
            memoryText: savedMemoryText,
            memoryAntiForgetEnabled: savedMemoryAntiForgetEnabled,
            memoryAntiForgetText: savedMemoryAntiForgetText,
            memoryUpdatedAt: savedMemoryUpdatedAt,
            memoryTextDigest: savedMemoryTextDigest,
            pinnedConversationIDs: savedPinnedConversationIDs,
            pinnedConversationIDsUpdatedAt: savedPinnedConversationIDsUpdatedAt,
            contextAISummaryEnabled: savedContextAISummaryEnabled,
            contextDefaultCap: savedContextDefaultCap,
            contextPriceLineReminderEnabled: savedContextPriceLineReminderEnabled
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
        // darkPalette follows theme: when unset the key stays absent
        if let darkPalette = preference.darkPalette {
            defaults.set(darkPalette, forKey: Key.darkPalette)
        } else {
            defaults.removeObject(forKey: Key.darkPalette)
        }
        if let darkPaletteCustom = preference.darkPaletteCustom {
            defaults.set(darkPaletteCustom, forKey: Key.darkPaletteCustom)
        } else {
            defaults.removeObject(forKey: Key.darkPaletteCustom)
        }
        defaults.set(preference.language.rawValue, forKey: Key.language)
        defaults.set(preference.memoryText, forKey: scopedKey(Key.memoryText))
        defaults.set(preference.memoryAntiForgetEnabled, forKey: scopedKey(Key.memoryAntiForgetEnabled))
        defaults.set(preference.memoryAntiForgetText, forKey: scopedKey(Key.memoryAntiForgetText))
        defaults.set(preference.memoryUpdatedAt, forKey: scopedKey(Key.memoryUpdatedAt))
        savedMemoryTextDigest = preference.memoryTextDigest
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
        defaults.set(preference.contextAISummaryEnabled, forKey: scopedKey(Key.contextAISummaryEnabled))
        defaults.set(preference.contextDefaultCap.storageText, forKey: scopedKey(Key.contextDefaultCap))
        defaults.set(
            preference.contextPriceLineReminderEnabled,
            forKey: scopedKey(Key.contextPriceLineReminderEnabled)
        )
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
        defaults.removeObject(forKey: scopedKey(Key.memoryItemsMigrated, uid: uid))
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
        case mcp = "MCP"
        case voice = "Voice"
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

    /// Formats by the in-app language: `String.localizedStringWithFormat` picks plural forms from the
    /// system `Locale.current`, which selects the wrong form when the app language differs (e.g. ru 5 falls into other).
    static func format(_ format: String, _ arguments: CVarArg...) -> String {
        String(format: format, locale: formattingLocale(AppLocalization.currentLocale), arguments: arguments)
    }

    /// Same, with an explicit locale (for tests and known target languages).
    static func format(_ format: String, locale: Locale, _ arguments: CVarArg...) -> String {
        String(format: format, locale: formattingLocale(locale), arguments: arguments)
    }

    /// Counts in the Arabic UI always use Latin digits: since CLDR 46 ar defaults to latn, but the ICU of older systems
    /// still produces Arabic-Indic digits, so it is pinned explicitly. Plural categories depend only on the language,
    /// not on the numbering system. Other languages are returned unchanged.
    static func formattingLocale(_ locale: Locale) -> Locale {
        guard locale.language.languageCode?.identifier == "ar" else { return locale }
        var components = Locale.Components(locale: locale)
        components.numberingSystem = Locale.NumberingSystem("latn")
        return Locale(components: components)
    }
}
