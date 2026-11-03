package ai.oriveo.community.core.model

import androidx.compose.runtime.Immutable
import ai.oriveo.community.core.context.isUnicodeWhiteSpace
import ai.oriveo.community.core.context.trimWhiteSpace
import ai.oriveo.community.core.util.normalizeUuid
import kotlinx.serialization.Serializable

/** One skill an assistant reply used (skill_sync_fields.v1 usedSkills entry). [reason] only for via auto. */
@Immutable
@Serializable
data class UsedSkill(
    val id: String,
    val name: String,
    val via: String,
    val reason: String? = null,
)

/** Skill ids / disabled auto skills read off a conversation document. */
data class ConversationSkillFields(
    val skillIds: List<String>,
    val disabledAutoSkillIds: List<String>,
)

/** Skill fields read off a message document; only the field of the matching role is filled. */
data class MessageSkillFields(
    val attachedSkillIds: List<String>,
    val usedSkills: List<UsedSkill>,
)

/**
 * Write / read rules of the shared skill-contracts/skill_sync_fields.v1.json, shared by Room mapping and Firestore mapping.
 * Ids are sync ids: trimmed, UUIDs upper-cased via [normalizeUuid], others unchanged.
 */
object SkillSyncFields {
    const val SKILL_IDS_MAX: Int = 3
    const val DISABLED_AUTO_SKILL_IDS_MAX: Int = 30
    const val REASON_MAX: Int = 60
    const val VIA_AUTO: String = "auto"
    const val VIA_MANUAL: String = "manual"
    val USED_SKILL_VIA: List<String> = listOf(VIA_AUTO, VIA_MANUAL)

    const val KEY_SKILL_IDS: String = "skillIds"
    const val KEY_SKILL_ID: String = "skillId"
    const val KEY_DISABLED_AUTO_SKILL_IDS: String = "disabledAutoSkillIds"
    const val KEY_ATTACHED_SKILL_IDS: String = "attachedSkillIds"
    const val KEY_USED_SKILLS: String = "usedSkills"

    fun syncId(raw: String): String = normalizeUuid(raw.trimWhiteSpace())

    /** String items only, normalised, blank dropped, deduplicated in order, first [max]. */
    fun idList(raw: Any?, max: Int): List<String> {
        val out = mutableListOf<String>()
        for (item in raw as? List<*> ?: return emptyList()) {
            val id = (item as? String)?.let(::syncId) ?: continue
            if (id.isNotEmpty() && id !in out) out += id
        }
        return out.take(max)
    }

    /**
     * Conversation read rule: [skillIds] null = key absent. A non-blank [legacySkillId] that differs from
     * skillIds[0] means an old client changed it → [legacy].
     */
    fun resolveSkillIds(skillIds: Any?, legacySkillId: Any?): List<String> {
        val legacy = (legacySkillId as? String)?.let(::syncId)?.takeIf { it.isNotEmpty() }
        val ids = if (skillIds is List<*>) idList(skillIds, SKILL_IDS_MAX) else null
        return when {
            ids == null -> listOfNotNull(legacy)
            legacy != null && ids.firstOrNull() != legacy -> listOf(legacy)
            else -> ids
        }
    }

    fun conversationWrite(skillIds: List<String>, disabledAutoSkillIds: List<String>): Map<String, Any> {
        val out = linkedMapOf<String, Any>()
        val ids = idList(skillIds, SKILL_IDS_MAX)
        if (ids.isNotEmpty()) {
            out[KEY_SKILL_IDS] = ids
            out[KEY_SKILL_ID] = ids.first()
        }
        val disabled = idList(disabledAutoSkillIds, DISABLED_AUTO_SKILL_IDS_MAX)
        if (disabled.isNotEmpty()) out[KEY_DISABLED_AUTO_SKILL_IDS] = disabled
        return out
    }

