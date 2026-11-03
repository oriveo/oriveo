import Foundation
import CoreGraphics
import SwiftUI
import Testing
@testable import Oriveo

@Suite("HomeModelPickerSheet", .sharedProcessState)
struct HomeModelPickerSheetTests {

    @Test("Add-model entry stays in the provider footer")
    func addModelEntryStaysInProviderFooter() throws {
        let source = try loadHomeModelPickerSheetSource()
        let searchSource = try source.requiredSlice(
            from: "private var searchBar",
            to: "private var flatListItems"
        )
        let listSource = try source.requiredSlice(
            from: "private var flatListItems",
            to: "private func flatListItemView"
        )
        let footerSource = try source.requiredSlice(
            from: "// MARK: - Add Models Row",
            to: "private func isExpanded"
        )

        #expect(!searchSource.contains("addModelButton"))
        #expect(listSource.contains("contents.append(.addModels(providerID: provider.id))"))
        #expect(footerSource.contains("catalogProviderID = providerID"))
    }

    @Test("Model picker model names may wrap and display in full")
    func modelPickerRowsAllowLongModelNamesToWrap() throws {
        let source = try loadHomeModelPickerSheetSource()
        let rowSource = try source.requiredSlice(
            from: "private struct ModelPickerRow",
            to: "// MARK: - Row Button Style"
        )
        let titleSource = try rowSource.requiredSlice(
            from: "Text(ModelIdentifierBreaks.displayTitle(title))",
            to: "rowMetadata"
        )

        #expect(titleSource.contains("Text(ModelIdentifierBreaks.displayTitle(title))"))
        #expect(!titleSource.contains(".lineLimit(1)"))
        #expect(titleSource.contains(".fixedSize(horizontal: false, vertical: true)"))
        #expect(titleSource.contains(".layoutPriority(1)"))
    }

    @Test("Model leaf rows never repeat the provider or vendor logo")
    func modelRowsNeverRepeatHierarchyLogos() throws {
        let source = try loadHomeModelPickerSheetSource()
        let rowSource = try source.requiredSlice(
            from: "private struct ModelPickerRow",
            to: "// MARK: - Row Button Style"
        )
        let flatItemSource = try source.requiredSlice(
            from: "struct ModelPickerFlatItem",
            to: "struct ModelPickerVendorGroup"
        )
        let official = makeProvider(
            name: "OpenAI",
            models: [
                makeModel(id: "gpt-5.4", name: "GPT-5.4", groupKey: "gpt", groupName: "GPT"),
                makeModel(id: "gpt-5.4-mini", name: "GPT-5.4 mini", groupKey: "gpt", groupName: "GPT"),
            ],
            kind: .openAI
        )
        let sections = buildModelPickerSections(
            context: .home, providers: [official],
            currentProviderID: nil, currentModel: nil, realtimeCatalog: Self.realtimeCatalog()
        )
        let section = try #require(sections.first { $0.id == official.id })
        #expect(section.models.count == 2)
        #expect(section.realtimeModels.count == 2)
        #expect(section.visibleRowCount == 4, "section header count includes realtime rows")

        let rowsSource = try loadHomeModelPickerSheetSource().requiredSlice(
            from: "private func flatListItemView",
            to: "private var emptyStateCard"
        )
        #expect(rowsSource.contains("modelCount: section.visibleRowCount"))
    }

    @MainActor
    @Test("After the realtime chip filter, the section header counts only realtime rows")
    func realtimeFilterHeaderCountsRealtimeRows() throws {
        let official = makeProvider(
            name: "OpenAI",
            models: [makeModel(id: "gpt-5.4", name: "GPT-5.4", groupKey: "gpt", groupName: "GPT")],
            kind: .openAI
        )
        let relay = makeProvider(
            name: "Relay",
            models: [makeModel(id: "gpt-5.4", name: "GPT-5.4", groupKey: "gpt", groupName: "GPT")]
        )
        let sections = buildModelPickerSections(
            context: .home, providers: [official, relay],
            currentProviderID: nil, currentModel: nil, realtimeCatalog: Self.realtimeCatalog()
        )
        let filtered = ModelPickerCapabilityFilter.apply(sections: sections, active: [.realtime])
        #expect(filtered.map(\.id) == [official.id])
        let section = try #require(filtered.first)
        #expect(section.models.isEmpty)
        #expect(section.visibleRowCount == 2, "with the realtime chip, header count = realtime row count")
        #expect(ModelPickerSection.visibleRowTotal(filtered) == 2)
    }

