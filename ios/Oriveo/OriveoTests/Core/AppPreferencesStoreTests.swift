import Foundation
import Testing
@testable import Oriveo

private enum AppPreferencesTestKeys {
    static let theme = "oriveo.preferences.theme"
    static let language = "oriveo.preferences.language"
    static let memoryText = "oriveo.preferences.memoryText"
    static let memoryAntiForgetEnabled = "oriveo.preferences.memoryAntiForgetEnabled"
    static let memoryAntiForgetText = "oriveo.preferences.memoryAntiForgetText"
    static let memoryUpdatedAt = "oriveo.preferences.memoryUpdatedAt"
    static let memoryUsageCount = "oriveo.preferences.memoryUsageCount"
    static let memoryUsageConversationIDs = "oriveo.preferences.memoryUsageConversationIDs"
    static let memoryHasSeen = "oriveo.preferences.memoryHasSeen"
}

private let appPreferencesAccountScopedKeys = [
    AppPreferencesTestKeys.memoryText,
    AppPreferencesTestKeys.memoryAntiForgetEnabled,
    AppPreferencesTestKeys.memoryAntiForgetText,
    AppPreferencesTestKeys.memoryUpdatedAt,
    AppPreferencesTestKeys.memoryUsageCount,
    AppPreferencesTestKeys.memoryUsageConversationIDs,
    AppPreferencesTestKeys.memoryHasSeen,
]

private func clearScopedPreferenceKeys(for uid: String) {
    let defaults = UserDefaults.standard
    for key in appPreferencesAccountScopedKeys {
        defaults.removeObject(forKey: "\(key).\(uid)")
    }
}

private func clearLegacyPreferenceKeys() {
    let defaults = UserDefaults.standard
    defaults.removeObject(forKey: AppPreferencesTestKeys.theme)
    defaults.removeObject(forKey: AppPreferencesTestKeys.language)
    for key in appPreferencesAccountScopedKeys {
        defaults.removeObject(forKey: key)
    }
}

private func resetPreferenceCaches() {
    let savedUID = AppSessionStore.activeUID
    AppSessionStore.activeUID = "guest"
    AppPreferencesStore.save(AppPreference(theme: .system, language: .system))
    AppPreferencesStore.clearAccountData(for: "guest")
    AppSessionStore.activeUID = savedUID
}

@Suite("AppPreferencesStore", .serialized)
struct AppPreferencesStoreTests {

    @Test("Theme Is Shared And Memory Is Scoped")
    func themeIsSharedAndMemoryIsScoped() {
        let savedUID = AppSessionStore.activeUID
        let uid1 = "prefs-user-1"
        let uid2 = "prefs-user-2"
        defer {
            AppSessionStore.activeUID = savedUID
            clearScopedPreferenceKeys(for: uid1)
            clearScopedPreferenceKeys(for: uid2)
            clearLegacyPreferenceKeys()
            resetPreferenceCaches()
        }

        clearScopedPreferenceKeys(for: uid1)
        clearScopedPreferenceKeys(for: uid2)
        clearLegacyPreferenceKeys()
        resetPreferenceCaches()

        AppSessionStore.activeUID = uid1
        AppPreferencesStore.save(
            AppPreference(
                theme: .dark,
                themeSetByUser: true,
                language: .english,
                memoryText: "memory-user-1",
                memoryAntiForgetEnabled: true,
                memoryAntiForgetText: "anti-forget-1",
                memoryUpdatedAt: Date(timeIntervalSince1970: 1_710_000_000)
            )
        )
        AppPreferencesStore.memoryUsageCount = 1
        AppPreferencesStore.memoryUsageConversationIDs = ["conversation-1"]
        AppPreferencesStore.memoryHasSeen = true

        AppSessionStore.activeUID = uid2
        AppPreferencesStore.save(
            AppPreference(
                theme: .light,
                themeSetByUser: true,
                language: .french,
                memoryText: "memory-user-2",
                memoryAntiForgetEnabled: false,
                memoryAntiForgetText: "anti-forget-2",
                memoryUpdatedAt: Date(timeIntervalSince1970: 1_720_000_000)
            )
        )
        AppPreferencesStore.memoryUsageCount = 2
        AppPreferencesStore.memoryUsageConversationIDs = ["conversation-2"]
        AppPreferencesStore.memoryHasSeen = false

        AppSessionStore.activeUID = uid1
        let user1Preference = AppPreferencesStore.load()
        #expect(AppPreferencesStore.savedTheme == .light)
        #expect(AppPreferencesStore.savedLanguage == .french)
        #expect(user1Preference.memoryText == "memory-user-1")
        #expect(user1Preference.memoryAntiForgetEnabled)
        #expect(user1Preference.memoryAntiForgetText == "anti-forget-1")
        #expect(AppPreferencesStore.memoryUsageCount == 1)
        #expect(AppPreferencesStore.memoryUsageConversationIDs == ["conversation-1"])
        #expect(AppPreferencesStore.memoryHasSeen)

        AppSessionStore.activeUID = uid2
        let user2Preference = AppPreferencesStore.load()
        #expect(AppPreferencesStore.savedTheme == .light)
        #expect(AppPreferencesStore.savedLanguage == .french)
        #expect(user2Preference.memoryText == "memory-user-2")
        #expect(!user2Preference.memoryAntiForgetEnabled)
        #expect(user2Preference.memoryAntiForgetText == "anti-forget-2")
        #expect(AppPreferencesStore.memoryUsageCount == 2)
        #expect(AppPreferencesStore.memoryUsageConversationIDs == ["conversation-2"])
        #expect(!AppPreferencesStore.memoryHasSeen)
    }

