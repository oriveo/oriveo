import Foundation
import CoreGraphics
import SwiftUI
import Testing
@testable import Oriveo

@Suite("HomeModelPickerSheet", .sharedProcessState)
struct HomeModelPickerSheetTests {

    @MainActor
    @Test("the snapshot builds the initial expansion state once at initialization")
    func presentationStoreBuildsInitialExpansionOnce() {
        let provider = makeProvider(
            name: "Relay A",
            models: [makeModel(id: "model-a", name: "Model A", groupKey: "a", groupName: "A")]
        )
        let store = ModelPickerPresentationSnapshot(
            context: .home,
            providers: [provider],
            providersVersion: 7,
            currentProviderID: provider.id,
            currentModel: provider.models.first
        )

        #expect(store.sections.count == 1)
        #expect(store.initialExpandedProviderIDs == [provider.id])
        #expect(store.initialExpandedVendorGroupIDs.isEmpty)
    }

    // Linearity is judged by the time ratio when the catalog doubles, not by an absolute budget: a fixed
    // budget measures machine load, the ratio measures complexity (linear ~2x, quadratic ~4x).
    @MainActor
    @Test("building a model picker snapshot scales linearly with catalog size")
    func largeCatalogBuildScalesLinearly() {
        func providers(count: Int) -> [Provider] {
            (0..<count).map { providerIndex in
                makeProvider(
                    name: "Relay \(providerIndex)",
                    models: (0..<300).map { modelIndex in
                        makeModel(
                            id: "p\(providerIndex)-m\(modelIndex)",
                            name: "Model \(modelIndex)",
                            groupKey: "group-\(modelIndex % 10)",
                            groupName: "Group \(modelIndex % 10)"
                        )
                    }
                )
            }
        }
        func fastestBuild(_ providers: [Provider]) -> Duration {
            let clock = ContinuousClock()
            var best = Duration.seconds(3_600)
            // The first round warms caches; scheduling jitter can only inflate a sample, so keep the minimum.
            for _ in 0..<3 {
                let start = clock.now
                _ = buildModelPickerSections(
                    context: .home,
                    providers: providers,
                    currentProviderID: providers.first?.id,
                    currentModel: providers.first?.models.first
                )
                best = min(best, start.duration(to: clock.now))
            }
            return best
        }

        let small = providers(count: 5)
        let large = providers(count: 10)
        let sections = buildModelPickerSections(
            context: .home,
            providers: large,
            currentProviderID: large.first?.id,
            currentModel: large.first?.models.first
        )
        #expect(sections.count == 10)
        #expect(sections.reduce(0) { $0 + $1.models.count } == 3_000)

        let ratio = fastestBuild(large) / fastestBuild(small)
        #expect(ratio < 2.5, "doubling the catalog took \(ratio)x")
    }

    @Test("structured prices split into compact Input and Output")
    func structuredPricingUsesCompactFields() {
        var model = makeModel(
            id: "gpt-4.1",
            name: "GPT-4.1",
            groupKey: "openai",
            groupName: "OpenAI"
        )
        model.promptPrice = 0.00000125
        model.completionPrice = 0.00000375

        let pricing = ModelPickerPricePresentation(model: model)

        #expect(pricing.input == "$1.25/M")
        #expect(pricing.output == "$3.75/M")
        #expect(pricing.fallback == nil)
    }

    @Test("the three-step price layout degradation matches the original nested ViewThatFits criterion")
    func priceLayoutDegradesInSameOrderAsNestedViewThatFits() {
        // Ideal sizes of the labels / values: Input 36+4+44=84, Output 46+4+50=100, the whole row 84+12+100=196.
        let sizes = [
            CGSize(width: 36, height: 13), CGSize(width: 44, height: 13),
            CGSize(width: 46, height: 13), CGSize(width: 50, height: 13),
        ]
        typealias Layout = ModelPickerPriceLayout

        // Measuring the ideal size (no width proposed) and fitting the whole row put the two side by side.
        #expect(Layout.arrangement(idealSizes: sizes, width: nil) == .singleLine)
        #expect(Layout.arrangement(idealSizes: sizes, width: 196) == .singleLine)
        // When the whole row does not fit it splits into lines, and each part compares its own "label value" width.
        #expect(Layout.arrangement(idealSizes: sizes, width: 195.5) == .lines(stacked: [false, false]))
        #expect(Layout.arrangement(idealSizes: sizes, width: 100) == .lines(stacked: [false, false]))
        #expect(Layout.arrangement(idealSizes: sizes, width: 99) == .lines(stacked: [false, true]))
        #expect(Layout.arrangement(idealSizes: sizes, width: 80) == .lines(stacked: [true, true]))
        // With only one price part the whole row is that part.
        #expect(Layout.arrangement(idealSizes: Array(sizes.prefix(2)), width: 84) == .singleLine)
        #expect(Layout.arrangement(idealSizes: Array(sizes.prefix(2)), width: 83) == .lines(stacked: [true]))
    }

    @Test("model context length uses the same compact format as the web app")
    func modelContextLengthUsesCrossPlatformCompactFormat() {
        #expect(formatModelPickerContextLength(nil) == nil)
        #expect(formatModelPickerContextLength(0) == nil)
        #expect(formatModelPickerContextLength(999) == "999")
        #expect(formatModelPickerContextLength(32_000) == "32K")
        #expect(formatModelPickerContextLength(131_072) == "131K")
        #expect(formatModelPickerContextLength(1_000_000) == "1M")
        #expect(formatModelPickerContextLength(1_050_000) == "1.1M")
        #expect(formatModelPickerContextLength(12_400_000) == "12M")
    }

    @Test("a missing price on one side is not reported as zero or free")
    func missingStructuredPriceStaysUnknown() {
        var outputOnly = makeModel(
            id: "output-only",
            name: "Output only",
            groupKey: "test",
            groupName: "Test"
        )
        outputOnly.promptPrice = nil
        outputOnly.completionPrice = 0.0000032
        let outputPricing = ModelPickerPricePresentation(model: outputOnly)

        var inputOnly = outputOnly
        inputOnly.promptPrice = 0
        inputOnly.completionPrice = nil
        let inputPricing = ModelPickerPricePresentation(model: inputOnly)

        #expect(outputPricing.input == nil)
        #expect(outputPricing.output == "$3.2/M")
        #expect(outputPricing.fallback == nil)
        #expect(inputPricing.input == "$0/M")
        #expect(inputPricing.output == nil)
        #expect(inputPricing.fallback == nil)
    }

    private func makeModel(
        id: String,
        name: String,
        groupKey: String,
        groupName: String,
        priceTier: String = "standard"
    ) -> AIModel {
        AIModel(
            id: id,
            name: name,
            capabilities: [.text],
            reasoningModeAvailable: false,
            isAvailable: true,
            isDefault: false,
            priceTier: priceTier,
            groupKey: groupKey,
            groupName: groupName
        )
    }

    private func makeProvider(name: String, models: [AIModel], kind: ProviderKind = .relay) -> Provider {
        Provider(
            id: UUID(),
            kind: kind,
            status: .connected,
            models: models,
            catalogModels: [],
            lastCheckedAt: nil,
            apiKey: "sk-test",
            apiKeyPreview: "sk-...",
            lastError: nil,
            baseURLText: nil,
            customName: name
        )
    }
}
