import Foundation
import Testing
@testable import Oriveo

/// The web search page family screenshots read the shared manifest `shared/test-fixtures/shots/webSearch.v1.json`: the page-name set matches this platform's page-name table,
/// and every page's services can be staged through production pure functions.
@Suite("Screenshot manifest · web search page family")
@MainActor
struct WebSearchShotsManifestTests {
    private static func manifest() throws -> SearchJSON {
        try SearchJSON.parse(Data(contentsOf: WebSearchShots.manifestURL()))
    }

    @Test("shotsManifestPagesMatchImplemented: manifest page-name set == this platform's page-name table")
    func shotsManifestPagesMatchImplemented() throws {
        let pages = try #require(try Self.manifest()["pages"]?.arrayValue)
        let names = pages.compactMap { $0["name"]?.stringValue }
        #expect(Set(names) == Set(WebSearchShots.Shot.allCases.map(\.rawValue)))
        #expect(names.count == WebSearchShots.Shot.allCases.count)
        let opens: Set<String> = ["settingsHome", "main", "addSheet", "connect", "detail", "customForm", "customConsent", "chat", "modelOptions", "sourcePicker"]
        for page in pages {
            #expect(opens.contains(page["preset"]?["open"]?.stringValue ?? ""), "\(page["name"]?.stringValue ?? "?")")
        }
    }

    @Test("services staged per manifest: default DeepSeek goes through the connection, Tavily carries the last 4 key characters, custom has no key")
    func staysInMemory() throws {
        let manifest = try Self.manifest()
        let page = try #require(manifest["pages"]?.arrayValue?.first { $0["name"]?.stringValue == "webSearchMain" })
        let staged = WebSearchShots.stage(manifest: manifest, page: page, entries: [])
        #expect(staged.items.map(\.id) == ["s-deepseek", "s-tavily", "s-custom"])
        #expect(staged.defaultID == "s-deepseek")
        #expect(staged.items[0].service.kind == .reuseConnection)
        #expect(staged.items[1].keyTail == "9xQ2")
        #expect(staged.items[2].row.keySource == .none)
        let empty = try #require(manifest["pages"]?.arrayValue?.first { $0["name"]?.stringValue == "webSearchEmpty" })
        #expect(WebSearchShots.stage(manifest: manifest, page: empty, entries: []).items.isEmpty)
    }
}
