import SwiftUI
import UniformTypeIdentifiers

/// The generation parameter editor. By default it edits the long-lived provider + model values; with a conversationID it edits the current conversation's overrides.
struct GenerationParameterDefaultsSheet: View {
    /// Presentation. `embeddedPage` is the pushed sub-page behind "Model options → Advanced settings" on the chat page, hosted by
    /// `AdvancedSettingsPage` (which draws its own header and has no presets or backup, the **connection-level maintenance** features;
    /// those belong to the provider detail page and would only distract on the way to adjusting one conversation).
    /// This type keeps `embeddedPage` only so the chat page's entry does not have to change how it calls in.
    enum Presentation {
        case sheet
        case embeddedPage

        var showsConnectionTools: Bool { self == .sheet }
    }

    let provider: Provider
    let conversationID: UUID?
    var presentation: Presentation = .sheet
    /// "Model options → Advanced settings" hangs the generation owner's capability footer (status note / rejected upstream /
    /// risk notice / view supported models) at the top of this page.
    var capabilityHeader: AnyView?
    /// The chat page may still open this to look at the state, but any write is forbidden while the identity is missing.
    var isReadOnly: Bool = false

    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState
    private let initialModelID: String
    @State private var modelID: String
    @State private var values: GenerationParameterOverrides
    @State private var presetName = ""
    @State private var presetRevision = 0
    /// The current model's parameter table and rows. Rebuilt on entry, on a model change and on a metadata refresh; a value change only recomputes the rows.
    @State private var catalog: AdvancedSettingsCatalog?
    @State private var rows: [AdvancedParameterRow] = []
    @State private var expandedRows: Set<String> = []
    @State private var expandedClusters: Set<String> = []
    @State private var supportedModelsParameterID: String?
    @State private var showImporter = false
    @State private var showExporter = false
    @State private var pendingDestruction: DestructiveAction?
    @State private var importFailed = false
    @State private var exportFailed = false
    @State private var pendingPresetDeletion: GenerationParameterPreset?
    /// Applying a preset overwrites every current value, so it is confirmed before writing.
    @State private var pendingPresetApplication: GenerationParameterPreset?

    /// Destructive actions are always confirmed first. All three write to disk immediately and cannot be undone.
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
    /// The previous frame's dormant ids, stored per modelID. They are **bucketed by model** so that switching models is not reported as a "recovery":
    /// what changed then is the observed object, not this connection's capability. A missing key means this model has not been seen in this session yet: record, do not report.
    @State private var dormantSnapshots: [String: [String]] = [:]
    /// The current state of the "Developer → Additional request body" entry, refreshed on entry, on a model change and on returning from the sub-page.
    @State private var additionalBodySummary = ""
    /// Neither the number pad nor the JSON editor has a return key; without this focus the keyboard could not be dismissed.
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
        self.initialModelID = initialID
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
    /// The same production scope as the chat UI: a relay is visible and editable only when the resolver can determine the final route uniquely.
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

    private var scope: GenerationParameterEntryScope {
        conversationID == nil ? .connectionDefaults : .session
    }

    /// The parameters visible in the current scope; the criterion lives in `AdvancedSettingsCatalog.production` alone.
    private var parameters: [GenerationParameterRef] { catalog?.parameters ?? [] }

    /// Stored values are split field by field into active and dormant against the current profile.
    /// Without a model everything is dormant: nothing can be sent, and pretending otherwise would be a false state.
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

