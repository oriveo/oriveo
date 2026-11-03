import Foundation

/// Model identifier line-break points: a break is allowed only after "-", "_", or "/", never inside a word.
/// The result is for display only; accessibility labels and copy always use the raw id (same as the Android function of the same name).
enum ModelIdentifierBreaks {
    private static let separators: Set<Character> = ["-", "_", "/"]
    private static let zeroWidthSpace: Character = "\u{200B}"

    /// Inserts one U+200B after each separator and keeps all other characters as they are.
    static func displayTitle(_ id: String) -> String {
        var result = ""
        result.reserveCapacity(id.count + 8)
        for character in id {
            result.append(character)
            if separators.contains(character) {
                result.append(zeroWidthSpace)
            }
        }
        return result
    }
}
