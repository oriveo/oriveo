import Foundation
import Observation

/// The "new feature" red dot on an entry row. The registry is the shared `feature-badges.v1.json`;
/// `registeredIDs` matches its `badges[].id` entry by entry (checked by a unit test).
///
/// Stored only in the local `UserDefaults` key `featureBadges.seen` (a string array): not included in backups.
@MainActor
@Observable
final class FeatureBadges {
    /// The "Memory" row in Settings, leading to the memory settings page.
    static let settingsMemory = "settings.memory.2026-10"

    /// Currently registered ids; to prompt again for an updated feature, add a new id and remove the old one.
    static let registeredIDs: [String] = [settingsMemory]

    static let storageKey = "featureBadges.seen"

    static let shared = FeatureBadges()

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let registered: Set<String>
    private(set) var seen: Set<String>

    init(defaults: UserDefaults = .standard, registered: [String] = FeatureBadges.registeredIDs) {
        self.defaults = defaults
        self.registered = Set(registered)
        let stored = Set(defaults.stringArray(forKey: Self.storageKey) ?? [])
        // Ids outside the registry are dropped on read, so the set does not only grow.
        let pruned = stored.intersection(self.registered)
        self.seen = pruned
        if pruned != stored { persist(pruned) }
    }

    func isUnseen(_ id: String) -> Bool {
        registered.contains(id) && !seen.contains(id)
    }

    func markSeen(_ id: String) {
        guard registered.contains(id), !seen.contains(id) else { return }
        let next = seen.union([id]).intersection(registered)
        seen = next
        persist(next)
    }

    private func persist(_ ids: Set<String>) {
        defaults.set(ids.sorted(), forKey: Self.storageKey)
    }
}
