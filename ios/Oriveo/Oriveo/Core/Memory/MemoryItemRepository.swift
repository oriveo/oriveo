import Foundation
import GRDB
import Observation
import OriveoProviderKit

// Local memory item table and repository. Items are stored in each partition's own database (the memory_item table, created by v37),
// with all rules coming from the ProviderKit `MemoryItems` pure functions; the legacy memoryText field is dual-written by the repository, and a
// memoryText changed by an older build is folded back into items by reconcileLegacy. Local writes are marked pending.

/// Push state of an item: pending when it was written locally and has not been pushed successfully yet.
nonisolated enum MemoryItemSyncState: String, Hashable, Sendable {
    case synced
    case pending
}

extension Notification.Name {
    /// A write to the memory_item table (any partition); object is the `DatabasePool` used for the write.
    nonisolated static let memoryItemsDidChange = Notification.Name("MemoryItemStore.memoryItemsDidChange")
}

/// Reads and writes the memory_item table: one row per item, with the payload holding the full JSON in the contract fieldOrder; ids are lowercase.
final class MemoryItemStore: @unchecked Sendable {
    nonisolated static let table = "memory_item"

    private let dbPool: DatabasePool

    /// The connection this store uses (the item cache uses it to tell whether a write came from the connection it is observing).
    nonisolated var pool: DatabasePool { dbPool }

    nonisolated init(dbPool: DatabasePool) {
        self.dbPool = dbPool
    }

