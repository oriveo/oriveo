package ai.oriveo.community.core.data.database

import androidx.room.Database
import androidx.room.RoomDatabase
import ai.oriveo.community.core.data.dao.ConversationDao
import ai.oriveo.community.core.data.dao.FolderDao
import ai.oriveo.community.core.data.dao.MessageDao
import ai.oriveo.community.core.data.dao.MetadataCacheDao
import ai.oriveo.community.core.data.dao.NoteDao
import ai.oriveo.community.core.data.dao.NoteFolderDao
import ai.oriveo.community.core.data.dao.PreferenceDao
import ai.oriveo.community.core.data.dao.ProviderDao
import ai.oriveo.community.core.data.dao.SkillDao
import ai.oriveo.community.core.data.entity.ConversationEntity
import ai.oriveo.community.core.data.entity.FolderEntity
import ai.oriveo.community.core.data.entity.MessageEntity
import ai.oriveo.community.core.data.entity.MetadataCacheEntity
import ai.oriveo.community.core.data.entity.NoteEntity
import ai.oriveo.community.core.data.entity.NoteFolderEntity
import ai.oriveo.community.core.data.entity.NoteFtsEntity
import ai.oriveo.community.core.data.entity.PreferenceEntity
import ai.oriveo.community.core.data.entity.ProviderEntity
import ai.oriveo.community.core.data.entity.SkillEntity

/**
 * Partition every row belongs to.
 *
 * Everything this app stores lives on the device in a single partition. The column exists so a
 * future profile feature can be added without rewriting every query and index, and so the
 * composite primary keys stay stable if it ever is.
 */
const val LOCAL_PARTITION_ID = "local"

/**
 * The on-device store: conversations, messages, notes, folders, skills, providers, preferences,
 * and the cached model catalog.
 *
 * Schemas are exported to `app/schemas` and checked in, so a change to an entity shows up as a
 * reviewable diff rather than a surprise at runtime.
 */
@Database(
    entities = [
        ProviderEntity::class,
        ConversationEntity::class,
        MessageEntity::class,
        PreferenceEntity::class,
        FolderEntity::class,
        SkillEntity::class,
        MetadataCacheEntity::class,
        NoteEntity::class,
        NoteFolderEntity::class,
        NoteFtsEntity::class,
    ],
    version = 1,
    exportSchema = true,
)
abstract class OriveoDatabase : RoomDatabase() {
    abstract fun providerDao(): ProviderDao
    abstract fun conversationDao(): ConversationDao
    abstract fun messageDao(): MessageDao
    abstract fun preferenceDao(): PreferenceDao
    abstract fun folderDao(): FolderDao
    abstract fun skillDao(): SkillDao
    abstract fun metadataCacheDao(): MetadataCacheDao
    abstract fun noteDao(): NoteDao
    abstract fun noteFolderDao(): NoteFolderDao

    companion object {
        const val DATABASE_NAME = "oriveo.db"
    }
}
