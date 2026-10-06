import SwiftUI
import UIKit

/// A self-drawn page header: back, title, subtitle, and an action at the top right.
///
/// These pages are pushed from the model options panel, where the system navigation bar would bring a third set of text sizes and a separator;
/// the header draws itself and also guarantees the top spacing (sheet content without a navigation bar must not touch the grabber).
struct AdvancedPageHeader: View {
    let title: String
    let subtitle: String
    var trailingTitle: String?
    var trailingEnabled: Bool = true
    let onBack: () -> Void
    var onTrailing: (() -> Void)?

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(OriveoTheme.Palette.textPrimary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(L10n.tr("Back")))

            VStack(spacing: 1) {
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(OriveoTheme.Palette.textPrimary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(OriveoTheme.Palette.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)

            if let trailingTitle, let onTrailing {
                Button(action: onTrailing) {
                    Text(trailingTitle)
                        .font(.system(size: 15))
                        .foregroundStyle(OriveoTheme.Palette.primaryTextSafe)
                        .frame(minWidth: 56, minHeight: 44, alignment: .trailing)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!trailingEnabled)
                .opacity(trailingEnabled ? 1 : 0.4)
            } else {
                Color.clear.frame(width: 56, height: 44)
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 18)
        // A sheet without a navigation bar: the content root keeps at least 24pt at the top, or the title touches the grabber.
        .padding(.top, 24)
        .padding(.bottom, 4)
    }
}

/// Lets a page with a self-drawn header still be popped by swiping from the left edge inside a sheet's NavigationStack.
///
/// Once the system back button is hidden, the system's pop gesture is refused by its own delegate. While the page is visible the delegate is replaced by
/// "allow when the stack holds more than one page", and restored on leaving. The app-level edge swipe (`SwipeBackCoordinator`,
/// attached to the window and driving the navigation stack under the sheet) is turned off meanwhile: otherwise one swipe would pop
/// the page in the sheet and the chat page beneath it together.
struct SheetInteractivePopEnabler: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ controller: Controller, context: Context) {}

    final class Controller: UIViewController, UIGestureRecognizerDelegate {
        private weak var boundNavigationController: UINavigationController?
        private weak var originalDelegate: UIGestureRecognizerDelegate?

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            bind()
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            unbind()
        }

        func bind() {
            guard let navigationController,
                  let gesture = navigationController.interactivePopGestureRecognizer else { return }
            if gesture.delegate !== self { originalDelegate = gesture.delegate }
            boundNavigationController = navigationController
            gesture.delegate = self
            gesture.isEnabled = true
            SwipeBackCoordinator.shared.isBackSwipeEnabled = false
        }

        func unbind() {
            if let gesture = boundNavigationController?.interactivePopGestureRecognizer, gesture.delegate === self {
                gesture.delegate = originalDelegate
            }
            boundNavigationController = nil
            SwipeBackCoordinator.shared.isBackSwipeEnabled = true
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let navigation = boundNavigationController else { return false }
            // The root page has nowhere to go back to; starting again during a transition would corrupt the navigation stack.
            return navigation.viewControllers.count > 1 && navigation.transitionCoordinator == nil
        }
    }
}

/// "Model options → Advanced settings" on the chat page.
///
/// Each row shows the **value really in effect and where it comes from** (`resolveWithSources`), not "what this layer stores":
/// a temperature set in the model default is visible here, and it is clear that this conversation did not change it.
struct AdvancedSettingsPage: View {
    let provider: Provider
    let conversationID: UUID?
    var capabilityHeader: AnyView?
    var isReadOnly: Bool
    let store: GenerationParameterSettingsStore
    /// Samples and tests pass a parameter table directly; on the production path it is nil and assembled from the existing criteria.
    let fixtureCatalog: AdvancedSettingsCatalog?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(AppState.self) private var appState: AppState?

    @State private var modelID: String
    /// The values stored by the layer being edited itself (the conversation override layer; the model default layer while the conversation is not saved yet).
    @State private var values = GenerationParameterOverrides()
    @State private var catalog: AdvancedSettingsCatalog?
    @State private var rows: [AdvancedParameterRow] = []
    @State private var activeThinking: GenerationParameterRowModel.ThinkingContext?
    @State private var expandedRows: Set<String>
    @State private var expandedClusters: Set<String>
    @State private var pendingReset: AdvancedSettingsResetScope?
    @State private var showsClearDormantConfirmation = false
    @State private var dormantExpanded = false
    @State private var bodySummary: (text: String, emphasized: Bool) = ("", false)
    @State private var showsAdditionalBody = false
    @State private var supportedModelsParameterID: String?
    @State private var dormantSnapshots: [String: [String]] = [:]
    @FocusState private var focusedField: String?

