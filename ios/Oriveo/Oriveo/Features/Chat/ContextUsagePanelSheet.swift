import OriveoProviderKit
import SwiftUI

/// View-free values behind the context panel and the settings usage row.
enum ContextUsagePanel {
    /// Sheet heights: opens at large so ring, legend and limit rows are visible at once; medium stays draggable.
    static let detents: Set<PresentationDetent> = [.medium, .large]
    static let initialDetent: PresentationDetent = .large

    enum Segment: Hashable, Sendable {
        case conversation, library, summary, instructions, memory, free
    }

    enum Action: Hashable, Sendable {
        case compact, newChatWithSummary, clear
    }

    /// Segmented ring for percent / never_observed; otherwise a dashed circle with a hint.
    enum Mode: Hashable, Sendable {
        case ring
        case dashed(hintKey: String)
    }

    struct Slice: Hashable, Sendable {
        var segment: Segment
        var tokens: Int
    }

    struct OmittedRow: Hashable, Sendable {
        var kind: ContextSegmentKind
        var count: Int
    }

    // MARK: Ring and legend

    static func mode(for summary: ContextUsageSummary) -> Mode {
        if summary.display == .percent || summary.reason == .neverObserved { return .ring }
        switch summary.reason {
        case .windowUnknown: return .dashed(hintKey: "context_usage_hint_window_unknown")
        case .compactedSince: return .dashed(hintKey: "context_usage_hint_compacted")
        // Compaction cleared since the last send, or the summary has not been read yet.
        case .clearedSince, .neverObserved, nil: return .dashed(hintKey: "context_usage_hint_empty")
        }
    }

    /// Legend rows: segments with tokens > 0; conversation and free are always listed.
    static func legend(for summary: ContextUsageSummary) -> [Slice] {
        guard let segments = summary.segments else { return [] }
        return [
            Slice(segment: .conversation, tokens: segments.conversation),
            Slice(segment: .library, tokens: segments.library),
            Slice(segment: .summary, tokens: segments.summary),
            Slice(segment: .instructions, tokens: segments.instructions),
            Slice(segment: .memory, tokens: segments.memory),
            Slice(segment: .free, tokens: segments.free),
        ].filter { $0.segment == .conversation || $0.segment == .free || $0.tokens > 0 }
    }

    /// Drawn arcs in ring order; free space is the track underneath.
    static func ringSlices(for summary: ContextUsageSummary) -> [Slice] {
        legend(for: summary).filter { $0.segment != .free && $0.tokens > 0 }
    }

    static func omittedRows(for summary: ContextUsageSummary) -> [OmittedRow] {
        guard let omitted = summary.omitted else { return [] }
        return [
            OmittedRow(kind: .notes, count: omitted.notes),
            OmittedRow(kind: .knowledge, count: omitted.knowledge),
            OmittedRow(kind: .memory, count: omitted.memory),
        ].filter { $0.count > 0 }
    }

    // MARK: Actions

    /// [Compact] is always shown; new-chat-with-summary and clear only with a checkpoint.
    static func buttons(for summary: ContextUsageSummary) -> [Action] {
        summary.checkpointCount > 0 ? [.compact, .newChatWithSummary, .clear] : [.compact]
    }

    static func isCompactDisabled(isCompacting: Bool, isSending: Bool) -> Bool {
        isCompacting || isSending
    }

    /// Also disabled while an AI summary compaction of this conversation is in flight.
    static func isCompactDisabled(
        isCompacting: Bool,
        isSending: Bool,
        aiCompactingIDs: Set<UUID>,
        conversationID: UUID
    ) -> Bool {
        isCompactDisabled(isCompacting: isCompacting, isSending: isSending)
            || aiCompactingIDs.contains(conversationID)
    }

    static func showsBreakerRetry(isFallbackOnly: Bool) -> Bool {
        isFallbackOnly
    }

    // MARK: Text

    /// "N%" when measured, about_percent when estimated or never observed; nil when there is no percent.
    static func percentText(_ summary: ContextUsageSummary?, locale: Locale = AppLocalization.currentLocale) -> String? {
        guard let summary else { return nil }
        if summary.display == .percent, let percent = summary.percent {
            return summary.basis == .observed ? "\(percent)%" : aboutPercent(percent, locale: locale)
        }
        if summary.reason == .neverObserved, let estimated = summary.estimatedPercent {
            return aboutPercent(estimated, locale: locale)
        }
        return nil
    }

