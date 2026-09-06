import Combine
import Foundation
import SwiftUI

// MARK: - Context

enum ModelPickerContext {
    case home
    case chat(conversationID: UUID?)
    case crosscheck
}

private struct CapabilityCountKey: Equatable {
    let query: String
    let revision: UInt64
}

struct ModelPickerSelection {
    let providerID: UUID
    let modelID: String
    let context: ModelPickerContext
}

struct ModelPickerPresentationSnapshot: Identifiable {
    let id = UUID()
    let sections: [ModelPickerSection]
    let providersVersion: UInt
    let selectedProviderID: UUID?
    let selectedModel: AIModel?
    let initialExpandedProviderIDs: Set<UUID>
    let initialExpandedVendorGroupIDs: [UUID: Set<String>]

    @MainActor
    init(
        context: ModelPickerContext,
        providers: [Provider],
        providersVersion: UInt,
        currentProviderID: UUID?,
        currentModel: AIModel?
    ) {
        let sections = buildModelPickerSections(
            context: context,
            providers: providers,
            currentProviderID: currentProviderID,
            currentModel: currentModel
        )
        self.providersVersion = providersVersion
        selectedProviderID = currentProviderID
        selectedModel = currentModel
        self.sections = sections
        initialExpandedProviderIDs = defaultExpandedModelPickerProviderIDs(
            sections.map(\.provider),
            selectedProviderID: currentProviderID
        )

        initialExpandedVendorGroupIDs = [:]
    }
}

// MARK: - Grouped Surface

private let modelPickerCardRadius: CGFloat = 16

private struct ModelPickerGroupedBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            if colorScheme == .dark {
                OriveoV2ScreenBackground()
            } else {
                LinearGradient(
                    colors: [Color(hex: 0xF3F1F9), Color(hex: 0xEEECF6)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()
            }
        }
    }
}

// MARK: - Model Picker Sheet

struct ModelPickerSheet: View {
    let context: ModelPickerContext
    let presentation: ModelPickerPresentationSnapshot
    let onSelect: (ModelPickerSelection) -> Void