    private var rowsByID: [String: AdvancedParameterRow] {
        Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private var resetScope: AdvancedSettingsResetScope { .init(conversationID: conversationID) }

    var body: some View {
        if presentation == .embeddedPage {
            AdvancedSettingsPage(
                provider: provider,
                initialModelID: initialModelID,
                conversationID: conversationID,
                capabilityHeader: capabilityHeader,
                isReadOnly: isReadOnly
            )
        } else {
            sheetBody
        }
    }

    private var sheetBody: some View {
        // Subscribes only to the global content revision; a metadata refresh or an expired candidate TTL makes the whole sheet
        // read the facade projection again, and no per-row timer is ever created.
        let revision = CapabilityEvidenceObservationBridge.shared.contentRevision
        return NavigationStack { editor }
        .onChange(of: revision) { _, _ in rebuildCatalog() }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            guard let url = try? result.get().first else { return }
            let didAccess = url.startAccessingSecurityScopedResource()
            defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { return }
            // An import must not fail silently (wrong file, wrong format, and nothing happens), so both outcomes are acknowledged.
            // The ToastManager overlay sits **below** sheets, so a toast raised here is not seen;
            // failure therefore uses an alert, and success is visible through the refreshed values.
            if (try? GenerationParameterSyncContract.importJSON(data)) != nil {
                values = loadValues(modelID: modelID)
                presetRevision += 1
                refreshRows()
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
        sheetEditor
        // Both presentations are titled "Advanced settings": one page with two names on two paths
        // would be taken for two different things.
        .navigationTitle(L10n.tr("Advanced Settings"))
        .onAppear {
            recordSeenProfile()
            rebuildCatalog()
            syncDormantSnapshot()
            // Fires again when returning from the additional request body sub-page, so "in use / not used" never stays stale.
            refreshCustomFieldsEntry()
        }
        .onChange(of: modelID) { _, _ in
            recordSeenProfile()
            refreshCustomFieldsEntry()
        }
        .onChange(of: partition.dormantIDs.joined(separator: "|")) { _, _ in syncDormantSnapshot() }
        .toolbar {
            // "Done" sits in the standard top-right position. A destructive clear-all without confirmation must never sit there,
            // where muscle memory taps; restoring defaults is a row at the bottom of the list, with confirmation.
            ToolbarItem(placement: .confirmationAction) {
                Button(L10n.tr("Done")) { dismiss() }
                    .font(.body.weight(.semibold))
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
        // Applying a preset overwrites everything: say what will be replaced first, write after confirmation.
        .alert(
            L10n.tr("Apply this preset?", table: .providers),
            isPresented: Binding(
                get: { pendingPresetApplication != nil },
                set: { if !$0 { pendingPresetApplication = nil } }
            ),
            presenting: pendingPresetApplication
        ) { preset in
            Button(L10n.tr("Cancel"), role: .cancel) {
                pendingPresetApplication = nil
            }
            Button(L10n.tr("Apply preset", table: .providers)) {
                applyPreset(preset)
            }
        } message: { preset in
            Text(GenerationParameterPresetApplication.confirmationMessage(
                presetName: preset.name,
                overwrittenTitles: GenerationParameterPresetApplication.overwrittenParameterIDs(current: values)
                    .map(parameterTitle)
            ))
        }
        .navigationDestination(isPresented: Binding(
            get: { supportedModelsParameterID != nil },
            set: { if !$0 { supportedModelsParameterID = nil } }
        )) {
            // A disabled row **must** come with an action that can be taken; otherwise the user is stuck on a row that cannot be changed and leads nowhere.
            // This path is read-only: it answers "which model should I use then"
            // and does not switch models for the user.
            if let id = supportedModelsParameterID {
                GenerationParameterSupportedModelsPage(
                    provider: provider,
                    parameterID: id,
                    parameterTitle: parameterTitle(id),
                    scope: scope
                )
            }
        }
        // System blue seeps in from menus, pickers and DisclosureGroup chevrons,
        // while this page is pushed from the purple model options panel. The whole chain uses the brand primary color.
        // **It must sit at the end of the chain**: `.tint` only affects the subtree it wraps, and placed before `.toolbar` / `.alert`
        // those buttons take their environment from further out and stay system blue. Destructive is decided by the role and stays red.
        .tint(OriveoTheme.Palette.primary)
    }

    // MARK: - The `.sheet` presentation (opened from the provider detail page, with connection-level maintenance)

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
                        // The expanded state is "the row being edited for the previous model" and must be dropped on a model change.
                        expandedRows.removeAll()
                        rebuildCatalog()
                    }
                }

                // The sheet's title does not change with the scope;
                // the scope difference is expressed by this subtitle alone.
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
                                // Passing all `values` (including those this device considers dormant) is intentional,
                                // not a missing filter: see the comment on GenerationParameterPresetStore.save.
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
                                    // With no current values there is nothing to overwrite, so apply directly; otherwise confirm first.
                                    if GenerationParameterPresetApplication.needsConfirmation(current: values) {
                                        pendingPresetApplication = preset
                                    } else {
                                        applyPreset(preset)
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
                                            // Copies with the same name cannot be told apart in the list; one could only guess by position which is new.
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
                                // Several Buttons in one List row without a buttonStyle all trigger the same action:
                                // tapping the trash can might "apply the preset".
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
                        Text(compatibilityConflicts.sorted().map(parameterTitle).joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(.orange)
                        if !isReadOnly {
                            Button(
                                L10n.tr("Remove conflicts", table: .providers),
                                role: .destructive
                            ) {
                                pendingDestruction = .removeConflicts
                            }
                        }
                    }
                    .listRowBackground(OriveoTheme.Palette.surface)
                }

                if presentation.showsConnectionTools, provider.kind == .relay {
                    Section {
                        // A button that stays tappable without a model or identity and silently does nothing is a trap.
                        // When it cannot run it is disabled, and after running it confirms in place with one line.
                        Button(
                            L10n.tr("Clear learned capabilities", table: .providers)
                        ) {
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
                    // The container **never collapses**. There has to be something to say even without a model, hence the fallback to the "not measured yet" state
                    // (it holds just as well for a connection with no model to choose, and it is the fail-safe side).
                    emptyStateSection(catalog?.emptyState ?? .notVerified)
                    dormantSummarySection
                } else {
                    if let unverifiedGroupNote = catalog?.unverifiedGroupNote {
                        Section {
                            Text(unverifiedGroupNote)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .listRowBackground(OriveoTheme.Palette.surface)
                    }
                    // Rows and groups are the same components as on the chat page: one group per list row (all rows of the group sit in that cell, with their own hairlines).
                    ForEach(AdvancedSettingsLayout.sections(parameters: parameters)) { section in
                        Section {
                            AdvancedSettingsSectionBody(
                                section: section,
                                rows: rowsByID,
                                facts: catalog?.facts ?? [:],
                                expandedRows: $expandedRows,
                                expandedClusters: $expandedClusters,
                                inheritedLabel: L10n.tr("Connection Defaults", table: .providers),
                                useDefaultTitle: conversationID != nil
                                    ? L10n.tr("Use model default", table: .chat)
                                    : L10n.tr("Clear"),
                                focus: $focusedField,
                                onEdit: { row, edit in apply(edit, to: row) },
                                onSupportedModels: { supportedModelsParameterID = $0 }
                            )
                            .listRowInsets(EdgeInsets())
                        } header: {
                            if let title = section.title { Text(title) }
                        }
                        .listRowBackground(OriveoTheme.Palette.surface)
                    }
                    // After the runtime corrects the transport, only some of the parameters in the old scope's record are still in the new protocol's template:
                    // the panel is **not empty** then, and the remaining items have no row to render in. The summary must appear here too; covering only
                    // the empty state would leave dormant values of the non-empty state as silent orphans.
                    dormantSummarySection
                }

                if !isReadOnly, !values.values.isEmpty {
                    Section {
                        Button(resetScope.confirmButtonTitle, role: .destructive) {
                            pendingDestruction = .restoreDefaults
                        }
                    }
                    .listRowBackground(OriveoTheme.Palette.surface)
                }

                // The developer group **does not disappear when read-only**: read-only means "cannot be changed right now",
                // not "this feature does not exist". If the whole group vanished, a user who is sending would see
                // a missing feature, while its state (not used / in use) is exactly
                // what a read-only page should still show. When read-only it degrades to a status line that cannot be pushed.
                Section {
                    if isReadOnly || model == nil {
                        customFieldsRowLabel
                    } else {
                        NavigationLink { customFieldsDestination } label: {
                            customFieldsRowLabel
                        }
                    }
                } header: {
                    Text(L10n.tr("Developer", table: .providers))
                } footer: {
                    // The parameters above sync across devices; the additional request body does not.
                    Text(L10n.tr("Saved on this device only, not synced", table: .chat))
                }
                .listRowBackground(OriveoTheme.Palette.surface)
            }
            // Pushed from the model options panel, the background has to match: not one light page and one dark.
            .scrollContentBackground(.hidden)
            .background(OriveoTheme.Palette.background)
    }

    // MARK: - Developer group (entry to the additional request body)

    /// **The entry row is always there and does not disappear with the model**: a developer who switches models and no longer sees it
    /// first assumes the feature is gone or broken. Without a model, or when read-only, it degrades to a status line.
    ///
    /// The summary is read from disk once and kept in `@State`. As a computed property it would decode UserDefaults several times per frame,
    /// and none of it changes by itself during one visit.
    private func refreshCustomFieldsEntry() {
        guard let model else {
            additionalBodySummary = L10n.tr("Not in use", table: .providers)
            return
        }
        // The additional request body needs no recipe runtime identity, so this row can always be opened.
        // The officially declared fields for web search and thinking are reached through this page as well; how they are read is in `AdditionalRequestBodyEntry`
        // (falling back to the model default scope when the conversation layer has no record, with `forwardPort:` carrying records across recipe versions).
        let summary = AdditionalRequestBodyEntry.summary(
            provider: provider, model: model, conversationID: conversationID, store: .shared
        )
        additionalBodySummary = summary.text
    }

    @ViewBuilder
    private var customFieldsDestination: some View {
        // An empty string is passed without a runtime identity: the web search and thinking sections then do not appear, and the page is the additional request body alone.
        if let model {
            AdditionalRequestBodyPage(
                provider: provider,
                model: model,
                conversationID: conversationID,
                transportIdentity: CapabilityPreferenceRuntimeIdentity.make(provider: provider, model: model)?
                    .wireValue ?? ""
            )
        }
    }

    private var customFieldsRowLabel: some View {
        HStack(spacing: 8) {
            Text(L10n.tr("Additional request body", table: .chat))
                .foregroundStyle(OriveoTheme.Palette.textPrimary)
            Spacer(minLength: 8)
            Text(additionalBodySummary)
                .font(.caption)
                .foregroundStyle(OriveoTheme.Palette.textTertiary)
                .multilineTextAlignment(.trailing)
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }

    // MARK: - Criteria and copy

    /// The single copy of the scope title and description. The two sides are laid out differently (a headline inside a card in the sheet, bare text in the header
    /// when embedded), but they must say the same sentence; two copies would drift apart.
    private func scopeTitle(model: AIModel) -> String {
        conversationID == nil
            ? "\(L10n.tr("Connection Defaults", table: .providers)) · \(model.name)"
            : "\(L10n.tr("Current Conversation")) · \(model.name)"
    }

    private var scopeDetail: String {
        conversationID == nil
            ? L10n.tr("Applies to new messages on this connection with this model, until you override them in a conversation.", table: .providers)
            : L10n.tr("Only applies while this model is used in this conversation. Switching models does not copy values; switching back restores them.")
    }

    // MARK: - The four empty states

    /// Records that this device has seen a non-empty profile for this model on this connection. The criterion is the number of **declared** parameters, not visible ones:
    /// this state asks whether the profile itself ever had content; being emptied by a support filter is a different state.
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

    // MARK: - The "kept · not in effect" summary

    /// A one-line summary with "View" and "Clear", shown only when dormant values exist. Rendered in **both** the empty and the non-empty state: rendering it only when empty
    /// would leave dormant values of the non-empty state as silent orphans.
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

                Button(
                    dormantExpanded ? L10n.tr("Hide") : L10n.tr("View", table: .providers)
                ) {
                    withAnimation(.easeInOut(duration: 0.2)) { dormantExpanded.toggle() }
                }

                if dormantExpanded {
                    ForEach(split.dormantIDs, id: \.self) { id in
                        HStack {
                            // The same formatting as the parameter rows. Two copies would diverge: one parameter
                            // with one name in the list and another in the "kept" summary.
                            Text(parameterTitle(id))
                            Spacer()
                            Text(dormantValueText(split.dormant.values[id]))
                                .foregroundStyle(.secondary)
                        }
                        .font(.caption)
                    }
                }

                // Only the dormant half is deleted and values in effect stay; clearing a whole record is tombstoned by the storage layer.
                if !isReadOnly {
                    Button(L10n.tr("Clear"), role: .destructive) {
                        pendingDestruction = .clearDormant
                    }
                }
            }
            .listRowBackground(OriveoTheme.Palette.surface)
        }
    }

    /// The value column of the read-only dormant list. **Echoed as is, never converted or trimmed into another value**:
    /// the user opens "View" to confirm what exactly was set back then.
    private func dormantValueText(_ override: GenerationParameterOverride?) -> String {
        guard let override, override.state != .inherit else { return "" }
        if override.state == .omit { return L10n.tr("Omit") }
        return displayValue(override.value)
    }

    /// When the profile matches again, compatible values come back by themselves (they were never deleted, only the criterion changed), with a one-time toast.
    /// A value removed by "Clear" is not reported as recovered: it is no longer in `values`.
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

    /// A copy needs a different name: reusing the name gives two identical rows, and one could only guess by position which is new.
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
        // Title, body and button all come from the same scope value: the copy names a layer, and that layer is what gets cleared.
        case .restoreDefaults, .none: return resetScope.confirmationTitle
        }
    }

    private func destructionConfirmTitle(_ action: DestructiveAction) -> String {
        switch action {
        case .restoreDefaults: return resetScope.confirmButtonTitle
        case .clearDormant: return L10n.tr("Clear")
        case .removeConflicts: return L10n.tr("Remove conflicts", table: .providers)
        }
    }

    private func destructionMessage(_ action: DestructiveAction) -> String {
        switch action {
        case .restoreDefaults:
            return resetScope.confirmationMessage
        case .clearDormant:
            // Says which half is deleted: values in effect are not touched.
            return L10n.tr("This deletes the stored values that no longer apply to this model. This cannot be undone.", table: .providers)
        case .removeConflicts:
            return compatibilityConflicts.sorted().map(parameterTitle).joined(separator: " · ")
        }
    }

    private func perform(_ action: DestructiveAction) {
        switch action {
        case .restoreDefaults:
            resetScope.perform(
                store: .shared, providerID: provider.id, modelID: modelID, profileFingerprint: profileFingerprint
            )
            values = loadValues(modelID: modelID)
        case .clearDormant:
            values = partition.active
            dormantExpanded = false
            persist()
        case .removeConflicts:
            compatibilityConflicts.forEach { values.values.removeValue(forKey: $0) }
            persist()
        }
        expandedRows.removeAll()
        refreshRows()
        pendingDestruction = nil
    }

    private func applyPreset(_ preset: GenerationParameterPreset) {
        defer { pendingPresetApplication = nil }
        guard let fingerprint = profileFingerprint,
              let applied = GenerationParameterPresetStore.shared.apply(
                preset,
                providerID: provider.id,
                modelID: modelID,
                profileFingerprint: fingerprint,
                semanticMapping: portableSemanticMapping
              ) else { return }
        values = applied
        persist()
        refreshRows()
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

    // MARK: - Rows

    /// Rebuilds the parameter table (visible set, editability criteria, support notes), then recomputes the rows.
    private func rebuildCatalog() {
        catalog = model.map {
            AdvancedSettingsCatalog.production(
                provider: provider, model: $0, scope: scope,
                identity: capabilityEvidenceIdentity, isReadOnly: isReadOnly
            )
        }
        refreshRows()
    }

    private func refreshRows() {
        rows = catalog?.rows(
            store: .shared, providerID: provider.id, modelID: modelID, conversationID: conversationID,
            layerValues: values, profileFingerprint: profileFingerprint
        ) ?? []
    }

    private func apply(_ edit: AdvancedParameterEdit, to row: AdvancedParameterRow) {
        guard !isReadOnly else { return }
        values = AdvancedSettingsEditing.applying(edit, to: row.parameter, in: values, parameters: parameters)
        persist()
        refreshRows()
    }

    /// Row title and accessibility label share one copy, so VoiceOver does not read a name different from the one on screen.
    private func parameterTitle(_ id: String) -> String {
        GenerationParameterVocabulary.title(id)
    }

    /// Folds user input back into a parseable decimal literal. The single implementation is in `GenerationParameterValueText`.
    static func normalizedNumberInput(_ raw: String, locale: Locale = .current) -> String {
        GenerationParameterValueText.normalizedNumberInput(raw, locale: locale)
    }

    /// The single implementation of number display, shared by tests and the panel.
    static func numberDisplayText(_ number: Double) -> String {
        GenerationParameterValueText.number(number)
    }

    private func displayValue(_ value: GenerationParameterValue?) -> String {
        GenerationParameterValueText.editingText(value)
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