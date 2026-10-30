import SwiftUI

// Search service detail: status hint → Key and set as default → test search → pricing (presets only) → advanced → (custom) name / address / protocol → delete.

struct WebSearchDetailView: View {
    let serviceID: String

    @Environment(AppState.self) private var appState
    @Environment(\.openURL) private var openURL
    @State private var model = WebSearchSettingsModel()
    @State private var query = WebSearchCopy.tr("test.queryDefault")
    @State private var testPhase: WebSearchTestPhase = .idle
    @State private var testResult: SearchTestPresentation?
    @State private var showsRekey = false
    @State private var showsDeleteConfirm = false
    @State private var draft = WebSearchCustomDraft()
    @State private var savedDraft = WebSearchCustomDraft()
    @State private var formErrors = SearchFormFieldErrors(fields: [:], warnings: [:], blocking: false)
    @State private var saving = false
    @State private var saveFailure: SearchTestPresentation?
    /// Custom service: the key box is shown after tapping the Key row / "Update Key".
    @State private var editingCustomKey = false
    @State private var scrollTarget: String?
    @FocusState private var focusedField: String?

    private var item: WebSearchServiceItem? { model.item(serviceID) }

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if let item {
                    if item.row.status != .ready { noticeCard(item) }
                    keyAndDefaultCard(item)
                    testSection(item)
                    if !item.isCustom { priceSection(item) }
                    advancedCard(item)
                    if item.isCustom { customEditSection(item).id("edit") }
                    deleteCard
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .padding(.bottom, 24)
            .oriveoContentWidth()
            .disabled(testPhase.isTesting || saving)
        }
        .onChange(of: scrollTarget) { _, target in
            guard let target else { return }
            withAnimation { proxy.scrollTo(target, anchor: .top) }
            scrollTarget = nil
        }
        }
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .top, spacing: 0) {
            WebSearchTopBar(title: item?.displayName ?? "", onBack: { appState.pop() }) {
                if let item {
                    WebSearchServiceLogo(serviceId: item.service.serviceId, custom: item.isCustom, size: 28)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("web_search_detail_screen")
        .oriveoScreenBackground()
        .onAppear {
            #if DEBUG
            // Screenshot staging only: an already finished test result
            if let staged = WebSearchShots.takeDetailTest() { testResult = staged }
            #endif
            Task {
                await reload()
                applyLaunchIntent()
            }
        }
        .sheet(isPresented: $showsRekey, onDismiss: { Task { await reload() } }) {
            WebSearchRekeySheet(model: model, serviceID: serviceID, onFinished: { showsRekey = false })
        }
        .alert(deleteTitle, isPresented: $showsDeleteConfirm) {
            Button(WebSearchCopy.tr("detail.deleteConfirm"), role: .destructive) {
                Task {
                    try? await model.delete(serviceID)
                    appState.pop()
                }
            }
            Button(L10n.tr("Cancel"), role: .cancel) {}
        } message: {
            Text(deleteMessage)
        }
    }

    /// Arriving from a chat error card: Update Key opens the Key editor directly; Check settings goes straight to the custom service editing area. One-shot.
    private func applyLaunchIntent() {
        guard let intent = WebSearchDetailLaunch.take(serviceID: serviceID), let item else { return }
        switch intent {
        case .updateKey: openKeyEditor(item)
        case .editCustom: if item.isCustom { scrollTarget = "edit" }
        }
    }

    private func reload() async {
        await model.load(appState: appState)
        if let service = item?.service, service.kind == .custom {
            let restored = WebSearchCustomDraft(service: service)
            draft = restored
            savedDraft = restored
        }
    }

    // MARK: Status hint

    @ViewBuilder
    private func noticeCard(_ item: WebSearchServiceItem) -> some View {
        let status = item.row.status
        WebSearchCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(OriveoTheme.Palette.warning)
                    Text(noticeText(item))
                        .font(.system(size: 14))
                        .foregroundStyle(OriveoTheme.Palette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if status == .hostChanged {
                    noticeButton("action.reconfirm") { Task { await reconfirmHost(item) } }
                } else if status == .connectionMissing || status == .needsKey {
                    noticeButton("connect.pasteAnother") { showsRekey = true }
                }
            }
            .padding(16)
        }
    }

    private func noticeText(_ item: WebSearchServiceItem) -> String {
        switch item.row.status {
        case .hostChanged:
            let host = currentHost(item) ?? ""
            return WebSearchCopy.format("detail.hostChangedNotice", item.displayName, host)
        case .withdrawn: return WebSearchCopy.tr("detail.withdrawnNotice")
        case .connectionMissing: return WebSearchCopy.tr("detail.connectionMissingNotice")
        case .needsKey: return WebSearchCopy.tr("row.needsKey")
        case .catalogUnavailable: return WebSearchCopy.tr("row.catalogUnavailable")
        case .ready: return ""
        }
    }

    private func noticeButton(_ titleID: String, action: @escaping @MainActor () -> Void) -> some View {
        Button(action: action) {
            Text(WebSearchCopy.tr(titleID))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(OriveoTheme.Palette.primaryTextSafe)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(Capsule().fill(OriveoTheme.Palette.primarySoft))
        }
        .buttonStyle(.plain)
    }

    private func currentHost(_ item: WebSearchServiceItem) -> String? {
        SearchCatalog.region(of: item.entry, id: item.service.regionId)?["host"]?.stringValue
    }

    /// Rebind the host to the new catalog host, keeping the key (SearchServiceStore carries the same key over).
    private func reconfirmHost(_ item: WebSearchServiceItem) async {
        guard let host = currentHost(item) else { return }
        var service = item.service
        service.boundHost = host
        try? await model.update(service)
        await reload()
    }

    // MARK: Key and default

    private func keyAndDefaultCard(_ item: WebSearchServiceItem) -> some View {
        WebSearchCard {
            Button(action: { openKeyEditor(item) }) {
                HStack(spacing: 12) {
                    Text(WebSearchCopy.tr("detail.key"))
                        .font(.system(size: 16))
                        .foregroundStyle(OriveoTheme.Palette.textPrimary)
                    Spacer(minLength: 8)
                    Text(keyValue(item))
                        .font(.system(size: 15))
                        .foregroundStyle(OriveoTheme.Palette.textSecondary)
                        .multilineTextAlignment(.trailing)
                    if !item.isCustom || item.keyTail != nil {
                        Image(systemName: "chevron.forward")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(OriveoTheme.Palette.textTertiary)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 13)
            }
            .buttonStyle(WebSearchRowButtonStyle())
            // Custom: with no key the key box is already in the editing area; with a key, tap here to expand the key box and change the key
            .disabled(item.isCustom ? item.keyTail == nil : (item.row.status == .withdrawn || item.entry == nil))
            WebSearchDivider()
            HStack(spacing: 12) {
                Text(WebSearchCopy.tr("detail.setDefault"))
                    .font(.system(size: 16))
                    .foregroundStyle(OriveoTheme.Palette.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Toggle(WebSearchCopy.tr("detail.setDefault"), isOn: Binding(
                    get: { model.defaultID == item.id },
                    set: { on in if on { Task { try? await model.setDefault(item.id) } } }
                ))
                .labelsHidden()
                .tint(OriveoTheme.Palette.primary)
                .disabled(model.defaultID == item.id)
            }
            .padding(.leading, 16)
            .padding(.trailing, 12)
            .padding(.vertical, 10)
        }
    }

    /// Change key: presets go to the change-key page; custom expands the editing area and focuses the key box (the new key is saved only if its test passes).
    private func openKeyEditor(_ item: WebSearchServiceItem) {
        guard item.isCustom else {
            showsRekey = true
            return
        }
        editingCustomKey = true
        scrollTarget = "edit"
        Task { @MainActor in focusedField = "key" }
    }

    private func keyValue(_ item: WebSearchServiceItem) -> String {
        if item.service.kind == .reuseConnection {
            return WebSearchCopy.format("detail.keyViaConnection", model.connectionName(item.service.connectionRef) ?? "")
        }
        if let tail = item.keyTail { return "\(WebSearchCopy.tr("detail.keySaved")) ••••\(tail)" }
        return WebSearchCopy.tr("detail.keyNone")
    }

    // MARK: Test search

    private func testSection(_ item: WebSearchServiceItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            WebSearchSectionHeader(title: WebSearchCopy.tr("test.section"))
            WebSearchCard {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        TextField(WebSearchCopy.tr("test.queryDefault"), text: $query)
                            .font(.system(size: 16))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(OriveoTheme.Palette.surfaceInset)
                            )
                        Button(action: { Task { await runTest(item) } }) {
                            Group {
                                if testPhase.isTesting {
                                    ProgressView()
                                } else {
                                    Text(WebSearchCopy.tr("test.run"))
                                }
                            }
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(OriveoTheme.Palette.primaryTextSafe)
                            .frame(minWidth: 56)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(OriveoTheme.Palette.primarySoft)
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(SearchJSText.trim(query).isEmpty || testPhase.isTesting)
                    }
                    if let testResult {
                        if testResult.state == .passed {
                            Text(WebSearchCopy.testPassed(testResult))
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(OriveoTheme.Palette.success)
                        } else {
                            WebSearchTestFailure(presentation: testResult) { handle($0, item: item) }
                        }
                    }
                }
                .padding(16)
            }
        }
    }

    private func runTest(_ item: WebSearchServiceItem) async {
        guard let target = await model.testTarget(for: item) else {
            testResult = SearchSettings.searchTestPresentation(.failed(errorClass: "service_withdrawn", card: nil))
            return
        }
        testPhase = .testing
        testResult = await model.runTest(target, query: query, count: item.service.effectiveResultCount)
        testPhase = .idle
    }

    private func handle(_ action: String, item: WebSearchServiceItem) {
        switch action {
        case "update_key":
            openKeyEditor(item)
        case "top_up":
            if let entry = item.entry, let pricing = SearchCatalog.regionLinks(entry, regionId: item.service.regionId).pricing,
               let url = URL(string: pricing) { openURL(url) }
        case "view_setup_guide":
            if let url = URL(string: SearchSettings.searxngSetupGuideUrl) { openURL(url) }
        case "reconfirm":
            Task { await reconfirmHost(item) }
        case "check_settings":
            scrollTarget = "edit"
        default:
            Task { await runTest(item) }
        }
    }

    // MARK: Pricing

    private func priceSection(_ item: WebSearchServiceItem) -> some View {
        let summary = SearchSettings.searchPriceSummary(item.entry, regionId: item.service.regionId)
        let small = [
            summary.billing == "non_empty_only" ? WebSearchCopy.tr("price.nonEmptyOnly") : nil,
            WebSearchCopy.format("price.billedBy", item.displayName),
        ].compactMap { $0 }.joined(separator: " · ")
        let pricing = item.entry.flatMap { SearchCatalog.regionLinks($0, regionId: item.service.regionId).pricing }
        return VStack(alignment: .leading, spacing: 10) {
            WebSearchSectionHeader(title: WebSearchCopy.tr("detail.price"))
            WebSearchCard {
                VStack(alignment: .leading, spacing: 4) {
                    if let text = WebSearchCopy.price(summary) {
                        Text(text)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(OriveoTheme.Palette.textPrimary)
                    }
                    Text(small)
                        .font(.system(size: 13))
                        .foregroundStyle(OriveoTheme.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(16)
                if let pricing, let url = URL(string: pricing) {
                    WebSearchDivider()
                    Button(action: { openURL(url) }) {
                        HStack(spacing: 4) {
                            Text(WebSearchCopy.format("detail.officialLink", item.displayName))
                            Image(systemName: "arrow.up.right").font(.system(size: 12, weight: .semibold))
                            Spacer(minLength: 0)
                        }
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(OriveoTheme.Palette.primaryTextSafe)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 13)
                    }
                    .buttonStyle(WebSearchRowButtonStyle())
                }
            }
        }
    }

    // MARK: Advanced

    private func advancedCard(_ item: WebSearchServiceItem) -> some View {
        WebSearchCard {
            Button(action: {
                appState.navigation.attemptNavigate(to: .webSearchResultCount(serviceID: item.id))
            }) {
                HStack(spacing: 12) {
                    Text(WebSearchCopy.tr("detail.advanced"))
                        .font(.system(size: 16))
                        .foregroundStyle(OriveoTheme.Palette.textPrimary)
                    Spacer(minLength: 8)
                    Text(WebSearchCopy.format("detail.resultCountValue", WebSearchCopy.integer(item.service.effectiveResultCount)))
                        .font(.system(size: 15))
                        .foregroundStyle(OriveoTheme.Palette.textSecondary)
                    Image(systemName: "chevron.forward")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(OriveoTheme.Palette.textTertiary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 13)
            }
            .buttonStyle(WebSearchRowButtonStyle())
        }
    }

    // MARK: Custom editing

    private func customEditSection(_ item: WebSearchServiceItem) -> some View {
        let originChanges = SearchTransport.addressChangeClearsKey(savedDraft.address, draft.address)
        return VStack(alignment: .leading, spacing: 12) {
            WebSearchCustomFields(
                model: model, draft: $draft, errors: $formErrors,
                showsKey: originChanges || item.keyTail == nil || editingCustomKey, focus: $focusedField
            )
            if originChanges && item.keyTail != nil {
                WebSearchFieldMessage(text: WebSearchCopy.tr("detail.addressChangeNotice"), warning: true)
                    .padding(.horizontal, 4)
            }
            if let saveFailure {
                WebSearchTestFailure(presentation: saveFailure) { action in
                    switch action {
                    case "view_setup_guide":
                        if let url = URL(string: SearchSettings.searxngSetupGuideUrl) { openURL(url) }
                    case "update_key":
                        openKeyEditor(item)
                    case "check_settings":
                        scrollTarget = "edit"
                    default:
                        Task { await saveCustom(item) }
                    }
                }
                .padding(.horizontal, 4)
            }
            if draft != savedDraft {
                Button(action: { Task { await saveCustom(item) } }) {
                    HStack(spacing: 8) {
                        if saving { ProgressView().tint(Color(uiColor: OriveoPrimaryButtonStyle.foregroundUIColor)) }
                        Text(WebSearchCopy.tr("detail.save"))
                    }
                }
                .buttonStyle(WebSearchPrimaryButtonStyle())
                .disabled(saving)
            }
        }
    }

    /// The edit plan follows customServiceEditPlan: a name-only change saves directly; a changed address / protocol / mapping / reference is tested first, then saved;
    /// when the same_as reference is unchanged the stored snapshot is kept (the preset need not be available); when the address source changes the key is cleared (the new key and new address are tested together).
    /// Entering a new key also requires testing before saving.
    private func saveCustom(_ item: WebSearchServiceItem) async {
        saveFailure = nil
        func side(_ draft: WebSearchCustomDraft) -> SearchCustomEditSide {
            SearchCustomEditSide(
                name: draft.name,
                address: draft.address,
                protocolID: draft.protocolID,
                mapping: draft.protocolID == "manual" ? draft.manualMapping : nil,
                presetId: draft.protocolID == "same_as" ? draft.sameAsServiceID : nil,
                regionId: nil
            )
        }
        let plan = SearchSettings.customServiceEditPlan(before: side(savedDraft), after: side(draft))
        let storedSnapshot = draft.protocolID == "same_as" && !plan.resnapshot
            ? item.service.mappingJSON.flatMap { try? SearchJSON.parse($0) }
            : nil
        saving = true
        defer { saving = false }
        let result = await model.validate(draft, storedSnapshot: storedSnapshot)
        formErrors = result.fields
        guard !result.fields.blocking else { return }
        var service = item.service
        service.name = SearchJSText.trim(draft.name)
        if plan.mode == .testThenSave || result.key != nil {
            guard var target = result.target else { return }
            // Source unchanged and no new key entered: test with the stored key
            if result.key == nil, !plan.clearsKey,
               case let .custom(spec, address, path, _) = target,
               case let .custom(_, _, _, storedKey)? = await model.testTarget(for: item) {
                target = .custom(spec: spec, address: address, requestPath: path, key: storedKey)
            }
            let presentation = await model.runTest(target, query: WebSearchCopy.tr("test.queryDefault"))
            guard presentation.state == .passed else {
                saveFailure = presentation
                return
            }
            service.address = SearchJSText.trim(draft.address)
            service.protocolID = draft.protocolID
            service.mappingJSON = draft.protocolID == "searxng" ? nil : result.spec?.encodedString()
        }
        try? await model.update(service, key: result.key)
        editingCustomKey = false
        await reload()
    }

    // MARK: Delete

    private var deleteCard: some View {
        Button(action: { showsDeleteConfirm = true }) {
            Text(WebSearchCopy.tr("detail.delete"))
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(OriveoTheme.Palette.danger)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(OriveoTheme.Palette.surface)
                )
        }
        .buttonStyle(WebSearchRowButtonStyle())
        .accessibilityIdentifier("web_search_detail_delete_button")
    }

    private var deleteTitle: String {
        WebSearchCopy.format("detail.deleteTitle", item?.displayName ?? "")
    }

    private var deleteMessage: String {
        var text = WebSearchCopy.tr("detail.deleteBody")
        if let next = model.defaultAfterDeleting(serviceID) {
            text += " " + WebSearchCopy.format("detail.deleteNewDefault", next.displayName)
        }
        return text
    }
}

