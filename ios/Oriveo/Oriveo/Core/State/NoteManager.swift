import Foundation

@MainActor
final class NoteManager {
    unowned private(set) var appState: AppState!
    private(set) var isBound = false
    private let bridge: NoteRuntimeBridge

    init() { self.bridge = NoteRuntimeBridge() }
    init(bridge: NoteRuntimeBridge) { self.bridge = bridge }

    func bind(to appState: AppState) {
        self.appState = appState
        isBound = true
        reloadFromStore()
    }

    private var uid: String { appState.sessionPartitionUID }
    private var mirrorGeneration: UInt = 0

    private func makeStore() throws -> NoteStore {
        try bridge.makeStore(for: uid)
    }


    func reloadFromStore() {
        guard isBound else { return }
        let targetUID = uid
        let bridge = self.bridge
        let startGeneration = mirrorGeneration
        Task { @MainActor [weak self, weak state = appState] in
            guard let self else { return }
            let snapshot: NoteMirrorSnapshot? = await Task.detached(priority: .userInitiated) {
                do {
                    let store = try bridge.makeStore(for: targetUID)
                    return NoteMirrorSnapshot(
                        active: try store.fetchNoteSummaries(includeDeleted: false),
                        trashed: try store.fetchNoteSummaries(includeDeleted: true),
                        folders: try store.fetchNoteFolders(includeDeleted: false)
                    )
                } catch {
                    return nil
                }
            }.value
            guard let snapshot, let state, self.isBound, state.sessionPartitionUID == targetUID else { return }
            if self.mirrorGeneration != startGeneration {
                self.reloadFromStore()
                return
            }
            state.noteSummaries = snapshot.active
            state.trashedNoteSummaries = snapshot.trashed
            state.noteFolders = snapshot.folders
        }
    }

    func reloadMirrorSync() {
        guard isBound, let store = try? makeStore() else { return }
        appState.noteSummaries = (try? store.fetchNoteSummaries(includeDeleted: false)) ?? []
        appState.trashedNoteSummaries = (try? store.fetchNoteSummaries(includeDeleted: true)) ?? []
        appState.noteFolders = (try? store.fetchNoteFolders(includeDeleted: false)) ?? []
    }

    func clearMirror() {
        guard isBound else { return }
        appState.noteSummaries = []
        appState.trashedNoteSummaries = []
        appState.noteFolders = []
    }


    func note(id: UUID) -> Note? {
        (try? makeStore().fetchNote(id: id)) ?? nil
    }

    func noteDetail(id: UUID) async -> Note? {
        guard let store = try? makeStore() else { return nil }
        return (try? await store.fetchNoteAsync(id: id)) ?? nil
    }

    func referenceCount(conversationID: UUID) -> Int {
        (try? makeStore().referenceCount(conversationID: conversationID)) ?? 0
    }

    func referenceCount(conversationIDs: [UUID]) -> Int {
        guard !conversationIDs.isEmpty else { return 0 }
        return (try? makeStore().referenceCount(conversationIDs: conversationIDs)) ?? 0
    }

    func searchActiveNotes(query: String) async -> [NoteSummary] {
        guard let store = try? makeStore() else { return [] }
        return (try? await store.searchNotes(query: query, includeDeleted: false)) ?? []
    }

    func searchTrashedNotes(query: String) async -> [NoteSummary] {
        guard let store = try? makeStore() else { return [] }
        return (try? await store.searchNotes(query: query, includeDeleted: true)) ?? []
    }

    func recallCandidates(terms: [String]) async -> [NoteRecallCandidate] {
        guard !terms.isEmpty else { return [] }
        guard let store = try? makeStore() else { return [] }
        return (try? await store.fetchRecallCandidates(
            terms: terms,
            recentLimit: NoteRecallEngine.recentCandidateNotes,
            totalLimit: NoteRecallEngine.maxCandidateNotes
        )) ?? []
    }


