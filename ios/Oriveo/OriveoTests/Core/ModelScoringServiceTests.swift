import XCTest
@testable import Oriveo

final class ModelScoringServiceTests: XCTestCase {

    // MARK: - selectDefault

    func testSelectDefault_marksHighestScoreAsDefault() {
        let models = [
            makeModel(id: "low", score: 10),
            makeModel(id: "high", score: 100),
            makeModel(id: "mid", score: 50)
        ]

        let result = ModelScoringService.selectDefault(from: models) { scoreMap[$0.id] ?? 0 }

        XCTAssertFalse(result[0].isDefault)
        XCTAssertTrue(result[1].isDefault)
        XCTAssertFalse(result[2].isDefault)
    }

    func testSelectDefault_emptyModelsReturnsEmpty() {
        let result = ModelScoringService.selectDefault(from: []) { _ in 0 }
        XCTAssertTrue(result.isEmpty)
    }

    func testSelectDefault_singleModel() {
        let models = [makeModel(id: "only")]
        let result = ModelScoringService.selectDefault(from: models) { _ in 42 }

        XCTAssertEqual(result.count, 1)
        XCTAssertTrue(result[0].isDefault)
    }

    func testSelectDefault_tiedScoresPicksFirst() {
        let models = [
            makeModel(id: "a", score: 50),
            makeModel(id: "b", score: 50)
        ]

        let result = ModelScoringService.selectDefault(from: models) { scoreMap[$0.id] ?? 0 }

        let defaultCount = result.filter(\.isDefault).count
        XCTAssertEqual(defaultCount, 1, "there can be only one default")
    }

    // MARK: - selectRecommended

    func testSelectRecommended_preferredGroupsFirst() {
        let models = [
            makeModel(id: "m1", groupKey: "openai", score: 80, isAvailable: true),
            makeModel(id: "m2", groupKey: "anthropic", score: 90, isAvailable: true),
            makeModel(id: "m3", groupKey: "google", score: 70, isAvailable: true),
            makeModel(id: "m4", groupKey: "meta", score: 60, isAvailable: true)
        ]

        let result = ModelScoringService.selectRecommended(
            from: models,
            scoreFn: { scoreMap[$0.id] ?? 0 },
            preferredGroups: ["anthropic", "openai"],
            maxCount: 3
        )

        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result[0].id, "m2", "anthropic should rank first")
        XCTAssertEqual(result[1].id, "m1", "openai should rank second")
    }

    func testSelectRecommended_maxCountLimits() {
        let models = (0 ..< 10).map {
            makeModel(id: "m\($0)", groupKey: "g\($0)", score: 100 - $0, isAvailable: true)
        }

        let result = ModelScoringService.selectRecommended(
            from: models,
            scoreFn: { scoreMap[$0.id] ?? 0 },
            preferredGroups: [],
            maxCount: 4
        )

        XCTAssertEqual(result.count, 4)
    }

    func testSelectRecommended_filtersUnavailableIfPossible() {
        let models = [
            makeModel(id: "available", groupKey: "a", score: 50, isAvailable: true),
            makeModel(id: "unavailable", groupKey: "b", score: 100, isAvailable: false)
        ]

        let result = ModelScoringService.selectRecommended(
            from: models,
            scoreFn: { scoreMap[$0.id] ?? 0 },
            preferredGroups: [],
            maxCount: 6
        )

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].id, "available")
    }

    func testSelectRecommended_fallsBackToAllWhenNoneAvailable() {
        let models = [
            makeModel(id: "u1", groupKey: "a", score: 80, isAvailable: false),
            makeModel(id: "u2", groupKey: "b", score: 60, isAvailable: false)
        ]

        let result = ModelScoringService.selectRecommended(
            from: models,
            scoreFn: { scoreMap[$0.id] ?? 0 },
            preferredGroups: [],
            maxCount: 6
        )

        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].id, "u1", "higher score ranks first")
    }

    func testSelectRecommended_noDuplicates() {
        let models = [
            makeModel(id: "m1", groupKey: "anthropic", score: 100, isAvailable: true),
            makeModel(id: "m2", groupKey: "openai", score: 80, isAvailable: true)
        ]

        let result = ModelScoringService.selectRecommended(
            from: models,
            scoreFn: { scoreMap[$0.id] ?? 0 },
            preferredGroups: ["anthropic", "openai"],
            maxCount: 6
        )

        let ids = result.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count, "must not have duplicate models")
    }

    // MARK: - Helpers

    private var scoreMap: [String: Int] = [:]

    private func makeModel(
        id: String,
        groupKey: String = "default",
        score: Int = 0,
        isAvailable: Bool = true
    ) -> AIModel {
        scoreMap[id] = score
        return AIModel(
            id: id,
            name: id,
            capabilities: [.text],
            reasoningModeAvailable: false,
            isAvailable: isAvailable,
            isDefault: false,
            priceTier: "",
            summary: nil,
            groupKey: groupKey,
            groupName: groupKey
        )
    }
}