    init(
        provider: Provider,
        initialModelID: String? = nil,
        conversationID: UUID? = nil,
        capabilityHeader: AnyView? = nil,
        isReadOnly: Bool = false,
        store: GenerationParameterSettingsStore = .shared,
        fixtureCatalog: AdvancedSettingsCatalog? = nil,
        expandedRows: Set<String> = [],
        expandedClusters: Set<String> = []
    ) {
        self.provider = provider
        self.conversationID = conversationID
        self.capabilityHeader = capabilityHeader
        self.isReadOnly = isReadOnly
        self.store = store
        self.fixtureCatalog = fixtureCatalog
        _modelID = State(initialValue: initialModelID
            ?? provider.models.first(where: \.isDefault)?.id
            ?? provider.models.first?.id
            ?? "")
        _expandedRows = State(initialValue: expandedRows)
        _expandedClusters = State(initialValue: expandedClusters)
    }


    private var model: AIModel? { provider.models.first { $0.id == modelID } }
    private var scope: GenerationParameterEntryScope { conversationID == nil ? .connectionDefaults : .session }
    private var resetScope: AdvancedSettingsResetScope { .init(conversationID: conversationID) }
    private var profileFingerprint: String? {
        model.map { GenerationParameterProfileFingerprint.make(provider: provider, model: $0) }
    }
    private var rowsByID: [String: AdvancedParameterRow] {
        Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// The same production scope as the chat UI: a relay is visible and editable only when the resolver can determine the final route uniquely.
    private var capabilityEvidenceIdentity: CapabilityEvidenceRequestIdentity? {
        guard let model, let appState else { return nil }
        if provider.kind == .relay {
            return CapabilityEvidenceProductionAdapter.uiDispatchIdentity(
                provider: provider, model: model, partitionID: appState.sessionPartitionUID
            )
        }
        return CapabilityEvidenceRequestIdentity.make(
            provider: provider, model: model, partitionID: appState.sessionPartitionUID,
            hasExplicitValue: false
        )
    }

    var body: some View {
        // Subscribes only to the global content revision: after a metadata refresh the page reads everything once, and no per-row timer is created.
        let revision = CapabilityEvidenceObservationBridge.shared.contentRevision
        VStack(spacing: 0) {
            AdvancedPageHeader(
                title: L10n.tr("Advanced Settings"),
                subtitle: headerSubtitle,
                trailingTitle: isReadOnly ? nil : L10n.tr("Reset", table: .providers),
                trailingEnabled: !values.values.isEmpty,
                onBack: { dismiss() },
                onTrailing: { pendingReset = resetScope }
            )
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if let capabilityHeader { capabilityHeader }
                    if conversationID == nil, provider.models.count > 1 { modelPickerCard }
                    if let note = catalog?.unverifiedGroupNote {
                        ModelControlNote(text: note).padding(.horizontal, 6)
                    }
                    if let catalog, !catalog.parameters.isEmpty {
                        ForEach(AdvancedSettingsLayout.sections(parameters: catalog.parameters)) { section in
                            sectionView(section)
                        }
                    } else {
                        // The container never collapses: there has to be something to say even without a model, hence the fallback to "not measured yet".
                        emptyStateCard(catalog?.emptyState ?? .notVerified)
                    }
                    dormantCard
                    additionalBodySection
                    if conversationID != nil, catalog?.parameters.isEmpty == false { legend }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 32)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .background(OriveoTheme.Palette.background)
        .background(SheetInteractivePopEnabler())
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .toolbar {
            // Neither the number pad nor the multi-line input has a return key; without this the keyboard could not be dismissed.
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button(L10n.tr("Done")) { focusedField = nil }
                    .font(.body.weight(.semibold))
            }
        }
        .onAppear {
            reload()
            // Fires again when returning from the additional request body sub-page, so the summary never stays stale.
            refreshBodySummary()
        }
        .onChange(of: revision) { _, _ in reload() }
        .alert(
            pendingReset?.confirmationTitle ?? "",
            isPresented: Binding(get: { pendingReset != nil }, set: { if !$0 { pendingReset = nil } }),
            presenting: pendingReset
        ) { scope in
            Button(L10n.tr("Cancel"), role: .cancel) {
                pendingReset = nil
            }
            Button(scope.confirmButtonTitle, role: .destructive) {
                performReset(scope)
            }
        } message: { scope in
            Text(scope.confirmationMessage)
        }
        .alert(L10n.tr("Clear"), isPresented: $showsClearDormantConfirmation) {
            Button(L10n.tr("Cancel"), role: .cancel) {}
            Button(L10n.tr("Clear"), role: .destructive) {
                clearDormant()
            }
        } message: {
            Text(L10n.tr(
                "This deletes the stored values that no longer apply to this model. This cannot be undone.",
                table: .providers
            ))
        }
        .navigationDestination(isPresented: $showsAdditionalBody) {
            if let model {
                AdditionalRequestBodyPage(
                    provider: provider, model: model, conversationID: conversationID,
                    transportIdentity: CapabilityPreferenceRuntimeIdentity.make(provider: provider, model: model)?
                        .wireValue ?? "",
                    store: store
                )
            }
        }
        .navigationDestination(isPresented: Binding(
            get: { supportedModelsParameterID != nil },
            set: { if !$0 { supportedModelsParameterID = nil } }
        )) {
            if let id = supportedModelsParameterID {
                GenerationParameterSupportedModelsPage(
                    provider: provider,
                    parameterID: id,
                    parameterTitle: GenerationParameterVocabulary.title(id),
                    scope: scope
                )
            }
        }
        // The whole chain uses the brand primary color; it must sit at the end of the chain because `.tint` only affects the subtree it wraps.
        .tint(OriveoTheme.Palette.primary)
    }

