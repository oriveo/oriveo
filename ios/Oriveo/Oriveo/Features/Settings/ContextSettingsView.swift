import OriveoProviderKit
import SwiftUI

/// How older history is condensed once a chat exceeds the model's context budget.
/// Backed by `AppPreference.contextAISummaryEnabled`; stored on this device only (never synced).
enum ContextSettingsMode: CaseIterable, Identifiable {
    /// Default: drop earlier AI replies, keep the user's own words. No extra cost.
    case fallback
    /// Ask the current model to summarize earlier turns (one extra model call each time).
    case aiSummary

    var id: Self { self }

    init(aiSummaryEnabled: Bool) {
        self = aiSummaryEnabled ? .aiSummary : .fallback
    }

    var aiSummaryEnabled: Bool { self == .aiSummary }

    @MainActor
    static func current(in appState: AppState) -> ContextSettingsMode {
        ContextSettingsMode(aiSummaryEnabled: appState.preferences.contextAISummaryEnabled)
    }

    var title: String {
        switch self {
        case .fallback: L10n.tr("settings_context_mode_fallback", table: .settings)
        case .aiSummary: L10n.tr("settings_context_mode_ai", table: .settings)
        }
    }

    var hint: String {
        switch self {
        case .fallback: L10n.tr("settings_context_mode_fallback_hint", table: .settings)
        case .aiSummary: L10n.tr("settings_context_mode_ai_hint", table: .settings)
        }
    }

    /// Short name shown as the value of the Settings › Context row.
    var rowValue: String {
        switch self {
        case .fallback: L10n.tr("settings_context_row_value_fallback", table: .settings)
        case .aiSummary: L10n.tr("settings_context_mode_ai", table: .settings)
        }
    }

    /// Persists locally and updates in-memory preferences. Deliberately does not touch the sync adapter.
    @MainActor
    func apply(to appState: AppState) {
        var updated = appState.preferences
        guard updated.contextAISummaryEnabled != aiSummaryEnabled
            || AppPreferencesStore.savedContextAISummaryEnabled != aiSummaryEnabled else { return }
        updated.contextAISummaryEnabled = aiSummaryEnabled
        AppPreferencesStore.save(updated)
        appState.preferences = updated
    }
}

/// Global default context cap (`AppPreference.contextDefaultCap`, P9 U7): a conversation without its own cap
/// follows it. Stored locally the same way as `ContextSettingsMode.apply`.
@MainActor
enum ContextDefaultCapSetting {
    static func current(in appState: AppState) -> ContextBudgetCap {
        appState.preferences.contextDefaultCap
    }

    static func presentation(in appState: AppState) -> ContextCapPresentation.Settings {
        ContextCapPresentation.settings(cap: current(in: appState))
    }

    /// Persists locally and updates in-memory preferences.
    static func apply(_ cap: ContextBudgetCap, to appState: AppState) {
        var updated = appState.preferences
        guard updated.contextDefaultCap != cap || AppPreferencesStore.savedContextDefaultCap != cap else { return }
        updated.contextDefaultCap = cap
        AppPreferencesStore.save(updated)
        appState.preferences = updated
        // Conversations without their own cap follow the default: their usage ring and panel recompute
        // the denominator now, not at the next send (same notification as `setContextCap`).
        for conversation in appState.conversations where conversation.contextCap == nil {
            NotificationCenter.default.post(
                name: .contextUsageInputsDidChange,
                object: nil,
                userInfo: [ContextCompactionStore.conversationIdKey: conversation.id.uuidString]
            )
        }
    }

    /// Commits the typed custom number. The global default is not tied to a model, so U is unknown;
    /// text that does not parse restores the previous value and writes nothing.
    @discardableResult
    static func commitCustom(text: String, to appState: AppState) -> ContextCapPresentation.Commit {
        let commit = ContextCapPresentation.commit(
            text: text,
            U: nil,
            previous: presentation(in: appState).customPrefill
        )
        if !commit.restored {
            apply(.custom(commit.value), to: appState)
        }
        return commit
    }

    static func title(_ selection: ContextCapPresentation.SettingsSelection) -> String {
        switch selection {
        case .auto: L10n.tr("context_cap_auto", table: .chat)
        case .unlimited: L10n.tr("context_cap_unlimited", table: .chat)
        case .custom: L10n.tr("context_cap_custom", table: .chat)
        }
    }

    /// Compact token count isolated with FSI…PDI so it keeps its order inside RTL / mixed text.
    static func isolatedCount(_ value: Int) -> String {
        "\u{2068}\(ContextCompactionSeparator.compactCount(value))\u{2069}"
    }

