import SwiftUI

// The model options web card hooks into external search services (external search services contract).
// This only assembles local facts (selectable services, default, source, reusable connections, tool calls) into shape inputs; every UI state is derived through SearchRoute functions.

@MainActor
enum ModelOptionsWebSearch {
    /// Model key remembered per conversation selection: `<connection id>:<model id>`.
    static func modelKey(provider: Provider, model: AIModel) -> String {
        "\(provider.id.uuidString):\(model.id)"
    }

    static func form(_ provider: Provider) -> WebSearchRouteInput.Form {
        switch ProviderForm.of(provider) {
        case .relay: return .relay
        case .official: return .byok
        case .subscription: return provider.kind == .grok ? .subscriptionGrok : .subscriptionCodex
        }
    }

    /// Catalog tool-call tri-state: allowed → supported; explicitly not allowed → unsupported; insufficient evidence → unknown.
    static func toolCall(provider: Provider, model: AIModel, partitionID: String) -> WebSearchRouteInput.ToolCall {
        let projection = ChatView.capabilityProjection(provider: provider, model: model, partitionID: partitionID)
        switch projection.resolution(for: "tool_call")?.requestPolicy {
        case .allow?, .allowExplicitUnverified?: return .supported
        case .omitUnsupported?, .omitRuntimeRejected?: return .unsupported
        case .omitUnknown?, nil: return .unknown
        }
    }

    /// The provider has rejected web search on this model: the panel shows the rejection copy (`webRejectedUpstream`), the same fact as the route's "native revoked or tier rejected".
    static func webRejectedUpstream(provider: Provider, model: AIModel, partitionID: String) -> Bool {
        !ModelControlsSheet.rejectedCapabilityKeys(provider: provider, model: model, partitionID: partitionID)
            .isDisjoint(with: CapabilityRecipeRequestCompiler.capabilityEvidenceKeys(capability: .web, selectedIntent: nil))
    }

    /// Local facts → facts for resolveWebSearchState (the single normalization point). The panel passes the facts it has already computed;
    /// sending and the composer preview use the per-connection variant below, and both go through the same mapping.
    static func facts(
        form: WebSearchRouteInput.Form,
        presentation: CapabilityControlPresentation,
        relayWeb: ModelOptionCapabilityShape.RelayWeb?,
        nativeRejected: Bool,
        managedWebAvailable: Bool,
        toolCall: WebSearchRouteInput.ToolCall
    ) -> WebSearchFacts {
        // Only API-key connections and Codex read the recipe web controls; every other form is none.
        let readsRecipe = form == .byok || form == .subscriptionCodex
        let recipeWeb: WebSearchFacts.RecipeWeb
        switch presentation {
        case _ where !readsRecipe: recipeWeb = .none
        case .automaticAvailable, .forceUnsupported: recipeWeb = .autoAvailable
        case .unsupported, .externalConnectorOnly: recipeWeb = .unavailable
        case .customOnly: recipeWeb = .customOnly
        case .pending, .unknown, .alwaysOn: recipeWeb = .none
        }
        let relayStatus: WebSearchFacts.RelayStatus? = switch relayWeb {
        case .localEngine?: .localEngine
        case .undecided?: .protocolUndecided
        case let .relay(fact)?: WebSearchFacts.RelayStatus(rawValue: fact.statusId.rawValue)
        case nil: nil
        }
        return .init(
            form: form, recipeWeb: recipeWeb, nativeRejected: nativeRejected, relayStatus: relayStatus,
            managedWebAvailable: managedWebAvailable, toolCall: toolCall
        )
    }

    /// Fetch facts per connection (before sending, composer preview): same sourcing as the panel (presentation resolver, relay web-switch facts, rejection negative cache, catalog evidence).
    static func facts(provider: Provider, model: AIModel, partitionID: String, webOn: Bool) -> WebSearchFacts {
        facts(
            form: form(provider),
            presentation: CapabilityControlPresentationResolver.presentation(provider: provider, model: model, capability: "web"),
            relayWeb: provider.kind == .relay ? RelayWebProbe.panelFact(provider: provider, model: model, preference: webOn) : nil,
            nativeRejected: webRejectedUpstream(provider: provider, model: model, partitionID: partitionID),
            managedWebAvailable: false,
            toolCall: toolCall(provider: provider, model: model, partitionID: partitionID)
        )
    }