    fun conversationRead(data: Map<String, Any?>): ConversationSkillFields = ConversationSkillFields(
        skillIds = resolveSkillIds(data[KEY_SKILL_IDS], data[KEY_SKILL_ID]),
        disabledAutoSkillIds = idList(data[KEY_DISABLED_AUTO_SKILL_IDS], DISABLED_AUTO_SKILL_IDS_MAX),
    )

    /** Accepts [UsedSkill] items (local) or Firestore maps (remote); applies the usedSkills rule. */
    fun usedList(raw: Any?): List<UsedSkill> {
        val out = mutableListOf<UsedSkill>()
        for (item in raw as? List<*> ?: return emptyList()) {
            val fields: (String) -> Any? = when (item) {
                is UsedSkill -> { key ->
                    when (key) {
                        "id" -> item.id
                        "name" -> item.name
                        "via" -> item.via
                        else -> item.reason
                    }
                }
                is Map<*, *> -> { key -> item[key] }
                else -> continue
            }
            val rawId = fields("id") as? String ?: continue
            val rawName = fields("name") as? String ?: continue
            val via = fields("via") as? String ?: continue
            if (via !in USED_SKILL_VIA) continue
            val id = syncId(rawId)
            val name = collapse(rawName)
            if (id.isEmpty() || name.isEmpty() || out.any { it.id == id }) continue
            val reason = (fields("reason") as? String)?.let { prefixCodePoints(collapse(it), REASON_MAX) }
            out += UsedSkill(id = id, name = name, via = via, reason = reason?.takeIf { it.isNotEmpty() })
        }
        return out
    }

    fun usedSkillToMap(skill: UsedSkill): Map<String, Any> = buildMap {
        put("id", skill.id)
        put("name", skill.name)
        put("via", skill.via)
        skill.reason?.let { put("reason", it) }
    }

    fun messageWrite(role: ChatRole, attachedSkillIds: List<String>, usedSkills: List<UsedSkill>): Map<String, Any> {
        val out = linkedMapOf<String, Any>()
        when (role) {
            ChatRole.User -> idList(attachedSkillIds, SKILL_IDS_MAX)
                .takeIf { it.isNotEmpty() }?.let { out[KEY_ATTACHED_SKILL_IDS] = it }
            ChatRole.Assistant -> usedList(usedSkills)
                .takeIf { it.isNotEmpty() }?.let { list -> out[KEY_USED_SKILLS] = list.map(::usedSkillToMap) }
        }
        return out
    }

    fun messageRead(role: ChatRole, data: Map<String, Any?>): MessageSkillFields = MessageSkillFields(
        attachedSkillIds = if (role == ChatRole.User) idList(data[KEY_ATTACHED_SKILL_IDS], SKILL_IDS_MAX) else emptyList(),
        usedSkills = if (role == ChatRole.Assistant) usedList(data[KEY_USED_SKILLS]) else emptyList(),
    )

    /** Local "turn off for this conversation": dedupe-append, keep the newest [DISABLED_AUTO_SKILL_IDS_MAX]. */
    fun appendDisabledAutoSkill(current: List<String>, skillId: String): List<String> {
        val id = syncId(skillId)
        val normalized = idList(current, Int.MAX_VALUE)
        if (id.isEmpty() || id in normalized) return normalized
        return (normalized + id).takeLast(DISABLED_AUTO_SKILL_IDS_MAX)
    }

    /** Every run of Unicode White_Space becomes one space, then trim. */
    private fun collapse(text: String): String {
        val out = StringBuilder(text.length)
        var inSpace = false
        for (c in text) {
            if (c.isUnicodeWhiteSpace()) {
                if (!inSpace) out.append(' ')
                inSpace = true
            } else {
                out.append(c)
                inSpace = false
            }
        }
        return out.toString().trimWhiteSpace()
    }

    private fun prefixCodePoints(text: String, max: Int): String {
        val count = text.codePointCount(0, text.length)
        if (count <= max) return text
        return text.substring(0, text.offsetByCodePoints(0, max))
    }
}