    /// Creates the table (`v37_memory_items`).
    nonisolated static func createTables(in db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE \(table) (
                id TEXT PRIMARY KEY NOT NULL,
                status TEXT NOT NULL,
                payload TEXT NOT NULL,
                syncState TEXT NOT NULL DEFAULT 'pending'
            )
            """)
    }

    /// The store of the partition; nil when the database cannot be opened.
    nonisolated static func forPartition(_ uid: String) -> MemoryItemStore? {
        (try? DatabaseManager.shared.openIfNeeded(for: uid)).map { MemoryItemStore(dbPool: $0) }
    }

    /// All items (including tombstones); corrupt rows are skipped.
    nonisolated func all() throws -> [MemoryItem] {
        try dbPool.read { db in try Self.fetchAll(db) }
    }

    nonisolated func item(id: String) throws -> MemoryItem? {
        try dbPool.read { db in
            try Row.fetchOne(db, sql: "SELECT payload FROM \(Self.table) WHERE id = ?", arguments: [id.lowercased()])
                .flatMap(Self.item(from:))
        }
    }

    /// Items waiting to be pushed (including tombstones), ordered by id ascending; corrupt rows are skipped.
    nonisolated func pendingItems() throws -> [MemoryItem] {
        try dbPool.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT payload FROM \(Self.table) WHERE syncState = ? ORDER BY id ASC",
                arguments: [MemoryItemSyncState.pending.rawValue]
            ).compactMap(Self.item(from:))
        }
    }

    nonisolated func syncState(id: String) throws -> MemoryItemSyncState? {
        try dbPool.read { db in
            try String.fetchOne(db, sql: "SELECT syncState FROM \(Self.table) WHERE id = ?", arguments: [id.lowercased()])
                .flatMap(MemoryItemSyncState.init(rawValue:))
        }
    }

    /// Overwrites the row with the same id. `alongside` runs in the same write transaction (other tables of the same database); if it throws, everything rolls back.
    nonisolated func upsert(
        _ items: [MemoryItem],
        syncState: MemoryItemSyncState,
        alongside: (@Sendable (Database) throws -> Void)? = nil
    ) throws {
        guard !items.isEmpty else { return }
        try dbPool.write { db in
            for item in items {
                try Self.write(item, syncState: syncState, replace: true, in: db)
            }
            try alongside?(db)
        }
        postChange()
    }

    /// create-if-absent: a row with the same id is left untouched; returns the items actually written.
    @discardableResult
    nonisolated func insertIfAbsent(_ items: [MemoryItem], syncState: MemoryItemSyncState) throws -> [MemoryItem] {
        guard !items.isEmpty else { return [] }
        let inserted = try dbPool.write { db -> [MemoryItem] in
            var inserted: [MemoryItem] = []
            for item in items {
                if try Self.write(item, syncState: syncState, replace: false, in: db) {
                    inserted.append(MemoryItems.canonical(item))
                }
            }
            return inserted
        }
        if !inserted.isEmpty { postChange() }
        return inserted
    }

    nonisolated func setSyncState(_ syncState: MemoryItemSyncState, id: String) throws {
        try dbPool.write { db in
            try db.execute(
                sql: "UPDATE \(Self.table) SET syncState = ? WHERE id = ?",
                arguments: [syncState.rawValue, id.lowercased()]
            )
        }
        postChange()
    }

    /// Calls back whenever items change (first with the current full set, including tombstones), on the main queue.
    nonisolated func observe(_ onChange: @escaping @MainActor ([MemoryItem]) -> Void) -> AnyDatabaseCancellable {
        ValueObservation.tracking { db in try Self.fetchAll(db) }
            .start(
                in: dbPool,
                scheduling: .async(onQueue: .main),
                onError: { _ in },
                onChange: { items in MainActor.assumeIsolated { onChange(items) } }
            )
    }

    @discardableResult
    private nonisolated static func write(
        _ item: MemoryItem, syncState: MemoryItemSyncState, replace: Bool, in db: Database
    ) throws -> Bool {
        let canonical = MemoryItems.canonical(item)
        let payload = String(decoding: try JSONEncoder().encode(canonical), as: UTF8.self)
        let verb = replace ? "INSERT OR REPLACE" : "INSERT OR IGNORE"
        try db.execute(
            sql: "\(verb) INTO \(table) (id, status, payload, syncState) VALUES (?, ?, ?, ?)",
            arguments: [canonical.id, canonical.status.rawValue, payload, syncState.rawValue]
        )
        return db.changesCount > 0
    }

    private nonisolated static func fetchAll(_ db: Database) throws -> [MemoryItem] {
        try Row.fetchAll(db, sql: "SELECT payload FROM \(table) ORDER BY id ASC").compactMap(item(from:))
    }

    private nonisolated static func item(from row: Row) -> MemoryItem? {
        guard let payload: String = row["payload"] else { return nil }
        return decodeItem(Data(payload.utf8))
    }

    /// Decodes one item: an unknown status falls back to paused and an unknown kind to fact, so no row is dropped (a new value written by a newer build does not make an older build lose data).
    nonisolated static func decodeItem(_ data: Data) -> MemoryItem? {
        if let item = try? JSONDecoder().decode(MemoryItem.self, from: data) { return item }
        guard var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        if let raw = object["status"], !(raw is NSNull), (raw as? String).flatMap(MemoryStatus.init(rawValue:)) == nil {
            object["status"] = MemoryStatus.paused.rawValue
        }
        if let raw = object["kind"], (raw as? String).flatMap(MemoryKind.init(rawValue:)) == nil {
            object["kind"] = MemoryKind.fact.rawValue
        }
        guard let patched = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        return try? JSONDecoder().decode(MemoryItem.self, from: patched)
    }

    private nonisolated func postChange() {
        NotificationCenter.default.post(name: .memoryItemsDidChange, object: dbPool)
    }
}

/// In-memory copy of the current partition's memory items (no tombstones, in list order), refreshed by database observation. The request snapshot of the send path is taken from here,
/// so the database is never read on the main thread; `bind` on partition activation, and when the partition changes it clears first and then observes the new database, with the first value arriving asynchronously.
/// Observable: the toolbar memory indicator and the "memory used" popover refresh as items change.
///
/// GRDB observation only sees writes committed by the same `DatabasePool`; `DatabaseManager` keeps the connection of only one partition,
/// so once another partition has been opened elsewhere (or after close), reopening this partition yields a new connection, and writes through the new connection never deliver a value to the old observation.
/// So it also listens to `.memoryItemsDidChange`: when a write to this partition's database file comes from another connection, it re-observes on that connection.
@Observable
final class MemoryItemsCache {
    private(set) var items: [MemoryItem] = []
    private(set) var uid: String?
    @ObservationIgnored private var observation: AnyDatabaseCancellable?
    @ObservationIgnored private var observedPool: DatabasePool?
    @ObservationIgnored private nonisolated(unsafe) var changeObserver: NSObjectProtocol?
    #if DEBUG
    /// Screenshots only: after in-memory items are placed here, it no longer binds to or follows any database.
    @ObservationIgnored private var pinnedForShots = false
    #endif

    init() {
        changeObserver = NotificationCenter.default.addObserver(
            forName: .memoryItemsDidChange, object: nil, queue: .main
        ) { [weak self] note in
            guard let pool = note.object as? DatabasePool else { return }
            MainActor.assumeIsolated { self?.followWriter(pool) }
        }
    }

    nonisolated deinit {
        if let changeObserver {
            NotificationCenter.default.removeObserver(changeObserver)
        }
    }

    func bind(uid: String) {
        #if DEBUG
        if pinnedForShots { return }
        #endif
        guard self.uid != uid || observation == nil else { return }
        self.uid = uid
        items = []
        observe(MemoryItemStore.forPartition(uid))
    }

    /// The writer's connection points at this partition's database file but is not the one being observed: switch to observing it (its first value already includes this write).
    private func followWriter(_ pool: DatabasePool) {
        #if DEBUG
        if pinnedForShots { return }
        #endif
        guard let uid, pool !== observedPool,
              pool.path == AppSessionStore.databasePath(for: uid).path else { return }
        observe(MemoryItemStore(dbPool: pool))
    }

    #if DEBUG
    /// Screenshots only: switch to the in-memory items built from the manifest and detach from database observation (nothing is read or written).
    func pinForShots(_ items: [MemoryItem]) {
        pinnedForShots = true
        observation?.cancel()
        observation = nil
        observedPool = nil
        self.items = MemoryItems.listOrder(items.filter { $0.status != .deleted })
    }
    #endif

    private func observe(_ store: MemoryItemStore?) {
        observation?.cancel()
        observedPool = store?.pool
        guard let uid else { return }
        observation = store?.observe { [weak self] all in
            guard let self, self.uid == uid else { return }
            self.items = MemoryItems.listOrder(all.filter { $0.status != .deleted })
        }
    }
}

/// Read/write port for the legacy fields (the memoryText group of preferences): AppState wires it to preference persistence, and tests wire it to memory.
struct MemoryLegacyPrefsBridge {
    var read: () -> MemoryLegacyPrefs
    var write: (MemoryLegacyCompile) -> Void
}

/// Memory mode for backup import: maps one-to-one onto `ImportMode`.
enum MemoryBackupImportMode {
    case newOnly
    case merge
    case replace
}

/// The memory item repository of one partition. All writes work the same way: a new mutationId (random, lowercase), baseRevision = revision, this device's deviceId,
/// marked pending; a new item gets createdAt = local time; a delete writes a tombstone. After items change, the legacy fields are compiled and dual-written only if they differ from prefs.
final class MemoryItemRepository {
    let uid: String
    let deviceId: String
    let store: MemoryItemStore
    private let migrationScope: String
    private let bridge: MemoryLegacyPrefsBridge
    private let now: () -> Date
    /// Notified after a local write.
    var onLocalChange: (@MainActor () -> Void)?

    /// - Parameters:
    ///   - uid: partition uid ("guest" for the guest partition); determines the deterministic ids of migrated items.
    ///   - migrationScope: the partition key holding the "migrated" flag; defaults to uid.
    init(
        uid: String,
        store: MemoryItemStore,
        bridge: MemoryLegacyPrefsBridge,
        deviceId: String = AppPreferencesStore.memoryDeviceId,
        migrationScope: String? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.uid = uid
        self.store = store
        self.bridge = bridge
        self.deviceId = deviceId
        self.migrationScope = migrationScope ?? uid
        self.now = now
    }

    /// nil when the partition database cannot be opened.
    static func forPartition(_ uid: String, bridge: MemoryLegacyPrefsBridge) -> MemoryItemRepository? {
        MemoryItemStore.forPartition(uid).map { MemoryItemRepository(uid: uid, store: $0, bridge: bridge) }
    }

    var isMigrated: Bool {
        AppPreferencesStore.memoryItemsMigrated(uid: migrationScope)
    }

    // MARK: Reads

    /// List order, without tombstones.
    func list() -> [MemoryItem] {
        MemoryItems.listOrder(allItems().filter { $0.status != .deleted })
    }

    /// All items, including tombstones.
    func allItems() -> [MemoryItem] {
        (try? store.all()) ?? []
    }

    func syncState(id: String) -> MemoryItemSyncState? {
        try? store.syncState(id: id)
    }

    /// Calls back whenever the list (no tombstones, list order) changes, first with the current value.
    func observe(_ onChange: @escaping @MainActor ([MemoryItem]) -> Void) -> AnyDatabaseCancellable {
        store.observe { items in
            onChange(MemoryItems.listOrder(items.filter { $0.status != .deleted }))
        }
    }

    // MARK: Writes

    /// Manual create; when layer = episodic it is created as L3 (occurredAt defaults to now, and conflicts are checked after saving).
    @discardableResult
    func create(
        kind: MemoryKind = .fact, content: String, pinned: Bool = false, layer: MemoryLayer = .semantic,
        occurredAt: String? = nil
    ) throws -> MemoryItem {
        let item = try writer().create(kind: kind, content: content, pinned: pinned, layer: layer, occurredAt: occurredAt)
        didWriteLocally()
        return item
    }

    /// Creates an item after a candidate is confirmed: the same create path as create (new id, pending, dual-write of the legacy fields), with fields taken from the draft.
    @discardableResult
    func createFromDraft(
        _ draft: MemoryItemDraft,
        alongside: (@Sendable (Database) throws -> Void)? = nil
    ) async throws -> MemoryItem {
        try await perform { try $0.create(draft: draft, alongside: alongside) }
    }

    /// Edits the content; when `kind` is non-nil the kind is changed too (settings editor); when `occurredAt` is non-nil the L3 date is changed.
    @discardableResult
    func update(id: String, content: String, kind: MemoryKind? = nil, occurredAt: String? = nil) throws -> MemoryItem? {
        try finish(writer().update(id: id, content: content, kind: kind, occurredAt: occurredAt))
    }

    @discardableResult
    func setPinned(id: String, pinned: Bool) throws -> MemoryItem? {
        try finish(writer().setPinned(id: id, pinned: pinned))
    }

    /// Changing to deleted is the same as remove (writes a tombstone).
    @discardableResult
    func setStatus(id: String, status: MemoryStatus) throws -> MemoryItem? {
        try finish(writer().setStatus(id: id, status: status))
    }

    /// Writes a tombstone; returns nil when the item does not exist or is already a tombstone.
    @discardableResult
    func remove(id: String) throws -> MemoryItem? {
        try finish(writer().remove(id: id))
    }

    /// Database reads and writes run on a background thread; back on the main thread the legacy fields are dual-written (all settings-page writes go through here, so the main thread never touches the database).
    @discardableResult
    func perform<T: Sendable>(_ write: @escaping @Sendable (MemoryItemWriter) throws -> T) async throws -> T {
        let writer = writer()
        let (result, all) = try await Task.detached(priority: .userInitiated) {
            let result = try write(writer)
            return (result, try writer.store.all())
        }.value
        dualWrite(items: all)
        notifyLocalChange()
        return result
    }

    // MARK: Legacy fields

    /// Called on partition activation or when memoryText changes: migrates if not yet migrated, otherwise folds a memoryText changed by an older build back into items;
    /// then marks "migrated" and writes back the legacy fields when needed.
    func reconcileLegacy() throws {
        let result = MemoryItems.legacySync(
            uid: uid,
            migrated: isMigrated,
            deviceId: deviceId,
            items: allItems(),
            prefs: bridge.read(),
            deletedAt: Self.timestamp(now())
        )
        try store.insertIfAbsent(result.create, syncState: .pending)
        try store.upsert(result.update, syncState: .pending)
        AppPreferencesStore.setMemoryItemsMigrated(true, uid: migrationScope)
        if let writePrefs = result.writePrefs {
            bridge.write(writePrefs)
        }
        if !result.create.isEmpty || !result.update.isEmpty { notifyLocalChange() }
    }

    /// Receives the guest partition's items on sign-in: tombstones are skipped, original ids are kept, items are marked pending; items whose id already exists in this partition are left alone. Returns the number written.
    @discardableResult
    func adoptGuestItems(_ items: [MemoryItem]) throws -> Int {
        let inserted = try store.insertIfAbsent(items.filter { $0.status != .deleted }, syncState: .pending)
        if !inserted.isEmpty {
            dualWrite()
            notifyLocalChange()
        }
        return inserted.count
    }

    // MARK: Backup

    /// Backup import: replace lands the backup items as a whole and turns items that live locally but are missing from the backup into tombstones (existing local tombstones are kept as they are); merge follows `MemoryItems.backupMerge` and takes the higher revision (never resurrects a local tombstone);
    /// newOnly adds only ids missing locally (a tombstone counts as present). Old backups without memoryItems are migrated from their preferences, and under merge / newOnly
    /// created if absent. Imported rows are always pending; the caller dual-writes the legacy fields via `dualWriteLegacy()` after preferences are restored.
    /// Returns the number of changed items (replace includes the local items it replaced).
    @discardableResult
    func importBackup(_ backup: MemoryBackupInput, mode: MemoryBackupImportMode) throws -> Int {
        let local = allItems().map(MemoryItems.canonical)
        var changed = 0
        switch mode {
        case .replace:
            // The backup items land as a whole; items alive locally but absent from the backup become tombstones; existing local tombstones are kept as they are
            let incoming = MemoryItems.backupMerge(mode: .replace, local: local, backup: backup, uid: uid, deviceId: deviceId)
            let missing = Set(MemoryItems.backupReplaceTombstonedIds(local: local, replaced: incoming))
            let deletedAt = Self.timestamp(now())
            let tombstones = local.filter { missing.contains($0.id) }
                .map { MemoryItems.tombstone($0, mutationId: Self.newId(), deviceId: deviceId, deletedAt: deletedAt) }
            try store.upsert(incoming + tombstones, syncState: .pending)
            changed = incoming.count + tombstones.count
        case .merge where backup.memoryItems != nil:
            let localById = Dictionary(local.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let written = MemoryItems.backupMerge(mode: .merge, local: local, backup: backup, uid: uid, deviceId: deviceId)
                .filter { localById[$0.id] != $0 }
            try store.upsert(written, syncState: .pending)
            changed = written.count
        case .merge, .newOnly:
            let incoming = backup.memoryItems
                ?? backup.preferences.map { MemoryItems.migrate(uid: uid, deviceId: deviceId, prefs: $0) }
                ?? []
            changed = try store.insertIfAbsent(incoming, syncState: .pending).count
        }
        // After importing a backup with an items section (in any mode) this partition counts as migrated: the legacy fields are not migrated into items again, to avoid duplicating the imported items
        if backup.memoryItems != nil {
            AppPreferencesStore.setMemoryItemsMigrated(true, uid: migrationScope)
        }
        if changed > 0 { notifyLocalChange() }
        return changed
    }

    /// After items change (for example after a backup import or a preference restore), compiles the legacy fields and dual-writes only if they differ from prefs.
    func dualWriteLegacy() {
        dualWrite()
    }

    // MARK: Conflicts

    /// Conflict landing: both the original item and the copy (local changes) are marked pending. Counts as a local change and dual-writes the legacy fields.
    func applyConflict(_ conflict: MemoryConflict) throws {
        try store.upsert([conflict.original, conflict.copy], syncState: .pending)
        dualWrite()
        notifyLocalChange()
    }

    /// Resolves a conflict: the kept item becomes active with conflictGroupId cleared, and the rest of the group are tombstoned. Returns nil if the item does not exist, is deleted, or is not in a conflict group.
    @discardableResult
    func resolveConflict(keepId: String) throws -> MemoryItem? {
        try finish(writer().resolveConflict(keepId: keepId))
    }

    /// L3 conflict resolution: rewrites local items with the two patches from `MemoryRecall.resolve` and deletes nothing.
    /// Returns nil if either item does not exist or is deleted; L3 is a plain local edit.
    @discardableResult
    func resolveL3Conflict(
        newerId: String, olderId: String, resolution: MemoryConflictResolution
    ) throws -> [MemoryItem]? {
        let written = try writer().resolveL3Conflict(newerId: newerId, olderId: olderId, resolution: resolution)
        if written != nil { didWriteLocally() }
        return written
    }

    private func writer() -> MemoryItemWriter {
        MemoryItemWriter(store: store, deviceId: deviceId, timestamp: Self.timestamp(now()))
    }

    /// Dual-writes only when something was actually written (non-nil result).
    private func finish(_ item: MemoryItem?) -> MemoryItem? {
        if item != nil { didWriteLocally() }
        return item
    }

    private func didWriteLocally() {
        dualWrite()
        notifyLocalChange()
    }

    private func notifyLocalChange() {
        onLocalChange?()
    }

    /// Writes the legacy fields only when the compiled result or digest differs from prefs.
    private func dualWrite() {
        dualWrite(items: allItems())
    }

    private func dualWrite(items: [MemoryItem]) {
        let compiled = MemoryItems.compileLegacy(uid: uid, items: items)
        let prefs = bridge.read()
        guard compiled.memoryText != (prefs.memoryText ?? "")
            || compiled.memoryTextDigest != prefs.memoryTextDigest
        else { return }
        bridge.write(compiled)
    }

    nonisolated static func newId() -> String {
        UUID().uuidString.lowercased()
    }

    /// Local time, RFC 3339 (UTC, milliseconds).
    nonisolated static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    /// Candidate source time (epoch milliseconds) to UTC RFC 3339, truncated to seconds, with a Z suffix.
    nonisolated static func observedAt(ms: Int64) -> String {
        let seconds = ms >= 0 ? ms / 1000 : (ms - 999) / 1000
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(seconds)))
    }
}

/// The database part of an item write: does not touch main-thread state and may run in the background; dual-writing the legacy fields is done by the repository on the main thread.
/// New mutationId (random, lowercase), baseRevision = revision, this device's deviceId, marked pending; timestamps use the local time at construction.
nonisolated struct MemoryItemWriter: Sendable {
    let store: MemoryItemStore
    let deviceId: String
    let timestamp: String

    func create(
        kind: MemoryKind = .fact, content: String, pinned: Bool = false, layer: MemoryLayer = .semantic,
        occurredAt: String? = nil
    ) throws -> MemoryItem {
        let item = MemoryItem(
            id: MemoryItemRepository.newId(), layer: layer, kind: kind, content: content, pinned: pinned,
            mutationId: MemoryItemRepository.newId(), deviceId: deviceId,
            occurredAt: layer == .episodic ? (occurredAt ?? timestamp) : nil, createdAt: timestamp
        )
        return try save(newItem: item)
    }

    /// A confirmed candidate draft becomes a new item: draft fields as they are, source.observedAt is observedAtMs truncated to seconds.
    /// `alongside` runs in the same write transaction as the item write (the candidate row is deleted on confirmation).
    func create(draft: MemoryItemDraft, alongside: (@Sendable (Database) throws -> Void)? = nil) throws -> MemoryItem {
        let item = MemoryItem(
            id: MemoryItemRepository.newId(),
            layer: draft.layer,
            kind: draft.kind,
            status: draft.status,
            content: draft.content,
            scope: draft.scope,
            source: MemorySource(
                type: draft.source.type,
                conversationId: draft.source.conversationId,
                messageIds: draft.source.messageIds,
                observedAt: draft.source.observedAtMs.map(MemoryItemRepository.observedAt(ms:))
            ),
            sensitivity: draft.sensitivity,
            confidence: draft.confidence,
            mutationId: MemoryItemRepository.newId(),
            deviceId: deviceId,
            // The draft carries no occurredAt: a new L3 item always takes the current local time.
            occurredAt: draft.layer == .episodic ? timestamp : nil,
            createdAt: timestamp
        )
        return try save(newItem: item, alongside: alongside)
    }

    /// Saves a new item; L3 checks for conflicts first: on a hit, both the new and the old item become conflicted with conflictGroupId = the old item's id, in the same write.
    private func save(
        newItem: MemoryItem,
        alongside: (@Sendable (Database) throws -> Void)? = nil
    ) throws -> MemoryItem {
        var item = MemoryItems.canonical(newItem)
        var writes: [MemoryItem] = []
        if item.layer == .episodic {
            let existing = try store.all()
            if let olderId = MemoryRecall.conflict(saved: item, items: existing),
               let stored = existing.first(where: { $0.id.lowercased() == olderId }) {
                var older = touched(MemoryItems.canonical(stored))
                older.status = .conflicted
                older.conflictGroupId = olderId
                item.status = .conflicted
                item.conflictGroupId = olderId
                writes.append(older)
            }
        }
        try store.upsert([item] + writes, syncState: .pending, alongside: alongside)
        return item
    }

    /// L3 conflict resolution: when both items exist and are not deleted, status / conflictGroupId / supersedes are patched per `MemoryRecall.resolve`.
    /// Returns [newer, older].
    func resolveL3Conflict(
        newerId: String, olderId: String, resolution: MemoryConflictResolution
    ) throws -> [MemoryItem]? {
        guard let newer = try store.item(id: newerId), newer.status != .deleted,
              let older = try store.item(id: olderId), older.status != .deleted else { return nil }
        let patches = MemoryRecall.resolve(newer: newer, older: older, resolution: resolution)
        let written = zip([newer, older], patches).map { stored, patch -> MemoryItem in
            var item = touched(MemoryItems.canonical(stored))
            item.status = patch.status
            item.conflictGroupId = patch.conflictGroupId
            item.supersedes = patch.supersedes
            return item
        }
        try store.upsert(written, syncState: .pending)
        return written
    }

    /// Common fields of a local edit: new mutationId, baseRevision = revision, this device's deviceId.
    private func touched(_ item: MemoryItem) -> MemoryItem {
        var item = item
        item.mutationId = MemoryItemRepository.newId()
        item.baseRevision = item.revision
        item.deviceId = deviceId
        return item
    }

    func update(id: String, content: String, kind: MemoryKind? = nil, occurredAt: String? = nil) throws -> MemoryItem? {
        try edit(id: id) { item in
            item.content = content
            if let kind { item.kind = kind }
            // occurredAt belongs to L3 only (the editor's date).
            if let occurredAt, item.layer == .episodic { item.occurredAt = occurredAt }
        }
    }

    func setPinned(id: String, pinned: Bool) throws -> MemoryItem? {
        try edit(id: id) { $0.pinned = pinned }
    }

    /// Changing to deleted is the same as remove (writes a tombstone).
    func setStatus(id: String, status: MemoryStatus) throws -> MemoryItem? {
        if status == .deleted { return try remove(id: id) }
        return try edit(id: id) { $0.status = status }
    }

    /// Writes a tombstone; returns nil when the item does not exist or is already a tombstone.
    func remove(id: String) throws -> MemoryItem? {
        guard let item = try store.item(id: id), item.status != .deleted else { return nil }
        let tombstone = MemoryItems.tombstone(
            item, mutationId: MemoryItemRepository.newId(), deviceId: deviceId, deletedAt: timestamp
        )
        try store.upsert([tombstone], syncState: .pending)
        return tombstone
    }

    /// The kept item becomes active with conflictGroupId cleared, and the rest of the group are tombstoned. Returns nil if the item does not exist, is deleted, or is not in a conflict group.
    func resolveConflict(keepId: String) throws -> MemoryItem? {
        guard let stored = try store.item(id: keepId), stored.status != .deleted,
              let groupId = stored.conflictGroupId?.lowercased() else { return nil }
        var kept = MemoryItems.canonical(stored)
        kept.status = .active
        kept.conflictGroupId = nil
        kept.mutationId = MemoryItemRepository.newId()
        kept.baseRevision = kept.revision
        kept.deviceId = deviceId
        let others = ((try? store.all()) ?? [])
            .filter { $0.id.lowercased() != kept.id && $0.conflictGroupId?.lowercased() == groupId && $0.status != .deleted }
            .map { MemoryItems.tombstone($0, mutationId: MemoryItemRepository.newId(), deviceId: deviceId, deletedAt: timestamp) }
        try store.upsert([kept] + others, syncState: .pending)
        return kept
    }

    private func edit(id: String, _ change: (inout MemoryItem) -> Void) throws -> MemoryItem? {
        guard let stored = try store.item(id: id), stored.status != .deleted else { return nil }
        var item = MemoryItems.canonical(stored)
        change(&item)
        item.mutationId = MemoryItemRepository.newId()
        item.baseRevision = item.revision
        item.deviceId = deviceId
        try store.upsert([item], syncState: .pending)
        return item
    }
}

extension AppPreference {
    /// Snapshot of the legacy fields, for legacySync / dual-write comparison.
    var memoryLegacyPrefs: MemoryLegacyPrefs {
        MemoryLegacyPrefs(
            memoryText: memoryText,
            memoryTextDigest: memoryTextDigest,
            antiForgetEnabled: memoryAntiForgetEnabled,
            antiForgetText: memoryAntiForgetText,
            memoryUpdatedAt: memoryUpdatedAt.map(MemoryItemRepository.timestamp)
        )
    }

    /// Writes the dual-write result into preferences: memoryText and the digest are written as is, Anti-Forget is untouched. memoryUpdatedAt is refreshed only when memoryText really changed —
    /// when only the digest is filled in it is not refreshed, so that a new device does not get it blocked by a newer timestamp.
    func applyingMemoryLegacy(_ compiled: MemoryLegacyCompile, now: Date) -> AppPreference {
        var updated = self
        if updated.memoryText != compiled.memoryText {
            updated.memoryText = compiled.memoryText
            updated.memoryUpdatedAt = now
        }
        updated.memoryTextDigest = compiled.memoryTextDigest
        return updated
    }
}
