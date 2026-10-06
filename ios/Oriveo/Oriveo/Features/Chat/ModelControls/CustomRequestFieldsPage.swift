import SwiftUI

struct CustomRequestFieldsPage: View {
    @Environment(AppState.self) private var appState

    let provider: Provider
    let model: AIModel
    let conversationID: UUID?
    let transportIdentity: String

    @State private var drafts: [String: String] = [:]
    @State private var legacyEmptyCustomOwners: Set<String> = []
    @State private var pendingRemovalOwner: String?
    @State private var sections: [String] = []
    @State private var schemaOwners: Set<String> = []
    @State private var didLoad = false
    @FocusState private var focusedOwner: String?
    /// Draft and "Send with requests" switch of the additional request body. The two are stored
    /// separately: switching it off keeps the content and just stops sending it.
    @State private var additionalBodyDraft = ""
    @State private var additionalBodySends = false

    /// Generation parameters are not listed here: they have no officially declared custom fields
    /// and are covered by the additional request body below.
    private static let ownerNamespaces: [(owner: String, namespace: String)] = [
        ("web", "webPatch"),
        ("reasoning", "reasoningPatch"),
    ]
    private static let additionalBodyFocus = "additional_request_body"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if !sections.isEmpty {
                    ForEach(sections, id: \.self) { owner in
                        ownerCard(owner)
                    }
                    // This note is only accurate for the sections above, which are validated
                    // against officially declared fields. The additional request body has its own.
                    ModelControlNote(
                        text: L10n.tr(
                            "Fields are added to the request exactly as written. Only fields this provider officially declares are supported; mistakes can make requests fail. Drafts stay on this device.",
                            table: .chat
                        ),
                        systemImage: "iphone.and.arrow.forward"
                    )
                    .padding(.horizontal, 4)
                }

