import Foundation
import GRDB

/// Source label of a write transaction. Values match the `heavy_write_labels` in the shared fixture `mobile-telemetry.v1.json` verbatim,
/// reported as the tag `db.write_label` / `hang.blocker=db:<label>`; must be a constant defined here, never a concatenated variable.
nonisolated struct DatabaseWriteLabel: RawRepresentable, Hashable, Sendable {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    static let conversationReplaceAll = DatabaseWriteLabel(rawValue: "conversation.replaceAll")
    static let backupConverge = DatabaseWriteLabel(rawValue: "backup.converge")
    static let syncBatch = DatabaseWriteLabel(rawValue: "sync.batch")
    static let messagePersist = DatabaseWriteLabel(rawValue: "message.persist")
    /// Write transaction with no caller-supplied label.
    static let unlabeled = DatabaseWriteLabel(rawValue: "unlabeled")

    /// Fixture `heavy_write_labels`: these write transactions enter the Sentry scope when they start (`hang_blockers.inflight`) and are removed when they end.
    /// Only for heavy writers: ordinary writes do not touch the scope, so every database write does not mutate global state.
    static let heavy: [DatabaseWriteLabel] = [.conversationReplaceAll, .backupConverge, .syncBatch, .messagePersist]

    /// Tags the current write transaction. Must be called **inside** the write closure (where `db` is available): GRDB's async writes run on their own queue,
    /// so thread-local / task-local values on the caller's thread do not reach there; only the connection object is known on both sides.
    /// With nesting, the outer label takes effect.
    static func with<T>(
        _ label: DatabaseWriteLabel,
        _ db: Database,
        ledger: DatabaseWriteLedger = .shared,
        _ body: () throws -> T
    ) rethrows -> T {
        try ledger.withLabel(
            label,
            connection: ObjectIdentifier(db),
            insideTransaction: db.isInsideTransaction,
            body
        )
    }
}

