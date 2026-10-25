import Foundation
import Testing
@testable import Oriveo

/// Case-by-case run of the shared fixture `shared/test-fixtures/capability/overrides.v1.json`:
/// fixture text -> production decoder -> production normalizer -> production encoder, compared field by field
/// with the fixture's expectations.
nonisolated enum CapabilityOverridesFixture {
    static let root: [String: Any] = {
        let data = try! Data(contentsOf: findFixtureURL())
        return try! JSONSerialization.jsonObject(with: data) as! [String: Any]
    }()

    static var cases: [[String: Any]] {
        root["cases"] as? [[String: Any]] ?? []
    }

    static var caseIDs: [String] {
        cases.compactMap { $0["id"] as? String }
    }

    static func testCase(_ id: String) throws -> [String: Any] {
        try #require(cases.first { $0["id"] as? String == id }, "Fixture is missing case \(id)")
    }

    /// A JSON fragment from the fixture -> production Decodable; null or absent gives nil.
    static func decode<T: Decodable>(_ type: T.Type, _ raw: Any?) throws -> T? {
        guard let raw, !(raw is NSNull) else { return nil }
        let data = try JSONSerialization.data(withJSONObject: raw)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private static func findFixtureURL() -> URL {
        let relativeComponents = ["shared", "test-fixtures", "capability", "overrides.v1.json"]
        var currentURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while true {
            let candidate = relativeComponents.reduce(currentURL) { $0.appendingPathComponent($1) }
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            let parentURL = currentURL.deletingLastPathComponent()
            if parentURL.path == currentURL.path { break }
            currentURL = parentURL
        }
        fatalError("Shared fixture overrides.v1.json not found")
    }
}

@Suite("CapabilityOverrideDelta")
struct CapabilityOverrideDeltaTests {
    @Test func fixtureHasCases() {
        #expect(CapabilityOverridesFixture.caseIDs.count >= 9)
    }

    @Test(arguments: CapabilityOverridesFixture.caseIDs)
    func fixtureCase(_ id: String) throws {
        let raw = try CapabilityOverridesFixture.testCase(id)
        let expect = try #require(raw["expect"] as? [String: Any])

        let connectionRaw = try #require(raw["connection"] as? String)
        let connection = try #require(ProviderForm(rawValue: connectionRaw), "\(id): unknown connection form \(connectionRaw)")
        let nowRaw = try #require(raw["now"] as? String)
        let now = try #require(CapabilityOverrideClock.parse(nowRaw))
        let legacy = try CapabilityOverridesFixture.decode(RelayCapabilityOverrides.self, raw["legacy"])
        let stored = try CapabilityOverridesFixture.decode(CapabilityOverrides.self, raw["stored"])
        let verdictRaw = try #require(raw["serverVerdict"] as? [String: String])
        var serverVerdict: [CapabilityOverrideKey: String] = [:]
        for (key, state) in verdictRaw {
            serverVerdict[try #require(CapabilityOverrideKey(rawValue: key))] = state
        }

        let result = CapabilityOverrideNormalizer.normalize(
            connection: connection,
            legacy: legacy,
            stored: stored,
            serverVerdict: serverVerdict,
            now: now
        )

        // capabilityOverrides: the production encoder's output matches the fixture field by field.
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(result.capabilityOverrides))
        let expectedOverrides = try #require(expect["capabilityOverrides"] as? [String: Any])
        #expect((encoded as? NSDictionary) == (expectedOverrides as NSDictionary), "\(id): capabilityOverrides")

        // legacyKept: the keys still left in the legacy field after migration (compared without regard to order).
        let kept = result.legacyKept
        let keptKeys = Set(RelayCapabilityOverrides.Key.allCases.filter { key in
            key == .reasoningLevels ? kept?.reasoningLevels != nil : kept?.value(for: key) != nil
        }.map(\.rawValue))
        let expectedKept = Set(try #require(expect["legacyKept"] as? [String]))
        #expect(keptKeys == expectedKept, "\(id): legacyKept")

        // effective: the effective op for each of the three input keys; null = follow the server.
        let expectedEffective = try #require(expect["effective"] as? [String: Any])
        #expect(Set(expectedEffective.keys) == Set(CapabilityOverrideKey.allCases.map(\.rawValue)), "\(id): effective key set")
        for key in CapabilityOverrideKey.allCases {
            let expected = expectedEffective[key.rawValue] as? String
            #expect(result.effective(key)?.rawValue == expected, "\(id): effective.\(key.rawValue)")
        }
    }
}