    /// Option name for auto / unlimited, compact number for custom.
    static func capText(_ cap: ContextBudgetCap) -> String {
        switch cap {
        case .auto: title(.auto)
        case .unlimited: title(.unlimited)
        case .custom(let tokens): isolatedCount(tokens)
        }
    }

    /// Value of the Settings › Context row: "cap · mode".
    static func rowValue(cap: ContextBudgetCap, mode: ContextSettingsMode) -> String {
        L10n.format(L10n.tr("settings_context_row_value", table: .settings), capText(cap), mode.rowValue)
    }

    static func rowValue(in appState: AppState) -> String {
        rowValue(cap: current(in: appState), mode: ContextSettingsMode.current(in: appState))
    }

    static var footer: String {
        L10n.format(
            L10n.tr("settings_context_cap_footer", table: .settings),
            isolatedCount(ContextBudget.autoCapDefault),
            isolatedCount(ContextBudget.customCapMin)
        )
    }
}

/// Global "ask before long-context pricing" switch (`AppPreference.contextPriceLineReminderEnabled`, P9 U8),
/// default on. Going over a custom cap is asked regardless. Stored locally the same way as `ContextSettingsMode.apply`.
@MainActor
enum ContextPriceLineReminderSetting {
    static func current(in appState: AppState) -> Bool {
        appState.preferences.contextPriceLineReminderEnabled
    }

    /// Persists locally and updates in-memory preferences.
    static func apply(_ enabled: Bool, to appState: AppState) {
        var updated = appState.preferences
        guard updated.contextPriceLineReminderEnabled != enabled
            || AppPreferencesStore.savedContextPriceLineReminderEnabled != enabled else { return }
        updated.contextPriceLineReminderEnabled = enabled
        AppPreferencesStore.save(updated)
        appState.preferences = updated
    }

    static var title: String { L10n.tr("settings_context_price_line_reminder", table: .settings) }

    static var footer: String { L10n.tr("settings_context_price_line_reminder_footer", table: .settings) }
}

