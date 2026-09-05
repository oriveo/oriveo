package ai.oriveo.community.di

import androidx.room.Room
import androidx.room.RoomDatabase
import ai.oriveo.community.core.data.database.DatabaseHealthProbe
import ai.oriveo.community.core.data.database.OriveoDatabase
import ai.oriveo.community.core.data.database.MessageContinuationDatabase
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
    single { get<OriveoDatabase>().messageDao() }
    single { get<OriveoDatabase>().preferenceDao() }
    single { get<OriveoDatabase>().folderDao() }
    single { get<OriveoDatabase>().skillDao() }
    single { get<OriveoDatabase>().metadataCacheDao() }
    single { get<OriveoDatabase>().noteDao() }
    single { get<OriveoDatabase>().noteFolderDao() }
    single { get<MessageContinuationDatabase>().dao() }
}
