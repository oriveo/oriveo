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
    #if DEBUG
    /// Makes queued writes fail (tests lock the rollback of the mirror).
    var _testingFailWrites = false
    #endif
    /// In-place mirror write generation: bumped on every in-place mirror edit. If the background read of
    /// `reloadFromStore` spans one, its snapshot is stale and is retried instead of overwriting the mirror.
    private var mirrorGeneration: UInt = 0

    private func makeStore() throws -> NoteStore {
        try bridge.makeStore(for: uid)
    }


    /// The background read queues behind the writes already enqueued: reading before they land would put stale
    /// rows into the mirror.
    @discardableResult
    func reloadFromStore() -> Task<Void, Never>? {
        guard isBound else { return nil }
        let targetUID = uid
        // The store instance is fixed on the main thread (as in `enqueueWrite`): the background read does not
        // reopen by uid through the shared manager.
        let capturedStore = try? makeStore()
        let startGeneration = mirrorGeneration
        let tail = writeTail
        return Task { @MainActor [weak self, weak state = appState] in
            guard let self else { return }
            let snapshot: NoteMirrorSnapshot? = await Task.detached(priority: .userInitiated) {
                await tail?.value
                do {
                    guard let store = capturedStore else { return nil }
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
            // An in-place mirror write happened during the read: the snapshot may miss it, so retry instead of
            // overwriting with it (a note that was just created must not be wiped).
            if self.mirrorGeneration != startGeneration {
                await self.reloadFromStore()?.value
                return
            }
            state.noteSummaries = snapshot.active
            state.trashedNoteSummaries = snapshot.trashed
            state.noteFolders = snapshot.folders
        }
    }

    /// Waits until every queued write has landed (and its main-thread follow-up has run). For tests and callers
    /// that must read the database directly.
    func waitForPendingWrites() async {
        while let tail = writeTail {
            await tail.value
            if writeTail == tail { return }
        }
    }

    /// The stored row with the writes still in flight applied on top = the latest local state.
    func note(id: UUID) -> Note? {
        let stored = (try? makeStore().fetchNote(id: id)) ?? nil
        return Self.applying(currentNoteOps(), to: stored, id: id)
    }

    /// Read-only resolver for pinned note content snapshots: the main thread only grabs the store handle and
    /// the fallback title, and the database read happens on the caller's thread (which may be off-main).
    /// Same rules as AppState.resolvePinnedNoteSnapshots: follows the order of `ids`, skips deleted or
    /// missing notes.
    func pinnedNoteSnapshotReader(ids: [UUID]) -> @Sendable () -> [ChatRequestPinnedNoteSnapshot] {
        guard !ids.isEmpty, let store = try? makeStore() else { return { [] } }
        let untitled = L10n.tr("Untitled note", table: .notes)
        let ops = currentNoteOps()
        return {
            ids.compactMap { id in
                let stored = (try? store.fetchNote(id: id)) ?? nil
                guard let note = NoteManager.applying(ops, to: stored, id: id), note.deletedAt == nil else { return nil }
                return ChatRequestPinnedNoteSnapshot(
                    id: id, title: NoteText.displayTitle(note.title, untitled: untitled), body: note.body
                )
            }
        }
    }

    func noteDetail(id: UUID) async -> Note? {
        guard let store = try? makeStore() else { return nil }
        let targetUID = uid
        let stored = (try? await store.fetchNoteAsync(id: id)) ?? nil
        // Do not read appState after the await (it may be gone): take the in-flight writes of the partition at entry.
        return Self.applying(noteOps(forUID: targetUID), to: stored, id: id)
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
        await waitForPendingWrites()
        return (try? await store.searchNotes(query: query, includeDeleted: false)) ?? []
    }

    func searchTrashedNotes(query: String) async -> [NoteSummary] {
        guard let store = try? makeStore() else { return [] }
        await waitForPendingWrites()
        return (try? await store.searchNotes(query: query, includeDeleted: true)) ?? []
    }

    func recallCandidates(terms: [String]) async -> [NoteRecallCandidate] {
        guard !terms.isEmpty else { return [] }
        guard let store = try? makeStore() else { return [] }
        await waitForPendingWrites()
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

        applyToMirror(note)
        enqueueWrite(phase: "create_note", noteOps: [.upsert(note)]) { store in
            try store.upsertNote(note)
        }
        return note
    }

    @discardableResult
    func createBlankNote(folderID: UUID? = nil) -> Note? {
        createNote(from: NoteDraft(body: "", noteFolderID: folderID, captureKind: .blank))
    }

    @discardableResult
    func discardEmptyBlankNoteIfNeeded(id: UUID) -> Bool {
        guard let note = note(id: id), Self.isDiscardableEmptyBlankNote(note) else { return false }
        mirrorGeneration &+= 1
        appState.noteSummaries.removeAll { $0.id == id }
        appState.trashedNoteSummaries.removeAll { $0.id == id }
        enqueueWrite(phase: "discard_blank_note", noteOps: [.remove([id])]) { store in
            try store.deleteNoteHard(id: id)
        }
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

    /// Keeps a cross-check as a single note with two sources: the body holds both answers and the
    /// provenance records the model behind each one. The note's source fields still point at the
    /// original answer, so opening it jumps back to the conversation it came from.
    @discardableResult
    func createNoteFromCrosscheck(
        origin: CrosscheckOrigin,
        crosscheckModel: CrosscheckModelOption,
        crosscheckText: String
    ) -> Note? {
        let answer: String
        let prompt: String?
        let modelID: String?
        let modelName: String?
        let providerKind: ProviderKind?
        let providerName: String?
        let conversationId: UUID?
        let messageId: UUID?
        let originAt: Date

        switch origin {
        case .note(let note):
            answer = note.bodySnapshot ?? note.body
            prompt = note.sourcePrompt
            modelID = note.sourceModelID
            modelName = note.sourceModelName
            providerKind = note.sourceProviderKind
            providerName = note.sourceProviderName
            conversationId = note.sourceConversationId
            messageId = note.sourceMessageId
            originAt = note.createdAt
        case .chatMessage(let convID, let message, let sourcePrompt):
            answer = message.text
            prompt = sourcePrompt
            modelID = message.modelID
            modelName = message.modelName
            providerKind = message.providerKind
            providerName = message.providerName
            conversationId = convID
            messageId = message.id
            originAt = message.createdAt ?? Date()
        }

        let trimmedAnswer = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCheck = crosscheckText.trimmingCharacters(in: .whitespacesAndNewlines)
        // The section headings stay in English on every platform so an exported note reads and
        // diffs the same everywhere.
        let body = "## Original answer\n\n\(trimmedAnswer)\n\n## Cross-check (\(crosscheckModel.modelName))\n\n\(trimmedCheck)"

        let provenance = [
            ProvenanceEntry(kind: .origin, modelID: modelID, modelName: modelName,
                            providerKind: providerKind, providerName: providerName,
                            conversationId: conversationId, messageId: messageId, at: originAt),
            // The second model answered outside any conversation, so it has no conversation or
            // message to point at.
            ProvenanceEntry(kind: .crosscheck, modelID: crosscheckModel.modelID,
                            modelName: crosscheckModel.modelName,
                            providerKind: crosscheckModel.providerKind,
                            providerName: crosscheckModel.providerName,
                            conversationId: nil, messageId: nil, at: Date())
        ]

        var draft = NoteDraft(body: body, captureKind: .fullAnswer)
        draft.bodySnapshot = answer
        draft.sourceConversationId = conversationId
        draft.sourceMessageId = messageId
        draft.sourceModelID = modelID
        draft.sourceModelName = modelName
        draft.sourceProviderKind = providerKind
        draft.sourceProviderName = providerName
        draft.sourcePrompt = prompt
        draft.provenance = provenance

        return createNote(from: draft)
    }

    func deleteNote(id: UUID) {
        let now = Date()
        mirrorGeneration &+= 1
        if var summary = appState.noteSummaries.first(where: { $0.id == id }) {
            summary.deletedAt = now
            summary.updatedAt = now
            appState.noteSummaries.removeAll { $0.id == id }
            insertSorted(summary, into: &appState.trashedNoteSummaries)
        }
        enqueueWrite(phase: "trash_note", noteOps: [.trash(id: id, deletedAt: now, updatedAt: now)]) { store in
            try store.softDeleteNote(id: id, deletedAt: now, updatedAt: now)
        }
    }

    func restoreNote(id: UUID) {
        let now = Date()
        guard var restored = note(id: id) else { return }
        restored.deletedAt = nil
        restored.updatedAt = now
        appState.trashedNoteSummaries.removeAll { $0.id == id }
        applyToMirror(restored)
        enqueueWrite(phase: "restore_note", noteOps: [.restore(id: id, updatedAt: now)]) { store in
            try store.restoreNote(id: id, updatedAt: now)
        }
    }

    func permanentlyDeleteNote(id: UUID) {
        mirrorGeneration &+= 1
        appState.trashedNoteSummaries.removeAll { $0.id == id }
        enqueueWrite(phase: "delete_note", noteOps: [.remove([id])]) { store in
            try store.deleteNoteHard(id: id)
        }
    }

    func emptyTrash() {
        let ids = appState.trashedNoteSummaries.map(\.id)
        guard !ids.isEmpty else { return }
        mirrorGeneration &+= 1
        appState.trashedNoteSummaries = []
        enqueueWrite(phase: "empty_trash", noteOps: [.remove(Set(ids))]) { store in
            try store.emptyTrash(noteIDs: ids)
        }
    }


    @discardableResult
    func createNoteFolder(name: String, colorTag: String? = nil) -> NoteFolder? {
        let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Note.folderNameMaxLength))
        guard !trimmed.isEmpty, let store = try? makeStore() else { return nil }
        let now = Date()
        // The largest stored value (tombstones included) on top of creations / reorders that have not landed yet.
        let storedMax = (try? store.fetchMaxFolderSortOrder()) ?? nil
        let pendingMax = currentFolderOps().compactMap { op -> Int? in
            if case .upsert(let folder) = op { return folder.sortOrder }
            return nil
        }.max()
        let maxOrder = [storedMax, pendingMax, appState.noteFolders.map(\.sortOrder).max()].compactMap { $0 }.max()
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
        insertFolderSorted(folder)
        enqueueWrite(phase: "create_folder", folderOps: [.upsert(folder)]) { store in
            try store.upsertNoteFolder(folder)
        }
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
        mirrorGeneration &+= 1
        appState.noteFolders.removeAll { $0.id == id }
        // Cascade: notes that point at it move back to unfiled in the mirror first; a failed write reloads the mirror.
        clearFolderInMirror(folderID: id, updatedAt: now)
        let bridge = self.bridge
        let targetUID = uid
        enqueueWrite(
            phase: "delete_folder",
            noteOps: [.clearFolder(folderID: id, updatedAt: now)],
            folderOps: [.trash(id: id, deletedAt: now, updatedAt: now)]
        ) { store in
            _ = try bridge.softDeleteNoteFolder(in: store, uid: targetUID, id: id, deletedAt: now, updatedAt: now)
        }
    }

    func reorderNoteFolders(_ ordered: [NoteFolder]) {
        let now = Date()
        var rewritten: [NoteFolder] = []
        for (index, folder) in ordered.enumerated() {
            var f = folder
            f.sortOrder = (index + 1) * Note.folderSortStep
            f.updatedAt = now
            rewritten.append(f)
        }
        mirrorGeneration &+= 1
        appState.noteFolders = rewritten.sorted { $0.sortOrder < $1.sortOrder }
        let rows = rewritten
        enqueueWrite(phase: "reorder_folders", folderOps: rows.map { .upsert($0) }) { store in
            try store.upsertNoteFolders(rows)
        }
    }

    func noteFolderName(for id: UUID?) -> String? {
        guard let id else { return nil }
        return appState.noteFolders.first { $0.id == id }?.name
    }


    func allNotesForSync() -> [Note] {
        Self.overlaying(currentNoteOps(), on: (try? makeStore().fetchAllNotes()) ?? [])
    }

    func allNoteFoldersForSync() -> [NoteFolder] {
        Self.overlaying(currentFolderOps(), on: (try? makeStore().fetchAllNoteFolders()) ?? [])
    }

    /// The whole import (reads that decide + writes) runs on the serial write chain; the returned task completes
    /// once it has landed and the mirror has been reloaded, for callers that continue only afterwards.
    @discardableResult
    func importNotes(_ notes: [Note], folders: [NoteFolder], mode: ImportMode) -> Task<Void, Never> {
        guard isBound else { return Task {} }
        var noteOps: [PendingNoteOp] = []
        var folderOps: [PendingFolderOp] = []
        if mode == .importNewOnly {
            // Append-only: compute it from the mirror first so it is visible at once; the write still recomputes
            // from the database and the mirror is reloaded after it lands.
            let localNoteIDs = Set((appState.noteSummaries + appState.trashedNoteSummaries).map(\.id))
            let localFolderIDs = Set(appState.noteFolders.map(\.id))
            let newFolders = folders.filter { $0.deletedAt == nil && !localFolderIDs.contains($0.id) }
            let activeFolderIDs = localFolderIDs.union(newFolders.map(\.id))
            let newNotes = notes
                .filter { !localNoteIDs.contains($0.id) }
                .map { Self.withValidNoteFolder($0, activeFolderIDs: activeFolderIDs) }
            folderOps = newFolders.map { .upsert($0) }
            noteOps = newNotes.map { .upsert($0) }
            appendToMirror(notes: newNotes, folders: newFolders)
        }
        enqueueWrite(phase: "import_notes", userInitiated: false, noteOps: noteOps, folderOps: folderOps) { store in
            Self.performImport(notes, folders: folders, mode: mode, store: store)
        }
        return Task { @MainActor [weak self, weak state = appState] in
            guard let self, state != nil else { return }
            await self.reloadFromStore()?.value
        }
    }

    nonisolated private static func performImport(
        _ notes: [Note],
        folders: [NoteFolder],
        mode: ImportMode,
        store: NoteStore
    ) {
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
    }

    nonisolated private static func withValidNoteFolder(_ note: Note, activeFolderIDs: Set<UUID>) -> Note {
        guard let folderID = note.noteFolderID, !activeFolderIDs.contains(folderID) else { return note }
        var fixed = note
        fixed.noteFolderID = nil
        return fixed
    }


    // MARK: - Serial background writes and the in-flight overlay

    /// Serial tail of all note database writes: each write waits for the previous one to land (and for its
    /// main-thread follow-up) before it runs, so commit order equals enqueue order.
    private var writeTail: Task<Void, Never>?
    /// Overlay of in-flight writes: registered at enqueue, removed by token once the write has landed or failed.
    /// Database reads are overlaid with them in enqueue order = the latest local state. Tagged with the partition
    /// uid so a write of the previous partition never overlays a read of the new one.
    private var pendingNoteOps: [(token: UInt64, uid: String, op: PendingNoteOp)] = []
    private var pendingFolderOps: [(token: UInt64, uid: String, op: PendingFolderOp)] = []
    private var lastWriteToken: UInt64 = 0

    private func currentNoteOps() -> [PendingNoteOp] {
        guard !pendingNoteOps.isEmpty else { return [] }
        return noteOps(forUID: uid)
    }

    private func noteOps(forUID targetUID: String) -> [PendingNoteOp] {
        pendingNoteOps.filter { $0.uid == targetUID }.map(\.op)
    }

    private func currentFolderOps() -> [PendingFolderOp] {
        guard !pendingFolderOps.isEmpty else { return [] }
        let current = uid
        return pendingFolderOps.filter { $0.uid == current }.map(\.op)
    }

    /// Queues one background write: register the overlay, write on the serial tail, then drop the overlay on the
    /// main thread. On failure the mirror is reloaded from the database (rollback) and, for user actions, a
    /// warning toast is shown. The returned task is for callers that must wait for the write.
    @discardableResult
    private func enqueueWrite(
        phase: String,
        userInitiated: Bool = true,
        noteOps: [PendingNoteOp] = [],
        folderOps: [PendingFolderOp] = [],
        write: @escaping @Sendable (NoteStore) throws -> Void
    ) -> Task<Bool, Never> {
        let targetUID = uid
        // The store instance is fixed at enqueue time: the background write only touches this instance and does
        // not reopen by uid through the shared manager, so after a partition switch an in-flight write still lands
        // in the partition it was enqueued for and never swaps the shared manager back to the old database.
        let capturedStore = try? makeStore()
        lastWriteToken &+= 1
        let token = lastWriteToken
        pendingNoteOps += noteOps.map { (token, targetUID, $0) }
        pendingFolderOps += folderOps.map { (token, targetUID, $0) }
        var forceFailure = false
        #if DEBUG
        forceFailure = _testingFailWrites
        #endif
        let fail = forceFailure
        let previous = writeTail
        // AppState is captured weakly on its own: the manager may outlive it, so check it is alive before reading the partition.
        let task = Task.detached(priority: .userInitiated) { [weak self, weak state = appState] () -> Bool in
            await previous?.value
            let failure: Error?
            do {
                if fail { throw NoteWriteError.forcedFailure }
                guard let capturedStore else { throw NoteWriteError.storeUnavailable }
                try write(capturedStore)
                failure = nil
            } catch {
                failure = error
            }
            await MainActor.run {
                guard let self else { return }
                self.pendingNoteOps.removeAll { $0.token == token }
                self.pendingFolderOps.removeAll { $0.token == token }
                guard let failure, let state, self.isBound, state.sessionPartitionUID == targetUID else { return }
                self.reloadFromStore()
                AppLog.error(failure, module: "notes", context: ["phase": phase])
                if userInitiated {
                    ToastManager.shared.show(
                        L10n.tr("Couldn’t apply this change. Please try again.", table: .providers),
                        style: .warning
                    )
                }
            }
            return failure == nil
        }
        writeTail = Task.detached { _ = await task.value }
        return task
    }

    /// Stored row overlaid with the in-flight writes (in enqueue order).
    nonisolated static func applying(_ ops: [PendingNoteOp], to stored: Note?, id: UUID) -> Note? {
        ops.reduce(stored) { $1.apply(to: $0, id: id) }
    }

    nonisolated static func applying(_ ops: [PendingFolderOp], to stored: NoteFolder?, id: UUID) -> NoteFolder? {
        ops.reduce(stored) { $1.apply(to: $0, id: id) }
    }

    /// A whole-table read overlaid with the in-flight writes: rows created in flight that are not in the database yet are appended.
    nonisolated private static func overlaying(_ ops: [PendingNoteOp], on rows: [Note]) -> [Note] {
        guard !ops.isEmpty else { return rows }
        let known = Set(rows.map(\.id))
        var ids = rows.map(\.id)
        for case .upsert(let note) in ops where !known.contains(note.id) && !ids.contains(note.id) { ids.append(note.id) }
        let byID = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return ids.compactMap { applying(ops, to: byID[$0], id: $0) }
    }

    nonisolated private static func overlaying(_ ops: [PendingFolderOp], on rows: [NoteFolder]) -> [NoteFolder] {
        guard !ops.isEmpty else { return rows }
        let known = Set(rows.map(\.id))
        var ids = rows.map(\.id)
        for case .upsert(let folder) in ops where !known.contains(folder.id) && !ids.contains(folder.id) { ids.append(folder.id) }
        let byID = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return ids.compactMap { applying(ops, to: byID[$0], id: $0) }
    }

    /// Read-modify-write of one note: take the latest local state, apply the change, refresh updatedAt, update the
    /// mirror, then write in the background.
    @discardableResult
    private func mutate(id: UUID, _ transform: (inout Note) -> Void) -> Note? {
        guard var note = note(id: id) else { return nil }
        transform(&note)
        note.updatedAt = Date()
        applyToMirror(note)
        let row = note
        enqueueWrite(phase: "update_note", noteOps: [.upsert(row)]) { store in
            try store.upsertNote(row)
        }
        return note
    }

    @discardableResult
    private func mutateFolder(id: UUID, _ transform: (inout NoteFolder) -> Void) -> NoteFolder? {
        guard var folder = appState.noteFolders.first(where: { $0.id == id }) else { return nil }
        transform(&folder)
        folder.updatedAt = Date()
        mirrorGeneration &+= 1
        if let idx = appState.noteFolders.firstIndex(where: { $0.id == id }) {
            appState.noteFolders[idx] = folder
            appState.noteFolders.sort { $0.sortOrder < $1.sortOrder }
        }
        let row = folder
        enqueueWrite(phase: "update_folder", folderOps: [.upsert(row)]) { store in
            try store.upsertNoteFolder(row)
        }
        return folder
    }

    /// Notes (active and trashed) that point at a folder move back to unfiled in the mirror.
    private func clearFolderInMirror(folderID: UUID, updatedAt: Date) {
        let affected = (appState.noteSummaries + appState.trashedNoteSummaries).filter { $0.noteFolderID == folderID }
        for var summary in affected {
            summary.noteFolderID = nil
            summary.updatedAt = updatedAt
            applySummaryToMirror(summary)
        }
    }

    /// Appends to the mirror in one go (sorted once for the whole batch).
    private func appendToMirror(notes: [Note], folders: [NoteFolder]) {
        guard !notes.isEmpty || !folders.isEmpty else { return }
        mirrorGeneration &+= 1
        if !folders.isEmpty {
            let ids = Set(folders.map(\.id))
            appState.noteFolders = (appState.noteFolders.filter { !ids.contains($0.id) } + folders)
                .sorted { $0.sortOrder < $1.sortOrder }
        }
        guard !notes.isEmpty else { return }
        let ids = Set(notes.map(\.id))
        var active = appState.noteSummaries.filter { !ids.contains($0.id) }
        var trashed = appState.trashedNoteSummaries.filter { !ids.contains($0.id) }
        for note in notes {
            if note.deletedAt == nil { active.append(NoteSummary(note)) } else { trashed.append(NoteSummary(note)) }
        }
        appState.noteSummaries = active.sorted(by: Self.summaryOrder)
        appState.trashedNoteSummaries = trashed.sorted(by: Self.summaryOrder)
    }

    nonisolated private static func summaryOrder(_ lhs: NoteSummary, _ rhs: NoteSummary) -> Bool {
        if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
        return lhs.id.uuidString > rhs.id.uuidString
    }

    /// Writes a summary alone (a note whose noteFolderID the cascade changed) into the right mirror array.
    private func applySummaryToMirror(_ summary: NoteSummary) {
        mirrorGeneration &+= 1
        appState.noteSummaries.removeAll { $0.id == summary.id }
        appState.trashedNoteSummaries.removeAll { $0.id == summary.id }
        if summary.deletedAt == nil {
            insertSorted(summary, into: &appState.noteSummaries)
        } else {
            insertSorted(summary, into: &appState.trashedNoteSummaries)
        }
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
        array.sort(by: Self.summaryOrder)
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

private nonisolated enum NoteWriteError: Error {
    /// Failure injected by tests.
    case forcedFailure
    /// The database could not be opened at enqueue time.
    case storeUnavailable
}

/// What one in-flight note write does to a row (same semantics as the matching NoteStore SQL), overlaid on database reads.
nonisolated enum PendingNoteOp: Sendable {
    /// Whole-row write (create / edit).
    case upsert(Note)
    case trash(id: UUID, deletedAt: Date, updatedAt: Date)
    case restore(id: UUID, updatedAt: Date)
    /// Hard delete.
    case remove(Set<UUID>)
    /// Cascade: notes (trashed included) pointing at the folder move back to unfiled.
    case clearFolder(folderID: UUID, updatedAt: Date)

    func apply(to note: Note?, id: UUID) -> Note? {
        switch self {
        case .upsert(let row):
            return row.id == id ? row : note
        case .trash(let target, let deletedAt, let updatedAt):
            guard target == id, var note else { return note }
            note.deletedAt = deletedAt
            note.updatedAt = updatedAt
            return note
        case .restore(let target, let updatedAt):
            guard target == id, var note else { return note }
            note.deletedAt = nil
            note.updatedAt = updatedAt
            return note
        case .remove(let ids):
            return ids.contains(id) ? nil : note
        case .clearFolder(let folderID, let updatedAt):
            guard var note, note.noteFolderID == folderID else { return note }
            note.noteFolderID = nil
            note.updatedAt = updatedAt
            return note
        }
    }
}

/// Folder counterpart of `PendingNoteOp`.
nonisolated enum PendingFolderOp: Sendable {
    case upsert(NoteFolder)
    case trash(id: UUID, deletedAt: Date, updatedAt: Date)

    var folderID: UUID {
        switch self {
        case .upsert(let folder): folder.id
        case .trash(let id, _, _): id
        }
    }

    func apply(to folder: NoteFolder?, id: UUID) -> NoteFolder? {
        guard folderID == id else { return folder }
        switch self {
        case .upsert(let row):
            return row
        case .trash(_, let deletedAt, let updatedAt):
            guard var folder else { return nil }
            folder.deletedAt = deletedAt
            folder.updatedAt = updatedAt
            return folder
        }
    }
}
