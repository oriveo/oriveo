import Foundation
import Testing
@testable import Oriveo

/// New-feature red dots. Source of truth: `shared/ui-contracts/feature-badges.v1.json`.
@MainActor
@Suite("feature badges", .serialized)
struct FeatureBadgesTests {

    @Test("Shown by default when unseen; after markSeen it is not shown, and a fresh instance re-reading still does not show it")
    func markSeenPersists() {
        let defaults = Self.isolatedDefaults()
        let badges = FeatureBadges(defaults: defaults)
        #expect(badges.isUnseen(FeatureBadges.settingsMemory))

        badges.markSeen(FeatureBadges.settingsMemory)
        #expect(!badges.isUnseen(FeatureBadges.settingsMemory))
        #expect(defaults.stringArray(forKey: FeatureBadges.storageKey) == [FeatureBadges.settingsMemory])

        let reloaded = FeatureBadges(defaults: defaults)
        #expect(!reloaded.isUnseen(FeatureBadges.settingsMemory))
    }

    @Test("The Web search tile's red dot: after entering the page and markSeen it is no longer shown, and the Memory row is unaffected")
    func webSearchBadgeIsIndependent() {
        let defaults = Self.isolatedDefaults()
        let badges = FeatureBadges(defaults: defaults)
        #expect(FeatureBadges.settingsWebSearch == "settings.webSearch.2026-10")
        #expect(badges.isUnseen(FeatureBadges.settingsWebSearch))

        badges.markSeen(FeatureBadges.settingsWebSearch)
        #expect(!badges.isUnseen(FeatureBadges.settingsWebSearch))
        #expect(badges.isUnseen(FeatureBadges.settingsMemory))
        #expect(!FeatureBadges(defaults: defaults).isUnseen(FeatureBadges.settingsWebSearch))
    }

    @Test("Ids outside the registry are dropped from the seen set and not shown")
    func unregisteredIDsArePruned() {
        let defaults = Self.isolatedDefaults()
        defaults.set(["settings.memory.2025-01", FeatureBadges.settingsMemory], forKey: FeatureBadges.storageKey)

        let badges = FeatureBadges(defaults: defaults)
        #expect(badges.seen == [FeatureBadges.settingsMemory])
        #expect(defaults.stringArray(forKey: FeatureBadges.storageKey) == [FeatureBadges.settingsMemory])
        #expect(!badges.isUnseen("settings.memory.2025-01"))

        badges.markSeen("not.registered.2026-10")
        #expect(defaults.stringArray(forKey: FeatureBadges.storageKey) == [FeatureBadges.settingsMemory])
    }

    @Test("The constant id list matches the shared registry badges[].id one by one")
    func idsMatchSharedRegistry() throws {
        struct Registry: Decodable {
            struct Badge: Decodable { let id: String }
            let badges: [Badge]
        }
        let url = try #require(Self.registryURL(), "cannot find shared/ui-contracts/feature-badges.v1.json")
        let registry = try JSONDecoder().decode(Registry.self, from: Data(contentsOf: url))
        #expect(FeatureBadges.registeredIDs == registry.badges.map(\.id))
    }

    private static func registryURL() -> URL? {
        var folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while folder.path != "/" {
            let candidate = folder
                .appendingPathComponent("shared")
                .appendingPathComponent("ui-contracts")
                .appendingPathComponent("feature-badges.v1.json")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            folder.deleteLastPathComponent()
        }
        return nil
    }

    private static func isolatedDefaults() -> UserDefaults {
        let name = "FeatureBadgesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }
}