    private var headerSubtitle: String {
        let name = model?.name ?? modelID
        let scopeWord = conversationID != nil
            ? L10n.tr("This conversation only", table: .chat)
            : L10n.tr("Model defaults", table: .chat)
        return "\(name) · \(scopeWord)"
    }

    // MARK: - Groups

    @ViewBuilder
    private func sectionView(_ section: AdvancedSettingsLayout.Section) -> some View {
        if let title = section.title {
            AdvancedSectionLabel(title: title)
        }
        AdvancedSettingsSectionBody(
            section: section,
            rows: rowsByID,
            facts: catalog?.facts ?? [:],
            expandedRows: $expandedRows,
            expandedClusters: $expandedClusters,
            inheritedLabel: L10n.tr("Your default", table: .chat),
            useDefaultTitle: conversationID != nil
                ? L10n.tr("Use model default", table: .chat)
                : L10n.tr("Clear"),
            focus: $focusedField,
            onEdit: { row, edit in apply(edit, to: row) },
            onSupportedModels: { supportedModelsParameterID = $0 }
        )
        .modelControlSurface()
        if section.id == "common", let footnote = AdvancedSettingsLayout.commonFootnote(
            rows: rows,
            commonIDs: GenerationParameterPresentationFacts.commonParameterIDs,
            engineName: AdditionalRequestBodyInspector.engineName(engineProfile: catalog?.engineProfile)
        ) {
            Text(footnote)
                .font(.system(size: 12.5))
                .foregroundStyle(OriveoTheme.Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 6)
        }
    }

    // MARK: - Other cards

