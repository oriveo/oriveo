import Foundation
import Testing
@testable import Oriveo

/// Model-row capability badges follow one cross-platform rule, read from
/// `shared/model-contracts/model_row_capability_badges.v1.json` (Android and Web read the same file).
/// The picker row and the provider detail row must use the same projection and the same limit.
@Suite("Model Row Capability Badge Contract")
struct ModelRowCapabilityContractTests {
    private struct Fixture: Decodable {
        struct Case: Decodable {
            let name: String
            let input: [String]
            let expected: [String]
        }

        let contractVersion: Int
        let maxVisible: Int
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
        let url = try repoFile(["shared", "model-contracts", "model_row_capability_badges.v1.json"])
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    private static func capability(_ raw: String) throws -> ModelCapability {
        try #require(ModelCapability(rawValue: raw), "unknown capability \(raw)")
    }

    @Test("Row limit matches the shared contract")
    func rowLimitMatchesContract() throws {
        let fixture = try Self.fixture()
        #expect(fixture.contractVersion == 1)
        #expect(ModelCapability.modelRowMaxCapabilities == fixture.maxVisible)
    }

    @Test("Truncation matches every shared case")
    func truncationMatchesEveryCase() throws {
        let fixture = try Self.fixture()
        #expect(!fixture.cases.isEmpty)
        for item in fixture.cases {
            let input = try item.input.map(Self.capability)
            let expected = try item.expected.map(Self.capability)
            #expect(
                ModelCapability.limitForModelRow(input, maxCapabilities: fixture.maxVisible) == expected,
                "\(item.name)"
            )
        }
    }

    @Test("Picker row and provider detail row share the projection and the limit")
    func pickerAndProviderDetailShareProjection() throws {
        let base = ["ios", "Oriveo", "Oriveo", "Features"]
        let picker = try String(
            contentsOf: Self.repoFile(base + ["Home", "HomeModelPickerSheet.swift"]),
            encoding: .utf8
        )
        let detail = try String(
            contentsOf: Self.repoFile(base + ["Providers", "ProviderEnabledModels.swift"]),
            encoding: .utf8
        )
        let pickerRow = try #require(
            picker.range(of: "private struct ModelPickerRow:").flatMap { start in
                picker.range(of: "private struct ModelPickerRowButtonStyle", range: start.upperBound..<picker.endIndex)
                    .map { String(picker[start.lowerBound..<$0.lowerBound]) }
            }
        )
        for source in [pickerRow, detail] {
            #expect(source.contains("model.visibleMetadataCapabilities(provider: provider)"))
        }
        // The picker must not split web / reasoning out into trailing icons, nor pick a smaller limit.
        #expect(!pickerRow.contains("maxCapabilities:"))
        #expect(!pickerRow.contains("intentCapabilities"))
    }
}
