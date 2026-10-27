import SwiftUI

// Connect a preset service: reuse a connection or paste a key → "Confirm before enabling" → agree and test → saved only if it passes.
// The detail page reuses this same page for changing the key (mode = .rekey), also writing only after the test passes.

/// Consent → test → result.
enum WebSearchTestPhase: Equatable {
    case idle
    case testing
    case passed(message: String)
    case failed(SearchTestPresentation)

    var isTesting: Bool { self == .testing }
}

struct WebSearchConnectView: View {
    enum Mode {
        case add(SearchAddSheetRow)
        case rekey(serviceID: String)
    }

    let model: WebSearchSettingsModel
    let mode: Mode
    let onFinished: @MainActor () -> Void

    @Environment(\.openURL) private var openURL
    @State private var useConnection = true
    @State private var key = ""
    @State private var regionID: String?
    @State private var keyError: String?
    @State private var phase: WebSearchTestPhase = .idle
    @FocusState private var keyFocused: Bool

    private var serviceID: String? {
        switch mode {
        case .add(let row): row.serviceId
        case .rekey(let id): model.item(id)?.service.serviceId
        }
    }

    private var entry: SearchJSON? { model.entry(serviceID) }
    private var name: String { model.catalogName(serviceID) }

    /// Reusable connections (already resolved by the add sheet; resolved on demand when changing a key).
    private var connection: (id: String, name: String, regionId: String)? {
        switch mode {
        case .add(let row):
            guard let ref = row.connectionRef else { return nil }
            return (ref, row.connectionName ?? "", row.regionId ?? "")
        case .rekey:
            return model.reusableConnection(for: entry).map { ($0.connection.id, $0.connection.name, $0.regionId) }
        }
    }

    private var regions: [String] {
        (entry?["regions"]?.arrayValue ?? []).compactMap { $0["id"]?.stringValue }
    }

    private var usingConnection: Bool { connection != nil && useConnection }

    private var effectiveRegion: String? {
        if usingConnection { return connection?.regionId }
        if let regionID { return regionID }
        if case .add(let row) = mode, row.connectionRef == nil { return row.regionId ?? regions.first }
        if case .rekey(let id) = mode { return model.item(id)?.service.regionId ?? regions.first }
        return regions.first
    }

    private var links: SearchRegionLinks? {
        entry.map { SearchCatalog.regionLinks($0, regionId: effectiveRegion) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if connection != nil { keySourceCard }
                // Paste a key: site → API key → get a key (the link follows the selected site)
                if !usingConnection && regions.count > 1 { regionPicker }
                if !usingConnection { keyCard }
                if case .failed(let presentation) = phase {
                    WebSearchTestFailureBanner(presentation: presentation, onAction: handle)
                }
                WebSearchConsentCard(lines: SearchSettings.searchConsentLines(
                    kind: .preset, platform: .ios, serviceName: name, host: nil
                ))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .disabled(phase.isTesting)
        }
        .scrollDismissesKeyboard(.interactively)
        .oriveoScreenBackground(showsGlow: false)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(phase.isTesting)
        .interactiveDismissDisabled(phase.isTesting)
        .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
        #if DEBUG
        // Screenshot staging only: an already finished test result
        .onAppear { if let staged = WebSearchShots.takeTestPhase() { phase = staged } }
        #endif
    }

    // MARK: Header

