import Foundation
import GRDB
import OriveoProviderKit

/// Context Ledger persistence: the ρ calibration per (transport instance, model), and the context manifest of each request.
/// Local diagnostic data only: not included in backups. Manifests are removed with their conversation (ON DELETE CASCADE), and only the newest 50 by createdAt are kept per conversation.
final class ContextLedgerStore: @unchecked Sendable {
    nonisolated static let rhoTable = "context_rho_calibration"
    nonisolated static let manifestTable = "context_manifest"

    private let dbPool: DatabasePool

    nonisolated init(dbPool: DatabasePool) {
        self.dbPool = dbPool
    }

    /// Creates the tables (`v34_context_stop_reason_ledger`).
    nonisolated static func createTables(in db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE \(rhoTable) (
                transportInstanceId TEXT NOT NULL,
                modelId TEXT NOT NULL,
                n INTEGER NOT NULL,
                rho REAL NOT NULL,
                seeds TEXT NOT NULL,
                PRIMARY KEY (transportInstanceId, modelId)
            )
            """)
        try db.execute(sql: """
            CREATE TABLE \(manifestTable) (
                conversationId TEXT NOT NULL REFERENCES conversation(id) ON DELETE CASCADE,
                requestId TEXT NOT NULL,
                createdAt INTEGER NOT NULL,
                json TEXT NOT NULL
            )
            """)
        try db.execute(sql: """
            CREATE INDEX idx_context_manifest_conversation_created
            ON \(manifestTable)(conversationId, createdAt)
            """)
    }

    /// The Ledger of the partition the conversation lives in; nil when the database cannot be opened (the Ledger is only diagnostic data, so callers send as usual).
    nonisolated static func forPartition(_ uid: String) -> ContextLedgerStore? {
        #if DEBUG
        if let pool = shotsPool { return ContextLedgerStore(dbPool: pool) }
        #endif
        return (try? DatabaseManager.shared.openIfNeeded(for: uid)).map { ContextLedgerStore(dbPool: $0) }
    }

    #if DEBUG
    /// Screenshots only: an isolated partition for the context pages (a standalone database in a temp directory, see ContextShots); when set, the real partition database is not opened.
    nonisolated(unsafe) static var shotsPool: DatabasePool?
    #endif

    /// The ρHi of this (transport instance, model) in the partition database; falls back to the default calibration (rho0) when the database is unreadable or has no record.
    /// Reads and writes the same partition (the one the conversation lives in), so a written-back ρ is visible to the next assembly immediately.
    /// The caller obtains the database through `ChatManager.contextLedgerResolver`, so reads and writes share one source; pass nil to use the default calibration.
    nonisolated static func currentRhoHi(for key: RhoCalibrationKey, in ledger: ContextLedgerStore?) -> Double {
        guard let table = try? ledger?.loadRhoTable() else {
            return RhoCalibration().rhoHi
        }
        return table.calibration(for: key).rhoHi
    }

    /// ρ sample from a successful finish: read this calibration, record the sample, write it back.
    nonisolated func recordRhoSample(_ key: RhoCalibrationKey, observedInput: Int, textBytes: Int) throws {
        let current = try loadRhoTable().calibration(for: key)
        let next = current.recordingSample(observedInput: observedInput, mediaTokens: 0, textBytes: textBytes)
        guard next != current else { return }
        try saveRho(key, next)
    }

    /// The prediction did not exceed U but an overflow was reported: raise ρ and write it back.
    nonisolated func recordRhoOverflowMiss(_ key: RhoCalibrationKey) throws {
        try saveRho(key, try loadRhoTable().calibration(for: key).recordingOverflowMiss())
    }

    nonisolated func loadRhoTable() throws -> RhoCalibrationTable {
        try dbPool.read { db in
            let rows = try Row.fetchAll(
                db, sql: "SELECT transportInstanceId, modelId, n, rho, seeds FROM \(Self.rhoTable)"
            )
            var entries: [RhoCalibrationKey: RhoCalibration] = [:]
            for row in rows {
                let key = RhoCalibrationKey(transportInstanceId: row["transportInstanceId"], modelId: row["modelId"])
                let seedsJSON: String = row["seeds"]
                // Corrupt seeds only make this one row fall back to the default calibration; they do not block reading the whole table.
                guard let seeds = try? JSONDecoder().decode([Double].self, from: Data(seedsJSON.utf8)) else { continue }
                entries[key] = RhoCalibration(n: row["n"], rho: row["rho"], seeds: seeds)
            }
            return RhoCalibrationTable(entries: entries)
        }
    }

    nonisolated func saveRho(_ key: RhoCalibrationKey, _ calibration: RhoCalibration) throws {
        let seeds = String(decoding: try JSONEncoder().encode(calibration.seeds), as: UTF8.self)
        try dbPool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO \(Self.rhoTable) (transportInstanceId, modelId, n, rho, seeds)
                    VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(transportInstanceId, modelId) DO UPDATE SET
                        n = excluded.n, rho = excluded.rho, seeds = excluded.seeds
                    """,
                arguments: [key.transportInstanceId, key.modelId, calibration.n, calibration.rho, seeds]
            )
        }
    }

    nonisolated func appendManifest(_ manifest: ContextManifest) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = String(decoding: try encoder.encode(manifest), as: UTF8.self)
        try dbPool.write { db in
            try db.execute(
                sql: "INSERT INTO \(Self.manifestTable) (conversationId, requestId, createdAt, json) VALUES (?, ?, ?, ?)",
                arguments: [manifest.conversationId, manifest.requestId, manifest.createdAt, json]
            )
            try db.execute(
                sql: """
                    DELETE FROM \(Self.manifestTable)
                    WHERE conversationId = ? AND rowid NOT IN (
                        SELECT rowid FROM \(Self.manifestTable)
                        WHERE conversationId = ?
                        ORDER BY createdAt DESC, rowid DESC
                        LIMIT ?
                    )
                    """,
                arguments: [
                    manifest.conversationId, manifest.conversationId, ContextManifestLog.capacityPerConversation,
                ]
            )
        }
    }

    /// Oldest to newest, consistent with `ContextManifestLog.manifests(conversationId:)`.
    nonisolated func manifests(conversationId: String) throws -> [ContextManifest] {
        let payloads = try dbPool.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT json FROM \(Self.manifestTable) WHERE conversationId = ? ORDER BY createdAt ASC, rowid ASC",
                arguments: [conversationId]
            )
        }
        let decoder = JSONDecoder()
        return payloads.compactMap { try? decoder.decode(ContextManifest.self, from: Data($0.utf8)) }
    }
}
