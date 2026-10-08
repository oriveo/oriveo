import Foundation

/// What the advanced settings page needs: which parameters this model has right now, and whether each can be changed.
///
/// On the production path `production` assembles it from the existing criteria (visible set, editability, the support presentation table are the existing ones
/// and are not written again here); samples and tests use `fixture` to pass a parameter table directly, without metadata or network.
/// The chat page and the provider detail page read the same type, so their rows are never computed separately.
struct AdvancedSettingsCatalog {
    struct RowFacts: Equatable {
        var isEditable = true
        /// The price of letting a relay's locally synthesized unknown parameters through is this per-row badge.
        var showsUnverifiedBadge = false
        /// A support note for the non-regular cases; nil for the regular ones (supported / accepted), which stay silent.
        var statusNote: String?
        /// A value the model fixes.
        var fixedValueText: String?
        /// The way forward when it cannot be adjusted.
        var disabledActionTitle: String?
    }

    /// The profile used for the outbound request. Without it the page shows its empty state.
    var profile: GenerationProfileRef?
    /// The parameters visible in the current scope, in the declaration order of the parameter table.
    var parameters: [GenerationParameterRef]
    var facts: [String: RowFacts]
    /// The group-level note "these parameters are inferred from the protocol".
    var unverifiedGroupNote: String?
    /// `nil` = there are visible parameters and the page takes its normal form.
    var emptyState: GenerationParameterEmptyState?
    /// Ids of parameters that still go out; stored values not among them are "kept · not in effect".
    var activeParameterIDs: Set<String>
    /// The identifier of a self-hosted engine (llamacpp / ollama / lmstudio / vllm / openwebui).
    var engineProfile: String?

    static func production(
        provider: Provider,
        model: AIModel,
        scope: GenerationParameterEntryScope,
        identity: CapabilityEvidenceRequestIdentity?,
        isReadOnly: Bool
    ) -> AdvancedSettingsCatalog {
        let parameters = GenerationParameterPanelPresentation.visibleParameters(
            provider: provider, model: model, scope: scope, identity: identity
        )
        let projection = CapabilityEvidenceProductionAdapter.generationProjection(
            provider: provider, model: model, identity: identity
        )
        var facts: [String: RowFacts] = [:]
        var annotationInputs: [AdvancedSettingsRowAnnotations.Input] = []
        for parameter in parameters {
            guard let id = parameter.id else { continue }
            // The editability criterion has the same source as the outbound allow-list, with the presentation class ANDed on top: it only narrows, never widens.
            let supportEntry = GenerationParameterSupportPresentation.entry(for: parameter.support)
            let editable = !isReadOnly
                && GenerationParameterAvailability.editable(
                    provider: provider, model: model, parameter: parameter, scope: scope,
                    identity: identity
                )
                && supportEntry.control == .editable
            let isUnverified = GenerationParameterPanelPresentation.showsUnverifiedBadge(
                parameter: parameter, projection: projection
            )
            annotationInputs.append(.init(
                id: id, presentationClass: String(describing: supportEntry.presentationClass),
                isUnverified: isUnverified
            ))
            facts[id] = RowFacts(
                isEditable: editable,
                showsUnverifiedBadge: isUnverified,
                statusNote: GenerationParameterRowStatus.note(support: parameter.support, source: parameter.source),
                fixedValueText: supportEntry.presentationClass == .notAdjustable
                    ? parameter.fixedValue.map { GenerationParameterValueText.display($0, parameterID: id) }
                    : nil,
                disabledActionTitle: supportEntry.control == .disabled ? supportEntry.primaryAction : nil
            )
        }
        let annotations = Self.applyAnnotations(annotationInputs, to: &facts)
        // Reasoning-group rows are derived by the server from the model's thinking tiers, but this protocol's
        // wire table has no write path for them. Without a note they are grey rows that can't be tapped and
        // don't say why. Thinking on these protocols goes out only through the capability recipe.
        let wire = GenerationParameterAvailability.profile(provider: provider, model: model, identity: identity)?.wire
        for parameter in parameters where GenerationParameterAvailability.isReasoningParameter(parameter) {
            guard let id = parameter.id, wire?[id]?.isEmpty != false else { continue }
            facts[id]?.isEditable = false
            facts[id]?.statusNote = reasoningSetByThinkingNoteText
            facts[id]?.disabledActionTitle = nil
        }
        // The header sentence is about "these parameters" and is said only when `showsUnverifiedGroupNote` holds and unverified really is the tone of the whole page.
        let showsGroupNote = annotations.showsPageNote
            && GenerationParameterPanelPresentation.showsUnverifiedGroupNote(
                parameters: parameters, projection: projection
            )
        return AdvancedSettingsCatalog(
            profile: GenerationParameterAvailability.profile(provider: provider, model: model, identity: identity),
            parameters: parameters,
            facts: facts,
            unverifiedGroupNote: showsGroupNote ? unverifiedGroupNoteText : nil,
            emptyState: GenerationParameterPanelPresentation.emptyState(
                provider: provider,
                model: model,
                scope: scope,
                hasSeenNonEmptyProfile: GenerationParameterProfileHistory.shared.hasSeenNonEmptyProfile(
                    providerID: provider.id, modelID: model.id
                ),
                identity: identity
            ),
            activeParameterIDs: GenerationParameterLifecycle.activeParameterIDs(
                provider: provider, model: model, identity: identity
            ),
            engineProfile: provider.relayRequested?.engineProfile
        )
    }

