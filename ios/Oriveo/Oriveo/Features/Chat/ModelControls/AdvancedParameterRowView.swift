import SwiftUI
import UIKit

/// One change the user makes on a row. The row stores no value; it hands the intent to the page.
enum AdvancedParameterEdit: Equatable {
    case set(GenerationParameterValue)
    /// Clears this layer's value and falls back to the layer below (on the conversation page: back to the model default).
    case useDefault
    /// Explicitly does not send this item.
    case omit
}

// MARK: - Presenting a value

/// The value on the right of a row. Three sources, three looks: changed in this layer is a purple chip, inherited from the layer below is a gray chip with small text,
/// and unset everywhere is secondary-colored text (a gray number when the parameter table has an engine default).
struct AdvancedParameterValueBadge: View {
    let row: AdvancedParameterRow
    /// The small text in the gray chip: "Model default" on the conversation page.
    let inheritedLabel: String

    var body: some View {
        if row.model.supersededBy != nil {
            Text(row.trailingText)
                .font(Self.numberFont)
                .strikethrough(true, color: OriveoTheme.Palette.textTertiary.opacity(0.7))
                .foregroundStyle(OriveoTheme.Palette.textTertiary)
        } else if row.isOmitted {
            plain(row.trailingText)
        } else if let value = row.model.displayValue, row.standing == .editedHere {
            let invalid = row.model.validationError != nil
            Text(value)
                .font(Self.numberFont)
                .lineLimit(1)
                .foregroundStyle(invalid ? OriveoTheme.Palette.danger : OriveoTheme.Palette.primaryTextSafe)
                .padding(.horizontal, 11)
                .frame(height: 28)
                .background {
                    Capsule().fill(invalid ? OriveoTheme.Palette.dangerSoft : OriveoTheme.Palette.primarySoft)
                }
        } else if let value = row.model.displayValue, row.standing == .inherited {
            HStack(spacing: 6) {
                Text(value)
                    .font(Self.numberFont)
                    .foregroundStyle(OriveoTheme.Palette.textSecondary)
                Text(inheritedLabel)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(OriveoTheme.Palette.textTertiary)
            }
            .lineLimit(1)
            .padding(.horizontal, 11)
            .frame(height: 28)
            .background { Capsule().fill(OriveoTheme.Palette.textPrimary.opacity(0.06)) }
        } else if let engineDefault = row.engineDefaultText {
            // The engine's own default: it is not sent unless changed, so it is just a gray number without a chip.
            Text(engineDefault)
                .font(.system(size: 15, design: .rounded).monospacedDigit())
                .foregroundStyle(OriveoTheme.Palette.textTertiary)
        } else {
            plain(row.trailingText)
        }
    }

    private func plain(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 14))
            .foregroundStyle(OriveoTheme.Palette.textTertiary)
            .lineLimit(1)
    }

    static let numberFont = Font.system(size: 15, weight: .semibold, design: .rounded).monospacedDigit()
}

// MARK: - One row

/// One parameter's row in advanced settings. The chat page and the provider detail page share this rendering:
/// collapsed it is "title + value", and tapping expands it in place into an editing control.
struct AdvancedParameterRowView: View {
    let row: AdvancedParameterRow
    let isExpanded: Bool
    /// A row that cannot be edited does not expand; it only states its status.
    var isEditable: Bool = true
    var inheritedLabel: String = L10n.tr("Your default", table: .chat)
    /// The label of the "back to model default" button; the provider detail page edits the model default itself, where it is called "Clear".
    var useDefaultTitle: String = L10n.tr("Use model default", table: .chat)
    var showsUnverifiedBadge: Bool = false
    /// A support note for the non-regular cases (regular ones stay silent).
    var statusNote: String?
    /// A value the model fixes: shown directly, which says more than an empty disabled input.
    var fixedValueText: String?
    /// The way forward when it cannot be adjusted (view supported models).
    var disabledActionTitle: String?
    var onDisabledAction: (() -> Void)?
    /// The short title used inside its own family's card (main name + the parameter name in secondary color).
    var shortTitle: (name: String, symbol: String)?
    var focus: FocusState<String?>.Binding
    let onToggle: () -> Void
    let onChange: (AdvancedParameterEdit) -> Void

