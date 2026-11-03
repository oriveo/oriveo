import Foundation
import GRDB

/// Local tables for studio works (studio_data_model.v1 `localTables`). Schema only: no rows,
/// no read / write API yet. Array / object columns hold JSON TEXT, booleans are INTEGER,
/// timestamps are INTEGER like ContextCompactionStore.
nonisolated enum StudioWorkSchema {
    static let worksTable = "studio_works"
    static let roundsTable = "studio_rounds"
    static let versionsTable = "studio_versions"
    static let roundRefsTable = "studio_round_refs"

    static func createTables(in db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE \(worksTable) (
                id TEXT NOT NULL PRIMARY KEY,
                title TEXT,
                currentVersionId TEXT,
                source TEXT NOT NULL,
                chatConversationId TEXT,
                chatMessageId TEXT,
                favorite INTEGER,
                selectedVersionIds TEXT,
                deletedVersionIds TEXT,
                createdAt INTEGER,
                updatedAt INTEGER,
                deletedAt INTEGER,
                revision INTEGER,
                baseRevision INTEGER,
                accountPartition TEXT,
                syncState TEXT
            )
            """)
        try db.execute(sql: """
            CREATE TABLE \(roundsTable) (
                id TEXT NOT NULL PRIMARY KEY,
                workId TEXT NOT NULL REFERENCES \(worksTable)(id) ON DELETE CASCADE,
                "index" INTEGER NOT NULL,
                baseVersionId TEXT,
                operation TEXT NOT NULL,
                prompt TEXT,
                composedPrompt TEXT,
                enhancedPrompt TEXT,
                presetIds TEXT,
                params TEXT,
                modelRef TEXT,
                status TEXT NOT NULL,
                errorKind TEXT,
                adjustments TEXT,
                nRequested INTEGER,
                nDelivered INTEGER,
                costEstimateUsd REAL,
                chargedUsd REAL,
                fundingSource TEXT,
                managedJobId TEXT,
                clientJobId TEXT,
                startedAt INTEGER,
                finishedAt INTEGER
            )
            """)
        try db.execute(sql: """
            CREATE TABLE \(versionsTable) (
                id TEXT NOT NULL PRIMARY KEY,
                roundId TEXT NOT NULL REFERENCES \(roundsTable)(id) ON DELETE CASCADE,
                workId TEXT NOT NULL,
                parentVersionId TEXT,
                assetId TEXT NOT NULL,
                width INTEGER,
                height INTEGER,
                mime TEXT,
                kept INTEGER,
                createdAt INTEGER
            )
            """)
        try db.execute(sql: """
            CREATE TABLE \(roundRefsTable) (
                roundId TEXT NOT NULL REFERENCES \(roundsTable)(id) ON DELETE CASCADE,
                "order" INTEGER NOT NULL,
                assetId TEXT NOT NULL,
                role TEXT NOT NULL,
                PRIMARY KEY (roundId, "order")
            )
            """)
        try db.execute(sql: """
            CREATE UNIQUE INDEX idx_studio_rounds_work_index ON \(roundsTable)(workId, "index")
            """)
        try db.execute(sql: "CREATE INDEX idx_studio_versions_work ON \(versionsTable)(workId)")
        try db.execute(sql: "CREATE INDEX idx_studio_versions_round ON \(versionsTable)(roundId)")
        try db.execute(sql: "CREATE INDEX idx_studio_versions_asset ON \(versionsTable)(assetId)")
        try db.execute(sql: "CREATE INDEX idx_studio_round_refs_asset ON \(roundRefsTable)(assetId)")
        try db.execute(sql: "CREATE INDEX idx_studio_works_updated ON \(worksTable)(updatedAt)")
    }
}
