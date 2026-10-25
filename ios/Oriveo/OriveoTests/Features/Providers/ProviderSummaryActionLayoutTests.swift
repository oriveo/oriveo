import Foundation
import Testing
@testable import Oriveo

@Suite("ProviderSummaryActionLayout", .serialized, .sharedProcessState)
struct ProviderSummaryActionLayoutTests {

    @Test("the new chat and verify connection buttons share one width in the horizontal layout")
    func horizontalActionsShareWidthForNonRelayProviderWithDefaultModel() {
        let provider = TestFactories.makeProvider(
            kind: .openRouter,
            models: [TestFactories.makeModel(id: "openai/gpt-4o", isDefault: true)]
        )

        let layout = ProviderSummaryActionLayout.resolve(provider: provider)

        #expect(layout.secondaryActionSizing == .fillAvailableWidth)
    }

    @Test("the detail summary card no longer renders the lastError inline banner")
    func summaryCardDoesNotShowInlineErrorBanner() {
        let provider = TestFactories.makeProvider(
            status: .issue("invalid_key"),
            lastError: "API key validation failed"
        )

        #expect(ProviderSummaryPresentation.showsInlineErrorBanner(for: provider) == false)
    }

    @Test("the detail hero's model count uses the added-models figure")
    func summaryCardUsesAddedModelCountCopy() throws {
        let testDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let projectDirectory = testDirectory
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let summarySourceURL = projectDirectory
            .appendingPathComponent("Oriveo")
            .appendingPathComponent("Features")
            .appendingPathComponent("Providers")
            .appendingPathComponent("ProviderSummaryCard.swift")
        let summarySource = try String(contentsOf: summarySourceURL, encoding: .utf8)

        #expect(summarySource.contains("provider.enabledModelCount"))
        #expect(summarySource.contains("%lld available models"))
        #expect(!summarySource.contains("provider.availableModelCount"))
    }
}
