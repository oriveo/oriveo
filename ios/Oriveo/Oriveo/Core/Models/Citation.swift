import Foundation

nonisolated enum ExternalURLPolicy {
    static func httpsURL(from raw: String) -> URL? {
        guard var components = URLComponents(
            string: raw.trimmingCharacters(in: .whitespacesAndNewlines)
        ),
        components.scheme?.lowercased() == "https",
        components.host?.isEmpty == false,
        components.user == nil,
        components.password == nil else { return nil }
        components.scheme = "https"
        return components.url
    }

    static func allows(_ url: URL) -> Bool {
        httpsURL(from: url.absoluteString) != nil
    }
}

struct Citation: Codable, Hashable, Sendable {
    var url: String
    var title: String?
    var snippet: String?
    var faviconUrl: String?
    var index: Int?
    var startIndex: Int?
    var endIndex: Int?

    init(
        url: String,
        title: String? = nil,
        snippet: String? = nil,
        faviconUrl: String? = nil,
        index: Int? = nil,
        startIndex: Int? = nil,
        endIndex: Int? = nil,
    ) {
        self.url = url
        self.title = title
        self.snippet = snippet
        self.faviconUrl = faviconUrl
        self.index = index
        self.startIndex = startIndex
        self.endIndex = endIndex
    }
}


extension Citation {
    static func normalizeUrl(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed) else {
            return trimmed
        }
        var copy = components
        copy.fragment = nil
        if let scheme = copy.scheme {
            copy.scheme = scheme.lowercased()
        }
        if let host = copy.host {
            copy.host = host.lowercased()
        }
        var rendered = copy.string ?? trimmed
        if rendered.hasSuffix("/"), let scheme = copy.scheme,
           rendered != "\(scheme)://\(copy.host ?? "")/" {
            rendered.removeLast()
        }
        return rendered
    }

    var hasUsableUrl: Bool {
        !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var fallbackDedupeKey: String {
        let t = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let s = (snippet ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty && s.isEmpty { return "" }
        return "title:\(t)|snippet:\(s)"
    }

    var dedupeKey: String {
        if hasUsableUrl {
            return Citation.normalizeUrl(url)
        }
        return fallbackDedupeKey
    }
}

struct CitationAccumulator: Sendable {
    private(set) var citations: [Citation] = []
    private var indexByKey: [String: Int] = [:]

    mutating func ingest(_ incoming: Citation) {
        let key = incoming.dedupeKey
        guard !key.isEmpty else { return }
        if let existingIndex = indexByKey[key] {
            var merged = citations[existingIndex]
            merged.title = chooseLongerNonEmpty(merged.title, incoming.title)
            merged.snippet = chooseLongerNonEmpty(merged.snippet, incoming.snippet)
            merged.faviconUrl = chooseLongerNonEmpty(merged.faviconUrl, incoming.faviconUrl)
            if merged.index == nil { merged.index = incoming.index }
            if merged.startIndex == nil { merged.startIndex = incoming.startIndex }
            if merged.endIndex == nil { merged.endIndex = incoming.endIndex }
            if incoming.hasUsableUrl, !merged.hasUsableUrl {
                merged.url = incoming.url
            }
            citations[existingIndex] = merged
        } else {
            citations.append(incoming)
            indexByKey[key] = citations.count - 1
        }
    }

    mutating func ingest(_ many: [Citation]) {
        for c in many { ingest(c) }
    }

    var snapshot: [Citation]? {
        citations.isEmpty ? nil : citations
    }

    private func chooseLongerNonEmpty(_ lhs: String?, _ rhs: String?) -> String? {
        let l = lhs?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let r = rhs?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if l.isEmpty { return r.isEmpty ? lhs : rhs }
        if r.isEmpty { return lhs }
        return r.count > l.count ? rhs : lhs
    }
}