    @Test("Unset Theme Defaults To Dark Without Persisted Key")
    func unsetThemeDefaultsToDarkWithoutPersistedKey() {
        let savedUID = AppSessionStore.activeUID
        defer {
            AppSessionStore.activeUID = savedUID
            clearLegacyPreferenceKeys()
            resetPreferenceCaches()
        }

        clearLegacyPreferenceKeys()
        resetPreferenceCaches()

        let loaded = AppPreferencesStore.load()
        #expect(loaded.theme == .dark)
        #expect(!loaded.themeSetByUser)
        #expect(AppPreferencesStore.savedTheme == nil)
        #expect(UserDefaults.standard.object(forKey: AppPreferencesTestKeys.theme) == nil)

        AppPreferencesStore.save(loaded)
        #expect(UserDefaults.standard.object(forKey: AppPreferencesTestKeys.theme) == nil)

        var explicit = loaded
        explicit.theme = .light
        explicit.themeSetByUser = true
        AppPreferencesStore.save(explicit)
        #expect(AppPreferencesStore.savedTheme == .light)
        let reloaded = AppPreferencesStore.load()
        #expect(reloaded.theme == .light)
        #expect(reloaded.themeSetByUser)
    }

    @Test("Legacy Fallback Only Applies To Signed In Users")
    func legacyFallbackOnlyAppliesToSignedInUsers() {
        let savedUID = AppSessionStore.activeUID
        let signedInUID = "prefs-signed-in"
        defer {
            AppSessionStore.activeUID = savedUID
            clearScopedPreferenceKeys(for: signedInUID)
            clearLegacyPreferenceKeys()
            resetPreferenceCaches()
        }

        clearScopedPreferenceKeys(for: signedInUID)
        clearLegacyPreferenceKeys()
        resetPreferenceCaches()

        let defaults = UserDefaults.standard
        defaults.set("legacy-memory", forKey: AppPreferencesTestKeys.memoryText)
        defaults.set(true, forKey: AppPreferencesTestKeys.memoryAntiForgetEnabled)
        defaults.set("legacy-anti-forget", forKey: AppPreferencesTestKeys.memoryAntiForgetText)
        defaults.set(9, forKey: AppPreferencesTestKeys.memoryUsageCount)
        defaults.set(["legacy-conversation"], forKey: AppPreferencesTestKeys.memoryUsageConversationIDs)
        defaults.set(true, forKey: AppPreferencesTestKeys.memoryHasSeen)

        AppSessionStore.activeUID = signedInUID
        #expect(AppPreferencesStore.savedMemoryText == "legacy-memory")
        #expect(AppPreferencesStore.savedMemoryAntiForgetEnabled)
        #expect(AppPreferencesStore.savedMemoryAntiForgetText == "legacy-anti-forget")
        #expect(AppPreferencesStore.memoryUsageCount == 9)
        #expect(AppPreferencesStore.memoryUsageConversationIDs == ["legacy-conversation"])
        #expect(AppPreferencesStore.memoryHasSeen)

        AppSessionStore.activeUID = "guest"
        #expect(AppPreferencesStore.savedMemoryText.isEmpty)
        #expect(!AppPreferencesStore.savedMemoryAntiForgetEnabled)
        #expect(AppPreferencesStore.savedMemoryAntiForgetText.isEmpty)
        #expect(AppPreferencesStore.memoryUsageCount == 0)
        #expect(AppPreferencesStore.memoryUsageConversationIDs.isEmpty)
        #expect(!AppPreferencesStore.memoryHasSeen)
    }

