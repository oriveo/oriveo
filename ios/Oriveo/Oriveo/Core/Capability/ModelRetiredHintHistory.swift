import Foundation

/// Fallback hint history for when the preferred model of a new chat has been retired: shown once per
/// connection x retired model on this device. Call `consumeFirstHint` when the fallback really takes effect
/// and a toast is about to show; see `FirstHintHistory` for storage and eviction.
final class ModelRetiredHintHistory: FirstHintHistory, @unchecked Sendable {
    static let shared = ModelRetiredHintHistory()

    static let storageKey = "model_retired_hint_seen.v1"
    /// Toast copy key for "your last model was retired, now using X" (Chat table).
    static let lastUsedRetiredHintKey = "Your last model was retired. Now using %@."

    init(defaults: UserDefaults = .standard) {
        super.init(storageKey: Self.storageKey, defaults: defaults)
    }

    static func lastUsedRetiredMessage(fallbackModelName: String) -> String {
        String(format: L10n.tr(lastUsedRetiredHintKey, table: .chat), fallbackModelName)
    }
}