    /// Settings sheet usage row value.
    static func settingsUsageValue(_ summary: ContextUsageSummary?, locale: Locale = AppLocalization.currentLocale) -> String {
        percentText(summary, locale: locale) ?? L10n.tr("context_usage_unavailable", table: .chat)
    }

    static func usedText(_ summary: ContextUsageSummary, locale: Locale = AppLocalization.currentLocale) -> String? {
        guard let used = summary.used, let B = summary.B else { return nil }
        return "\(ContextCompactionSeparator.compactCount(used, locale: locale)) / "
            + ContextCompactionSeparator.compactCount(B, locale: locale)
    }

    static func basisText(_ summary: ContextUsageSummary) -> String {
        L10n.tr(summary.basis == .observed ? "context_usage_measured" : "context_usage_estimated", table: .chat)
    }

    // MARK: Cap rows

    /// This conversation's cap rows: the cap value, the model-limited note and the window / price-line line.
    struct CapRows: Sendable {
        var source: ContextCapPresentation.PanelSource
        var panel: ContextCapPresentation.Panel

        init(source: ContextCapPresentation.PanelSource, used: Int) {
            self.source = source
            panel = source.panel(used: used)
        }

        /// Price line T drawn on the ring, only when it sits below B.
        var priceLineTick: Int? {
            panel.windowLine == .aboveLine ? source.window.priceLineTokens : nil
        }
    }

    /// Compact number for the cap; the option name when the window is unknown and the cap is auto / unlimited.
    static func capValueText(_ rows: CapRows, locale: Locale = AppLocalization.currentLocale) -> String {
        if let value = rows.panel.capValue { return isolatedCount(value, locale: locale) }
        let key = switch rows.source.cap {
        case .auto: "context_cap_auto"
        case .unlimited: "context_cap_unlimited"
        case .custom: "context_cap_custom"
        }
        return L10n.tr(key, table: .chat)
    }

    /// "Limited by the model to N" when a custom cap is above what the model can take.
    static func limitedText(_ rows: CapRows, locale: Locale = AppLocalization.currentLocale) -> String? {
        guard rows.panel.limitedByModel, let actual = rows.panel.actual else { return nil }
        return L10n.format(
            L10n.tr("context_cap_row_limited", table: .chat),
            locale: locale,
            isolatedCount(actual, locale: locale)
        )
    }

    /// Window line, or the above-the-price-line line; nil when the window is unknown.
    static func windowLineText(_ rows: CapRows, locale: Locale = AppLocalization.currentLocale) -> String? {
        let window = rows.source.window.W.map { isolatedCount($0, locale: locale) }
        let line = rows.source.window.priceLineTokens.map { isolatedCount($0, locale: locale) }
        switch rows.panel.windowLine {
        case .unknown:
            return nil
        case .window:
            guard let window else { return nil }
            return L10n.format(L10n.tr("context_cap_window_line", table: .chat), locale: locale, window)
        case .windowPriceLine:
            guard let window, let line else { return nil }
            if let mult = multiplierText(rows.panel.multiplier, locale: locale) {
                return L10n.format(
                    L10n.tr("context_cap_window_line_price", table: .chat), locale: locale, window, line, mult
                )
            }
            return L10n.format(L10n.tr("context_cap_window_line_price_plain", table: .chat), locale: locale, window, line)
        case .aboveLine:
            guard let line else { return nil }
            return L10n.format(L10n.tr("context_cap_above_line", table: .chat), locale: locale, line)
        }
    }

    /// Long-context multiplier sentence: "both" when the sides are equal, otherwise the sides that are listed.
    static func multiplierText(
        _ multiplier: ContextCapPresentation.Multiplier?,
        locale: Locale = AppLocalization.currentLocale
    ) -> String? {
        guard let multiplier else { return nil }
        let input = multiplier.input.map { tenthsText($0, locale: locale) }
        let output = multiplier.output.map { tenthsText($0, locale: locale) }
        switch (input, output) {
        case let (input?, _) where multiplier.isUniform:
            return L10n.format(L10n.tr("context_cap_mult_both", table: .chat), locale: locale, input)
        case let (input?, output?):
            return L10n.format(L10n.tr("context_cap_mult_split", table: .chat), locale: locale, input, output)
        case let (input?, nil):
            return L10n.format(L10n.tr("context_cap_mult_input", table: .chat), locale: locale, input)
        case let (nil, output?):
            return L10n.format(L10n.tr("context_cap_mult_output", table: .chat), locale: locale, output)
        case (nil, nil):
            return nil
        }
    }

