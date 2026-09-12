import SwiftUI

struct NotesView: View {
    @Environment(AppState.self) private var appState

    private enum Tab: Hashable { case notes, trash }

    @State private var tab: Tab = .notes
    @State private var searchText = ""
    @State private var searchResults: [NoteSummary] = []
    @State private var searchTask: Task<Void, Never>?
    @State private var folderFilter: NoteFolderFilter = .all
    @State private var sortKey: NoteSortKey = .updatedAt
    @State private var selectedTags: Set<String> = []
    @State private var visibleCount = NotesView.pageSize
    @State private var showNewFolderSheet = false
    @State private var showEmptyTrashConfirm = false
    @State private var moveSheetNote: NoteSummary?
    @State private var permanentDeleteNote: NoteSummary?
    @State private var folderToEdit: NoteFolder?
    @State private var folderToManage: NoteFolder?
    @State private var folderDeleteConfirming = false
    static let pageSize = 10

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: OriveoTheme.Spacing.lg) {
                header
                tabSwitcher
                if tab == .notes {
                    notesSection
                } else {
                    trashSection
                }
            }
            .padding(.horizontal, OriveoTheme.Spacing.lg)
            .padding(.vertical, OriveoTheme.Spacing.md)
        }
        .background(notesBackground.ignoresSafeArea())
        .navigationTitle(L10n.tr("Notes", table: .notes))
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: L10n.tr("Search notes, tags, remarks...", table: .notes))
        .onChange(of: searchText) { _, _ in scheduleSearch() }
        .onChange(of: tab) { _, _ in resetPagingAndSearch() }
        .onChange(of: folderFilter) { _, _ in
            selectedTags = []
            visibleCount = NotesView.pageSize
        }
        .onChange(of: sortKey) { _, _ in visibleCount = NotesView.pageSize }
        .sheet(isPresented: $showNewFolderSheet) {
            CreateNoteFolderSheet()
        }
        .sheet(item: $moveSheetNote) { summary in
            MoveToNoteFolderSheet(noteID: summary.id, current: summary.noteFolderID)
        }
        .confirmationDialog(
            L10n.tr("Delete permanently", table: .notes),
            isPresented: Binding(
                get: { permanentDeleteNote != nil },
                set: { if !$0 { permanentDeleteNote = nil } }
            ),
            titleVisibility: .visible,
            presenting: permanentDeleteNote
        ) { summary in
            Button(L10n.tr("Delete permanently", table: .notes), role: .destructive) {
                appState.noteManager.permanentlyDeleteNote(id: summary.id)
            }
            Button(L10n.tr("Cancel", table: .notes), role: .cancel) {}
        } message: { _ in
            Text(L10n.tr("This note will be permanently deleted and can't be recovered.", table: .notes))
        }
        .sheet(item: $folderToEdit) { folder in
            EditNoteFolderSheet(folder: folder)
        }
    }

    // MARK: Header

    private var notesBackground: LinearGradient { NotesChrome.background }

    @ViewBuilder
    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: OriveoTheme.Spacing.sm) {
                brandIcon
                Text(L10n.tr("Notes", table: .notes))
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(OriveoTheme.Palette.textPrimary)
                Spacer(minLength: 0)
                headerActionButton(systemImage: "folder.badge.plus",
                                   tint: AuroraTheme.Colors.textSecondary,
                                   accessibility: L10n.tr("New folder", table: .notes)) {
                    showNewFolderSheet = true
                }
                headerActionButton(systemImage: "square.and.pencil",
                                   tint: AuroraTheme.Colors.textSecondary,
                                   accessibility: L10n.tr("New note", table: .notes)) {
                    createBlankNote()
                }
            }

        }
        .padding(.top, OriveoTheme.Spacing.xs)
    }

    /// The brand notes icon top-left (white glyph on violet with a violet glow) instead of the grey cloud icon.
    private var brandIcon: some View {
        RoundedRectangle(cornerRadius: OriveoTheme.Radius.chip, style: .continuous)
            .fill(OriveoTheme.Palette.primary)
            .frame(width: 40, height: 40)
            .overlay(
                // The same Lucide notebook-pen glyph as the Home Notes entry (Home uses the thin gradient version,
                // NotesNotebookLine, without the binder ticks). Change one and the other must follow, otherwise
                // the icon changes when arriving from Home.
                Image("NotesNotebook")
                    .renderingMode(.template)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 19, height: 19)
                    .foregroundStyle(.white)
            )
            .shadow(color: OriveoTheme.Palette.primary.opacity(0.35), radius: 8, y: 4)
    }

    /// Action icon button: a bare icon with no fill, 16pt medium, 38×38, neutral grey `AuroraTheme.Colors.textSecondary`.
    /// The Home top bar uses its own "search | new folder" capsule metrics; the two screens no longer share constants.
    private func headerActionButton(systemImage: String, tint: Color, accessibility: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 38, height: 38)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibility)
    }

    @ViewBuilder
    private var tabSwitcher: some View {
        Picker("", selection: $tab) {
            Label(L10n.tr("Notes", table: .notes), systemImage: "note.text").tag(Tab.notes)
            Label(trashTabLabel, systemImage: "trash").tag(Tab.trash)
        }
        .pickerStyle(.segmented)
        .labelStyle(.titleAndIcon)
    }

    private var trashTabLabel: String {
        let n = appState.trashedNoteSummaries.count
        return n > 0 ? "\(L10n.tr("Trash", table: .notes)) (\(n))" : L10n.tr("Trash", table: .notes)
    }

    // MARK: Notes section

    @ViewBuilder
    private var notesSection: some View {
        folderRail
        if !scopedTags.isEmpty {
            tagFilterRail
        }
        sortAndCount
        let notes = displayedNotes
        if notes.isEmpty {
            emptyState
        } else {
            ForEach(notes.prefix(visibleCount)) { summary in
                Button {
                    appState.openNoteDetail(noteID: summary.id)
                } label: {
                    NoteCard(summary: summary)
                }
                .buttonStyle(.plain)
                .contextMenu { cardMenu(summary) }
                .padding(.bottom, 6)
            }
            if notes.count > visibleCount {
                showMoreButton(remaining: notes.count - visibleCount)
            }
        }
    }

    @ViewBuilder
    private func cardMenu(_ summary: NoteSummary) -> some View {
        Button {
            _ = appState.noteManager.setPinned(id: summary.id, isPinned: !summary.isPinned)
        } label: {
            Label(summary.isPinned ? L10n.tr("Unpin", table: .notes) : L10n.tr("Pin", table: .notes),
                  systemImage: summary.isPinned ? "pin.slash" : "pin")
        }
        Button {
            moveSheetNote = summary
        } label: {
            Label(L10n.tr("Move to folder", table: .notes), systemImage: "folder")
        }
        Button(role: .destructive) {
            deleteNote(summary)
        } label: {
            Label(L10n.tr("Delete", table: .notes), systemImage: "trash")
        }
    }

    @ViewBuilder
    private func folderActionMenu(_ folder: NoteFolder) -> some View {
        VStack(spacing: 0) {
            if folderDeleteConfirming {
                Button {
                    folderDeleteConfirming = false
                } label: {
                    Label(L10n.tr("Cancel"), systemImage: "xmark")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .padding(.horizontal, 18)
                        .padding(.vertical, 14)
                }
                .foregroundStyle(OriveoTheme.Palette.textPrimary)
                Divider()
                Button(role: .destructive) {
                    appState.noteManager.deleteNoteFolder(id: folder.id)
                    ToastManager.shared.show(L10n.tr("Folder deleted", table: .home))
                    folderDeleteConfirming = false
                    folderToManage = nil
                } label: {
                    Label(String(format: L10n.tr("Delete \"%@\"?", table: .home), folder.name), systemImage: "trash")
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .padding(.horizontal, 18)
                        .padding(.vertical, 14)
                }
            } else {
                Button {
                    folderToManage = nil
                    folderToEdit = folder
                } label: {
                    Label(L10n.tr("Edit", table: .notes), systemImage: "pencil")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .padding(.horizontal, 18)
                        .padding(.vertical, 14)
                }
                .foregroundStyle(OriveoTheme.Palette.textPrimary)
                Divider()
                Button(role: .destructive) {
                    folderDeleteConfirming = true
                } label: {
                    Label(L10n.tr("Delete Folder", table: .home), systemImage: "trash")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .padding(.horizontal, 18)
                        .padding(.vertical, 14)
                }
            }
        }
        .frame(width: 220)
    }

    @ViewBuilder
    private var folderRail: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: OriveoTheme.Spacing.sm) {
                folderChip(title: L10n.tr("All notes", table: .notes),
                           count: appState.noteSummaries.count,
                           filter: .all,
                           icon: "square.grid.2x2.fill",
                           tint: OriveoTheme.Palette.primary,
                           showCount: false)
                ForEach(appState.noteFolders) { folder in
                    folderChip(title: folder.name,
                               count: appState.noteSummaries.count { $0.noteFolderID == folder.id },
                               filter: .folder(folder.id),
                               icon: "folder.fill",
                               tint: FolderColor.from(folder.colorTag).color)
                        .onLongPressGesture {
                            OriveoHaptic.tap()
                            folderDeleteConfirming = false
                            folderToManage = folder
                        }
                        .popover(isPresented: Binding(
                            get: { folderToManage?.id == folder.id },
                            set: { if !$0 { folderToManage = nil; folderDeleteConfirming = false } }
                        )) {
                            folderActionMenu(folder)
                                .presentationCompactAdaptation(.popover)
                        }
                }
                let unc = NoteListPresentation.uncategorizedCount(appState.noteSummaries)
                if NoteListPresentation.shouldShowUncategorizedFilter(uncategorizedCount: unc) {
                    folderChip(title: L10n.tr("Uncategorized", table: .notes),
                               count: unc, filter: .uncategorized,
                               icon: "tray.fill",
                               tint: OriveoTheme.Palette.textSecondary)
                }
            }
            .padding(.vertical, 2)
        }
    }

    @ViewBuilder
    private func folderChip(title: String, count: Int, filter: NoteFolderFilter, icon: String, tint: Color, showCount: Bool = true) -> some View {
        let active = folderFilter == filter
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(active ? Color.white : tint)
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(active ? Color.white : OriveoTheme.Palette.textPrimary)
            if showCount {
                Text("\(count)")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(active ? Color.white.opacity(0.75) : OriveoTheme.Palette.textTertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(active ? tint : OriveoTheme.Palette.surfaceElevated)
        )
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onTapGesture { withAnimation(.snappy(duration: 0.2)) { folderFilter = filter } }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder
    private var tagFilterRail: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(scopedTags, id: \.self) { tag in
                    let active = selectedTags.contains(tag)
                    NoteTagChip(
                        tag: tag,
                        brand: OriveoTheme.Palette.primary,
                        hasSource: false,
                        isSelected: active,
                        onTap: {
                            withAnimation(.snappy(duration: 0.2)) {
                                if active { selectedTags.remove(tag) } else { selectedTags.insert(tag) }
                            }
                            visibleCount = NotesView.pageSize
                        }
                    )
                }
            }
            .padding(.vertical, 2)
        }
    }

    @ViewBuilder
    private var sortAndCount: some View {
        HStack {
            Menu {
                Picker("", selection: $sortKey) {
                    Text(L10n.tr("Updated", table: .notes)).tag(NoteSortKey.updatedAt)
                    Text(L10n.tr("Created", table: .notes)).tag(NoteSortKey.createdAt)
                    Text(L10n.tr("Source model", table: .notes)).tag(NoteSortKey.sourceProviderKind)
                }
            } label: {
                Label(sortLabel, systemImage: "slider.horizontal.3")
                    .font(OriveoTheme.Typography.footnote.weight(.medium))
                    .foregroundStyle(OriveoTheme.Palette.textSecondary)
            }
            Spacer()
        }
    }

    private var sortLabel: String {
        switch sortKey {
        case .updatedAt: return L10n.tr("Updated", table: .notes)
        case .createdAt: return L10n.tr("Created", table: .notes)
        case .sourceProviderKind: return L10n.tr("Source model", table: .notes)
        }
    }

    @ViewBuilder
    private func showMoreButton(remaining: Int) -> some View {
        Button {
            visibleCount += NotesView.pageSize
        } label: {
            Text(String(format: L10n.tr("Show More (%d)", table: .notes), remaining))
                .font(OriveoTheme.Typography.caption.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, OriveoTheme.Spacing.md)
                .background(RoundedRectangle(cornerRadius: OriveoTheme.Radius.inset).fill(OriveoTheme.Palette.surfaceInset))
        }
        .buttonStyle(.plain)
        .foregroundStyle(OriveoTheme.Palette.textSecondary)
        .padding(.top, OriveoTheme.Spacing.xs)
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: OriveoTheme.Spacing.md) {
            Image(systemName: "doc.text")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(OriveoTheme.Palette.textTertiary)
            Text(L10n.tr("No notes yet", table: .notes))
                .font(OriveoTheme.Typography.title3)
                .foregroundStyle(OriveoTheme.Palette.textPrimary)
            Text(L10n.tr("In chat, save a strong answer or select a passage to send it here.", table: .notes))
                .font(OriveoTheme.Typography.caption)
                .foregroundStyle(OriveoTheme.Palette.textSecondary)
                .multilineTextAlignment(.center)
            Button {
                createBlankNote()
            } label: {
                Text(L10n.tr("New note", table: .notes))
                    .font(OriveoTheme.Typography.caption.weight(.semibold))
                    .padding(.horizontal, OriveoTheme.Spacing.lg)
                    .padding(.vertical, OriveoTheme.Spacing.sm)
                    .background(Capsule().fill(OriveoTheme.Palette.primary))
                    .foregroundStyle(OriveoTheme.Palette.onPrimary)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, OriveoTheme.Spacing.xxl)
    }

    // MARK: Trash section

    @ViewBuilder
    private var trashSection: some View {
        let notes = displayedTrash
        if !appState.trashedNoteSummaries.isEmpty {
            HStack(spacing: OriveoTheme.Spacing.sm) {
                Text(L10n.tr("Long press a note to restore or delete it.", table: .notes))
                    .font(OriveoTheme.Typography.footnote)
                    .foregroundStyle(OriveoTheme.Palette.textTertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: OriveoTheme.Spacing.sm)
                Button(role: .destructive) {
                    showEmptyTrashConfirm = true
                } label: {
                    Label(L10n.tr("Empty trash", table: .notes), systemImage: "trash.slash")
                        .font(OriveoTheme.Typography.footnote.weight(.semibold))
                        .layoutPriority(1)
                }
                .buttonStyle(.plain)
                .foregroundStyle(OriveoTheme.Palette.danger)
            }
            .confirmationDialog(L10n.tr("Empty trash", table: .notes), isPresented: $showEmptyTrashConfirm, titleVisibility: .visible) {
                Button(L10n.tr("Empty trash", table: .notes), role: .destructive) {
                    appState.noteManager.emptyTrash()
                }
                Button(L10n.tr("Cancel", table: .notes), role: .cancel) {}
            } message: {
                Text(L10n.tr("Deleted notes will appear here.", table: .notes))
            }
        }
        if notes.isEmpty {
            VStack(spacing: OriveoTheme.Spacing.sm) {
                Image(systemName: "trash")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(OriveoTheme.Palette.textTertiary)
                Text(L10n.tr("Trash is empty", table: .notes))
                    .font(OriveoTheme.Typography.title3)
                    .foregroundStyle(OriveoTheme.Palette.textPrimary)
                Text(L10n.tr("Deleted notes will appear here.", table: .notes))
                    .font(OriveoTheme.Typography.caption)
                    .foregroundStyle(OriveoTheme.Palette.textSecondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, OriveoTheme.Spacing.xxl)
        } else {
            ForEach(notes.prefix(visibleCount)) { summary in
                NoteCard(summary: summary)
                    .contextMenu { trashMenu(summary) }
                    .padding(.bottom, 6)
            }
            if notes.count > visibleCount {
                showMoreButton(remaining: notes.count - visibleCount)
            }
        }
    }

    @ViewBuilder
    private func trashMenu(_ summary: NoteSummary) -> some View {
        Button {
            appState.noteManager.restoreNote(id: summary.id)
        } label: {
            Label(L10n.tr("Restore", table: .notes), systemImage: "arrow.uturn.backward")
        }
        Button(role: .destructive) {
            permanentDeleteNote = summary
        } label: {
            Label(L10n.tr("Delete permanently", table: .notes), systemImage: "trash")
        }
    }

    // MARK: Derived data

    private var scopedTags: [String] {
        let folderScoped = NoteListPresentation.filterByFolder(baseActiveNotes, filter: folderFilter)
        return NoteListPresentation.allTags(in: folderScoped, limit: 12)
    }

    private var baseActiveNotes: [NoteSummary] {
        searchText.trimmingCharacters(in: .whitespaces).isEmpty ? appState.noteSummaries : searchResults
    }

    private var displayedNotes: [NoteSummary] {
        var notes = NoteListPresentation.filterByFolder(baseActiveNotes, filter: folderFilter)
        notes = NoteListPresentation.filterByTags(notes, tags: selectedTags)
        return NoteListPresentation.sort(notes, by: sortKey)
    }

    private var displayedTrash: [NoteSummary] {
        let base = searchText.trimmingCharacters(in: .whitespaces).isEmpty ? appState.trashedNoteSummaries : searchResults
        return NoteListPresentation.sort(base, by: sortKey)
    }

    // MARK: Actions

    private func createBlankNote() {
        if let note = appState.noteManager.createBlankNote() {
            appState.openNoteDetail(noteID: note.id)
        }
    }

    private func deleteNote(_ summary: NoteSummary) {
        appState.noteManager.deleteNote(id: summary.id)
        ToastManager.shared.show(
            L10n.tr("Note deleted", table: .notes),
            duration: 5,
            actionTitle: L10n.tr("Undo", table: .notes)
        ) {
            appState.noteManager.restoreNote(id: summary.id)
        }
    }

    private func resetPagingAndSearch() {
        visibleCount = NotesView.pageSize
        scheduleSearch()
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        let query = searchText
        let trashScope = (tab == .trash)
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            searchResults = []
            return
        }
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            let results = trashScope
                ? await appState.noteManager.searchTrashedNotes(query: query)
                : await appState.noteManager.searchActiveNotes(query: query)
            guard !Task.isCancelled else { return }
            searchResults = results
            visibleCount = NotesView.pageSize
        }
    }
}

enum NotesChrome {
    static var background: LinearGradient {
        LinearGradient(
            colors: [
                Color.dynamic(light: 0xF7F5FB, dark: 0x171520),
                Color.dynamic(light: 0xF1ECF8, dark: 0x131019)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}
