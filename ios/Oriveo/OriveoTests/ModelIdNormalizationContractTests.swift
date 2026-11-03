import Foundation
import Testing
@testable import Oriveo

/// Model id normalization cases shared by all three clients: reads
/// `shared/model-contracts/model_id_normalization.v1.json` and checks every case.
@Suite("ModelIdNormalizationContractTests")
struct ModelIdNormalizationContractTests {
    private struct Fixture: Decodable {
        struct Case: Decodable {
            let caseId: String
            let input: String
            let expect: String
        }

        let contractId: String
        let version: Int
        let steps: [String]
        let cases: [Case]
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
        let url = try repoFile(["\u{5171}\u{4EAB}", "model-contracts", "model_id_normalization.v1.json"])
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    @Test("Fixture header matches model_id_normalization.v1")
    func fixtureHeader() throws {
        let fixture = try Self.fixture()
        #expect(fixture.contractId == "model_id_normalization.v1")
        #expect(fixture.version == 1)
        #expect(fixture.steps == ["trim", "lowercase", "strip_through_last_slash", "strip_trailing_date"])
        #expect(!fixture.cases.isEmpty)
    }

    @Test("Every fixture case normalizes to the expected lookup key")
    func everyCase() throws {
        for testCase in try Self.fixture().cases {
            #expect(
                ModelIdNormalization.normalize(testCase.input) == testCase.expect,
                "\(testCase.caseId)"
            )
        }
    }
}
