package ai.oriveo.community.core.model

private val defaultHomeSkillKeys = listOf(
    "translation_expert",
    "writing_coach",
    "email_assistant",
    "brainstorm",
    "document_summarizer",
)

const val homeSkillDisplayLimit = 7

fun selectHomeSkills(
    skills: List<Skill>,
    limit: Int = homeSkillDisplayLimit,
): List<Skill> {
    if (limit <= 0) return emptyList()

    val catalogSkills = skills.filter { it.isBuiltIn }
    val pinned = skills
        .filter { it.isPinned }
        .sortedBy { it.pinOrder }
    val recent = skills
        .filter { !it.isPinned && !it.lastUsedAt.isNullOrBlank() }
        .sortedByDescending { it.lastUsedAt }
    val recommended = defaultHomeSkillKeys.mapNotNull { key ->
        catalogSkills.firstOrNull { it.key == key }
    }
    val remainingBuiltin = catalogSkills

    val selected = mutableListOf<Skill>()
    val seenIds = linkedSetOf<String>()

    fun appendUnique(candidates: List<Skill>) {
        for (skill in candidates) {
            if (selected.size >= limit) return
            if (!seenIds.add(skill.id)) continue
            selected += skill
        }
    }

    appendUnique(pinned)
    appendUnique(recent)
    appendUnique(recommended)
    appendUnique(remainingBuiltin)
    return selected
}
