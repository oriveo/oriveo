package ai.oriveo.community.core.model

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

@Serializable
data class SkillKnowledgeRuntimeConfig(
    val provider: String,
    val retrievalModel: String,
    val expiresAfterDays: Int,
    val maxResults: Int,
    val maxSnippetChars: Int,
    val maxTotalSnippetChars: Int,
    val supportedFileTypes: List<String> = emptyList(),
    val createdAt: String? = null,
    val updatedAt: String? = null,
)

@Serializable
data class SkillKnowledgeEligibility(
    val eligible: Boolean,
    val errorCode: SkillKnowledgeErrorCode? = null,
    val requiredModel: String? = null,
)

@Serializable
data class SkillKnowledgeRetrievalTarget(
    val retrievalModel: String,
    val vectorStoreId: String,
)

@Serializable
data class SkillKnowledgeSnippet(
    val fileId: String,
    val fileName: String,
    val text: String,
    val score: Double,
)

@Serializable
data class SkillKnowledgeUsage(
    @SerialName("prompt_tokens")
    val promptTokens: Int,
    @SerialName("completion_tokens")
    val completionTokens: Int,
    @SerialName("total_tokens")
    val totalTokens: Int,
)

@Serializable
data class SkillKnowledgeRetrieveResponse(
    val snippets: List<SkillKnowledgeSnippet>,
    val usage: SkillKnowledgeUsage,
)

data class SkillKnowledgeUploadPayload(
    val data: ByteArray,
    val uploadFileName: String,
    val displayName: String,
    val displayMimeType: String,
    val displaySizeBytes: Long,
    val ingestionMode: SkillKnowledgeIngestionMode,
    val extractedFrom: SkillKnowledgeExtractedFrom? = null,
)

data class SkillKnowledgeRetrievalContext(
    val snippets: List<SkillKnowledgeSnippet>,
    val usage: SkillKnowledgeUsage,
    val estimatedCost: Double,
    val providerId: String,
    val modelId: String,
)

data class ChatDeliveredUsageMetrics(
    val promptTokens: Int,
    val completionTokens: Int,
)

data class ChatDeliveredUsageRequest(
    val providerId: String,
    val providerKind: ProviderKind,
    val modelId: String,
    val conversationId: String,
    val skillId: String?,
    val source: String?,
    val promptTokens: Int,
    val completionTokens: Int,
    val estimatedCost: Double,
    val costStatus: String = "priced",
)

object ChatDeliveryAccounting {
    private fun generationEstimatedCost(
        deliveredCost: Double,
        retrieval: SkillKnowledgeRetrievalContext?,
    ): Double {
        val retrievalCost = retrieval?.estimatedCost ?: 0.0
        return if (retrievalCost > CostFormatter.COST_EPSILON) {
            (deliveredCost - retrievalCost).coerceAtLeast(0.0)
        } else {
            deliveredCost
        }
    }

    fun deliveredCost(
        baseCost: Double,
        retrieval: SkillKnowledgeRetrievalContext? = null,
    ): Double {
        if (retrieval == null || retrieval.estimatedCost <= CostFormatter.COST_EPSILON) {
            return baseCost
        }
        return baseCost + retrieval.estimatedCost
    }

    fun usageRequests(
        conversation: Conversation,
        message: ChatMessage,
        generation: ChatDeliveredUsageMetrics?,
        retrieval: SkillKnowledgeRetrievalContext?,
        generationCostStatus: String = "priced",
    ): List<ChatDeliveredUsageRequest> {
        val requests = mutableListOf<ChatDeliveredUsageRequest>()

        if (retrieval != null && retrieval.estimatedCost > CostFormatter.COST_EPSILON) {
            requests += ChatDeliveredUsageRequest(
                providerId = retrieval.providerId,
                providerKind = ProviderKind.OpenAI,
                modelId = retrieval.modelId,
                conversationId = conversation.id,
                skillId = conversation.skillId,
                source = "skill_knowledge_retrieval",
                promptTokens = retrieval.usage.promptTokens,
                completionTokens = retrieval.usage.completionTokens,
                estimatedCost = retrieval.estimatedCost,
            )
        }

        if (generation != null) {
            requests += ChatDeliveredUsageRequest(
                providerId = conversation.providerID,
                providerKind = message.providerKind,
                modelId = conversation.modelID,
                conversationId = conversation.id,
                skillId = conversation.skillId,
                source = null,
                promptTokens = generation.promptTokens,
                completionTokens = generation.completionTokens,
                estimatedCost = if (generationCostStatus == "unknown") {
                    0.0
                } else {
                    generationEstimatedCost(message.estimatedCost, retrieval)
                },
                costStatus = generationCostStatus,
            )
        }

        return requests
    }
}