    private var header: some View {
        let summary = SearchSettings.searchPriceSummary(entry, regionId: effectiveRegion)
        let subtitle = [
            WebSearchCopy.price(summary),
            summary.billing == "non_empty_only" ? WebSearchCopy.tr("price.nonEmptyOnly") : nil,
        ].compactMap { $0 }.joined(separator: " · ")
        return HStack(spacing: 14) {
            WebSearchServiceLogo(serviceId: serviceID, size: 56)
            VStack(alignment: .leading, spacing: 4) {
                Text(name)
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(OriveoTheme.Palette.textPrimary)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(OriveoTheme.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
    }

    // MARK: Key source

    private var keySourceCard: some View {
        WebSearchCard {
            optionRow(
                title: WebSearchCopy.format("connect.useConnection", connection?.name ?? ""),
                hint: WebSearchCopy.tr("connect.useConnectionHint"),
                selected: useConnection
            ) { useConnection = true }
            WebSearchDivider()
            optionRow(
                title: WebSearchCopy.tr("connect.pasteAnother"),
                hint: nil,
                selected: !useConnection
            ) { useConnection = false }
        }
    }

    private func optionRow(
        title: String,
        hint: String?,
        selected: Bool,
        action: @escaping @MainActor () -> Void
    ) -> some View {
        Button(action: {
            action()
            keyError = nil
            if phase != .testing { phase = .idle }
        }) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 16))
                        .foregroundStyle(OriveoTheme.Palette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let hint {
                        Text(hint)
                            .font(.system(size: 13))
                            .foregroundStyle(OriveoTheme.Palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(OriveoTheme.Palette.primaryTextSafe)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
        }
        .buttonStyle(WebSearchRowButtonStyle())
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var keyCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            WebSearchCard {
                VStack(alignment: .leading, spacing: 6) {
                    Text(WebSearchCopy.tr("connect.keyLabel"))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(OriveoTheme.Palette.textTertiary)
                    SecureField(WebSearchCopy.format("connect.keyPlaceholder", name), text: $key)
                        .font(.system(size: 16))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($keyFocused)
                        .onChange(of: key) { _, _ in keyError = nil }
                        .accessibilityIdentifier("web_search_connect_key_field")
                    if let keyError { WebSearchFieldMessage(text: keyError) }
                }
                .padding(16)
            }
            if let help = links?.keyHelp, let url = URL(string: help) {
                Button(action: { openURL(url) }) {
                    HStack(spacing: 4) {
                        Text(WebSearchCopy.format("connect.getKey", name))
                        Image(systemName: "arrow.up.right").font(.system(size: 12, weight: .semibold))
                    }
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(OriveoTheme.Palette.primaryTextSafe)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 4)
            }
        }
    }

    private var regionPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            WebSearchSectionHeader(title: WebSearchCopy.tr("region.label"))
            Picker(WebSearchCopy.tr("region.label"), selection: Binding(
                get: { effectiveRegion ?? regions.first ?? "" },
                set: { regionID = $0 }
            )) {
                ForEach(regions, id: \.self) { id in
                    Text(WebSearchCopy.regionName(id)).tag(id)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    // MARK: Bottom

    private var bottomBar: some View {
        VStack(spacing: 12) {
            if case .passed(let message) = phase {
                Text(message)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(OriveoTheme.Palette.success)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
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
            if let terms = links?.terms, let url = URL(string: terms) {
                Button(action: { openURL(url) }) {
                    Text(WebSearchCopy.format("connect.viewTerms", name))
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(OriveoTheme.Palette.primaryTextSafe)
                }
                .buttonStyle(.plain)
                .disabled(phase.isTesting)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(OriveoTheme.Palette.background.opacity(0.96))
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

    // MARK: Test → save

    private func agreeAndTest() async {
        guard let entry, let region = effectiveRegion,
              let host = SearchCatalog.region(of: entry, id: region)?["host"]?.stringValue else { return }
        var sendKey: String?
        if usingConnection {
            sendKey = model.connectionKey(connection?.id)
        } else {
            let normalized = SearchTransport.normalizeSearchKey(key)
            if let error = normalized.error {
                let hint = (try? SearchSettings.customFormFieldErrors(errors: [error], warnings: []))?.fields["key"] ?? "keyInvalid"
                keyError = WebSearchCopy.tr("form.\(hint)")
                keyFocused = true
                return
            }
            sendKey = normalized.key
        }
        phase = .testing
        let presentation = await model.runTest(
            .preset(entry: entry, regionId: region, boundHost: host, key: sendKey),
            query: WebSearchCopy.tr("test.queryDefault")
        )
        guard presentation.state == .passed else {
            phase = .failed(presentation)
            return
        }
        do {
            let connectionRef = usingConnection ? connection?.id : nil
            switch mode {
            case .add:
                let saved = try await model.addPreset(entry: entry, regionId: region, connectionRef: connectionRef, key: sendKey)
                phase = .passed(message: WebSearchCopy.tr(saved.becameDefault ? "consent.passedDefault" : "consent.passed"))
            case .rekey(let id):
                guard var service = model.item(id)?.service else { return }
                service.kind = connectionRef == nil ? .preset : .reuseConnection
                service.connectionRef = connectionRef
                service.regionId = region
                service.boundHost = host
                try await model.update(service, key: connectionRef == nil ? sendKey : nil)
                phase = .passed(message: WebSearchCopy.testPassed(presentation))
            }
        } catch {
            phase = .failed(SearchSettings.searchTestPresentation(.failed(errorClass: nil, card: nil)))
        }
    }

    private func handle(_ action: String) {
        switch action {
        case "update_key":
            useConnection = false
            phase = .idle
            keyFocused = true
        case "top_up":
            if let pricing = links?.pricing, let url = URL(string: pricing) { openURL(url) }
        case "view_setup_guide":
            if let url = URL(string: SearchSettings.searxngSetupGuideUrl) { openURL(url) }
        default:
            Task { await agreeAndTest() }
        }
    }
}

/// Change key from the detail page: wrapped in a navigation stack inside the sheet (same as the connect page).
struct WebSearchRekeySheet: View {
    let model: WebSearchSettingsModel
    let serviceID: String
    let onFinished: @MainActor () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            WebSearchConnectView(model: model, mode: .rekey(serviceID: serviceID), onFinished: onFinished)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(L10n.tr("Cancel")) { dismiss() }
                    }
                }
        }
    }
}
