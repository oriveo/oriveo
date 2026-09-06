package ai.oriveo.community.core.data.repository

import ai.oriveo.community.core.model.SkillKnowledgeBase
import kotlinx.serialization.Serializable

/** Everything needed to create a skill. */
@Serializable
data class CreateSkillRequest(
    val name: String,
    val description: String = "",
    val icon: String = "🤖",
    val color: String = "#6d38ff",
    val systemPrompt: String,
    val suggestedProviderId: String? = null,
    val suggestedModelId: String? = null,
    val modelCapabilityHint: String = "any",
    val temperature: Double? = null,
    val reasoningLevel: String? = null,
    val webSearchEnabled: Boolean? = null,
    val starterMessages: List<String> = emptyList(),
    val knowledgeFiles: List<CreateKnowledgeFileRequest> = emptyList(),
    val knowledgeBase: SkillKnowledgeBase? = null,
    val useMemory: Boolean = true,
)

/** A reference document attached to a skill. */
@Serializable
data class CreateKnowledgeFileRequest(
    val name: String,
    val content: String,
)

/**
 * A partial edit to a skill. Every field is nullable and null means "leave alone", so an editor
 * that only changed the name does not have to resend the whole skill.
 */
@Serializable
data class UpdateSkillRequest(
    val name: String? = null,
    val description: String? = null,
    val icon: String? = null,
    val color: String? = null,
    val systemPrompt: String? = null,
    val suggestedProviderId: String? = null,
    val suggestedModelId: String? = null,
    val modelCapabilityHint: String? = null,
    val temperature: Double? = null,
    val reasoningLevel: String? = null,
    val webSearchEnabled: Boolean? = null,
    val starterMessages: List<String>? = null,
    val knowledgeFiles: List<CreateKnowledgeFileRequest>? = null,
    val knowledgeBase: SkillKnowledgeBase? = null,
    val useMemory: Boolean? = null,
    val isPinned: Boolean? = null,
    val pinOrder: Int? = null,
    val updatedAt: String? = null,
)

