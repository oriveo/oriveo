import Foundation
import Testing
@testable import Oriveo

@Suite("ProviderDetail visual refresh")
struct ProviderDetailVisualRefreshTests {

    @Test("Detail View Uses Refreshed Visual Structure")
    func detailViewUsesRefreshedVisualStructure() throws {
        let detailSource = try String(contentsOf: providerSourceURL("ProviderDetailView.swift"), encoding: .utf8)
        let summarySource = try String(contentsOf: providerSourceURL("ProviderSummaryCard.swift"), encoding: .utf8)
        let enabledModelsSource = try String(contentsOf: providerSourceURL("ProviderEnabledModels.swift"), encoding: .utf8)
        let settingsSource = try String(contentsOf: providerSourceURL("ProviderSettingsSection.swift"), encoding: .utf8)

        #expect(detailSource.contains("ProviderDetailBrandHeroCard"))
        #expect(!summarySource.contains("ProviderDefaultModelPreviewCard"))
        #expect(!summarySource.contains("defaultModelPreview"))
        #expect(summarySource.contains("private var watermark"))
        #expect(summarySource.contains("subduedBrand"))
        #expect(summarySource.contains(".environment(\\.colorScheme, .dark)"))
        #expect(summarySource.contains("private var nameAndMeta"))
        #expect(summarySource.contains("private var apiKeyRow"))
        #expect(summarySource.contains("apiKeyDisplayValue"))
        #expect(summarySource.contains("struct ProviderSectionHeader"))
        #expect(!summarySource.contains("let eyebrow: String"))
        #expect(enabledModelsSource.contains("ProviderSectionHeader("))
        #expect(detailSource.contains("ProviderSectionHeader("))
        #expect(detailSource.contains("private func topBar() -> some View"))
        #expect(detailSource.contains("ProviderConnectionIssueRecoveryCard"))
        #expect(detailSource.contains("onUpdateAPIKey"))
        #expect(detailSource.contains("onRetryConnection"))
        #expect(enabledModelsSource.contains("ProviderEnabledModelRow"))
        #expect(enabledModelsSource.contains("groupedModelsPanel"))
        #expect(enabledModelsSource.contains("rowBackgroundTint"))
        #expect(!enabledModelsSource.contains("rowShadowColor"))
        #expect(!enabledModelsSource.contains(".scaleEffect(isHighlighted"))
        #expect(enabledModelsSource.contains("ModelListMetadataRow("))
        #expect(enabledModelsSource.contains("provider: provider"))
        #expect(enabledModelsSource.contains("model.normalizedPriceTier"))
        let enabledRowSource = try enabledModelsSource.requiredSlice(
            from: "struct ProviderEnabledModelRow",
            to: "    private var modelActions"
        )
        #expect(!enabledRowSource.contains("StatusPill(title: L10n.tr(\"Default\")"))
        #expect(!enabledRowSource.contains("model.isDefault ||"))
        #expect(settingsSource.contains("settingsRow("))
        #expect(settingsSource.contains("rowDivider"))
        #expect(!settingsSource.contains("ProviderSettingsGroupedPanel"))
        #expect(!settingsSource.contains("ProviderDangerDivider"))
    }

    @Test("Model Rows Allow Long Model Names To Wrap")
    func modelRowsAllowLongModelNamesToWrap() throws {
        let enabledModelsSource = try String(contentsOf: providerSourceURL("ProviderEnabledModels.swift"), encoding: .utf8)
        let modelLibrarySource = try String(contentsOf: providerSourceURL("ProviderModelLibrary.swift"), encoding: .utf8)

        let enabledRowSource = try enabledModelsSource.requiredSlice(
            from: "struct ProviderEnabledModelRow",
            to: "    private var modelActions"
        )
        // The catalog row is split into a board row (name in RelayCatalogRowContent) and a plain row; the name-wrapping constraint is checked on the plain row.
        let catalogRowSource = try modelLibrarySource.requiredSlice(
            from: "    private func plainRow",
            to: "        .buttonStyle(.plain)"
        )

        #expect(enabledRowSource.contains("Text(model.name)"))
        #expect(!enabledRowSource.contains(".lineLimit(1)"))
        #expect(enabledRowSource.contains(".fixedSize(horizontal: false, vertical: true)"))

        #expect(catalogRowSource.contains("Text(model.name)"))
        #expect(!catalogRowSource.contains(".lineLimit(2)"))
        #expect(catalogRowSource.contains(".fixedSize(horizontal: false, vertical: true)"))
        #expect(catalogRowSource.contains(".layoutPriority(1)"))
    }

    @Test("Model Specifications Use Compact Inline Layout")
    func modelSpecificationsUseCompactInlineLayout() throws {
        let enabledModelsSource = try String(contentsOf: providerSourceURL("ProviderEnabledModels.swift"), encoding: .utf8)
        let sharedSource = try String(contentsOf: providerSourceURL("ProviderModelShared.swift"), encoding: .utf8)

        let enabledRowSource = try enabledModelsSource.requiredSlice(
            from: "struct ProviderEnabledModelRow",
            to: "    private var modelActions"
        )
        let inlineSpecSource = try sharedSource.requiredSlice(
            from: "struct ProviderModelSpecInline",
            to: "private func perMillionPriceText"
        )

        #expect(enabledRowSource.contains("if hasDetailedSpecifications"))
        #expect(inlineSpecSource.contains("VStack(alignment: .leading, spacing: 3)"))
        #expect(inlineSpecSource.contains("Text(\"  •  \")"))
        #expect(inlineSpecSource.contains(".lineLimit(1)"))
        #expect(inlineSpecSource.contains(".minimumScaleFactor(0.7)"))
        #expect(!inlineSpecSource.contains("GridItem"))
        #expect(!inlineSpecSource.contains(".adaptive("))
    }

