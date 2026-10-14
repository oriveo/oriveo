import SwiftUI

/// Cells, selection and writes of the "Change icon" sheet (`pickerCases` in the fixture `relay-avatar-icon.v1.json`).
enum RelayAvatarPicker {
    static let letterKey = "Letter"

    static func cells(for provider: Provider) -> [RelayAvatarPickerCell] {
        RelayAvatarResolver.pickerCells(for: provider)
    }

    /// The selected cell is the one actually drawn right now: with no stored choice, the brand cell or the default icon picked by id.
    static func selectedCell(
        in cells: [RelayAvatarPickerCell],
        provider: Provider,
        choices: RelayAvatarChoiceStore = .shared
    ) -> RelayAvatarPickerCell? {
        guard let avatar = RelayAvatarResolver.avatar(for: provider, choice: choices.choice(for: provider.id)) else {
            return nil
        }
        return cells.first { $0.avatar == avatar }
    }

    static func select(
        _ cell: RelayAvatarPickerCell,
        provider: Provider,
        choices: RelayAvatarChoiceStore = .shared
    ) {
        choices.select(cell, for: provider.id)
    }

    static func title(of cell: RelayAvatarPickerCell) -> String {
        switch cell {
        case let .brand(brand): return brand.kind.displayName
        case let .icon(icon): return L10n.tr(icon.titleKey, table: .providers)
        case .letter: return L10n.tr(letterKey, table: .providers)
        }
    }
}

/// The sheet opened from the detail header avatar: a 4-column grid, each cell a 32pt icon plus a 12pt label; the selected cell gets a light highlight (a selection state, not an avatar backing plate).
struct RelayAvatarPickerSheet: View {
    let provider: Provider

    @Environment(\.dismiss) private var dismiss

    private let columns = Array(repeating: GridItem(.flexible(), spacing: OriveoTheme.Spacing.sm), count: 4)

    var body: some View {
        let cells = RelayAvatarPicker.cells(for: provider)
        let selected = RelayAvatarPicker.selectedCell(in: cells, provider: provider)
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: OriveoTheme.Spacing.sm) {
                    ForEach(cells, id: \.self) { cell in
                        cellButton(cell, isSelected: cell == selected)
                    }
                }
                .padding(OriveoTheme.Spacing.lg)
            }
            .navigationTitle(L10n.tr(RelayDetailBoardModel.changeIconKey, table: .providers))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.tr("Done")) { dismiss() }
                        .font(.body.weight(.semibold))
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func cellButton(_ cell: RelayAvatarPickerCell, isSelected: Bool) -> some View {
        let title = RelayAvatarPicker.title(of: cell)
        return Button(action: {
            RelayAvatarPicker.select(cell, provider: provider)
        }) {
            VStack(spacing: OriveoTheme.Spacing.xs) {
                RelayAvatarView(avatar: cell.avatar, size: 32)
                Text(verbatim: title)
                    .font(.system(size: 12))
                    .foregroundStyle(OriveoTheme.Palette.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, OriveoTheme.Spacing.sm)
            .background(
                RoundedRectangle(cornerRadius: OriveoTheme.Radius.md, style: .continuous)
                    .fill(isSelected ? OriveoTheme.Palette.primarySoft : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: title))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
