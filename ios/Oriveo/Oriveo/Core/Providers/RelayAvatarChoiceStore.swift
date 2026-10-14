import Foundation
import Observation

/// On-device relay avatar choices (fixture `shared/test-fixtures/relay/relay-avatar-icon.v1.json`).
///
/// Stored in the local key-value store `relay_avatar_choices.v1` as `{connection id: icon id | "letter"}`. It stays on this device: never synced, never backed up, no database column;
/// deleting a connection deletes its entry. Observable: places drawn through `ConnectionAvatarIcon` read it and refresh as soon as a choice is made;
/// message headers go through `ModelDisplayLookup`, and the chat page rebuilds the lookup by `revision`.
@MainActor
@Observable
final class RelayAvatarChoiceStore {
    static let storageKey = "relay_avatar_choices.v1"
    static let shared = RelayAvatarChoiceStore()

    /// Connection id (`UUID.uuidString`) -> choice value.
    private(set) var choices: [String: String]
    /// Incremented on every write, so paths not observed by SwiftUI (the chat page lookup) can tell whether to rebuild.
    private(set) var revision: UInt = 0

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.choices = defaults.dictionary(forKey: Self.storageKey) as? [String: String] ?? [:]
    }

    func choice(for providerID: UUID) -> String? {
        choices[providerID.uuidString]
    }

    /// A cell was picked in the sheet: the brand cell deletes the stored choice, an icon cell stores the icon id, the letter cell stores "letter".
    func select(_ cell: RelayAvatarPickerCell, for providerID: UUID) {
        setChoice(cell.storedChoice, for: providerID)
    }

    func setChoice(_ choice: String?, for providerID: UUID) {
        let key = providerID.uuidString
        guard choices[key] != choice else { return }
        choices[key] = choice
        persist()
    }

    /// Called when a connection is deleted.
    func deleteConnection(_ providerID: UUID) {
        guard choices[providerID.uuidString] != nil else { return }
        choices[providerID.uuidString] = nil
        persist()
    }

    private func persist() {
        if choices.isEmpty {
            defaults.removeObject(forKey: Self.storageKey)
        } else {
            defaults.set(choices, forKey: Self.storageKey)
        }
        revision &+= 1
    }
}
