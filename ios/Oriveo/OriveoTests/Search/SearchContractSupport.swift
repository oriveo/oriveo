import Foundation
import Testing
@testable import Oriveo

/// Shared reading and comparison for the external search contract tests. Each test file spells out the repo-relative fixture path itself (shared/search-contracts/...),
/// and this only reads the originals, encodes production output to JSON, and compares by JSON semantics.
nonisolated enum SearchContractSupport {
    static var repoRoot: URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        return url
    }

    static func load(_ repoRelativePath: String) throws -> SearchJSON {
        try SearchJSON.parse(Data(contentsOf: repoRoot.appendingPathComponent(repoRelativePath)))
    }

    /// Production output (Encodable) → JSON value; nil fields are omitted and treated as null when comparing.
    static func json<T: Encodable>(_ value: T) throws -> SearchJSON {
        try SearchJSON.parse(JSONEncoder().encode(value))
    }

    /// Compares only top-level keys present in expect; a key missing from production output counts as null. Nested values are compared as a whole by JSON semantics.
    static func mismatchedKeys(actual: SearchJSON, expect: SearchJSON) -> [String] {
        guard let expected = expect.objectValue else { return actual == expect ? [] : ["<root>"] }
        return expected.entries.compactMap { entry in
            (actual[entry.key] ?? .null) == entry.value ? nil : entry.key
        }
    }

    static func service(_ id: String, in catalog: SearchJSON) -> SearchJSON? {
        catalog["services"]?.arrayValue?.first { $0["id"]?.stringValue == id }
    }

    /// Modifies one site in an entry (the fixture's catalogHostOverride / regionUrlsOverride).
    static func modifyingRegion(_ entry: SearchJSON, id regionId: String, _ change: (inout SearchJSONObject) -> Void) -> SearchJSON {
        guard var object = entry.objectValue, let regions = object["regions"]?.arrayValue else { return entry }
        object["regions"] = .array(regions.map { region in
            guard region["id"]?.stringValue == regionId, var regionObject = region.objectValue else { return region }
            change(&regionObject)
            return .object(regionObject)
        })
        return .object(object)
    }

    /// buildSearchRequest result comparison: when expect carries skip, nothing must be sent; otherwise compare the request item by item.
    static func buildMismatches(_ build: SearchRequestBuild, expect: SearchJSON) -> [String] {
        switch build {
        case .skip(let reason):
            return expect["skip"]?.stringValue == reason ? [] : ["skip \(reason)"]
        case .send(let request):
            if let skip = expect["skip"] { return ["expected skip \(skip.jsString)"] }
            return requestMismatches(request, expect: expect)
        }
    }

    /// Request comparison: method, scheme://host[:port]/path, decoded query (unordered), headers, and body by JSON semantics.
    static func requestMismatches(_ actual: SearchHTTPRequest, expect: SearchJSON) -> [String] {
        var problems: [String] = []
        if actual.method != expect["method"]?.stringValue { problems.append("method \(actual.method)") }
        let actualURL = URLComponents(string: actual.url)
        let expectURL = URLComponents(string: expect["url"]?.stringValue ?? "")
        if actualURL == nil || expectURL == nil { problems.append("url unparsable \(actual.url)") }
        if let actualURL, let expectURL {
            if actualURL.scheme != expectURL.scheme || actualURL.host != expectURL.host
                || actualURL.port != expectURL.port || actualURL.path != expectURL.path {
                problems.append("url \(actual.url)")
            }
            let pairs = { (components: URLComponents) in
                (components.queryItems ?? []).map { "\($0.name)=\($0.value ?? "")" }.sorted()
            }
            if pairs(actualURL) != pairs(expectURL) { problems.append("query \(pairs(actualURL))") }
        }
        let expectHeaders = (expect["headers"]?.objectValue?.entries ?? []).reduce(into: [String: String]()) {
            $0[$1.key] = $1.value.stringValue
        }
        if actual.headers != expectHeaders { problems.append("headers \(actual.headers)") }
        if (actual.body ?? .null) != (expect["body"] ?? .null) {
            problems.append("body \(actual.body?.encodedString() ?? "null")")
        }
        return problems
    }
}