    @discardableResult
    func createNote(from draft: NoteDraft) -> Note? {
        let now = Date()
        let trimmedTitle = draft.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let useManual = !(trimmedTitle?.isEmpty ?? true)
        let title = useManual
            ? trimmedTitle!
            : Self.placeholderTitle(fromPrompt: draft.sourcePrompt, body: NoteText.displayBody(draft.body))

        let note = Note(
            id: UUID(),
            title: title,
            titleSource: useManual ? .manual : .placeholder,
            body: draft.body,
            bodySnapshot: draft.bodySnapshot,
            userNote: draft.userNote,
            tags: draft.tags,
            noteFolderID: draft.noteFolderID,
            sourceConversationId: draft.sourceConversationId,
            sourceMessageId: draft.sourceMessageId,
            sourceModelID: draft.sourceModelID,
            sourceModelName: draft.sourceModelName,
            sourceProviderKind: draft.sourceProviderKind,
            sourceProviderName: draft.sourceProviderName,
            sourcePrompt: draft.sourcePrompt,
            captureKind: draft.captureKind,
            provenance: draft.provenance,
            isPinned: false,
            createdAt: now,
            updatedAt: now,
            deletedAt: nil
        )

        guard persist(note) else { return nil }
        applyToMirror(note)
        return note
    }

    @discardableResult
    func createBlankNote(folderID: UUID? = nil) -> Note? {
        createNote(from: NoteDraft(body: "", noteFolderID: folderID, captureKind: .blank))
    }

    @discardableResult
    func discardEmptyBlankNoteIfNeeded(id: UUID) -> Bool {
        guard let note = note(id: id), Self.isDiscardableEmptyBlankNote(note),
              let store = try? makeStore()
        else { return false }
        do { try store.deleteNoteHard(id: id) } catch { return false }
        mirrorGeneration &+= 1
        appState.noteSummaries.removeAll { $0.id == id }
        appState.trashedNoteSummaries.removeAll { $0.id == id }
        return true
    }

