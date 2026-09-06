import SwiftUI
import UniformTypeIdentifiers

struct GenerationParameterDefaultsSheet: View {
    enum Presentation {
        case sheet
        case embeddedPage

        var showsConnectionTools: Bool { self == .sheet }
    }

    let provider: Provider
    let conversationID: UUID?
    var presentation: Presentation = .sheet
    var capabilityHeader: AnyView?
    var isReadOnly: Bool = false

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(AppState.self) private var appState
    @State private var modelID: String
    @State private var values: GenerationParameterOverrides
    @State private var presetName = ""
    @State private var presetRevision = 0
    @State private var schemaDrafts: [String: String] = [:]
    @State private var numberDrafts: [String: String] = [:]
    @State private var invalidSchemaIDs: Set<String> = []
    @State private var showImporter = false
    @State private var showExporter = false
    @State private var pendingDestruction: DestructiveAction?
    @State private var importFailed = false
    @State private var exportFailed = false
    @State private var pendingPresetDeletion: GenerationParameterPreset?

    enum DestructiveAction: String, Identifiable {
        case restoreDefaults
        case clearDormant
        case removeConflicts

        var id: String { rawValue }
    }
    @State private var didClearLearnedCapabilities = false
    @State private var exportDocument: GenerationParameterJSONDocument?
    @State private var exportFilename = "oriveo-generation-parameters.v1"
    @State private var dormantExpanded = false
    @State private var expandedGroups: Set<String> = []
    @State private var dormantSnapshots: [String: [String]] = [:]
    @State private var customFieldsEntry: CustomFieldsEntry = .unsupported
    @State private var showsCustomFieldsUnsupportedAlert = false
    @State private var showsCustomFieldsSupportedModels = false
    @FocusState private var focusedField: String?

    init(
        provider: Provider,
        initialModelID: String? = nil,
        conversationID: UUID? = nil,
        presentation: Presentation = .sheet,
        capabilityHeader: AnyView? = nil,
        isReadOnly: Bool = false
    ) {
        self.provider = provider
        self.conversationID = conversationID
        self.presentation = presentation
        self.capabilityHeader = capabilityHeader
        self.isReadOnly = isReadOnly
        let initialID = initialModelID
            ?? provider.models.first(where: \.isDefault)?.id
            ?? provider.models.first?.id
            ?? ""
        _modelID = State(initialValue: initialID)
        let initialModel = provider.models.first { $0.id == initialID }
        let fingerprint = initialModel.map { GenerationParameterProfileFingerprint.make(provider: provider, model: $0) }
        let stored = conversationID.map {
            GenerationParameterSettingsStore.shared.sessionOverrides(
                providerID: provider.id,
                modelID: initialID,
                conversationID: $0,
                profileFingerprint: fingerprint
            )
        } ?? GenerationParameterSettingsStore.shared.modelDefaults(
            providerID: provider.id,
            modelID: initialID,
            profileFingerprint: fingerprint
        )
        _values = State(initialValue: stored ?? .init())
    }

    private var model: AIModel? { provider.models.first { $0.id == modelID } }
    private var capabilityEvidenceIdentity: CapabilityEvidenceRequestIdentity? {
        guard let model else { return nil }
        if provider.kind == .relay {
            return CapabilityEvidenceProductionAdapter.uiDispatchIdentity(
                provider: provider,
                model: model,
                partitionID: appState.sessionPartitionUID
            )
        }
        return CapabilityEvidenceRequestIdentity.make(
            provider: provider,
            model: model,
            partitionID: appState.sessionPartitionUID,
            hasExplicitValue: false
        )
    }

    private var generationProfile: GenerationProfileRef? {
        model.flatMap {
            GenerationParameterAvailability.profile(
                provider: provider, model: $0, identity: capabilityEvidenceIdentity
            )
        }
    }
    private var generationEvidenceProjection: GenerationParameterEvidenceProjection? {
        guard let model else { return nil }
        return CapabilityEvidenceProductionAdapter.generationProjection(
            provider: provider,
            model: model,
            identity: capabilityEvidenceIdentity
        )
    }
    private var scope: GenerationParameterEntryScope {
        conversationID == nil ? .connectionDefaults : .session
    }

    private var parameters: [GenerationParameterRef] {
        guard let model else { return [] }
        return GenerationParameterPanelPresentation.visibleParameters(
            provider: provider,
            model: model,
            scope: scope,
            identity: capabilityEvidenceIdentity
        )
    }

    private var partition: GenerationParameterLifecycle.Partition {
        guard let model else {
            return GenerationParameterLifecycle.partition(activeParameterIDs: [], values: values)
        }
        return GenerationParameterLifecycle.partition(
            provider: provider,
            model: model,
            values: values,
            identity: capabilityEvidenceIdentity
        )
    }

    private var emptyState: GenerationParameterEmptyState? {
        guard let model else { return nil }
        return GenerationParameterPanelPresentation.emptyState(
            provider: provider,
            model: model,
            scope: scope,
            hasSeenNonEmptyProfile: GenerationParameterProfileHistory.shared.hasSeenNonEmptyProfile(
                providerID: provider.id,
                modelID: model.id
            ),
            identity: capabilityEvidenceIdentity
        )
    }

