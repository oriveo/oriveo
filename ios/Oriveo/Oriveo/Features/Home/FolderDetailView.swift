import SwiftUI

struct FolderDetailView: View {
    let folderID: UUID
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var isEditing = false
    @State private var selectedIDs: Set<UUID> = []
    @State private var showMoveSheet = false
    @State private var showDeleteConfirm = false
    @State private var showBatchDeleteConfirm = false
    @State private var showRenameAlert = false
    @State private var renameText = ""

    private var folder: Folder? {
        appState.folderManager.folder(for: folderID)
    }

    private var conversations: [Conversation] {
        appState.folderManager.searchConversations(in: folderID, matching: searchText)
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: OriveoTheme.Spacing.md) {
                header
                if !isEditing {
                    TextField(L10n.tr("Search in folder...", table: .home), text: $searchText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .padding(.horizontal, OriveoTheme.Spacing.md)
                        .padding(.vertical, OriveoTheme.Spacing.sm)
                        .oriveoRoundedSurface(
                            fill: OriveoTheme.Palette.surfaceInset,
                            border: OriveoTheme.Palette.border,
                            radius: OriveoTheme.Radius.sm,
                            shadow: .none
                        )
                }

                if conversations.isEmpty {
                    emptyState
                } else {
                    ForEach(conversations) { conversation in
                        Button {
                            if isEditing {
                                toggleSelect(conversation.id)
                            } else {
                                appState.openChat(conversationID: conversation.id)
                            }
                        } label: {
                            HStack(spacing: OriveoTheme.Spacing.md) {
                                if isEditing {
                                    selectionIndicator(for: conversation.id)
                                }
                                let provider = appState.provider(for: conversation.providerID)
                                ConversationRow(
                                    conversation: conversation,
                                    provider: provider,
                                    resolvedModelName: ConversationRow.resolveModelName(
                                        for: conversation,
                                        provider: provider
                                    ),
                                    skillIcon: conversation.skillId.flatMap { appState.skillManager.skill(by: $0)?.icon },
                                    isStreaming: appState.streamingConversationIDs.contains(conversation.id)
                                )
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(OriveoTheme.Spacing.xl)
        }
        .oriveoScreenBackground()
        .navigationTitle(folder?.name ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            if isEditing && !selectedIDs.isEmpty {
                editingToolbar
            }
        }
        .onChange(of: appState.foldersVersion) {
            if folder == nil {
                appState.navigation.pop()
            }
        }
        .alert(L10n.tr("Rename Folder", table: .home), isPresented: $showRenameAlert) {
            TextField(L10n.tr("Folder name", table: .home), text: $renameText)
            Button(L10n.tr("Cancel"), role: .cancel) { }
            Button(L10n.tr("Save")) {
                appState.folderManager.renameFolder(id: folderID, newName: renameText)
            }
        }
        .confirmationDialog(
            String(format: L10n.tr("Delete \"%@\"?", table: .home), folder?.name ?? ""),
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button(L10n.tr("Delete Folder", table: .home), role: .destructive) {
                appState.folderManager.deleteFolder(id: folderID)
                ToastManager.shared.show(L10n.tr("Folder deleted", table: .home))
                appState.navigation.pop()
            }
        } message: {
            Text(L10n.tr("Conversations inside will be kept.", table: .home))
        }
        .sheet(isPresented: $showMoveSheet) {
            MoveToFolderSheet(
                convIDs: Array(selectedIDs),
                onComplete: {
                    selectedIDs.removeAll()
                    isEditing = false
                }
            )
            .presentationDetents([.medium])
            .environment(appState)
        }
    }

    private var header: some View {
        HStack(spacing: OriveoTheme.Spacing.sm) {
            Text(folder?.name ?? "")
                .font(OriveoTheme.Typography.title3)
                .foregroundStyle(OriveoTheme.Palette.textPrimary)
                .lineLimit(1)
            Spacer(minLength: OriveoTheme.Spacing.sm)
            Menu {
                Button {
                    renameText = folder?.name ?? ""
                    showRenameAlert = true
                } label: {
                    Label(L10n.tr("Rename"), systemImage: "pencil")
                }
                Button {
                    isEditing.toggle()
                    if !isEditing { selectedIDs.removeAll() }
                } label: {
                    Label(isEditing ? L10n.tr("Done") : L10n.tr("Edit"),
                          systemImage: isEditing ? "checkmark" : "pencil.line")
                }
                Divider()
                Button(role: .destructive) {
                    showDeleteConfirm = true
                } label: {
                    Label(L10n.tr("Delete Folder", table: .home), systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(OriveoTheme.Palette.textSecondary)
                    .frame(width: 38, height: 38)
                    .contentShape(Rectangle())
            }
        }
    }


    private var emptyState: some View {
        VStack(spacing: OriveoTheme.Spacing.md) {
            Spacer().frame(height: OriveoTheme.Spacing.xxl)
            Image(systemName: "folder")
                .font(.system(size: 36))
                .foregroundStyle(OriveoTheme.Palette.textTertiary)
            Text(L10n.tr("No conversations yet", table: .home))
                .font(OriveoTheme.Typography.caption)
                .foregroundStyle(OriveoTheme.Palette.textTertiary)
            Text(L10n.tr("Move conversations here or start a new one", table: .home))
                .font(OriveoTheme.Typography.footnote)
                .foregroundStyle(OriveoTheme.Palette.textTertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }


    private func toggleSelect(_ id: UUID) {
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
    }

    private func selectionIndicator(for id: UUID) -> some View {
        Image(systemName: selectedIDs.contains(id) ? "checkmark.circle.fill" : "circle")
            .foregroundStyle(selectedIDs.contains(id)
                ? OriveoTheme.Palette.primary
                : OriveoTheme.Palette.textTertiary)
    }

    private var editingToolbar: some View {
        HStack(spacing: OriveoTheme.Spacing.lg) {
            Text(String(format: L10n.tr("%d selected"), selectedIDs.count))
                .font(OriveoTheme.Typography.caption)
                .foregroundStyle(OriveoTheme.Palette.textSecondary)

            Spacer()

            Button {
                showMoveSheet = true
            } label: {
                Label(L10n.tr("Move to", table: .home), systemImage: "folder")
                    .font(OriveoTheme.Typography.caption)
            }
            .disabled(selectedIDs.isEmpty)

            Button(role: .destructive) {
                showBatchDeleteConfirm = true
            } label: {
                Label(L10n.tr("Delete"), systemImage: "trash")
                    .font(OriveoTheme.Typography.caption)
            }
            .disabled(selectedIDs.isEmpty)
            .confirmationDialog(
                L10n.tr("Delete selected conversations?", table: .home),
                isPresented: $showBatchDeleteConfirm,
                titleVisibility: .visible
            ) {
                Button(L10n.tr("Delete"), role: .destructive) {
                    appState.deleteConversations(ids: selectedIDs)
                    selectedIDs.removeAll()
                    isEditing = false
                }
            } message: {
                Text(String(format: L10n.tr("%d conversations will be permanently deleted.", table: .home), selectedIDs.count))
            }
        }
        .padding(.horizontal, OriveoTheme.Spacing.lg)
        .padding(.vertical, OriveoTheme.Spacing.md)
        .background(.ultraThinMaterial)
    }
}
