import Foundation

enum ProviderKeyInput {
    private static let printableASCIIRange: ClosedRange<UInt8> = 0x20...0x7e

    static func isPrintableASCII(_ key: String) -> Bool {
        if key.isEmpty { return false }
        for byte in key.utf8 where !printableASCIIRange.contains(byte) {
            return false
        }
        return true
    }

    static var illegalCharsMessage: String {
        L10n.tr(
            "API Key contains unsupported characters. Please re-paste — it likely picked up a full-width space, zero-width space, or non-ASCII character.",
            table: .providers
        )
    }

    static func illegalCharsError(actionTitle: String = L10n.tr("OK")) -> OriveoError {
        OriveoError(
            id: UUID(),
            title: L10n.tr("Check your API Key", table: .providers),
            message: illegalCharsMessage,
            actionTitle: actionTitle,
            detail: "",
            severity: .warning
        )
    }
}