    @Test("Clear Account Data Removes Scoped And Legacy Memory Data")
    func clearAccountDataRemovesScopedAndLegacyMemoryData() {
        let uid = "prefs-clear-account-data"
        clearScopedPreferenceKeys(for: uid)
        clearLegacyPreferenceKeys()

        let defaults = UserDefaults.standard
        defaults.set("scoped-memory", forKey: "\(AppPreferencesTestKeys.memoryText).\(uid)")
        defaults.set(7, forKey: "\(AppPreferencesTestKeys.memoryUsageCount).\(uid)")
        defaults.set("legacy-memory", forKey: AppPreferencesTestKeys.memoryText)
        defaults.set(3, forKey: AppPreferencesTestKeys.memoryUsageCount)

        AppPreferencesStore.clearAccountData(for: uid)

        #expect(defaults.object(forKey: "\(AppPreferencesTestKeys.memoryText).\(uid)") == nil)
        #expect(defaults.object(forKey: "\(AppPreferencesTestKeys.memoryUsageCount).\(uid)") == nil)
        #expect(defaults.object(forKey: AppPreferencesTestKeys.memoryText) == nil)
        #expect(defaults.object(forKey: AppPreferencesTestKeys.memoryUsageCount) == nil)

        clearScopedPreferenceKeys(for: uid)
        clearLegacyPreferenceKeys()
        resetPreferenceCaches()
    }

    @Test("Copy Account Data Preserves Target Only Values")
    func copyAccountDataPreservesTargetOnlyValues() {
        let savedUID = AppSessionStore.activeUID
        let sourceUID = "prefs-copy-source"
        let targetUID = "prefs-copy-target"
        defer {
            AppSessionStore.activeUID = savedUID
            clearScopedPreferenceKeys(for: sourceUID)
            clearScopedPreferenceKeys(for: targetUID)
            clearLegacyPreferenceKeys()
            resetPreferenceCaches()
        }

        clearScopedPreferenceKeys(for: sourceUID)
        clearScopedPreferenceKeys(for: targetUID)
        clearLegacyPreferenceKeys()
        resetPreferenceCaches()

        AppSessionStore.activeUID = sourceUID
        AppPreferencesStore.save(
            AppPreference(
                theme: .system,
                language: .system,
                memoryText: "guest-memory",
                memoryAntiForgetEnabled: false,
                memoryAntiForgetText: "",
                memoryUpdatedAt: Date(timeIntervalSince1970: 1_710_000_000)
            )
        )

        AppSessionStore.activeUID = targetUID
        AppPreferencesStore.memoryUsageCount = 7
        AppPreferencesStore.memoryUsageConversationIDs = ["existing-conversation"]
        AppPreferencesStore.memoryHasSeen = true

        AppPreferencesStore.copyAccountData(from: sourceUID, to: targetUID)

        #expect(AppPreferencesStore.savedMemoryText == "guest-memory")
        #expect(AppPreferencesStore.memoryUsageCount == 7)
        #expect(AppPreferencesStore.memoryUsageConversationIDs == ["existing-conversation"])
        #expect(AppPreferencesStore.memoryHasSeen)
    }
}
