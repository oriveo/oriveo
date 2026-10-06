import Foundation
import Testing
@testable import Oriveo

/// Summary for the "Advanced settings" row on the model options page: only items changed in this conversation that will actually be sent right now.
@Suite("Generation parameter row model")
struct GenerationParameterRowModelTests {
    private static func row(
        _ id: String, _ title: String, _ value: String?,
        source: GenerationParameterResolution.Source = .conversation,
        validationError: String? = nil,
        dropReason: GenerationParameterApplication.DropReason? = nil,
        supersededBy: String? = nil
    ) -> GenerationParameterRowModel {
        GenerationParameterRowModel(
            id: id, title: title, displayValue: value, source: source,
            allowedRangeText: nil, validationError: validationError,
            dropReason: dropReason, supersededBy: supersededBy
        )
    }

    @Test("Only items changed in this conversation count; inherited model defaults and model-decided values stay out of the summary")
    func summaryCountsOnlyConversationRows() {
        let summary = GenerationParameterRowModel.summary([
            Self.row("temperature", "Temperature", "0.7"),
            Self.row("top_p", "Top P", "0.9", source: .modelDefault),
            Self.row("seed", "Seed", nil, source: .providerDecides),
            Self.row("max_tokens", "Max tokens", "4096"),
        ])
        #expect(summary.chips == ["Temperature 0.7", "Max tokens 4096"])
        #expect(summary.moreCount == 0)
    }

    @Test("Items past the limit fold into the remaining count, in the order of the rows passed in")
    func summaryFoldsOverflowIntoMoreCount() {
        let rows = [
            Self.row("temperature", "Temperature", "0.7"),
            Self.row("max_tokens", "Max tokens", "4096"),
            Self.row("top_p", "Top P", "0.9"),
            Self.row("top_k", "Top K", "40"),
        ]
        let summary = GenerationParameterRowModel.summary(rows)
        #expect(summary.chips == ["Temperature 0.7", "Max tokens 4096"])
        #expect(summary.moreCount == 2)

        let single = GenerationParameterRowModel.summary(rows, maxChips: 1)
        #expect(single.chips == ["Temperature 0.7"])
        #expect(single.moreCount == 3)

        // A limit of zero or less yields no chips; everything goes into the count.
        let none = GenerationParameterRowModel.summary(rows, maxChips: 0)
        #expect(none.chips.isEmpty)
        #expect(none.moreCount == 4)
    }

    @Test("Items that will not be sent stay out of the summary: out of range, dropped, taken over by another parameter, or with no value to show")
    func summarySkipsRowsThatWillNotBeSent() {
        let summary = GenerationParameterRowModel.summary([
            Self.row("temperature", "Temperature", "9", validationError: "Enter a value from 0 to 2."),
            Self.row("top_k", "Top K", "40", dropReason: .thinkingIncompatible),
            Self.row("top_p", "Top P", "0.9", supersededBy: "mirostat"),
            Self.row("stop", "Stop sequences", nil),
            Self.row("max_tokens", "Max tokens", "4096"),
        ])
        #expect(summary.chips == ["Max tokens 4096"])
        #expect(summary.moreCount == 0)
    }

    @Test("Source and drop reason come straight from the production evaluation, not from a second set of enums")
    func rowsCarryProductionSourceAndDropReason() {
        // The source comes from production's layer-to-source projection, not assembled by the test.
        let resolution = GenerationParameterResolution(entries: [
            "temperature": .init(override: .init(state: .value, value: .number(0.7)), layer: .conversation),
            "top_p": .init(override: .init(state: .value, value: .number(0.9)), layer: .connectionModel),
        ])
        var application = GenerationParameterApplication()
        application.drop("top_p", .conflict)

        let rows = ["temperature", "top_p", "seed"].map { id in
            Self.row(
                id, id, resolution.entries[id] == nil ? nil : "set",
                source: resolution.source(for: id),
                dropReason: application.dropped.first { $0.parameterID == id }?.reason
            )
        }
        #expect(rows.map(\.source) == [.conversation, .modelDefault, .providerDecides])
        #expect(rows.map(\.dropReason) == [nil, .conflict, nil])
        #expect(rows.map(\.id) == ["temperature", "top_p", "seed"])
        #expect(GenerationParameterRowModel.summary(rows).chips == ["temperature set"])
    }
}
