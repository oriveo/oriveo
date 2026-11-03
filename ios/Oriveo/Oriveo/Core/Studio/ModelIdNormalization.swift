import Foundation

/// Client-side mechanical model id normalization (`shared/model-contracts/model_id_normalization.v1.json`):
/// trim, lowercase, drop everything up to the last `/`, drop one trailing `-YYYY-MM-DD` or
/// `-YYYYMMDD`. Nothing else: `-preview` / `-latest` / `-all` and community names are resolved
/// by the Server alias table, never by clients. The result is only a lookup key; the wire always
/// sends the id exactly as the connection lists it.
enum ModelIdNormalization {
    /// ISO date first so `-2026-04-21` is never half-matched; only one suffix is dropped.
    private static let trailingDatePatterns = ["-[0-9]{4}-[0-9]{2}-[0-9]{2}$", "-[0-9]{8}$"]

    static func normalize(_ modelId: String) -> String {
        var id = modelId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let slash = id.lastIndex(of: "/") {
            id = String(id[id.index(after: slash)...])
        }
        for pattern in trailingDatePatterns {
            if let range = id.range(of: pattern, options: .regularExpression) {
                id.removeSubrange(range)
                break
            }
        }
        return id
    }
}
