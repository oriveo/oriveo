package ai.oriveo.community.di

import androidx.room.Room
import androidx.room.RoomDatabase
import androidx.room.withTransaction
import androidx.sqlite.db.SupportSQLiteDatabase
import ai.oriveo.community.core.data.database.ConversationSearchSchema
import ai.oriveo.community.core.data.database.DatabaseHealthProbe
import ai.oriveo.community.core.data.database.OriveoDatabase
import ai.oriveo.community.core.data.database.MessageContinuationDatabase
import ai.oriveo.community.core.data.search.ConversationSearchIndexer
import java.util.concurrent.Executors
import org.koin.android.ext.koin.androidContext
import org.koin.dsl.module

val databaseModule = module {
    single {
        Room.databaseBuilder(
            androidContext(),
            OriveoDatabase::class.java,
            OriveoDatabase.DATABASE_NAME,
        )
            // Write-ahead logging lets a read run while a stream is still writing tokens, which
            // is what keeps the conversation list responsive mid-generation.
            .setJournalMode(RoomDatabase.JournalMode.WRITE_AHEAD_LOGGING)
            // A small read pool plus a single writer: SQLite serialises writes anyway, and a
            // second writer thread only adds lock contention.
            .setQueryExecutor(Executors.newFixedThreadPool(4))
            .setTransactionExecutor(Executors.newSingleThreadExecutor())
            // Every version step lives in OriveoDatabase.allMigrations (v1 to v2 FTS4 search, v2 to v3 MCP tables,
            // v3 to v4 relay columns, v4 to v5 context and memory, v5 to v6 non-USD cost columns).
            .addMigrations(*OriveoDatabase.allMigrations())
            .addCallback(
                object : RoomDatabase.Callback() {
                    override fun onOpen(db: SupportSQLiteDatabase) {
                        super.onOpen(db)
                        // The migration only covers databases that were upgraded; a fresh install
                        // goes through Room's createAllTables and runs no migration at all. Every
                        // statement is CREATE TRIGGER IF NOT EXISTS, so repeating it costs nothing.
                        ConversationSearchSchema.installTriggers(db)
                    }
                },
            )
            .fallbackToDestructiveMigrationOnDowngrade(true)
            .build()
    }

    single {
        Room.databaseBuilder(
            androidContext(), MessageContinuationDatabase::class.java,
            MessageContinuationDatabase.DATABASE_NAME,
        ).setJournalMode(RoomDatabase.JournalMode.WRITE_AHEAD_LOGGING).build()
    }

    // The probe has to be able to open the database itself, so it takes the open call as a
    // lambda rather than the database instance: resolving the instance here would perform the
    // very open it is meant to guard.
    single {
        val scope = this
        val appContext = androidContext()
        DatabaseHealthProbe(
            openAndQuery = {
                scope.get<OriveoDatabase>().openHelper.writableDatabase
                    .query("SELECT 1")
                    .use { cursor -> cursor.moveToFirst() }
            },
            usableSpaceBytes = { appContext.filesDir.usableSpace },
        )
    }

    single { get<OriveoDatabase>().providerDao() }
    single { get<OriveoDatabase>().conversationDao() }
    single { get<OriveoDatabase>().conversationSearchDao() }
    single { ConversationSearchIndexer(dao = get()) }
    single { get<OriveoDatabase>().messageDao() }
    single { get<OriveoDatabase>().preferenceDao() }
    single { get<OriveoDatabase>().folderDao() }
    single { get<OriveoDatabase>().skillDao() }
    single { get<OriveoDatabase>().metadataCacheDao() }
    single { get<OriveoDatabase>().noteDao() }
    single { get<OriveoDatabase>().noteFolderDao() }
    single { get<OriveoDatabase>().mcpServerDao() }
    single { get<OriveoDatabase>().contextLedgerDao() }
    single { get<OriveoDatabase>().contextCheckpointDao() }
    single { ai.oriveo.community.core.data.repository.ContextCompactionStore(get()) }
    single { get<OriveoDatabase>().memoryItemDao() }
    single { get<OriveoDatabase>().memoryCandidateDao() }
    single {
        val db = get<OriveoDatabase>()
        ai.oriveo.community.core.memory.MemoryItemRepository(
            dao = get(),
            preferenceDao = get(),
            preferences = get(),
            runInTransaction = { block -> db.withTransaction { block() } },
        )
    }
    single {
        ai.oriveo.community.core.memory.MemoryCandidateRepository(
            dao = get(),
            items = get(),
            preferences = get(),
        )
    }
    single { get<MessageContinuationDatabase>().dao() }
}
