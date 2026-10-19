package ai.oriveo.community.feature.settings

import androidx.annotation.StringRes
import ai.oriveo.community.R
import ai.oriveo.community.core.context.MemoryItem
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.core.model.Conversation
import ai.oriveo.community.core.model.LastUsedModelRef
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.provider.ModelDisplayLookup
import ai.oriveo.community.core.provider.ModelSelectionUtils
import ai.oriveo.community.core.provider.ProviderCredentialResolver
import ai.oriveo.community.core.provider.RelayModelFallback
import ai.oriveo.community.core.util.takeGraphemes

/**
 * Pre-send disclosure for AI memory extraction (P6·U5 contract 1–3): the dialog names the single
 * provider + model and the scope; nothing is sent before the user confirms, and the request uses
 * exactly this provider + model with no fallback.
 */
data class MemoryExtractionDisclosure(
    @param:StringRes val titleRes: Int,
    @param:StringRes val scopeRes: Int,
    val provider: Provider,
    val model: AIModel,
    /** Draft only: the excerpts computed before the dialog opens; sent verbatim on confirm. */
    val excerpts: String = "",
    /** Organize only: the item whose full text is sent on confirm; null for draft. */
    val organizeItem: MemoryItem? = null,
) {
    val providerName: String get() = provider.displayName

    /** Same display function as the chat model capsule ([ModelDisplayLookup.modelDisplayName]). */
    val modelName: String =
        ModelDisplayLookup(listOf(provider)).modelDisplayName(
            providerId = provider.id,
            modelId = model.id,
            fallback = model.name.ifBlank { model.id },
        ) ?: model.id

    /** Dialog body, one entry per line: model, scope, no-fallback (string res + format args). */
    fun bodyLines(): List<MemoryExtractionDisclosureLine> = listOf(
        MemoryExtractionDisclosureLine(R.string.memory_extraction_model, listOf(providerName, modelName)),
        MemoryExtractionDisclosureLine(scopeRes),
        MemoryExtractionDisclosureLine(R.string.memory_extraction_no_fallback),
    )

    companion object {
        fun draft(candidate: MemoryExtractionCandidate, excerpts: String) = MemoryExtractionDisclosure(
            titleRes = R.string.memory_extraction_title_draft,
            scopeRes = R.string.memory_extraction_scope_draft,
            provider = candidate.provider,
            model = candidate.model,
            excerpts = excerpts,
        )

        fun organize(candidate: MemoryExtractionCandidate, item: MemoryItem) = MemoryExtractionDisclosure(
            titleRes = R.string.memory_extraction_title_organize,
            scopeRes = R.string.memory_extraction_scope_organize,
            provider = candidate.provider,
            model = candidate.model,
            organizeItem = item,
        )
    }
}

data class MemoryExtractionDisclosureLine(
    @param:StringRes val resId: Int,
    val args: List<Any> = emptyList(),
)

data class MemoryExtractionCandidate(
    val provider: Provider,
    val model: AIModel,
)

internal object MemoryExtraction {
    const val EXCERPT_CHARACTER_LIMIT = 500
    private const val CONVERSATION_SEPARATOR = "\n---\n"

    /**
     * Candidates in the existing order: relays are not excluded for lacking a key (auth=none local / LAN
     * connections can still send, D-68 ⑦); the last-used connection first, the rest in original order.
     */
    fun candidates(allProviders: List<Provider>, lastUsed: LastUsedModelRef?): List<MemoryExtractionCandidate> =
        allProviders
            .filter { it.kind == ProviderKind.Relay || ProviderCredentialResolver.apiKey(it, null).isNotBlank() }
            .sortedByDescending { lastUsed != null && it.id == lastUsed.providerID }
            .mapNotNull { provider -> provider.toCandidate(lastUsed) }

    /**
     * Draft scope: per conversation keep only user messages sent to [providerId] (blank providerID dropped),
     * same line format, first 500 graphemes; conversations left empty are dropped; joined by `\n---\n`.
     * Returns blank when nothing is left.
     */
    fun draftExcerpts(conversations: List<Conversation>, providerId: String): String =
        conversations
            .map { conversation ->
                conversation.messages
                    .filter { it.role == ChatRole.User && !it.providerID.isNullOrBlank() && it.providerID == providerId }
                    .joinToString("\n") { message -> "${message.role.name.lowercase()}: ${message.text}" }
                    .takeGraphemes(EXCERPT_CHARACTER_LIMIT)
            }
            .filter { it.isNotBlank() }
            .joinToString(CONVERSATION_SEPARATOR)

    private fun Provider.toCandidate(lastUsed: LastUsedModelRef?): MemoryExtractionCandidate? {
        // The last-used model wins when still valid.
        if (lastUsed != null && lastUsed.providerID == id) {
            ModelSelectionUtils.resolveStoredModel(models, lastUsed.modelID, kind)
                ?.let { return MemoryExtractionCandidate(provider = this, model = it) }
        }
        // Relay: last-used (pointing here and still enabled) → first enabled model; never an unenabled catalog model.
        if (kind == ProviderKind.Relay) {
            val model = RelayModelFallback.fallbackModel(this, lastUsed) ?: return null
            return MemoryExtractionCandidate(provider = this, model = model)
        }
        val resolvedModel: AIModel = defaultModel
            ?: models.firstOrNull()
            ?: allModels.firstOrNull()
            ?: return null
        return MemoryExtractionCandidate(provider = this, model = resolvedModel)
    }
}
