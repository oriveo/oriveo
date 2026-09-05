import SwiftUI

struct CreateNoteFolderSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var color: FolderColor = .blue

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(L10n.tr("Folder name", table: .notes), text: $name)
                        .onChange(of: name) { _, value in
                            if value.count > Note.folderNameMaxLength {
                                name = String(value.prefix(Note.folderNameMaxLength))
                            }
                        }
                }
                Section(L10n.tr("Color", table: .notes)) {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: OriveoTheme.Spacing.md) {
                        ForEach(FolderColor.ordered, id: \.self) { option in
                            Circle()
                                .fill(option.color)
                                .frame(width: 30, height: 30)
                                .overlay {
                                    if option == color {
                                        Circle().strokeBorder(OriveoTheme.Palette.textPrimary, lineWidth: 2)
                                            .padding(-3)
                                    }
                                }
                                .onTapGesture { color = option }
                        }
                    }
                    .padding(.vertical, OriveoTheme.Spacing.xs)
                }
            }
            .navigationTitle(L10n.tr("New folder", table: .notes))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.tr("Cancel", table: .notes)) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.tr("Create", table: .notes)) {
                        _ = appState.noteManager.createNoteFolder(name: name, colorTag: color.rawValue)
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}