    @Test("Catalog model groups preserve catalog order and expose pricing metadata")
    func modelGroupsAndSpecificationsFollowTheCatalog() {
        let models = [
            AIModel(
                id: "zeta-1",
                name: "Zeta",
                capabilities: [.text],
                reasoningModeAvailable: false,
                isAvailable: true,
                isDefault: true,
                priceTier: "",
                contextLength: 128_000,
                groupKey: "zeta",
                groupName: "Zeta",
                promptPrice: 0.00000125,
                completionPrice: 0.00000375,
                cacheReadInputPerMToken: 0.125,
                cacheCreationInputPerMToken: 1.5
            ),
            AIModel(
                id: "alpha-1",
                name: "Alpha",
                capabilities: [.text],
                reasoningModeAvailable: false,
                isAvailable: true,
                isDefault: false,
                priceTier: "",
                groupKey: "alpha",
                groupName: "Alpha"
            ),
        ]
        let provider = Provider(
            id: UUID(),
            kind: .openAI,
            status: .connected,
            models: models,
            catalogModels: models,
            lastCheckedAt: nil,
            apiKey: "",
            apiKeyPreview: ""
        )

        let groups = detailEnabledModelGroups(for: provider)
        #expect(groups.map(\.id) == ["zeta", "alpha"])
        #expect(groups.first?.models.map(\.id) == ["zeta-1"])

        let specificationIDs = providerModelSpecifications(for: models[0]).map(\.id)
        #expect(specificationIDs == ["context", "input", "output", "cache-read", "cache-write"])

        let modelWithoutCachePricing = AIModel(
            id: "sparse-1",
            name: "Sparse",
            capabilities: [.text],
            reasoningModeAvailable: false,
            isAvailable: true,
            isDefault: false,
            priceTier: "",
            contextLength: 128_000,
            promptPrice: 0.00000125,
            completionPrice: 0.00000375
        )
        #expect(providerModelSpecifications(for: modelWithoutCachePricing).map(\.id) == ["context", "input", "output"])
    }

    @Test("The edit-connection sheet draws its own header and protects against unsaved dismissal")
    func relayEditSheetUsesPremiumSettingsStructure() throws {
        let relayEditSource = try String(contentsOf: providerSourceURL("RelayEditView.swift"), encoding: .utf8)

        #expect(relayEditSource.contains(".interactiveDismissDisabled(shouldDisableInteractiveDismiss)"))
        #expect(relayEditSource.contains("private var shouldDisableInteractiveDismiss"))
        // The header is drawn by hand (close at top left, centered "Edit connection", connection name as subtitle)
        // instead of the system navigation bar.
        #expect(!relayEditSource.contains("NavigationStack"))
        #expect(!relayEditSource.contains(".toolbar"))
        #expect(relayEditSource.contains("L10n.tr(RelayEditBoardModel.titleKey, table: .providers)"))
        #expect(RelayEditBoardModel.titleKey == RelayDetailBoardModel.editConnectionKey, "The entry name and the destination page share one name")
    }

    private func providerSourceURL(_ filename: String) -> URL {
        let testDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let projectDirectory = testDirectory
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        return projectDirectory
            .appendingPathComponent("Oriveo")
            .appendingPathComponent("Features")
            .appendingPathComponent("Providers")
            .appendingPathComponent(filename)
    }
}

private extension String {
    func requiredSlice(from start: String, to end: String) throws -> String {
        guard let startRange = range(of: start),
              let endRange = range(of: end, range: startRange.upperBound..<endIndex) else {
            throw SliceError.missingBoundary
        }
        return String(self[startRange.lowerBound..<endRange.lowerBound])
    }
}

extension ProviderDetailVisualRefreshTests {
    @Test("The one-off notice after an unverified save: its title says the connection was not verified, not that no model catalog was obtained")
    func unverifiedSaveNoticeTitleSaysNotVerified() throws {
        #expect(ProviderDetailNotice.Kind.unverifiedSaveTitleKey == ProviderIssueMessage.unverifiedConnectionKey)
        #expect(ProviderDetailNotice.Kind.unverifiedSaveTitleKey == "Connection has not been verified.")
        let values = try ProductionSource.localizations(
            table: "Providers", key: ProviderDetailNotice.Kind.unverifiedSaveTitleKey
        )
        #expect(values.count == 16)

        let source = try ProductionSource.read("Features/Providers/ProviderDetailView.swift")
        #expect(source.contains("Text(ProviderIssueMessage.localized(ProviderDetailNotice.Kind.unverifiedSaveTitleKey))"))
        #expect(!source.contains("Saved without a model catalog"))
    }
}

private enum SliceError: Error {
    case missingBoundary
}
