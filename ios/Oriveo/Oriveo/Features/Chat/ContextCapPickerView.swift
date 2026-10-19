import OriveoProviderKit
import SwiftUI

/// State behind the per-conversation cap picker (P9 U7 contract items 1, 2): options write at once,
/// follow writes nil, the slider is bound to a tick index and writes on release, the typed number
/// writes on commit. The writer is injected so the view and tests go through the same path.
struct ContextCapPickerState {
    let source: ContextCapPresentation.PanelSource
    private(set) var conversationCap: ContextBudgetCap?
    /// Raw token integer in the custom input.
    var customText: String
    /// Slider position as a tick index.
    private(set) var sliderIndex: Double
    /// The custom value the hint, echo and slider tint follow (saved value, or the tick being dragged).
    private(set) var customValue: Int
    /// Set when the last commit was clamped: the inline "Adjusted to X".
    private(set) var adjustedValue: Int?
    /// Tick index when the slider was pressed; release at the same index writes nothing.
    private var slideStartIndex: Double?

    init(source: ContextCapPresentation.PanelSource) {
        self.source = source
        conversationCap = source.conversationCap
        let model = Self.picker(source, cap: source.conversationCap)
        // The stored custom value is shown as is, even above U (the panel shows the model-limited row).
        let value = if case .custom(let tokens) = source.conversationCap { tokens } else { model.customStart }
        customText = String(value)
        customValue = value
        sliderIndex = Double(model.sliderIndex)
    }

    var model: ContextCapPresentation.PickerModel { Self.picker(source, cap: conversationCap) }

    /// Hint under the custom option for the value being shown.
    var customHint: ContextCapPresentation.CustomHint {
        Self.picker(source, cap: .custom(customValue)).customHint
    }

    /// The slider turns amber past the price line.
    var isAbovePriceLine: Bool {
        guard let line = source.window.priceLineTokens else { return false }
        return customValue > line
    }

    mutating func select(_ selection: ContextCapPresentation.PickerSelection, write: (ContextBudgetCap?) -> Void) {
        adjustedValue = nil
        switch selection {
        case .follow: apply(nil, write: write)
        case .auto: apply(.auto, write: write)
        case .unlimited: apply(.unlimited, write: write)
        case .custom:
            let value = if case .custom(let tokens) = conversationCap { tokens } else { model.customStart }
            setCustom(value)
            apply(.custom(value), write: write)
        }
    }

    /// Commits the typed number; text that does not parse restores the previous value and writes nothing.
    @discardableResult
    mutating func commitCustomText(write: (ContextBudgetCap?) -> Void) -> ContextCapPresentation.Commit {
        let commit = ContextCapPresentation.commit(text: customText, U: model.U, previous: customValue)
        customText = String(commit.value)
        adjustedValue = commit.adjusted ? commit.value : nil
        if !commit.restored {
            setCustom(commit.value)
            apply(.custom(commit.value), write: write)
        }
        return commit
    }

    mutating func beginSlide() {
        slideStartIndex = sliderIndex
    }

    /// Slider moved: input and hint follow the tick; nothing is written until release.
    mutating func slide(to index: Double) {
        sliderIndex = index
        adjustedValue = nil
        customValue = tick(at: index)
        customText = String(customValue)
    }

    /// Writes the tick on release; a tap that leaves the index where it was pressed keeps the saved value.
    mutating func endSlide(write: (ContextBudgetCap?) -> Void) {
        defer { slideStartIndex = nil }
        guard slideStartIndex != sliderIndex else { return }
        apply(.custom(tick(at: sliderIndex)), write: write)
    }

    func tick(at index: Double) -> Int {
        let ticks = model.ticks
        return ticks[min(max(Int(index.rounded()), 0), ticks.count - 1)]
    }

    private mutating func setCustom(_ value: Int) {
        customValue = value
        customText = String(value)
        sliderIndex = Double(ContextCapPresentation.nearestTickIndex(value, ticks: model.ticks))
    }

    private mutating func apply(_ cap: ContextBudgetCap?, write: (ContextBudgetCap?) -> Void) {
        conversationCap = cap
        write(cap)
    }