    @State private var draft = ""
    @State private var pendingStop = ""
    @State private var isAddingStop = false
    @State private var schemaIsInvalid = false

    private var parameter: GenerationParameterRef { row.parameter }
    private var schema: String { parameter.valueSchema ?? "string" }
    private var isNumeric: Bool { schema == "number" || schema == "integer" }
    private var isSuperseded: Bool { row.model.supersededBy != nil }

    /// Validation of a draft that is not a value yet (input such as "abc" that parses to no number); it takes precedence over the note for the stored value.
    private var draftIssue: String? {
        guard isExpanded, isNumeric,
              let issue = GenerationParameterInputValidation.issue(numericDraft: draft, parameter: parameter)
        else { return nil }
        return GenerationParameterInputValidation.message(issue, parameterID: row.id)
    }

    private var notice: (text: String, isError: Bool)? {
        if let draftIssue { return (draftIssue, true) }
        return row.notice
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isExpanded, isEditable {
                expanded
            } else {
                collapsed
            }
        }
        .onAppear(perform: syncDraft)
        .onChange(of: isExpanded) { _, expanded in
            syncDraft()
            // Opening a row means editing it, so the caret goes straight into the field. An empty field
            // only shows a grey fallback note, and without a caret it does not read as an input. The field
            // enters the hierarchy after the row expands, hence the deferred focus request. Rows with a
            // switch or a menu have no field, so the request simply finds nothing. Stop sequences are a
            // set of chips: opening them shows the list first instead of raising the keyboard.
            guard expanded, isEditable, schema != "string-list" else { return }
            Task { @MainActor in focus.wrappedValue = row.id }
        }
        .onChange(of: row.ownValue) { _, _ in
            // Not read back while typing in this row: intermediate states such as `0.` or `-` would be overwritten by the stored value.
            if focus.wrappedValue != row.id { syncDraft() }
        }
    }

    // MARK: Collapsed

    private var collapsed: some View {
        VStack(alignment: .leading, spacing: 6) {
            if isEditable {
                Button(action: onToggle) { summaryLine }
                    .buttonStyle(.plain)
            } else {
                summaryLine
            }
            footnotes
        }
        .padding(.horizontal, 16)
        .padding(.vertical, hasCollapsedFootnotes ? 10 : 0)
    }

    private var hasCollapsedFootnotes: Bool {
        notice != nil || (!isEditable && statusNote != nil) || disabledActionTitle != nil
    }

    private var summaryLine: some View {
        HStack(spacing: 10) {
            titleText(weight: .regular)
            if showsUnverifiedBadge { unverifiedBadge }
            Spacer(minLength: 8)
            if let fixedValueText {
                Text(fixedValueText)
                    .font(.system(size: 14))
                    .foregroundStyle(OriveoTheme.Palette.textTertiary)
            } else {
                AdvancedParameterValueBadge(row: row, inheritedLabel: inheritedLabel)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var titleLabel: Text {
        guard let shortTitle else { return Text(row.model.title) }
        return Text(shortTitle.name)
            + Text(" \(shortTitle.symbol)").foregroundStyle(OriveoTheme.Palette.textTertiary)
    }

    private func titleText(weight: Font.Weight) -> some View {
        titleLabel
            .font(.system(size: 16, weight: weight))
            .strikethrough(isSuperseded, color: OriveoTheme.Palette.textTertiary.opacity(0.7))
            .foregroundStyle(isSuperseded ? OriveoTheme.Palette.textTertiary : OriveoTheme.Palette.textPrimary)
            .multilineTextAlignment(.leading)
    }

    @ViewBuilder
    private var footnotes: some View {
        if let notice {
            Text(notice.text)
                .font(.system(size: 12.5))
                .foregroundStyle(notice.isError ? OriveoTheme.Palette.danger : OriveoTheme.Palette.warningText)
                .fixedSize(horizontal: false, vertical: true)
        }
        // An editable row keeps its support note for the expanded state: one sentence on each of dozens of rows would bury the drop reasons that matter.
        if let statusNote, !isEditable {
            Text(statusNote)
                .font(.caption)
                .foregroundStyle(OriveoTheme.Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let disabledActionTitle, let onDisabledAction {
            Button(action: onDisabledAction) {
                Text(disabledActionTitle)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(OriveoTheme.Palette.primaryTextSafe)
                    .frame(minHeight: 30, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private var unverifiedBadge: some View {
        // A neutral badge, not the warning color: it states "this has not been tested", not "something is wrong here".
        Text(L10n.tr("Unverified", table: .providers))
            .font(.caption2)
            .foregroundStyle(OriveoTheme.Palette.textSecondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background { Capsule().fill(OriveoTheme.Palette.textPrimary.opacity(0.06)) }
    }

    // MARK: Expanded

    private var expanded: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Button(action: onToggle) {
                    titleText(weight: .semibold)
                        .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                inlineControl
            }

            blockControl

            if let notice {
                Text(notice.text)
                    .font(.system(size: 12.5))
                    .foregroundStyle(notice.isError ? OriveoTheme.Palette.danger : OriveoTheme.Palette.warningText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let supersededNote = row.supersededNote {
                // Being taken over is not an error to act on: secondary color, and said only when this row is opened.
                Text(supersededNote)
                    .font(.system(size: 12.5))
                    .foregroundStyle(OriveoTheme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let annotation = GenerationParameterPresentationFacts.annotation(parameterID: row.id) {
                Text(annotation)
                    .font(.system(size: 12.5))
                    .foregroundStyle(OriveoTheme.Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if isNumeric, sliderRange == nil, let range = row.model.allowedRangeText {
                Text(String(format: L10n.tr("Allowed range: %@", table: .chat), range))
                    .font(.system(size: 12.5))
                    .foregroundStyle(OriveoTheme.Palette.textTertiary)
            }
            if let statusNote {
                Text(statusNote)
                    .font(.caption)
                    .foregroundStyle(OriveoTheme.Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                ghostButton(
                    useDefaultTitle, isOn: false
                ) {
                    focus.wrappedValue = nil
                    draft = ""
                    onChange(.useDefault)
                }
                .disabled(row.standing != .editedHere)
                .opacity(row.standing == .editedHere ? 1 : 0.45)
                // A field the upstream requires cannot be removed; a button that would not stop it from being sent would be a lie.
                if row.model.dropReason != .requiredField || row.isOmitted {
                    ghostButton(
                        L10n.tr("Don’t send this setting", table: .chat),
                        isOn: row.isOmitted && row.standing == .editedHere
                    ) {
                        focus.wrappedValue = nil
                        draft = ""
                        onChange(row.isOmitted && row.standing == .editedHere ? .useDefault : .omit)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 16)
    }

    private func ghostButton(
        _ title: String, isOn: Bool, action: @escaping @MainActor () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(isOn ? OriveoTheme.Palette.primaryTextSafe : OriveoTheme.Palette.textSecondary)
                .padding(.horizontal, 13)
                .frame(height: 34)
                .background {
                    Capsule().fill(isOn ? OriveoTheme.Palette.primarySoft : OriveoTheme.Palette.textPrimary.opacity(0.06))
                }
                // The chip is only 34pt tall; the tap target is padded to 44pt.
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Controls that fit to the right of the title: number field, toggle, enum menu.
    @ViewBuilder
    private var inlineControl: some View {
        if isNumeric {
            let invalid = draftIssue != nil || (row.model.validationError != nil && row.standing == .editedHere)
            let isSet = !draft.isEmpty
            TextField(
                "",
                text: Binding(get: { draft }, set: commitNumericDraft),
                prompt: Text(row.isOmitted ? L10n.tr("Omit") : fallbackPrompt)
                    .foregroundStyle(OriveoTheme.Palette.textTertiary)
            )
            .font(.system(size: 17, weight: .semibold, design: .rounded).monospacedDigit())
            .multilineTextAlignment(.trailing)
            // `.decimalPad` has no minus key, and penalty parameters take negative values.
            .keyboardType(.numbersAndPunctuation)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .foregroundStyle(
                invalid ? OriveoTheme.Palette.danger
                    : (isSet ? OriveoTheme.Palette.primaryTextSafe : OriveoTheme.Palette.textPrimary)
            )
            .padding(.horizontal, 12)
            .frame(width: draft.count > 5 ? 124 : 92, height: 38)
            .background {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(
                        invalid ? OriveoTheme.Palette.dangerSoft
                            : (isSet ? OriveoTheme.Palette.primarySoft : OriveoTheme.Palette.textPrimary.opacity(0.05))
                    )
            }
            .focused(focus, equals: row.id)
            .accessibilityLabel(Text(row.model.title))
        } else if schema == "boolean" {
            Toggle("", isOn: Binding(
                get: {
                    if case .boolean(let flag)? = row.effectiveValue ?? row.fallbackValue { return flag }
                    return false
                },
                set: { onChange(.set(.boolean($0))) }
            ))
            .labelsHidden()
            .tint(OriveoTheme.Palette.primaryTextSafe)
            .accessibilityLabel(Text(row.model.title))
        } else if schema == "enum", let options = parameter.enumValues, !options.isEmpty {
            Picker("", selection: Binding(
                get: { row.effectiveValue.map(GenerationParameterValueText.editingText) ?? "" },
                set: { next in
                    if next.isEmpty { onChange(.useDefault) } else { onChange(.set(.string(next))) }
                }
            )) {
                Text(GenerationParameterPresentationFacts.unsetLabel(parameterID: row.id)).tag("")
                ForEach(enumOptions(options), id: \.self) { option in
                    Text(option).tag(option)
                }
            }
            .labelsHidden()
            .tint(OriveoTheme.Palette.primaryTextSafe)
            .accessibilityLabel(Text(row.model.title))
        } else if schema == "string-list" {
            let count = stopList.count
            Text(GenerationParameterStopSequences.limit(for: parameter).map { "\(count) / \($0)" } ?? "\(count)")
                .font(.system(size: 12.5, design: .rounded).monospacedDigit())
                .foregroundStyle(OriveoTheme.Palette.textTertiary)
        }
    }

    /// Controls that take a line of their own under the title: slider, tags, text field.
    @ViewBuilder
    private var blockControl: some View {
        if isNumeric, let sliderRange {
            AdvancedParameterSlider(
                value: Binding(
                    get: { sliderValue(in: sliderRange) },
                    set: { next in
                        focus.wrappedValue = nil
                        let rounded = roundedToStep(next, in: sliderRange)
                        draft = GenerationParameterValueText.number(rounded)
                        onChange(.set(.number(rounded)))
                    }
                ),
                range: sliderRange,
                step: sliderStep(in: sliderRange),
                modelDefault: numericModelDefault,
                defaultLabel: inheritedLabel,
                accessibilityTitle: row.model.title
            )
        } else if schema == "string-list" {
            stopTags
        } else if schema == "json-schema" {
            TextEditor(text: Binding(get: { draft }, set: commitSchemaDraft))
                .font(.system(size: 13, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(minHeight: 112)
                .background {
                    // An error is expressed as a fill: in a dense list a red outline and a gray outline are almost indistinguishable.
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(schemaIsInvalid ? OriveoTheme.Palette.dangerSoft : OriveoTheme.Palette.textPrimary.opacity(0.05))
                }
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .focused(focus, equals: row.id)
                .accessibilityLabel(Text(row.model.title))
        } else if !isNumeric, schema != "boolean", schema != "enum" || (parameter.enumValues ?? []).isEmpty {
            TextField(
                "",
                text: Binding(get: { draft }, set: { next in
                    draft = next
                    if next.isEmpty { onChange(.useDefault) } else { onChange(.set(.string(next))) }
                }),
                prompt: Text(fallbackPrompt).foregroundStyle(OriveoTheme.Palette.textTertiary),
                axis: .vertical
            )
            .font(.system(size: 14, design: .monospaced))
            .lineLimit(1...8)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(OriveoTheme.Palette.textPrimary.opacity(0.05))
            }
            .focused(focus, equals: row.id)
            .accessibilityLabel(Text(row.model.title))
        }
    }

    // MARK: Stop sequences

    private var stopList: [String] {
        if case .stringList(let list)? = row.ownValue { return list }
        if row.standing == .inherited, case .stringList(let list)? = row.effectiveValue { return list }
        return []
    }

    private var stopTags: some View {
        let limit = GenerationParameterStopSequences.limit(for: parameter)
        let list = stopList
        return VStack(alignment: .leading, spacing: 10) {
            AdvancedFlowLayout(spacing: 8) {
                ForEach(list, id: \.self) { sequence in
                    HStack(spacing: 2) {
                        Text(GenerationParameterStopSequences.visible(sequence))
                            .font(.system(size: 13.5, design: .monospaced))
                            .foregroundStyle(
                                GenerationParameterStopSequences.hasInvisibleCharacters(sequence)
                                    ? OriveoTheme.Palette.primaryTextSafe : OriveoTheme.Palette.textPrimary
                            )
                            .lineLimit(1)
                        Button {
                            let next = list.filter { $0 != sequence }
                            if next.isEmpty { onChange(.useDefault) } else { onChange(.set(.stringList(next))) }
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(OriveoTheme.Palette.textTertiary)
                                .frame(width: 30, height: 34)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text(String(
                            format: L10n.tr("Remove %@", table: .chat),
                            GenerationParameterStopSequences.visible(sequence)
                        )))
                    }
                    .padding(.leading, 12)
                    .frame(height: 34)
                    .background {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(OriveoTheme.Palette.textPrimary.opacity(0.06))
                    }
                }
                if !isAddingStop, limit.map({ list.count < $0 }) ?? true {
                    Button {
                        isAddingStop = true
                        focus.wrappedValue = row.id
                    } label: {
                        Text(L10n.tr("Add", table: .chat))
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundStyle(OriveoTheme.Palette.primaryTextSafe)
                            .padding(.horizontal, 13)
                            .frame(height: 34)
                            .background {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(OriveoTheme.Palette.primarySoft)
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
            if isAddingStop {
                HStack(alignment: .top, spacing: 8) {
                    // A vertical input: return inserts a newline, and a newline can itself be part of a stop sequence.
                    TextField(
                        "",
                        text: $pendingStop,
                        prompt: Text(L10n.tr("New stop sequence", table: .chat))
                            .foregroundStyle(OriveoTheme.Palette.textTertiary),
                        axis: .vertical
                    )
                    .font(.system(size: 13.5, design: .monospaced))
                    .lineLimit(1...4)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(OriveoTheme.Palette.textPrimary.opacity(0.05))
                    }
                    .focused(focus, equals: row.id)
                    .accessibilityLabel(Text(L10n.tr("New stop sequence", table: .chat)))

                    Button {
                        if case .added(let next) = GenerationParameterStopSequences.adding(
                            pendingStop, to: list, limit: limit
                        ) {
                            onChange(.set(.stringList(next)))
                        }
                        pendingStop = ""
                        isAddingStop = false
                        focus.wrappedValue = nil
                    } label: {
                        Text(L10n.tr("Add", table: .chat))
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundStyle(OriveoTheme.Palette.primaryTextSafe)
                            .frame(minWidth: 44, minHeight: 36)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(pendingStop.isEmpty)
                    .opacity(pendingStop.isEmpty ? 0.45 : 1)
                }
            }
        }
    }

    // MARK: Numbers

    private var numericFallback: Double? {
        if case .number(let number)? = row.fallbackValue { return number }
        return nil
    }

    /// The slider's "model default" tick only uses a value a lower layer really set; the engine's own default is not "the default you set".
    private var numericModelDefault: Double? {
        if case .number(let number)? = row.modelDefaultValue { return number }
        return nil
    }

    private var fallbackPrompt: String { row.fallbackText }

    /// A slider is offered only when both ends are bounded and the span suits dragging; a parameter with just a lower bound, such as max tokens, gets none.
    private var sliderRange: ClosedRange<Double>? {
        guard let range = parameter.range,
              let lower = range.min ?? range.minExclusive, let upper = range.max ?? range.maxExclusive,
              upper > lower else { return nil }
        if schema == "integer", upper - lower > 100 { return nil }
        return lower...upper
    }

    private func sliderStep(in range: ClosedRange<Double>) -> Double {
        if let step = parameter.range?.step, step > 0 { return step }
        if schema == "integer" { return 1 }
        return range.upperBound - range.lowerBound <= 1 ? 0.01 : 0.05
    }

    private func sliderValue(in range: ClosedRange<Double>) -> Double {
        let current: Double? = {
            if case .number(let number)? = row.effectiveValue { return number }
            return numericFallback
        }()
        // This only places the thumb within the track; an out-of-range value is not changed, and the input still shows it, marked red.
        return min(max(current ?? range.lowerBound, range.lowerBound), range.upperBound)
    }

    private func roundedToStep(_ value: Double, in range: ClosedRange<Double>) -> Double {
        let step = sliderStep(in: range)
        let snapped = (value / step).rounded() * step
        return (snapped * 10_000).rounded() / 10_000
    }

    private func commitNumericDraft(_ raw: String) {
        draft = raw
        guard !raw.trimmingCharacters(in: .whitespaces).isEmpty else {
            onChange(.useDefault)
            return
        }
        // Nothing is written when no number can be parsed (the row is marked red); a parsed number is written as is, out of range or not, without clamping:
        // that item alone is dropped from the outbound request, and the row states the allowed range.
        if let number = Double(GenerationParameterValueText.normalizedNumberInput(raw)) {
            onChange(.set(.number(number)))
        }
    }

    private func commitSchemaDraft(_ raw: String) {
        draft = raw
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            schemaIsInvalid = false
            onChange(.useDefault)
            return
        }
        guard let data = raw.data(using: .utf8),
              let value = try? JSONDecoder().decode(GenerationParameterValue.self, from: data),
              ProfileParamsResolver.isValidGenerationValue(value, for: parameter) else {
            schemaIsInvalid = true
            return
        }
        schemaIsInvalid = false
        onChange(.set(value))
    }

    private func enumOptions(_ declared: [GenerationParameterValue]) -> [String] {
        var result = declared.map(GenerationParameterValueText.editingText)
        // A stored value that is not among the declared options (the model changed) is listed too, or the menu would show a blank.
        if let current = row.effectiveValue.map(GenerationParameterValueText.editingText),
           !current.isEmpty, !result.contains(current) {
            result.append(current)
        }
        return result
    }

    private func syncDraft() {
        guard schema != "string-list", schema != "boolean" else { return }
        draft = GenerationParameterValueText.editingText(row.ownValue)
        schemaIsInvalid = false
    }
}

// MARK: - One group

/// All rows of one group card: parameter rows, mode switches, clusters that expand in place.
/// Both the chat page and the provider detail page use it, so the two never lay rows out differently.
struct AdvancedSettingsSectionBody: View {
    let section: AdvancedSettingsLayout.Section
    let rows: [String: AdvancedParameterRow]
    let facts: [String: AdvancedSettingsCatalog.RowFacts]
    @Binding var expandedRows: Set<String>
    @Binding var expandedClusters: Set<String>
    var inheritedLabel: String
    var useDefaultTitle: String
    var focus: FocusState<String?>.Binding
    let onEdit: (AdvancedParameterRow, AdvancedParameterEdit) -> Void
    let onSupportedModels: (String) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(section.items.enumerated()), id: \.element.id) { index, item in
                if index > 0 { ModelControlHairline() }
                itemView(item)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func itemView(_ item: AdvancedSettingsLayout.Item) -> some View {
        switch item {
        case .parameter(let id):
            parameterRow(id)
        case let .mode(id, description, options):
            if let row = rows[id] {
                AdvancedParameterModeControl(
                    row: row, description: description, options: options,
                    isEditable: facts[id]?.isEditable ?? false
                ) { edit in onEdit(row, edit) }
            }
        case .cluster(let cluster):
            clusterRow(cluster)
            if expandedClusters.contains(cluster.id) {
                ForEach(cluster.memberIDs, id: \.self) { id in
                    ModelControlHairline()
                    parameterRow(id)
                }
            }
        }
    }

    @ViewBuilder
    private func parameterRow(_ id: String) -> some View {
        if let row = rows[id] {
            let rowFacts = facts[id] ?? .init(isEditable: false)
            AdvancedParameterRowView(
                row: row,
                isExpanded: expandedRows.contains(id),
                isEditable: rowFacts.isEditable,
                inheritedLabel: inheritedLabel,
                useDefaultTitle: useDefaultTitle,
                showsUnverifiedBadge: rowFacts.showsUnverifiedBadge,
                statusNote: rowFacts.statusNote,
                fixedValueText: rowFacts.fixedValueText,
                disabledActionTitle: rowFacts.disabledActionTitle,
                onDisabledAction: { onSupportedModels(id) },
                // Inside a mode family's own card (Mirostat), member rows drop the family prefix.
                shortTitle: section.id.hasPrefix("family:")
                    ? GenerationParameterPresentationFacts.memberShortTitle(parameterID: id) : nil,
                focus: focus,
                onToggle: {
                    focus.wrappedValue = nil
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                        if expandedRows.contains(id) { expandedRows.remove(id) } else { expandedRows.insert(id) }
                    }
                },
                onChange: { edit in onEdit(row, edit) }
            )
        }
    }

    private func clusterRow(_ cluster: AdvancedSettingsLayout.Cluster) -> some View {
        let expanded = expandedClusters.contains(cluster.id)
        let summary = AdvancedSettingsLayout.summary(of: cluster, rows: rows)
        return Button {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                if expanded { expandedClusters.remove(cluster.id) } else { expandedClusters.insert(cluster.id) }
            }
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(cluster.title)
                        .font(.system(size: 16))
                        .foregroundStyle(OriveoTheme.Palette.textPrimary)
                        .multilineTextAlignment(.leading)
                    if let subtitle = cluster.subtitle {
                        Text(subtitle)
                            .font(.system(size: 12.5))
                            .foregroundStyle(OriveoTheme.Palette.textTertiary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                AdvancedSummaryText(text: summary.text, emphasized: summary.emphasized)
                AdvancedChevron(isExpanded: expanded)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, cluster.subtitle == nil ? 0 : 8)
            .frame(maxWidth: .infinity, minHeight: cluster.subtitle == nil ? 54 : 58, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(Text(summary.text))
    }
}

// MARK: - Mode switch

/// A segmented mode switch (Mirostat: Off / v1 / v2).
struct AdvancedParameterModeControl: View {
    let row: AdvancedParameterRow
    let description: String?
    let options: [AdvancedSettingsLayout.ModeOption]
    var isEditable: Bool = true
    let onChange: (AdvancedParameterEdit) -> Void

    private var selection: Int {
        if case .number(let number)? = row.effectiveValue ?? row.fallbackValue { return Int(number) }
        return options.first?.value ?? 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            if let description {
                Text(description)
                    .font(.system(size: 12.5))
                    .foregroundStyle(OriveoTheme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Picker(row.model.title, selection: Binding(
                get: { selection },
                set: { onChange(.set(.number(Double($0)))) }
            )) {
                ForEach(options) { option in
                    Text(option.title).tag(option.value)
                }
            }
            .pickerStyle(.segmented)
            .disabled(!isEditable)
            if let notice = row.notice {
                Text(notice.text)
                    .font(.system(size: 12.5))
                    .foregroundStyle(notice.isError ? OriveoTheme.Palette.danger : OriveoTheme.Palette.warningText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }
}

// MARK: - Slider

/// A slider with a "model default" tick. The tick is a reference only and does not snap.
struct AdvancedParameterSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    /// The model default you set; without one neither tick nor label is drawn.
    let modelDefault: Double?
    let defaultLabel: String
    let accessibilityTitle: String

    private static let labelFont = UIFont.systemFont(ofSize: 11.5)

    var body: some View {
        VStack(spacing: 4) {
            Slider(value: $value, in: range, step: step)
                .tint(OriveoTheme.Palette.primary)
                .accessibilityLabel(Text(accessibilityTitle))
            GeometryReader { proxy in
                let marks = AdvancedSliderScale.marks(
                    range: range, modelDefault: modelDefault, defaultLabel: defaultLabel,
                    width: proxy.size.width,
                    textWidth: { ceil(($0 as NSString).size(withAttributes: [.font: Self.labelFont]).width) }
                )
                ZStack(alignment: .topLeading) {
                    if let tickX = marks.defaultTickX {
                        RoundedRectangle(cornerRadius: 1)
                            .fill(OriveoTheme.Palette.textSecondary)
                            .frame(width: 2, height: 7)
                            .offset(x: tickX - 1)
                    }
                    ForEach(marks.labels, id: \.kind) { label in
                        Text(label.text)
                            .font(.system(size: 11.5).monospacedDigit())
                            .foregroundStyle(
                                label.kind == .modelDefault
                                    ? OriveoTheme.Palette.textSecondary : OriveoTheme.Palette.textTertiary
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
}

// MARK: - Small parts

/// Lays tags out with wrapping. With few subviews, measuring each once is enough.
struct AdvancedFlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        return arrange(subviews: subviews, width: width).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let arrangement = arrange(subviews: subviews, width: bounds.width)
        for (index, origin) in arrangement.origins.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y),
                proposal: .init(width: min(arrangement.sizes[index].width, bounds.width), height: nil)
            )
        }
    }

    private func arrange(subviews: Subviews, width: CGFloat) -> (origins: [CGPoint], sizes: [CGSize], size: CGSize) {
        var origins: [CGPoint] = []
        var sizes: [CGSize] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxX: CGFloat = 0
        for subview in subviews {
            var size = subview.sizeThatFits(.unspecified)
            if width.isFinite { size.width = min(size.width, width) }
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            sizes.append(size)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            maxX = max(maxX, x - spacing)
        }
        return (origins, sizes, CGSize(width: maxX, height: y + rowHeight))
    }
}

/// Group heading: 12pt semibold with slight tracking.
struct AdvancedSectionLabel: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .tracking(0.7)
            .foregroundStyle(OriveoTheme.Palette.textSecondary)
            .padding(.horizontal, 6)
            .padding(.top, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}

/// The chevron on the right of cluster and entry rows.
struct AdvancedChevron: View {
    var isExpanded: Bool = false

    var body: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(OriveoTheme.Palette.textTertiary.opacity(0.8))
            .rotationEffect(.degrees(isExpanded ? 90 : 0))
    }
}

/// Summary chip: purple when it holds a value changed in this layer, secondary-colored text otherwise.
struct AdvancedSummaryText: View {
    let text: String
    let emphasized: Bool

    var body: some View {
        if emphasized {
            Text(text)
                .font(AdvancedParameterValueBadge.numberFont)
                .foregroundStyle(OriveoTheme.Palette.primaryTextSafe)
                .lineLimit(1)
                .padding(.horizontal, 11)
                .frame(height: 28)
                .background { Capsule().fill(OriveoTheme.Palette.primarySoft) }
        } else {
            Text(text)
                .font(.system(size: 14))
                .foregroundStyle(OriveoTheme.Palette.textTertiary)
                .lineLimit(1)
        }
    }
}
