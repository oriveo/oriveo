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

struct RelayCapabilitySection: View {
    @Binding var hasWebSearch: Bool
    @Binding var webSearchProfile: String?
    @Binding var transportKind: String?

    let isSubmitting: Bool

    @State private var isExpanded = false

    static let knownProfiles: [(value: String, label: String)] = [
        ("oai_responses_web", "OpenAI Responses • web_search"),
        ("oai_web_tool", "OpenAI Chat • gpt-5-search-api"),
        ("ant_web_tool", "Anthropic • web_search_20250305"),
        ("gem_web", "Gemini 2.0+ • google_search"),
        ("gem_web_retrieval", "Gemini 1.5 • google_search_retrieval"),
        ("grok_responses_web", "Grok 4.1+ • web_search (Agent Tools)"),
        ("qwen_web", "Qwen DashScope • search_options"),
        ("zhipu_web", "Zhipu GLM • web_search"),
        ("or_web", "OpenRouter • openrouter:web_search"),
        ("kimi_web_search", "Moonshot/Kimi • $web_search"),
    ]

    static let knownTransports: [(value: String, label: String)] = [
        ("openai_chat", "openai_chat - Chat Completions"),
        ("openai_responses", "openai_responses - Responses API"),
        ("anthropic_messages", "anthropic_messages - Anthropic Messages"),
        ("gemini_generate", "gemini_generate - Gemini generateContent"),
        ("dashscope_native", "dashscope_native - DashScope native"),
        ("openai_images", "openai_images - OpenAI Images"),
        ("gemini_image", "gemini_image - Gemini Image"),
        ("qwen_image", "qwen_image - Qwen Image"),
        ("grok_image", "grok_image - Grok Imagine"),
        ("zhipu_image", "zhipu_image - Zhipu Image"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: OriveoTheme.Spacing.sm) {
            disclosureHeader

            if isExpanded {
                VStack(alignment: .leading, spacing: OriveoTheme.Spacing.sm) {
                    Toggle(L10n.tr("Supports web search", table: .providers), isOn: $hasWebSearch)
                        .disabled(isSubmitting)
                        .font(OriveoTheme.Typography.footnote.weight(.medium))

                    if hasWebSearch {
                        profilePicker
                    }

                    transportPicker
                }
                .padding(OriveoTheme.Spacing.md)
                .oriveoRoundedSurface(
                    fill: OriveoTheme.Palette.surface,
                    border: OriveoTheme.Palette.border,
                    radius: OriveoTheme.Radius.md,
                    shadow: .none
                )
            }
        }
    }

    private var disclosureHeader: some View {
        Button {
            withAnimation(.snappy(duration: 0.18)) { isExpanded.toggle() }
        } label: {
            HStack(spacing: OriveoTheme.Spacing.sm) {
                Image(systemName: "globe.americas")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(OriveoTheme.Palette.textTertiary)
                    .frame(width: 18, height: 18)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(OriveoTheme.Palette.surfaceInset)
                    )

                Text(L10n.tr("Capabilities", table: .providers))
                    .font(OriveoTheme.Typography.footnote.weight(.semibold))
                    .foregroundStyle(OriveoTheme.Palette.textSecondary)
                    .textCase(.uppercase)
                    .tracking(0.4)

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

    private var profilePicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.tr("Web search profile", table: .providers))
                .font(OriveoTheme.Typography.caption.weight(.semibold))
                .foregroundStyle(OriveoTheme.Palette.textSecondary)
            Picker(L10n.tr("Web search profile", table: .providers), selection: Binding<String>(
                get: { webSearchProfile ?? Self.knownProfiles.first!.value },
                set: { webSearchProfile = $0 }
            )) {
                ForEach(Self.knownProfiles, id: \.value) { item in
                    Text(item.label).tag(item.value)
                }
            }
            .pickerStyle(.menu)
            .disabled(isSubmitting)
        }
    }

    private var transportPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.tr("Transport", table: .providers))
                .font(OriveoTheme.Typography.caption.weight(.semibold))
                .foregroundStyle(OriveoTheme.Palette.textSecondary)
            Picker(L10n.tr("Transport", table: .providers), selection: Binding<String>(
                get: { transportKind ?? Self.knownTransports.first!.value },
                set: { transportKind = $0 }
            )) {
                ForEach(Self.knownTransports, id: \.value) { item in
                    Text(item.label).tag(item.value)
                }
            }
            .pickerStyle(.menu)
            .disabled(isSubmitting)
        }
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