    static let unverifiedGroupNoteText = L10n.tr(
        "These parameters are inferred from the protocol you chose. Oriveo hasn't verified they take effect on this connection.",
        table: .providers
    )

    /// Reasoning-group parameters have no write path in this protocol's wire table (Anthropic, Gemini):
    /// thinking there goes out only through the capability recipe, set from Thinking in Model Options.
    static let reasoningSetByThinkingNoteText = L10n.tr(
        "Thinking for this model is set under Thinking in Model Options. To keep a level as the default, pick it there and tap Set as default for this model. This row isn't sent.",
        table: .providers
    )

    /// When the whole page is the same kind of "unverified", the header says so once; rows keep a label only where they differ from the page's tone.
    /// The production path and the sample fixtures both pass through here, so both use the same decision.
    private static func applyAnnotations(
        _ inputs: [AdvancedSettingsRowAnnotations.Input], to facts: inout [String: RowFacts]
    ) -> AdvancedSettingsRowAnnotations.Output {
        let annotations = AdvancedSettingsRowAnnotations.resolve(inputs)
        for id in facts.keys where !annotations.inlineIDs.contains(id) {
            facts[id]?.showsUnverifiedBadge = false
            facts[id]?.statusNote = nil
        }
        return annotations
    }

    /// Passes a parameter table directly: every item is editable and in the outbound set.
    ///
    /// - Parameter inferredFromProtocol: the table is inferred from the protocol and not verified (the real state of custom and local engine
    ///   connections). When true the rows carry "unverified" as on a real connection and then go through the same annotation decision.
    static func fixture(
        profile: GenerationProfileRef, engineProfile: String? = nil, inferredFromProtocol: Bool = false
    ) -> AdvancedSettingsCatalog {
        let parameters = profile.parameters ?? []
        let ids = parameters.compactMap(\.id)
        var facts: [String: RowFacts] = Dictionary(ids.map { ($0, RowFacts()) }, uniquingKeysWith: { first, _ in first })
        var showsPageNote = false
        if inferredFromProtocol {
            var inputs: [AdvancedSettingsRowAnnotations.Input] = []
            for parameter in parameters {
                guard let id = parameter.id else { continue }
                let supportEntry = GenerationParameterSupportPresentation.entry(for: parameter.support)
                facts[id]?.showsUnverifiedBadge = true
                facts[id]?.statusNote = GenerationParameterRowStatus.note(
                    support: parameter.support, source: parameter.source
                )
                inputs.append(.init(
                    id: id, presentationClass: String(describing: supportEntry.presentationClass), isUnverified: true
                ))
            }
            showsPageNote = applyAnnotations(inputs, to: &facts).showsPageNote
        }
        return AdvancedSettingsCatalog(
            profile: profile,
            parameters: parameters,
            facts: facts,
            unverifiedGroupNote: showsPageNote ? unverifiedGroupNoteText : nil,
            emptyState: nil,
            activeParameterIDs: Set(ids),
            engineProfile: engineProfile
        )
    }