    @MainActor
    @Test("Home header \"M models\" = sum of section header counts after filter and search (text + realtime)")
    func homeHeaderTotalIncludesRealtimeRows() throws {
        let official = makeProvider(
            name: "OpenAI",
            models: [makeModel(id: "gpt-5.4", name: "GPT-5.4", groupKey: "gpt", groupName: "GPT")],
            kind: .openAI
        )
        let relay = makeProvider(
            name: "Relay",
            models: [
                makeModel(id: "gpt-5.4", name: "GPT-5.4", groupKey: "gpt", groupName: "GPT"),
                makeModel(id: "gpt-5.4-mini", name: "GPT-5.4 mini", groupKey: "gpt", groupName: "GPT"),
            ]
        )
        let sections = buildModelPickerSections(
            context: .home, providers: [official, relay],
            currentProviderID: nil, currentModel: nil, realtimeCatalog: Self.realtimeCatalog()
        )
        // 3 text + 2 realtime
        #expect(ModelPickerSection.visibleRowTotal(sections) == 5)
        #expect(ModelPickerSection.visibleRowTotal(sections) == sections.reduce(0) { $0 + $1.visibleRowCount })

        let statsSource = try loadHomeModelPickerSheetSource().requiredSlice(
            from: "private var homeStatsInline",
            to: "private func statBadge"
        )
        #expect(statsSource.contains("let sections = providerSections"), "total uses the rendered sections (after search, then filter)")
        #expect(statsSource.contains("let providerCount = sections.count"), "provider count = providerSections.count")
        #expect(statsSource.contains("ModelPickerSection.visibleRowTotal(sections)"))
        #expect(!statsSource.contains("baseSections"))
        #expect(!statsSource.contains("$1.models.count"))

        // After the realtime chip filter: the Relay section is removed, the provider count becomes 1, and only realtime rows remain as models
        let filtered = ModelPickerCapabilityFilter.apply(sections: sections, active: [.realtime])
        #expect(sections.count == 2)
        #expect(filtered.count == 1, "provider count after filtering = remaining section count")
        #expect(ModelPickerSection.visibleRowTotal(filtered) == 2)
    }

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

    @Test("Home/chat/crosscheck: tapping a text row selects it and dismisses the picker")
    func pickerDismissesAfterSelectingTextRow() throws {
        let source = try loadHomeModelPickerSheetSource()
        let selectionSource = try source.requiredSlice(
            from: "private func selectModel",
            to: "private func isModelSelected"
        )
        let dismissalSource = try source.requiredSlice(
            from: "private var dismissesAfterSelection",
            to: "private var telemetryContext"
        )

        #expect(selectionSource.contains("selectedProviderID = providerID"))
        #expect(selectionSource.contains("selectedModel = model"))
        #expect(selectionSource.contains("onSelect("))
        #expect(selectionSource.contains("if dismissesAfterSelection"))
        #expect(selectionSource.contains("dismiss()"))
        #expect(dismissalSource.contains("true"))
        #expect(!dismissalSource.contains("isCrosscheck"))
        #expect(!selectionSource.contains("appState"))
        #expect(!selectionSource.contains("Task.yield"))
    }

    @Test("Home/chat: tapping a realtime row selects it and dismisses the picker; the page still shows the disclosure after dismissal")
    func pickerDismissesAfterSelectingRealtimeRow() throws {
        let source = try loadHomeModelPickerSheetSource()
        let selectionSource = try source.requiredSlice(
            from: "private func selectRealtimeModel",
            to: "private func loadRealtimeCatalog"
        )

        #expect(selectionSource.contains("modelKind: .realtime"))
        #expect(selectionSource.contains("onSelect("))
        #expect(selectionSource.contains("if dismissesAfterSelection"))
        #expect(selectionSource.contains("dismiss()"))
        #expect(!selectionSource.contains("VoiceDisclosure"))
    }

    @Test("Crosscheck with only one provider still keeps the provider section header")
    func crosscheckKeepsSingleProviderHeader() throws {
        let source = try loadHomeModelPickerSheetSource()
        let policySource = try source.requiredSlice(
            from: "private var showsProviderHeaders",
            to: "private var chevronAnimation"
        )
        let listSource = try source.requiredSlice(
            from: "private var flatListItems",
            to: "private func flatListItemView"
        )

        #expect(policySource.contains("!isSingleProvider || isCrosscheck"))
        #expect(listSource.contains("let providerExpanded = !showsProviderHeaders || isExpanded"))
        #expect(listSource.contains("if showsProviderHeaders"))
        #expect(listSource.contains("providerHeader(section: section"))
    }