/// Settings › AI › Context: default cap group (single choice, custom input with echo and adjusted hint,
/// footnote), the price-line reminder switch, then the overflow mode group (two single-choice options with hints and a footnote).
struct ContextSettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var customText = ""
    @State private var adjustedTo: Int?
    @FocusState private var customFocused: Bool

    var body: some View {
        let selected = ContextSettingsMode.current(in: appState)
        let cap = ContextDefaultCapSetting.presentation(in: appState)
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                sectionHeader(L10n.tr("settings_context_cap_header", table: .settings))

                ForEach(ContextCapPresentation.SettingsSelection.allCases, id: \.self) { selection in
                    Button {
                        select(selection, prefill: cap.customPrefill)
                    } label: {
                        option(
                            title: ContextDefaultCapSetting.title(selection),
                            hint: nil,
                            selected: selection == cap.selected
                        )
                    }
                    .buttonStyle(.plain)

                    if selection == .custom, cap.selected == .custom {
                        customInput(prefill: cap.customPrefill)
                    }
                }

                footnote(ContextDefaultCapSetting.footer)
                    .padding(.bottom, 12)

                priceLineReminder
                    .padding(.bottom, 12)

                sectionHeader(L10n.tr("settings_context_overflow_header", table: .settings))

                ForEach(ContextSettingsMode.allCases) { mode in
                    Button {
                        mode.apply(to: appState)
                    } label: {
                        option(title: mode.title, hint: mode.hint, selected: mode == selected)
                    }
                    .buttonStyle(.plain)
                }

                footnote(L10n.tr("settings_context_overflow_footer", table: .settings))
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 20)
            .oriveoContentWidth()
        }
        // The route hides the system navigation bar (oriveoNavigationChrome), so the page draws its own bar.
        .safeAreaInset(edge: .top, spacing: 0) { topBar }
        .oriveoScreenBackground()
        .onAppear {
            customText = String(ContextDefaultCapSetting.presentation(in: appState).customPrefill)
        }
        .onChange(of: customFocused) { _, focused in
            if !focused { commitCustom() }
        }
        .onDisappear {
            if customFocused { commitCustom() }
        }
    }

    private var priceLineReminderBinding: Binding<Bool> {
        Binding(
            get: { ContextPriceLineReminderSetting.current(in: appState) },
            set: { ContextPriceLineReminderSetting.apply($0, to: appState) }
        )
    }

    private var priceLineReminder: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(
                ContextPriceLineReminderSetting.title,
                isOn: priceLineReminderBinding
            )
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(OriveoTheme.Palette.textPrimary)
            .tint(OriveoTheme.Palette.primary)
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(OriveoTheme.Palette.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(OriveoTheme.Palette.border, lineWidth: 1)
            )

            footnote(ContextPriceLineReminderSetting.footer)
        }
    }

    /// Top bar: back button and centered title, same layout as other settings sub-pages.
    private var topBar: some View {
        ZStack {
            Text(L10n.tr("settings_context_title", table: .settings))
                .font(OriveoTheme.Typography.title3)
                .foregroundStyle(OriveoTheme.Palette.textPrimary)
                .lineLimit(1)
                .padding(.horizontal, 56)
                .accessibilityAddTraits(.isHeader)
            HStack(spacing: 0) {
                OriveoBackButton {
                    appState.pop()
                }
                .padding(.leading, -OriveoBackButton.edgeInset)
                Spacer(minLength: 0)
            }
        }
        .frame(minHeight: OriveoBackButton.hitSize)
        .padding(.horizontal, 20)
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(OriveoTheme.Palette.textSecondary)
            .textCase(.uppercase)
            .padding(.horizontal, 4)
            .accessibilityAddTraits(.isHeader)
    }

    private func footnote(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(OriveoTheme.Palette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 4)
    }

    private func select(_ selection: ContextCapPresentation.SettingsSelection, prefill: Int) {
        adjustedTo = nil
        switch selection {
        case .auto:
            ContextDefaultCapSetting.apply(.auto, to: appState)
        case .unlimited:
            ContextDefaultCapSetting.apply(.unlimited, to: appState)
        case .custom:
            // Writes the prefill at once; no auto-focus, so the keyboard does not pop up (as on Android / Web).
            ContextDefaultCapSetting.apply(.custom(prefill), to: appState)
            customText = String(prefill)
        }
    }

    private func commitCustom() {
        let commit = ContextDefaultCapSetting.commitCustom(text: customText, to: appState)
        customText = String(commit.value)
        adjustedTo = commit.adjusted ? commit.value : nil
    }

    /// Raw token integer input; the echo below shows the value that would be saved, in compact notation.
    private func customInput(prefill: Int) -> some View {
        let preview = ContextCapPresentation.commit(text: customText, U: nil, previous: prefill)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(L10n.tr("context_cap_input_label", table: .chat))
                    .font(.system(size: 15))
                    .foregroundStyle(OriveoTheme.Palette.textSecondary)
                TextField(L10n.tr("context_cap_input_label", table: .chat), text: $customText)
                    .keyboardType(.numberPad)
                    .focused($customFocused)
                    .submitLabel(.done)
                    .onSubmit { commitCustom() }
                    .font(.system(size: 16, design: .monospaced))
                    .foregroundStyle(OriveoTheme.Palette.textPrimary)
                Text(L10n.tr("context_cap_input_unit", table: .chat))
                    .font(.system(size: 15))
                    .foregroundStyle(OriveoTheme.Palette.textSecondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(OriveoTheme.Palette.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(customFocused ? OriveoTheme.Palette.primary : OriveoTheme.Palette.border, lineWidth: 1)
            )
            .contentShape(Rectangle())
            .onTapGesture {
                customFocused = true
            }

            if !preview.restored {
                Text(L10n.format(
                    L10n.tr("context_cap_input_echo", table: .chat),
                    ContextDefaultCapSetting.isolatedCount(preview.value)
                ))
                .font(.system(size: 13))
                .foregroundStyle(OriveoTheme.Palette.textSecondary)
            }

            if let adjustedTo {
                Text(L10n.format(
                    L10n.tr("context_cap_adjusted", table: .chat),
                    ContextDefaultCapSetting.isolatedCount(adjustedTo)
                ))
                .font(.system(size: 13))
                .foregroundStyle(OriveoTheme.Palette.warningText)
            }
        }
        .padding(.horizontal, 4)
    }

    private func option(title: String, hint: String?, selected: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 22))
                .foregroundStyle(selected ? OriveoTheme.Palette.primary : OriveoTheme.Palette.borderStrong)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(OriveoTheme.Palette.textPrimary)
                if let hint {
                    Text(hint)
                        .font(.system(size: 13.5))
                        .foregroundStyle(OriveoTheme.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(selected ? OriveoTheme.Palette.primarySoft : OriveoTheme.Palette.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(selected ? OriveoTheme.Palette.primary.opacity(0.45) : OriveoTheme.Palette.border, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}
