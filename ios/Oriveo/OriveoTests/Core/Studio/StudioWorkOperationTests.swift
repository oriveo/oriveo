import Foundation
import Testing
@testable import Oriveo

/// `StudioWorkOperation.resolve` against `operationTable` in the shared fixture
/// `studio_data_model.v1.json`.
@Suite("StudioWorkOperationTests")
struct StudioWorkOperationTests {
    @Test func testOperationTable_matchFixture() throws {
        let fixture = try StudioByokTasksContractTests.jsonObject(["studio_data_model.v1.json"])
        let table = try #require(fixture["operationTable"] as? [[String: Any]])
        #expect(!table.isEmpty)
        for row in table {
            let caseId = try #require(row["caseId"] as? String)
            let context = try #require(row["context"] as? [String: Any], "\(caseId)")
            let expect = try #require(row["expect"] as? [String: Any], "\(caseId)")
            let inWorkDetail = try #require(context["inWorkDetail"] as? Bool, "\(caseId)")
            let images = try #require(context["images"] as? [String], "\(caseId)")
            let modelOps = try #require(row["modelOps"] as? [String], "\(caseId)")
            let roles = try images.map { raw in try #require(StudioReferenceRole(rawValue: raw), "\(caseId) role \(raw)") }
            let operations = try modelOps.map { raw in
                try #require(StudioWorkOperationKind(rawValue: raw), "\(caseId) operation \(raw)")
            }

            let result = StudioWorkOperation.resolve(
                inWorkDetail: inWorkDetail,
                imageRoles: roles,
                modelOperations: Set(operations)
            )

            #expect(result.operation?.rawValue == expect["operation"] as? String, "\(caseId) operation")
            #expect(result.base?.rawValue == expect["base"] as? String, "\(caseId) base")
            #expect(result.importFirst == (expect["importFirst"] as? Bool), "\(caseId) importFirst")
            #expect(result.blocked?.rawValue == expect["blocked"] as? String, "\(caseId) blocked")
        }
    }
}
