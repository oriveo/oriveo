import Foundation
import Testing
@testable import Oriveo

/// Preset client cases shared by all three clients: reads the clientCases block of
/// `shared/studio-contracts/studio_presets.v1.json` (decode / locale / snapshot /
/// refreshPlan / refreshApply). Snapshot cases load the bundled copy through the
/// production loader.
@Suite("StudioPresetsContractTests")
struct StudioPresetsContractTests {
    private struct BadFixture: Error {
        let detail: String
    }

    private static func repoFile(_ components: [String]) throws -> URL {
        var current = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while true {
            let candidate = components.reduce(current) { $0.appendingPathComponent($1) }
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { break }
            current = parent
        }
        throw CocoaError(.fileNoSuchFile)
    }

    private static func fixture() throws -> JSONValue {
        let url = try repoFile(["shared", "studio-contracts", "studio_presets.v1.json"])
        return try JSONValue(data: Data(contentsOf: url))
    }

    private static func clientCases(_ name: String) throws -> [JSONValue] {
        let cases = try #require(try fixture()["clientCases"]?[name]?.arrayValue, "clientCases.\(name)")
        #expect(!cases.isEmpty, "clientCases.\(name) is empty")
        return cases
    }

    private static func same(_ actual: JSONValue, _ expected: JSONValue?) -> (Bool, String) {
        let actualText = actual.canonicalJSONString
        let expectedText = (expected ?? .null).canonicalJSONString
        // Scalar-wise comparison: String == would treat canonically equivalent text as equal.
        return (actualText.unicodeScalars.elementsEqual(expectedText.unicodeScalars), actualText)
    }

    private static func object(_ pairs: [(String, JSONValue)]) -> JSONValue {
        .object(JSONObject(pairs))
    }

    private static func optional(_ text: String?) -> JSONValue {
        text.map(JSONValue.string) ?? .null
    }

    private static func groupJSON(_ group: StudioPresets.Group) -> JSONValue {
        object([("id", .string(group.id)), ("order", .number(Double(group.order))), ("displayName", .string(group.displayName))])
    }

    private static func json(_ result: Result<StudioPresets.Catalog, StudioPresets.DecodeError>) -> JSONValue {
        switch result {
        case .failure(let error):
            return object([("error", .string(error.rawValue))])
        case .success(let catalog):
            let styles = catalog.styles.map { style in
                object([
                    ("id", .string(style.id)),
                    ("group", .string(style.group)),
                    ("order", .number(Double(style.order))),
                    ("featured", .bool(style.featured)),
                    ("displayName", .string(style.displayName)),
                    ("description", .string(style.description)),
                    ("promptFragment", .string(style.promptFragment)),
                    ("placeholderColor", optional(style.placeholderColor)),
                    ("sample", style.sample.map { sample in
                        object([
                            ("url", .string(sample.url)),
                            ("width", .number(Double(sample.width))),
                            ("height", .number(Double(sample.height))),
                            ("sha256", .string(sample.sha256)),
                        ])
                    } ?? .null),
                ])
            }
            let effects = catalog.effects.map { effect in
                object([
                    ("id", .string(effect.id)),
                    ("group", .string(effect.group)),
                    ("order", .number(Double(effect.order))),
                    ("displayName", .string(effect.displayName)),
                    ("promptFragment", .string(effect.promptFragment)),
                    ("swatch", .array(effect.swatch.map(JSONValue.string))),
                ])
            }
            let dropped = catalog.dropped.map { item in
                object([("kind", .string(item.kind.rawValue)), ("id", optional(item.id)), ("reason", .string(item.reason.rawValue))])
            }
            return object([
                ("error", .null),
                ("revision", .string(catalog.revision)),
                ("locale", .string(catalog.locale)),
                ("styleGroups", .array(catalog.styleGroups.map { groupJSON($0) })),
                ("effectGroups", .array(catalog.effectGroups.map { groupJSON($0) })),
                ("styles", .array(styles)),
                ("effects", .array(effects)),
                ("dropped", .array(dropped)),
            ])
        }
    }

    private static func cache(_ raw: JSONValue?, _ caseId: String) throws -> StudioPresets.Cache? {
        guard let raw, raw != .null else { return nil }
        guard let locale = raw["locale"]?.stringValue,
              let revision = raw["revision"]?.stringValue,
              let checkedAtMs = raw["checkedAtMs"]?.intValue
        else { throw BadFixture(detail: "\(caseId): cache") }
        return StudioPresets.Cache(locale: locale, revision: revision, etag: raw["etag"]?.stringValue, checkedAtMs: Int64(checkedAtMs))
    }

    private static func json(_ cache: StudioPresets.Cache?) -> JSONValue {
        guard let cache else { return .null }
        return object([
            ("locale", .string(cache.locale)),
            ("revision", .string(cache.revision)),
            ("etag", optional(cache.etag)),
            ("checkedAtMs", .number(Double(cache.checkedAtMs))),
        ])
    }

    private static func body(_ value: JSONValue) -> Data {
        Data(value.orderedJSONString.utf8)
    }

