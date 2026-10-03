import Foundation

// MARK: - Parameter display for the confirmation dialog and the step detail view
//
// Pure functions. Keys are the parameter names exactly as the server defines them and values are the
// raw content the model supplied; this file only decides which ones to show and how to shorten them.

nonisolated struct McpConfirmationParameter: Sendable, Equatable, Identifiable {
    enum Display: Sendable, Equatable {
        /// Short value: shown as is (the UI clamps it to two lines).
        case inline(String)
        /// Long text: only the character count is shown, next to a "view full text" action.
        case long(characterCount: Int)
    }

    var id: String { key }
    var key: String
    /// The complete value (for the full-text page). Strings are verbatim, other types are JSON text.
    var fullText: String
    var display: Display
}

nonisolated enum McpConfirmationContent {
    /// Maximum number of top-level parameters the dialog shows.
    static let maxParameters = 4
    /// Values longer than this (or containing a line break) are treated as long text.
    static let inlineCharacterLimit = 80

    /// The first 4 top-level parameters, in the order the model supplied them.
    static func parameters(for arguments: JSONValue) -> [McpConfirmationParameter] {
        guard let object = arguments.objectValue else { return [] }
        return object.keys.prefix(maxParameters).compactMap { key in
            guard let value = object[key] else { return nil }
            let text = text(for: value)
            let isLong = text.count > inlineCharacterLimit || text.contains("\n")
            return McpConfirmationParameter(
                key: key,
                fullText: text,
                display: isLong ? .long(characterCount: text.count) : .inline(text)
            )
        }
    }

    /// Title of the owning conversation shown in the root-level dialog; a blank title hides the row.
    static func displayConversationTitle(_ title: String?) -> String? {
        guard let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// Whether there are more top-level parameters than the dialog shows (the rest are only on the full-text page).
    static func hasMoreParameters(_ arguments: JSONValue) -> Bool {
        (arguments.objectValue?.keys.count ?? 0) > maxParameters
    }

    /// All parameters, one `key: value` per line (full-text page and the "parameters sent" section of the step detail).
    static func allParametersText(_ arguments: JSONValue) -> String {
        guard let object = arguments.objectValue else { return arguments.canonicalJSONString }
        return object.keys.compactMap { key in
            object[key].map { "\(key): \(lineValue(for: $0))" }
        }.joined(separator: "\n")
    }

    /// Parameter text for a locally stored payload in the step detail (stored as canonical JSON).
    /// Shown verbatim when it cannot be parsed.
    static func allParametersText(storedJSON: String) -> String {
        guard let value = try? JSONValue(parsing: storedJSON) else { return storedJSON }
        return allParametersText(value)
    }

    private static func text(for value: JSONValue) -> String {
        if let string = value.stringValue { return string }
        return value.canonicalJSONString
    }

    /// Inline value: strings keep their quotes, everything else is JSON text.
    private static func lineValue(for value: JSONValue) -> String {
        value.canonicalJSONString
    }
}
