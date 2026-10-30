import SwiftUI

// Custom service: name / address / Key (optional) → protocol → validate only on continue →
// custom consent page → saved only if the test passes. Form field components are shared with detail-page editing.

/// Fields of the custom form (shared by adding and detail editing). Errors hang under the field (red); the cleartextLan warning hangs under the address (orange).
struct WebSearchCustomFields: View {
    let model: WebSearchSettingsModel
    @Binding var draft: WebSearchCustomDraft
    @Binding var errors: SearchFormFieldErrors
    /// Detail-page editing: when a key exists and the source has not changed, the Key row is hidden (shown again when the Key row is tapped).
    var showsKey = true
    /// Focus a given field (detail page "Update Key" focuses the key box); field names match the error fields (name / address / key …).
    var focus: FocusState<String?>.Binding

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 10) {
                WebSearchCard {
                    field("custom.name", placeholder: WebSearchCopy.tr("custom.namePlaceholder"), text: $draft.name, error: "name")
                    WebSearchDivider()
                    field("custom.address", placeholder: "https://", text: $draft.address, error: "address", keyboard: .URL)
                    if showsKey {
                        WebSearchDivider()
                        field("custom.key", placeholder: WebSearchCopy.tr("custom.keyOptional"), text: $draft.key, error: "key", secure: true)
                    }
                }
                WebSearchFooter(text: WebSearchCopy.tr("custom.addressHintMobile"))
            }

            VStack(alignment: .leading, spacing: 10) {
                WebSearchSectionHeader(title: WebSearchCopy.tr("custom.protocol"))
                WebSearchCard {
                    protocolOption("searxng", title: "custom.protocolSearxng", hint: "custom.protocolSearxngHint")
                    WebSearchDivider()
                    protocolOption("same_as", title: "custom.protocolSameAs", hint: "custom.protocolSameAsHint",
                                   disabled: !model.catalogAvailable)
                    if draft.protocolID == "same_as" && model.catalogAvailable {
                        WebSearchDivider()
                        sameAsPicker
                    }
                    WebSearchDivider()
                    protocolOption("manual", title: "custom.protocolManual", hint: "custom.protocolManualHint")
                }
                if let hint = errors.fields["protocol"] ?? errors.fields["mapping"] {
                    WebSearchFieldMessage(text: WebSearchCopy.tr("form.\(hint)")).padding(.horizontal, 4)
                } else if !model.catalogAvailable {
                    WebSearchFooter(text: WebSearchCopy.tr("form.presetUnavailable"))
                }
            }

            if draft.protocolID == "manual" { manualSection }
        }
    }

    // MARK: Text fields

    private func field(
        _ labelID: String,
        placeholder: String,
        text: Binding<String>,
        error: String,
        keyboard: UIKeyboardType = .default,
        secure: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(WebSearchCopy.tr(labelID))
                    .font(.system(size: 16))
                    .foregroundStyle(OriveoTheme.Palette.textPrimary)
                    .frame(minWidth: 64, alignment: .leading)
                Group {
                    if secure {
                        SecureField(placeholder, text: text)
                    } else {
                        TextField(placeholder, text: text)
                            .keyboardType(keyboard)
                    }
                }
                .font(.system(size: 16))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused(focus, equals: error)
                .onChange(of: text.wrappedValue) { _, _ in clear(error) }
            }
            if let hint = errors.fields[error] {
                WebSearchFieldMessage(text: WebSearchCopy.tr("form.\(hint)"))
            } else if error == "address", let warning = errors.warnings["address"] {
                WebSearchFieldMessage(text: WebSearchCopy.tr("form.\(warning)"), warning: true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func clear(_ field: String) {
        errors.fields[field] = nil
        if field == "address" { errors.warnings["address"] = nil }
    }

    // MARK: Protocol

    private func protocolOption(_ id: String, title: String, hint: String, disabled: Bool = false) -> some View {
        Button(action: {
            draft.protocolID = id
            if id == "same_as" && draft.sameAsServiceID == nil {
                draft.sameAsServiceID = model.entries.first?["id"]?.stringValue
            }
            clear("protocol")
            clear("mapping")
        }) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(WebSearchCopy.tr(title))
                        .font(.system(size: 16))
                        .foregroundStyle(OriveoTheme.Palette.textPrimary)
                    Text(WebSearchCopy.tr(hint))
                        .font(.system(size: 13))
                        .foregroundStyle(OriveoTheme.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if draft.protocolID == id {
                    Image(systemName: "checkmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(OriveoTheme.Palette.primaryTextSafe)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .opacity(disabled ? 0.45 : 1)
        }
        .buttonStyle(WebSearchRowButtonStyle())
        .disabled(disabled)
        .accessibilityAddTraits(draft.protocolID == id ? .isSelected : [])
    }

    private var sameAsPicker: some View {
        HStack {
            Text(WebSearchCopy.tr("custom.protocolSameAsPick"))
                .font(.system(size: 16))
                .foregroundStyle(OriveoTheme.Palette.textPrimary)
            Spacer(minLength: 8)
            Picker(WebSearchCopy.tr("custom.protocolSameAsPick"), selection: Binding(
                get: { draft.sameAsServiceID ?? "" },
                set: { draft.sameAsServiceID = $0 }
            )) {
                ForEach(model.entries.compactMap { $0["id"]?.stringValue }, id: \.self) { id in
                    Text(model.catalogName(id)).tag(id)
                }
            }
            .tint(OriveoTheme.Palette.primaryTextSafe)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: Manual mapping

    private var manualSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            WebSearchSectionHeader(title: WebSearchCopy.tr("manual.section"))
            WebSearchCard {
                segmented("manual.method", selection: $draft.method, options: [("GET", "GET"), ("POST", "POST")], error: "method")
                WebSearchDivider()
                segmented("manual.auth", selection: $draft.auth, options: [
                    ("bearer", WebSearchCopy.tr("manual.authBearer")),
                    ("header", WebSearchCopy.tr("manual.authHeader")),
                    ("none", WebSearchCopy.tr("manual.authNone")),
                ], error: "auth")
                if draft.auth == "header" {
                    WebSearchDivider()
                    field("manual.headerName", placeholder: "X-API-Key", text: $draft.headerName, error: "auth")
                }
                WebSearchDivider()
                field("manual.queryField", placeholder: "q", text: $draft.queryField, error: "query")
                WebSearchDivider()
                field("manual.countField", placeholder: WebSearchCopy.tr("manual.optional"), text: $draft.countField, error: "count")
            }
            VStack(alignment: .leading, spacing: 10) {
                WebSearchSectionHeader(title: WebSearchCopy.tr("manual.params"))
                WebSearchCard {
                    ForEach($draft.params) { $param in
                        HStack(spacing: 8) {
                            TextField(WebSearchCopy.tr("manual.paramName"), text: $param.name)
                            TextField(WebSearchCopy.tr("manual.paramValue"), text: $param.value)
                            Button(action: {
                                draft.params.removeAll { $0.id == param.id }
                                clear("params")
                            }) {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(OriveoTheme.Palette.danger)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(L10n.tr("Delete"))
                        }
                        .font(.system(size: 16))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .onChange(of: param) { _, _ in clear("params") }
                        WebSearchDivider()
                    }
                    if draft.params.count < 10 {
                        Button(action: {
                            draft.params.append(.init())
                            clear("params")
                        }) {
                            HStack(spacing: 8) {
                                Image(systemName: "plus")
                                Text(WebSearchCopy.tr("manual.addParam"))
                                Spacer(minLength: 0)
                            }
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(OriveoTheme.Palette.primaryTextSafe)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                        }
                        .buttonStyle(WebSearchRowButtonStyle())
                    }
                }
                if let hint = errors.fields["params"] {
                    WebSearchFieldMessage(text: WebSearchCopy.tr("form.\(hint)")).padding(.horizontal, 4)
                }
            }
            WebSearchCard {
                field("manual.resultsPath", placeholder: "results", text: $draft.resultsPath, error: "results")
                WebSearchDivider()
                field("manual.titlePath", placeholder: "title", text: $draft.titlePath, error: "title")
                WebSearchDivider()
                field("manual.urlPath", placeholder: "url", text: $draft.urlPath, error: "url")
                WebSearchDivider()
                field("manual.snippetPath", placeholder: "content", text: $draft.snippetPath, error: "snippet")
                WebSearchDivider()
                field("manual.sitePath", placeholder: WebSearchCopy.tr("manual.optional"), text: $draft.sitePath, error: "site")
                WebSearchDivider()
                field("manual.datePath", placeholder: WebSearchCopy.tr("manual.optional"), text: $draft.datePath, error: "date")
            }
            WebSearchFooter(text: WebSearchCopy.tr("manual.pathHint"))
        }
    }

    private func segmented(
        _ labelID: String,
        selection: Binding<String>,
        options: [(String, String)],
        error: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Text(WebSearchCopy.tr(labelID))
                    .font(.system(size: 16))
                    .foregroundStyle(OriveoTheme.Palette.textPrimary)
                Spacer(minLength: 8)
                Picker(WebSearchCopy.tr(labelID), selection: selection) {
                    ForEach(options, id: \.0) { option in Text(option.1).tag(option.0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .onChange(of: selection.wrappedValue) { _, _ in clear(error) }
            }
            if let hint = errors.fields[error] {
                WebSearchFieldMessage(text: WebSearchCopy.tr("form.\(hint)"))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

/// Custom form page in the add flow (pushed inside the sheet); continue → custom consent page.
struct WebSearchCustomFormView: View {
    let model: WebSearchSettingsModel
    let onFinished: @MainActor () -> Void

    @State private var draft = WebSearchCustomDraft()
    @State private var errors = SearchFormFieldErrors(fields: [:], warnings: [:], blocking: false)
    @State private var validating = false
    @FocusState private var focusedField: String?
    @State private var consent: WebSearchCustomConsentInput?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                WebSearchCustomFields(model: model, draft: $draft, errors: $errors, focus: $focusedField)
                WebSearchFooter(text: WebSearchCopy.tr("custom.footer"))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .disabled(validating)
        }
        .scrollDismissesKeyboard(.interactively)
        .oriveoScreenBackground(showsGlow: false)
        .navigationTitle(WebSearchCopy.tr("custom.title"))
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Button(action: { Task { await proceed() } }) {
                HStack(spacing: 8) {
                    if validating { ProgressView().tint(Color(uiColor: OriveoPrimaryButtonStyle.foregroundUIColor)) }
                    Text(WebSearchCopy.tr("custom.continue"))
                }
            }
            .buttonStyle(WebSearchPrimaryButtonStyle())
            .disabled(validating)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(OriveoTheme.Palette.background.opacity(0.96))
            .accessibilityIdentifier("web_search_custom_continue_button")
        }
        #if DEBUG
        // Screenshot staging only: prefilled draft, go straight to the consent page per the manifest (the target is built in memory following the production SearXNG rules, no address validation, no network)
        .onAppear {
            guard let staged = WebSearchShots.takeDraft() else { return }
            draft = staged
            if WebSearchShots.takeOpensConsent(), let address = SearchTransport.parseServiceAddress(staged.address) {
                let spec = staged.protocolID == "searxng" ? SearchTransport.searxngSpec : staged.manualMapping
                let path = staged.protocolID == "searxng" ? SearchTransport.searxngPath(address.path) : address.path
                consent = WebSearchCustomConsentInput(
                    draft: staged, target: .custom(spec: spec, address: address, requestPath: path, key: nil),
                    spec: spec, key: nil, address: address
                )
            }
        }
        #endif
        .navigationDestination(item: $consent) { input in
            WebSearchCustomConsentView(model: model, input: input, onFinished: onFinished, onCheckSettings: { action in
                consent = nil
                // "Update Key" returns to the form and focuses the key box; "Check settings" only returns to the form
                if action == "update_key" { Task { @MainActor in focusedField = "key" } }
            })
        }
    }

    private func proceed() async {
        validating = true
        let result = await model.validate(draft)
        validating = false
        errors = result.fields
        guard !result.fields.blocking, let target = result.target, let address = SearchTransport.parseServiceAddress(draft.address) else { return }
        consent = WebSearchCustomConsentInput(draft: draft, target: target, spec: result.spec, key: result.key, address: address)
    }
}

/// Input to the custom consent page (the form has already passed validation).
struct WebSearchCustomConsentInput: Hashable, Identifiable {
    let id = UUID()
    let draft: WebSearchCustomDraft
    let target: WebSearchTestTarget
    let spec: SearchJSON?
    let key: String?
    let address: SearchServiceAddress

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Custom consent page: server icon + name + custom tag + "<protocol name> · <host[:port]>"; the rest is the same as the connect page.
struct WebSearchCustomConsentView: View {
    let model: WebSearchSettingsModel
    let input: WebSearchCustomConsentInput
    let onFinished: @MainActor () -> Void
    /// Back to the form (check_settings / update_key).
    let onCheckSettings: @MainActor (String) -> Void

    @Environment(\.openURL) private var openURL
    @State private var phase: WebSearchTestPhase = .idle

    private var host: String { WebSearchCopy.hostLabel(input.address) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if case .failed(let presentation) = phase {
                    WebSearchTestFailureBanner(presentation: presentation, onAction: handle)
                }
                WebSearchConsentCard(lines: SearchSettings.searchConsentLines(
                    kind: .custom, platform: .ios, serviceName: input.draft.name, host: host
                ))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .disabled(phase.isTesting)
        }
        .oriveoScreenBackground(showsGlow: false)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(phase.isTesting)
        .interactiveDismissDisabled(phase.isTesting)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 12) {
                if case .passed(let message) = phase {
                    Text(message)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(OriveoTheme.Palette.success)
                        .multilineTextAlignment(.center)
                }
                Button(action: primaryAction) {
                    HStack(spacing: 8) {
                        if phase.isTesting { ProgressView().tint(Color(uiColor: OriveoPrimaryButtonStyle.foregroundUIColor)) }
                        Text(primaryTitle)
                    }
                }
                .buttonStyle(WebSearchPrimaryButtonStyle())
                .disabled(phase.isTesting)
                .accessibilityIdentifier("web_search_consent_agree_button")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(OriveoTheme.Palette.background.opacity(0.96))
        }
        #if DEBUG
        // Screenshot staging only: an already finished test result
        .onAppear { if let staged = WebSearchShots.takeTestPhase() { phase = staged } }
        #endif
    }

    private var header: some View {
        let sameAsName = input.draft.protocolID == "same_as" ? model.catalogName(input.draft.sameAsServiceID) : nil
        return HStack(spacing: 14) {
            WebSearchServiceLogo(serviceId: nil, custom: true, size: 56)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(SearchJSText.trim(input.draft.name))
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(OriveoTheme.Palette.textPrimary)
                    WebSearchTag(text: WebSearchCopy.tr("badge.custom"), neutral: true)
                }
                Text("\(WebSearchCopy.protocolName(input.draft.protocolID, sameAsName: sameAsName)) · \(host)")
                    .font(.system(size: 13))
                    .foregroundStyle(OriveoTheme.Palette.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
    }

    private var primaryTitle: String {
        switch phase {
        case .testing: WebSearchCopy.tr("consent.testing")
        case .passed: WebSearchCopy.tr("consent.done")
        default: WebSearchCopy.tr("consent.agree")
        }
    }

    private func primaryAction() {
        if case .passed = phase {
            onFinished()
            return
        }
        Task { await agreeAndTest() }
    }

    private func agreeAndTest() async {
        phase = .testing
        let presentation = await model.runTest(input.target, query: WebSearchCopy.tr("test.queryDefault"))
        guard presentation.state == .passed else {
            phase = .failed(presentation)
            return
        }
        let draft = input.draft
        let service = StoredSearchService(
            id: UUID().uuidString,
            kind: .custom,
            name: SearchJSText.trim(draft.name),
            address: SearchJSText.trim(draft.address),
            protocolID: draft.protocolID,
            mappingJSON: draft.protocolID == "searxng" ? nil : input.spec?.encodedString()
        )
        do {
            let becameDefault = try await model.addCustom(service, key: input.key)
            phase = .passed(message: WebSearchCopy.tr(becameDefault ? "consent.passedDefault" : "consent.passed"))
        } catch {
            phase = .failed(SearchSettings.searchTestPresentation(.failed(errorClass: nil, card: nil)))
        }
    }

    private func handle(_ action: String) {
        switch action {
        case "check_settings", "update_key":
            onCheckSettings(action)
        case "view_setup_guide":
            if let url = URL(string: SearchSettings.searxngSetupGuideUrl) { openURL(url) }
        default:
            Task { await agreeAndTest() }
        }
    }
}