                additionalBodyCard
            }
            .padding(.horizontal, 18)
            .padding(.top, 6)
            .padding(.bottom, 32)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(OriveoTheme.Palette.background)
        .navigationTitle(L10n.tr("Custom request fields", table: .chat))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
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


    private func title(for owner: String) -> String {
        switch owner {
        case "web": return L10n.tr("Web Search", table: .chat)
        default: return L10n.tr("Thinking Mode", table: .chat)
        }
    }

    // MARK: - Additional request body

    private var additionalBodyTrimmed: String {
        additionalBodyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var additionalBodyCard: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text(L10n.tr("Additional request body", table: .chat))
                .font(.body.weight(.semibold))
                .foregroundStyle(OriveoTheme.Palette.textPrimary)

            HStack(spacing: 8) {
                Text(L10n.tr("Send with requests", table: .chat))
                    .font(.subheadline)
                    .foregroundStyle(OriveoTheme.Palette.textPrimary)
                Spacer(minLength: 8)
                Toggle("", isOn: Binding(
                    get: { additionalBodySends },
                    set: { next in
                        additionalBodySends = next
                        persistAdditionalBody()
                    }
                ))
                    .labelsHidden()
                    .tint(OriveoTheme.Palette.primaryTextSafe)
                    .accessibilityLabel(Text(L10n.tr("Send with requests", table: .chat)))
            }

            TextEditor(text: Binding(
                get: { additionalBodyDraft },
                // Saved on every edit, like the sections above: closing the page must not lose
                // half-written JSON.
                set: { next in
                    additionalBodyDraft = next
                    persistAdditionalBody()
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
            .focused($focusedOwner, equals: Self.additionalBodyFocus)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .accessibilityLabel(Text(L10n.tr("Additional request body", table: .chat)))

            additionalBodyValidation

            ModelControlNote(
                text: conversationID != nil
                    ? L10n.tr("Scope: this conversation, connection, model, and transport.", table: .chat)
                    : L10n.tr(
                        "Scope: this model on this connection, used as the default for its conversations.",
                        table: .chat
                    ),
                systemImage: "scope"
            )
            ModelControlNote(
                text: L10n.tr("Stays on this device. It isn’t synced or included in backups.", table: .chat),
                systemImage: "iphone"
            )
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modelControlSurface()
    }

    @ViewBuilder
    private var additionalBodyValidation: some View {
        if additionalBodyTrimmed.isEmpty {
            ModelControlNote(
                text: L10n.tr(
                    "Enter a JSON object. Its fields are merged into each request and override parameter settings for the same field.",
                    table: .chat
                ),
                systemImage: "text.cursor"
            )
        } else {
            switch AdditionalRequestBody.parse(additionalBodyDraft) {
            case .success:
                ModelControlNote(
                    text: additionalBodySends
                        ? L10n.tr("This JSON is merged into each request.", table: .chat)
                        : L10n.tr("Saved, but not sent. Turn on “Send with requests” to use it.", table: .chat),
                    systemImage: additionalBodySends ? "checkmark.seal.fill" : "pause.circle",
                    tone: additionalBodySends ? OriveoTheme.Palette.success : OriveoTheme.Palette.textSecondary
                )
            case let .failure(rejection):
                ModelControlNote(
                    text: rejection.localizedMessage,
                    systemImage: "exclamationmark.triangle.fill",
                    tone: OriveoTheme.Palette.danger
                )
            }
        }
    }

    private var additionalBodyModelID: String {
        CapabilityPreferenceRuntimeIdentity.canonicalModelID(provider: provider, model: model)
    }

    private func loadAdditionalBody() {
        let configuration = GenerationParameterSettingsStore.shared.effectiveAdditionalRequestBody(
            providerID: provider.id, modelID: additionalBodyModelID, conversationID: conversationID
        )
        additionalBodyDraft = configuration.rawJSON
        additionalBodySends = configuration.sendsWithRequest
    }

    /// A conversation scope always keeps a record, even an empty one. Otherwise clearing it would
    /// fall back to the model default and the content just deleted would be back the next time the
    /// page opens. The model-default scope drops its record once it is empty and switched off.
    private func persistAdditionalBody() {
        let isBlank = additionalBodyTrimmed.isEmpty
        let configuration: AdditionalRequestBodyConfiguration? = conversationID == nil && isBlank && !additionalBodySends
            ? nil
            : .init(rawJSON: additionalBodyDraft, sendsWithRequest: additionalBodySends)
        GenerationParameterSettingsStore.shared.setAdditionalRequestBody(
            configuration, providerID: provider.id, modelID: additionalBodyModelID,
            conversationID: conversationID
        )
    }

    // MARK: - Sections for officially declared fields

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

    private func errorMessage(owner: String, reason: SafeCustomFragmentCompiler.Rejection) -> String {
        switch reason {
        case .invalidJSON, .duplicateJSONKey:
            return L10n.tr("Enter valid JSON with no duplicate keys.", table: .chat)
        case .unknownPath, .crossOwner, .forbiddenRoot, .forbiddenChannel, .forbiddenKey, .invalidValue:
            let allowed = CapabilityRecipeExecution.safeCustomAllowedPaths(
                owner: owner, providerKind: provider.kind, modelID: model.id,
                transport: transport(owner) ?? ""
            )
            guard !allowed.isEmpty else {
                return L10n.tr(
                    "This field conflicts with the managed request schema or is not allowed for this connection.",
                    table: .chat
                )
            }
            return String(
                format: L10n.tr("This field isn’t allowed. Fields this model accepts: %@", table: .chat),
                allowed.joined(separator: " • ")
            )
        case .tooLarge, .depthExceeded, .nodeLimitExceeded:
            return L10n.tr("This JSON fragment is too large or complex to apply.", table: .chat)
        }
    }


    private var canonicalModelID: String {
        CapabilityPreferenceRuntimeIdentity.make(provider: provider, model: model)?.canonicalModelID ?? ""
    }

    private func load() {
        guard !didLoad else { return }
        didLoad = true
        loadAdditionalBody()
        var visible: [String] = []
        // Without a runtime identity (empty string) these sections can be neither read nor
        // written, so they are not shown.
        for entry in Self.ownerNamespaces where !transportIdentity.isEmpty {
            let configuration = GenerationParameterSettingsStore.shared.effectiveLocalCustomConfiguration(
                providerID: provider.id, modelID: canonicalModelID, conversationID: conversationID,
                transportIdentity: transportIdentity, namespace: entry.namespace,
                forwardPort: .init(providerKind: provider.kind, schemaModelID: model.id)
            )
            drafts[entry.owner] = configuration.rawJSON
            let hasContent = !configuration.rawJSON
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if configuration.mode == .custom, !hasContent {
                legacyEmptyCustomOwners.insert(entry.owner)
            }
            if CapabilityRecipeExecution.hasSafeCustomSchema(
                owner: entry.owner, providerKind: provider.kind, modelID: model.id,
                transport: transport(entry.owner) ?? ""
            ) {
                schemaOwners.insert(entry.owner)
            }
            if schemaOwners.contains(entry.owner) || hasContent
                || legacyEmptyCustomOwners.contains(entry.owner) {
                visible.append(entry.owner)
            }
        }
        sections = visible
    }

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
