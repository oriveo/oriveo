import Foundation

/// First-attachment hint history for unknown input capabilities: shown once per connection x model on this
/// device, regardless of medium. Call `consumeFirstHint` when an attachment is actually added to the draft;
/// see `FirstHintHistory` for storage and eviction.
final class InputCapabilityHintHistory: FirstHintHistory, @unchecked Sendable {
    static let shared = InputCapabilityHintHistory()

    static let storageKey = "input_capability_hint_seen.v1"

    init(defaults: UserDefaults = .standard) {
        super.init(storageKey: Self.storageKey, defaults: defaults)
    }
}
