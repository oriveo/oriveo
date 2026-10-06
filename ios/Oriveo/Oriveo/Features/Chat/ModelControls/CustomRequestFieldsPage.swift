import SwiftUI

/// The editor for officially declared fields of web search and thinking (Advanced settings → Additional request body → Web search and thinking fields).
///
/// Generation parameters have no "officially declared fields"; `AdditionalRequestBodyPage` covers them.
/// This page holds the two sections that are validated against the field schema delivered by the catalog.
///
/// A JSON entry on each capability card would put a **very rarely used escape hatch**
/// on the same level as controls used all the time. The chain is therefore
/// panel → advanced settings → developer → this page, with depth following frequency, and this page has to hold
/// **all** owners of one connection × model × transport at once, one section per owner.
///
/// The page works out by itself which owners exist (the caller passes no owner or binding): two copies of that criterion, one at the entry and one in the content,
/// are how "it opens but cannot be changed" happens.
struct CustomRequestFieldsPage: View {
    @Environment(AppState.self) private var appState

    let provider: Provider
    let model: AIModel
    let conversationID: UUID?
    let transportIdentity: String

    /// Drafts per owner. **The only editing state**: the mode is not chosen explicitly but derived from the content here
    /// (non-empty = custom, cleared = automatic), so the page needs no second mode state.
    @State private var drafts: [String: String] = [:]
    /// Kept for existing data only: "custom with an empty raw value" could be stored once (deliberately fail-closed). The current UI cannot produce it,
    /// but data stored that way must be shown as it is; otherwise the user sees a blank page and cannot send messages.
    @State private var legacyEmptyCustomOwners: Set<String> = []
    @State private var pendingRemovalOwner: String?
    /// The sections and the schema snapshot, fixed on entering the page.
    ///
    /// Fixing them at that moment has two reasons: clearing the content must not make the section vanish on the spot, since the user is still editing and
    /// keyboard and focus would go with it; and `hasSafeCustomSchema` resolves metadata each time, which in the body
    /// would run three times per frame. The schema does not change during one visit, so a snapshot is enough.
    @State private var sections: [String] = []
    @State private var schemaOwners: Set<String> = []
    @State private var didLoad = false
    @FocusState private var focusedOwner: String?
    @Environment(\.dismiss) private var dismiss

    /// The fixed mapping from owner to local storage namespace. The order is the section order on the page (the same as the cards on the panel).
    /// Generation parameters are not here: they have no "officially declared fields" and belong to the additional request body page.
    private static let ownerNamespaces: [(owner: String, namespace: String)] = [
        ("web", "webPatch"),
        ("reasoning", "reasoningPatch"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            AdvancedPageHeader(
                title: L10n.tr("Web search and thinking fields", table: .chat),
                subtitle: model.name,
                onBack: { dismiss() }
            )
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if sections.isEmpty {
                        emptyCard
                    } else {
                        ForEach(sections, id: \.self) { owner in
                            ownerCard(owner)
                        }
                        // This sentence is only accurate for the sections above that are validated against the official declaration; the additional request body has its own note.
                        ModelControlNote(
                            text: L10n.tr(
                                "Fields are added to the request exactly as written. Only fields this provider officially declares are supported; mistakes can make requests fail. Drafts stay on this device.",
                                table: .chat
                            ),
                            systemImage: "iphone.and.arrow.forward"
                        )
                        .padding(.horizontal, 4)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 6)
                .padding(.bottom, 32)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .background(OriveoTheme.Palette.background)
        .background(SheetInteractivePopEnabler())
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .toolbar {
            // TextEditor has no return key; without this the keyboard could not be dismissed.
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button(L10n.tr("Done")) { focusedOwner = nil }
                    .font(.body.weight(.semibold))
            }
        }
        .onAppear(perform: load)
        .alert(
            L10n.tr("Remove custom request fields?", table: .chat),
            isPresented: Binding(
                get: { pendingRemovalOwner != nil },
                set: { if !$0 { pendingRemovalOwner = nil } }
            ),
            presenting: pendingRemovalOwner
        ) { owner in
            Button(L10n.tr("Keep custom fields", table: .chat), role: .cancel) { pendingRemovalOwner = nil }
            Button(L10n.tr("Remove custom fields", table: .chat), role: .destructive) {
                drafts[owner] = ""
                legacyEmptyCustomOwners.remove(owner)
                persist(owner)
                pendingRemovalOwner = nil
            }
        } message: { owner in
            // As above: the confirmation must say **what this particular action really deletes**.
            Text(String(
                format: conversationID != nil
                    ? L10n.tr(
                        "This removes the custom fields for %@ on this conversation, connection, model and transport. This cannot be undone.",
                        table: .chat
                    )
                    : L10n.tr(
                        "This removes the custom fields for %@ on this connection, model and transport. This cannot be undone.",
                        table: .chat
                    ),
                title(for: owner)
            ))
        }
    }

