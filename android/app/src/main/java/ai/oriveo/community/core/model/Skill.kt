package ai.oriveo.community.core.model

import androidx.compose.runtime.Immutable
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

@Immutable
@Serializable
data class Skill(
    val id: String,
    val key: String? = null,
    val name: String,
    val description: String = "",
    val icon: String = "\uD83E\uDD16",
    val color: String = "#6d38ff",
    val systemPrompt: String,
    val suggestedProviderId: String? = null,
    val suggestedModelId: String? = null,
    val modelCapabilityHint: String = "any",
    val temperature: Double? = null,
    val reasoningLevel: String? = null,
    val webSearchEnabled: Boolean? = null,
    val starterMessages: List<String> = emptyList(),
    val knowledgeFiles: List<SkillKnowledgeFile> = emptyList(),
    val knowledgeBase: SkillKnowledgeBase? = null,
    val useMemory: Boolean = true,
    val isPinned: Boolean = false,
    val pinOrder: Int = 0,
    val source: SkillSource = SkillSource.USER,
    val forkedFromId: String? = null,
    val category: String? = null,
    val sortOrder: Int = 0,
    val usageCount: Int = 0,
    val lastUsedAt: String? = null,
    val createdAt: String = "",
    val updatedAt: String = "",
) {
    val isBuiltIn get() = source == SkillSource.BUILTIN
    val isEditable get() = source == SkillSource.USER
}

@Immutable
@Serializable
data class SkillKnowledgeFile(
    val id: String,
    val name: String,
    val mimeType: String = "text/plain",
    val sourceType: SkillKnowledgeSourceType = SkillKnowledgeSourceType.TEXT,
    val content: String,
    val charCount: Int,
    val createdAt: String? = null,
    val updatedAt: String? = null,
)

@Serializable
enum class SkillKnowledgeSourceType {
    @SerialName("text") TEXT,
    @SerialName("pdf_text") PDF_TEXT,
}

@Serializable
enum class SkillKnowledgeFileStatus {
    @SerialName("extracting") EXTRACTING,
    @SerialName("uploading") UPLOADING,
    @SerialName("indexing") INDEXING,
    @SerialName("ready") READY,
    @SerialName("failed") FAILED,
    @SerialName("replacing") REPLACING,
    @SerialName("deleting") DELETING,
    @SerialName("disabled") DISABLED,
}

@Serializable
enum class SkillKnowledgeIngestionMode {
    @SerialName("native_file") NATIVE_FILE,
    @SerialName("extracted_text") EXTRACTED_TEXT,
}

@Serializable
enum class SkillKnowledgeExtractedFrom {
    @SerialName("xlsx") XLSX,
}

@Serializable
enum class SkillKnowledgeErrorCode {
    @SerialName("openai_not_configured") OPENAI_NOT_CONFIGURED,
    @SerialName("openai_endpoint_not_official") OPENAI_ENDPOINT_NOT_OFFICIAL,
    @SerialName("retrieval_model_not_enabled") RETRIEVAL_MODEL_NOT_ENABLED,
    @SerialName("knowledge_service_unavailable") KNOWLEDGE_SERVICE_UNAVAILABLE,
    @SerialName("unsupported_file_type") UNSUPPORTED_FILE_TYPE,
    @SerialName("reference_file_too_large") REFERENCE_FILE_TOO_LARGE,
    @SerialName("reference_file_char_limit_exceeded") REFERENCE_FILE_CHAR_LIMIT_EXCEEDED,
    @SerialName("knowledge_file_too_large") KNOWLEDGE_FILE_TOO_LARGE,
    @SerialName("knowledge_total_size_exceeded") KNOWLEDGE_TOTAL_SIZE_EXCEEDED,
    @SerialName("knowledge_extract_failed") KNOWLEDGE_EXTRACT_FAILED,
    @SerialName("knowledge_upload_failed") KNOWLEDGE_UPLOAD_FAILED,
    @SerialName("knowledge_index_failed") KNOWLEDGE_INDEX_FAILED,
    @SerialName("knowledge_retrieve_failed") KNOWLEDGE_RETRIEVE_FAILED,
    @SerialName("knowledge_cleanup_failed") KNOWLEDGE_CLEANUP_FAILED,
}

@Immutable
@Serializable
data class SkillKnowledgeBase(
    val provider: String,
    val retrievalModel: String,
    val vectorStoreId: String,
    val expiresAfterDays: Int,
    val files: List<SkillKnowledgeBaseFile> = emptyList(),
    val updatedAt: String? = null,
)

@Immutable
@Serializable
data class SkillKnowledgeBaseFile(
    val id: String,
    val name: String,
    val mimeType: String,
    val sizeBytes: Long,
    val ingestionMode: SkillKnowledgeIngestionMode,
    val extractedFrom: SkillKnowledgeExtractedFrom? = null,
    val openAIFileId: String? = null,
    val status: SkillKnowledgeFileStatus,
    val errorCode: SkillKnowledgeErrorCode? = null,
    val createdAt: String? = null,
    val updatedAt: String? = null,
)

@Serializable
enum class SkillSource {
    @SerialName("builtin") BUILTIN,
    @SerialName("user") USER,
    @SerialName("community") COMMUNITY;

    val value: String get() = name.lowercase()

    companion object {
        fun from(s: String) = entries.firstOrNull { it.value == s } ?: USER
    }
}

@Immutable
@Serializable
data class SkillCategory(
    val id: String,
    val name: String,
    val icon: String = "",
    val sortOrder: Int = 0,
)