    var body: some View {
        let _ = CapabilityEvidenceObservationBridge.shared.contentRevision
        Group {
            if presentation == .sheet {
                NavigationStack { editor }
            } else {
                editor
            }
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            guard let url = try? result.get().first else { return }
            let didAccess = url.startAccessingSecurityScopedResource()
            defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { return }
            if (try? GenerationParameterSyncContract.importJSON(data)) != nil {
                values = loadValues(modelID: modelID)
                presetRevision += 1
            } else {
                importFailed = true
            }
        }
        .fileExporter(
            isPresented: $showExporter,
            document: exportDocument,
            contentType: .json,
            defaultFilename: exportFilename
        ) { _ in exportDocument = nil }
        .alert(L10n.tr("Import Backup", table: .backup), isPresented: $importFailed) {
            Button(L10n.tr("OK")) { importFailed = false }
        } message: {
            Text(L10n.tr("This file could not be read as an Oriveo backup.", table: .backup))
        }
        .alert(L10n.tr("Export Backup", table: .backup), isPresented: $exportFailed) {
            Button(L10n.tr("OK")) { exportFailed = false }
        } message: {
            Text(L10n.tr("This export could not be prepared.", table: .backup))
        }
    }

    private var editor: some View {
        Group {
            if presentation == .sheet {
                sheetEditor
            } else {
                embeddedEditor
            }
        }
        .navigationTitle(L10n.tr("Advanced Settings"))
        .onAppear {
            recordSeenProfile()
            syncDormantSnapshot()
            refreshCustomFieldsEntry()
        }
        .onChange(of: modelID) { _, _ in
            recordSeenProfile()
            refreshCustomFieldsEntry()
        }
        .onChange(of: partition.dormantIDs.joined(separator: "|")) { _, _ in syncDormantSnapshot() }
        .toolbar {
            if presentation == .sheet {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.tr("Done")) { dismiss() }
                        .font(.body.weight(.semibold))
                }
            }
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button(L10n.tr("Done")) { focusedField = nil }
                    .font(.body.weight(.semibold))
            }
        }
        .alert(
            L10n.tr("Delete"),
            isPresented: Binding(
                get: { pendingPresetDeletion != nil },
                set: { if !$0 { pendingPresetDeletion = nil } }
            )
        ) {
            Button(L10n.tr("Cancel"), role: .cancel) { pendingPresetDeletion = nil }
            Button(L10n.tr("Delete"), role: .destructive) {
                if let preset = pendingPresetDeletion {
                    GenerationParameterPresetStore.shared.remove(id: preset.id)
                    presetRevision += 1
                }
                pendingPresetDeletion = nil
            }
        } message: {
            Text(pendingPresetDeletion?.name ?? "")
        }
        .alert(
            destructionTitle,
            isPresented: Binding(
                get: { pendingDestruction != nil },
                set: { if !$0 { pendingDestruction = nil } }
            ),
            presenting: pendingDestruction
        ) { action in
            Button(L10n.tr("Cancel"), role: .cancel) { pendingDestruction = nil }
            Button(destructionConfirmTitle(action), role: .destructive) { perform(action) }
        } message: { action in
            Text(destructionMessage(action))
        }
        .alert(
            L10n.tr("Custom request fields", table: .chat),
            isPresented: $showsCustomFieldsUnsupportedAlert
        ) {
            if !customFieldsSupportedModelCandidates.isEmpty {
                Button(L10n.tr("View supported models", table: .chat)) {
                    showsCustomFieldsUnsupportedAlert = false
                    showsCustomFieldsSupportedModels = true
                }
            }
            Button(L10n.tr("OK")) { showsCustomFieldsUnsupportedAlert = false }
        } message: {
            Text(customFieldsUnsupportedMessage)
        }
        .navigationDestination(isPresented: $showsCustomFieldsSupportedModels) {
            CapabilitySupportedModelsPage(
                provider: provider,
                capability: "generation",
                title: L10n.tr("Custom request fields", table: .chat),
                candidates: customFieldsSupportedModelCandidates,
                onSelect: selectCustomFieldsCandidate
            )
        }
        .tint(OriveoTheme.Palette.primary)
    }


    private var sheetEditor: some View {
            List {
                if let capabilityHeader {
                    Section { capabilityHeader }
                        .listRowBackground(OriveoTheme.Palette.surface)
                }

                if conversationID == nil, provider.models.count > 1 {
                    Picker(L10n.tr("Model", table: .providers), selection: $modelID) {
                        ForEach(provider.models) { model in Text(model.name).tag(model.id) }
                    }
                    .onChange(of: modelID) { _, next in
                        values = loadValues(modelID: next)
                        numberDrafts.removeAll()
                        schemaDrafts.removeAll()
                    }
                }

                if let model {
                    Section {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(scopeTitle(model: model))
                                .font(.headline)
                            Text(scopeDetail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .listRowBackground(OriveoTheme.Palette.surface)
                }

                if presentation.showsConnectionTools, let fingerprint = profileFingerprint {
                    Section(L10n.tr("Presets", table: .providers)) {
                        HStack {
                            TextField(L10n.tr("Preset name", table: .providers), text: $presetName)
                            Button(L10n.tr("Save")) {
                                _ = GenerationParameterPresetStore.shared.save(
                                    name: presetName,
                                    providerID: provider.id,
                                    modelID: modelID,
                                    profileFingerprint: fingerprint,
                                    values: values
                                )
                                presetName = ""
                                presetRevision += 1
                            }
                            .disabled(presetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                        ForEach(presets(fingerprint: fingerprint)) { preset in
                            HStack {
                                Button(preset.name) {
                                    if let applied = GenerationParameterPresetStore.shared.apply(
                                        preset,
                                        providerID: provider.id,
                                        modelID: modelID,
                                        profileFingerprint: fingerprint,
                                        semanticMapping: portableSemanticMapping
                                    ) {
                                        values = applied
                                        persist()
                                    }
                                }
                                Spacer()
                                Button {
                                    if let copied = GenerationParameterPresetStore.shared.apply(
                                        preset,
                                        providerID: provider.id,
                                        modelID: modelID,
                                        profileFingerprint: fingerprint,
                                        semanticMapping: portableSemanticMapping
                                    ) {
                                        _ = GenerationParameterPresetStore.shared.save(
                                            name: copyName(of: preset.name, fingerprint: fingerprint),
                                            providerID: provider.id,
                                            modelID: modelID,
                                            profileFingerprint: fingerprint,
                                            values: copied
                                        )
                                        presetRevision += 1
                                    }
                                } label: {
                                    Image(systemName: "plus.square.on.square")
                                        .frame(width: 44, height: 44)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel(L10n.tr("Copy"))
                                Button(role: .destructive) {
                                    pendingPresetDeletion = preset
                                } label: {
                                    Image(systemName: "trash")
                                        .frame(width: 44, height: 44)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel(L10n.tr("Delete"))
                            }
                        }
                        .id(presetRevision)
                    }
                    .listRowBackground(OriveoTheme.Palette.surface)
                }

                if presentation.showsConnectionTools, conversationID == nil {
                    Section(L10n.tr("Connection", table: .providers)) {
                        Button {
                            let portableIDs = Set(parameters.filter { $0.portability == "portable" }.compactMap(\.id))
                            GenerationParameterSettingsStore.shared.setConnectionDefaults(
                                .init(values: values.values.filter { portableIDs.contains($0.key) }),
                                providerID: provider.id
                            )
                        } label: {
                            Label(L10n.tr("Save"), systemImage: "link")
                        }
                        Button {
                            exportFilename = "oriveo-generation-parameters.v1"
                            exportDocument = try? .init(data: GenerationParameterSyncContract.exportJSON())
                            showExporter = exportDocument != nil
                            exportFailed = exportDocument == nil
                        } label: {
                            Label(L10n.tr("Export Backup", table: .backup), systemImage: "square.and.arrow.up")
                        }
                        Button {
                            showImporter = true
                        } label: {
                            Label(L10n.tr("Import Backup", table: .backup), systemImage: "square.and.arrow.down")
                        }
                    }
                    .listRowBackground(OriveoTheme.Palette.surface)
                }

                if !compatibilityConflicts.isEmpty {
                    Section(L10n.tr("Compatibility", table: .providers)) {
                        Text(compatibilityConflicts.sorted().map(parameterTitle).joined(separator: " • "))
                            .font(.caption)
                            .foregroundStyle(.orange)
                        if !isReadOnly {
                            Button(L10n.tr("Remove conflicts", table: .providers), role: .destructive) {
                                pendingDestruction = .removeConflicts
                            }
                        }
                    }
                    .listRowBackground(OriveoTheme.Palette.surface)
                }

                if presentation.showsConnectionTools, provider.kind == .relay {
                    Section {
                        Button(L10n.tr("Clear learned capabilities", table: .providers)) {
                            guard let model, let identity = capabilityEvidenceIdentity else { return }
                            UnsupportedParamCache.shared.clear(
                                providerKind: .relay,
                                modelID: model.id,
                                identity: identity
                            )
                            didClearLearnedCapabilities = true
                        }
                        .disabled(model == nil || capabilityEvidenceIdentity == nil)

                        if didClearLearnedCapabilities {
                            Label(L10n.tr("Done"), systemImage: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(OriveoTheme.Palette.success)
                        }
                    }
                    .listRowBackground(OriveoTheme.Palette.surface)
                }

                if parameters.isEmpty {
                    emptyStateSection(emptyState ?? .notVerified)
                    dormantSummarySection
                } else {
                    if let unverifiedGroupNote {
                        Section {
                            Text(unverifiedGroupNote)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .listRowBackground(OriveoTheme.Palette.surface)
                    }
                    let basic = basicParameters
                    if !basic.isEmpty {
                        Section(L10n.tr("Basic Settings", table: .providers)) {
                            ForEach(basic, id: \.id) { parameter in parameterRow(parameter) }
                        }
                        .listRowBackground(OriveoTheme.Palette.surface)
                    }
                    ForEach(advancedGroups) { group in
                        Section {
                            DisclosureGroup(group.title) {
                                ForEach(group.parameters, id: \.id) { parameter in parameterRow(parameter) }
                            }
                        }
                        .listRowBackground(OriveoTheme.Palette.surface)
                    }
                    dormantSummarySection
                }

                if !isReadOnly, !values.values.isEmpty {
                    Section {
                        Button(L10n.tr("Restore Defaults"), role: .destructive) {
                            pendingDestruction = .restoreDefaults
                        }
                    }
                    .listRowBackground(OriveoTheme.Palette.surface)
                }

                Section(L10n.tr("Developer", table: .providers)) {
                    if isReadOnly {
                        customFieldsRowLabel
                    } else if customFieldsEntry == .unsupported {
                        Button { showsCustomFieldsUnsupportedAlert = true } label: {
                            customFieldsRowLabel
                        }
                        .buttonStyle(.plain)
                    } else {
                        NavigationLink { customFieldsDestination } label: {
                            customFieldsRowLabel
                        }
                    }
                }
                .listRowBackground(OriveoTheme.Palette.surface)
            }
            .scrollContentBackground(.hidden)
            .background(OriveoTheme.Palette.background)
    }


    private var embeddedEditor: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let capabilityHeader {
                    capabilityHeader
                }
                if let model {
                    embeddedScopeHeader(model: model)
                }
                if conversationID == nil, provider.models.count > 1 {
                    embeddedModelPickerCard
                }
                if !compatibilityConflicts.isEmpty {
                    embeddedConflictCard
                }
                if parameters.isEmpty {
                    embeddedEmptyStateCard(emptyState ?? .notVerified)
                } else {
                    embeddedParameterCard
                }
                embeddedDormantCard
                if !isReadOnly, !values.values.isEmpty {
                    embeddedRestoreDefaultsCard
                }
                embeddedDeveloperCard
            }
            .padding(.horizontal, 16)
            .padding(.top, 2)
            .padding(.bottom, 32)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(OriveoTheme.Palette.background)
    }

    private func embeddedScopeHeader(model: AIModel) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(scopeTitle(model: model))
                .font(.footnote.weight(.semibold))
                .foregroundStyle(OriveoTheme.Palette.textSecondary)
            Text(scopeDetail)
                .font(.caption)
                .foregroundStyle(OriveoTheme.Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var embeddedModelPickerCard: some View {
        HStack(spacing: 8) {
            Text(L10n.tr("Model", table: .providers))
                .font(.body.weight(.medium))
                .foregroundStyle(OriveoTheme.Palette.textPrimary)
            Spacer(minLength: 8)
            Picker("", selection: $modelID) {
                ForEach(provider.models) { model in Text(model.name).tag(model.id) }
            }
            .labelsHidden()
            .accessibilityLabel(Text(L10n.tr("Model", table: .providers)))
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
        .modelControlSurface()
        .onChange(of: modelID) { _, next in
            values = loadValues(modelID: next)
            numberDrafts.removeAll()
            schemaDrafts.removeAll()
        }
    }

    private var embeddedConflictCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.tr("Compatibility", table: .providers))
                .font(.footnote.weight(.semibold))
                .foregroundStyle(OriveoTheme.Palette.textSecondary)
            ModelControlNote(
                text: compatibilityConflicts.sorted().map(parameterTitle).joined(separator: " • "),
                systemImage: "exclamationmark.triangle",
                tone: OriveoTheme.Palette.warningText
            )
            if !isReadOnly {
                embeddedDestructiveButton(L10n.tr("Remove conflicts", table: .providers)) {
                    pendingDestruction = .removeConflicts
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modelControlSurface()
    }

    private var embeddedParameterCard: some View {
        let basic = basicParameters
        let advanced = advancedGroups
        return VStack(alignment: .leading, spacing: 10) {
            if let unverifiedGroupNote {
                ModelControlNote(text: unverifiedGroupNote)
            }
            VStack(spacing: 0) {
                if !basic.isEmpty {
                    if !advanced.isEmpty {
                        embeddedGroupTitle(L10n.tr("Basic Settings", table: .providers))
                    }
                    embeddedRows(basic)
                }
                ForEach(Array(advanced.enumerated()), id: \.element.id) { index, group in
                    if !basic.isEmpty || index > 0 {
                        ModelControlHairline(leadingInset: 0)
                    }
                    embeddedAdvancedGroup(group)
                }
            }
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .modelControlSurface()

            ModelControlNote(text: L10n.tr(
                "Parameters you leave unset aren’t sent; the provider uses the model’s defaults.",
                table: .providers
            ))
        }
    }

    private func embeddedGroupTitle(_ title: String) -> some View {
        Text(title)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(OriveoTheme.Palette.textSecondary)
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func embeddedRows(_ list: [GenerationParameterRef]) -> some View {
        ForEach(Array(list.enumerated()), id: \.element.id) { index, parameter in
            if index > 0 { ModelControlHairline() }
            parameterRow(parameter)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
        }
    }

    @ViewBuilder
    private func embeddedAdvancedGroup(_ group: ParameterGroup) -> some View {
        let expanded = expandedGroups.contains(group.id)
        Button {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                if expanded {
                    expandedGroups.remove(group.id)
                } else {
                    expandedGroups.insert(group.id)
                }
            }
        } label: {
            HStack(spacing: 8) {
                Text(group.title)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(OriveoTheme.Palette.textSecondary)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(OriveoTheme.Palette.textTertiary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(Text(expanded ? L10n.tr("Hide") : L10n.tr("View", table: .providers)))

        if expanded {
            ModelControlHairline()
            embeddedRows(group.parameters)
        }
    }

    private func embeddedEmptyStateCard(_ state: GenerationParameterEmptyState) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(state.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(OriveoTheme.Palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            if let detail = state.detail {
                ModelControlNote(text: detail)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modelControlSurface()
    }

    @ViewBuilder
    private var embeddedDormantCard: some View {
        let split = partition
        if !split.dormantIDs.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ModelControlNote(text: String(
                    format: L10n.tr("%d parameters you set are kept and won't be sent right now.", table: .providers),
                    split.dormantIDs.count
                ))

                Button {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { dormantExpanded.toggle() }
                } label: {
                    Text(dormantExpanded ? L10n.tr("Hide") : L10n.tr("View", table: .providers))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(OriveoTheme.Palette.primary)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if dormantExpanded {
                    VStack(spacing: 6) {
                        ForEach(split.dormantIDs, id: \.self) { id in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(parameterTitle(id))
                                    .foregroundStyle(OriveoTheme.Palette.textSecondary)
                                Spacer(minLength: 8)
                                Text(dormantValueText(split.dormant.values[id]))
                                    .foregroundStyle(OriveoTheme.Palette.textTertiary)
                            }
                            .font(.caption)
                        }
                    }
                }

                if !isReadOnly {
                    embeddedDestructiveButton(L10n.tr("Clear")) { pendingDestruction = .clearDormant }
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .modelControlSurface()
        }
    }

    private var embeddedRestoreDefaultsCard: some View {
        Button { pendingDestruction = .restoreDefaults } label: {
            Text(L10n.tr("Restore Defaults"))
                .font(.body.weight(.medium))
                .foregroundStyle(OriveoTheme.Palette.danger)
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modelControlSurface()
    }

    private func embeddedDestructiveButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(OriveoTheme.Palette.danger)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }


    private enum CustomFieldsEntry {
        case unsupported
        case idle
        case inUse
    }

    private var customFieldsRuntimeIdentity: CapabilityPreferenceRuntimeIdentity? {
        model.flatMap { CapabilityPreferenceRuntimeIdentity.make(provider: provider, model: $0) }
    }

    private func refreshCustomFieldsEntry() {
        guard let model, let identity = customFieldsRuntimeIdentity else {
            customFieldsEntry = .unsupported
            return
        }
        var reachable = false
        var inUse = false
        for (owner, namespace) in [
            ("web", "webPatch"), ("reasoning", "reasoningPatch"), ("generation", "generationPatch"),
        ] {
            if hasCustomFieldSchema(owner: owner, model: model) { reachable = true }
            let configuration = GenerationParameterSettingsStore.shared.effectiveLocalCustomConfiguration(
                providerID: provider.id, modelID: identity.canonicalModelID,
                conversationID: conversationID, transportIdentity: identity.wireValue,
                namespace: namespace,
                forwardPort: .init(providerKind: provider.kind, schemaModelID: model.id)
            )
            if configuration.mode == .custom { inUse = true; reachable = true }
            if !configuration.rawJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                reachable = true
            }
        }
        customFieldsEntry = inUse ? .inUse : (reachable ? .idle : .unsupported)
    }

    private func hasCustomFieldSchema(owner: String, model: AIModel) -> Bool {
        CapabilityRecipeExecution.hasSafeCustomSchema(
            owner: owner, providerKind: provider.kind, modelID: model.id,
            transport: CapabilityRecipeExecution.finalTransport(
                owner: owner, provider: provider, model: model
            ) ?? ""
        )
    }

    private var customFieldsSupportedModelCandidates: [AIModel] {
        return provider.models.filter { candidate in
            ["web", "reasoning", "generation"].contains { hasCustomFieldSchema(owner: $0, model: candidate) }
        }
    }

    private var customFieldsUnsupportedMessage: String {
        let base = L10n.tr(
            "Custom request fields are only available on models whose provider officially declares a field schema.",
            table: .providers
        )
        guard customFieldsSupportedModelCandidates.isEmpty else { return base }
        return base + "\n\n" + L10n.tr(
            "No models in this connection support this capability yet.", table: .chat
        )
    }

    private func selectCustomFieldsCandidate(_ candidate: AIModel) {
        appState.selectModel(modelID: candidate.id, providerID: provider.id, for: conversationID)
        modelID = candidate.id
        values = loadValues(modelID: candidate.id)
        numberDrafts.removeAll()
        schemaDrafts.removeAll()
        showsCustomFieldsSupportedModels = false
        refreshCustomFieldsEntry()
    }

    private var customFieldsStatusText: String {
        switch customFieldsEntry {
        case .unsupported: return L10n.tr("Not supported by this model", table: .chat)
        case .idle: return L10n.tr("Not in use", table: .providers)
        case .inUse: return L10n.tr("In use", table: .providers)
        }
    }

    @ViewBuilder
    private var customFieldsDestination: some View {
        if let model, let identity = customFieldsRuntimeIdentity {
            CustomRequestFieldsPage(
                provider: provider,
                model: model,
                conversationID: conversationID,
                transportIdentity: identity.wireValue
            )
        }
    }

    private var customFieldsRowLabel: some View {
        HStack(spacing: 8) {
            Text(L10n.tr("Custom request fields", table: .chat))
                .foregroundStyle(OriveoTheme.Palette.textPrimary)
            Spacer(minLength: 8)
            Text(customFieldsStatusText)
                .font(.caption)
                .foregroundStyle(OriveoTheme.Palette.textTertiary)
                .multilineTextAlignment(.trailing)
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }

    private var embeddedDeveloperCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.tr("Developer", table: .providers))
                .font(.footnote.weight(.semibold))
                .foregroundStyle(OriveoTheme.Palette.textSecondary)
            if isReadOnly {
                customFieldsRowLabel
            } else if customFieldsEntry == .unsupported {
                Button { showsCustomFieldsUnsupportedAlert = true } label: {
                    customFieldsRowLabel
                }
                .buttonStyle(.plain)
            } else {
                NavigationLink { customFieldsDestination } label: {
                    HStack(spacing: 8) {
                        customFieldsRowLabel
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(OriveoTheme.Palette.textTertiary)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modelControlSurface()
    }


    private func scopeTitle(model: AIModel) -> String {
        conversationID == nil
            ? "\(L10n.tr("Connection Defaults", table: .providers)) • \(model.name)"
            : "\(L10n.tr("Current Conversation")) • \(model.name)"
    }

    private var scopeDetail: String {
        conversationID == nil
            ? L10n.tr("Applies to new messages on this connection with this model, until you override them in a conversation.", table: .providers)
            : L10n.tr("Only applies while this model is used in this conversation. Switching models does not copy values; switching back restores them.")
    }

    private var unverifiedGroupNote: String? {
        guard let generationEvidenceProjection,
              GenerationParameterPanelPresentation.showsUnverifiedGroupNote(
                parameters: parameters, projection: generationEvidenceProjection
              ) else { return nil }
        return L10n.tr(
            "These parameters are inferred from the protocol you chose. Oriveo hasn't verified they take effect on this connection.",
            table: .providers
        )
    }

    private struct ParameterGroup: Identifiable {
        let id: String
        let title: String
        let parameters: [GenerationParameterRef]
    }

    private var advancedGroups: [ParameterGroup] {
        let basicIDs = Set(basicParameters.compactMap(\.id))
        let advanced = parameters.filter { !basicIDs.contains($0.id ?? "") }
        return groupOrder.compactMap { group in
            let grouped = advanced.filter { ($0.group ?? "sampling") == group }
            guard !grouped.isEmpty else { return nil }
            return ParameterGroup(id: group, title: groupTitle(group), parameters: grouped)
        }
    }

    private let groupOrder = ["budget", "reasoning", "sampling", "repetition", "reproducibility", "output_contract", "engine_runtime"]


    private func recordSeenProfile() {
        guard let model else { return }
        let declared = GenerationParameterAvailability
            .profile(provider: provider, model: model)?.parameters?.count ?? 0
        GenerationParameterProfileHistory.shared.recordSeenProfile(
            providerID: provider.id,
            modelID: model.id,
            parameterCount: declared
        )
    }

    @ViewBuilder
    private func emptyStateSection(_ state: GenerationParameterEmptyState) -> some View {
        Section(L10n.tr("Parameters", table: .providers)) {
            VStack(alignment: .leading, spacing: 6) {
                Text(state.title)
                    .font(.subheadline.weight(.semibold))
                if let detail = state.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

        }
        .listRowBackground(OriveoTheme.Palette.surface)
    }


    @ViewBuilder
    private var dormantSummarySection: some View {
        let split = partition
        if !split.dormantIDs.isEmpty {
            Section {
                Text(String(
                    format: L10n.tr("%d parameters you set are kept and won't be sent right now.", table: .providers),
                    split.dormantIDs.count
                ))
                .font(.caption)
                .foregroundStyle(.secondary)

                Button(dormantExpanded ? L10n.tr("Hide") : L10n.tr("View", table: .providers)) {
                    withAnimation(.easeInOut(duration: 0.2)) { dormantExpanded.toggle() }
                }

                if dormantExpanded {
                    ForEach(split.dormantIDs, id: \.self) { id in
                        HStack {
                            Text(parameterTitle(id))
                            Spacer()
                            Text(dormantValueText(split.dormant.values[id]))
                                .foregroundStyle(.secondary)
                        }
                        .font(.caption)
                    }
                }

                if !isReadOnly {
                    Button(L10n.tr("Clear"), role: .destructive) {
                        pendingDestruction = .clearDormant
                    }
                }
            }
            .listRowBackground(OriveoTheme.Palette.surface)
        }
    }

    private func dormantValueText(_ override: GenerationParameterOverride?) -> String {
        guard let override, override.state != .inherit else { return "" }
        if override.state == .omit { return L10n.tr("Omit") }
        return displayValue(override.value)
    }

    private func syncDormantSnapshot() {
        let current = partition.dormantIDs
        let previous = dormantSnapshots[modelID]
        dormantSnapshots[modelID] = current
        guard let previous else { return }
        let restored = previous.filter { !current.contains($0) && values.values[$0] != nil }
        guard !restored.isEmpty else { return }
        ToastManager.shared.show(
            String(format: L10n.tr("Restored %d parameters", table: .providers), restored.count),
            style: .success
        )
    }

    private var profileFingerprint: String? {
        model.map { GenerationParameterProfileFingerprint.make(provider: provider, model: $0) }
    }

    private var compatibilityConflicts: Set<String> {
        let active = Set(values.values.compactMap { $0.value.state == .value ? $0.key : nil })
        return Set(parameters.compactMap { parameter in
            guard let id = parameter.id, active.contains(id),
                  parameter.conflictsWith?.contains(where: active.contains) == true else { return nil }
            return id
        })
    }

    private func copyName(of name: String, fingerprint: String) -> String {
        let existing = Set(presets(fingerprint: fingerprint).map(\.name))
        guard existing.contains(name) else { return name }
        var index = 2
        while existing.contains("\(name) \(index)") { index += 1 }
        return "\(name) \(index)"
    }

    private var destructionTitle: String {
        switch pendingDestruction {
        case .clearDormant: return L10n.tr("Clear")
        case .removeConflicts: return L10n.tr("Remove conflicts", table: .providers)
        case .restoreDefaults, .none: return L10n.tr("Restore Defaults")
        }
    }

    private func destructionConfirmTitle(_ action: DestructiveAction) -> String {
        switch action {
        case .restoreDefaults: return L10n.tr("Restore Defaults")
        case .clearDormant: return L10n.tr("Clear")
        case .removeConflicts: return L10n.tr("Remove conflicts", table: .providers)
        }
    }

    private func destructionMessage(_ action: DestructiveAction) -> String {
        switch action {
        case .restoreDefaults:
            return L10n.tr("This clears every value you set for this model. This cannot be undone.", table: .providers)
        case .clearDormant:
            return L10n.tr("This deletes the stored values that no longer apply to this model. This cannot be undone.", table: .providers)
        case .removeConflicts:
            return compatibilityConflicts.sorted().map(parameterTitle).joined(separator: " • ")
        }
    }

    private func perform(_ action: DestructiveAction) {
        switch action {
        case .restoreDefaults:
            values = .init()
        case .clearDormant:
            values = partition.active
            dormantExpanded = false
        case .removeConflicts:
            compatibilityConflicts.forEach { values.values.removeValue(forKey: $0) }
        }
        numberDrafts.removeAll()
        schemaDrafts.removeAll()
        persist()
        pendingDestruction = nil
    }

    private func presets(fingerprint: String) -> [GenerationParameterPreset] {
        GenerationParameterPresetStore.shared.list(
            providerID: provider.id,
            modelID: modelID,
            profileFingerprint: fingerprint,
            portableParameterIDs: Set(portableSemanticMapping.keys)
        )
    }

    private var portableSemanticMapping: [String: String] {
        Dictionary(uniqueKeysWithValues: parameters.compactMap { parameter in
            guard parameter.portability == "portable", let id = parameter.id else { return nil }
            return (id, id)
        })
    }

    private var basicParameters: [GenerationParameterRef] {
        var result = parameters.filter { $0.id == "max_output_tokens" }
        if let sampling = parameters.first(where: { $0.id == "temperature" })
            ?? parameters.first(where: { $0.id == "top_p" }) {
            result.append(sampling)
        }
        return result
    }

    private func groupTitle(_ group: String) -> String {
        switch group {
        case "budget": return L10n.tr("Output Budget")
        case "reasoning": return L10n.tr("Reasoning")
        case "sampling": return L10n.tr("Sampling")
        case "repetition": return L10n.tr("Repetition Control")
        case "reproducibility": return L10n.tr("Reproducibility")
        case "output_contract": return L10n.tr("Output Contract")
        default: return L10n.tr("Engine Runtime")
        }
    }

    private func loadValues(modelID: String) -> GenerationParameterOverrides {
        let fingerprint = provider.models.first(where: { $0.id == modelID }).map {
            GenerationParameterProfileFingerprint.make(provider: provider, model: $0)
        }
        if let conversationID {
            return GenerationParameterSettingsStore.shared.sessionOverrides(
                providerID: provider.id,
                modelID: modelID,
                conversationID: conversationID,
                profileFingerprint: fingerprint
            ) ?? .init()
        }
        return GenerationParameterSettingsStore.shared.modelDefaults(
            providerID: provider.id,
            modelID: modelID,
            profileFingerprint: fingerprint
        ) ?? .init()
    }

    @ViewBuilder
    private func parameterRow(_ parameter: GenerationParameterRef) -> some View {
        if let id = parameter.id {
            let current = values.values[id]
            let supportEntry = GenerationParameterSupportPresentation.entry(for: parameter.support)
            let editable = !isReadOnly && (model.map {
                GenerationParameterAvailability.editable(
                    provider: provider,
                    model: $0,
                    parameter: parameter,
                    scope: scope,
                    identity: capabilityEvidenceIdentity
                )
            } ?? false) && supportEntry.control == .editable
            let binding = Binding<String>(
                get: { numberDrafts[id] ?? displayValue(current?.state == .value ? current?.value : nil) },
                set: { update(id: id, raw: $0, schema: parameter.valueSchema) }
            )
            let showsUnverified = generationEvidenceProjection.map {
                GenerationParameterPanelPresentation.showsUnverifiedBadge(parameter: parameter, projection: $0)
            } ?? false
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(parameterTitle(id))
                        .font(.body.weight(.medium))
                    if showsUnverified { unverifiedBadge }
                    Spacer()
                    if supportEntry.presentationClass == .notAdjustable, parameter.fixedValue != nil {
                        Text(displayValue(parameter.fixedValue))
                            .foregroundStyle(.secondary)
                    } else if parameter.valueSchema == "enum", let enumValues = parameter.enumValues, !enumValues.isEmpty {
                        Picker("", selection: binding) {
                            Text(L10n.tr("Model default")).tag("")
                            ForEach(enumDisplayValues(enumValues, current: current?.value), id: \.self) { value in
                                Text(value).tag(value)
                            }
                        }
                        .labelsHidden()
                        .accessibilityLabel(Text(parameterTitle(id)))
                        .disabled(!editable || current?.state == .omit)
                    } else if parameter.valueSchema == "boolean" {
                        Toggle("", isOn: Binding(
                            get: { if case .boolean(let value)? = current?.value, current?.state == .value { return value }; return false },
                            set: { value in updateValue(id: id, value: .boolean(value), parameter: parameter) }
                        ))
                        .labelsHidden()
                        .accessibilityLabel(Text(parameterTitle(id)))
                        .disabled(!editable || current?.state == .omit)
                    } else if parameter.valueSchema == "json-schema" {
                        TextEditor(text: Binding(
                            get: { schemaDrafts[id] ?? displayValue(current?.state == .value ? current?.value : nil) },
                            set: { updateSchema(id: id, raw: $0, parameter: parameter) }
                        ))
                        .frame(minHeight: 112)
                        .font(.system(.caption, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .background {
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(invalidSchemaIDs.contains(id)
                                    ? OriveoTheme.Palette.danger.opacity(0.10)
                                    : OriveoTheme.Palette.textPrimary.opacity(0.04))
                        }
                        .accessibilityLabel(Text(parameterTitle(id)))
                        .disabled(!editable || current?.state == .omit)
                    } else {
                        let placeholder = current?.state == .omit ? L10n.tr("Omit") : L10n.tr("Model default")
                        TextField(
                            "",
                            text: binding,
                            prompt: Text(placeholder).foregroundStyle(OriveoTheme.Palette.textTertiary)
                        )
                        .font(current?.state == .value ? .subheadline.weight(.medium) : .subheadline)
                        .foregroundStyle(OriveoTheme.Palette.textPrimary)
                        .multilineTextAlignment(.trailing)
                        .keyboardType(parameter.valueSchema == "integer" || parameter.valueSchema == "number" ? .numbersAndPunctuation : .default)
                        .accessibilityLabel(Text(parameterTitle(id)))
                        .focused($focusedField, equals: id)
                        .disabled(!editable || current?.state == .omit)
                    }
                    if editable {
                        Menu {
                            Picker(L10n.tr("Parameter behavior"), selection: behaviorBinding(id: id, current: current)) {
                                Text(L10n.tr("Model default")).tag(RowBehavior.modelDefault)
                                Text(L10n.tr("Custom", table: .chat)).tag(RowBehavior.custom)
                                Text(L10n.tr("Omit")).tag(RowBehavior.omit)
                            }
                            .pickerStyle(.inline)
                        } label: {
                            Image(systemName: current?.state == .omit ? "minus.circle.fill" : "ellipsis.circle")
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .accessibilityLabel(L10n.tr("Parameter behavior"))
                        .accessibilityValue(Text(parameterTitle(id)))
                    }
                }
                if let annotation = basicParameterAnnotation(id) {
                    Text(annotation)
                        .font(.caption)
                        .foregroundStyle(OriveoTheme.Palette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let status = statusNote(parameter) {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(parameter.support == "unknown" && !showsUnverified ? .orange : .secondary)
                }

                if supportEntry.control == .disabled, let action = supportEntry.primaryAction {
                    NavigationLink {
                        GenerationParameterSupportedModelsPage(
                            provider: provider,
                            parameterID: id,
                            parameterTitle: parameterTitle(id),
                            scope: scope,
                        )
                    } label: {
                        Text(action)
                            .font(.caption)
                            .foregroundStyle(OriveoTheme.Palette.primary)
                    }
                    .buttonStyle(.plain)
                }
            }
        } else {
            EmptyView()
        }
    }

    private enum RowBehavior: Hashable {
        case modelDefault
        case custom
        case omit
    }

    private func behaviorBinding(id: String, current: GenerationParameterOverride?) -> Binding<RowBehavior> {
        Binding(
            get: {
                switch current?.state {
                case .value: return .custom
                case .omit: return .omit
                default: return .modelDefault
                }
            },
            set: { next in
                switch next {
                case .modelDefault:
                    clearValue(id: id)
                case .custom:
                    if current?.state == .omit { clearValue(id: id) }
                    focusedField = id
                case .omit:
                    omitValue(id: id)
                }
            }
        )
    }

    private func parameterTitle(_ id: String) -> String {
        GenerationParameterVocabulary.title(id)
    }

    private func basicParameterAnnotation(_ id: String) -> String? {
        switch id {
        case "temperature":
            return L10n.tr("Higher is more creative, lower is more consistent.", table: .providers)
        case "max_output_tokens":
            return L10n.tr("The longest reply the model may write.", table: .providers)
        default:
            return nil
        }
    }

    private var unverifiedBadge: some View {
        Text(L10n.tr("Unverified", table: .providers))
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(Color.secondary.opacity(0.12))
            )
            .accessibilityLabel(L10n.tr("Unverified", table: .providers))
    }

    static func normalizedNumberInput(_ raw: String, locale: Locale = .current) -> String {
        var text = raw.trimmingCharacters(in: .whitespaces)
        if let grouping = locale.groupingSeparator, !grouping.isEmpty {
            text = text.replacingOccurrences(of: grouping, with: "")
        }
        if let decimal = locale.decimalSeparator, decimal != "." {
            text = text.replacingOccurrences(of: decimal, with: ".")
        }
        return text
    }

    static func numberDisplayText(_ number: Double) -> String {
        if number == number.rounded(), abs(number) < 1e15 {
            return String(Int64(number))
        }
        return String(number)
    }

    private func displayValue(_ value: GenerationParameterValue?) -> String {
        switch value {
        case .number(let number):
            return Self.numberDisplayText(number)
        case .string(let string): return string
        case .stringList(let strings): return strings.joined(separator: ", ")
        case .object(let object):
            guard JSONSerialization.isValidJSONObject(object.mapValues(\.foundationValue)),
                  let data = try? JSONSerialization.data(withJSONObject: object.mapValues(\.foundationValue), options: [.prettyPrinted, .sortedKeys]) else { return "" }
            return String(decoding: data, as: UTF8.self)
        default: return ""
        }
    }

    private func updateSchema(id: String, raw: String, parameter: GenerationParameterRef) {
        schemaDrafts[id] = raw
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            invalidSchemaIDs.remove(id)
            clearValue(id: id)
            return
        }
        guard let data = raw.data(using: .utf8),
              let value = try? JSONDecoder().decode(GenerationParameterValue.self, from: data),
              ProfileParamsResolver.isValidGenerationValue(value, for: parameter) else {
            invalidSchemaIDs.insert(id)
            return
        }
        invalidSchemaIDs.remove(id)
        updateValue(id: id, value: value, parameter: parameter)
    }

    private func update(id: String, raw: String, schema: String?) {
        let isNumeric = schema == "integer" || schema == "number"
        if isNumeric { numberDrafts[id] = raw }
        guard !raw.isEmpty else {
            numberDrafts[id] = nil
            values.values.removeValue(forKey: id)
            persist(); return
        }
        if isNumeric {
            if let number = Double(Self.normalizedNumberInput(raw)) {
                updateValue(id: id, value: .number(number), parameter: parameters.first { $0.id == id })
            }
            return
        }
        if schema == "string-list" {
            updateValue(id: id, value: .stringList(raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }), parameter: parameters.first { $0.id == id })
        } else {
            updateValue(id: id, value: .string(raw), parameter: parameters.first { $0.id == id })
        }
    }

    private func updateValue(id: String, value: GenerationParameterValue, parameter: GenerationParameterRef?) {
        for conflict in parameter?.conflictsWith ?? [] { values.values.removeValue(forKey: conflict) }
        for candidate in parameters where candidate.conflictsWith?.contains(id) == true {
            if let candidateID = candidate.id { values.values.removeValue(forKey: candidateID) }
        }
        values.values[id] = .init(state: .value, value: value)
        persist()
    }

    private func clearValue(id: String) {
        values.values.removeValue(forKey: id)
        persist()
    }

    private func omitValue(id: String) {
        values.values[id] = .init(state: .omit)
        persist()
    }

    private func enumDisplayValues(_ declared: [GenerationParameterValue], current: GenerationParameterValue?) -> [String] {
        var result = declared.map(displayValue)
        if let current {
            let value = displayValue(current)
            if !result.contains(value) { result.append(value) }
        }
        return result
    }

    private func statusNote(_ parameter: GenerationParameterRef) -> String? {
        GenerationParameterRowStatus.note(support: parameter.support, source: parameter.source)
    }

    private func persist() {
        guard !isReadOnly else { return }
        let fingerprint = model.map { GenerationParameterProfileFingerprint.make(provider: provider, model: $0) }
        if let conversationID {
            GenerationParameterSettingsStore.shared.setSessionOverrides(
                values,
                providerID: provider.id,
                modelID: modelID,
                conversationID: conversationID,
                profileFingerprint: fingerprint
            )
        } else {
            GenerationParameterSettingsStore.shared.setModelDefaults(
                values,
                providerID: provider.id,
                modelID: modelID,
                profileFingerprint: fingerprint
            )
        }
    }
}

private struct GenerationParameterJSONDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    let data: Data

    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