    /// Assembles the rows from the evaluation of real storage.
    ///
    /// - Parameter layerValues: the current values of the layer being edited. The conversation page passes the conversation override layer,
    ///   the provider detail page the model default layer.
    func rows(
        store: GenerationParameterSettingsStore,
        providerID: UUID,
        modelID: String,
        conversationID: UUID?,
        layerValues: GenerationParameterOverrides,
        profileFingerprint: String?,
        activeThinking: GenerationParameterRowModel.ThinkingContext? = nil
    ) -> [AdvancedParameterRow] {
        guard let profile else { return [] }
        func activeValues(_ overrides: GenerationParameterOverrides?) -> GenerationParameterOverrides {
            .init(values: (overrides?.values ?? [:]).filter { activeParameterIDs.contains($0.key) })
        }
        let connectionDefaults = activeValues(store.connectionDefaults(providerID: providerID))
        let resolution: GenerationParameterResolution
        let lower: GenerationParameterResolution
        let editingLayers: Set<GenerationParameterResolution.Layer>
        if let conversationID {
            resolution = store.resolveWithSources(
                transient: nil, providerID: providerID, modelID: modelID, conversationID: conversationID,
                profileFingerprint: profileFingerprint, activeParameterIDs: activeParameterIDs
            )
            lower = .modelDefaultScope(
                modelDefaults: activeValues(store.modelDefaults(
                    providerID: providerID, modelID: modelID, profileFingerprint: profileFingerprint
                )),
                connectionDefaults: connectionDefaults
            )
            editingLayers = [.singleSend, .conversation]
        } else {
            resolution = .modelDefaultScope(
                modelDefaults: activeValues(layerValues), connectionDefaults: connectionDefaults
            )
            lower = .modelDefaultScope(modelDefaults: nil, connectionDefaults: connectionDefaults)
            editingLayers = [.connectionModel]
        }
        return AdvancedParameterRow.rows(
            .init(
                parameters: parameters,
                profile: profile,
                resolution: resolution,
                activeThinking: activeThinking,
                lowerLayerValues: lower.entries.compactMapValues {
                    $0.override.state == .value ? $0.override.value : nil
                }
            ),
            editingLayers: editingLayers,
            ownValues: layerValues
        )
    }
}

/// The result of one edit on "the layer being edited". Both pages share it, so conflict handling exists once.
enum AdvancedSettingsEditing {
    static func applying(
        _ edit: AdvancedParameterEdit,
        to parameter: GenerationParameterRef,
        in values: GenerationParameterOverrides,
        parameters: [GenerationParameterRef]
    ) -> GenerationParameterOverrides {
        guard let id = parameter.id else { return values }
        var next = values
        switch edit {
        case .set(let value):
            // Two items that declare a conflict with each other do not coexist within one layer: the one set later stays. Conflicts across layers are not removed here;
            // the note on the row tells the user which item will not be sent.
            for conflict in parameter.conflictsWith ?? [] { next.values.removeValue(forKey: conflict) }
            for candidate in parameters where candidate.conflictsWith?.contains(id) == true {
                if let candidateID = candidate.id { next.values.removeValue(forKey: candidateID) }
            }
            next.values[id] = .init(state: .value, value: value)
        case .useDefault:
            next.values.removeValue(forKey: id)
        case .omit:
            next.values[id] = .init(state: .omit)
        }
        return next
    }
}

