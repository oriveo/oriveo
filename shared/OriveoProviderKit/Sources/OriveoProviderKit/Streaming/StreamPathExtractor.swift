import Foundation

/// Reads a value out of a decoded stream chunk by dotted path.
///
/// A recipe can name where a provider hides its result - for example
/// `choices.0.delta.tool_calls.0.web_search.search_result` - instead of the parser hard-coding
/// one layout per vendor.
///
/// The grammar is intentionally tiny: `.` separates segments, an all-digit segment indexes an
/// array, anything else is a dictionary key. There are no wildcards, filters or expressions, so
/// a path from a recipe can only read one place and can never become a query language.
public enum StreamPathExtractor {

    /// Follows `path` and returns the value at the end, or nil if any segment does not resolve.
    public static func extract(_ json: Any?, path: String) -> Any? {
        guard let json else { return nil }
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return json }

        var current: Any? = json
        for segment in trimmed.split(separator: ".") {
            guard let cur = current else { return nil }

            if let index = Int(segment), let array = cur as? [Any] {
                guard index >= 0, index < array.count else { return nil }
                current = array[index]
            } else if let dict = cur as? [String: Any] {
                current = dict[String(segment)]
            } else {
                return nil
            }
        }
        return current
    }

    /// Returns the value at `path` when it is a string.
    public static func extractString(_ json: Any?, path: String) -> String? {
        extract(json, path: path) as? String
    }

    /// Returns the value at `path` when it is an array.
    public static func extractArray(_ json: Any?, path: String) -> [Any]? {
        extract(json, path: path) as? [Any]
    }

    /// Returns the value at `path` as an integer, accepting the number, string and `NSNumber`
    /// spellings that different JSON payloads use for the same field.
    public static func extractInt(_ json: Any?, path: String) -> Int? {
        let node = extract(json, path: path)
        if let i = node as? Int { return i }
        if let d = node as? Double { return Int(d) }
        if let s = node as? String { return Int(s) }
        if let n = node as? NSNumber { return n.intValue }
        return nil
    }
}

/// Decodes a single SSE line into an untyped JSON value for path-based extraction.
public enum SSEChunkParser {
    /// Accepts a line with or without its `data:` prefix. The `[DONE]` sentinel and anything
    /// that is not JSON return nil.
    public static func parse(_ raw: String) -> Any? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Tolerate both `data: {...}` and a bare JSON payload.
        let jsonPart: String
        if trimmed.hasPrefix("data:") {
            let after = trimmed.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines)
            jsonPart = String(after)
        } else {
            jsonPart = trimmed
        }

        guard !jsonPart.isEmpty, jsonPart != "[DONE]" else { return nil }
        guard let data = jsonPart.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }
}
