import Foundation
import Testing
@testable import Oriveo

/// ImageProfile resolution cases shared by all three clients: reads
/// `shared/model-contracts/image_profile_resolution.v1.json` (cases + visibilityCases) and checks
/// the hard-coded enums and route tables against `image_profile.v2.json`.
@Suite("ImageProfileResolutionContractTests")
struct ImageProfileResolutionContractTests {
    typealias JSONValue = ImageProfileResolver.JSONValue

    private struct Fixture: Decodable {
        struct Input: Decodable {
            let providerKind: String?
            let modelId: String
            let relay: ImageProfileResolver.RelayContext?
        }

        struct Expect: Decodable {
            let profileRef: String?
            let reason: String?
            let appliedOverride: [String: JSONValue]?
        }

        struct Case: Decodable {
            let caseId: String
            let input: Input
            let expect: Expect
        }

        struct VisibilityContext: Decodable {
            let connectionUsable: Bool
            let hasBase: Bool
            let referenceCount: Int
        }

        struct VisibilityCase: Decodable {
            let caseId: String
            let profileRef: String
            let context: VisibilityContext
            let expectVisible: Bool
        }

        let contractId: String
        let version: Int
        let reasons: [String]
        let metadata: ImageProfileResolver.Slice
        let cases: [Case]
        let visibilityCases: [VisibilityCase]
    }

    private struct ProfileSchema: Decodable {
        struct Fields: Decodable {
            let required: [String]
        }

        let contractId: String
        let enums: [String: [String]]
        let fields: Fields
        let routes: [String: JSONValue]
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

    private static func load<T: Decodable>(_ type: T.Type, _ name: String) throws -> T {
        let url = try repoFile(["shared", "model-contracts", name])
        return try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
    }

    private static func fixture() throws -> Fixture {
        try load(Fixture.self, "image_profile_resolution.v1.json")
    }

    /// Order-independent JSON text, so override objects compare by content.
    private static func canonical(_ value: [String: JSONValue]?) throws -> String? {
        guard let value else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    private static func strings(_ value: JSONValue?) -> [String]? {
        guard case .array(let items)? = value else { return nil }
        return items.compactMap { item -> String? in
            if case .string(let text) = item { return text }
            return nil
        }
    }

    @Test("Fixture header and reason set match image_profile_resolution.v1")
    func fixtureHeader() throws {
        let fixture = try Self.fixture()
        #expect(fixture.contractId == "image_profile_resolution.v1")
        #expect(fixture.version == 1)
        #expect(fixture.reasons == ImageProfileResolver.Reason.allCases.map(\.rawValue))
        #expect(!fixture.cases.isEmpty)
        #expect(!fixture.visibilityCases.isEmpty)
    }

    @Test("Every resolution case yields the expected profileRef, reason and override")
    func everyCase() throws {
        let fixture = try Self.fixture()
        for testCase in fixture.cases {
            let result = ImageProfileResolver.resolve(
                fixture.metadata,
                providerKind: testCase.input.providerKind,
                modelId: testCase.input.modelId,
                relay: testCase.input.relay
            )
            #expect(result.profileRef == testCase.expect.profileRef, "\(testCase.caseId)")
            #expect(result.reason?.rawValue == testCase.expect.reason, "\(testCase.caseId)")
            #expect(
                try Self.canonical(result.appliedOverride) == Self.canonical(testCase.expect.appliedOverride),
                "\(testCase.caseId)"
            )
            #expect((result.profile != nil) == (testCase.expect.profileRef != nil), "\(testCase.caseId)")
        }
    }

    @Test("Override is shallow-merged into the resolved typed profile")
    func overrideMergesIntoProfile() throws {
        let fixture = try Self.fixture()
        let result = ImageProfileResolver.resolve(fixture.metadata, providerKind: "qwen", modelId: "qwen-image-2.0")
        let profile = try #require(result.profile)
        #expect(profile.maxReferenceImages == 2)
        #expect(profile.typicalSeconds == [5, 15])
        #expect(profile.route == .dashscopeMultimodal)
        #expect(profile.sizeParam == .dashscopeWxh)
        #expect(profile.editTransport == .inline)
        #expect(profile.maxNPerCall == 1)
        #expect(profile.source == .officialApi)
    }

    @Test("Every visibility case matches visibleInStudio")
    func visibilityCases() throws {
        let fixture = try Self.fixture()
        for visibilityCase in fixture.visibilityCases {
            guard case .object(let raw)? = fixture.metadata.profiles?.image?[visibilityCase.profileRef] else {
                Issue.record("profile \(visibilityCase.profileRef) missing for \(visibilityCase.caseId)")
                continue
            }
            let profile = try? ImageProfileResolver.validate(raw).get()
            #expect(profile != nil, "\(visibilityCase.caseId)")
            let visible = ImageProfileResolver.visibleInStudio(
                profile,
                connectionUsable: visibilityCase.context.connectionUsable,
                hasBase: visibilityCase.context.hasBase,
                referenceCount: visibilityCase.context.referenceCount
            )
            #expect(visible == visibilityCase.expectVisible, "\(visibilityCase.caseId)")
        }
    }

    @Test("Hard-coded enums, required fields and route tables match image_profile.v2")
    func enumsMatchSchema() throws {
        let schema = try Self.load(ProfileSchema.self, "image_profile.v2.json")
        #expect(schema.contractId == "image_profile.v2")
        #expect(Set(schema.enums.keys) == [
            "operations", "routes", "editTransports", "sizeParams",
            "qualityTiers", "resolutionTiers", "sources", "pricingUnits",
        ])
        #expect(schema.enums["operations"] == ImageProfile.Operation.allCases.map(\.rawValue))
        #expect(schema.enums["routes"] == ImageProfile.Route.allCases.map(\.rawValue))
        #expect(schema.enums["editTransports"] == ImageProfile.EditTransport.allCases.map(\.rawValue))
        #expect(schema.enums["sizeParams"] == ImageProfile.SizeParam.allCases.map(\.rawValue))
        #expect(schema.enums["qualityTiers"] == ImageProfile.QualityTier.allCases.map(\.rawValue))
        #expect(schema.enums["resolutionTiers"] == ImageProfile.ResolutionTier.allCases.map(\.rawValue))
        #expect(schema.enums["sources"] == ImageProfile.Source.allCases.map(\.rawValue))
        #expect(schema.enums["pricingUnits"] == ImageProfile.PricingUnit.allCases.map(\.rawValue))
        #expect(schema.fields.required == ImageProfile.requiredFields)

        let routeRows = schema.routes.filter { !$0.key.hasPrefix("$") }
        #expect(Set(routeRows.keys) == Set(ImageProfile.Route.allCases.map(\.rawValue)))
        for route in ImageProfile.Route.allCases {
            guard case .object(let row)? = routeRows[route.rawValue] else {
                Issue.record("route \(route.rawValue) missing from image_profile.v2")
                continue
            }
            #expect(
                Self.strings(row["allowedEditTransports"]) == route.allowedEditTransports.map(\.rawValue),
                "\(route.rawValue)"
            )
            #expect(
                Self.strings(row["allowedSizeParams"]) == route.allowedSizeParams.map(\.rawValue),
                "\(route.rawValue)"
            )
        }
    }
}
