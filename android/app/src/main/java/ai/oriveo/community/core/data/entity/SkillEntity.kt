package ai.oriveo.community.core.data.entity

import androidx.room.Entity
import androidx.room.Index
import androidx.room.PrimaryKey


@Entity(
    tableName = "skills",
    indices = [Index(value = ["accountId", "source"])],
)
data class SkillEntity(
    @PrimaryKey val id: String,
    val accountId: String,
    val key: String?,
    val name: String,
    val description: String,
    val icon: String,
    val color: String,
    val systemPrompt: String,
    val suggestedProviderId: String?,
    val suggestedModelId: String?,
    val modelCapabilityHint: String,
    val temperature: Double?,
    val reasoningLevel: String?,
    val webSearchEnabled: Boolean?,
    val starterMessagesJson: String,
    val knowledgeFilesJson: String,
    val knowledgeBaseJson: String?,
    val useMemory: Boolean,
    val isPinned: Boolean,
    val pinOrder: Int,
    val source: String,
    val forkedFromId: String?,
    val category: String?,
    val sortOrder: Int,
    val usageCount: Int,
    val lastUsedAt: String?,
    val createdAt: String,
    val updatedAt: String,
)
