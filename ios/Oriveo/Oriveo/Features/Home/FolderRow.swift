import SwiftUI

struct FolderRow: View {
    let folder: Folder
    let isEditing: Bool
    @Binding var selectedIDs: Set<UUID>

    @Environment(AppState.self) private var appState
    @State private var showRenameAlert = false
    @State private var renameText = ""
    @State private var showDeleteConfirm = false
    @State private var showColorPicker = false
    @State private var conversationToRename: Conversation?
    @State private var convRenameText = ""

    private var isExpanded: Bool {
        appState.folderManager.isExpanded(folder.id)
    }

    private var folderConversations: [Conversation] {
        appState.folderManager.conversations(in: folder.id)
    }

    private var count: Int {
        appState.folderManager.conversationCount(in: folder.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            folderHeader

            if isExpanded {
                folderContent
                    .transition(.opacity)
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: isExpanded)
        .alert(L10n.tr("Rename Folder", table: .home), isPresented: $showRenameAlert) {
            TextField(L10n.tr("Folder name", table: .home), text: $renameText)
            Button(L10n.tr("Cancel"), role: .cancel) { }
            Button(L10n.tr("Save")) {
                appState.folderManager.renameFolder(id: folder.id, newName: renameText)
            }
        }
        .confirmationDialog(
            String(format: L10n.tr("Delete \"%@\"?", table: .home), folder.name),
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button(L10n.tr("Delete Folder", table: .home), role: .destructive) {
                appState.folderManager.deleteFolder(id: folder.id)
                ToastManager.shared.show(L10n.tr("Folder deleted", table: .home))
            }
        } message: {
            Text(L10n.tr("Conversations inside will be kept.", table: .home))
        }
        .alert(
            L10n.tr("Rename Conversation", table: .home),
            isPresented: Binding(
                get: { conversationToRename != nil },
                set: { if !$0 { conversationToRename = nil } }
            )
        ) {
            TextField(L10n.tr("Conversation title", table: .home), text: $convRenameText)
            Button(L10n.tr("Cancel"), role: .cancel) { conversationToRename = nil }
            Button(L10n.tr("Save")) {
                if let conv = conversationToRename {
                    appState.conversationManager.renameConversation(id: conv.id, newTitle: convRenameText)
                    conversationToRename = nil
                }
            }
        }
        .sheet(isPresented: $showColorPicker) {
            FolderColorPicker(
                selectedColor: Binding(
                    get: { FolderColor.from(folder.colorTag) },
                    set: { appState.folderManager.updateFolderColor(id: folder.id, colorTag: $0.rawValue) }
                ),
                onDismiss: { showColorPicker = false }
            )
            .presentationDetents([.height(200)])
            .presentationDragIndicator(.visible)
        }
    }


    private var folderHeader: some View {
        Button {
            appState.folderManager.toggleExpand(folder.id)
        } label: {
            HStack(spacing: OriveoTheme.V2.Sp.s12) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: FolderColor.from(folder.colorTag).gradientColors,
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 34, height: 34)
                    .overlay(
                        Image(systemName: isExpanded ? "folder.fill" : "folder")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                    )
                    .shadow(color: FolderColor.from(folder.colorTag).color.opacity(0.25), radius: 4, y: 2)

                Text(folder.name)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(AuroraTheme.Colors.textPrimary)
                    .lineLimit(1)

                Spacer()

                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(AuroraTheme.Colors.textTertiary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(
                            Capsule(style: .continuous)
                                .fill(OriveoTheme.V2.Colors.bgSubtle)
                        )
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AuroraTheme.Colors.textTertiary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
            .padding(.horizontal, OriveoTheme.V2.Sp.s16)
            .padding(.vertical, 14)
            // The same card surface as the Home conversation groups (radius 20 / dark #221F35 / light pure white)
            .background { AuroraGroupedCard { Color.clear } }
        }
        .buttonStyle(.plain)
        .contextMenu { folderContextMenu }
    }


    private var folderContent: some View {
        let conversations = folderConversations
        return VStack(alignment: .leading, spacing: 0) {
            if conversations.isEmpty {
                VStack(spacing: OriveoTheme.V2.Sp.s12) {
                    Image(systemName: "tray")
                        .font(.system(size: 24, weight: .light))
                        // The empty-state icon uses full opacity: on the group card that is 5.0:1 in dark and 4.8:1 in light
                        // (the earlier 0.72 was tuned for the old V2 surface; on the #221F35 card it dropped to about 4.4:1)
                        .foregroundStyle(OriveoTheme.V2.Colors.textTertiary)

                    VStack(spacing: 4) {
                        Text(L10n.tr("No conversations yet", table: .home))
                            .font(.system(size: 14))
                            .foregroundStyle(OriveoTheme.V2.Colors.textSecondary)
                        Text(L10n.tr("Move conversations here or start a new one", table: .home))
                            .font(.system(size: 13))
                            .foregroundStyle(OriveoTheme.V2.Colors.textTertiary)
                            .multilineTextAlignment(.center)
                    }

                    newChatButton
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, OriveoTheme.V2.Sp.s24)
                .padding(.horizontal, OriveoTheme.V2.Sp.s16)
                .background { AuroraGroupedCard { Color.clear } }
            } else {
                // Conversation list: the same group card as the main Home list, no separators inside
                AuroraGroupedCard {
                    VStack(spacing: 0) {
                        ForEach(conversations) { conversation in
                            conversationInFolder(conversation)
                        }
                    }
                }

                newChatButton
                    .padding(.leading, OriveoTheme.V2.Sp.s4)
            }
        }
        .padding(.top, OriveoTheme.V2.Sp.s8)
    }

    private func conversationInFolder(_ conversation: Conversation) -> some View {
        Button {
            if isEditing {
                if selectedIDs.contains(conversation.id) {
                    selectedIDs.remove(conversation.id)
                } else {
                    selectedIDs.insert(conversation.id)
                }
            } else {
                appState.openChat(conversationID: conversation.id)
            }
        } label: {
            // Editing works like the main Home list: the checkmark is inset 14 and the row gives up its own leading
            // padding (isEditing is passed into the row); otherwise the circle hugs the card edge and the corner clips it
            HStack(spacing: isEditing ? 10 : 12) {
                if isEditing {
                    Image(systemName: selectedIDs.contains(conversation.id)
                        ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 22, weight: .regular))
                        .foregroundStyle(selectedIDs.contains(conversation.id)
                            ? OriveoTheme.V2.Colors.primary
                            : OriveoTheme.V2.Colors.textTertiary)
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
                    grouped: true,
                    isEditing: isEditing,
                    isStreaming: appState.streamingConversationIDs.contains(conversation.id)
                )
                .equatable()
            }
            .padding(.leading, isEditing ? 14 : 0)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            conversationContextMenu(for: conversation)
        }
    }

