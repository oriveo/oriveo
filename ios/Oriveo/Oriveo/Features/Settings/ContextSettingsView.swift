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

    /// Overview card at the top of Settings › Context (contract `shared/ui-contracts/context-settings-hero.v1.json`).
    /// The bar is illustrative only: it does not mark any model's real long-context price threshold.
    struct Hero: Equatable {
        /// Token count shown as the big number; nil means the "full window" word replaces it (unlimited).
        let valueTokens: Int?
        let captionKey: String
        /// Bar fill ratio in 0...1.
        let fill: Double

        var showsUnit: Bool { valueTokens != nil }

        var valueText: String {
            guard let valueTokens else { return L10n.tr("settings_context_hero_full_window", table: .settings) }
            return ContextDefaultCapSetting.isolatedCount(valueTokens)
        }

        var caption: String { L10n.tr(captionKey, table: .settings) }
    }

    static let heroAutoFill = 0.66
    /// Fixed tick position of the "price threshold" label on the illustrative bar.
    static let heroPriceLineMarker = 0.70
    static let heroMinFill = 0.12
    static let heroMaxFill = 1.0

    static func hero(cap: ContextBudgetCap) -> Hero {
        switch cap {
        case .auto:
            Hero(valueTokens: ContextBudget.autoCapDefault, captionKey: "settings_context_hero_caption_auto", fill: heroAutoFill)
        case .unlimited:
            Hero(valueTokens: nil, captionKey: "settings_context_hero_caption_unlimited", fill: heroMaxFill)
        case .custom(let tokens):
            Hero(
                valueTokens: tokens,
                captionKey: "settings_context_hero_caption_custom",
                fill: min(max(Double(tokens) / Double(ContextBudget.autoCapDefault) * heroAutoFill, heroMinFill), heroMaxFill)
            )
        }
    }

    /// Cap fed to the overview card. While custom is selected it follows the same preview as the input echo
    /// (`ContextCapPresentation.commit(text:U:nil,previous:)`), so typing moves the card before the value is saved;
    /// text that does not parse falls back to the saved value. Auto / unlimited use the saved cap as is.
    static func heroCap(stored: ContextBudgetCap, customText: String, previous: Int) -> ContextBudgetCap {
        guard case .custom = stored else { return stored }
        let preview = ContextCapPresentation.commit(text: customText, U: nil, previous: previous)
        return preview.restored ? stored : .custom(preview.value)
    }

    /// Hint under the custom input: the lowest accepted value, in compact notation.
    static var customMinText: String {
        L10n.format(
            L10n.tr("settings_context_custom_min", table: .settings),
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

/// Settings › AI › Context: overview card, default cap segments (custom input with echo and adjusted hint),
/// the price-line reminder card, then the two overflow mode cards and the local-kept footnote.
struct ContextSettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var customText = ""
    @State private var adjustedTo: Int?
    @FocusState private var customFocused: Bool

    var body: some View {
        let selected = ContextSettingsMode.current(in: appState)
        let cap = ContextDefaultCapSetting.presentation(in: appState)
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                heroCard(
                    hero: ContextDefaultCapSetting.hero(cap: ContextDefaultCapSetting.heroCap(
                        stored: ContextDefaultCapSetting.current(in: appState),
                        customText: customText,
                        previous: cap.customPrefill
                    )),
                    selection: cap.selected
                )

                VStack(alignment: .leading, spacing: 12) {
                    sectionHeader(L10n.tr("settings_context_cap_header", table: .settings), icon: "ContextHeaderCap")
                    capSegments(cap)
                    if cap.selected == .custom {
                        customInput(prefill: cap.customPrefill)
                    }
                    footnote(L10n.tr("settings_context_per_chat", table: .settings))
                }

                priceLineReminder

                VStack(alignment: .leading, spacing: 12) {
                    sectionHeader(L10n.tr("settings_context_overflow_header", table: .settings), icon: "ContextHeaderOverflow")
                    HStack(alignment: .top, spacing: 10) {
                        ForEach(ContextSettingsMode.allCases) { mode in
                            Button {
                                mode.apply(to: appState)
                            } label: {
                                modeCard(mode, selected: mode == selected)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    // Both cards take the taller one's height.
                    .fixedSize(horizontal: false, vertical: true)
                }

                localKeptNote
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 32)
            .oriveoContentWidth()
        }
        .scrollDismissesKeyboard(.interactively)
        // The route hides the system navigation bar (oriveoNavigationChrome), so the page draws its own bar.
        .safeAreaInset(edge: .top, spacing: 0) { topBar }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("context_settings_screen")
        .oriveoScreenBackground()
        .toolbar {
            // numberPad has no return key; without this the keyboard cannot be dismissed. Clearing focus commits.
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button(L10n.tr("Done")) { customFocused = false }
                    .font(.body.weight(.semibold))
            }
        }
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

    // MARK: Overview card

    private func heroCard(hero: ContextDefaultCapSetting.Hero, selection: ContextCapPresentation.SettingsSelection) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 8) {
                icon("ContextLimitWindow", size: 16)
                    .foregroundStyle(OriveoTheme.Palette.primary)
                Text(L10n.tr("settings_context_hero_label", table: .settings))
                    .font(.system(size: 12, weight: .medium))
                    .tracking(1.2)
                    .foregroundStyle(OriveoTheme.Palette.textSecondary)
                Spacer(minLength: 8)
                Text(ContextDefaultCapSetting.title(selection))
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(OriveoTheme.Palette.primary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(OriveoTheme.Palette.primarySoft))
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(hero.valueText)
                    .font(.system(size: 44, weight: .semibold).monospacedDigit())
                    .tracking(-1.2)
                    .foregroundStyle(OriveoTheme.Palette.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if hero.showsUnit {
                    Text(L10n.tr("context_cap_input_unit", table: .chat))
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(OriveoTheme.Palette.textSecondary)
                }
            }
            .accessibilityElement(children: .combine)

            heroScale(fill: hero.fill)
                .accessibilityHidden(true)

            Text(hero.caption)
                .font(.system(size: 13))
                .foregroundStyle(OriveoTheme.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 22)
        .padding(.top, 22)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(OriveoTheme.Palette.surface))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(OriveoTheme.Palette.hairline, lineWidth: 1))
    }

    /// Illustrative bar: threshold label above (trailing edge on the fixed tick), fill and tick, "0 / window" labels below.
    private func heroScale(fill: Double) -> some View {
        let marker = ContextDefaultCapSetting.heroPriceLineMarker
        return VStack(spacing: 8) {
            // Price-threshold label sits above the bar, its trailing edge on the tick; grows toward the start edge.
            GeometryReader { geo in
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    Text(L10n.tr("settings_context_scale_price_line", table: .settings))
                        .fixedSize()
                    Color.clear.frame(width: geo.size.width * (1 - marker), height: 0)
                }
                .font(.system(size: 11))
                .foregroundStyle(OriveoTheme.Palette.textTertiary)
                .frame(maxHeight: .infinity)
            }
            .frame(height: 16)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(OriveoTheme.Palette.textPrimary.opacity(0.08))
                    Capsule()
                        .fill(OriveoTheme.Palette.primary)
                        .frame(width: geo.size.width * fill)
                    pinned(at: marker, width: geo.size.width) {
                        RoundedRectangle(cornerRadius: 1)
                            .fill(OriveoTheme.Palette.textPrimary.opacity(0.55))
                            .frame(width: 2, height: 18)
                    }
                }
            }
            .frame(height: 8)
            .animation(.snappy(duration: 0.3), value: fill)

            HStack(spacing: 0) {
                Text(verbatim: "0")
                Spacer(minLength: 8)
                Text(L10n.tr("settings_context_scale_window", table: .settings))
            }
            .font(.system(size: 11))
            .foregroundStyle(OriveoTheme.Palette.textTertiary)
            .lineLimit(1)
            .frame(height: 16)
        }
    }

    /// Centers `content` on the point `ratio` of the way along the leading → trailing axis (mirrors in RTL).
    private func pinned<Content: View>(at ratio: Double, width: CGFloat, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: width * ratio, height: 0)
            Color.clear
                .frame(width: 0, height: 0)
                .overlay { content().fixedSize() }
            Spacer(minLength: 0)
        }
    }

    // MARK: Default cap

    private func capSegments(_ cap: ContextCapPresentation.Settings) -> some View {
        HStack(spacing: 4) {
            ForEach(ContextCapPresentation.SettingsSelection.allCases, id: \.self) { selection in
                Button {
                    select(selection, prefill: cap.customPrefill)
                } label: {
                    capSegment(selection, selected: selection == cap.selected)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(OriveoTheme.Palette.surface))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(OriveoTheme.Palette.hairline, lineWidth: 1))
    }

    private func capSegment(_ selection: ContextCapPresentation.SettingsSelection, selected: Bool) -> some View {
        VStack(spacing: 6) {
            icon(Self.capIcon(selection), size: 22)
            Text(ContextDefaultCapSetting.title(selection))
                .font(.system(size: 13, weight: selected ? .semibold : .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .foregroundStyle(selected ? OriveoTheme.Palette.primary : OriveoTheme.Palette.textSecondary)
        .frame(maxWidth: .infinity, minHeight: 68)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(selected ? OriveoTheme.Palette.surfaceElevated : Color.clear)
                .shadow(color: selected ? OriveoTheme.Palette.shadow : .clear, radius: 1, y: 1)
        )
        .contentShape(Rectangle())
        .animation(.easeOut(duration: 0.2), value: selected)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private static func capIcon(_ selection: ContextCapPresentation.SettingsSelection) -> String {
        switch selection {
        case .auto: "ContextCapAuto"
        case .unlimited: "ContextCapUnlimited"
        case .custom: "ContextCapCustom"
        }
    }

    /// Raw token integer input; the echo below shows the value that would be saved, in compact notation.
    private func customInput(prefill: Int) -> some View {
        let preview = ContextCapPresentation.commit(text: customText, U: nil, previous: prefill)
        return VStack(alignment: .leading, spacing: 10) {
            Text(L10n.tr("context_cap_input_label", table: .chat))
                .font(.system(size: 13))
                .foregroundStyle(OriveoTheme.Palette.textSecondary)

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                TextField(L10n.tr("context_cap_input_label", table: .chat), text: $customText)
                    .keyboardType(.numberPad)
                    .focused($customFocused)
                    .submitLabel(.done)
                    .onSubmit { commitCustom() }
                    .font(.system(size: 30, weight: .semibold).monospacedDigit())
                    .tracking(-0.6)
                    .foregroundStyle(OriveoTheme.Palette.textPrimary)
                Text(L10n.tr("context_cap_input_unit", table: .chat))
                    .font(.system(size: 14))
                    .foregroundStyle(OriveoTheme.Palette.textSecondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(OriveoTheme.Palette.surfaceElevated)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
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

            Text(ContextDefaultCapSetting.customMinText)
                .font(.system(size: 12))
                .foregroundStyle(OriveoTheme.Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(OriveoTheme.Palette.surface))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(OriveoTheme.Palette.hairline, lineWidth: 1))
    }

    // MARK: Price-line reminder

    private var priceLineReminderBinding: Binding<Bool> {
        Binding(
            get: { ContextPriceLineReminderSetting.current(in: appState) },
            set: { ContextPriceLineReminderSetting.apply($0, to: appState) }
        )
    }

    /// Layout rule: leading icon, multi-line text and the trailing switch are all centered on the whole row.
    private var priceLineReminder: some View {
        HStack(alignment: .center, spacing: 14) {
            icon("ContextPriceLine", size: 20)
                .foregroundStyle(OriveoTheme.Palette.primary)
                .frame(width: 36, height: 36)
                .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(OriveoTheme.Palette.primarySoft))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(ContextPriceLineReminderSetting.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(OriveoTheme.Palette.textPrimary)
                Text(ContextPriceLineReminderSetting.footer)
                    .font(.system(size: 12))
                    .foregroundStyle(OriveoTheme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Toggle(
                ContextPriceLineReminderSetting.title,
                isOn: priceLineReminderBinding
            )
            .labelsHidden()
            .tint(OriveoTheme.Palette.primary)
        }
        .padding(.vertical, 16)
        .padding(.leading, 18)
        .padding(.trailing, 16)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(OriveoTheme.Palette.surface))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(OriveoTheme.Palette.hairline, lineWidth: 1))
    }

    // MARK: Overflow mode

    private func modeCard(_ mode: ContextSettingsMode, selected: Bool) -> some View {
        let ink = selected ? OriveoTheme.Palette.primary : OriveoTheme.Palette.textPrimary.opacity(0.28)
        return VStack(alignment: .leading, spacing: 10) {
            modeIllustration(mode, ink: ink)
                .accessibilityHidden(true)

            HStack(alignment: .center, spacing: 8) {
                Text(mode.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(OriveoTheme.Palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                selectionDot(selected)
            }

            Text(mode.hint)
                .font(.system(size: 12))
                .foregroundStyle(OriveoTheme.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            costTag(mode)
        }
        .padding(.horizontal, 10)
        .padding(.top, 10)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(OriveoTheme.Palette.surface))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(selected ? OriveoTheme.Palette.primary : OriveoTheme.Palette.hairline, lineWidth: 1)
        )
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(selected ? OriveoTheme.Palette.primary.opacity(0.08) : .clear, lineWidth: 4)
                .padding(-2)
        )
        .contentShape(Rectangle())
        .animation(.easeOut(duration: 0.2), value: selected)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    /// Small sketch: dropped AI replies as dashed bubbles, or a summary block above the kept turns.
    private func modeIllustration(_ mode: ContextSettingsMode, ink: Color) -> some View {
        let ghost = OriveoTheme.Palette.textPrimary.opacity(0.22)
        return VStack(spacing: 5) {
            switch mode {
            case .fallback:
                bubble(0.62, leading: true) { $0.strokeBorder(ghost, style: StrokeStyle(lineWidth: 1, dash: [3, 2])) }
                bubble(0.54, leading: false) { $0.fill(ink) }
                bubble(0.70, leading: true) { $0.strokeBorder(ghost, style: StrokeStyle(lineWidth: 1, dash: [3, 2])) }
                bubble(0.44, leading: false) { $0.fill(ink) }
            case .aiSummary:
                VStack(alignment: .leading, spacing: 4) {
                    summaryLine(0.84, color: ink)
                    summaryLine(0.64, color: ghost)
                    summaryLine(0.74, color: ghost)
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(OriveoTheme.Palette.hairline))
                bubble(0.50, leading: false) { $0.fill(ink) }
                bubble(0.66, leading: true) { $0.fill(OriveoTheme.Palette.textPrimary.opacity(0.08)) }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 76, maxHeight: 76)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(OriveoTheme.Palette.surfaceInset))
    }

    private func bubble<Bubble: View>(_ ratio: Double, leading: Bool, @ViewBuilder shape: (RoundedRectangle) -> Bubble) -> some View {
        let bubble = shape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        return GeometryReader { geo in
            bubble
                .frame(width: geo.size.width * ratio)
                .frame(maxWidth: .infinity, alignment: leading ? .leading : .trailing)
        }
        .frame(height: 12)
    }

    private func summaryLine(_ ratio: Double, color: Color) -> some View {
        GeometryReader { geo in
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: geo.size.width * ratio)
        }
        .frame(height: 3)
    }

    private func selectionDot(_ selected: Bool) -> some View {
        ZStack {
            if selected {
                Circle().fill(OriveoTheme.Palette.primary)
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(OriveoTheme.Palette.onPrimary)
            } else {
                Circle().strokeBorder(OriveoTheme.Palette.textPrimary.opacity(0.22), lineWidth: 1.5)
            }
        }
        .frame(width: 20, height: 20)
        .accessibilityHidden(true)
    }

    private func costTag(_ mode: ContextSettingsMode) -> some View {
        let extra = mode == .aiSummary
        return HStack(spacing: 4) {
            icon(extra ? "ContextCostExtra" : "ContextCostNone", size: 12)
            Text(L10n.tr(extra ? "settings_context_cost_extra" : "settings_context_cost_none", table: .settings))
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(extra ? OriveoTheme.Palette.warningText : OriveoTheme.Palette.success)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(extra ? OriveoTheme.Palette.warningSoft : OriveoTheme.Palette.successSoft))
    }

    /// Footnote with the local-kept icon; icon and text centered on each other.
    private var localKeptNote: some View {
        HStack(alignment: .center, spacing: 10) {
            icon("ContextLocalKept", size: 16)
                .accessibilityHidden(true)
            Text(L10n.tr("settings_context_overflow_footer", table: .settings))
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(OriveoTheme.Palette.textTertiary)
        .padding(.horizontal, 4)
    }

    // MARK: Shared pieces

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
                .accessibilityIdentifier("settings_context_back_button")
                .padding(.leading, -OriveoBackButton.edgeInset)
                Spacer(minLength: 0)
            }
        }
        .frame(minHeight: OriveoBackButton.hitSize)
        .padding(.horizontal, 20)
    }

    /// Template vector icon from Assets (`shared/icons/context-settings`), tinted by the foreground style.
    private func icon(_ name: String, size: CGFloat) -> some View {
        Image(name)
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
    }

    private func sectionHeader(_ text: String, icon name: String) -> some View {
        HStack(alignment: .center, spacing: 7) {
            icon(name, size: 15)
                .accessibilityHidden(true)
            Text(text)
                .font(.system(size: 13, weight: .semibold))
                .tracking(0.4)
        }
        .foregroundStyle(OriveoTheme.Palette.textTertiary)
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private func footnote(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(OriveoTheme.Palette.textTertiary)
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
}
