import Foundation

/// Strips API keys out of text that may be shown or logged.
///
/// Upstream error bodies sometimes echo the key back - a DeepSeek 401 message includes it - so
/// the user's own key is masked first, and then anything that looks like a credential after an
/// `sk-` or `Bearer ` marker, which covers keys belonging to a relay or to another service that
/// this client never held.
public enum CredentialRedactor {
    public static func redact(_ text: String, apiKey: String) -> String {
        var result = apiKey.isEmpty ? text : text.replacingOccurrences(of: apiKey, with: "***")
        result = redactAfter(marker: "sk-", in: result)
        result = redactAfter(marker: "Bearer ", in: result)
        return result
    }

    private static func redactAfter(marker: String, in text: String) -> String {
        var out = ""
        var rest = Substring(text)
        while let range = rest.range(of: marker) {
            out += rest[rest.startIndex ..< range.upperBound]
            var cursor = range.upperBound
            while cursor < rest.endIndex, isCredentialCharacter(rest[cursor]) {
                cursor = rest.index(after: cursor)
            }
            if cursor > range.upperBound { out += "***" }
            rest = rest[cursor...]
        }
        return out + rest
    }

    /// `*` counts as part of a credential so that an already-masked key such as `sk-****abcd`
    /// is consumed whole, rather than leaving its trailing characters behind.
    private static func isCredentialCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_" || character == "-" || character == "*"
    }
}