    /// Every decode case yields the expected catalog or error.
    @Test
    func decodeCases() throws {
        for testCase in try Self.clientCases("decode") {
            let caseId = testCase["caseId"]?.stringValue ?? "?"
            let input = try #require(testCase["input"], "\(caseId): input")
            let (ok, actual) = Self.same(Self.json(StudioPresets.decode(Self.body(input))), testCase["expect"])
            #expect(ok, "\(caseId): got \(actual)")
        }
    }

    /// Every locale tag resolves to the expected preset locale.
    @Test
    func localeCases() throws {
        let locales = try #require(try Self.fixture()["locales"]?.arrayValue).compactMap(\.stringValue)
        #expect(!locales.isEmpty)
        for testCase in try Self.clientCases("locale") {
            let tag = try #require(testCase["tag"]?.stringValue)
            let expected = testCase["expect"]?.stringValue
            let actual = StudioPresets.resolveLocale(locales, tag)
            #expect(actual == expected, "tag \"\(tag)\": got \(actual)")
        }
    }

    /// The bundled snapshot localizes and decodes to the expected offline catalog.
    @Test
    func snapshotCases() throws {
        let snapshot = try #require(StudioPresets.bundledSnapshot(), "bundled snapshot loads")
        for testCase in try Self.clientCases("snapshot") {
            let tag = try #require(testCase["tag"]?.stringValue)
            let actual: JSONValue
            switch StudioPresets.decode(StudioPresets.localize(snapshot, tag)) {
            case .failure(let error):
                actual = Self.object([("error", .string(error.rawValue))])
            case .success(let catalog):
                let firstStyle = catalog.styles.first
                let firstEffect = catalog.effects.first
                let firstGroup = catalog.styleGroups.first
                actual = Self.object([
                    ("locale", .string(catalog.locale)),
                    ("revision", .string(catalog.revision)),
                    ("styles", .number(Double(catalog.styles.count))),
                    ("effects", .number(Double(catalog.effects.count))),
                    ("dropped", .number(Double(catalog.dropped.count))),
                    ("everySampleNull", .bool(catalog.styles.allSatisfy { $0.sample == nil })),
                    ("firstStyle", firstStyle.map { style in
                        Self.object([
                            ("id", .string(style.id)),
                            ("displayName", .string(style.displayName)),
                            ("description", .string(style.description)),
                            ("placeholderColor", Self.optional(style.placeholderColor)),
                        ])
                    } ?? .null),
                    ("firstEffect", firstEffect.map { effect in
                        Self.object([("id", .string(effect.id)), ("displayName", .string(effect.displayName))])
                    } ?? .null),
                    ("firstStyleGroup", firstGroup.map { Self.groupJSON($0) } ?? .null),
                ])
            }
            let (ok, text) = Self.same(actual, testCase["expect"])
            #expect(ok, "tag \"\(tag)\": got \(text)")
        }
    }

    /// Every refresh plan case yields the expected fetch decision.
    @Test
    func refreshPlanCases() throws {
        for testCase in try Self.clientCases("refreshPlan") {
            let caseId = testCase["caseId"]?.stringValue ?? "?"
            let input = testCase["input"]
            let locale = try #require(input?["locale"]?.stringValue, "\(caseId): locale")
            let nowMs = try #require(input?["nowMs"]?.intValue, "\(caseId): nowMs")
            let plan = StudioPresets.planRefresh(cache: try Self.cache(input?["cache"], caseId), locale: locale, nowMs: Int64(nowMs))
            let actual = Self.object([("fetch", .bool(plan.fetch)), ("ifNoneMatch", Self.optional(plan.ifNoneMatch))])
            let (ok, text) = Self.same(actual, testCase["expect"])
            #expect(ok, "\(caseId): got \(text)")
        }
    }

    /// Every refresh response case yields the expected outcome and cache.
    @Test
    func refreshApplyCases() throws {
        for testCase in try Self.clientCases("refreshApply") {
            let caseId = testCase["caseId"]?.stringValue ?? "?"
            let input = testCase["input"]
            let locale = try #require(input?["locale"]?.stringValue, "\(caseId): locale")
            let nowMs = try #require(input?["nowMs"]?.intValue, "\(caseId): nowMs")
            let rawResponse = try #require(input?["response"], "\(caseId): response")
            let status = try #require(rawResponse["status"]?.intValue, "\(caseId): status")
            let response = StudioPresets.Response(
                status: status,
                etag: rawResponse["etag"]?.stringValue,
                body: rawResponse["body"].flatMap { $0 == .null ? nil : Self.body($0) }
            )
            let applied = StudioPresets.applyResponse(
                cache: try Self.cache(input?["cache"], caseId),
                locale: locale,
                nowMs: Int64(nowMs),
                response: response
            )
            let actual = Self.object([
                ("outcome", .string(applied.outcome.rawValue)),
                ("cache", Self.json(applied.cache)),
                ("bodyReplaced", .bool(applied.bodyReplaced)),
            ])
            let (ok, text) = Self.same(actual, testCase["expect"])
            #expect(ok, "\(caseId): got \(text)")
        }
    }
}
