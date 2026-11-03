import Foundation
import GRDB
import Testing
@testable import Oriveo

/// Write-transaction ledger (data source for hang attribution): transaction boundary bookkeeping, ring buffer, in-flight registration of heavy writes, and main-thread write metering.
@Suite("DatabaseWriteLedger")
struct DatabaseWriteLedgerTests {
    /// Acts as the "connection" identity: the ledger distinguishes connections by object identity only.
    private final class FakeConnection {}

    private final class MetricBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [DatabaseWriteLedger.Metric] = []
        func append(_ metric: DatabaseWriteLedger.Metric) {
            lock.lock(); stored.append(metric); lock.unlock()
        }
        var all: [DatabaseWriteLedger.Metric] {
            lock.lock(); defer { lock.unlock() }; return stored
        }
    }

    private final class InflightLog: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [[String]] = []
        func append(_ entries: [DatabaseWriteLedger.Inflight]) {
            lock.lock(); stored.append(entries.map(\.label)); lock.unlock()
        }
        var all: [[String]] {
            lock.lock(); defer { lock.unlock() }; return stored
        }
    }

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("heavy label matches fixture heavy_write_labels exactly")
    func heavyLabelsMatchFixture() throws {
        let fixture = try TelemetryContractFixture.load()
        let labels = try #require(fixture["heavy_write_labels"] as? [String])
        #expect(DatabaseWriteLabel.heavy.map(\.rawValue) == labels)
    }

    @Test("BEGIN → end records one entry; transactions shorter than 100ms are not buffered; no label records unlabeled")
    func recordsOnlyLongTransactions() {
        let ledger = DatabaseWriteLedger(metricObserver: { _ in })
        let connection = FakeConnection()
        let id = ObjectIdentifier(connection)
        ledger.transactionDidBegin(connection: id, isMainThread: false, at: t0)
        ledger.transactionDidEnd(connection: id, at: t0.addingTimeInterval(0.05))
        #expect(ledger.snapshot(now: t0.addingTimeInterval(1)).isEmpty)

        ledger.transactionDidBegin(connection: id, isMainThread: false, at: t0.addingTimeInterval(1))
        ledger.transactionDidEnd(connection: id, at: t0.addingTimeInterval(1.25))
        let records = ledger.snapshot(now: t0.addingTimeInterval(2))
        #expect(records == [DatabaseWriteLedger.Record(
            label: "unlabeled", start: t0.addingTimeInterval(1), end: t0.addingTimeInterval(1.25), isMainThread: false
        )])
        // End notifications with no BEGIN record (implicit commit of a single statement outside a transaction) are ignored.
        ledger.transactionDidEnd(connection: ObjectIdentifier(FakeConnection()), at: t0)
        #expect(ledger.snapshot(now: t0.addingTimeInterval(2)).count == 1)
    }

    @Test("Ring buffer keeps only the latest 32 entries, old → new")
    func ringBufferKeepsNewest() {
        let ledger = DatabaseWriteLedger(metricObserver: { _ in })
        let connection = FakeConnection()
        let id = ObjectIdentifier(connection)
        for index in 0..<40 {
            let start = t0.addingTimeInterval(Double(index))
            ledger.transactionDidBegin(connection: id, isMainThread: false, at: start)
            ledger.transactionDidEnd(connection: id, at: start.addingTimeInterval(0.2))
        }
        let records = ledger.snapshot(now: t0.addingTimeInterval(100))
        #expect(records.count == 32)
        #expect(records.first?.start == t0.addingTimeInterval(8))
        #expect(records.last?.start == t0.addingTimeInterval(39))
    }

    @Test("In-progress write transactions also appear in the snapshot (end = now); those not ended within 60s are treated as lost notifications and excluded")
    func snapshotIncludesRunningTransactions() {
        let ledger = DatabaseWriteLedger(metricObserver: { _ in })
        let running = FakeConnection()
        let stale = FakeConnection()
        ledger.transactionDidBegin(connection: ObjectIdentifier(stale), isMainThread: false, at: t0)
        ledger.transactionDidBegin(connection: ObjectIdentifier(running), isMainThread: false, at: t0.addingTimeInterval(70))
        let now = t0.addingTimeInterval(72)
        #expect(ledger.snapshot(now: now) == [DatabaseWriteLedger.Record(
            label: "unlabeled", start: t0.addingTimeInterval(70), end: now, isMainThread: false
        )])
    }

    @Test("Label: outer label takes effect; without a BEGIN record but inside a transaction, the label time is the start point")
    func labelsStampTransactions() {
        let ledger = DatabaseWriteLedger(metricObserver: { _ in })
        let connection = FakeConnection()
        let id = ObjectIdentifier(connection)
        ledger.transactionDidBegin(connection: id, isMainThread: false, at: t0)
        ledger.withLabel(.syncBatch, connection: id, insideTransaction: true) {
            ledger.withLabel(.messagePersist, connection: id, insideTransaction: true) {}
        }
        ledger.transactionDidEnd(connection: id, at: t0.addingTimeInterval(0.3))
        #expect(ledger.snapshot(now: t0.addingTimeInterval(1)).map(\.label) == ["sync.batch"])
        #expect(ledger.labeledTransactionCount(.syncBatch) == 1)

        // In DEBUG the trace slot is occupied by the write guard: with no BEGIN, the label time is the start point.
        let other = FakeConnection()
        let otherID = ObjectIdentifier(other)
        ledger.withLabel(.conversationReplaceAll, connection: otherID, insideTransaction: true, now: t0.addingTimeInterval(2)) {}
        ledger.transactionDidEnd(connection: otherID, at: t0.addingTimeInterval(2.5))
        #expect(ledger.snapshot(now: t0.addingTimeInterval(3)).last == DatabaseWriteLedger.Record(
            label: "conversation.replaceAll",
            start: t0.addingTimeInterval(2),
            end: t0.addingTimeInterval(2.5),
            isMainThread: Thread.isMainThread
        ))
        // A label set outside a transaction does not fabricate a transaction.
        ledger.withLabel(.syncBatch, connection: ObjectIdentifier(FakeConnection()), insideTransaction: false) {}
        #expect(ledger.snapshot(now: t0.addingTimeInterval(3)).count == 2)
    }

    @Test("Heavy write start registers in-flight, end removes it; ordinary labels are not registered")
    func heavyLabelsPublishInflight() {
        let ledger = DatabaseWriteLedger(metricObserver: { _ in })
        let log = InflightLog()
        ledger.setInflightObserver { log.append($0) }
        let id = ObjectIdentifier(FakeConnection())
        ledger.withLabel(.conversationReplaceAll, connection: id, insideTransaction: false) {
            #expect(ledger.inflightSnapshot().map(\.label) == ["conversation.replaceAll"])
            ledger.withLabel(.backupConverge, connection: id, insideTransaction: false) {
                #expect(ledger.inflightSnapshot().map(\.label) == ["conversation.replaceAll", "backup.converge"])
            }
        }
        #expect(ledger.inflightSnapshot().isEmpty)
        #expect(log.all == [
            ["conversation.replaceAll"],
            ["conversation.replaceAll", "backup.converge"],
            ["conversation.replaceAll"],
            [],
        ])
        ledger.withLabel(.unlabeled, connection: id, insideTransaction: false) {}
        #expect(log.all.count == 4)
    }

    @Test("In-flight registration is removed even when body throws")
    func inflightRemovedOnThrow() {
        struct Boom: Error {}
        let ledger = DatabaseWriteLedger(metricObserver: { _ in })
        #expect(throws: Boom.self) {
            try ledger.withLabel(.syncBatch, connection: ObjectIdentifier(FakeConnection()), insideTransaction: false) {
                throw Boom()
            }
        }
        #expect(ledger.inflightSnapshot().isEmpty)
    }

    @Test("Main-thread write transaction ≥ 16ms records db.main_thread_write_ms{db.write_label}; background and short writes do not")
    func mainThreadWriteMetric() throws {
        let box = MetricBox()
        let ledger = DatabaseWriteLedger(metricObserver: { box.append($0) })
        let id = ObjectIdentifier(FakeConnection())
        ledger.transactionDidBegin(connection: id, isMainThread: true, at: t0)
        ledger.transactionDidEnd(connection: id, at: t0.addingTimeInterval(0.010))
        ledger.transactionDidBegin(connection: id, isMainThread: false, at: t0)
        ledger.transactionDidEnd(connection: id, at: t0.addingTimeInterval(0.040))
        ledger.transactionDidBegin(connection: id, isMainThread: true, at: t0)
        ledger.withLabel(.messagePersist, connection: id, insideTransaction: true) {}
        ledger.transactionDidEnd(connection: id, at: t0.addingTimeInterval(0.032))
        let metrics = box.all
        #expect(metrics.count == 1)
        let metric = try #require(metrics.first)
        #expect(metric.name == "db.main_thread_write_ms")
        #expect(metric.label == "message.persist")
        #expect(abs(metric.valueMs - 32) < 0.001)

        let fixture = try TelemetryContractFixture.load()
        let registered = try #require(fixture["metrics"] as? [[String: Any]])
        let entry = try #require(registered.first { $0["name"] as? String == metric.name })
        #expect(entry["kind"] as? String == "distribution")
        #expect(entry["tags"] as? [String] == ["db.write_label"])
    }

    @Test("Write transactions ≥ 500ms (any thread) record db.long_write_ms{db.write_label}; long main-thread writes record both")
    func longWriteMetric() throws {
        let box = MetricBox()
        let ledger = DatabaseWriteLedger(metricObserver: { box.append($0) })
        let id = ObjectIdentifier(FakeConnection())
        ledger.transactionDidBegin(connection: id, isMainThread: false, at: t0)
        ledger.transactionDidEnd(connection: id, at: t0.addingTimeInterval(0.499))
        #expect(box.all.isEmpty)
        ledger.transactionDidBegin(connection: id, isMainThread: false, at: t0)
        ledger.withLabel(.conversationReplaceAll, connection: id, insideTransaction: true) {}
        ledger.transactionDidEnd(connection: id, at: t0.addingTimeInterval(1.2))
        #expect(box.all.map(\.name) == ["db.long_write_ms"])
        #expect(box.all.first?.label == "conversation.replaceAll")
        #expect(abs((box.all.first?.valueMs ?? 0) - 1200) < 0.001)
        ledger.transactionDidBegin(connection: id, isMainThread: true, at: t0)
        ledger.transactionDidEnd(connection: id, at: t0.addingTimeInterval(0.6))
        #expect(box.all.suffix(2).map(\.name) == ["db.main_thread_write_ms", "db.long_write_ms"])

        let fixture = try TelemetryContractFixture.load()
        let registered = try #require(fixture["metrics"] as? [[String: Any]])
        let entry = try #require(registered.first { $0["name"] as? String == "db.long_write_ms" })
        #expect(entry["kind"] as? String == "distribution")
        #expect(entry["tags"] as? [String] == ["db.write_label"])
        #expect((entry["platforms"] as? [String])?.contains("ios") == true)
    }

    @Test("Installed on a real connection: BEGIN recognized by trace, commit and rollback closed out by the transaction observer")
    func installedOnRealConnection() throws {
        let ledger = DatabaseWriteLedger(minimumRecordedDuration: 0, metricObserver: { _ in })
        var configuration = Configuration()
        configuration.prepareDatabase { db in
            DatabaseWriteLedger.install(on: db, ledger: ledger, tracingBegin: true)
        }
        let queue = try DatabaseQueue(configuration: configuration)
        try queue.write { db in
            try db.execute(sql: "CREATE TABLE t(a)")
        }
        try queue.write { db in
            try DatabaseWriteLabel.with(.syncBatch, db, ledger: ledger) {
                try db.execute(sql: "INSERT INTO t VALUES (1)")
            }
        }
        struct Abort: Error {}
        _ = try? queue.write { db in
            try db.execute(sql: "INSERT INTO t VALUES (2)")
            throw Abort()
        }
        // A savepoint inside a transaction is not a transaction boundary.
        try queue.write { db in
            try db.inSavepoint {
                try db.execute(sql: "INSERT INTO t VALUES (3)")
                return .rollback
            }
        }
        #expect(ledger.snapshot().map(\.label) == ["unlabeled", "sync.batch", "unlabeled", "unlabeled"])
        #expect(ledger.labeledTransactionCount(.syncBatch) == 1)
    }

    @Test("Production write paths are labeled: replaceAll / message persist / remote batch write")
    func productionWritesAreLabeled() async throws {
        let uid = "ledger-\(UUID().uuidString)"
        try FileManager.default.createDirectory(at: AppSessionStore.userDir(for: uid), withIntermediateDirectories: true)
        defer { await TestPartitionCleanup.remove(uid) }
        let dbPool = try DatabasePool(
            path: AppSessionStore.databasePath(for: uid).path,
            configuration: DatabaseSchema.makeConfiguration()
        )
        // Runs before the TestPartitionCleanup defer above, so the pool is closed before the directory is unlinked.
        defer { try? dbPool.close() }
        let attachmentFileStore = AttachmentFileStore(
            rootDirectory: AppSessionStore.userDir(for: uid).appendingPathComponent("Files", isDirectory: true)
        )
        try DatabaseSchema.makeMigrator(attachmentFileStore: attachmentFileStore).migrate(dbPool)
        let store = ConversationStore(dbPool: dbPool, attachmentFileStore: attachmentFileStore)
        let shared = DatabaseWriteLedger.shared

        // Other cases running in parallel only make the count larger, so the assertion is "at least +1".
        let replaceAll = shared.labeledTransactionCount(.conversationReplaceAll)
        try store.replaceAllConversations([TestFactories.makeConversation()])
        #expect(shared.labeledTransactionCount(.conversationReplaceAll) > replaceAll)

        let persist = shared.labeledTransactionCount(.messagePersist)
        let conversation = TestFactories.makeConversation()
        try store.upsertConversation(conversation)
        #expect(shared.labeledTransactionCount(.messagePersist) > persist)

        let batch = shared.labeledTransactionCount(.syncBatch)
        let summary = try #require(try store.fetchConversationSummary(id: conversation.id))
        try store.applyRemoteConversationMetadataPatches([summary])
        #expect(shared.labeledTransactionCount(.syncBatch) > batch)
    }
}
