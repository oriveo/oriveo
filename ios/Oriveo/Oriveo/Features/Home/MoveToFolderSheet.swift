import SwiftUI

struct MoveToFolderSheet: View {
    let convIDs: [UUID]
    var onComplete: (() -> Void)?

    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var showNewFolder = false
    @State private var showFolderLimitSheet = false
    @State private var newFolderName = ""

    private var hasConversationsInFolder: Bool {
        convIDs.contains { id in
            appState.conversations.first { $0.id == id }?.folderID != nil
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(appState.folderManager.sortedFolders) { folder in
                        Button {
                            appState.folderManager.batchMove(convIDs, to: folder.id)
                            let msg = convIDs.count == 1
                                ? String(format: L10n.tr("Moved to folder \"%@\"", table: .home), folder.name)
                                : String(format: L10n.tr("Moved %lld conversations to \"%@\"", table: .home), Int64(convIDs.count), folder.name)
                            ToastManager.shared.show(msg)
                            dismiss()
                            onComplete?()
                        } label: {
                            Label {
                                Text(folder.name)
                            } icon: {
                                Image(systemName: "folder.fill")
                                    .foregroundStyle(FolderColor.from(folder.colorTag).color)
                            }
                        }
                    }
                }

                Section {
                    Button {
                        newFolderName = ""
                        showNewFolder = true
                    } label: {
                        Label(L10n.tr("New Folder", table: .home), systemImage: "folder.badge.plus")
                    }
                }

                if hasConversationsInFolder {
                    Section {
                        Button {
                            appState.folderManager.batchMove(convIDs, to: nil)
                            let msg = convIDs.count == 1
                                ? L10n.tr("Removed from folder", table: .home)
                                : String(format: L10n.tr("Removed %lld conversations from folder", table: .home), Int64(convIDs.count))
                            ToastManager.shared.show(msg)
                            dismiss()
                            onComplete?()
                        } label: {
                            Label(L10n.tr("Remove from Folder", table: .home), systemImage: "folder.badge.minus")
                                .foregroundStyle(OriveoTheme.Palette.danger)
                        }
                    }
                }
            }
            .navigationTitle(L10n.tr("Move to Folder", table: .home))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.tr("Cancel")) { dismiss() }
                }
            }
            .alert(L10n.tr("New Folder", table: .home), isPresented: $showNewFolder) {
                TextField(L10n.tr("Folder name", table: .home), text: $newFolderName)
                Button(L10n.tr("Cancel"), role: .cancel) { }
                Button(L10n.tr("Create", table: .home)) {
                    guard !newFolderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                    guard let folder = appState.folderManager.createFolder(name: newFolderName) else { return }
                    appState.folderManager.batchMove(convIDs, to: folder.id)
                    ToastManager.shared.show(
                        String(format: L10n.tr("Moved %lld conversations to \"%@\"", table: .home), Int64(convIDs.count), folder.name)
                    )
                    dismiss()
                    onComplete?()
                }
            }
            .sheet(isPresented: $showFolderLimitSheet) {
                EmptyView()
            }
        }
    }
}