// MARK: - Advanced › Results per search

struct WebSearchResultCountView: View {
    let serviceID: String

    @Environment(AppState.self) private var appState
    @State private var model = WebSearchSettingsModel()

    private var item: WebSearchServiceItem? { model.item(serviceID) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                WebSearchSectionHeader(title: WebSearchCopy.tr("detail.resultCount"))
                WebSearchCard {
                    ForEach(Array(SearchSettings.resultCountChoices.enumerated()), id: \.offset) { index, count in
                        if index > 0 { WebSearchDivider() }
                        option(count)
                    }
                }
                WebSearchFooter(text: WebSearchCopy.tr("detail.resultCountFooter"))
            }
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .padding(.bottom, 24)
            .oriveoContentWidth()
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            WebSearchTopBar(title: WebSearchCopy.tr("detail.advanced")) {
                appState.pop()
            }
        }
        .oriveoScreenBackground()
        .onAppear { Task { await model.load(appState: appState) } }
    }

    private func option(_ count: Int) -> some View {
        let selected = item?.service.effectiveResultCount == count
        return Button(action: {
            guard var service = item?.service else { return }
            service.resultCount = count
            Task {
                try? await model.update(service)
                await model.load(appState: appState)
            }
        }) {
            HStack {
                Text(WebSearchCopy.integer(count))
                    .font(.system(size: 16))
                    .foregroundStyle(OriveoTheme.Palette.textPrimary)
                Spacer(minLength: 8)
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
}

/// Things to do together when pushing into the service detail from elsewhere (chat error card "Update Key" / "Check settings"); taken once when the detail page appears.
@MainActor
enum WebSearchDetailLaunch {
    enum Intent: Equatable { case updateKey, editCustom }

    private static var pending: (serviceID: String, intent: Intent)?

    static func set(_ intent: Intent, serviceID: String) { pending = (serviceID, intent) }

    static func take(serviceID: String) -> Intent? {
        guard let pending, pending.serviceID == serviceID else { return nil }
        self.pending = nil
        return pending.intent
    }
}