    private var newChatButton: some View {
        Button {
            guard let convID = appState.folderManager.createConversationInFolder(folder.id) else { return }
            appState.openChat(conversationID: convID)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .medium))
                Text(L10n.tr("New Chat"))
                    .font(.system(size: 13, weight: .medium))
            }
            .foregroundStyle(OriveoTheme.V2.Colors.textTertiary)
            .padding(.vertical, OriveoTheme.V2.Sp.s8)
        }
        .buttonStyle(.plain)
    }


    @ViewBuilder
    private var folderContextMenu: some View {
        Button {
            renameText = folder.name
            showRenameAlert = true
        } label: {
            Label(L10n.tr("Rename"), systemImage: "pencil")
        }

        Button {
            appState.navigation.path.append(.folderDetail(folderID: folder.id))
        } label: {
            Label(L10n.tr("View All", table: .home), systemImage: "list.bullet")
        }

        Button {
            showColorPicker = true
        } label: {
            Label(L10n.tr("Change Color", table: .home), systemImage: "paintpalette")
        }

        Divider()

        Button(role: .destructive) {
            showDeleteConfirm = true
        } label: {
            Label(L10n.tr("Delete Folder", table: .home), systemImage: "trash")
        }
    }

    @ViewBuilder
    private func conversationContextMenu(for conversation: Conversation) -> some View {
        Menu {
            ForEach(appState.folderManager.sortedFolders) { f in
                if f.id != folder.id {
                    Button(f.name) {
                        appState.folderManager.moveConversation(conversation.id, to: f.id)
                        ToastManager.shared.show(
                            String(format: L10n.tr("Moved to folder \"%@\"", table: .home), f.name)
                        )
                    }
                }
            }
            Divider()
            Button(L10n.tr("Remove from Folder", table: .home)) {
                appState.folderManager.moveConversation(conversation.id, to: nil)
                ToastManager.shared.show(L10n.tr("Removed from folder", table: .home))
            }
        } label: {
            Label(L10n.tr("Move to Folder", table: .home), systemImage: "folder")
        }

        Button {
            convRenameText = conversation.title
            conversationToRename = conversation
        } label: {
            Label(L10n.tr("Rename"), systemImage: "pencil")
        }

        Divider()

        Button(role: .destructive) {
            appState.deleteConversation(id: conversation.id)
        } label: {
            Label(L10n.tr("Delete"), systemImage: "trash")
        }
    }
}