    /// Ring caption: distance to the price line (or already past it) when the cap is above the line.
    static func ringCaption(
        _ summary: ContextUsageSummary,
        rows: CapRows?,
        locale: Locale = AppLocalization.currentLocale
    ) -> String {
        guard summary.used != nil, let rows, rows.priceLineTick != nil,
              let distance = rows.panel.priceLineDistance
        else { return basisText(summary) }
        let observed = summary.basis == .observed
        if distance == 0 {
            return L10n.tr(
                observed ? "context_usage_measured_price_line_crossed" : "context_usage_estimated_price_line_crossed",
                table: .chat
            )
        }
        return L10n.format(
            L10n.tr(observed ? "context_usage_measured_price_line" : "context_usage_estimated_price_line", table: .chat),
            locale: locale,
            isolatedCount(distance, locale: locale)
        )
    }

    /// Tenths as a number in the locale's compact-number decimal: 20 -> "2", 15 -> "1.5".
    static func tenthsText(_ tenths: Int, locale: Locale = AppLocalization.currentLocale) -> String {
        let fraction = tenths % 10
        guard fraction != 0 else { return String(tenths / 10) }
        let code = ContextCompactNumber.resolveLocale(locale.identifier)
        let decimal = ContextCompactNumber.tables.first { $0.code == code }?.table.decimal ?? "."
        return "\(tenths / 10)\(decimal)\(fraction)"
    }

    /// Compact count isolated with FSI…PDI so it keeps its order inside RTL / mixed text.
    static func isolatedCount(_ value: Int, locale: Locale = AppLocalization.currentLocale) -> String {
        "\u{2068}\(ContextCompactionSeparator.compactCount(value, locale: locale))\u{2069}"
    }

    /// "Condensed N times · <relative time>"; nil without a checkpoint or its time.
    static func compactedCountText(
        for summary: ContextUsageSummary,
        now: Date = .now,
        locale: Locale = AppLocalization.currentLocale
    ) -> String? {
        guard summary.checkpointCount > 0, let latest = summary.latestCompactedAt else { return nil }
        let relative = RelativeDateTimeFormatter()
        relative.locale = L10n.formattingLocale(locale)
        relative.unitsStyle = .full
        relative.dateTimeStyle = .named
        return L10n.format(
            L10n.tr("context_usage_compacted_count", table: .chat),
            locale: locale,
            summary.checkpointCount,
            relative.localizedString(for: latest, relativeTo: now)
        )
    }

    static func omittedText(_ row: OmittedRow, locale: Locale = AppLocalization.currentLocale) -> String {
        let key = switch row.kind {
        case .notes: "context_usage_omitted_notes"
        case .knowledge: "context_usage_omitted_knowledge"
        default: "context_usage_omitted_memory"
        }
        return L10n.format(L10n.tr(key, table: .chat), locale: locale, row.count)
    }

    static func label(_ segment: Segment) -> String {
        let key = switch segment {
        case .conversation: "context_usage_segment_conversation"
        case .library: "context_usage_segment_library"
        case .summary: "context_usage_segment_summary"
        case .instructions: "context_usage_segment_instructions"
        case .memory: "context_usage_segment_memory"
        case .free: "context_usage_segment_free"
        }
        return L10n.tr(key, table: .chat)
    }

    static func color(_ segment: Segment) -> Color {
        switch segment {
        case .conversation: OriveoTheme.Palette.primary
        case .library: OriveoTheme.Palette.info
        case .summary: OriveoTheme.Palette.textSecondary
        case .instructions: OriveoTheme.Palette.warning
        case .memory: DetailRowPalette.teal
        case .free: OriveoTheme.Palette.border
        }
    }

    private static func aboutPercent(_ percent: Int, locale: Locale) -> String {
        L10n.format(L10n.tr("context_usage_about_percent", table: .chat), locale: locale, percent)
    }
}

