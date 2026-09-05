package ai.oriveo.community.feature.chat

import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.Skill
import ai.oriveo.community.core.model.SkillKnowledgeFileStatus
import ai.oriveo.community.core.model.SkillKnowledgeRetrievalContext
import ai.oriveo.community.core.model.SkillKnowledgeRetrievalTarget
import ai.oriveo.community.core.model.SkillKnowledgeSnippet
import ai.oriveo.community.core.util.graphemeCount
import ai.oriveo.community.core.util.takeGraphemes
import kotlinx.coroutines.withTimeoutOrNull

data class ReferencePromptFile(
    val fileName: String,
    val content: String,
)

data class SkillKnowledgeBudgetResult(
    val referenceFiles: List<ReferencePromptFile>,
    val retrievalSnippets: List<SkillKnowledgeSnippet>,
)

fun applySkillKnowledgeBudget(
    referenceFiles: List<ReferencePromptFile>,
    retrievalSnippets: List<SkillKnowledgeSnippet>,
    maxPromptChars: Int,
): SkillKnowledgeBudgetResult {
    var remainingChars = maxOf(0, maxPromptChars)

    val totalReferenceChars = referenceFiles.sumOf { it.content.graphemeCount() }
    val totalSnippetChars = retrievalSnippets.sumOf { it.text.graphemeCount() }
    var overflow = maxOf(0, totalReferenceChars + totalSnippetChars - remainingChars)

    val trimmedSnippets = retrievalSnippets.mapNotNull { snippet ->
        if (overflow <= 0) return@mapNotNull snippet
        val snippetChars = snippet.text.graphemeCount()
        if (overflow >= snippetChars) {
            overflow -= snippetChars
            return@mapNotNull null
        }
        val keepChars = snippetChars - overflow
        overflow = 0
        snippet.copy(text = snippet.text.takeGraphemes(keepChars))
    }

    val trimmedReferences = referenceFiles.mapNotNull { file ->
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

    return SkillKnowledgeBudgetResult(
        referenceFiles = trimmedReferences,
        retrievalSnippets = trimmedSnippets,
    )
}

object SkillKnowledgeRetrievalResolver {
    private const val RUNTIME_CONFIG_TIMEOUT_MS = 2_000L
    private const val RETRIEVAL_TIMEOUT_MS = 6_000L
    private const val DEFAULT_MAX_RESULTS = 6
    private const val DEFAULT_MAX_SNIPPET_CHARS = 2_000
    private const val DEFAULT_MAX_TOTAL_SNIPPET_CHARS = 12_000
    private const val OFFICIAL_OPENAI_BASE_URL = "https://api.openai.com/v1"

    private fun resolveBaseUrl(baseUrl: String?): String {
        val raw = baseUrl?.takeIf { it.isNotBlank() } ?: ProviderKind.OpenAI.defaultBaseUrl.orEmpty()
        val trimmed = raw.trim().trimEnd('/')
        return if (trimmed.startsWith("http")) trimmed else "https://$trimmed"
    }

    private fun usesOfficialOpenAIApi(baseUrl: String?): Boolean {
        return resolveBaseUrl(baseUrl) == OFFICIAL_OPENAI_BASE_URL
    }

    suspend fun resolve(
        latestUserText: String,
        skill: Skill?,
        providers: List<Provider>,
        client: Any = Any(),
    ): SkillKnowledgeRetrievalContext? {
        @Suppress("UNUSED_PARAMETER")
        val ignored = Triple(latestUserText, skill, providers)
        return null
    }

    private fun Provider.hasEnabledModel(modelId: String): Boolean {
        val normalized = modelId.trim()
        if (normalized.isEmpty()) return false
        return models.any { model ->
            model.id == normalized || model.canonicalModelId == normalized
        }
    }
}