    /// The single definition of panelWritable (shared across platforms): whether a conversation-level preference can be written = a runtime identity exists. The panel, sending and the chip preview all call it.
    /// Relays are judged by the fixed identity of RelayWebSwitch: it can be stored even before metadata arrives.
    static func panelWritable(provider: Provider, model: AIModel) -> Bool {
        if provider.kind == .relay { return RelayWebSwitch.transportIdentity(provider: provider, model: model) != nil }
        return ModelControlsEditability.resolve(
            providerKind: provider.kind,
            transportIdentity: CapabilityPreferenceRuntimeIdentity.make(provider: provider, model: model)?.wireValue,
            runtimeIsReadOnly: false
        ).canPersist
    }

    /// Input to resolveWebSearchState: services (names via searchServiceDisplayName), default, source, one-tap enable target.
    static func stateInput(
        _ search: WebSearchSettingsModel,
        facts: WebSearchFacts,
        panelWritable: Bool,
        webOn: Bool,
        provider: Provider,
        model: AIModel,
        stored: SearchJSON?
    ) -> WebSearchStateInput {
        let target = oneTapTarget(search, providerKind: provider.kind.rawValue)
        return .init(
            facts: facts,
            panelWritable: panelWritable,
            webOn: webOn,
            modelKey: modelKey(provider: provider, model: model),
            services: search.items.map { WebSearchStateService(id: $0.id, name: $0.displayName, status: $0.row.status) },
            defaultServiceId: search.defaultID,
            stored: stored,
            oneTapTarget: target,
            oneTapServiceName: target.map { search.catalogName($0.serviceId) }
        )
    }

    static func resolution(_ search: WebSearchSettingsModel, stored: SearchJSON?, modelKey: String) -> SearchSourceResolution {
        SearchRoute.resolveSearchSource(
            stored: stored, modelKey: modelKey,
            selectable: search.selectableItems.map { SearchSelectableService(id: $0.id, status: $0.row.status) },
            defaultServiceId: search.defaultID
        )
    }

    /// The one-tap enable target; currentProviderKind = providerKind of the current model's connection.
    static func oneTapTarget(_ search: WebSearchSettingsModel, providerKind: String) -> SearchOneTapTarget? {
        SearchRoute.oneTapReuseTarget(
            catalogAvailable: search.catalogAvailable, entries: search.entries,
            connections: search.connections, currentProviderKind: providerKind
        )
    }

    /// Stored raw value of this conversation's source: a new conversation that has not been created yet lives only in memory, otherwise read from the search partition.
    static func storedSource(_ search: WebSearchSettingsModel, conversationID: UUID) async -> SearchJSON? {
        if let draft = SearchSourceDrafts.shared.value(for: conversationID) { return draft }
        return await search.conversationSource(conversationID.uuidString)
    }

    /// Computed fresh before sending: each send reads the local source and services and uses only the cached / built-in catalog, answering through resolveWebSearchState
    /// "does this turn go external, and must native / relay web fields be suppressed?". Read-only; when false the outbound request is entirely unchanged.
    static func nativeFieldsSuppressed(
        search: WebSearchSettingsModel, provider: Provider, model: AIModel, conversationID: UUID,
        partitionID: String, panelWritable: Bool, webOn: Bool
    ) async -> Bool {
        let stored = await storedSource(search, conversationID: conversationID)
        let state = SearchRoute.resolveWebSearchState(stateInput(
            search, facts: facts(provider: provider, model: model, partitionID: partitionID, webOn: webOn),
            panelWritable: panelWritable, webOn: webOn,
            provider: provider, model: model, stored: stored
        ))
        return state.nativeFieldsSuppressed
    }

    static func nativeFieldsSuppressed(
        appState: AppState, provider: Provider, model: AIModel, conversationID: UUID, webOn: Bool
    ) async -> Bool {
        await sendState(appState: appState, provider: provider, model: model, conversationID: conversationID, webOn: webOn)
            .state.nativeFieldsSuppressed
    }