    nonisolated static func isDiscardableEmptyBlankNote(_ note: Note) -> Bool {
        note.deletedAt == nil &&
            note.captureKind == .blank &&
            note.titleSource == .placeholder &&
            note.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            note.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            (note.bodySnapshot?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) &&
            (note.userNote?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) &&
            note.tags.allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } &&
            note.sourceConversationId == nil &&
            note.sourceMessageId == nil &&
            (note.sourceModelID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) &&
            (note.sourceModelName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) &&
            note.sourceProviderKind == nil &&
            (note.sourceProviderName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) &&
            (note.sourcePrompt?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) &&
            (note.provenance?.isEmpty ?? true) &&
            !note.isPinned
    }


    @discardableResult
    func updateTitle(id: UUID, title: String) -> Note? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return mutate(id: id) { note in
            if trimmed.isEmpty {
                note.title = Self.placeholderTitle(fromPrompt: note.sourcePrompt, body: NoteText.displayBody(note.body))
                note.titleSource = .placeholder
            } else {
                note.title = trimmed
                note.titleSource = .manual
            }
        }
    }

    @discardableResult
    func updateBody(id: UUID, body: String) -> Note? {
        mutate(id: id) { note in
            note.body = body
            if note.titleSource == .placeholder {
                note.title = Self.placeholderTitle(fromPrompt: note.sourcePrompt, body: NoteText.displayBody(body))
            }
        }
    }

    @discardableResult
    func replaceNote(id: UUID, with draft: NoteDraft) -> Note? {
        mutate(id: id) { note in
            note.body = draft.body
            note.bodySnapshot = draft.bodySnapshot
            note.sourceConversationId = draft.sourceConversationId
            note.sourceMessageId = draft.sourceMessageId
            note.sourceModelID = draft.sourceModelID
            note.sourceModelName = draft.sourceModelName
            note.sourceProviderKind = draft.sourceProviderKind
            note.sourceProviderName = draft.sourceProviderName
            note.sourcePrompt = draft.sourcePrompt
            note.captureKind = draft.captureKind
            note.provenance = nil
            if note.titleSource == .placeholder {
                note.title = Self.placeholderTitle(fromPrompt: draft.sourcePrompt, body: NoteText.displayBody(draft.body))
            }
        }
    }

    @discardableResult
    func updateTags(id: UUID, tags: [String]) -> Note? {
        mutate(id: id) { $0.tags = tags }
    }

    @discardableResult
    func updateUserNote(id: UUID, userNote: String?) -> Note? {
        mutate(id: id) { note in
            let trimmed = userNote?.trimmingCharacters(in: .whitespacesAndNewlines)
            note.userNote = (trimmed?.isEmpty ?? true) ? nil : trimmed
        }
    }

    @discardableResult
    func setPinned(id: UUID, isPinned: Bool) -> Note? {
        mutate(id: id) { $0.isPinned = isPinned }
    }

    @discardableResult
    func moveNote(id: UUID, toFolder folderID: UUID?) -> Note? {
        mutate(id: id) { $0.noteFolderID = folderID }
    }

    func deleteNote(id: UUID) {
        let now = Date()
        guard let store = try? makeStore() else { return }
        do { try store.softDeleteNote(id: id, deletedAt: now, updatedAt: now) } catch { return }
        mirrorGeneration &+= 1
        if var summary = appState.noteSummaries.first(where: { $0.id == id }) {
            summary.deletedAt = now
            summary.updatedAt = now
            appState.noteSummaries.removeAll { $0.id == id }
            insertSorted(summary, into: &appState.trashedNoteSummaries)
        }
    }

    func restoreNote(id: UUID) {
        let now = Date()
        guard let store = try? makeStore() else { return }
        do { try store.restoreNote(id: id, updatedAt: now) } catch { return }
        if let restored = note(id: id) {
            appState.trashedNoteSummaries.removeAll { $0.id == id }
            applyToMirror(restored)
        }
    }

    func permanentlyDeleteNote(id: UUID) {
        guard let store = try? makeStore() else { return }
        do { try store.deleteNoteHard(id: id) } catch { return }
        mirrorGeneration &+= 1
        appState.trashedNoteSummaries.removeAll { $0.id == id }
    }

    func emptyTrash() {
        let ids = appState.trashedNoteSummaries.map(\.id)
        guard !ids.isEmpty, let store = try? makeStore() else { return }
        do { try store.emptyTrash(noteIDs: ids) } catch { return }
        mirrorGeneration &+= 1
        appState.trashedNoteSummaries = []
    }


    @discardableResult
    func createNoteFolder(name: String, colorTag: String? = nil) -> NoteFolder? {
        let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Note.folderNameMaxLength))
        guard !trimmed.isEmpty, let store = try? makeStore() else { return nil }
        let now = Date()
        let maxOrder = (try? store.fetchMaxFolderSortOrder()) ?? nil
        let sortOrder = (maxOrder ?? 0) + Note.folderSortStep
        let folder = NoteFolder(
            id: UUID(),
            name: trimmed,
            sortOrder: sortOrder,
            colorTag: colorTag,
            createdAt: now,
            updatedAt: now,
            deletedAt: nil
        )
        do { try store.upsertNoteFolder(folder) } catch { return nil }
        insertFolderSorted(folder)
        return folder
    }

    @discardableResult
    func renameNoteFolder(id: UUID, name: String) -> NoteFolder? {
        mutateFolder(id: id) {
            $0.name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Note.folderNameMaxLength))
        }
    }

    @discardableResult
    func setNoteFolderColor(id: UUID, colorTag: String?) -> NoteFolder? {
        mutateFolder(id: id) { $0.colorTag = colorTag }
    }

    func deleteNoteFolder(id: UUID) {
        let now = Date()
        let affected: [UUID]
        do {
            affected = try bridge.softDeleteNoteFolder(for: uid, id: id, deletedAt: now, updatedAt: now)
        } catch {
            AppLog.error(
                error,
                module: "notes-folder",
                context: ["phase": "delete-local"]
            )
            return
        }
        mirrorGeneration &+= 1
        appState.noteFolders.removeAll { $0.id == id }
        for noteID in affected {
            if let updated = note(id: noteID) { applyToMirror(updated) }
        }
    }

    func reorderNoteFolders(_ ordered: [NoteFolder]) {
        guard let store = try? makeStore() else { return }
        let now = Date()
        var rewritten: [NoteFolder] = []
        for (index, folder) in ordered.enumerated() {
            var f = folder
            f.sortOrder = (index + 1) * Note.folderSortStep
            f.updatedAt = now
            rewritten.append(f)
        }
        do { try store.upsertNoteFolders(rewritten) } catch { return }
        mirrorGeneration &+= 1
        appState.noteFolders = rewritten.sorted { $0.sortOrder < $1.sortOrder }
    }

    func noteFolderName(for id: UUID?) -> String? {
        guard let id else { return nil }
        return appState.noteFolders.first { $0.id == id }?.name
    }


    func allNotesForSync() -> [Note] {
        (try? makeStore().fetchAllNotes()) ?? []
    }

    func allNoteFoldersForSync() -> [NoteFolder] {
        (try? makeStore().fetchAllNoteFolders()) ?? []
    }

    func importNotes(_ notes: [Note], folders: [NoteFolder], mode: ImportMode) {
        guard isBound, let store = try? makeStore() else { return }
        switch mode {
        case .importNewOnly:
            let localFolders = (try? store.fetchAllNoteFolders()) ?? []
            let existingFolderIDs = Set(localFolders.map(\.id))
            let existingNoteIDs = Set(((try? store.fetchAllNotes()) ?? []).map(\.id))
            let foldersToWrite = folders.filter { $0.deletedAt == nil && !existingFolderIDs.contains($0.id) }
            var activeFolderIDs = Set(localFolders.filter { $0.deletedAt == nil }.map(\.id))
            activeFolderIDs.formUnion(foldersToWrite.map(\.id))
            try? store.upsertNoteFolders(foldersToWrite)
            let notesToWrite = notes
                .filter { !existingNoteIDs.contains($0.id) }
                .map { Self.withValidNoteFolder($0, activeFolderIDs: activeFolderIDs) }
            try? store.upsertNotes(notesToWrite)
        case .merge:
            let localNotes = Dictionary(((try? store.fetchAllNotes()) ?? []).map { ($0.id, $0) }) { a, _ in a }
            let localFolders = Dictionary(((try? store.fetchAllNoteFolders()) ?? []).map { ($0.id, $0) }) { a, _ in a }
            var resolvedFolders = localFolders
            var foldersToWrite: [NoteFolder] = []
            for bf in folders {
                if let local = localFolders[bf.id] {
                    if bf.updatedAt > local.updatedAt {
                        foldersToWrite.append(bf)
                        resolvedFolders[bf.id] = bf
                    }
                } else if bf.deletedAt == nil {
                    foldersToWrite.append(bf)
                    resolvedFolders[bf.id] = bf
                }
            }
            let activeFolderIDs = Set(resolvedFolders.values.filter { $0.deletedAt == nil }.map(\.id))
            try? store.upsertNoteFolders(foldersToWrite)
            let notesToWrite = notes.compactMap { bn -> Note? in
                guard let local = localNotes[bn.id] else {
                    return Self.withValidNoteFolder(bn, activeFolderIDs: activeFolderIDs)
                }
                return bn.updatedAt > local.updatedAt
                    ? Self.withValidNoteFolder(bn, activeFolderIDs: activeFolderIDs)
                    : nil
            }
            try? store.upsertNotes(notesToWrite)
            let cleanupTime = Date()
            for folder in resolvedFolders.values where folder.deletedAt != nil {
                _ = try? store.clearNoteFolderReference(folderID: folder.id, updatedAt: cleanupTime)
            }
        case .replaceAll:
            let activeFolders = folders.filter { $0.deletedAt == nil }
            let activeFolderIDs = Set(activeFolders.map(\.id))
            let normalizedNotes = notes.map { Self.withValidNoteFolder($0, activeFolderIDs: activeFolderIDs) }
            try? store.replaceAllNoteFolders(activeFolders)
            try? store.replaceAllNotes(normalizedNotes)
        }
        reloadMirrorSync()
    }

    private static func withValidNoteFolder(_ note: Note, activeFolderIDs: Set<UUID>) -> Note {
        guard let folderID = note.noteFolderID, !activeFolderIDs.contains(folderID) else { return note }
        var fixed = note
        fixed.noteFolderID = nil
        return fixed
    }

    func migrateGuestNotes(_ notes: [Note], folders: [NoteFolder]) {
        guard isBound, let store = try? makeStore() else { return }
        let existingNoteIDs = Set(((try? store.fetchAllNotes()) ?? []).map(\.id))
        let existingFolderIDs = Set(((try? store.fetchAllNoteFolders()) ?? []).map(\.id))
        let foldersToAdd = folders.filter { !existingFolderIDs.contains($0.id) }
        let notesToAdd = notes.filter { !existingNoteIDs.contains($0.id) }
        try? store.upsertNoteFolders(foldersToAdd)
        try? store.upsertNotes(notesToAdd)
        reloadMirrorSync()
    }


    private func persist(_ note: Note) -> Bool {
        guard let store = try? makeStore() else { return false }
        do { try store.upsertNote(note); return true } catch { return false }
    }

    @discardableResult
    private func mutate(id: UUID, _ transform: (inout Note) -> Void) -> Note? {
        guard var note = note(id: id) else { return nil }
        transform(&note)
        note.updatedAt = Date()
        guard persist(note) else { return nil }
        applyToMirror(note)
        return note
    }

    @discardableResult
    private func mutateFolder(id: UUID, _ transform: (inout NoteFolder) -> Void) -> NoteFolder? {
        guard var folder = appState.noteFolders.first(where: { $0.id == id }) else { return nil }
        transform(&folder)
        folder.updatedAt = Date()
        guard let store = try? makeStore() else { return nil }
        do { try store.upsertNoteFolder(folder) } catch { return nil }
        mirrorGeneration &+= 1
        if let idx = appState.noteFolders.firstIndex(where: { $0.id == id }) {
            appState.noteFolders[idx] = folder
            appState.noteFolders.sort { $0.sortOrder < $1.sortOrder }
        }
        return folder
    }

    private func applyToMirror(_ note: Note) {
        mirrorGeneration &+= 1
        let summary = NoteSummary(note)
        appState.noteSummaries.removeAll { $0.id == note.id }
        appState.trashedNoteSummaries.removeAll { $0.id == note.id }
        if note.deletedAt == nil {
            insertSorted(summary, into: &appState.noteSummaries)
        } else {
            insertSorted(summary, into: &appState.trashedNoteSummaries)
        }
    }

    private func insertSorted(_ summary: NoteSummary, into array: inout [NoteSummary]) {
        array.removeAll { $0.id == summary.id }
        array.append(summary)
        array.sort { lhs, rhs in
            if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
            return lhs.id.uuidString > rhs.id.uuidString
        }
    }

    private func insertFolderSorted(_ folder: NoteFolder) {
        mirrorGeneration &+= 1
        appState.noteFolders.removeAll { $0.id == folder.id }
        appState.noteFolders.append(folder)
        appState.noteFolders.sort { $0.sortOrder < $1.sortOrder }
    }


    nonisolated static func placeholderTitle(fromPrompt sourcePrompt: String?, body: String) -> String {
        if let fromPrompt = firstMeaningfulLine(sourcePrompt ?? ""), !fromPrompt.isEmpty {
            return fromPrompt
        }
        return firstMeaningfulLine(body) ?? ""
    }

    nonisolated static func firstMeaningfulLine(_ text: String) -> String? {
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.range(of: "^[|\\s:+-]+$", options: .regularExpression) != nil { continue }
            if line.hasPrefix("```") || line.hasPrefix("~~~") { continue }
            var s = line
            s = s.replacingOccurrences(of: "^#{1,6}\\s+", with: "", options: .regularExpression)
            s = s.replacingOccurrences(of: "^>\\s+", with: "", options: .regularExpression)
            s = s.replacingOccurrences(of: "^[-*+]\\s+", with: "", options: .regularExpression)
            s = s.replacingOccurrences(of: "^\\d+\\.\\s+", with: "", options: .regularExpression)
            s = s.replacingOccurrences(of: "^\\|", with: "", options: .regularExpression)
            s = s.replacingOccurrences(of: "[*_`~]", with: "", options: .regularExpression)
            s = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            s = s.trimmingCharacters(in: .whitespaces)
            if s.isEmpty { continue }
            return String(s.prefix(200))
        }
        return nil
    }
}

private struct NoteMirrorSnapshot: Sendable {
    let active: [NoteSummary]
    let trashed: [NoteSummary]
    let folders: [NoteFolder]
}
