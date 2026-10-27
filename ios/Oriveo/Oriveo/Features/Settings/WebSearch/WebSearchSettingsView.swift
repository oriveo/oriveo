import SwiftUI

// Settings › Web search: intro → my search services → add → footer.

struct WebSearchSettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var model = WebSearchSettingsModel()
    @State private var showsAddSheet = false
    #if DEBUG
    /// Screenshot staging only: model options web card.
    @State private var shotModelOptions: WebSearchShots.ModelOptions?
    #endif

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text(WebSearchCopy.tr("main.intro"))
                    .font(.system(size: 15))
                    .foregroundStyle(OriveoTheme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)

                VStack(alignment: .leading, spacing: 10) {
                    WebSearchSectionHeader(title: WebSearchCopy.tr("main.section"))
                    WebSearchCard {
                        if model.loaded && model.items.isEmpty {
                            Text(WebSearchCopy.tr("main.empty"))
                                .font(.system(size: 15))
                                .foregroundStyle(OriveoTheme.Palette.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(16)
                            WebSearchDivider()
                        }
                        ForEach(model.items) { item in
                            serviceRow(item)
                            WebSearchDivider(leading: 56)
                        }
                        addRow
                    }
                    WebSearchFooter(text: WebSearchCopy.tr("main.footer"))
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .padding(.bottom, 24)
            .oriveoContentWidth()
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            WebSearchTopBar(title: WebSearchCopy.tr("entry.title")) {
                appState.pop()
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("web_search_settings_screen")
        .oriveoScreenBackground()
        .onAppear {
            #if DEBUG
            // Screenshot staging only: when staging, do not change the local seen set; open the add sheet per the manifest
            if WebSearchShots.staged != nil {
                if WebSearchShots.takeOpensAddSheet() { showsAddSheet = true }
                if let options = WebSearchShots.takeModelOptions() { shotModelOptions = options }
            } else {
                FeatureBadges.shared.markSeen(FeatureBadges.settingsWebSearch)
            }
            #else
            FeatureBadges.shared.markSeen(FeatureBadges.settingsWebSearch)
            #endif
            Task { await model.load(appState: appState) }
        }
        // Arrived from model options "Add search service" but left without adding: invalidate that "select after adding", so services added directly here afterwards do not send pick_service.
        .onDisappear { SearchArmAfterAdd.shared.clear(origin: .settings) }
        #if DEBUG
        .sheet(isPresented: Binding(get: { shotModelOptions != nil }, set: { if !$0 { shotModelOptions = nil } })) {
            if let shotModelOptions { WebSearchShotModelOptionsHost(shot: shotModelOptions) }
        }
        #endif
        .sheet(isPresented: $showsAddSheet, onDismiss: { Task { await model.load(appState: appState) } }) {
            WebSearchAddSheet(model: model) { serviceID in
                showsAddSheet = false
                appState.navigation.attemptNavigate(to: .webSearchServiceDetail(serviceID: serviceID))
            }
        }
    }

    private func serviceRow(_ item: WebSearchServiceItem) -> some View {
        let subtitle = WebSearchCopy.rowSubtitle(item)
        return Button(action: {
            appState.navigation.attemptNavigate(to: .webSearchServiceDetail(serviceID: item.id))
        }) {
            HStack(spacing: 12) {
                WebSearchServiceLogo(serviceId: item.service.serviceId, custom: item.isCustom, size: 28)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(item.displayName)
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(OriveoTheme.Palette.textPrimary)
                            .lineLimit(1)
                        if model.defaultID == item.id {
                            WebSearchTag(text: WebSearchCopy.tr("badge.default"))
                        }
                        if item.isCustom {
                            WebSearchTag(text: WebSearchCopy.tr("badge.custom"), neutral: true)
                        }
                    }
                    Text(subtitle.text)
                        .font(.system(size: 13))
                        .foregroundStyle(subtitle.warning ? OriveoTheme.Palette.warningText : OriveoTheme.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.forward")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(OriveoTheme.Palette.textTertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .buttonStyle(WebSearchRowButtonStyle())
        .accessibilityIdentifier("web_search_service_\(item.id)")
    }

    private var addRow: some View {
        Button(action: { showsAddSheet = true }) {
            HStack(spacing: 12) {
                Image(systemName: "plus")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 28, height: 28)
                Text(WebSearchCopy.tr("main.add"))
                    .font(.system(size: 16, weight: .medium))
                Spacer(minLength: 0)
            }
            .foregroundStyle(OriveoTheme.Palette.primaryTextSafe)
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
        }
        .buttonStyle(WebSearchRowButtonStyle())
        .accessibilityIdentifier("web_search_add_button")
    }
}

// MARK: - Add sheet

/// Pushed pages inside the sheet.
enum WebSearchAddRoute: Hashable {
    case connect(SearchAddSheetRow)
    case custom
}

struct WebSearchAddSheet: View {
    let model: WebSearchSettingsModel
    /// Tapped an already added row: close the sheet and go to its detail.
    let onOpenExisting: @MainActor (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var path: [WebSearchAddRoute] = []

    var body: some View {
        NavigationStack(path: $path) {
            list
                .navigationTitle(WebSearchCopy.tr("add.title"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(L10n.tr("Cancel")) { dismiss() }
                    }
                }
                #if DEBUG
                // Screenshot staging only: push the connect page / custom form per the manifest
                .onAppear { if let route = WebSearchShots.takeAddRoute() { path = [route] } }
                #endif
                .navigationDestination(for: WebSearchAddRoute.self) { route in
                    switch route {
                    case .connect(let row):
                        WebSearchConnectView(model: model, mode: .add(row), onFinished: { dismiss() })
                    case .custom:
                        WebSearchCustomFormView(model: model, onFinished: { dismiss() })
                    }
                }
        }
    }

    private var list: some View {
        let sheet = model.addSheet
        return ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if sheet.presets == .unavailable {
                    WebSearchCard {
                        Text(WebSearchCopy.tr("add.presetsUnavailable"))
                            .font(.system(size: 15))
                            .foregroundStyle(OriveoTheme.Palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(16)
                    }
                }
                ForEach(sheet.sections) { section in
                    VStack(alignment: .leading, spacing: 10) {
                        WebSearchSectionHeader(title: WebSearchCopy.tr(sectionTitleKey(section.id)))
                        WebSearchCard {
                            ForEach(Array(section.rows.enumerated()), id: \.offset) { index, row in
                                if index > 0 { WebSearchDivider(leading: 56) }
                                presetRow(row, reuse: section.id == .reuse)
                            }
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 10) {
                    WebSearchSectionHeader(title: WebSearchCopy.tr("add.sectionCustom"))
                    WebSearchCard { customRow }
                    WebSearchFooter(text: WebSearchCopy.tr("add.footer"))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .oriveoScreenBackground(showsGlow: false)
    }

    private func sectionTitleKey(_ kind: SearchAddSheetSection.Kind) -> String {
        switch kind {
        case .reuse: "add.sectionReuse"
        case .domestic: "add.sectionDomestic"
        case .overseas: "add.sectionOverseas"
        }
    }

    private func presetRow(_ row: SearchAddSheetRow, reuse: Bool) -> some View {
        let entry = model.entry(row.serviceId)
        let price = WebSearchCopy.price(SearchSettings.searchPriceSummary(entry, regionId: row.regionId), includeOtherRegion: !reuse)
        let subtitle: String? = if row.addedServiceRef != nil {
            WebSearchCopy.tr("add.added")
        } else if reuse {
            [WebSearchCopy.format("add.reuseRow", row.connectionName ?? ""), price].compactMap { $0 }.joined(separator: " · ")
        } else {
            price
        }
        return Button(action: {
            if let existing = row.addedServiceRef {
                onOpenExisting(existing)
            } else {
                path.append(.connect(row))
            }
        }) {
            HStack(spacing: 12) {
                WebSearchServiceLogo(serviceId: row.serviceId, size: 28)
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.catalogName(row.serviceId))
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(OriveoTheme.Palette.textPrimary)
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 13))
                            .foregroundStyle(OriveoTheme.Palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.forward")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(OriveoTheme.Palette.textTertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .buttonStyle(WebSearchRowButtonStyle())
        .accessibilityIdentifier("web_search_add_\(row.serviceId)")
    }

    private var customRow: some View {
        Button(action: { path.append(.custom) }) {
            HStack(spacing: 12) {
                WebSearchServiceLogo(serviceId: nil, custom: true, size: 28)
                VStack(alignment: .leading, spacing: 3) {
                    Text(WebSearchCopy.tr("add.customTitle"))
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(OriveoTheme.Palette.textPrimary)
                    Text(WebSearchCopy.tr("add.customSubtitle"))
                        .font(.system(size: 13))
                        .foregroundStyle(OriveoTheme.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.forward")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(OriveoTheme.Palette.textTertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .buttonStyle(WebSearchRowButtonStyle())
        .accessibilityIdentifier("web_search_add_custom")
    }
}
