import OriveoProviderKit
import SwiftUI

/// The two kinds of L3 items in the editor (segmented choice).
enum MemoryEpisodicKind: String, CaseIterable, Identifiable, Sendable {
    case decision
    case event

    var id: String { rawValue }

    var kind: MemoryKind {
        switch self {
        case .decision: .decision
        case .event: .event
        }
    }

    init(kind: MemoryKind) {
        self = kind == .event ? .event : .decision
    }

    var title: String {
        switch self {
        case .decision: L10n.tr("memory_kind_decision", table: .chat)
        case .event: L10n.tr("memory_kind_event", table: .chat)
        }
    }
}

/// State of the item editor: new / edit, one of four categories, text, code point count.
/// L3: kind is only decision / event, with an extra date, saved as occurredAt at 00:00:00Z of that day.
struct MemoryItemEditorState: Equatable, Identifiable, Sendable {
    enum Mode: Equatable, Sendable {
        case create
        case edit(id: String)
    }

    static let maxLength = 2000

    let mode: Mode
    /// The item's original kind when editing; the category mapping uses it to keep fact.
    let originalKind: MemoryKind?
    var category: MemoryItemGroup
    var text: String
    /// The layer the item belongs to; for episodic the editor switches to the L3 layout.
    var layer: MemoryLayer = .semantic
    var episodicKind: MemoryEpisodicKind = .decision
    /// The L3 date (year, month and day from the device calendar).
    var occurredDate: Date = Date()

    var id: String {
        switch mode {
        case .create: "new"
        case .edit(let id): id
        }
    }

    var isNew: Bool { mode == .create }
    var isEpisodic: Bool { layer == .episodic }

    /// Kind options offered by the editor: L3 has only decision / event; L2 has the representative kind of each of the four categories (excluding decision / event).
    var kindOptions: [MemoryKind] {
        isEpisodic ? MemoryEpisodicKind.allCases.map(\.kind) : MemoryItemGroup.allCases.map { $0.kind(keeping: nil) }
    }

    /// The occurredAt written when saving L3: 00:00:00Z of the chosen day; nil for L2.
    var occurredAt: String? {
        guard isEpisodic else { return nil }
        let day = Calendar.current.dateComponents([.year, .month, .day], from: occurredDate)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        guard let midnight = utc.date(from: day) else { return nil }
        return MemoryItemRepository.timestamp(midnight)
    }

    /// Counted by code point (the same as the other platforms).
    var characterCount: Int { text.unicodeScalars.count }
    var isTooLong: Bool { characterCount > Self.maxLength }
    var trimmedText: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    var canSave: Bool { !isTooLong && !trimmedText.isEmpty }
    /// The kind written on save.
    var kind: MemoryKind { isEpisodic ? episodicKind.kind : category.kind(keeping: originalKind) }

    static func create(category: MemoryItemGroup = .about, text: String = "") -> Self {
        Self(mode: .create, originalKind: nil, category: category, text: text)
    }

    /// New L3: kind defaults to decision, date defaults to today.
    static func createEpisodic(now: Date = Date()) -> Self {
        Self(mode: .create, originalKind: nil, category: .projects, text: "",
             layer: .episodic, episodicKind: .decision, occurredDate: now)
    }

    /// Edit a live item; the id is case-insensitive, and the result is nil when it is not found, deleted, or not in a list group (an L2 event).
    static func edit(itemId: String, in items: [MemoryItem]) -> Self? {
        let target = itemId.lowercased()
        guard let item = items.first(where: { $0.id.lowercased() == target && $0.status != .deleted }) else {
            return nil
        }
        if item.layer == .episodic {
            return Self(mode: .edit(id: item.id), originalKind: item.kind, category: .projects, text: item.content,
                        layer: .episodic, episodicKind: MemoryEpisodicKind(kind: item.kind),
                        occurredDate: localDay(of: item) ?? Date())
        }
        guard let category = MemoryItemGroup(kind: item.kind) else { return nil }
        return Self(mode: .edit(id: item.id), originalKind: item.kind, category: category, text: item.content)
    }

    /// Convert the item's UTC date to the same day on the device calendar, so the date picker shows the day that was stored.
    private static func localDay(of item: MemoryItem) -> Date? {
        guard let date = MemoryEpisodicTime.date(of: item) else { return nil }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return Calendar.current.date(from: utc.dateComponents([.year, .month, .day], from: date))
    }
}

