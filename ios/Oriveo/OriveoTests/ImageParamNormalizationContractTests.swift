import Foundation
import Testing
@testable import Oriveo

/// Parameter normalization cases shared by all three clients: reads
/// `shared/model-contracts/image_param_normalization.v1.json`, shallow-merges each case's
/// profileOverride over its profile, validates it with ImageProfileResolver and compares the
/// normalized result (or error) with expect field by field.
@Suite("ImageParamNormalizationContractTests")
struct ImageParamNormalizationContractTests {
    typealias JSONValue = ImageProfileResolver.JSONValue

    private struct Fixture: Decodable {
        struct Case: Decodable {
            let caseId: String
            let profile: String
            let profileOverride: [String: JSONValue]?
            let request: [String: JSONValue]
            let expect: [String: JSONValue]
        }

        let contractId: String
        let version: Int
        let defaultAspect: String
        let profiles: [String: [String: JSONValue]]
        let cases: [Case]
    }

    private struct BadRequestValue: Error {
        let caseId: String
        let key: String
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

    private static func fixture() throws -> Fixture {
        let url = try repoFile(["\u{5171}\u{4EAB}", "model-contracts", "image_param_normalization.v1.json"])
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    /// Order-independent JSON text, so result objects compare by content.
    private static func canonical(_ value: [String: JSONValue]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    private static func string(_ raw: [String: JSONValue], _ key: String, _ caseId: String) throws -> String? {
        switch raw[key] {
        case .none, .some(.null): return nil
        case .some(.string(let text)): return text
        default: throw BadRequestValue(caseId: caseId, key: key)
        }
    }

    private static func request(_ raw: [String: JSONValue], _ caseId: String) throws -> ImageParamNormalizer.Request {
        var n: Int?
        switch raw["n"] {
        case .none, .some(.null):
            n = nil
        case .some(.number(let number)) where number.rounded() == number && abs(number) < 1e15:
            n = Int(number)
        default:
            throw BadRequestValue(caseId: caseId, key: "n")
        }
        return ImageParamNormalizer.Request(
            aspect: try string(raw, "aspect", caseId),
            resolution: try string(raw, "resolution", caseId),
            quality: try string(raw, "quality", caseId),
            n: n
        )
    }

    @Test("Fixture header matches image_param_normalization.v1")
    func fixtureHeader() throws {
        let fixture = try Self.fixture()
        #expect(fixture.contractId == "image_param_normalization.v1")
        #expect(fixture.version == 1)
        #expect(fixture.defaultAspect == ImageParamNormalizer.defaultAspect)
        #expect(!fixture.cases.isEmpty)
    }

    @Test("Every normalization case yields the expected result or error")
    func everyCase() throws {
        let fixture = try Self.fixture()
        for testCase in fixture.cases {
            guard var object = fixture.profiles[testCase.profile] else {
                Issue.record("profile \(testCase.profile) missing for \(testCase.caseId)")
                continue
            }
            if let override = testCase.profileOverride {
                object.merge(override) { _, overriding in overriding }
            }
            guard case .success(let profile) = ImageProfileResolver.validate(object) else {
                Issue.record("\(testCase.caseId): merged profile must validate")
                continue
            }
            let request = try Self.request(testCase.request, testCase.caseId)
            let actual: [String: JSONValue]
            switch ImageParamNormalizer.normalize(profile, request: request, defaultAspect: fixture.defaultAspect) {
            case .success(let normalized):
                actual = normalized.jsonObject
            case .failure(let failure):
                actual = ["error": .string(failure.rawValue)]
            }
            let actualText = try Self.canonical(actual)
            let expectedText = try Self.canonical(testCase.expect)
            #expect(actualText == expectedText, "\(testCase.caseId)")
        }
    }
}