    /// Computed fresh before sending (same sourcing as nativeFieldsSuppressed): the whole state with the settings and facts read this time; the executor picks the service by route.path.
    static func sendState(
        appState: AppState, provider: Provider, model: AIModel, conversationID: UUID, webOn: Bool
    ) async -> (state: WebSearchState, search: WebSearchSettingsModel, facts: WebSearchFacts) {
        let search = WebSearchSettingsModel()
        await search.load(appState: appState)
        let stored = await storedSource(search, conversationID: conversationID)
        let facts = facts(provider: provider, model: model, partitionID: appState.sessionPartitionUID, webOn: webOn)
        let state = SearchRoute.resolveWebSearchState(stateInput(
            search, facts: facts, panelWritable: panelWritable(provider: provider, model: model), webOn: webOn,
            provider: provider, model: model, stored: stored
        ))
        return (state, search, facts)
    }

    /// Preview for the composer web chip: the same composition entry and the same inputs as the real request.
    static func previewState(
        appState: AppState, provider: Provider, model: AIModel, conversationID: UUID, webOn: Bool
    ) async -> WebSearchState {
        let search = WebSearchSettingsModel()
        await search.load(appState: appState)
        let stored = await storedSource(search, conversationID: conversationID)
        return SearchRoute.resolveWebSearchState(stateInput(
            search,
            facts: facts(provider: provider, model: model, partitionID: appState.sessionPartitionUID, webOn: webOn),
            panelWritable: panelWritable(provider: provider, model: model), webOn: webOn,
            provider: provider, model: model, stored: stored
        ))
    }
}

extension ModelOptionsWebSearch {
    /// Error card "Answer again with X": send pick_service for this conversation x current model (written to storage if the conversation already exists).
    static func pickService(serviceID: String, name: String, conversationID: UUID, modelKey: String, store: SearchServiceStore) async {
        let stored = await store.conversationSource(conversationID.uuidString)
        let next = SearchRoute.updateSearchSource(
            stored: stored, modelKey: modelKey, event: .pickService(serviceId: serviceID, serviceName: name)
        )
        try? await store.setConversationSource(next, conversationID: conversationID.uuidString)
        NotificationCenter.default.post(name: .oriveoConversationSearchSourceChanged, object: nil)
    }
}

extension Notification.Name {
    /// Error card "Switch service": the input bar opens the model options panel and pushes "Search method" (object = conversation id).
    static let oriveoOpenSearchSourcePage = Notification.Name("oriveoOpenSearchSourcePage")
    /// The per-conversation source or the search service list changed (panel source pick / toggle / one-tap enable / services added or removed in settings): the panel and composer preview recompute on this.
    static let oriveoConversationSearchSourceChanged = Notification.Name("oriveoConversationSearchSourceChanged")
}

/// "Open when external is explicitly chosen": when "One-tap enable" (oneTapArms true) or "Add search service" is tapped from the web card, remember conversation x model,
/// and send pick_service with the new service id the moment the service is added. One-shot: consumed, or cleared the next time the model options panel opens.
@MainActor
final class SearchArmAfterAdd {
    static let shared = SearchArmAfterAdd()

    /// Which panel entry started it: one-tap enable completes inside the panel; "Add search service" (web card CTA / last row of the search method page) completes in settings.
    enum Origin: Equatable { case oneTap, settings }

    struct Pending: Equatable {
        let conversationID: UUID
        let modelKey: String
        /// Written to storage for an existing conversation; to memory (SearchSourceDrafts) for a new one.
        let persisted: Bool
        let origin: Origin
    }

    private(set) var pending: Pending?

    func expect(_ pending: Pending) { self.pending = pending }

    func clear() { pending = nil }

    /// The flow that started it ended without adding (one-tap page dismissed / left settings): invalidated, so services added directly in settings afterwards do not send pick_service.
    func clear(origin: Origin) { if pending?.origin == origin { pending = nil } }