/// Write-transaction ledger: records recent long write transactions `{label, start/end time, whether on the main thread}`, used to attribute App Hangs.
///
/// Why it exists: a hang event carries only the main-thread stack. When the main thread is blocked waiting for the GRDB write lock, the stack only shows `SerializedDatabase.sync`,
/// and the real lock holder (a background full-table write) is not on the stack, so Sentry can only name it after the last UI event (several such hangs were recorded as paste).
/// beforeSend intersects the hang interval with the write transactions here, which attributes the issue to the write that held the lock.
///
/// Overhead budget: accounting happens only at transaction boundaries (BEGIN is recognized by the statement trace, COMMIT / ROLLBACK are notified by the GRDB transaction observer),
/// with no per-statement profiling; the ring buffer keeps only the latest 32 entries of ≥ 100ms, and in-lock work is O(1).
nonisolated final class DatabaseWriteLedger: @unchecked Sendable {
    nonisolated struct Record: Equatable, Sendable {
        let label: String
        let start: Date
        let end: Date
        let isMainThread: Bool

        var duration: TimeInterval { end.timeIntervalSince(start) }
    }

    nonisolated struct Inflight: Equatable, Sendable {
        let label: String
        let start: Date
        let isMainThread: Bool
    }

    /// Metrics sent to the facade (main-thread writes / long writes). The caller decides how to hop threads.
    nonisolated struct Metric: Equatable, Sendable {
        let name: String
        let valueMs: Double
        let label: String
    }

    static let shared = DatabaseWriteLedger()

    static let mainThreadWriteMetric = "db.main_thread_write_ms"
    /// Main-thread write transactions longer than one frame (16ms) record a distribution entry.
    static let mainThreadWriteThreshold: TimeInterval = 0.016
    static let longWriteMetric = "db.long_write_ms"
    /// Write transactions ≥ 500ms on any thread: a long background write makes queued main-thread writes wait behind it (fixture db.long_write).
    static let longWriteThreshold: TimeInterval = 0.5

    let capacity: Int
    let minimumRecordedDuration: TimeInterval
    /// An "in-flight" transaction that has not received its end notification after this long is treated as having lost its notification and excluded from attribution (otherwise it would be taken as an over-long write covering everything).
    let staleOpenTransactionAge: TimeInterval = 60

    private let lock = NSLock()
    private var open: [ObjectIdentifier: OpenTransaction] = [:]
    private var ring: [Record] = []
    private var ringHead = 0
    private var inflight: [UInt64: Inflight] = [:]
    private var nextInflightToken: UInt64 = 0
    private var labeledTransactionCounts: [String: Int] = [:]
    /// Publishing in-flight registrations must preserve order: when two threads interleave, the snapshot computed later must be written to the scope later.
    private let publishLock = NSLock()
    private var inflightObserver: (@Sendable ([Inflight]) -> Void)?
    private var metricObserver: @Sendable (Metric) -> Void

    nonisolated private struct OpenTransaction {
        let start: Date
        let isMainThread: Bool
        var label: String?
    }

    init(
        capacity: Int = 32,
        minimumRecordedDuration: TimeInterval = 0.1,
        metricObserver: @escaping @Sendable (Metric) -> Void = DatabaseWriteLedger.relayToObservability
    ) {
        self.capacity = capacity
        self.minimumRecordedDuration = minimumRecordedDuration
        self.metricObserver = metricObserver
    }

    /// Callback when in-flight registrations change (full list; empty list = no in-flight heavy writes). The official build wires it to the scope via `SentryReporter.start`.
    func setInflightObserver(_ observer: (@Sendable ([Inflight]) -> Void)?) {
        lock.lock()
        inflightObserver = observer
        lock.unlock()
    }

    // MARK: - Installation

    /// Installed on the write connection (`DatabaseSchema.makeConfiguration().prepareDatabase`).
    ///
    /// - Parameter tracingBegin: recognize BEGIN via the statement trace to get the start of unlabeled write transactions. GRDB gives each connection only one
    ///   trace slot, which in DEBUG is taken by `MainThreadDatabaseWriteGuard`; pass false then: the start falls back to the moment of the first
    ///   `DatabaseWriteLabel.with` call, and only labeled writes are recorded.
    static func install(on db: Database, ledger: DatabaseWriteLedger = .shared, tracingBegin: Bool) {
        guard !db.configuration.readonly else { return }
        let connection = ObjectIdentifier(db)
        db.add(transactionObserver: EndObserver(ledger: ledger), extent: .databaseLifetime)
        guard tracingBegin else { return }
        db.trace(options: .statement) { event in
            guard case let .statement(statement) = event, statement.sql.hasPrefix("BEGIN") else { return }
            ledger.transactionDidBegin(connection: connection, isMainThread: Thread.isMainThread, at: Date())
        }
    }

    nonisolated private final class EndObserver: TransactionObserver {
        let ledger: DatabaseWriteLedger

        init(ledger: DatabaseWriteLedger) {
            self.ledger = ledger
        }

        func observes(eventsOfKind eventKind: DatabaseEventKind) -> Bool { false }
        func databaseDidChange(with event: DatabaseEvent) {}

        func databaseDidCommit(_ db: Database) {
            ledger.transactionDidEnd(connection: ObjectIdentifier(db), at: Date())
        }

        func databaseDidRollback(_ db: Database) {
            ledger.transactionDidEnd(connection: ObjectIdentifier(db), at: Date())
        }
    }

    // MARK: - Accounting

    func transactionDidBegin(connection: ObjectIdentifier, isMainThread: Bool, at date: Date) {
        lock.lock()
        open[connection] = OpenTransaction(start: date, isMainThread: isMainThread, label: nil)
        lock.unlock()
    }

    func transactionDidEnd(connection: ObjectIdentifier, at date: Date) {
        lock.lock()
        guard let transaction = open.removeValue(forKey: connection) else {
            lock.unlock()
            return
        }
        let label = transaction.label ?? DatabaseWriteLabel.unlabeled.rawValue
        if transaction.label != nil {
            labeledTransactionCounts[label, default: 0] += 1
        }
        let record = Record(label: label, start: transaction.start, end: date, isMainThread: transaction.isMainThread)
        if record.duration >= minimumRecordedDuration {
            appendLocked(record)
        }
        let observer = metricObserver
        lock.unlock()

        for metric in metrics(for: record) {
            observer(metric)
        }
    }

    /// Which metrics this write transaction should emit. Main-thread writes longer than a frame: any write on the main thread makes the UI wait with it;
    /// long writes ignore threads: while one holds the write lock, any other write can only queue.
    func metrics(for record: Record) -> [Metric] {
        let ms = record.duration * 1000
        var result: [Metric] = []
        if record.isMainThread, record.duration >= Self.mainThreadWriteThreshold {
            result.append(Metric(name: Self.mainThreadWriteMetric, valueMs: ms, label: record.label))
        }
        if record.duration >= Self.longWriteThreshold {
            result.append(Metric(name: Self.longWriteMetric, valueMs: ms, label: record.label))
        }
        return result
    }

    func withLabel<T>(
        _ label: DatabaseWriteLabel,
        connection: ObjectIdentifier,
        insideTransaction: Bool,
        now: Date = Date(),
        _ body: () throws -> T
    ) rethrows -> T {
        let isHeavy = DatabaseWriteLabel.heavy.contains(label)
        var token: UInt64?
        lock.lock()
        if var transaction = open[connection] {
            if transaction.label == nil {
                transaction.label = label.rawValue
                open[connection] = transaction
            }
        } else if insideTransaction {
            // No BEGIN record (in DEBUG the trace slot is taken by the write guard): use the labeling moment as the start.
            open[connection] = OpenTransaction(start: now, isMainThread: Thread.isMainThread, label: label.rawValue)
        }
        if isHeavy {
            nextInflightToken &+= 1
            token = nextInflightToken
            inflight[nextInflightToken] = Inflight(label: label.rawValue, start: now, isMainThread: Thread.isMainThread)
        }
        lock.unlock()

        guard let token else { return try body() }
        publishInflight()
        defer {
            lock.lock()
            inflight.removeValue(forKey: token)
            lock.unlock()
            publishInflight()
        }
        return try body()
    }

    private func appendLocked(_ record: Record) {
        if ring.count < capacity {
            ring.append(record)
        } else {
            ring[ringHead] = record
            ringHead = (ringHead + 1) % capacity
        }
    }

    private func publishInflight() {
        publishLock.lock()
        defer { publishLock.unlock() }
        lock.lock()
        let observer = inflightObserver
        let entries = inflight.sorted { $0.key < $1.key }.map(\.value)
        lock.unlock()
        observer?(entries)
    }

    // MARK: - Reading

    /// Recent long write transactions (oldest → newest), plus write transactions still in progress now (their end is recorded as `now`).
    func snapshot(now: Date = Date()) -> [Record] {
        lock.lock()
        defer { lock.unlock() }
        let ordered = Array(ring[ringHead...]) + Array(ring[..<ringHead])
        let running = open.values
            .filter { now.timeIntervalSince($0.start) < staleOpenTransactionAge }
            .map { transaction in
                Record(
                    label: transaction.label ?? DatabaseWriteLabel.unlabeled.rawValue,
                    start: transaction.start,
                    end: now,
                    isMainThread: transaction.isMainThread
                )
            }
            .sorted { $0.start < $1.start }
        return ordered + running
    }

    func inflightSnapshot() -> [Inflight] {
        lock.lock()
        defer { lock.unlock() }
        return inflight.sorted { $0.key < $1.key }.map(\.value)
    }

    /// Cumulative count of labeled write transactions that ended (regardless of duration). Tests use it to confirm a production write path really got its label.
    func labeledTransactionCount(_ label: DatabaseWriteLabel) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return labeledTransactionCounts[label.rawValue] ?? 0
    }

    /// Production exit: metric names and tag keys come from the fixture `metrics` and are emitted through the facade (Sentry in the official build, local logging in the community build).
    static let relayToObservability: @Sendable (Metric) -> Void = { metric in
        ObservabilityRelay.distribution(
            metric.name,
            value: metric.valueMs,
            unit: .millisecond,
            tags: ["db.write_label": metric.label]
        )
    }
}