    @Test("First frame expands the current model directly, and grouping uses linear appends")
    func initialExpansionIsStableAndGroupingAvoidsArrayCopies() throws {
        let source = try loadHomeModelPickerSheetSource()
        let storeSource = try source.requiredSlice(
            from: "struct ModelPickerPresentationSnapshot",
            to: "func buildModelPickerSections"
        )
        let groupingSource = try source.requiredSlice(
            from: "func groupModelPickerModelsByVendor",
            to: "func defaultExpandedModelPickerVendorGroupIDs"
        )

        #expect(storeSource.contains("initialExpandedProviderIDs"))
        #expect(storeSource.contains("initialExpandedVendorGroupIDs"))
        #expect(storeSource.contains("defaultExpandedModelPickerVendorGroupIDs"))
        #expect(!source.contains("configureExpansionState"))
        #expect(groupingSource.contains("modelsByGroup[key, default: []].append(model)"))
        #expect(!groupingSource.contains("existing.models + [model]"))
    }

    @Test("Over-long backend price uses only the full-width fallback copy")
    func longServerPriceUsesFullWidthFallback() throws {
        let serverPrice = "$2.50 / 1M input · $15 / 1M output · $0.25 / 1M cache-read"
        let model = makeModel(
            id: "gpt-4.1",
            name: "A",
            groupKey: "openai",
            groupName: "OpenAI",
            priceTier: serverPrice
        )
        let pricing = ModelPickerPricePresentation(model: model)
        let source = try loadHomeModelPickerSheetSource()
        let rowSource = try source.requiredSlice(
            from: "private struct ModelPickerRow",
            to: "// MARK: - Row Button Style"
        )

        #expect(pricing.fallback == serverPrice)
        #expect(!rowSource.contains("modelPickerPriceColumnWidth"))
        #expect(rowSource.contains("ModelPickerPriceRow("))
        #expect(rowSource.contains("pricing: pricing,"))
        #expect(rowSource.contains("contextLengthLabel: contextLengthLabel"))
    }

    @Test("Model picker main list groups by vendor and keeps a single group flat")
    func modelPickerMainListRendersVendorGroups() throws {
        let source = try loadHomeModelPickerSheetSource()
        let listSource = try source.requiredSlice(
            from: "private var flatListItems",
            to: "private var emptyStateCard"
        )
        let contentSource = try source.requiredSlice(
            from: "private var content",
            to: "// MARK: - Home Header"
        )

        #expect(listSource.contains("groupModelPickerModelsByVendor"))
        #expect(listSource.contains("groups.count > 1"))
        #expect(contentSource.components(separatedBy: "LazyVStack").count - 1 == 1)
        #expect(contentSource.contains("LazyVStack(alignment: .leading, spacing: 0)"))
        #expect(contentSource.contains("item.beginsProvider ? 16 : 0"))
        #expect(!listSource.contains("LazyVStack"))
        #expect(source.contains("expandedVendorGroupIDs"))
    }

    @Test("Disclosure visual state does not trigger a spring on the whole catalog tree")
    func disclosureStylingKeepsStructureAnimationFree() throws {
        let source = try loadHomeModelPickerSheetSource()
        let providerSource = try source.requiredSlice(
            from: "private func providerSectionHeader",
            to: "// MARK: - Add Models Row"
        )
        let rowSource = try source.requiredSlice(
            from: "private struct ModelPickerRow",
            to: "// MARK: - Row Button Style"
        )
        let rowStyleSource = try source.requiredSlice(
            from: "private struct ModelPickerRowButtonStyle",
            to: "// MARK: - Section Model"
        )

        #expect(!providerSource.contains("withAnimation"))
        #expect(providerSource.contains("minHeight: 64"))
        #expect(providerSource.contains(".frame(width: 30, height: 30)"))
        #expect(!providerSource.contains("if isCurrent"))
        #expect(rowSource.contains(".opacity(model.isAvailable ? 1 : 0.68)"))
        #expect(rowSource.contains(".accessibilityAddTraits(isSelected ? .isSelected : [])"))
        #expect(rowStyleSource.contains("primary.opacity(0.08)"))
        #expect(!rowStyleSource.contains(".frame(width: 2, height: 28)"))
    }