/// Create / edit a memory: category + multi-line text + `n / 2000` at the bottom right; going over shows red text and disables save.
struct MemoryItemEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var state: MemoryItemEditorState
    @FocusState private var isTextFocused: Bool
    let onSave: (MemoryItemEditorState) -> Void

    init(state: MemoryItemEditorState, onSave: @escaping (MemoryItemEditorState) -> Void) {
        _state = State(initialValue: state)
        self.onSave = onSave
    }

    /// Ruled editing area: 17pt body, 28pt line spacing.
    private static let fontSize: CGFloat = 17
    private static let lineHeight: CGFloat = 28
    private static var lineSpacing: CGFloat {
        max(0, lineHeight - UIFont.systemFont(ofSize: fontSize).lineHeight)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            VStack(alignment: .leading, spacing: 0) {
                if state.isEpisodic {
                    episodicFields
                } else {
                    categoryPicker
                }

                ruledEditor
                    .padding(.top, state.isEpisodic ? 16 : 18)

                counter
                    .padding(.top, 10)
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(OriveoTheme.Palette.surface)
        .onAppear { isTextFocused = true }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(28)
        .presentationBackground(OriveoTheme.Palette.surface)
    }

    // MARK: Top bar: Cancel / title / Save

    private var header: some View {
        HStack(spacing: 8) {
            Button {
                dismiss()
            } label: {
                Text(L10n.tr("Cancel"))
                    .font(.system(size: 17))
                    .foregroundStyle(OriveoTheme.Palette.textSecondary)
                    .padding(.horizontal, 12)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)

            Button {
                onSave(state)
                dismiss()
            } label: {
                Text(L10n.tr("Save"))
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(state.canSave
                                     ? OriveoTheme.Palette.primaryTextSafe
                                     : OriveoTheme.Palette.textTertiary)
                    .padding(.horizontal, 12)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!state.canSave)
        }
        .overlay {
            Text(state.isNew
                 ? L10n.tr("memory_editor_title_new", table: .chat)
                 : L10n.tr("memory_editor_title_edit", table: .chat))
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(OriveoTheme.Palette.textPrimary)
                .lineLimit(1)
                .padding(.horizontal, 96)
                .accessibilityAddTraits(.isHeader)
        }
        .frame(height: 52)
        .padding(.horizontal, 8)
        .padding(.top, 14)
    }

    // MARK: Category 2x2 tiles

    private var categoryPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            categoryLabel

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                ForEach(MemoryItemGroup.allCases) { group in
                    Button {
                        state.category = group
                    } label: {
                        MemoryEditorTile(
                            glyph: group.glyph,
                            glyphSize: 18,
                            hue: group.hue,
                            title: group.title,
                            isSelected: state.category == group
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// The "Category" subheading (shared by L2 / L3).
    private var categoryLabel: some View {
        Text(L10n.tr("memory_editor_category", table: .chat))
            .font(.system(size: 12.5, weight: .semibold))
            .tracking(0.5)
            .foregroundStyle(OriveoTheme.Palette.textTertiary)
            .padding(.leading, 2)
            .accessibilityAddTraits(.isHeader)
    }

    // MARK: L3: decision / event + calendar tile

    private var episodicFields: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
            categoryLabel
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                ForEach(MemoryEpisodicKind.allCases) { kind in
                    Button {
                        state.episodicKind = kind
                    } label: {
                        MemoryEditorTile(
                            glyph: kind == .decision ? .diamond : .ring,
                            glyphSize: 16,
                            hue: OriveoTheme.Palette.memoryHue.episodic,
                            title: kind.title,
                            isSelected: state.episodicKind == kind
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .accessibilityLabel(L10n.tr("memory_editor_category", table: .chat))
            }

            dateBlock
        }
    }

    /// Calendar tile: custom-drawn appearance; taps land on the system compact date picker layered on top (popover style), which only switches to the brand color.
    private var dateBlock: some View {
        HStack(spacing: 12) {
            VStack(spacing: 0) {
                OriveoTheme.Palette.memoryHue.episodic
                    .frame(height: 12)
                Text(verbatim: "\(Calendar.current.component(.day, from: state.occurredDate))")
                    .font(OriveoTheme.Typography.brandDigits(18))
                    .tracking(-0.5)
                    .foregroundStyle(OriveoTheme.Palette.textPrimary)
                    .frame(maxHeight: .infinity)
            }
            .frame(width: 40, height: 44)
            .background(OriveoTheme.Palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(OriveoTheme.Palette.border, lineWidth: 0.5)
            )
            .shadow(color: OriveoTheme.Palette.shadow.opacity(colorScheme == .dark ? 0 : 0.6), radius: 3, y: 2)

            VStack(alignment: .leading, spacing: 1) {
                Text(L10n.tr("memory_item_date", table: .chat))
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(OriveoTheme.Palette.textTertiary)
                Text(verbatim: Self.dayString(state.occurredDate))
                    .font(OriveoTheme.Typography.brandDigits(16))
                    .foregroundStyle(OriveoTheme.Palette.textPrimary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: "chevron.forward")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(OriveoTheme.Palette.textTertiary)
        }
        .padding(.leading, 12)
        .padding(.trailing, 12)
        .frame(height: 64)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(OriveoTheme.Palette.surfaceInset)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(OriveoTheme.Palette.border, lineWidth: 0.5)
        )
        .accessibilityHidden(true)
        .overlay {
            DatePicker(
                L10n.tr("memory_item_date", table: .chat),
                selection: $state.occurredDate,
                displayedComponents: .date
            )
            .datePickerStyle(.compact)
            .labelsHidden()
            .tint(OriveoTheme.Palette.primaryTextSafe)
            // The system control only recognizes its own button area: scale it to cover the whole tile and multiply its color to fully transparent (still tappable), so a tap anywhere opens the system date picker
            .scaleEffect(x: 3.2, y: 1.6)
            .colorMultiply(.clear)
            .opacity(0.011)
            .accessibilityLabel(L10n.tr("memory_item_date", table: .chat))
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private static func dayString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    // MARK: Ruled editing area + character count ring

    private var ruledEditor: some View {
        TextEditor(text: $state.text)
            .focused($isTextFocused)
            .font(.system(size: Self.fontSize))
            .lineSpacing(Self.lineSpacing)
            .foregroundStyle(OriveoTheme.Palette.textPrimary)
            .tint(OriveoTheme.Palette.primary)
            .scrollContentBackground(.hidden)
            .padding(.horizontal, 11)
            .padding(.vertical, 4)
            .frame(maxHeight: .infinity)
            .background {
                // Ruled lines at 28pt line spacing (6% ink), aligned with the bottom of the body lines; decoration only
                Canvas { context, size in
                    var rules = Path()
                    var y: CGFloat = 12 + Self.lineHeight - 1
                    while y < size.height - 4 {
                        rules.move(to: CGPoint(x: 16, y: y))
                        rules.addLine(to: CGPoint(x: size.width - 16, y: y))
                        y += Self.lineHeight
                    }
                    context.stroke(rules, with: .color(OriveoTheme.Palette.textPrimary.opacity(colorScheme == .dark ? 0.05 : 0.06)), lineWidth: 1)
                }
                .accessibilityHidden(true)
            }
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(OriveoTheme.Palette.surfaceInset)
            )
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(
                        state.isTooLong ? OriveoTheme.Palette.danger : OriveoTheme.Palette.border,
                        lineWidth: state.isTooLong ? 1 : 0.5
                    )
            )
    }

    private var counter: some View {
        HStack(spacing: 8) {
            if state.isTooLong {
                Text(L10n.tr("memory_editor_too_long", table: .chat))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(OriveoTheme.Palette.danger)
            }
            Spacer(minLength: 0)
            let progress = min(1, CGFloat(state.characterCount) / CGFloat(MemoryItemEditorState.maxLength))
            ZStack {
                Circle()
                    .stroke(OriveoTheme.Palette.borderStrong, lineWidth: 2.2)
                Circle()
                    .trim(from: 0, to: max(0.02, progress))
                    .stroke(
                        state.isTooLong ? OriveoTheme.Palette.danger : OriveoTheme.Palette.primary,
                        style: StrokeStyle(lineWidth: 2.2, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 15, height: 15)
            .accessibilityHidden(true)
            Text(verbatim: "\(state.characterCount) / \(MemoryItemEditorState.maxLength)")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(state.isTooLong ? OriveoTheme.Palette.danger : OriveoTheme.Palette.textTertiary)
        }
    }
}

/// Editor category tile: 14pt rounded inset background; when selected, a light hue fill + 1.5pt hue stroke + a checkmark circle on the right.
private struct MemoryEditorTile: View {
    @Environment(\.colorScheme) private var colorScheme
    let glyph: MemoryGlyph.Kind
    let glyphSize: CGFloat
    let hue: Color
    let title: String
    let isSelected: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        HStack(spacing: 9) {
            MemoryGlyph(kind: glyph, size: glyphSize)
                .foregroundStyle(hue)
                .frame(width: 18)
            Text(title)
                .font(.system(size: 15, weight: isSelected ? .semibold : .medium))
                .foregroundStyle(OriveoTheme.Palette.textPrimary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 4)
            if isSelected {
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .heavy))
                    .foregroundStyle(OriveoTheme.Palette.surface)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(hue))
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, minHeight: 52)
        .background {
            if isSelected {
                ZStack {
                    shape.fill(OriveoTheme.Palette.surface)
                    shape.fill(hue.opacity(colorScheme == .dark ? 0.12 : 0.08))
                }
            } else {
                shape.fill(OriveoTheme.Palette.surfaceInset)
            }
        }
        .overlay {
            shape.strokeBorder(isSelected ? hue : OriveoTheme.Palette.border, lineWidth: isSelected ? 1.5 : 0.5)
        }
        .contentShape(shape)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}
