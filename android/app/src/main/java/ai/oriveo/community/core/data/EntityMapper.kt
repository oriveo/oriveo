package ai.oriveo.community.core.data

import ai.oriveo.community.core.data.entity.ConversationEntity
import ai.oriveo.community.core.data.entity.FolderEntity
import ai.oriveo.community.core.data.entity.MessageEntity
import ai.oriveo.community.core.data.entity.NoteEntity
import ai.oriveo.community.core.data.entity.NoteFolderEntity
import ai.oriveo.community.core.data.entity.ProviderEntity
import ai.oriveo.community.core.data.entity.SkillEntity
import ai.oriveo.community.core.data.mapper.ConversationMapper
import ai.oriveo.community.core.data.mapper.FolderMapper
import ai.oriveo.community.core.data.mapper.MessageMapper
import ai.oriveo.community.core.data.mapper.NoteFolderMapper
import ai.oriveo.community.core.data.mapper.NoteMapper
import ai.oriveo.community.core.data.mapper.ProviderMapper
import ai.oriveo.community.core.data.mapper.SkillMapper
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.Conversation
import ai.oriveo.community.core.model.Folder
import ai.oriveo.community.core.model.Note
import ai.oriveo.community.core.model.NoteFolder
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.Skill

object EntityMapper {

    // ── Provider ────────────────────────────────────────────────

    fun ProviderEntity.toDomain(apiKey: String = ""): Provider =
        ProviderMapper.run { this@toDomain.toDomain(apiKey) }

    fun Provider.toEntity(accountId: String = "guest"): ProviderEntity =
        ProviderMapper.run { this@toEntity.toEntity(accountId) }

    // ── Folder ────────────────────────────────────────────────

    fun FolderEntity.toDomain(): Folder =
        FolderMapper.run { this@toDomain.toDomain() }

    fun Folder.toEntity(accountId: String = "guest"): FolderEntity =
        FolderMapper.run { this@toEntity.toEntity(accountId) }

    // ── Conversation ────────────────────────────────────────────

    fun ConversationEntity.toDomain(
        messages: List<ChatMessage> = emptyList(),
        messageCount: Int = messages.size,
    ): Conversation =
        ConversationMapper.run { this@toDomain.toDomain(messages, messageCount) }

    fun Conversation.toEntity(accountId: String = "guest"): ConversationEntity =
        ConversationMapper.run { this@toEntity.toEntity(accountId) }

    // ── Skill ──────────────────────────────────────────────────

    fun SkillEntity.toDomain(): Skill =
        SkillMapper.run { this@toDomain.toDomain() }

    fun Skill.toEntity(accountId: String = "guest"): SkillEntity =
        SkillMapper.run { this@toEntity.toEntity(accountId) }

    // ── Message ─────────────────────────────────────────────────

    fun MessageEntity.toDomain(): ChatMessage =
        MessageMapper.run { this@toDomain.toDomain() }

    fun ChatMessage.toEntity(accountId: String, conversationId: String, sortOrder: Int): MessageEntity =
        MessageMapper.run { this@toEntity.toEntity(accountId, conversationId, sortOrder) }

    // ── Note ────────────────────────────────────────────────────

    fun NoteEntity.toDomain(): Note =
        NoteMapper.run { this@toDomain.toDomain() }

    fun Note.toEntity(accountId: String = "guest"): NoteEntity =
        NoteMapper.run { this@toEntity.toEntity(accountId) }

    // ── NoteFolder ──────────────────────────────────────────────

    fun NoteFolderEntity.toDomain(): NoteFolder =
        NoteFolderMapper.run { this@toDomain.toDomain() }

    fun NoteFolder.toEntity(accountId: String = "guest"): NoteFolderEntity =
        NoteFolderMapper.run { this@toEntity.toEntity(accountId) }
}
