import Foundation
import GRDB

enum DatabaseSchema {
    static let fileName = "oriveo.sqlite"

    nonisolated static func makeConfiguration() -> Configuration {
        var configuration = Configuration()
        // GRDB defaults to `.immediate`, so BEGIN IMMEDIATE fails at the first SQLITE_BUSY.
        // A short lock is normal in WAL: another connection, or iOS snapshotting the
        // sqlite/WAL files while the app is inactive. Five seconds matches the other
        // GRDB stores. If the wait still ends in BUSY/LOCKED/INTERRUPT, SQLitePersistRetry
        // retries the conversation persist so a just-finished reply is not dropped.
        configuration.busyMode = .timeout(5)
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
        }
        return configuration
    }

    nonisolated static func makeMigrator(attachmentFileStore: AttachmentFileStore) -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1_init") { db in
            try createConversationTable(in: db)
            try createMessageTable(in: db)
            try createAttachmentTable(in: db)
            try createSearchIndexTable(in: db)
            try createMetadataCacheTable(in: db)
            try createMergeStateTable(in: db)
        }
        migrator.registerMigration("v2_add_citations") { db in
            try db.execute(sql: "ALTER TABLE message ADD COLUMN citations TEXT")
        }
        migrator.registerMigration("v3_add_reasoning_text") { db in
            try db.execute(sql: "ALTER TABLE message ADD COLUMN reasoningText TEXT")
            try db.execute(sql: "ALTER TABLE message ADD COLUMN reasoningDurationMs INTEGER")
        }
        migrator.registerMigration("v4_add_cost_breakdown") { db in
            try db.execute(sql: "ALTER TABLE message ADD COLUMN cachedInputTokens INTEGER")
            try db.execute(sql: "ALTER TABLE message ADD COLUMN cacheCreation5mTokens INTEGER")
            try db.execute(sql: "ALTER TABLE message ADD COLUMN cacheCreation1hTokens INTEGER")
            try db.execute(sql: "ALTER TABLE message ADD COLUMN costSource TEXT")
        }
        migrator.registerMigration("v5_add_attachment_extraction_meta") { db in
            try db.execute(sql: "ALTER TABLE attachment ADD COLUMN extractedTotalLines INTEGER")
            try db.execute(sql: "ALTER TABLE attachment ADD COLUMN extractedTruncated INTEGER")
            try db.execute(sql: "ALTER TABLE attachment ADD COLUMN extractedSizeBytes INTEGER")
            try db.execute(sql: "ALTER TABLE attachment ADD COLUMN extractionErrorCode TEXT")
            try db.execute(sql: "ALTER TABLE attachment ADD COLUMN originalBase64Data TEXT")
        }
        migrator.registerMigration("v6_search_index_trigram") { db in
            try db.execute(sql: "DROP TABLE IF EXISTS search_index")
            try db.execute(sql: """
                CREATE VIRTUAL TABLE search_index USING fts5(
                    conversationID,
                    title,
                    messageText,
                    tokenize='trigram'
                )
                """)
            try db.execute(sql: """
                INSERT INTO search_index(conversationID, title, messageText)
                SELECT c.id, c.title,
                       COALESCE((SELECT GROUP_CONCAT(m.text, ' ') FROM message m WHERE m.conversationID = c.id), '')
                FROM conversation c
                """)
        }
        migrator.registerMigration("v7_add_notes") { db in
            try createNoteFolderTable(in: db)
            try createNoteTable(in: db)
            try createNoteSearchIndexTable(in: db)
        }
        migrator.registerMigration("v8_add_pinned_notes") { db in
            try db.execute(sql: "ALTER TABLE conversation ADD COLUMN pinnedNoteIds TEXT")
        }
        migrator.registerMigration("v9_offload_original_base64_to_file") { db in
            try db.execute(sql: "ALTER TABLE attachment ADD COLUMN originalFileID TEXT")

            let ids = try String.fetchAll(
                db,
                sql: "SELECT id FROM attachment WHERE originalBase64Data IS NOT NULL AND originalBase64Data != ''"
            )
            for id in ids {
                guard let base64 = try String.fetchOne(
                    db,
                    sql: "SELECT originalBase64Data FROM attachment WHERE id = ?",
                    arguments: [id]
                ), !base64.isEmpty else { continue }

                guard let fileID = try? attachmentFileStore.saveBase64(base64, for: "\(id)-orig") else { continue }
                try db.execute(
                    sql: "UPDATE attachment SET originalFileID = ?, originalBase64Data = NULL WHERE id = ?",
                    arguments: [fileID, id]
                )
            }
        }
        migrator.registerMigration("v12_add_pending_conversation_deletion") { db in
            try db.execute(sql: """
                CREATE TABLE pending_conversation_deletion (
                    conversationID TEXT PRIMARY KEY,
                    enqueuedAt REAL NOT NULL
                )
                """)
        }
        migrator.registerMigration("v13_add_pending_provider_deletion") { db in
            try db.execute(sql: """
                CREATE TABLE pending_provider_deletion (
                    providerID TEXT PRIMARY KEY,
                    enqueuedAt REAL NOT NULL
                )
                """)
        }
        migrator.registerMigration("v14_add_provider_deletion_operation_id") { db in
            try db.execute(sql: "ALTER TABLE pending_provider_deletion ADD COLUMN operationID TEXT")
            let providerIDs = try String.fetchAll(
                db,
                sql: "SELECT providerID FROM pending_provider_deletion"
            )
            for providerID in providerIDs {
                try db.execute(
                    sql: "UPDATE pending_provider_deletion SET operationID = ? WHERE providerID = ?",
                    arguments: [UUID().uuidString, providerID]
                )
            }
        }
        migrator.registerMigration("v15_add_remote_message_count") { db in
            try db.execute(sql: "ALTER TABLE conversation ADD COLUMN remoteMessageCount INTEGER NOT NULL DEFAULT 0")
        }
        migrator.registerMigration("v19_add_quote_context") { db in
            try db.execute(sql: "ALTER TABLE message ADD COLUMN quoteContext TEXT")
        }
        migrator.registerMigration("v20_add_message_token_usage") { db in
            try db.execute(sql: "ALTER TABLE message ADD COLUMN inputTokens INTEGER")
            try db.execute(sql: "ALTER TABLE message ADD COLUMN outputTokens INTEGER")
            try db.execute(sql: "ALTER TABLE message ADD COLUMN cacheCreationInputTokens INTEGER")
        }
        migrator.registerMigration("v21_add_message_recipe_continuation") { db in
            try db.execute(sql: """
                CREATE TABLE message_recipe_continuation (
                    messageID TEXT PRIMARY KEY NOT NULL REFERENCES message(id) ON DELETE CASCADE,
                    kind TEXT NOT NULL,
                    stateJSON TEXT NOT NULL,
                    interrupted INTEGER NOT NULL DEFAULT 0,
                    updatedAt REAL NOT NULL
                )
                """)
        }
        migrator.registerMigration("v22_add_recipe_continuation_launch_token") { db in
            // Existing sidecars are deliberately invalid after this migration. The token makes
            // restart behavior fail-safe even if a previous process was killed mid tool-loop.
            try db.execute(sql: "ALTER TABLE message_recipe_continuation ADD COLUMN launchToken TEXT NOT NULL DEFAULT ''")
        }
        migrator.registerMigration("v23_move_recipe_continuation_out_of_primary_database") { db in
            // Opaque continuation blocks may contain encrypted reasoning/tool output. They must
            // never share the backed-up/syncable conversation SQLite file. Do not migrate old
            // plaintext: launch-token policy already requires a clean restart across processes.
            try db.execute(sql: "DROP TABLE IF EXISTS message_recipe_continuation")
        }
        migrator.registerMigration("v24_add_message_capability_execution") { db in
            // stores only owner -> terminal truth (requested/observed/unconfirmed/rejected/recovered).
            // It intentionally excludes raw Provider diagnostics and custom request fragments.
            try db.execute(sql: "ALTER TABLE message ADD COLUMN capabilityExecution TEXT")
        }
        migrator.registerMigration("v25_add_message_unhandled_tool_calls") { db in
            try db.execute(sql: "ALTER TABLE message ADD COLUMN unhandledToolCalls TEXT")
        }
        migrator.registerMigration("v26_add_connection_tool_call_memory") { db in
            try db.execute(sql: """
                CREATE TABLE connection_tool_call_memory (
                    connectionId TEXT NOT NULL,
                    modelId TEXT NOT NULL,
                    toolCall INTEGER NOT NULL,
                    observedAt TEXT NOT NULL,
                    reason TEXT NOT NULL,
                    PRIMARY KEY (connectionId, modelId)
                )
                """)
        }
        return migrator
    }


    nonisolated private static func createConversationTable(in db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE conversation (
                id TEXT PRIMARY KEY NOT NULL,
                title TEXT NOT NULL DEFAULT '',
                hasCustomTitle INTEGER NOT NULL DEFAULT 0,
                providerID TEXT NOT NULL,
                providerKind TEXT NOT NULL,
                modelID TEXT NOT NULL,
                previewText TEXT NOT NULL DEFAULT '',
                messageCount INTEGER NOT NULL DEFAULT 0,
                estimatedCost REAL NOT NULL DEFAULT 0,
                isDraft INTEGER NOT NULL DEFAULT 0,
                draftText TEXT NOT NULL DEFAULT '',
                createdAt REAL NOT NULL,
                updatedAt REAL NOT NULL,
                folderID TEXT,
                useMemory INTEGER NOT NULL DEFAULT 1,
                skillId TEXT,
                metadataUpdatedAt REAL,
                messagesHydratedAt REAL,
                messagesStale INTEGER NOT NULL DEFAULT 0,
                deletedAt REAL,
                isConflictCopy INTEGER NOT NULL DEFAULT 0,
                originalConversationId TEXT
            )
            """)
        try db.execute(sql: "CREATE INDEX idx_conv_updatedAt ON conversation(updatedAt DESC)")
        try db.execute(sql: "CREATE INDEX idx_conv_folderID ON conversation(folderID)")
        try db.execute(sql: "CREATE INDEX idx_conv_isConflictCopy ON conversation(isConflictCopy)")
        try db.execute(sql: "CREATE INDEX idx_conv_deletedAt ON conversation(deletedAt)")
    }

    nonisolated private static func createMessageTable(in db: Database) throws {
        // cachedInputTokens / cacheCreation5mTokens / cacheCreation1hTokens / costSource
        try db.execute(sql: """
            CREATE TABLE message (
                id TEXT PRIMARY KEY NOT NULL,
                conversationID TEXT NOT NULL REFERENCES conversation(id) ON DELETE CASCADE,
                role TEXT NOT NULL,
                text TEXT NOT NULL DEFAULT '',
                providerID TEXT,
                providerKind TEXT NOT NULL,
                providerName TEXT NOT NULL,
                modelID TEXT,
                modelName TEXT NOT NULL,
                servedModelID TEXT,
                estimatedCost REAL NOT NULL DEFAULT 0,
                state TEXT NOT NULL,
                errorTitle TEXT,
                errorDetail TEXT,
                createdAt REAL,
                sortOrder INTEGER NOT NULL DEFAULT 0
            )
            """)
        try db.execute(sql: "CREATE INDEX idx_msg_convID_createdAt ON message(conversationID, createdAt, id)")
        try db.execute(sql: "CREATE INDEX idx_msg_convID_sortOrder ON message(conversationID, sortOrder)")
    }

    nonisolated private static func createAttachmentTable(in db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE attachment (
                id TEXT PRIMARY KEY NOT NULL,
                messageID TEXT NOT NULL REFERENCES message(id) ON DELETE CASCADE,
                kind TEXT NOT NULL,
                fileName TEXT NOT NULL,
                mimeType TEXT NOT NULL,
                localFileID TEXT,
                localImageID TEXT,
                thumbnailBase64 TEXT,
                sortOrder INTEGER NOT NULL DEFAULT 0
            )
            """)
        try db.execute(sql: "CREATE INDEX idx_att_msgID ON attachment(messageID, sortOrder)")
    }

    nonisolated private static func createSearchIndexTable(in db: Database) throws {
        try db.execute(sql: """
            CREATE VIRTUAL TABLE search_index USING fts5(
                conversationID,
                title,
                messageText,
                content='',
                tokenize='unicode61'
            )
            """)
    }

    nonisolated private static func createMetadataCacheTable(in db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE metadata_cache (
                id INTEGER PRIMARY KEY CHECK (id = 1),
                payload TEXT NOT NULL,
                version INTEGER NOT NULL,
                contractVersion INTEGER NOT NULL,
                etag TEXT,
                updatedAt REAL NOT NULL
            )
            """)
    }

    nonisolated private static func createMergeStateTable(in db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE merge_state (
                uid TEXT PRIMARY KEY NOT NULL,
                sessionId TEXT,
                phase TEXT NOT NULL,
                strategy TEXT,
                backupRef TEXT,
                lastProcessedConversationId TEXT,
                syncState TEXT,
                updatedAt INTEGER NOT NULL
            )
            """)
        try db.execute(sql: "CREATE INDEX idx_merge_state_phase ON merge_state(phase)")
    }


    nonisolated private static func createNoteTable(in db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE note (
                id TEXT PRIMARY KEY NOT NULL,
                title TEXT NOT NULL DEFAULT '',
                titleSource TEXT NOT NULL,
                body TEXT NOT NULL DEFAULT '',
                bodySnapshot TEXT,
                userNote TEXT,
                tags TEXT NOT NULL DEFAULT '[]',
                noteFolderID TEXT,
                sourceConversationId TEXT,
                sourceMessageId TEXT,
                sourceModelID TEXT,
                sourceModelName TEXT,
                sourceProviderKind TEXT,
                sourceProviderName TEXT,
                sourcePrompt TEXT,
                captureKind TEXT NOT NULL,
                provenance TEXT,
                isPinned INTEGER NOT NULL DEFAULT 0,
                createdAt REAL NOT NULL,
                updatedAt REAL NOT NULL,
                deletedAt REAL
            )
            """)
        try db.execute(sql: "CREATE INDEX idx_note_updatedAt ON note(updatedAt DESC)")
        try db.execute(sql: "CREATE INDEX idx_note_folderID ON note(noteFolderID)")
        try db.execute(sql: "CREATE INDEX idx_note_deletedAt ON note(deletedAt)")
        try db.execute(sql: "CREATE INDEX idx_note_isPinned ON note(isPinned)")
        try db.execute(sql: "CREATE INDEX idx_note_sourceConversationId ON note(sourceConversationId)")
    }

    nonisolated private static func createNoteFolderTable(in db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE note_folder (
                id TEXT PRIMARY KEY NOT NULL,
                name TEXT NOT NULL,
                sortOrder INTEGER NOT NULL,
                colorTag TEXT,
                createdAt REAL NOT NULL,
                updatedAt REAL NOT NULL,
                deletedAt REAL
            )
            """)
        try db.execute(sql: "CREATE INDEX idx_note_folder_sortOrder ON note_folder(sortOrder)")
        try db.execute(sql: "CREATE INDEX idx_note_folder_deletedAt ON note_folder(deletedAt)")
    }

    nonisolated private static func createNoteSearchIndexTable(in db: Database) throws {
        try db.execute(sql: """
            CREATE VIRTUAL TABLE note_search_index USING fts5(
                noteID,
                title,
                body,
                userNote,
                tagsText,
                tokenize='trigram'
            )
            """)
    }
}