    // MARK: - Sections

    /// Section titles use the **user's words**, not web/reasoning/generation: this page is read by developers, but they still
    /// arrive through the concepts "web search / thinking / parameters".
    private func title(for owner: String) -> String {
        switch owner {
        case "web": return L10n.tr("Web Search", table: .chat)
        default: return L10n.tr("Thinking Mode", table: .chat)
        }
    }

    // MARK: - Sections for officially declared fields

    private var emptyCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            ModelControlNote(
                text: L10n.tr(
                    "Custom fields need an official field schema for this exact model and transport.",
                    table: .chat
                ),
                systemImage: "info.circle"
            )
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modelControlSurface()
    }

    @ViewBuilder
    private func ownerCard(_ owner: String) -> some View {
        let raw = drafts[owner] ?? ""
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 8) {
                Text(title(for: owner))
                    .font(.body.weight(.semibold))
                    .foregroundStyle(OriveoTheme.Palette.textPrimary)
                Spacer(minLength: 8)
                // "In effect" is this section's only statement of state: the mode is derived from the content and there is no second switch to look at.
                if !trimmed.isEmpty {
                    Text(L10n.tr("In use", table: .providers))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(OriveoTheme.Palette.textSecondary)
                }
            }

            if !hasSchema(owner) {
                ModelControlNote(
                    text: L10n.tr(
                        "This connection declares no custom fields for this control.",
                        table: .chat
                    ),
                    systemImage: "info.circle"
                )
            }

            // Existing "custom with empty content": the send path still fails closed, and the page has to say so;
            // otherwise the user only sees "cannot send" while this page looks unconfigured.
            if trimmed.isEmpty, legacyEmptyCustomOwners.contains(owner) {
                VStack(alignment: .leading, spacing: 9) {
                    ModelControlNote(
                        text: L10n.tr(
                            "Custom is selected but empty, so messages using this control will fail to send.",
                            table: .chat
                        ),
                        systemImage: "exclamationmark.triangle.fill",
                        tone: OriveoTheme.Palette.danger
                    )
                    Button {
                        legacyEmptyCustomOwners.remove(owner)
                        persist(owner)
                    } label: {
                        Text(L10n.tr("Switch back to automatic", table: .chat))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(OriveoTheme.Palette.danger)
                    }
                    .buttonStyle(.plain)
                }
            }

            TextEditor(text: Binding(
                get: { drafts[owner] ?? "" },
                // Drafts are saved as they are typed. Writing only on an Apply button would lose thirty lines of JSON when the page is closed.
                set: { next in
                    drafts[owner] = next
                    persist(owner)
                }
            ))
            .font(.system(size: 13, design: .monospaced))
            .scrollContentBackground(.hidden)
            .padding(12)
            .frame(minHeight: 150)
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(OriveoTheme.Palette.textPrimary.opacity(0.04))
            }
            .focused($focusedOwner, equals: owner)
            .accessibilityLabel(Text(L10n.tr("Custom request fields JSON", table: .chat)))

            validation(owner)

            riskNotes(owner)

            if let url = documentationURL(owner) {
                Link(destination: url) {
                    ModelControlInlineActionLabel(
                        title: L10n.tr("Open official provider documentation", table: .chat),
                        systemImage: "book"
                    )
                }
            } else if provider.kind == .relay {
                ModelControlNote(
                    text: L10n.tr("For this connection, use the documentation supplied by its administrator.", table: .chat),
                    systemImage: "book"
                )
            }

            // The scope follows the entry: coming from the chat page this edits the conversation, coming from the provider detail page
            // (`conversationID == nil`) it edits this model's default. With one sentence shared by both paths,
            // a detail-page user would believe "this conversation" is being changed, where there is no conversation.
            ModelControlNote(
                text: conversationID != nil
                    ? L10n.tr("Scope: this conversation, connection, model, and transport.", table: .chat)
                    : L10n.tr(
                        "Scope: this model on this connection, used as the default for its conversations.",
                        table: .chat
                    ),
                systemImage: "scope"
            )

            Button(role: .destructive) {
                pendingRemovalOwner = owner
            } label: {
                ModelControlInlineActionLabel(
                    title: L10n.tr("Remove custom fields", table: .chat),
                    systemImage: "trash",
                    tint: OriveoTheme.Palette.danger
                )
            }
            .buttonStyle(.plain)
            .disabled(trimmed.isEmpty && !legacyEmptyCustomOwners.contains(owner))
            .opacity(trimmed.isEmpty && !legacyEmptyCustomOwners.contains(owner) ? 0.4 : 1)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modelControlSurface()
    }

    @ViewBuilder
    private func riskNotes(_ owner: String) -> some View {
        ForEach(CapabilityRecipeExecution.customControlRiskTiers(
            owner: owner, providerKind: provider.kind, modelID: model.id,
            transport: transport(owner) ?? ""
        ), id: \.self) { tier in
            ModelControlNote(
                text: tier == "privacy_impacting"
                    ? L10n.tr("This field can send your data to a third-party service.", table: .chat)
                    : L10n.tr("This field can increase what the provider charges.", table: .chat),
                systemImage: tier == "privacy_impacting" ? "hand.raised.fill" : "creditcard.fill",
                tone: OriveoTheme.Palette.warningText
            )
        }
    }

    @ViewBuilder
    private func validation(_ owner: String) -> some View {
        switch preview(owner) {
        case .none:
            ModelControlNote(
                text: L10n.tr("Enter a JSON object to preview its allowed field paths.", table: .chat),
                systemImage: "text.cursor"
            )
        case let .some(.success(paths)):
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 11.5))
                    Text(L10n.tr("Redacted request delta preview", table: .chat))
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(OriveoTheme.Palette.success)

                Text(paths.map { "\($0): <redacted>" }.joined(separator: "\n"))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(OriveoTheme.Palette.textSecondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityElement(children: .combine)
        case let .some(.failure(reason)):
            ModelControlNote(
                text: errorMessage(owner: owner, reason: reason),
                systemImage: "exclamationmark.triangle.fill",
                tone: OriveoTheme.Palette.danger
            )
        }
    }

    // MARK: - Criteria

    private func transport(_ owner: String) -> String? {
        CapabilityRecipeExecution.finalTransport(owner: owner, provider: provider, model: model)
    }

    private func hasSchema(_ owner: String) -> Bool { schemaOwners.contains(owner) }

    private func preview(_ owner: String) -> Result<[String], SafeCustomFragmentCompiler.Rejection>? {
        guard let transport = transport(owner),
              !(drafts[owner] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return CapabilityRecipeExecution.redactedSafeCustomPreview(
            raw: drafts[owner] ?? "", owner: owner, providerKind: provider.kind,
            modelID: model.id, transport: transport
        )
    }

    private func documentationURL(_ owner: String) -> URL? {
        if let customURL = CapabilityRecipeExecution.officialCustomDocumentationURL(
            owner: owner, providerKind: provider.kind, modelID: model.id,
            transport: transport(owner) ?? ""
        ) { return customURL }
        guard provider.kind != .relay else { return nil }
        let snapshot = MetadataClient.shared.syncCapabilityRecipeRuntime(
            modelID: model.id, providerKind: provider.kind
        )
        guard let runtime = snapshot.runtime else { return nil }
        return CapabilityRecipeExecution.officialGenerationDocumentationURL(
            runtime: runtime, control: snapshot.controls?[owner]
        )
    }

    /// A path rejection has to answer "what can I write then". Saying only "this field is not allowed" leaves the user guessing,
    /// while the allowed set is known on the device (the schema has been delivered) and there is no reason not to list it.
    private func errorMessage(owner: String, reason: SafeCustomFragmentCompiler.Rejection) -> String {
        switch reason {
        case .invalidJSON, .duplicateJSONKey:
            return L10n.tr("Enter valid JSON with no duplicate keys.", table: .chat)
        case .unknownPath, .crossOwner, .forbiddenRoot, .forbiddenChannel, .forbiddenKey, .invalidValue:
            let allowed = CapabilityRecipeExecution.safeCustomAllowedPaths(
                owner: owner, providerKind: provider.kind, modelID: model.id,
                transport: transport(owner) ?? ""
            )
            // An existing owner whose schema is gone has no allowed set to list; report the conflict as it is rather than an empty list.
            guard !allowed.isEmpty else {
                return L10n.tr(
                    "This field conflicts with the managed request schema or is not allowed for this connection.",
                    table: .chat
                )
            }
            return String(
                format: L10n.tr("This field isn’t allowed. Fields this model accepts: %@", table: .chat),
                allowed.joined(separator: " · ")
            )
        case .tooLarge, .depthExceeded, .nodeLimitExceeded:
            return L10n.tr("This JSON fragment is too large or complex to apply.", table: .chat)
        }
    }

    // MARK: - Storage

    private var canonicalModelID: String {
        CapabilityPreferenceRuntimeIdentity.make(provider: provider, model: model)?.canonicalModelID ?? ""
    }

    /// Which sections this page has on entry, and each one's draft. The entry (the row on the additional request body page) and this page read the same function:
    /// two copies of that criterion are how "it opens but cannot be changed" happens.
    struct Sections {
        var visible: [String] = []
        var schemaOwners: Set<String> = []
        var drafts: [String: String] = [:]
        var legacyEmptyCustomOwners: Set<String> = []
    }

    static func resolveSections(
        provider: Provider, model: AIModel, conversationID: UUID?, transportIdentity: String
    ) -> Sections {
        var result = Sections()
        // Without a runtime identity (empty string) these two sections can neither be read nor written, so they are not shown.
        guard !transportIdentity.isEmpty else { return result }
        let canonicalModelID = CapabilityPreferenceRuntimeIdentity.make(provider: provider, model: model)?
            .canonicalModelID ?? ""
        for entry in ownerNamespaces {
            // Falls back to the model default scope when the conversation layer has no record (the same reading as the send path): fields written on the provider detail page
            // are in effect in this conversation, and an editor showing a blank would make the user think they were lost and write them again.
            let configuration = GenerationParameterSettingsStore.shared.effectiveLocalCustomConfiguration(
                providerID: provider.id, modelID: canonicalModelID, conversationID: conversationID,
                transportIdentity: transportIdentity, namespace: entry.namespace,
                // Drafts written under an older recipe version are carried forward; otherwise a recipe change in the catalog
                // would leave this page blank and the user would think their content was lost.
                forwardPort: .init(providerKind: provider.kind, schemaModelID: model.id)
            )
            result.drafts[entry.owner] = configuration.rawJSON
            let hasContent = !configuration.rawJSON
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if configuration.mode == .custom, !hasContent {
                result.legacyEmptyCustomOwners.insert(entry.owner)
            }
            if CapabilityRecipeExecution.hasSafeCustomSchema(
                owner: entry.owner, providerKind: provider.kind, modelID: model.id,
                transport: CapabilityRecipeExecution.finalTransport(
                    owner: entry.owner, provider: provider, model: model
                ) ?? ""
            ) {
                result.schemaOwners.insert(entry.owner)
            }
            // Owners with a schema ∪ owners with stored content. The second set cannot be dropped: the schema is delivered by the catalog
            // and may disappear on a metadata refresh, while the user's custom configuration is still in effect (the send path only looks at the mode).
            // Hiding the section as soon as the schema is gone would take away the only way to turn it off, and the fail-closed
            // compiler would stop that connection from sending messages.
            if result.schemaOwners.contains(entry.owner) || hasContent
                || result.legacyEmptyCustomOwners.contains(entry.owner) {
                result.visible.append(entry.owner)
            }
        }
        return result
    }

    private func load() {
        // onAppear fires again each time this page is returned to, and reading again would roll the draft being edited back to the stored value.
        guard !didLoad else { return }
        didLoad = true
        let resolved = Self.resolveSections(
            provider: provider, model: model, conversationID: conversationID,
            transportIdentity: transportIdentity
        )
        drafts = resolved.drafts
        legacyEmptyCustomOwners = resolved.legacyEmptyCustomOwners
        schemaOwners = resolved.schemaOwners
        sections = resolved.visible
    }

    /// The mode is derived from the content: non-empty = custom (in effect), cleared = automatic (off).
    /// This is the only write semantics; there is no separate automatic/custom choice.
    /// With an editor that has content yet "is not in effect", a user cannot tell a mistake in the content from a switch left off.
    private func persist(_ owner: String) {
        guard let namespace = Self.ownerNamespaces.first(where: { $0.owner == owner })?.namespace else { return }
        let raw = drafts[owner] ?? ""
        let isCustom = !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || legacyEmptyCustomOwners.contains(owner)
        GenerationParameterSettingsStore.shared.setLocalCustomConfiguration(
            .init(mode: isCustom ? .custom : .automatic, rawJSON: raw),
            providerID: provider.id,
            modelID: canonicalModelID,
            conversationID: conversationID,
            transportIdentity: transportIdentity, namespace: namespace
        )
        if isCustom,
           let selectedTransport = transport(owner),
           let identity = CapabilityEvidenceRequestIdentity.make(
                provider: provider,
                model: model,
                partitionID: appState.sessionPartitionUID,
                hasExplicitValue: true
           ).resolvingCapabilityRuntimeTransport(selectedTransport) {
            UnsupportedParamCache.shared.clearCustomRejections(
                providerKind: provider.kind,
                modelID: identity.query.effectiveModelID,
                owner: owner,
                identity: identity
            )
        }
    }
}