    /// Service added successfully (store = the partition used for adding): only when started from the panel, send pick_service for the remembered conversation x model (new service id).
    func serviceAdded(id: String, name: String?, store: SearchServiceStore) async {
        guard let pending else { return }
        self.pending = nil
        var stored = SearchSourceDrafts.shared.value(for: pending.conversationID)
        if stored == nil, pending.persisted { stored = await store.conversationSource(pending.conversationID.uuidString) }
        let next = SearchRoute.updateSearchSource(
            stored: stored, modelKey: pending.modelKey, event: .pickService(serviceId: id, serviceName: name)
        )
        if pending.persisted {
            try? await store.setConversationSource(next, conversationID: pending.conversationID.uuidString)
            NotificationCenter.default.post(name: .oriveoConversationSearchSourceChanged, object: nil)
        } else {
            SearchSourceDrafts.shared.set(next, for: pending.conversationID)
        }
    }
}

/// Per-conversation source for a new conversation that has no real id yet: memory only, keyed by draft id; when the conversation is created it moves to the real id and is written to disk once if non-empty,
/// then the in-memory copy is deleted. Never persisted under a draft id.
@MainActor
final class SearchSourceDrafts {
    static let shared = SearchSourceDrafts()

    private var values: [UUID: SearchSourceStored] = [:]

    func value(for id: UUID) -> SearchJSON? {
        values[id].flatMap { try? SearchJSON.parse(JSONEncoder().encode($0)) }
    }

    /// nil = clear.
    func set(_ value: SearchSourceStored?, for id: UUID) {
        values[id] = value
        NotificationCenter.default.post(name: .oriveoConversationSearchSourceChanged, object: nil)
    }

    /// Conversation created: the source under the draft id moves to the real id and is written to the search partition under the real id (only if non-empty); once written, the in-memory copy yields to storage.
    @discardableResult
    func adopt(from draftID: UUID, to conversationID: UUID, store: SearchServiceStore) -> Task<Void, Never>? {
        guard let value = values.removeValue(forKey: draftID) else { return nil }
        values[conversationID] = value
        return Task {
            try? await store.setConversationSource(value, conversationID: conversationID.uuidString)
            values[conversationID] = nil
        }
    }
}

/// "Search method" (pushed onto the model options panel's own navigation stack, no separate modal): rows come from searchSourcePickerItems; service-row subtitle uses picker.defaultSub for the default service,
/// the rest use the settings-page row status copy; last row "Add search service".
struct SearchSourcePickerSheet: View {
    let items: [SearchSourcePickerItem]
    /// Selectable services (corresponding to serviceId in items).
    let services: [WebSearchServiceItem]
    let modelName: String
    let onPickNative: () -> Void
    let onPickService: (WebSearchServiceItem) -> Void
    let onAdd: () -> Void

    var body: some View {
        List {
            Section {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    row(item)
                }
            } footer: {
                Text(WebSearchCopy.tr("picker.footer"))
            }
        }
        .navigationTitle(WebSearchCopy.tr("picker.title"))
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func row(_ item: SearchSourcePickerItem) -> some View {
        switch item {
        case let .native(selected):
            optionButton(
                title: WebSearchCopy.tr("picker.native"),
                subtitle: WebSearchCopy.format("picker.nativeSub", modelName),
                warning: false, selected: selected, logo: nil
            ) {
                onPickNative()
            }
        case let .service(serviceId, isDefault, _, selected):
            if let service = services.first(where: { $0.id == serviceId }) {
                let subtitle = isDefault
                    ? (WebSearchCopy.tr("picker.defaultSub"), false)
                    : WebSearchCopy.rowSubtitle(service)
                optionButton(
                    title: service.displayName, subtitle: subtitle.0, warning: subtitle.1, selected: selected,
                    logo: AnyView(WebSearchServiceLogo(serviceId: service.service.serviceId, custom: service.isCustom))
                ) {
                    onPickService(service)
                }
            }
        case .add:
            Button {
                onAdd()
            } label: {
                Label(WebSearchCopy.tr("main.add"), systemImage: "plus")
                    .foregroundStyle(OriveoTheme.Palette.primaryTextSafe)
            }
        }
    }

    private func optionButton(
        title: String, subtitle: String, warning: Bool, selected: Bool, logo: AnyView?, action: @escaping () -> Void
    ) -> some View {
        Button {
            action()
        } label: {
            HStack(spacing: 12) {
                if let logo { logo }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .foregroundStyle(OriveoTheme.Palette.textPrimary)
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(warning ? OriveoTheme.Palette.warningText : OriveoTheme.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if selected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(OriveoTheme.Palette.primaryTextSafe)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
