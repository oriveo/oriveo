package ai.oriveo.community.feature.chat

import ai.oriveo.community.core.util.graphemeCount
import ai.oriveo.community.core.util.takeGraphemes

data class ReferencePromptFile(
    val fileName: String,
    val content: String,
)

/**
 * Trims a skill's reference files to fit the prompt budget.
 *
 * Files are kept whole while they fit and the last one that does not is cut rather than dropped, so
 * a skill whose files exceed the budget still contributes its first files in full instead of
 * contributing nothing.
 */
fun applySkillReferenceFileBudget(
    referenceFiles: List<ReferencePromptFile>,
    maxPromptChars: Int,
): List<ReferencePromptFile> {
    val budget = maxOf(0, maxPromptChars)
    var overflow = maxOf(0, referenceFiles.sumOf { it.content.graphemeCount() } - budget)

    return referenceFiles.mapNotNull { file ->
        if (overflow <= 0) return@mapNotNull file
        val fileChars = file.content.graphemeCount()
        if (overflow >= fileChars) {
            overflow -= fileChars
            return@mapNotNull null
        }
        val keepChars = fileChars - overflow
        overflow = 0
        file.copy(content = file.content.takeGraphemes(keepChars))
    }
}