    /// While the conversation is not saved yet `conversationID` is still nil and this page is the model default scope, so the model picker has to stay.
    private var modelPickerCard: some View {
        HStack(spacing: 8) {
            Text(L10n.tr("Model", table: .providers))
                .font(.system(size: 16))
                .foregroundStyle(OriveoTheme.Palette.textPrimary)
            Spacer(minLength: 8)
            Picker("", selection: Binding(
                get: { modelID },
                set: { next in
                    modelID = next
                    expandedRows.removeAll()
                    reload()
                    refreshBodySummary()
                }
            )) {
                ForEach(provider.models) { model in Text(model.name).tag(model.id) }
            }
            .labelsHidden()
            .accessibilityLabel(Text(L10n.tr("Model", table: .providers)))
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
        .modelControlSurface()
    }

    private func emptyStateCard(_ state: GenerationParameterEmptyState) -> some View {
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

    private var dormantPartition: GenerationParameterLifecycle.Partition {
        GenerationParameterLifecycle.partition(
            activeParameterIDs: catalog?.activeParameterIDs ?? [], values: values
        )
    }

    /// "Kept · not in effect": after a protocol change the old values are still there, they just cannot be sent right now. Rendered in the non-empty state too,
    /// or those values would become orphans that can be neither seen nor cleared.
    @ViewBuilder
    private var dormantCard: some View {
        let split = dormantPartition
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
                        .foregroundStyle(OriveoTheme.Palette.primaryTextSafe)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if dormantExpanded {
                    ForEach(split.dormantIDs, id: \.self) { id in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(GenerationParameterVocabulary.title(id))
                                .foregroundStyle(OriveoTheme.Palette.textSecondary)
                            Spacer(minLength: 8)
                            // Echoed as is, without conversion: the user opens this to confirm what exactly was set back then.
                            Text(dormantValueText(split.dormant.values[id]))
                                .foregroundStyle(OriveoTheme.Palette.textTertiary)
                        }
                        .font(.caption)
                    }
                }
                if !isReadOnly {
                    Button {
                        showsClearDormantConfirmation = true
                    } label: {
                        Text(L10n.tr("Clear"))
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(OriveoTheme.Palette.danger)
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .modelControlSurface()
        }
    }

    private func dormantValueText(_ override: GenerationParameterOverride?) -> String {
        guard let override, override.state != .inherit else { return "" }
        if override.state == .omit { return L10n.tr("Omit") }
        return GenerationParameterValueText.editingText(override.value)
    }

    // MARK: - Write it yourself: additional request body

    /// This row does not disappear when read-only: read-only means "cannot be changed right now", not "this feature does not exist".
    /// When read-only it degrades to a status line without a chevron; a chevron would promise a place that cannot be reached right now.
    @ViewBuilder
    private var additionalBodySection: some View {
        let canOpen = !isReadOnly && model != nil
        AdvancedSectionLabel(title: L10n.tr("Write your own", table: .chat))
        Group {
            if canOpen {
                Button { showsAdditionalBody = true } label: {
                    additionalBodyRow(showsChevron: true)
                }
                .buttonStyle(.plain)
            } else {
                additionalBodyRow(showsChevron: false)
            }
        }
        .modelControlSurface()
        // Parameters in advanced settings sync across devices and this item does not: that should be known before going in.
        Text(L10n.tr("Saved on this device only, not synced", table: .chat))
            .font(.system(size: 12.5))
            .foregroundStyle(OriveoTheme.Palette.textTertiary)
            .padding(.horizontal, 6)
    }

    private func additionalBodyRow(showsChevron: Bool) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.tr("Additional request body", table: .chat))
                    .font(.system(size: 16))
                    .foregroundStyle(OriveoTheme.Palette.textPrimary)
                Text(L10n.tr("Add fields that aren’t listed above, as JSON", table: .chat))
                    .font(.system(size: 12.5))
                    .foregroundStyle(OriveoTheme.Palette.textTertiary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            AdvancedSummaryText(text: bodySummary.text, emphasized: bodySummary.emphasized)
            if showsChevron { AdvancedChevron() }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: 66, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var legend: some View {
        HStack(spacing: 14) {
            legendItem(OriveoTheme.Palette.primary.opacity(0.55), L10n.tr("Changed in this conversation", table: .chat))
            legendItem(
                OriveoTheme.Palette.textTertiary.opacity(0.45),
                L10n.tr("Using the model default you set", table: .chat)
            )
        }
        .padding(.horizontal, 6)
        .padding(.top, 4)
        .accessibilityElement(children: .combine)
    }

    private func legendItem(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 9, height: 9)
            Text(text)
                .font(.system(size: 12.5))
                .foregroundStyle(OriveoTheme.Palette.textTertiary)
        }
    }

    // MARK: - Reading and writing

    private func makeCatalog() -> AdvancedSettingsCatalog? {
        if let fixtureCatalog { return fixtureCatalog }
        guard let model else { return nil }
        return .production(
            provider: provider, model: model, scope: scope,
            identity: capabilityEvidenceIdentity, isReadOnly: isReadOnly
        )
    }

    /// Reads from disk and rebuilds the parameter table and rows. Runs only on entry, on a model change and on a metadata refresh; value changes go through `refreshRows`.
    private func reload() {
        if let conversationID {
            values = store.sessionOverrides(
                providerID: provider.id, modelID: modelID, conversationID: conversationID,
                profileFingerprint: profileFingerprint
            ) ?? .init()
        } else {
            values = store.modelDefaults(
                providerID: provider.id, modelID: modelID, profileFingerprint: profileFingerprint
            ) ?? .init()
        }
        catalog = makeCatalog()
        // Whether thinking is on does not change by itself during one visit (it is set on the previous page), so reading it once on entry is enough.
        activeThinking = model.flatMap {
            AdvancedSettingsThinkingProbe.activeThinking(
                provider: provider, model: $0, conversationID: conversationID,
                profile: catalog?.profile, store: store
            )
        }
        if fixtureCatalog == nil, let model {
            // Records that this device has seen a non-empty profile for this model: the empty state uses it to tell "not measured yet" from "had content once".
            let declared = GenerationParameterAvailability.profile(provider: provider, model: model)?
                .parameters?.count ?? 0
            GenerationParameterProfileHistory.shared.recordSeenProfile(
                providerID: provider.id, modelID: model.id, parameterCount: declared
            )
        }
        refreshRows()
        syncDormantSnapshot()
    }

