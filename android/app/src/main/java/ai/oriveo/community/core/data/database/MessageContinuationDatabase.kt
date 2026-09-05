package ai.oriveo.community.core.data.database

import androidx.room.Database
import androidx.room.RoomDatabase
import ai.oriveo.community.core.data.dao.MessageContinuationDao
import ai.oriveo.community.core.data.entity.MessageContinuationEntity

/** Local-only opaque continuation sidecar; its exact DB files are excluded from backup/transfer. */
@Database(entities = [MessageContinuationEntity::class], version = 1, exportSchema = true)
abstract class MessageContinuationDatabase : RoomDatabase() {
    abstract fun dao(): MessageContinuationDao

    companion object { const val DATABASE_NAME = "message_continuations.db" }
}