/// Sheet item for the context panel.
struct ContextUsagePanelPresentation: Identifiable {
    let id = UUID()
    let conversationID: UUID
    /// The composer's capability selection, the same source the send path resolves parameters from.
    var capabilitySelection = ChatCapabilitySelection()
}

/// Context panel: segmented usage ring, legend, limits and compaction actions.
struct ContextUsagePanelSheet: View {
    private static let ringDiameter: CGFloat = 200
    private static let ringLineWidth: CGFloat = 16

    let conversationID: UUID
    let summary: ContextUsageSummary
    let isSending: Bool
    /// "Limit for this chat" rows; nil while the conversation's model is unresolved.
    var capRows: ContextUsagePanel.CapRows?
    /// Writes this conversation's cap (nil = follow global); the cap row pushes the picker only when set.
    var onCapChange: ((ContextBudgetCap?) -> Void)?

    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var isCompacting = false
    @State private var isFallbackOnly = false
    @State private var showsCapPicker = false

    /// The "now" for the "Condensed N times · ..." relative time: the system clock; for screenshots only, the context page family pins it to a fixture clock (ContextShots.pinClock).
    static var now: Date {
        #if DEBUG
        if let pinned = ContextShots.pinnedClock { return pinned }
        #endif
        return .now
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: OriveoTheme.Spacing.lg) {
                    ringSection
                        .frame(maxWidth: .infinity)

                    let legend = ContextUsagePanel.legend(for: summary)
                    if !legend.isEmpty {
                        VStack(alignment: .leading, spacing: OriveoTheme.Spacing.sm) {
                            ForEach(legend, id: \.segment) { slice in
                                legendRow(slice)
                            }
                            if let tick = priceLineTick {
                                priceLineLegendRow(tick)
                            }
                        }
                    }

                    if let capRows {
                        capSection(capRows)
                    }

                    VStack(alignment: .leading, spacing: OriveoTheme.Spacing.sm) {
                        ForEach(ContextUsagePanel.omittedRows(for: summary), id: \.self) { row in
                            note(ContextUsagePanel.omittedText(row))
                        }
                        if let compacted = ContextUsagePanel.compactedCountText(for: summary, now: Self.now) {
                            note(compacted)
                        }
                    }

                    if ContextUsagePanel.showsBreakerRetry(isFallbackOnly: isFallbackOnly) {
                        breakerRow
                    }
                }
                .padding(OriveoTheme.Spacing.lg)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { actionBar }
            .navigationTitle(L10n.tr("context_usage_title", table: .chat))
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(isPresented: $showsCapPicker) {
                if let capRows, let onCapChange {
                    ContextCapPickerView(conversationID: conversationID, source: capRows.source, onCapChange: onCapChange)
                }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Text(L10n.tr("Done"))
                    }
                }
            }
        }
        .interactiveDismissDisabled(isCompacting)
        #if DEBUG
        .onAppear {
            // Screenshots only: the context page family pushes the picker page from the panel through the same entry (ContextShots.open).
            if ContextShots.takeCapPicker(conversationID: conversationID) {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 600_000_000)
                    showsCapPicker = true
                }
            }
        }
        #endif
        .task(id: summary.checkpointCount) {
            isFallbackOnly = appState.chatManager.compactionBreakerIsFallbackOnly(conversationId: conversationID)
        }
    }

    // MARK: Ring

    @ViewBuilder
    private var ringSection: some View {
        switch ContextUsagePanel.mode(for: summary) {
        case .ring:
            ZStack {
                Circle()
                    .stroke(ContextUsagePanel.color(.free), lineWidth: Self.ringLineWidth)
                ForEach(arcs, id: \.slice.segment) { arc in
                    Circle()
                        .trim(from: arc.start, to: arc.end)
                        .stroke(ContextUsagePanel.color(arc.slice.segment), lineWidth: Self.ringLineWidth)
                        .rotationEffect(.degrees(-90))
                }
                if let fraction = priceLineFraction {
                    priceLineMark
                        .frame(width: 3, height: Self.ringLineWidth + 8)
                        .offset(y: -(Self.ringDiameter - Self.ringLineWidth) / 2)
                        .rotationEffect(.degrees(360 * fraction))
                }
                VStack(spacing: 4) {
                    if let percent = ContextUsagePanel.percentText(summary) {
                        Text(percent)
                            .font(.system(size: 34, weight: .semibold, design: .rounded))
                            .foregroundStyle(OriveoTheme.Palette.textPrimary)
                    }
                    if let used = ContextUsagePanel.usedText(summary) {
                        Text(used)
                            .font(OriveoTheme.Typography.footnote)
                            .foregroundStyle(OriveoTheme.Palette.textSecondary)
                    }
                    Text(ContextUsagePanel.ringCaption(summary, rows: capRows))
                        .font(OriveoTheme.Typography.caption)
                        .foregroundStyle(OriveoTheme.Palette.textSecondary)
                }
                .multilineTextAlignment(.center)
                .padding(Self.ringLineWidth * 1.5)
            }
            .padding(Self.ringLineWidth / 2)
            .frame(width: Self.ringDiameter, height: Self.ringDiameter)
            .accessibilityElement(children: .combine)
        case .dashed(let hintKey):
            VStack(spacing: OriveoTheme.Spacing.md) {
                ZStack {
                    Circle()
                        .stroke(OriveoTheme.Palette.borderStrong, style: StrokeStyle(lineWidth: 2, dash: [6, 5]))
                    Text(L10n.tr("context_usage_unavailable", table: .chat))
                        .font(OriveoTheme.Typography.body)
                        .foregroundStyle(OriveoTheme.Palette.textSecondary)
                }
                .frame(width: Self.ringDiameter, height: Self.ringDiameter)
                Text(L10n.tr(hintKey, table: .chat))
                    .font(OriveoTheme.Typography.footnote)
                    .foregroundStyle(OriveoTheme.Palette.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private struct Arc {
        let slice: ContextUsagePanel.Slice
        let start: CGFloat
        let end: CGFloat
    }

    /// Cumulative arcs over B, clamped to a full turn.
    private var arcs: [Arc] {
        guard let B = summary.B, B > 0 else { return [] }
        var cursor: CGFloat = 0
        return ContextUsagePanel.ringSlices(for: summary).map { slice in
            let start = cursor
            cursor = min(1, cursor + CGFloat(slice.tokens) / CGFloat(B))
            return Arc(slice: slice, start: start, end: cursor)
        }
    }

    private var priceLineTick: Int? {
        guard ContextUsagePanel.mode(for: summary) == .ring else { return nil }
        return capRows?.priceLineTick
    }

    /// Position of the price line on the ring, as a fraction of B.
    private var priceLineFraction: CGFloat? {
        guard let tick = priceLineTick, let B = summary.B, B > 0 else { return nil }
        return min(1, CGFloat(tick) / CGFloat(B))
    }

    private var priceLineMark: some View {
        Capsule().fill(OriveoTheme.Palette.textPrimary)
    }

    // MARK: Rows

    private func priceLineLegendRow(_ tick: Int) -> some View {
        HStack(spacing: OriveoTheme.Spacing.sm) {
            priceLineMark
                .frame(width: 3, height: 10)
                .frame(width: 10)
            Text(L10n.tr("context_usage_legend_price_line", table: .chat))
                .font(OriveoTheme.Typography.footnote)
                .foregroundStyle(OriveoTheme.Palette.textPrimary)
            Spacer(minLength: 0)
            Text(ContextCompactionSeparator.compactCount(tick))
                .font(OriveoTheme.Typography.footnote.monospacedDigit())
                .foregroundStyle(OriveoTheme.Palette.textSecondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func capSection(_ rows: ContextUsagePanel.CapRows) -> some View {
        VStack(alignment: .leading, spacing: OriveoTheme.Spacing.xs) {
            Button {
                showsCapPicker = true
            } label: {
                HStack(spacing: OriveoTheme.Spacing.sm) {
                    Text(L10n.tr("context_cap_title", table: .chat))
                        .font(OriveoTheme.Typography.body)
                        .foregroundStyle(OriveoTheme.Palette.textPrimary)
                    Spacer(minLength: OriveoTheme.Spacing.sm)
                    Text(ContextUsagePanel.capValueText(rows))
                        .font(OriveoTheme.Typography.body.monospacedDigit())
                        .foregroundStyle(OriveoTheme.Palette.textSecondary)
                    if onCapChange != nil {
                        Image(systemName: "chevron.forward")
                            .font(OriveoTheme.Typography.footnote.weight(.semibold))
                            .foregroundStyle(OriveoTheme.Palette.textTertiary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(onCapChange == nil)
            if let limited = ContextUsagePanel.limitedText(rows) {
                note(limited)
            }
            if let line = ContextUsagePanel.windowLineText(rows) {
                note(line)
            }
        }
    }

    private func legendRow(_ slice: ContextUsagePanel.Slice) -> some View {
        HStack(spacing: OriveoTheme.Spacing.sm) {
            Circle()
                .fill(ContextUsagePanel.color(slice.segment))
                .frame(width: 10, height: 10)
            Text(ContextUsagePanel.label(slice.segment))
                .font(OriveoTheme.Typography.footnote)
                .foregroundStyle(OriveoTheme.Palette.textPrimary)
            Spacer(minLength: 0)
            Text(ContextCompactionSeparator.compactCount(slice.tokens))
                .font(OriveoTheme.Typography.footnote.monospacedDigit())
                .foregroundStyle(OriveoTheme.Palette.textSecondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(OriveoTheme.Typography.footnote)
            .foregroundStyle(OriveoTheme.Palette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var breakerRow: some View {
        VStack(alignment: .leading, spacing: OriveoTheme.Spacing.sm) {
            Text(L10n.tr("context_usage_breaker_paused", table: .chat))
                .font(OriveoTheme.Typography.footnote)
                .foregroundStyle(OriveoTheme.Palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                appState.chatManager.retryCompaction(conversationId: conversationID)
                isFallbackOnly = appState.chatManager.compactionBreakerIsFallbackOnly(conversationId: conversationID)
            } label: {
                Text(L10n.tr("context_usage_retry", table: .chat))
            }
            .buttonStyle(OriveoSecondaryButtonStyle())
        }
        .padding(OriveoTheme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(OriveoTheme.Palette.warningSoft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: Actions

    private var actionBar: some View {
        let actions = ContextUsagePanel.buttons(for: summary)
        return VStack(spacing: OriveoTheme.Spacing.sm) {
            Button {
                compact()
            } label: {
                HStack(spacing: 6) {
                    if isCompacting {
                        ProgressView().controlSize(.small)
                    }
                    Text(L10n.tr("context_compaction_action_compact", table: .chat))
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(OriveoPrimaryButtonStyle())
            .disabled(isCompactDisabled)

            if actions.contains(.newChatWithSummary) || actions.contains(.clear) {
                HStack(spacing: OriveoTheme.Spacing.sm) {
                    if actions.contains(.newChatWithSummary) {
                        Button {
                            ContextCompactionActions(appState: appState, conversationID: conversationID)
                                .startNewChatWithSummary()
                            dismiss()
                        } label: {
                            Text(L10n.tr("context_compaction_action_new_chat_with_summary", table: .chat))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(OriveoSecondaryButtonStyle())
                    }
                    if actions.contains(.clear) {
                        Button {
                            let toast = appState.chatManager.clearCompaction(conversationId: conversationID)
                            ContextCompactionActions.showToast(toast)
                        } label: {
                            Text(L10n.tr("context_compaction_action_clear", table: .chat))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(OriveoSecondaryButtonStyle())
                    }
                }
                .disabled(isCompacting)
            }
        }
        .padding(.horizontal, OriveoTheme.Spacing.lg)
        .padding(.vertical, OriveoTheme.Spacing.md)
        .background(.bar)
    }

    private var isCompactDisabled: Bool {
        ContextUsagePanel.isCompactDisabled(
            isCompacting: isCompacting,
            isSending: isSending,
            aiCompactingIDs: appState.aiCompactingConversationIDs,
            conversationID: conversationID
        )
    }

    private func compact() {
        guard !isCompactDisabled else { return }
        isCompacting = true
        let chatManager = appState.chatManager
        let conversationID = conversationID
        Task {
            let toast = await chatManager.manualCompact(conversationId: conversationID)
            isCompacting = false
            ContextCompactionActions.showToast(toast)
        }
    }
}

/// Panel sheet detents; the selection lives in the sheet content, so every presentation starts at `initialDetent`.
private struct ContextUsagePanelDetents: ViewModifier {
    @State private var selection = ContextUsagePanel.initialDetent

    func body(content: Content) -> some View {
        content.presentationDetents(ContextUsagePanel.detents, selection: $selection)
    }
}

extension View {
    func contextUsagePanelDetents() -> some View {
        modifier(ContextUsagePanelDetents())
    }
}
