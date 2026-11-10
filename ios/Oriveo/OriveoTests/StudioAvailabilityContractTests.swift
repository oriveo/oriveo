import Foundation
import Testing
@testable import Oriveo

/// Studio availability truth table shared by all three clients: reads
/// `shared/studio-contracts/studio_availability.v1.json` and checks every case key by key.
/// iOS has no Web API, so `webApiStatus` is the only skipped key.
@Suite("StudioAvailabilityContractTests")
struct StudioAvailabilityContractTests {
    private struct Fixture: Decodable {
        struct RawInput: Decodable {
            let compileFlag: Bool
            let remoteStudioEnabled: Bool?
            let remoteManagedEnabled: Bool?
            let imageDisabled: Bool?
            let enabledManagedModels: Int?
            let isPro: Bool
        }

        enum Value: Decodable, Equatable {
            case bool(Bool)
            case string(String)

            init(from decoder: Decoder) throws {
                let container = try decoder.singleValueContainer()
                if let value = try? container.decode(Bool.self) {
                    self = .bool(value)
                } else {
                    self = .string(try container.decode(String.self))
                }
            }
        }

        struct Case: Decodable {
            let caseId: String
            let input: RawInput
            let expect: [String: Value]
        }

        let contractId: String
        let version: Int
        let cases: [Case]
    }

    /// Keys in `expect` that only the Web client produces.
    private static let skippedKeys: Set<String> = ["webApiStatus"]

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

    private static func fixture() throws -> Fixture {
        let url = try repoFile(["shared", "studio-contracts", "studio_availability.v1.json"])
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    private static func keyed(_ result: StudioAvailability.Result) -> [String: Bool] {
        [
            "entryVisible": result.entryVisible,
            "deepLinkOpens": result.deepLinkOpens,
            "badgeRendered": result.badgeRendered,
            "managedListed": result.managedListed,
            "managedInChatPicker": result.managedInChatPicker,
            "chatWorkRegistration": result.chatWorkRegistration,
            "syncWorks": result.syncWorks,
        ]
    }

    @Test("Fixture header matches studio_availability.v1")
    func fixtureHeader() throws {
        let fixture = try Self.fixture()
        #expect(fixture.contractId == "studio_availability.v1")
        #expect(fixture.version == 1)
        #expect(!fixture.cases.isEmpty)
    }

    @Test("Every shared case matches key by key, skipping only webApiStatus")
    func casesMatchKeyByKey() throws {
        let fixture = try Self.fixture()
        for testCase in fixture.cases {
            let raw = testCase.input
            let result = StudioAvailability.evaluate(
                StudioAvailability.Input(
                    compileFlag: raw.compileFlag,
                    remoteStudioEnabled: raw.remoteStudioEnabled,
                    remoteManagedEnabled: raw.remoteManagedEnabled,
                    imageDisabled: raw.imageDisabled ?? false,
                    enabledManagedModels: raw.enabledManagedModels ?? 0,
                    isPro: raw.isPro
                )
            )
            let actual = Self.keyed(result)
            let expectedKeys = Set(testCase.expect.keys)
            let skipped = expectedKeys.subtracting(actual.keys)
            #expect(skipped == Self.skippedKeys, "case \(testCase.caseId): skipped keys \(skipped.sorted())")
            #expect(Set(actual.keys).isSubset(of: expectedKeys), "case \(testCase.caseId): result key missing from expect")
            for (key, value) in testCase.expect where !Self.skippedKeys.contains(key) {
                #expect(
                    actual[key].map(Fixture.Value.bool) == value,
                    "case \(testCase.caseId): \(key) expected \(value), got \(String(describing: actual[key]))"
                )
            }
        }
    }

    @Test("Empty featureFlags with compile flag on shows the entry and hides managed models")
    func emptyFeatureFlagsUseDefaults() {
        let input = StudioAvailability.input(
            featureFlags: [:],
            compileFlag: true,
            imageDisabled: false,
            enabledManagedModels: 2,
            isPro: false
        )
        #expect(input.remoteStudioEnabled == nil)
        #expect(input.remoteManagedEnabled == nil)
        let result = StudioAvailability.evaluate(input)
        #expect(result.entryVisible)
        #expect(!result.managedListed)
    }

    @Test("Explicit featureFlags values map through the literal remote key names")
    func explicitFeatureFlagsMapByKeyName() {
        let off = StudioAvailability.input(
            featureFlags: ["studio_enabled": false, "studio_managed_enabled": true],
            compileFlag: true,
            imageDisabled: false,
            enabledManagedModels: 2,
            isPro: false
        )
        #expect(off.remoteStudioEnabled == false)
        #expect(off.remoteManagedEnabled == true)
        let offResult = StudioAvailability.evaluate(off)
        #expect(!offResult.entryVisible)
        #expect(!offResult.managedListed)

        let on = StudioAvailability.input(
            featureFlags: ["studio_enabled": true, "studio_managed_enabled": true],
            compileFlag: true,
            imageDisabled: false,
            enabledManagedModels: 2,
            isPro: false
        )
        #expect(on.remoteStudioEnabled == true)
        #expect(on.remoteManagedEnabled == true)
        #expect(StudioAvailability.evaluate(on).managedListed)
    }
}