    private static func picker(
        _ source: ContextCapPresentation.PanelSource,
        cap: ContextBudgetCap?
    ) -> ContextCapPresentation.PickerModel {
        ContextCapPresentation.picker(window: source.window, conversationCap: cap, globalCap: source.globalCap)
    }
}

/// "Limit for this chat" picker pushed from the context panel: head line, follow / automatic /
/// no limit / custom (slider with tick labels, number input, echo and hint), footnote.
struct ContextCapPickerView: View {
    let conversationID: UUID
    let onCapChange: (ContextBudgetCap?) -> Void

    @Environment(AppState.self) private var appState
    @State private var state: ContextCapPickerState
    @FocusState private var customFocused: Bool

    private static let tickLabelFont = UIFont.systemFont(ofSize: 11.5)
    /// Half the system thumb: the track starts this far in from each edge.
    private static let trackInset: CGFloat = 14

    init(
        conversationID: UUID,
        source: ContextCapPresentation.PanelSource,
        onCapChange: @escaping (ContextBudgetCap?) -> Void
    ) {
        self.conversationID = conversationID
        self.onCapChange = onCapChange
        _state = State(initialValue: ContextCapPickerState(source: source))
    }

    var body: some View {
        let model = state.model
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                footnote(headText(model))

                ForEach(
                    [ContextCapPresentation.PickerSelection.follow, .auto, .unlimited, .custom],
                    id: \.self
                ) { selection in
                    Button {
                        select(selection)
                    } label: {
                        option(selection, model: model)
                    }
                    .buttonStyle(.plain)

                    if selection == .custom, model.selected == .custom {
                        customSection(model)
                    }
                }

                footnote(L10n.tr("context_cap_footer", table: .chat))
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 20)
        }
        .navigationTitle(L10n.tr("context_cap_title", table: .chat))
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: customFocused) { _, focused in
            if !focused { commitCustom() }
        }
        .onDisappear {
            if customFocused { commitCustom() }
        }
    }

    // MARK: Actions

    private func select(_ selection: ContextCapPresentation.PickerSelection) {
        state.select(selection, write: onCapChange)
    }

    private func commitCustom() {
        guard state.model.selected == .custom else { return }
        state.commitCustomText(write: onCapChange)
    }

    // MARK: Text

    private static func title(_ selection: ContextCapPresentation.PickerSelection) -> String {
        switch selection {
        case .follow: L10n.tr("context_cap_follow", table: .chat)
        case .auto: L10n.tr("context_cap_auto", table: .chat)
        case .unlimited: L10n.tr("context_cap_unlimited", table: .chat)
        case .custom: L10n.tr("context_cap_custom", table: .chat)
        }
    }

    private func count(_ value: Int) -> String { ContextUsagePanel.isolatedCount(value) }

    /// Display name of the conversation's model; its id when the name is blank or the model is unresolved.
    static func modelName(in appState: AppState, conversationID: UUID) -> String {
        guard let conversation = appState.conversation(for: conversationID) else { return "" }
        let model = appState.currentModel(for: conversation)
        let name = model?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? model?.id ?? conversation.modelID : name
    }

    /// Model, window and usable amount, then the price line when there is one.
    private func headText(_ model: ContextCapPresentation.PickerModel) -> String {
        let name = "\u{2068}\(Self.modelName(in: appState, conversationID: conversationID))\u{2069}"
        guard let window = state.source.window.W, let usable = model.U else {
            return L10n.format(L10n.tr("context_cap_head_unknown", table: .chat), name)
        }
        let head = L10n.format(L10n.tr("context_cap_head", table: .chat), name, count(window), count(usable))
        guard let line = state.source.window.priceLineTokens else { return head }
        return L10n.format(L10n.tr("context_cap_head_price_line", table: .chat), head, count(line))
    }

    /// Option hint and whether it is a price warning (amber).
    private func hint(
        _ selection: ContextCapPresentation.PickerSelection,
        model: ContextCapPresentation.PickerModel
    ) -> (text: String, warning: Bool)? {
        switch selection {
        case .follow:
            return (L10n.format(
                L10n.tr("context_cap_follow_hint", table: .chat),
                ContextDefaultCapSetting.capText(state.source.globalCap)
            ), false)
        case .auto:
            guard let value = model.auto.B else {
                return (L10n.tr("context_cap_hint_window_unknown", table: .chat), false)
            }
            switch model.auto.limitedBy {
            case .priceLine:
                return (L10n.format(L10n.tr("context_cap_auto_hint_price_line", table: .chat), count(value)), false)
            case .autoDefault:
                let key = state.source.window.priceLineTokens == nil
                    ? "context_cap_auto_hint_default" : "context_cap_auto_hint_default_below_line"
                return (L10n.format(
                    L10n.tr(key, table: .chat), count(value), count(ContextBudget.autoCapDefault)
                ), false)
            case .window:
                return (L10n.format(L10n.tr("context_cap_auto_hint_window", table: .chat), count(value)), false)
            case .custom, nil:
                return nil
            }
        case .unlimited:
            guard let usable = model.U else {
                return (L10n.tr("context_cap_hint_window_unknown", table: .chat), false)
            }
            if model.unlimitedCrossesPriceLine, let line = state.source.window.priceLineTokens {
                return (L10n.format(
                    L10n.tr("context_cap_unlimited_hint_price_line", table: .chat), count(usable), count(line)
                ), true)
            }
            return (L10n.format(L10n.tr("context_cap_unlimited_hint", table: .chat), count(usable)), false)
        case .custom:
            return nil
        }
    }

    private func customHintText() -> (text: String, warning: Bool)? {
        let hint = state.customHint
        switch hint.kind {
        case .none:
            return nil
        case .over:
            guard let line = state.source.window.priceLineTokens else { return nil }
            if let mult = ContextUsagePanel.multiplierText(ContextCapPresentation.multiplier(state.source.pricing)) {
                return (L10n.format(L10n.tr("context_cap_custom_over", table: .chat), count(line), mult), true)
            }
            return (L10n.format(L10n.tr("context_cap_custom_over_plain", table: .chat), count(line)), true)
        case .at:
            return (L10n.tr("context_cap_custom_at", table: .chat), false)
        case .under:
            guard let gap = hint.gap else { return nil }
            return (L10n.format(L10n.tr("context_cap_custom_under", table: .chat), count(gap)), false)
        }
    }

    // MARK: Views

    private func footnote(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(OriveoTheme.Palette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 4)
    }

    private func option(
        _ selection: ContextCapPresentation.PickerSelection,
        model: ContextCapPresentation.PickerModel
    ) -> some View {
        let selected = selection == model.selected
        let hint = hint(selection, model: model)
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 22))
                .foregroundStyle(selected ? OriveoTheme.Palette.primary : OriveoTheme.Palette.borderStrong)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(Self.title(selection))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(OriveoTheme.Palette.textPrimary)
                if let hint {
                    Text(hint.text)
                        .font(.system(size: 13.5))
                        .foregroundStyle(hint.warning ? OriveoTheme.Palette.warningText : OriveoTheme.Palette.textSecondary)
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

    private func customSection(_ model: ContextCapPresentation.PickerModel) -> some View {
        let preview = ContextCapPresentation.commit(text: state.customText, U: model.U, previous: state.customValue)
        return VStack(alignment: .leading, spacing: 8) {
            if model.ticks.count > 1 {
                slider(model)
            }

            HStack(spacing: 8) {
                Text(L10n.tr("context_cap_input_label", table: .chat))
                    .font(.system(size: 15))
                    .foregroundStyle(OriveoTheme.Palette.textSecondary)
                TextField(L10n.tr("context_cap_input_label", table: .chat), text: $state.customText)
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
                Text(L10n.format(L10n.tr("context_cap_input_echo", table: .chat), count(preview.value)))
                    .font(.system(size: 13))
                    .foregroundStyle(OriveoTheme.Palette.textSecondary)
            }

            if let adjusted = state.adjustedValue {
                Text(L10n.format(L10n.tr("context_cap_adjusted", table: .chat), count(adjusted)))
                    .font(.system(size: 13))
                    .foregroundStyle(OriveoTheme.Palette.warningText)
            }

            if let hint = customHintText() {
                Text(hint.text)
                    .font(.system(size: 13))
                    .foregroundStyle(hint.warning ? OriveoTheme.Palette.warningText : OriveoTheme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 4)
    }

    /// Slider over the tick ladder (index-bound, writes on release) with end labels and the price-line tick.
    private func slider(_ model: ContextCapPresentation.PickerModel) -> some View {
        let ticks = model.ticks
        let upper = Double(ticks.count - 1)
        return VStack(spacing: 4) {
            Slider(
                value: Binding(
                    get: { state.sliderIndex },
                    set: { state.slide(to: $0) }
                ),
                in: 0...upper,
                step: 1,
                onEditingChanged: { editing in
                    if editing {
                        state.beginSlide()
                    } else {
                        state.endSlide(write: onCapChange)
                    }
                }
            )
            .tint(state.isAbovePriceLine ? OriveoTheme.Palette.warning : OriveoTheme.Palette.primary)
            .accessibilityLabel(Text(L10n.tr("context_cap_custom", table: .chat)))
            .accessibilityValue(Text(L10n.format(
                L10n.tr("context_cap_slider_a11y", table: .chat),
                count(state.tick(at: state.sliderIndex))
            )))

            GeometryReader { proxy in
                let marks = tickMarks(ticks: ticks, priceLineIndex: model.priceLineTickIndex, width: proxy.size.width)
                ZStack(alignment: .topLeading) {
                    ForEach(marks.ticks, id: \.index) { mark in
                        RoundedRectangle(cornerRadius: 1)
                            .fill(mark.isPriceLine ? OriveoTheme.Palette.warning : OriveoTheme.Palette.border)
                            .frame(width: 2, height: mark.isPriceLine ? 7 : 4)
                            .offset(x: mark.x - 1)
                    }
                    ForEach(marks.labels, id: \.index) { label in
                        Text(label.text)
                            .font(.system(size: 11.5).monospacedDigit())
                            .foregroundStyle(
                                label.isPriceLine ? OriveoTheme.Palette.warningText : OriveoTheme.Palette.textTertiary
                            )
                            .fixedSize()
                            .offset(x: label.minX, y: 10)
                    }
                }
            }
            .frame(height: 26)
            .accessibilityHidden(true)
        }
    }

    private struct TickMark {
        var index: Int
        var x: CGFloat
        var isPriceLine: Bool
    }

    private struct TickLabel {
        var index: Int
        var text: String
        var minX: CGFloat
        var width: CGFloat
        var isPriceLine: Bool
        var maxX: CGFloat { minX + width }
    }

    /// Tick positions along the track; end labels, plus the price-line label, which wins over an end label it would overlap.
    private func tickMarks(ticks: [Int], priceLineIndex: Int?, width: CGFloat) -> (ticks: [TickMark], labels: [TickLabel]) {
        let track = max(0, width - Self.trackInset * 2)
        let span = CGFloat(max(ticks.count - 1, 1))
        func x(_ index: Int) -> CGFloat { Self.trackInset + track * CGFloat(index) / span }
        func textWidth(_ text: String) -> CGFloat {
            ceil((text as NSString).size(withAttributes: [.font: Self.tickLabelFont]).width)
        }
        let marks = ticks.indices.map { TickMark(index: $0, x: x($0), isPriceLine: $0 == priceLineIndex) }

        let lowerText = ContextCompactionSeparator.compactCount(ticks[0])
        let upperText = ContextCompactionSeparator.compactCount(ticks[ticks.count - 1])
        let upperWidth = textWidth(upperText)
        var labels = [
            TickLabel(index: 0, text: lowerText, minX: 0, width: textWidth(lowerText), isPriceLine: false),
            TickLabel(
                index: ticks.count - 1, text: upperText, minX: max(0, width - upperWidth), width: upperWidth,
                isPriceLine: false
            ),
        ]
        if let priceLineIndex {
            let text = L10n.format(
                L10n.tr("context_cap_price_line_tick", table: .chat),
                ContextCompactionSeparator.compactCount(ticks[priceLineIndex])
            )
            let labelWidth = textWidth(text)
            let minX = min(max(0, x(priceLineIndex) - labelWidth / 2), max(0, width - labelWidth))
            let label = TickLabel(index: -1, text: text, minX: minX, width: labelWidth, isPriceLine: true)
            labels.removeAll { $0.minX < label.maxX + 6 && label.minX < $0.maxX + 6 }
            labels.append(label)
        }
        return (marks, labels)
    }
}
