package ai.oriveo.community.core.data.mapper

import ai.oriveo.community.core.data.entity.MessageEntity
import ai.oriveo.community.core.model.Attachment
import ai.oriveo.community.core.model.CapabilityExecutionResult
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatMessageState
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.QuoteContext
import ai.oriveo.community.core.model.UnhandledToolCall
import ai.oriveo.community.core.util.normalizeAttachmentIds
import ai.oriveo.community.core.util.normalizeMessageIds
import ai.oriveo.community.core.util.normalizeUuid
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

/** Converts between the stored row and the in-memory message. */
object MessageMapper {

    private val json = Json { ignoreUnknownKeys = true; coerceInputValues = true }

    fun MessageEntity.toDomain(): ChatMessage = normalizeMessageIds(ChatMessage(
        id = id,
        role = ChatRole.valueOf(role),
        text = text,
        providerID = providerID,
        providerKind = ProviderKind.valueOf(providerKind),
        providerName = providerName,
        modelID = modelID,
        modelName = modelName,
        servedModelID = servedModelID,
        estimatedCost = estimatedCost,
        state = ChatMessageState.valueOf(state),
        errorTitle = errorTitle,
        errorDetail = errorDetail,
        attachments = attachmentsJson?.let { raw ->
            runCatching { json.decodeFromString<List<Attachment>>(raw) }.getOrNull()
        },
        quoteContext = quoteContextJson?.let { raw ->
            runCatching { json.decodeFromString<QuoteContext>(raw) }.getOrNull()?.takeIf { it.isValid }
        },
        createdAt = createdAt,
        reasoningText = reasoningText,
        reasoningDurationMs = reasoningDurationMs,
        citations = citationsJson?.let { raw ->
            runCatching {
                json.decodeFromString<List<ai.oriveo.community.core.model.Citation>>(raw)
            }.getOrNull()
        },
        capabilityExecutionResults = capabilityExecutionResultsJson?.let { raw ->
            runCatching { json.decodeFromString<List<CapabilityExecutionResult>>(raw) }.getOrDefault(emptyList())
        }.orEmpty(),
        unhandledToolCalls = unhandledToolCallsJson?.let { raw ->
            runCatching { json.decodeFromString<List<UnhandledToolCall>>(raw) }.getOrDefault(emptyList())
        }.orEmpty(),
        toolFallbackNotice = toolFallbackNotice,
        customRetryWithoutFieldsAvailable = customRetryWithoutFieldsAvailable,
        customRetryWithoutFieldsCode = customRetryWithoutFieldsCode,
        inputTokens = inputTokens,
        outputTokens = outputTokens,
        cachedInputTokens = cachedInputTokens,
        cacheCreationInputTokens = cacheCreationInputTokens,
        cacheCreation5mTokens = cacheCreation5mTokens,
        cacheCreation1hTokens = cacheCreation1hTokens,
        costSource = costSource,
    ))

    /**
     * Encodes attachments exactly the way [toEntity] does, so a caller that rewrites only the
     * attachment column produces a byte-identical result. Building a second `Json` here would
     * quietly diverge the moment either configuration changed.
     */
    fun encodeAttachmentsJson(attachments: List<Attachment>?): String? =
        attachments?.map(::normalizeAttachmentIds)?.let { json.encodeToString(it) }

    fun ChatMessage.toEntity(accountId: String, conversationId: String, sortOrder: Int): MessageEntity =
        MessageEntity(
            id = normalizeUuid(id),
            accountId = accountId,
            conversationId = normalizeUuid(conversationId),
            role = role.name,
            text = text,
            providerID = providerID?.let(::normalizeUuid),
            providerKind = providerKind.name,
            providerName = providerName,
            modelID = modelID,
            modelName = modelName,
            servedModelID = servedModelID,
            estimatedCost = estimatedCost,
            state = state.name,
            errorTitle = errorTitle,
            errorDetail = errorDetail,
            attachmentsJson = attachments?.map(::normalizeAttachmentIds)?.let { json.encodeToString(it) },
            quoteContextJson = quoteContext?.takeIf { it.isValid }?.let { json.encodeToString(it) },
            createdAt = createdAt,
            sortOrder = sortOrder,
            citationsJson = citations?.takeIf { it.isNotEmpty() }?.let { json.encodeToString(it) },
            capabilityExecutionResultsJson = capabilityExecutionResults
                .takeIf { it.isNotEmpty() }
                ?.let { json.encodeToString(it) },
            unhandledToolCallsJson = unhandledToolCalls
                .takeIf { it.isNotEmpty() }
                ?.let { json.encodeToString(it) },
            toolFallbackNotice = toolFallbackNotice?.takeIf { it.isNotBlank() },
            customRetryWithoutFieldsAvailable = customRetryWithoutFieldsAvailable,
            customRetryWithoutFieldsCode = customRetryWithoutFieldsCode,
            reasoningText = reasoningText?.takeIf { it.isNotBlank() },
            reasoningDurationMs = reasoningDurationMs,
            inputTokens = inputTokens,
            outputTokens = outputTokens,
            cachedInputTokens = cachedInputTokens,
            cacheCreationInputTokens = cacheCreationInputTokens,
            cacheCreation5mTokens = cacheCreation5mTokens,
            cacheCreation1hTokens = cacheCreation1hTokens,
            costSource = costSource,
        )
}
