import Foundation

enum RelayErrorSnippet {
    static func extract(from data: Data, maxBytes: Int = 2048, redacting credentials: [String] = []) -> String? {
        guard !data.isEmpty else { return nil }
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return nil }
        guard let snippet = whitelistedSnippet(from: json), !snippet.isEmpty else { return nil }
        return truncate(RelayRequestSecurity.redactingCredentials(snippet, credentials: credentials), maxBytes: maxBytes)
    }

    private static func whitelistedSnippet(from object: Any) -> String? {
        guard let dict = object as? [String: Any] else { return nil }
        if let error = dict["error"] {
            if let string = error as? String, !string.isEmpty { return string }
            if let nested = error as? [String: Any], let snippet = whitelistedFromFields(nested) { return snippet }
        }
        return whitelistedFromFields(dict)
    }

    private static func whitelistedFromFields(_ dict: [String: Any]) -> String? {
        for key in ["message", "msg", "type", "code"] {
            if let string = dict[key] as? String, !string.isEmpty { return string }
            if key == "code", let integer = dict[key] as? Int { return String(integer) }
        }
        return nil
    }

    static func truncate(_ string: String, maxBytes: Int) -> String {
        let utf8 = Array(string.utf8)
        guard utf8.count > maxBytes else { return string }
        var cut = maxBytes
        while cut > 0, (utf8[cut] & 0xC0) == 0x80 { cut -= 1 }
        return String(decoding: utf8.prefix(cut), as: UTF8.self) + "…"
    }
}
