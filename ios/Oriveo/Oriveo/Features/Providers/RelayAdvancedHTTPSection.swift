import SwiftUI

struct RelayWebSearchToolNameSection: View {
    @Binding var webSearchToolName: RelayWebSearchToolName?
    let isSubmitting: Bool

    private var current: RelayWebSearchToolName {
        webSearchToolName ?? .webSearch
    }

    var body: some View {
        VStack(alignment: .leading, spacing: OriveoTheme.Spacing.sm) {
            RelayGroupHeader(
                title: L10n.tr("Web search tool name", table: .providers),
                systemImage: "magnifyingglass",
                tint: Color.dynamic(light: 0x0EA5E9, dark: 0x38BDF8)
            )

            Picker(L10n.tr("Web search tool name", table: .providers), selection: Binding<RelayWebSearchToolName>(
                get: { current },
                set: { webSearchToolName = $0 }
            )) {
                Text("web_search").tag(RelayWebSearchToolName.webSearch)
                Text("web_search_preview").tag(RelayWebSearchToolName.webSearchPreview)
                Text(L10n.tr("Disabled")).tag(RelayWebSearchToolName.disabled)
            }
            .pickerStyle(.segmented)
            .disabled(isSubmitting)

            Text(currentHint)
                .font(OriveoTheme.Typography.caption)
                .foregroundStyle(currentHintColor)
                .padding(.horizontal, 2)
        }
        .padding(OriveoTheme.Spacing.md)
        .oriveoRoundedSurface(
            fill: OriveoTheme.Palette.surfaceChrome,
            border: OriveoTheme.Palette.border,
            radius: OriveoTheme.Radius.md,
            shadow: .none
        )
    }

    private var currentHint: String {
        switch current {
        case .webSearch:
            return L10n.tr("Default web_search matches OpenAI and main Codex relays. Switch to web_search_preview for legacy relays.", table: .providers)
        case .webSearchPreview:
            return L10n.tr("Legacy protocol name. Use only when the relay rejects web_search.", table: .providers)
        case .disabled:
            return L10n.tr("No web_search tool will be sent even if the chat web search toggle is on.", table: .providers)
        }
    }

    private var currentHintColor: Color {
        current == .disabled ? OriveoTheme.Palette.warning : OriveoTheme.Palette.textTertiary
    }
}
struct RelayAdvancedHTTPSection: View {
    @Binding var customUserAgent: String
    @Binding var headers: [RelayKeyValue]
    @Binding var queryParams: [RelayKeyValue]

    let isSubmitting: Bool

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: OriveoTheme.Spacing.sm) {
            disclosureHeader

            if isExpanded {
                RelayRowGroup {
                    RelayInlineTextRow(
                        title: L10n.tr("User-Agent", table: .providers),
                        text: $customUserAgent,
                        placeholder: L10n.tr("auto / leave blank", table: .providers),
                        isEnabled: !isSubmitting
                    )
                }

                kvSection(
                    title: L10n.tr("Custom Headers", table: .providers),
                    items: $headers,
                    keyPlaceholder: "X-Internal-Token",
                    valuePlaceholder: L10n.tr("value", table: .providers),
                    addLabel: L10n.tr("Add header", table: .providers)
                )

                kvSection(
                    title: L10n.tr("Custom Query Params", table: .providers),
                    items: $queryParams,
                    keyPlaceholder: "tenant",
                    valuePlaceholder: L10n.tr("value", table: .providers),
                    addLabel: L10n.tr("Add query param", table: .providers)
                )
            }
        }
    }

    private var disclosureHeader: some View {
        Button {
            withAnimation(.snappy(duration: 0.18)) { isExpanded.toggle() }
        } label: {
            HStack(spacing: OriveoTheme.Spacing.sm) {
                Image(systemName: "wrench.and.screwdriver")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.dynamic(light: 0xF59E0B, dark: 0xFBBF24))
                    .frame(width: 20, height: 20)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.dynamic(light: 0xF59E0B, dark: 0xFBBF24).opacity(0.14))
                    )

                Text(L10n.tr("Advanced HTTP", table: .providers))
                    .font(OriveoTheme.Typography.footnote.weight(.semibold))
                    .foregroundStyle(OriveoTheme.Palette.textSecondary)
                    .textCase(.uppercase)
                    .tracking(0.4)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)

                Spacer()

                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(OriveoTheme.Palette.textTertiary)
            }
            .padding(.horizontal, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func kvSection(
        title: String,
        items: Binding<[RelayKeyValue]>,
        keyPlaceholder: String,
        valuePlaceholder: String,
        addLabel: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(OriveoTheme.Typography.caption.weight(.semibold))
                .foregroundStyle(OriveoTheme.Palette.textSecondary)
                .padding(.horizontal, 2)
                .padding(.top, 4)

            VStack(spacing: 6) {
                ForEach(items.indices, id: \.self) { i in
                    HStack(spacing: 6) {
                        TextField(keyPlaceholder, text: items[i].key)
                            .textFieldStyle(.roundedBorder)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .font(OriveoTheme.Typography.footnote.monospaced())
                            .disabled(isSubmitting)
                        TextField(valuePlaceholder, text: items[i].value)
                            .textFieldStyle(.roundedBorder)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .font(OriveoTheme.Typography.footnote.monospaced())
                            .disabled(isSubmitting)
                        Button {
                            var current = items.wrappedValue
                            current.remove(at: i)
                            items.wrappedValue = current
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(OriveoTheme.Palette.danger)
                        }
                        .buttonStyle(.plain)
                        .disabled(isSubmitting)
                    }
                }

                Button {
                    var current = items.wrappedValue
                    current.append(RelayKeyValue(key: "", value: ""))
                    items.wrappedValue = current
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus.circle.fill")
                        Text(addLabel)
                    }
                    .font(OriveoTheme.Typography.footnote.weight(.semibold))
                    .foregroundStyle(OriveoTheme.Palette.primary)
                }
                .buttonStyle(.plain)
                .disabled(isSubmitting)
            }
            .padding(OriveoTheme.Spacing.sm)
            .oriveoRoundedSurface(
                fill: OriveoTheme.Palette.surfaceChrome,
                border: OriveoTheme.Palette.border,
                radius: OriveoTheme.Radius.md,
                shadow: .none
            )
        }
    }
}