/// Application-level retry for SQLITE_BUSY / LOCKED / INTERRUPT on conversation persist.
///
/// `busyMode = .timeout(5)` only covers the current BEGIN IMMEDIATE wait.
/// After that timeout, or after the connection is interrupted, a failed write
/// would drop the update: memory already has the new message, GRDB does not,
/// and killing the process loses the reply. Retry in place on the serial
/// persist queue so an older snapshot cannot overtake a newer write already queued.
enum SQLitePersistRetry {
    static let maxAttempts = 3

    static func isRetryable(_ error: Error) -> Bool {
        guard let dbError = error as? DatabaseError else { return false }
        switch dbError.resultCode {
        case .SQLITE_BUSY, .SQLITE_LOCKED, .SQLITE_INTERRUPT, .SQLITE_ABORT:
            return true
        default:
            return false
        }
    }

    static func delay(beforeAttempt attempt: Int) -> TimeInterval {
        attempt <= 2 ? 0.05 : 0.15
    }

    static func run(
        sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
        _ write: () throws -> Void
    ) throws {
        var lastError: Error?
        for attempt in 1...maxAttempts {
            do {
                try write()
                return
            } catch {
                lastError = error
                guard attempt < maxAttempts, isRetryable(error) else { throw error }
                sleep(delay(beforeAttempt: attempt + 1))
            }
        }
        throw lastError!
    }
}