/// "If this conversation sends a message now, is thinking on, and with what budget": the one fact the advanced settings page needs to predict the thinking interplay.
///
/// On the send path the capability writer writes thinking fields after the generation parameters (shared contract
/// `outboundRules.anthropicThinking.evaluatedAfter`), so this asks the same writer:
/// the same preference ladder (`resolvedCapabilityPreferences`), the same runtime and recipe,
/// applied to an empty object to see what it writes. The interface keeps no mapping of its own from levels to budgets.
///
/// Only cases that **can be determined** are answered. A relay's Anthropic-compatible endpoint is not among them: there the level passes one more
/// evidence gate that only a real request has, the interface cannot get a reliable value, and no label is better than a guess.
enum AdvancedSettingsThinkingProbe {
    static func activeThinking(
        provider: Provider,
        model: AIModel,
        conversationID: UUID?,
        profile: GenerationProfileRef?,
        store: GenerationParameterSettingsStore
    ) -> GenerationParameterRowModel.ThinkingContext? {
        guard profile?.template == "anthropic_messages",
              let identity = CapabilityPreferenceRuntimeIdentity.make(provider: provider, model: model)
        else { return nil }
        if provider.kind == .relay {
            // Whether a relay speaks the Anthropic protocol is decided by the connection's transport field alone,
            // never by the model name.
            guard provider.relayRequested?.transport == .anthropicMessages else { return nil }
            // Reads the same ladder as the send path (`ChatManager`'s level resolution): when no layer has a
            // stored value, or the stored value is "automatic" / "off", a relay has no official default level
            // and sends no thinking.
            let intent = CapabilityPreferenceValueResolver.displaySelection(
                conversation: conversationID.flatMap {
                    store.capabilityPreferences(
                        providerID: provider.id, modelID: identity.canonicalModelID, conversationID: $0,
                        transportIdentity: identity.wireValue
                    )
                },
                skill: nil,
                connectionModel: store.capabilityPreferences(
                    providerID: provider.id, modelID: identity.canonicalModelID, conversationID: nil,
                    transportIdentity: identity.wireValue
                ),
                connection: store.connectionCapabilityPreferences(
                    providerID: provider.id, modelID: identity.canonicalModelID, transportIdentity: identity.wireValue
                )
            ).reasoningIntent
            let mode = intent.flatMap(ReasoningMode.fromIntent).flatMap { $0 == .automatic ? nil : $0 }
            return context(fromRequestFields: AnthropicService.relayThinkingRequestFields(
                modelID: model.id, reasoningMode: mode
            ))
        }
        let preferences = store.resolvedCapabilityPreferences(
            providerID: provider.id, modelID: identity.canonicalModelID, conversationID: conversationID,
            skillID: nil, transportIdentity: identity.wireValue
        )
        let fields = CapabilityRecipeRequestCompiler.previewReasoningFields(
            providerKind: provider.kind,
            modelID: model.id,
            transport: CapabilityRecipeExecution.finalTransport(
                owner: "reasoning", provider: provider, model: model
            ) ?? "",
            reasoningMode: .automatic,
            capabilityPreferences: preferences
        )
        return context(fromRequestFields: fields)
    }

    /// "Thinking is on" is read from the same list the outbound guard uses.
    static func context(
        fromRequestFields fields: [String: Any]
    ) -> GenerationParameterRowModel.ThinkingContext? {
        guard let thinking = fields["thinking"] as? [String: Any],
              let type = thinking["type"] as? String,
              ProfileParamsResolver.anthropicThinkingActiveTypes.contains(type) else { return nil }
        return .init(budgetTokens: (thinking["budget_tokens"] as? NSNumber)?.intValue)
    }
}

/// How the status labels on rows and the header note share the work.
///
/// On custom and local engine connections every parameter is inferred from the protocol: an "unverified" badge on each of a dozen rows says the same thing
/// a dozen times and hides the one row that really differs. The page's tone is said once in the header, and rows only label **exceptions**.
enum AdvancedSettingsRowAnnotations {
    struct Input: Equatable {
        let id: String
        /// The support presentation class (as in `GenerationParameterSupportPresentation`).
        let presentationClass: String
        /// Whether this row is "inferred from the protocol, not verified".
        let isUnverified: Bool
    }

    struct Output: Equatable {
        /// Whether the header says "these parameters are inferred from the protocol".
        let showsPageNote: Bool
        /// Rows that keep their own inline labels (badge and status note).
        let inlineIDs: Set<String>
    }

    static func resolve(_ rows: [Input]) -> Output {
        let unverified = rows.filter(\.isUnverified)
        // Unverified is the page's tone only when more than half of the rows are; with just a few, the header's "these parameters" does not hold and each row labels itself.
        guard unverified.count * 2 > rows.count else {
            return .init(showsPageNote: false, inlineIDs: Set(rows.map(\.id)))
        }
        // The most common presentation class within that tone; rows that are unverified too but of a different class (for example fixed ones) still label themselves.
        var counts: [String: Int] = [:]
        for row in unverified { counts[row.presentationClass, default: 0] += 1 }
        let baseline = counts.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key
        let exceptions = rows.filter { !$0.isUnverified || $0.presentationClass != baseline }
        return .init(showsPageNote: true, inlineIDs: Set(exceptions.map(\.id)))
    }
}
