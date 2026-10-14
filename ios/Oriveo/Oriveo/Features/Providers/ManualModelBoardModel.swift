import Foundation

// MARK: - Row model of the "Add model manually" page
//
// Relays and official providers share one page and one layout: an input slot + a note under the slot + a bottom action bar.
// The view renders only what is given here; how the two modes differ is decided here.

struct ManualModelBoardModel: Equatable {
    enum Section: Equatable {
        case modelSlot
        case notes
    }

    /// One piece of copy: the key and the table it lives in ("Save" and "Model ID" are in the common table, the others in the Providers table).
    struct Copy: Equatable {
        let key: String
        let table: L10n.Table
    }

    enum Placeholder: Equatable {
        /// Technical value shown as is (the delivered model ID).
        case verbatim(String)
        case localized(Copy)
    }

    let sections: [Section]
    let title: Copy
    let slotTitle: Copy
    let placeholder: Placeholder
    /// The model ID is a technical value: in relay mode it is laid out left to right even in RTL languages (the same approach as the model slot on the manual setup page).
    let forcesLeftToRightValue: Bool
    let notes: [Copy]
    let primaryAction: Copy
    let secondaryAction: Copy?
    let trimmedModelID: String
    let showsClear: Bool
    let isPrimaryEnabled: Bool

    /// - Parameter relayPlaceholder: placeholder for relay mode, the delivered flagship model ID.
    static func make(
        isRelay: Bool,
        input: String,
        relayPlaceholder: String = RelayModelPlaceholder.current
    ) -> ManualModelBoardModel {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        return ManualModelBoardModel(
            sections: [.modelSlot, .notes],
            title: Copy(key: isRelay ? "Add Model" : "Fallback Model", table: .providers),
            slotTitle: Copy(key: "Model ID", table: .localizable),
            placeholder: isRelay
                ? .verbatim(relayPlaceholder)
                : .localized(Copy(key: "For example: claude-4-sonnet or gpt-4o", table: .providers)),
            forcesLeftToRightValue: isRelay,
            notes: isRelay
                ? [
                    Copy(key: "Enter the model ID exactly as your Custom Relay lists it.", table: .providers),
                    // Same convention as "Unknown · remembered after sending" on the model library row: this page does not claim capabilities on the model's behalf.
                    Copy(
                        key: "What it can do is remembered after you send a message, or you can test it under Advanced.",
                        table: .providers
                    ),
                ]
                : [
                    Copy(
                        key: "Just enter one usable model ID. You don't need to understand the protocol details.",
                        table: .providers
                    ),
                ],
            primaryAction: isRelay
                ? Copy(key: "Save", table: .localizable)
                : Copy(key: "Save & Continue", table: .providers),
            // The relay page does not pull a catalog, so retrying sync is meaningless; official providers keep the sync retry entry.
            secondaryAction: isRelay ? nil : Copy(key: "Retry Sync", table: .providers),
            trimmedModelID: trimmed,
            // Follows whether the slot has any text, not the trimmed result: typing only spaces must still allow clearing with one tap.
            showsClear: !input.isEmpty,
            isPrimaryEnabled: !trimmed.isEmpty
        )
    }
}