    @Environment(AppState.self) private var appState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dismiss) private var dismiss

    @State private var appeared = false
    @State private var searchText = ""
    @State private var searchQuery = ""
    @State private var expandedProviderIDs: Set<UUID>
    @State private var expandedVendorGroupIDs: [UUID: Set<String>]
    @State private var catalogProviderID: UUID?
    @State private var selectionFeedbackTick = 0
    @State private var toggleFeedbackTick = 0
    @State private var selectedProviderID: UUID?
    @State private var selectedModel: AIModel?
    @State private var refreshedSections: [ModelPickerSection]?
    @State private var activeCapabilityFilters: Set<ModelPickerCapabilityFilter.Capability> = []
    @State private var capabilityCounts: [ModelPickerCapabilityFilter.Capability: Int] = [:]
    @State private var searchHaystacks: [String: String] = [:]

    init(
        context: ModelPickerContext,
        presentation: ModelPickerPresentationSnapshot,
        onSelect: @escaping (ModelPickerSelection) -> Void
    ) {
        self.context = context
        self.presentation = presentation
        self.onSelect = onSelect
        _expandedProviderIDs = State(initialValue: presentation.initialExpandedProviderIDs)
        _expandedVendorGroupIDs = State(initialValue: presentation.initialExpandedVendorGroupIDs)
        _selectedProviderID = State(initialValue: presentation.selectedProviderID)
        _selectedModel = State(initialValue: presentation.selectedModel)
    }

    // MARK: - Computed properties

    private var isHome: Bool {
        if case .home = context { return true }
        return false
    }

    private var isCrosscheck: Bool {
        if case .crosscheck = context { return true }
        return false
    }

    private var allowsCatalogEditing: Bool {
        !isCrosscheck
    }

    private var dismissesAfterSelection: Bool {
        isCrosscheck
    }

    private var currentProviderID: UUID? {
        selectedProviderID
    }

    private var currentModel: AIModel? {
        selectedModel
    }

    private var currentProvider: Provider? {
        guard let currentProviderID else { return nil }
        return baseSections.first(where: { $0.provider.id == currentProviderID })?.provider
    }

    private var baseSections: [ModelPickerSection] {
        refreshedSections ?? presentation.sections
    }

    private var searchedSections: [ModelPickerSection] {
        let base = baseSections
        let query = searchQuery
        guard !query.isEmpty else { return base }

        let needle = query.lowercased()
        let haystacks = searchHaystacks
        return base.compactMap { section in
            let provider = section.provider
            let models = section.models.filter { model in
                if let haystack = haystacks[Self.searchHaystackKey(providerID: provider.id, modelID: model.id)] {
                    return haystack.contains(needle)
                }
                return model.name.localizedCaseInsensitiveContains(query) ||
                    model.id.localizedCaseInsensitiveContains(query) ||
                    (model.groupName?.localizedCaseInsensitiveContains(query) ?? false) ||
                    (model.groupKey?.localizedCaseInsensitiveContains(query) ?? false) ||
                    provider.displayName.localizedCaseInsensitiveContains(query) ||
                    (model.summary?.localizedCaseInsensitiveContains(query) ?? false)
            }
            guard shouldRenderModelPickerProviderSection(provider: provider, query: query, models: models) else {
                return nil
            }
            return ModelPickerSection(provider: provider, models: models)
        }
    }

    private var providerSections: [ModelPickerSection] {
        ModelPickerCapabilityFilter.apply(
            sections: searchedSections, active: activeCapabilityFilters
        )
    }

    private var isSingleProvider: Bool {
        baseSections.count == 1
    }

    private var showsProviderHeaders: Bool {
        !isSingleProvider || isCrosscheck
    }

    private var chevronAnimation: Animation? {
        reduceMotion ? nil : .easeOut(duration: 0.16)
    }

    // MARK: - Selection

    private func selectModel(_ model: AIModel, providerID: UUID) {
        selectionFeedbackTick &+= 1
        selectedProviderID = providerID
        selectedModel = model
        onSelect(ModelPickerSelection(providerID: providerID, modelID: model.id, context: context))
        if dismissesAfterSelection {
            dismiss()
        }
    }

    private func isModelSelected(_ model: AIModel, providerID: UUID) -> Bool {
        return currentProviderID == providerID && currentModel?.id == model.id
    }

    // MARK: - Catalog Refresh

    private func refreshSectionsAfterCatalogReturn() {
        let rebuilt = buildModelPickerSections(
            context: context,
            providers: appState.providers,
            currentProviderID: selectedProviderID,
            currentModel: selectedModel
        )
        var remaining = Dictionary(rebuilt.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var ordered: [ModelPickerSection] = []
        ordered.reserveCapacity(rebuilt.count)
        for section in baseSections {
            if let updated = remaining.removeValue(forKey: section.id) {
                ordered.append(updated)
            }
        }
        ordered.append(contentsOf: rebuilt.filter { remaining[$0.id] != nil })

        guard catalogSignature(ordered) != catalogSignature(baseSections) else { return }
        refreshedSections = ordered
        searchHaystacks = Self.buildSearchHaystacks(ordered)
    }

    static func searchHaystackKey(providerID: UUID, modelID: String) -> String {
        "\(providerID.uuidString)/\(modelID)"
    }

    static func buildSearchHaystacks(_ sections: [ModelPickerSection]) -> [String: String] {
        var result: [String: String] = [:]
        for section in sections {
            let providerName = section.provider.displayName.lowercased()
            for model in section.models {
                var fields = [model.name, model.id]
                if let groupName = model.groupName { fields.append(groupName) }
                if let groupKey = model.groupKey { fields.append(groupKey) }
                fields.append(providerName)
                if let summary = model.summary { fields.append(summary) }
                result[searchHaystackKey(providerID: section.provider.id, modelID: model.id)] =
                    fields.joined(separator: "\n").lowercased()
            }
        }
        return result
    }

    private func catalogSignature(_ sections: [ModelPickerSection]) -> [String] {
        sections.flatMap { section in
            [section.provider.id.uuidString] + section.models.map(\.id)
        }
    }

    // MARK: - Body

    private var capabilityEvidenceRevision: UInt64 {
        CapabilityEvidenceObservationBridge.shared.contentRevision
    }

    var body: some View {
        NavigationStack {
            content
                .background(ModelPickerGroupedBackground())
                .navigationBarTitleDisplayMode(.inline)
                .navigationTitle("")
                .toolbarVisibility(isHome ? .automatic : .hidden, for: .navigationBar)
                .toolbar {
                    if isHome {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(L10n.tr("Cancel")) { dismiss() }
                        }
                    }
                }
                .navigationDestination(item: $catalogProviderID) { providerID in
                    InlineModelCatalogView(providerID: providerID)
                }
                .onChange(of: catalogProviderID) { previous, current in
                    guard previous != nil, current == nil else { return }
                    refreshSectionsAfterCatalogReturn()
                }
                .sensoryFeedback(.selection, trigger: selectionFeedbackTick)
                .sensoryFeedback(.impact(weight: .light), trigger: toggleFeedbackTick)
                .onAppear {
                    if searchHaystacks.isEmpty {
                        searchHaystacks = Self.buildSearchHaystacks(baseSections)
                    }
                    if !appeared {
                        appeared = true
                    }
                }
                .task(id: searchText) {
                    if !searchText.isEmpty {
                        try? await Task.sleep(for: .milliseconds(120))
                        guard !Task.isCancelled else { return }
                    }
                    searchQuery = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                .task(id: CapabilityCountKey(query: searchQuery, revision: capabilityEvidenceRevision)) {
                    capabilityCounts = ModelPickerCapabilityFilter.counts(sections: searchedSections)
                }

        }
    }

    // MARK: - Content

    private var content: some View {
        ScrollView {
            let items = flatListItems
            LazyVStack(alignment: .leading, spacing: 0) {
                Group {
                    if isHome {
                        homeHeader
                    } else if isCrosscheck {
                        crosscheckHeader
                    } else {
                        chatHeader
                    }
                }
                .padding(.bottom, 16)

                searchBar
                    .padding(.bottom, 10)

                capabilityFilterChips
                    .padding(.bottom, 16)

                if items.isEmpty {
                    emptyStateCard
                        .padding(.top, 4)
                } else {
                    ForEach(items) { item in
                        flatListItemView(item)
                            .padding(.top, item.id == items.first?.id ? 0 : (item.beginsProvider ? 16 : 0))
                    }
                }
            }
            .scrollTargetLayout()
            .padding(.horizontal, 20)
            .padding(.top, isHome ? 4 : 22)
            .padding(.bottom, 28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollDismissesKeyboard(.interactively)
    }


    private var homeHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(L10n.tr("Choose Model"))
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(OriveoTheme.V2.Colors.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)

            Spacer(minLength: 8)

            if !baseSections.isEmpty {
                homeStatsInline
            }
        }
    }

    private var homeStatsInline: some View {
        let sections = baseSections
        let providerCount = sections.count
        let modelCount = sections.reduce(0) { $0 + $1.models.count }
        return HStack(spacing: 8) {
            statBadge(
                systemName: "square.grid.2x2.fill",
                text: String(format: L10n.tr("%lld providers"), providerCount)
            )

            Circle()
                .fill(OriveoTheme.V2.Colors.textTertiary.opacity(0.35))
                .frame(width: 3, height: 3)

            statBadge(
                systemName: "sparkles",
                text: String(format: L10n.tr("%lld models"), modelCount)
            )
        }
    }

    @ViewBuilder
    private func statBadge(systemName: String, text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(OriveoTheme.V2.Colors.primary)
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(OriveoTheme.V2.Colors.textSecondary)
                .monospacedDigit()
                .lineLimit(1)
        }
        .fixedSize()
    }

    // MARK: - Chat Header

    private var chatHeader: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.tr("Switch Model"))
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(OriveoTheme.V2.Colors.textPrimary)

                if let modelName = currentModel?.name, let providerName = currentProvider?.displayName {
                    Text(String(format: L10n.tr("Current: %@ • %@", table: .home), modelName, providerName))
                        .font(.system(size: 13))
                        .foregroundStyle(OriveoTheme.V2.Colors.textSecondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(L10n.tr("Change the model for the next turn while preserving this conversation.", table: .home))
                        .font(.system(size: 13))
                        .foregroundStyle(OriveoTheme.V2.Colors.textSecondary)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 8)

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(OriveoTheme.V2.Colors.textSecondary)
                    .frame(width: 30, height: 30)
                    .background(
                        Circle().fill(OriveoTheme.V2.Colors.surfaceDefault)
                    )
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.tr("Cancel"))
        }
        .padding(.top, 2)
    }

    private var crosscheckHeader: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.tr("Second model", table: .notes))
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(OriveoTheme.V2.Colors.textPrimary)

                Text(L10n.tr("Pick one model for this cross-check only.", table: .notes))
                    .font(.system(size: 13))
                    .foregroundStyle(OriveoTheme.V2.Colors.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(OriveoTheme.V2.Colors.textSecondary)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(OriveoTheme.V2.Colors.surfaceDefault))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.tr("Close", table: .notes))
        }
        .padding(.top, 2)
    }

    // MARK: - Search Bar

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(OriveoTheme.V2.Colors.textTertiary)

            TextField(L10n.tr("Search models..."), text: $searchText)
                .font(.system(size: 15))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.done)

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                    searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(OriveoTheme.V2.Colors.textTertiary)
                }
                .buttonStyle(.plain)
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(
            Capsule(style: .continuous).fill(OriveoTheme.V2.Colors.surfaceDefault)
        )
        .animation(.easeInOut(duration: 0.18), value: searchText.isEmpty)
    }


    private var capabilityFilterChips: some View {
        HStack(spacing: 8) {
            ForEach(ModelPickerCapabilityFilter.Capability.allCases) { capability in
                let isActive = activeCapabilityFilters.contains(capability)
                let count = capabilityCounts[capability]
                Button {
                    toggleFeedbackTick += 1
                    if isActive {
                        activeCapabilityFilters.remove(capability)
                    } else {
                        activeCapabilityFilters.insert(capability)
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: capability.symbolName)
                            .font(.system(size: 11, weight: .semibold))
                        Text(capability.chipTitle)
                            .font(.system(size: 13, weight: .medium))
                        if let count {
                            Text("\(count)")
                                .font(.system(size: 13, weight: .semibold))
                                .monospacedDigit()
                        }
                    }
                    .foregroundStyle(
                        isActive ? OriveoTheme.V2.Colors.primary : OriveoTheme.V2.Colors.textSecondary
                    )
                    .padding(.horizontal, 11)
                    .frame(height: 32)
                    .background(
                        Capsule(style: .continuous).fill(
                            isActive
                                ? OriveoTheme.V2.Colors.primary.opacity(0.12)
                                : OriveoTheme.V2.Colors.surfaceDefault
                        )
                    )
                    .contentShape(Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isActive ? [.isSelected, .isButton] : .isButton)
            }
            Spacer(minLength: 0)
        }
    }

    private var flatListItems: [ModelPickerFlatItem] {
        var result: [ModelPickerFlatItem] = []
        for section in providerSections {
            let provider = section.provider
            let providerExpanded = !showsProviderHeaders || isExpanded(providerID: provider.id)
            var contents: [ModelPickerFlatItem.Content] = []

            if showsProviderHeaders {
                contents.append(.providerHeader(section: section, isExpanded: providerExpanded))
            }
            if providerExpanded {
                contents.append(contentsOf: section.models.map {
                    .model(provider: provider, model: $0, isNestedUnderVendor: false)
                })
                if allowsCatalogEditing, provider.canAddModelsInModelPicker, searchQuery.isEmpty {
                    contents.append(.addModels(providerID: provider.id))
                }
            }

            for (index, content) in contents.enumerated() {
                result.append(
                    ModelPickerFlatItem(
                        content: content,
                        beginsProvider: index == 0,
                        endsProvider: index == contents.count - 1
                    )
                )
            }
        }
        return result
    }

    @ViewBuilder
    private func flatListItemView(_ item: ModelPickerFlatItem) -> some View {
        let shape = UnevenRoundedRectangle(
            cornerRadii: RectangleCornerRadii(
                topLeading: item.beginsProvider ? modelPickerCardRadius : 0,
                bottomLeading: item.endsProvider ? modelPickerCardRadius : 0,
                bottomTrailing: item.endsProvider ? modelPickerCardRadius : 0,
                topTrailing: item.beginsProvider ? modelPickerCardRadius : 0
            ),
            style: .continuous
        )

        Group {
            switch item.content {
            case .providerHeader(let section, let isExpanded):
                providerSectionHeader(
                    provider: section.provider,
                    modelCount: section.models.count,
                    isExpanded: isExpanded,
                    isCollapsible: true,
                    onToggle: { toggleProviderSection(section.provider.id) }
                )
            case .vendorHeader(let provider, let group, let isExpanded):
                ModelPickerVendorGroupHeader(
                    group: group,
                    isExpanded: isExpanded,
                    onToggle: { toggleVendorGroup(providerID: provider.id, groupID: group.id) }
                )
            case .model(let provider, let model, let isNestedUnderVendor):
                ModelPickerRow(
                    model: model,
                    provider: provider,
                    capabilityEvidenceRevision: capabilityEvidenceRevision,
                    isNestedUnderVendor: isNestedUnderVendor,
                    isSelected: isModelSelected(model, providerID: provider.id),
                    onTap: { selectModel(model, providerID: provider.id) }
                )
                .id(ModelPickerRowID(providerID: provider.id, modelID: model.id))
            case .addModels(let providerID):
                addModelsRow(providerID: providerID)
            }
        }
        .background(OriveoTheme.V2.Colors.surfaceDefault)
        .clipShape(shape)
        .overlay(alignment: .bottom) {
            if !item.endsProvider {
                Rectangle()
                    .fill(OriveoTheme.V2.Colors.borderSubtle)
                    .frame(height: 1 / UIScreen.main.scale)
                    .padding(.leading, item.dividerLeadingInset)
            }
        }
    }

    private var emptyStateCard: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(OriveoTheme.V2.Colors.textTertiary)
            Text(L10n.tr("No matching models found"))
                .font(.system(size: 15))
                .foregroundStyle(OriveoTheme.V2.Colors.textSecondary)
                .multilineTextAlignment(.center)

            if !activeCapabilityFilters.isEmpty {
                Button {
                    activeCapabilityFilters.removeAll()
                } label: {
                    Text(L10n.tr("Clear capability filters", table: .providers))
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(OriveoTheme.V2.Colors.primary)
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
        .background(
            RoundedRectangle(cornerRadius: modelPickerCardRadius, style: .continuous)
                .fill(OriveoTheme.V2.Colors.surfaceDefault)
        )
    }

    private func providerSectionHeader(
        provider: Provider,
        modelCount: Int,
        isExpanded: Bool,
        isCollapsible: Bool,
        onToggle: @escaping () -> Void
    ) -> some View {
        let resolvedKind = ProviderLogoResolver.logoKind(for: provider)
        let resolvedRelay: RelayKind? =
            (provider.kind == .relay && resolvedKind == .relay) ? provider.relayKind : nil

        return Button {
            guard isCollapsible else { return }
            onToggle()
        } label: {
            HStack(spacing: 12) {
                ProviderBadgeIcon(kind: resolvedKind, size: 28, relayKind: resolvedRelay)
                    .frame(width: 30, height: 30)

                VStack(alignment: .leading, spacing: 2) {
                    Text(provider.displayName)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(OriveoTheme.V2.Colors.textPrimary)
                        .lineLimit(1)

                    Text(String(format: L10n.tr("%lld models"), modelCount))
                        .font(.system(size: 12, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(OriveoTheme.V2.Colors.textTertiary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                if isCollapsible {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(OriveoTheme.V2.Colors.textTertiary)
                        .frame(width: 12)
                        .contentTransition(.symbolEffect(.replace))
                        .animation(chevronAnimation, value: isExpanded)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, minHeight: 64)
            .contentShape(Rectangle())
        }
        .buttonStyle(SectionHeaderButtonStyle())
        .disabled(!isCollapsible)
    }

    // MARK: - Add Models Row

    private func addModelsRow(providerID: UUID) -> some View {
        Button {
            catalogProviderID = providerID
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(OriveoTheme.V2.Colors.primary)
                    .frame(width: 28, height: 28)
                    .background(
                        Circle().fill(OriveoTheme.V2.Colors.primarySubtle)
                    )

                Text(L10n.tr("Add Models"))
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(OriveoTheme.V2.Colors.primary)

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(OriveoTheme.V2.Colors.textTertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(SectionHeaderButtonStyle())
    }

    private func isExpanded(providerID: UUID) -> Bool {
        let query = searchQuery
        if !query.isEmpty { return true }
        return expandedProviderIDs.contains(providerID)
    }

    private func toggleProviderSection(_ providerID: UUID) {
        let query = searchQuery
        guard query.isEmpty else { return }

        toggleFeedbackTick &+= 1
        if expandedProviderIDs.contains(providerID) {
            expandedProviderIDs.remove(providerID)
        } else {
            expandedProviderIDs.insert(providerID)
        }
    }

    private func isVendorGroupExpanded(providerID: UUID, group: ModelPickerVendorGroup) -> Bool {
        if !searchQuery.isEmpty {
            return true
        }
        return expandedVendorGroupIDs[providerID, default: []].contains(group.id)
    }

    private func toggleVendorGroup(providerID: UUID, groupID: String) {
        guard searchQuery.isEmpty else { return }
        toggleFeedbackTick &+= 1
        var groups = expandedVendorGroupIDs[providerID, default: []]
        if groups.contains(groupID) {
            groups.remove(groupID)
        } else {
            groups.insert(groupID)
        }
        expandedVendorGroupIDs[providerID] = groups
    }
}

private struct ModelPickerVendorGroupHeader: View {
    let group: ModelPickerVendorGroup
    let isExpanded: Bool
    let onToggle: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 10) {
                ModelVendorIcon(groupKey: group.id, groupName: group.name, size: 24)

                Text(group.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(OriveoTheme.V2.Colors.textPrimary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 8)

                Text("\(group.models.count)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(OriveoTheme.V2.Colors.textTertiary)
                    .monospacedDigit()

                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(OriveoTheme.V2.Colors.textTertiary)
                    .frame(width: 14)
                    .contentTransition(.symbolEffect(.replace))
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: isExpanded)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(SectionHeaderButtonStyle())
        .background(OriveoTheme.V2.Colors.bgInset.opacity(0.32))
    }
}


private struct SectionHeaderButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                configuration.isPressed
                    ? OriveoTheme.V2.Colors.textPrimary.opacity(0.05)
                    : Color.clear
            )
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: - Model Row

struct ModelPickerPricePresentation: Equatable {
    let input: String?
    let output: String?
    let fallback: String?

    init(model: AIModel) {
        let hasStructuredPricing = model.promptPrice != nil || model.completionPrice != nil
        if model.pricingUnit == "per_token", hasStructuredPricing {
            let isExplicitlyFree = model.promptPrice == 0 && model.completionPrice == 0
            if isExplicitlyFree {
                input = nil
                output = nil
                fallback = L10n.tr("Free")
            } else {
                input = model.promptPrice.flatMap(Self.formatPerMillion)
                output = model.completionPrice.flatMap(Self.formatPerMillion)
                fallback = nil
            }
        } else {
            input = nil
            output = nil
            let normalized = model.normalizedPriceTier
            fallback = normalized.isEmpty ? nil : normalized
        }
    }

    private static func formatPerMillion(_ perTokenPrice: Double) -> String? {
        guard perTokenPrice >= 0 else { return nil }
        return perTokenPrice == 0 ? "$0/M" : CostFormatter.formatPerMillion(perTokenPrice)
    }
}

func formatModelPickerContextLength(_ tokens: Int?) -> String? {
    guard let tokens, tokens > 0 else { return nil }
    if tokens >= 1_000_000 {
        let millions = Double(tokens) / 1_000_000
        if millions >= 10 {
            return "\(Int(millions.rounded()))M"
        }
        let rounded = (millions * 10).rounded() / 10
        return rounded == rounded.rounded()
            ? "\(Int(rounded))M"
            : String(format: "%.1fM", locale: Locale(identifier: "en_US_POSIX"), rounded)
    }
    if tokens >= 1_000 {
        return "\(Int((Double(tokens) / 1_000).rounded()))K"
    }
    return "\(tokens)"
}

private struct ModelPickerPriceRow: View {
    let pricing: ModelPickerPricePresentation
    let contextLengthLabel: String?

    private var hasPricing: Bool {
        pricing.input != nil || pricing.output != nil || pricing.fallback != nil
    }

    var body: some View {
        if contextLengthLabel != nil || hasPricing {
            HStack(alignment: .center, spacing: 8) {
                if let contextLengthLabel {
                    HStack(spacing: 3) {
                        Image(systemName: "memorychip")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(OriveoTheme.V2.Colors.textTertiary)
                        Text(contextLengthLabel)
                            .font(.system(size: 11, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(OriveoTheme.V2.Colors.textTertiary)
                    }
                    .fixedSize()
                }

                if contextLengthLabel != nil, hasPricing {
                    Circle()
                        .fill(OriveoTheme.V2.Colors.textTertiary.opacity(0.45))
                        .frame(width: 3, height: 3)
                        .accessibilityHidden(true)
                }

                pricingContent
            }
        }
    }

    @ViewBuilder
    private var pricingContent: some View {
        if pricing.input != nil || pricing.output != nil {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { structuredPrices }
                VStack(alignment: .leading, spacing: 3) { structuredPrices }
            }
        } else if let fallback = pricing.fallback {
            Text(fallback)
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(OriveoTheme.V2.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var structuredPrices: some View {
        if let input = pricing.input {
            price(label: L10n.tr("Input", table: .chat), value: input)
        }
        if let output = pricing.output {
            price(label: L10n.tr("Output", table: .chat), value: output)
        }
    }

    private func price(label: String, value: String) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 4) {
                priceText(label: label, value: value)
            }
            VStack(alignment: .leading, spacing: 1) {
                priceText(label: label, value: value)
            }
        }
        .font(.system(size: 11))
    }

    @ViewBuilder
    private func priceText(label: String, value: String) -> some View {
        Text(label)
            .foregroundStyle(OriveoTheme.V2.Colors.textTertiary)
        Text(value)
            .fontWeight(.semibold)
            .foregroundStyle(OriveoTheme.V2.Colors.textSecondary)
            .monospacedDigit()
    }
}

private struct ModelPickerRow: View {
    let model: AIModel
    let provider: Provider
    let capabilityEvidenceRevision: UInt64
    let isNestedUnderVendor: Bool
    let isSelected: Bool
    let onTap: () -> Void

    private var pricing: ModelPickerPricePresentation {
        ModelPickerPricePresentation(model: model)
    }

    private var title: String {
        model.modelPickerDisplayTitle
    }

    private var contextLengthLabel: String? {
        formatModelPickerContextLength(model.contextLength)
    }

    private var shouldShowVendorSource: Bool {
        !isNestedUnderVendor && provider.kind.isAggregatedProvider
    }

    private var sourceName: String? {
        guard shouldShowVendorSource,
              let trimmed = model.groupName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              trimmed != provider.displayName else {
            return nil
        }
        return trimmed
    }

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(OriveoTheme.V2.Colors.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .layoutPriority(1)

                    rowMetadata

                    ModelPickerPriceRow(
                        pricing: pricing,
                        contextLengthLabel: contextLengthLabel
                    )
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                ZStack {
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(OriveoTheme.V2.Colors.primary)
                    }
                }
                .frame(width: 18, height: 18)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, isNestedUnderVendor ? 52 : 16)
            .padding(.trailing, 16)
            .padding(.vertical, 13)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(ModelPickerRowButtonStyle(isSelected: isSelected))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .opacity(model.isAvailable ? 1 : 0.68)
        .disabled(!model.isAvailable)
    }

    @ViewBuilder
    private var rowMetadata: some View {
        let visible = ModelPickerCapabilityFilter.visibleCapabilities(model: model, provider: provider)
        let intent = ModelPickerCapabilityFilter.intentCapabilities(visibleCapabilities: visible)
        let intentSet = Set(intent.map(\.modelCapability))
        let others = Array(visible.filter { !intentSet.contains($0) }.prefix(2))

        HStack(spacing: 8) {
            if let sourceName {
                Text(sourceName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(OriveoTheme.V2.Colors.textTertiary)
                    .lineLimit(1)
            }

            ModelListMetadataRow(
                model: model,
                provider: provider,
                capabilityEvidenceRevision: capabilityEvidenceRevision,
                projectedCapabilities: others,
                maxCapabilities: 2,
                prominentPrice: false,
                compact: true,
                iconOnly: false,
                showPrice: false
            )
            .frame(maxWidth: .infinity, alignment: .leading)

            ForEach(intent) { capability in
                Image(systemName: capability.symbolName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(OriveoTheme.V2.Colors.textSecondary)
                    .accessibilityLabel(Text(capability.badgeAccessibilityLabel))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}


private struct ModelPickerRowButtonStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(rowBackground(pressed: configuration.isPressed))
            .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
    }

    @ViewBuilder
    private func rowBackground(pressed: Bool) -> some View {
        ZStack {
            if isSelected {
                OriveoTheme.V2.Colors.primary.opacity(0.08)
            }
            if pressed {
                OriveoTheme.V2.Colors.textPrimary.opacity(0.04)
            }
        }
    }
}

// MARK: - Section Model

struct ModelPickerSection: Identifiable {
    let provider: Provider
    let models: [AIModel]

    var id: UUID { provider.id }
}

func buildModelPickerSections(
    context: ModelPickerContext,
    providers: [Provider],
    currentProviderID: UUID?,
    currentModel: AIModel?
) -> [ModelPickerSection] {
    let isHome: Bool
    if case .home = context {
        isHome = true
    } else {
        isHome = false
    }

    let sortedProviders: [Provider]
    if isHome {
        var ordered = sortedProvidersForModelPicker(providers)
        if let currentProviderID,
           let activeIndex = ordered.firstIndex(where: { $0.id == currentProviderID }),
           activeIndex > 0 {
            let active = ordered.remove(at: activeIndex)
            ordered.insert(active, at: 0)
        }
        sortedProviders = ordered
    } else {
        sortedProviders = providers.sorted { lhs, rhs in
            let lhsActive = lhs.id == currentProviderID
            let rhsActive = rhs.id == currentProviderID
            if lhsActive != rhsActive { return lhsActive }
            return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
        }
    }

    return sortedProviders.compactMap { provider in
        var models = isHome ? sortedEnabledModels(for: provider) : provider.models
        if !isHome,
           provider.id == currentProviderID,
           let currentModel,
           !models.contains(where: { $0.id == currentModel.id }) {
            models.insert(currentModel, at: 0)
        }
        models = models.filter { isModelTransportSupportedForPicker(provider: provider, model: $0) }
        if !isHome, !provider.kind.usesServerOrderedModels {
            models.sort(by: pickerModelSort)
        }
        guard shouldRenderModelPickerProviderSection(provider: provider, query: "", models: models) else {
            return nil
        }
        return ModelPickerSection(provider: provider, models: models)
    }
}

func isModelTransportSupportedForPicker(provider: Provider, model: AIModel) -> Bool {
    switch provider.kind {
    case .relay:
        return true
    default:
        break
    }
    guard let resolved = MetadataClient.shared.syncResolveCatalogModel(
        modelID: model.id, providerKind: provider.kind
    ) else {
        return true
    }
    guard let kindRaw = resolved.transport?.trimmingCharacters(in: .whitespacesAndNewlines),
          !kindRaw.isEmpty else {
        return true
    }
    return TransportRegistry.isSupported(kindRaw: kindRaw)
}

struct ModelPickerRowID: Hashable {
    let providerID: UUID
    let modelID: String
}

struct ModelPickerFlatItem: Identifiable {
    enum ID: Hashable {
        case provider(UUID)
        case vendor(UUID, String)
        case model(ModelPickerRowID)
        case addModels(UUID)
    }

    enum Content {
        case providerHeader(section: ModelPickerSection, isExpanded: Bool)
        case vendorHeader(provider: Provider, group: ModelPickerVendorGroup, isExpanded: Bool)
        case model(provider: Provider, model: AIModel, isNestedUnderVendor: Bool)
        case addModels(providerID: UUID)
    }

    let content: Content
    let beginsProvider: Bool
    let endsProvider: Bool

    var id: ID {
        switch content {
        case .providerHeader(let section, _):
            return .provider(section.provider.id)
        case .vendorHeader(let provider, let group, _):
            return .vendor(provider.id, group.id)
        case .model(let provider, let model, _):
            return .model(ModelPickerRowID(providerID: provider.id, modelID: model.id))
        case .addModels(let providerID):
            return .addModels(providerID)
        }
    }

    var dividerLeadingInset: CGFloat {
        switch content {
        case .model(_, _, let isNestedUnderVendor):
            return isNestedUnderVendor ? 52 : 16
        default:
            return 16
        }
    }
}

struct ModelPickerVendorGroup: Identifiable, Equatable {
    let id: String
    let name: String
    let models: [AIModel]
}

func groupModelPickerModelsByVendor(_ models: [AIModel]) -> [ModelPickerVendorGroup] {
    var order: [String] = []
    var names: [String: String] = [:]
    var modelsByGroup: [String: [AIModel]] = [:]

    for model in models {
        let rawKey = model.groupKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let key = rawKey.isEmpty ? "__ungrouped__" : rawKey
        let rawName = model.groupName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let name = rawName.isEmpty ? (rawKey.isEmpty ? "Other" : rawKey) : rawName

        if modelsByGroup[key] == nil {
            order.append(key)
            names[key] = name
        }
        modelsByGroup[key, default: []].append(model)
    }

    return order.compactMap { key in
        guard let name = names[key], let groupedModels = modelsByGroup[key] else { return nil }
        return ModelPickerVendorGroup(id: key, name: name, models: groupedModels)
    }
}

func defaultExpandedModelPickerVendorGroupIDs(
    groups: [ModelPickerVendorGroup],
    selectedModelID: String?,
    searchText: String
) -> Set<String> {
    if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return Set(groups.map(\.id))
    }
    guard let selectedModelID,
          let activeGroup = groups.first(where: { group in
              group.models.contains(where: { $0.id == selectedModelID })
          }) else {
        return []
    }
    return [activeGroup.id]
}

func shouldRenderModelPickerProviderSection(provider: Provider, query: String, models: [AIModel]) -> Bool {
    !models.isEmpty || (query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && provider.canAddModelsInModelPicker)
}

func defaultExpandedModelPickerProviderIDs(
    _ providers: [Provider],
    selectedProviderID: UUID? = nil
) -> Set<UUID> {
    if let selectedProviderID, providers.contains(where: { $0.id == selectedProviderID }) {
        return [selectedProviderID]
    }
    guard let firstProvider = providers.first else { return [] }
    return [firstProvider.id]
}

extension Provider {
    var canAddModelsInModelPicker: Bool {
        if kind == .relay {
            return catalogModels.count > models.count
        }
        return kind.isAggregatedProvider
    }
}

private extension AIModel {
    var modelPickerDisplayTitle: String {
        var title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let groupName = groupName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !groupName.isEmpty {
            let prefix = "\(groupName): "
            if title.lowercased().hasPrefix(prefix.lowercased()) {
                let tail = title.dropFirst(prefix.count).trimmingCharacters(in: .whitespacesAndNewlines)
                if !tail.isEmpty {
                    title = tail
                }
            }
        }
        if title.lowercased().hasSuffix(" (free)") {
            title = String(title.dropLast(" (free)".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return title.isEmpty ? name : title
    }
}


enum ModelPickerGroupExpansionStore {
    private static func key(for providerID: UUID) -> String {
        "modelPicker.expandedGroups.\(providerID.uuidString)"
    }

    static func load(for providerID: UUID) -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: key(for: providerID)) ?? [])
    }

    static func save(_ groupIDs: Set<String>, for providerID: UUID) {
        UserDefaults.standard.set(Array(groupIDs), forKey: key(for: providerID))
    }
}


struct InlineModelCatalogView: View {
    let providerID: UUID

    @Environment(AppState.self) private var appState
    @State private var searchText = ""
    @State private var expandedGroupIDs = Set<String>()
    @State private var groups: [ProviderCatalogGroup] = []
    @State private var projectedRequest: ProviderCatalogProjectionRequestIdentity?
    @State private var expansionSignature: ProviderCatalogExpansionSignature?

    private var provider: Provider? {
        appState.provider(for: providerID)
    }

    private var capabilityEvidenceRevision: UInt64 {
        CapabilityEvidenceObservationBridge.shared.contentRevision
    }

    private var projectionRequest: ProviderCatalogProjectionRequestIdentity? {
        guard let provider else { return nil }
        let snapshot = ProviderCatalogSnapshotIdentity(
            providerID: provider.id,
            providersVersion: appState.providersVersion,
            metadataContentRevision: capabilityEvidenceRevision,
            metadataETag: MetadataClient.shared.syncMetadataETag()
        )
        return ProviderCatalogProjectionRequestIdentity(snapshot: snapshot, searchText: searchText)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: OriveoTheme.Spacing.lg) {
                if !groups.isEmpty || !searchText.isEmpty {
                    HStack(spacing: OriveoTheme.Spacing.sm) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(OriveoTheme.Palette.textSecondary)
                        TextField(L10n.tr("Search models..."), text: $searchText)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        if !searchText.isEmpty {
                            Button { searchText = "" } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(OriveoTheme.Palette.textSecondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, OriveoTheme.Spacing.md)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: OriveoTheme.Radius.md, style: .continuous)
                            .fill(OriveoTheme.Palette.surface)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: OriveoTheme.Radius.md, style: .continuous)
                            .stroke(OriveoTheme.Palette.border, lineWidth: 1)
                    )
                }

                if projectedRequest != projectionRequest {
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 96)
                } else if groups.isEmpty {
                    OriveoCard {
                        Text(searchText.isEmpty ? L10n.tr("All models are already enabled", table: .home) : L10n.tr("No matching models found"))
                            .font(OriveoTheme.Typography.body)
                            .foregroundStyle(OriveoTheme.Palette.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, OriveoTheme.Spacing.xl)
                    }
                } else if let provider {
                    ProviderCatalogGroupList(
                        provider: provider,
                        capabilityEvidenceRevision: capabilityEvidenceRevision,
                        groups: groups,
                        searchText: searchText,
                        expandedGroupIDs: expandedGroupIDs,
                        coordinateSpaceName: nil,
                        onToggleGroup: toggleGroup,
                        onAddModel: { model, _ in
                            appState.enableModel(modelID: model.id, for: providerID)
                        }
                    )
                }
            }
            .padding(OriveoTheme.Spacing.xl)
        }
        .oriveoScreenBackground()
        .navigationTitle(L10n.tr("Add Models"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbarVisibility(.visible, for: .navigationBar)
        .onAppear {
            expandedGroupIDs = ModelPickerGroupExpansionStore.load(for: providerID)
        }
        .task(id: projectionRequest) {
            guard let provider, let request = projectionRequest else {
                groups = []
                projectedRequest = nil
                return
            }
            if !searchText.isEmpty {
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled else { return }
            }
            let projected = await ProviderCatalogProjectionMemo.shared.groups(
                for: provider,
                searchText: searchText,
                snapshot: request.snapshot
            )
            guard !Task.isCancelled, request == projectionRequest else { return }
            groups = projected
            projectedRequest = request
            let update = ProviderCatalogExpansionPolicy.reconcile(
                expandedGroupIDs: expandedGroupIDs,
                previousSignature: expansionSignature,
                projection: request,
                groups: projected
            )
            expandedGroupIDs = update.expandedGroupIDs
            expansionSignature = update.signature
            if update.shouldPersist {
                ModelPickerGroupExpansionStore.save(update.expandedGroupIDs, for: providerID)
            }
        }
    }

    private func toggleGroup(_ groupID: String) {
        guard !shouldAutoExpandProviderCatalogGroups(searchText: searchText) else { return }

        if expandedGroupIDs.contains(groupID) {
            expandedGroupIDs.remove(groupID)
        } else {
            expandedGroupIDs.insert(groupID)
        }
        ModelPickerGroupExpansionStore.save(expandedGroupIDs, for: providerID)
    }
}