    private func refreshRows() {
        rows = catalog?.rows(
            store: store, providerID: provider.id, modelID: modelID, conversationID: conversationID,
            layerValues: values, profileFingerprint: profileFingerprint, activeThinking: activeThinking
        ) ?? []
    }

    private func apply(_ edit: AdvancedParameterEdit, to row: AdvancedParameterRow) {
        guard !isReadOnly, let catalog else { return }
        values = AdvancedSettingsEditing.applying(
            edit, to: row.parameter, in: values, parameters: catalog.parameters
        )
        persist()
        refreshRows()
    }

    private func persist() {
        guard !isReadOnly else { return }
        if let conversationID {
            store.setSessionOverrides(
                values, providerID: provider.id, modelID: modelID, conversationID: conversationID,
                profileFingerprint: profileFingerprint
            )
        } else {
            store.setModelDefaults(
                values, providerID: provider.id, modelID: modelID, profileFingerprint: profileFingerprint
            )
        }
    }

    private func performReset(_ scope: AdvancedSettingsResetScope) {
        guard !isReadOnly else { return }
        focusedField = nil
        scope.perform(
            store: store, providerID: provider.id, modelID: modelID, profileFingerprint: profileFingerprint
        )
        pendingReset = nil
        expandedRows.removeAll()
        reload()
    }

    private func clearDormant() {
        values = dormantPartition.active
        dormantExpanded = false
        persist()
        refreshRows()
        syncDormantSnapshot()
    }

    /// When the profile matches again, compatible values come back by themselves (they were never deleted, only the criterion changed), with a one-time notice.
    private func syncDormantSnapshot() {
        let current = dormantPartition.dormantIDs
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

    private func refreshBodySummary() {
        guard let model else {
            bodySummary = ("", false)
            return
        }
        bodySummary = AdditionalRequestBodyEntry.summary(
            provider: provider, model: model, conversationID: conversationID, store: store
        )
    }
}

/// The summary on the right of the "Additional request body" entry row. Shared by the chat page and the provider detail page.
enum AdditionalRequestBodyEntry {
    static func summary(
        provider: Provider, model: AIModel, conversationID: UUID?, store: GenerationParameterSettingsStore
    ) -> (text: String, emphasized: Bool) {
        let configuration = store.effectiveAdditionalRequestBody(
            providerID: provider.id,
            modelID: CapabilityPreferenceRuntimeIdentity.canonicalModelID(provider: provider, model: model),
            conversationID: conversationID
        )
        if configuration.isActive {
            let count = AdditionalRequestBodyInspector.inspect(configuration.rawJSON).addedCount
            return (String(format: L10n.tr("%lld fields", table: .chat), count), true)
        }
        // The officially declared fields for web search and thinking are reached through this page as well; while they are in use this row must not say "not used".
        if officialCustomFieldsInUse(provider: provider, model: model, conversationID: conversationID, store: store) {
            return (L10n.tr("In use", table: .providers), true)
        }
        return (L10n.tr("Not in use", table: .providers), false)
    }

    static func officialCustomFieldsInUse(
        provider: Provider, model: AIModel, conversationID: UUID?, store: GenerationParameterSettingsStore
    ) -> Bool {
        guard let identity = CapabilityPreferenceRuntimeIdentity.make(provider: provider, model: model) else {
            return false
        }
        return GenerationParameterSettingsStore.localCustomOwnerNamespaces.contains { _, namespace in
            // Falls back to the model default scope when the conversation layer has no record (the same reading as the send path), and carries fields written under an older recipe version forward.
            store.effectiveLocalCustomConfiguration(
                providerID: provider.id, modelID: identity.canonicalModelID,
                conversationID: conversationID, transportIdentity: identity.wireValue,
                namespace: namespace,
                forwardPort: .init(providerKind: provider.kind, schemaModelID: model.id)
            ).mode == .custom
        }
    }
}
