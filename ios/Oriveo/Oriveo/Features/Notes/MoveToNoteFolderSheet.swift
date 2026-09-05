import SwiftUI

struct MoveToNoteFolderSheet: View {
    let noteID: UUID
    let current: UUID?
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                row(title: L10n.tr("Uncategorized", table: .notes), folderID: nil, colorTag: nil)
                ForEach(appState.noteFolders) { folder in
                    row(title: folder.name, folderID: folder.id, colorTag: folder.colorTag)
                }
            }
            .navigationTitle(L10n.tr("Move to folder", table: .notes))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.tr("Cancel", table: .notes)) { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private func row(title: String, folderID: UUID?, colorTag: String?) -> some View {
        Button {
            _ = appState.noteManager.moveNote(id: noteID, toFolder: folderID)
            dismiss()
        } label: {
            HStack(spacing: OriveoTheme.Spacing.sm) {
                Image(systemName: folderID == nil ? "tray.fill" : "folder.fill")
                    .foregroundStyle(folderID == nil ? OriveoTheme.Palette.textTertiary : FolderColor.from(colorTag).color)
                Text(title)
                    .foregroundStyle(OriveoTheme.Palette.textPrimary)
                Spacer()
                if folderID == current {
                    Image(systemName: "checkmark").foregroundStyle(OriveoTheme.Palette.primary)
                }
            }
        }
    }
}