    @Test("Provider cards stand out via the group background, not a stroke")
    func providerCardsRelyOnGroupedBackgroundInsteadOfBorders() throws {
        let source = try loadHomeModelPickerSheetSource()
        let sheetSource = try source.requiredSlice(
            from: "struct ModelPickerSheet: View",
            to: "private struct ModelPickerVendorGroupHeader"
        )

        // White cards have under 2% contrast against the near-white OriveoV2ScreenBackground, so the groups originally needed a stroke.
        // With the background darkened, all strokes were removed; restoring any one of them brings the border back.
        #expect(!sheetSource.contains(".stroke("))
        #expect(sheetSource.contains("ModelPickerGroupedBackground()"))
        #expect(!sheetSource.contains("OriveoV2ScreenBackground()"))
    }

    @Test("Vendor groups keep their order and the current model group is expanded by default")
    func vendorGroupingAndExpansionRules() {
        let models = [
            makeModel(id: "gpt-4.1", name: "GPT-4.1", groupKey: "openai", groupName: "OpenAI"),
            makeModel(id: "claude-sonnet", name: "Claude Sonnet", groupKey: "anthropic", groupName: "Anthropic"),
            makeModel(id: "gpt-4o", name: "GPT-4o", groupKey: "openai", groupName: "OpenAI"),
        ]

        let groups = groupModelPickerModelsByVendor(models)

        #expect(groups.map(\.id) == ["openai", "anthropic"])
        #expect(groups[0].models.map(\.id) == ["gpt-4.1", "gpt-4o"])
        #expect(
            defaultExpandedModelPickerVendorGroupIDs(
                groups: groups,
                selectedModelID: "claude-sonnet",
                searchText: ""
            ) == ["anthropic"]
        )
        #expect(
            defaultExpandedModelPickerVendorGroupIDs(
                groups: groups,
                selectedModelID: nil,
                searchText: "claude"
            ) == Set(groups.map(\.id))
        )
    }

    @Test("Unselected model rows do not render an empty circle")
    func unselectedModelRowsDoNotRenderEmptyCircles() throws {
        let source = try loadHomeModelPickerSheetSource()
        let rowSource = try source.requiredSlice(
            from: "private struct ModelPickerRow",
            to: "// MARK: - Row Button Style"
        )

        #expect(rowSource.contains("checkmark.circle.fill"))
        #expect(!rowSource.contains("\"circle\""))
    }

    @Test("The selected icon uses a fixed slot vertically centered across the row")
    func selectedIconUsesVerticallyCenteredFixedSlot() throws {
        let source = try loadHomeModelPickerSheetSource()
        let rowSource = try source.requiredSlice(
            from: "private struct ModelPickerRow",
            to: "// MARK: - Row Button Style"
        )

        #expect(rowSource.contains("HStack(alignment: .center, spacing: 8)"))
        #expect(rowSource.contains(".frame(width: 18, height: 18)"))
        #expect(!rowSource.contains("HStack(alignment: .firstTextBaseline"))
    }

    @Test("Model titles strip only the current vendor prefix")
    func modelPickerTitleOnlyStripsCurrentVendorPrefix() throws {
        let source = try loadHomeModelPickerSheetSource()
        let titleSource = try source.requiredSlice(
            from: "var modelPickerDisplayTitle",
            to: "return title.isEmpty ? name : title"
        )

        #expect(titleSource.contains("groupName"))
        #expect(titleSource.contains("hasPrefix"))
        #expect(!titleSource.contains("title.range(of: \": \")"))
    }

    @Test("Chat model-switch header: the current model takes at most two lines")
    func chatHeaderCurrentModelUsesTwoLines() throws {
        let source = try loadHomeModelPickerSheetSource()
        let contentSource = try source.requiredSlice(
            from: "private var content",
            to: "// MARK: - Home Header"
        )
        let headerSource = try source.requiredSlice(
            from: "private var chatHeader",
            to: "// MARK: - Search Bar"
        )

        #expect(headerSource.contains("Current: %@ · %@"))
        #expect(headerSource.contains(".lineLimit(2)"))
        #expect(headerSource.contains(".fixedSize(horizontal: false, vertical: true)"))
        // The two paths without a navigation bar (chat / crosscheck) must leave room for the grabber at the top: 22 + the header's own 2 = 24.
        #expect(contentSource.contains(".padding(.top, isHome ? 4 : 22)"))
    }

    // MARK: - Realtime voice rows

    @MainActor
    @Test("Realtime rows: chat / home list a provider's realtime models after its text rows for official apiKey connections, with isDefault first; each connection of the same provider is listed; relay / managed / subscription are not listed")
    func realtimeRowsFollowOfficialAPIKeyConnections() {
        let catalog = Self.realtimeCatalog()
        let openA = makeProvider(
            name: "OpenAI A",
            models: [makeModel(id: "gpt-5.4", name: "GPT-5.4", groupKey: "gpt", groupName: "GPT")],
            kind: .openAI
        )
        let openB = makeProvider(
            name: "OpenAI B",
            models: [makeModel(id: "gpt-5.4-mini", name: "GPT-5.4 mini", groupKey: "gpt", groupName: "GPT")],
            kind: .openAI
        )
        var subscription = makeProvider(
            name: "OpenAI Plus",
            models: [makeModel(id: "gpt-5.4", name: "GPT-5.4", groupKey: "gpt", groupName: "GPT")],
            kind: .openAI
        )
        subscription.authMode = .subscription
        let relay = makeProvider(
            name: "Relay",
            models: [makeModel(id: "gpt-5.4", name: "GPT-5.4", groupKey: "gpt", groupName: "GPT")]
        )
        let providers = [openA, openB, subscription, relay]

        for context in [ModelPickerContext.home, .chat(conversationID: nil)] {
            let sections = buildModelPickerSections(
                context: context, providers: providers,
                currentProviderID: nil, currentModel: nil,
                realtimeCatalog: catalog
            )
            func section(_ provider: Provider) -> ModelPickerSection? {
                sections.first { $0.id == provider.id }
            }
            // Catalog order puts mini first; isDefault gpt-realtime moves to the front, the rest keep catalog order
            #expect(section(openA)?.realtimeModels == ["gpt-realtime", "gpt-realtime-mini"])
            #expect(section(openB)?.realtimeModels == ["gpt-realtime", "gpt-realtime-mini"], "the second connection of the same provider is also listed")
            #expect(section(subscription)?.realtimeModels == [], "subscription login is not an official apiKey")
            #expect(section(relay)?.realtimeModels == [], "a relay is not listed even when its catalog has entries")
            // Text rows are unaffected
            #expect(section(openA)?.models.map(\.id) == ["gpt-5.4"])
            #expect(ModelPickerCapabilityFilter.showsRealtimeFilter(sections: sections))
        }
    }

    @MainActor
    @Test("Realtime rows: crosscheck does not list them; without a realtime catalog or an official apiKey connection no realtime chip appears; the selection callback defaults to a text model")
    func realtimeRowsSkipCrosscheckAndHideChipWithoutRows() throws {
        let catalog = Self.realtimeCatalog()
        let official = makeProvider(
            name: "OpenAI",
            models: [makeModel(id: "gpt-5.4", name: "GPT-5.4", groupKey: "gpt", groupName: "GPT")],
            kind: .openAI
        )
        let relay = makeProvider(
            name: "Relay",
            models: [makeModel(id: "gpt-5.4", name: "GPT-5.4", groupKey: "gpt", groupName: "GPT")]
        )

        let crosscheck = buildModelPickerSections(
            context: .crosscheck, providers: [official, relay],
            currentProviderID: nil, currentModel: nil, realtimeCatalog: catalog
        )
        let crosscheckIDs = Set(crosscheck.map(\.id))
        #expect(crosscheckIDs == Set([official.id, relay.id]))
        #expect(crosscheck.allSatisfy { $0.realtimeModels.isEmpty })
        #expect(!ModelPickerCapabilityFilter.showsRealtimeFilter(sections: crosscheck))

        let noCatalog = buildModelPickerSections(
            context: .home, providers: [official], currentProviderID: nil, currentModel: nil
        )
        #expect(noCatalog.allSatisfy { $0.realtimeModels.isEmpty })
        #expect(!ModelPickerCapabilityFilter.showsRealtimeFilter(sections: noCatalog))

        let relayOnly = buildModelPickerSections(
            context: .chat(conversationID: nil), providers: [relay],
            currentProviderID: nil, currentModel: nil, realtimeCatalog: catalog
        )
        #expect(!ModelPickerCapabilityFilter.showsRealtimeFilter(sections: relayOnly))

        let selection = ModelPickerSelection(providerID: official.id, modelID: "gpt-5.4", context: .home)
        #expect(selection.modelKind == .text)

        // In the list, realtime rows follow that connection's text rows and come before "Add Models"
        let listSource = try loadHomeModelPickerSheetSource().requiredSlice(
            from: "private var flatListItems",
            to: "private func flatListItemView"
        )
        let textRows = try #require(listSource.range(of: ".model(provider: provider, model: $0, isNestedUnderVendor: false)"))
        let realtimeRows = try #require(listSource.range(of: ".realtimeModel(provider: provider, model: $0)"))
        let addModels = try #require(listSource.range(of: "contents.append(.addModels(providerID: provider.id))"))
        #expect(textRows.upperBound <= realtimeRows.lowerBound)
        #expect(realtimeRows.upperBound <= addModels.lowerBound)
    }

    @MainActor
    @Test("Section header count = the section's text rows + realtime rows (production-built sections); the list header uses the same basis")
    func providerHeaderCountIncludesRealtimeRows() throws {
        let official = makeProvider(
            name: "OpenAI",
            models: [
                makeModel(id: "gpt-5.4", name: "GPT-5.4", groupKey: "gpt", groupName: "GPT"),
                makeModel(id: "gpt-5.4-mini", name: "GPT-5.4 mini", groupKey: "gpt", groupName: "GPT"),
            ],
            kind: .openAI
        )
        let sections = buildModelPickerSections(
            context: .home, providers: [official],
            currentProviderID: nil, currentModel: nil, realtimeCatalog: Self.realtimeCatalog()
        )
        let section = try #require(sections.first { $0.id == official.id })
        #expect(section.models.count == 2)
        #expect(section.realtimeModels.count == 2)
        #expect(section.visibleRowCount == 4, "section header count includes realtime rows")

        let rowsSource = try loadHomeModelPickerSheetSource().requiredSlice(
            from: "private func flatListItemView",
            to: "private var emptyStateCard"
        )
        #expect(rowsSource.contains("modelCount: section.visibleRowCount"))
    }

    @MainActor
    @Test("Realtime row on first frame: when the snapshot is given the cached catalog, the first sections build already includes realtime rows; the sheet starts its State from the snapshot catalog")
    func realtimeRowsPresentInFirstSnapshotWhenCatalogCached() throws {
        let catalog = Self.realtimeCatalog()
        let official = makeProvider(
            name: "OpenAI",
            models: [makeModel(id: "gpt-5.4", name: "GPT-5.4", groupKey: "gpt", groupName: "GPT")],
            kind: .openAI
        )

        for context in [ModelPickerContext.home, .chat(conversationID: nil)] {
            let snapshot = ModelPickerPresentationSnapshot(
                context: context,
                providers: [official],
                providersVersion: 1,
                currentProviderID: official.id,
                currentModel: official.models.first,
                realtimeCatalog: catalog
            )
            #expect(snapshot.sections.first { $0.id == official.id }?.realtimeModels == ["gpt-realtime", "gpt-realtime-mini"])
            #expect(snapshot.realtimeCatalog == catalog)
        }

        let uncached = ModelPickerPresentationSnapshot(
            context: .home, providers: [official], providersVersion: 1,
            currentProviderID: official.id, currentModel: official.models.first
        )
        #expect(uncached.sections.allSatisfy { $0.realtimeModels.isEmpty })
        #expect(uncached.realtimeCatalog == nil)

        let sheetSource = try loadHomeModelPickerSheetSource()
        #expect(sheetSource.contains("_realtimeCatalog = State(initialValue: presentation.realtimeCatalog)"))
    }

    @MainActor
    @Test("Realtime reopen selection: only the realtime row for the selected model is checked, the last-used text row is not; when the selected item is not listed nothing is checked; home and session page pass the realtime selection on open")
    func realtimeSelectionChecksOnlyRealtimeRowOnReopen() throws {
        let catalog = Self.realtimeCatalog()
        let official = makeProvider(
            name: "OpenAI",
            models: [makeModel(id: "gpt-5.4", name: "GPT-5.4", groupKey: "gpt", groupName: "GPT")],
            kind: .openAI
        )
        let lastUsed = try #require(official.models.first)

        for context in [ModelPickerContext.home, .chat(conversationID: nil)] {
            let selection = RealtimeModelSelection(providerID: official.id, providerKind: .openAI, model: "gpt-realtime-mini")
            let snapshot = ModelPickerPresentationSnapshot(
                context: context, providers: [official], providersVersion: 1,
                currentProviderID: official.id, currentModel: lastUsed,
                realtimeCatalog: catalog, realtimeSelection: selection
            )
            #expect(snapshot.selectedRealtimeRow == ModelPickerRowID(providerID: official.id, modelID: "gpt-realtime-mini"))
            #expect(snapshot.realtimeSelection == selection)
            #expect(!modelPickerIsTextRowSelected(
                isRealtimeSelected: snapshot.realtimeSelection != nil,
                currentProviderID: snapshot.selectedProviderID, currentModelID: snapshot.selectedModel?.id,
                providerID: official.id, modelID: lastUsed.id
            ), "last-used text row is not checked when a realtime selection is active")

            // Selected item not listed (the catalog no longer lists that model): realtime row not checked, text row not checked either
            let missing = RealtimeModelSelection(providerID: official.id, providerKind: .openAI, model: "gpt-realtime-retired")
            let filtered = ModelPickerPresentationSnapshot(
                context: context, providers: [official], providersVersion: 1,
                currentProviderID: official.id, currentModel: lastUsed,
                realtimeCatalog: catalog, realtimeSelection: missing
            )
            #expect(filtered.selectedRealtimeRow == nil)
            #expect(!modelPickerIsTextRowSelected(
                isRealtimeSelected: filtered.realtimeSelection != nil,
                currentProviderID: filtered.selectedProviderID, currentModelID: filtered.selectedModel?.id,
                providerID: official.id, modelID: lastUsed.id
            ))

            // No realtime selection -> check the last-used text row as before
            let textOnly = ModelPickerPresentationSnapshot(
                context: context, providers: [official], providersVersion: 1,
                currentProviderID: official.id, currentModel: lastUsed, realtimeCatalog: catalog
            )
            #expect(textOnly.selectedRealtimeRow == nil)
            #expect(modelPickerIsTextRowSelected(
                isRealtimeSelected: textOnly.realtimeSelection != nil,
                currentProviderID: textOnly.selectedProviderID, currentModelID: textOnly.selectedModel?.id,
                providerID: official.id, modelID: lastUsed.id
            ))
        }

        let sheetSource = try loadHomeModelPickerSheetSource()
        #expect(sheetSource.contains("_selectedRealtimeRow = State(initialValue: presentation.selectedRealtimeRow)"))
        #expect(sheetSource.contains("_isRealtimeSelected = State(initialValue: presentation.realtimeSelection != nil)"))
    }

    @Test("Realtime row per design spec §8: 64 pt row height, 36 pt gradient tile, \"Realtime voice\" subtitle, same checkmark as text rows")
    func realtimeRowLayoutMatchesSpec() throws {
        let source = try loadHomeModelPickerSheetSource()
        let rowSource = try source.requiredSlice(
            from: "private struct ModelPickerRealtimeRow",
            to: "// MARK: - Section Model"
        )
        #expect(rowSource.contains(".frame(maxWidth: .infinity, minHeight: 64)"))
        // Left tile: 36 pt, corner radius 10, gradient only via theme tokens
        #expect(rowSource.contains("RoundedRectangle(cornerRadius: 10, style: .continuous)"))
        #expect(rowSource.contains(".fill(OriveoTheme.V2.Colors.realtimeBadgeGradient)"))
        #expect(rowSource.contains(".frame(width: 36, height: 36)"))
        #expect(rowSource.contains("Image(systemName: \"waveform\")"))
        #expect(rowSource.contains(".font(.system(size: 20, weight: .semibold))"))
        // Middle two lines: model name 16 semibold, subtitle 13 secondary color = "Realtime voice"
        #expect(rowSource.contains(".font(.system(size: 16, weight: .semibold))"))
        // Subtitle is a single key; no tag is concatenated
        #expect(rowSource.contains("Text(L10n.tr(\"Realtime voice · Interrupt anytime\", table: .voice))"))
        #expect(!rowSource.contains("\"Realtime Voice\""))
        #expect(rowSource.contains(".foregroundStyle(OriveoTheme.V2.Colors.textSecondary)"))
        // Trailing checkmark: same checkmark.circle.fill primary color as text rows (replaces the 24 pt brand gradient circle)
        #expect(rowSource.contains("Image(systemName: \"checkmark.circle.fill\")"))
        #expect(!rowSource.contains(".fill(OriveoTheme.Palette.primaryGradient)"))
        // Selected background reuses the row style (brand color at alpha 0.08); no badge is attached inside the row, and no color is hard-coded
        #expect(rowSource.contains(".buttonStyle(ModelPickerRowButtonStyle(isSelected: isSelected))"))
        #expect(!rowSource.contains("ModelPickerRealtimeBadge"))
        #expect(!source.contains("private struct ModelPickerRealtimeBadge"))
        #expect(!rowSource.contains("Color(hex:"))
    }

    @Test("Realtime row selection marker matches text rows: checkmark.circle.fill 17 pt primary color, 18 pt slot, no gradient circle")
    func realtimeRowUsesTextRowCheckmark() throws {
        let source = try loadHomeModelPickerSheetSource()
        let textRow = try source.requiredSlice(
            from: "private struct ModelPickerRow",
            to: "// MARK: - Row Button Style"
        )
        let realtimeRow = try source.requiredSlice(
            from: "private struct ModelPickerRealtimeRow",
            to: "// MARK: - Section Model"
        )
        for line in [
            "Image(systemName: \"checkmark.circle.fill\")",
            ".font(.system(size: 17, weight: .semibold))",
            ".foregroundStyle(OriveoTheme.V2.Colors.primary)",
        ] {
            #expect(textRow.contains(line), "\(line)")
            #expect(realtimeRow.contains(line), "\(line)")
        }
        #expect(realtimeRow.contains(".frame(width: 18, height: 18)"))
        #expect(!realtimeRow.contains("OriveoTheme.Palette.primaryGradient"))
        #expect(!realtimeRow.contains(".frame(width: 24, height: 24)"))
    }

    @Test("Realtime row title wraps to at most two lines without truncation; minimum row height 64")
    func realtimeRowTitleWrapsToTwoLines() throws {
        let source = try loadHomeModelPickerSheetSource()
        let realtimeRow = try source.requiredSlice(
            from: "private struct ModelPickerRealtimeRow",
            to: "// MARK: - Section Model"
        )
        let title = try realtimeRow.requiredSlice(
            from: "Text(ModelIdentifierBreaks.displayTitle(model))",
            to: "Text(L10n.tr(\"Realtime voice · Interrupt anytime\", table: .voice))"
        )
        #expect(title.contains(".lineLimit(2)"))
        #expect(!title.contains(".lineLimit(1)"))
        #expect(!title.contains("truncationMode"))
        #expect(realtimeRow.contains(".frame(maxWidth: .infinity, minHeight: 64)"))
    }

    /// Two OpenAI realtime models (catalog order puts mini first, gpt-realtime is the default); relay and managed also get entries, proving that exclusion depends on the auth shape.
    private static func realtimeCatalog() -> VoiceCatalog {
        func entry(_ model: String, isDefault: Bool) -> VoiceRealtimeEntry {
            VoiceRealtimeEntry(
                model: model,
                transport: .openaiRealtime,
                path: "/v1/realtime",
                contextWindow: 128_000,
                voices: [VoiceCatalogVoice(id: "marin", isDefault: true)],
                maxSessionSec: nil,
                inputTranscriptionModel: "gpt-4o-mini-transcribe",
                isDefault: isDefault
            )
        }
        let openAI = [entry("gpt-realtime-mini", isDefault: false), entry("gpt-realtime", isDefault: true)]
        return VoiceCatalog(schemaVersion: 2, revision: "picker", providers: [
            .openAI: VoiceProviderEntries(realtime: openAI),
            .relay: VoiceProviderEntries(realtime: openAI),
        ])
    }

    private func loadHomeModelPickerSheetSource() throws -> String {
        try loadFeatureSource(folder: "Home", file: "HomeModelPickerSheet.swift")
    }

    private func loadFeatureSource(folder: String, file: String) throws -> String {
        let testFile = URL(fileURLWithPath: #filePath)
        let projectRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let sourceURL = projectRoot
            .appendingPathComponent("Oriveo")
            .appendingPathComponent("Features")
            .appendingPathComponent(folder)
            .appendingPathComponent(file)

        return try String(contentsOf: sourceURL, encoding: .utf8)
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

private enum HomeModelPickerSheetSliceError: Error {
    case missingBoundary
}

private extension String {
    func requiredSlice(from start: String, to end: String) throws -> String {
        guard let startRange = range(of: start),
              let endRange = range(of: end, range: startRange.upperBound..<endIndex) else {
            throw HomeModelPickerSheetSliceError.missingBoundary
        }
        return String(self[startRange.lowerBound..<endRange.lowerBound])
    }
}
