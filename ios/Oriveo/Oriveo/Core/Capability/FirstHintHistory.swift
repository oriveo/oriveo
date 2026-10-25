import Foundation

/// First-time hint history ("show once per connection x model on this device"), kept separately per storageKey.
///
/// Pure UI history: not backed up and never part of a send decision; losing it only means the hint shows again.
/// Storage and eviction mirror `GenerationParameterProfileHistory`: a UserDefaults string array, oldest dropped past the cap.
class FirstHintHistory: @unchecked Sendable {
    /// Sized for the connection x model combinations a user actually touches; the oldest are dropped beyond it.
    static let maximumEntryCount = 300

    let storageKey: String
    private let defaults: UserDefaults
    private let lock = NSLock()

    init(storageKey: String, defaults: UserDefaults = .standard) {
        self.storageKey = storageKey
        self.defaults = defaults
    }

    func hasShownHint(providerID: UUID, modelID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return entries().contains(Self.entryKey(providerID: providerID, modelID: modelID))
    }

    /// Call when the hint is really about to show: the first call returns true and records it; afterwards the
    /// same connection x model always returns false.
    func consumeFirstHint(providerID: UUID, modelID: String) -> Bool {
        guard !modelID.isEmpty else { return false }
        let key = Self.entryKey(providerID: providerID, modelID: modelID)
        lock.lock()
        defer { lock.unlock() }
        var current = entries()
        guard !current.contains(key) else { return false }
        current.append(key)
        if current.count > FirstHintHistory.maximumEntryCount {
            current.removeFirst(current.count - FirstHintHistory.maximumEntryCount)
        }
        defaults.set(current, forKey: storageKey)
        return true
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        defaults.removeObject(forKey: storageKey)
    }

    private func entries() -> [String] {
        defaults.stringArray(forKey: storageKey) ?? []
    }

    private static func entryKey(providerID: UUID, modelID: String) -> String {
        "\(providerID.uuidString)|\(modelID)"
    }
}
