import Foundation
import Testing
@testable import Oriveo

@Suite("SkillManager Lifecycle")
@MainActor
struct SkillManagerLifecycleTests {
    @Test("Reload Cache Clears Stale Skills When Target Account Has No Cache")
    func reloadCacheClearsStaleSkillsWhenTargetAccountHasNoCache() throws {
        let defaults = UserDefaults.standard
        let previousUID = AppSessionStore.activeUID
        let cachedUID = "skill-cache-\(UUID().uuidString)"
        let emptyUID = "skill-empty-\(UUID().uuidString)"

        defer {
            AppSessionStore.activeUID = previousUID
            removeSkillCache(for: cachedUID, defaults: defaults)
            removeSkillCache(for: emptyUID, defaults: defaults)
        }

        let manager = SkillManager()
        try writeSkillCache(
            for: cachedUID,
            catalogSkills: [Skill(name: "Catalog Skill", source: .builtin)],
            userSkills: [Skill(name: "User Skill", source: .user)],
            version: 7,
            defaults: defaults
        )

        AppSessionStore.activeUID = cachedUID
        manager.reloadCacheForCurrentAccount()
        #expect(manager.totalSkillCount == 2)

        AppSessionStore.activeUID = emptyUID
        manager.reloadCacheForCurrentAccount()

        #expect(manager.catalogSkills.isEmpty)
        #expect(manager.userSkills.isEmpty)
        #expect(manager.totalSkillCount == 0)
    }

    private func writeSkillCache(
        for uid: String,
        catalogSkills: [Skill],
        userSkills: [Skill],
        version: Int,
        defaults: UserDefaults
    ) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        defaults.set(try encoder.encode(catalogSkills), forKey: "skills_\(uid)_catalog")
        defaults.set(try encoder.encode(userSkills), forKey: "skills_\(uid)_user")
        defaults.set(version, forKey: "skills_\(uid)_catalog_version")
    }

    private func removeSkillCache(for uid: String, defaults: UserDefaults) {
        defaults.removeObject(forKey: "skills_\(uid)_catalog")
        defaults.removeObject(forKey: "skills_\(uid)_categories")
        defaults.removeObject(forKey: "skills_\(uid)_user")
        defaults.removeObject(forKey: "skills_\(uid)_catalog_version")
    }
}
