package ai.oriveo.community.feature.skills

import ai.oriveo.community.core.model.SkillKnowledgeBase
import ai.oriveo.community.core.model.SkillKnowledgeBaseFile
import ai.oriveo.community.core.model.SkillKnowledgeErrorCode
import ai.oriveo.community.core.model.SkillKnowledgeExtractedFrom
import ai.oriveo.community.core.model.SkillKnowledgeFile
import ai.oriveo.community.core.model.SkillKnowledgeFileStatus
import ai.oriveo.community.core.model.SkillKnowledgeIngestionMode
import ai.oriveo.community.core.model.SkillKnowledgeSourceType
import ai.oriveo.community.core.model.SkillKnowledgeUploadPayload
import java.time.Instant
import java.util.Locale
import java.util.UUID
import kotlin.math.max

const val MAX_REFERENCE_FILE_SIZE_BYTES = 3L * 1024 * 1024
const val MAX_KNOWLEDGE_FILE_SIZE_BYTES = 20L * 1024 * 1024
const val MAX_KNOWLEDGE_FILES = 5
const val MAX_KNOWLEDGE_TOTAL_BYTES = 100L * 1024 * 1024
const val MAX_KNOWLEDGE_FILE_NAME_LENGTH = 120

data class SkillKnowledgeDraftCleanupPlan(
    val vectorStoreId: String,
    val deleteVectorStore: Boolean,
    val openAIFileIds: List<String>,
)

private val TEXT_FILE_EXTENSIONS = setOf(
    "txt", "md", "json", "csv", "html", "xml", "yaml", "yml",
    "css", "js", "ts", "jsx", "tsx", "py", "java", "kt", "swift", "go", "sql",
)

fun codePointCount(value: String): Int =
    value.codePointCount(0, value.length)

fun sanitizeKnowledgeFileName(
    name: String,
    maxLength: Int = MAX_KNOWLEDGE_FILE_NAME_LENGTH,
): String {
    val cleaned = name
        .map { if (it.code < 32 || it.code == 127) ' ' else it }
        .joinToString(separator = "")
        .trim()
        .split(Regex("\\s+"))
        .filter { it.isNotEmpty() }
        .joinToString(" ")

    if (cleaned.isEmpty()) return "file"
    if (cleaned.length <= maxLength) return cleaned

    val dotIndex = cleaned.lastIndexOf('.')
    if (dotIndex <= 0 || dotIndex == cleaned.lastIndex) {
        return cleaned.take(maxLength).trim()
    }

    val ext = cleaned.substring(dotIndex)
    val base = cleaned.substring(0, dotIndex)
    val clippedBase = base.take(max(1, maxLength - ext.length)).trim()
    return (clippedBase + ext).take(maxLength)
}

fun resolveImportedFileSize(
    metadataSizeBytes: Long?,
    fallbackSizeBytes: Long,
): Long = metadataSizeBytes?.takeIf { it > 0 } ?: max(0L, fallbackSizeBytes)

fun validateReferenceFileSize(sizeBytes: Long): SkillKnowledgeErrorCode? =
    if (sizeBytes > MAX_REFERENCE_FILE_SIZE_BYTES) {
        SkillKnowledgeErrorCode.REFERENCE_FILE_TOO_LARGE
    } else {
        null
    }

fun validateKnowledgeBaseQuota(
    existingCount: Int,
    existingBytes: Long,
    nextFileBytes: Long,
): SkillKnowledgeErrorCode? {
    if (existingCount >= MAX_KNOWLEDGE_FILES) {
        return SkillKnowledgeErrorCode.KNOWLEDGE_TOTAL_SIZE_EXCEEDED
    }
    if (nextFileBytes > MAX_KNOWLEDGE_FILE_SIZE_BYTES) {
        return SkillKnowledgeErrorCode.KNOWLEDGE_FILE_TOO_LARGE
    }
    if (existingBytes + nextFileBytes > MAX_KNOWLEDGE_TOTAL_BYTES) {
        return SkillKnowledgeErrorCode.KNOWLEDGE_TOTAL_SIZE_EXCEEDED
    }
    return null
}

fun formatKnowledgeBytes(bytes: Long): String {
    if (bytes < 1024) return "$bytes B"
    if (bytes < 1024 * 1024) return String.format(Locale.US, "%.1f KB", bytes / 1024.0)
    return String.format(Locale.US, "%.1f MB", bytes / (1024.0 * 1024.0))
}

fun isKnowledgeFileTypeSupported(
    fileName: String,
    mimeType: String,
    supportedFileTypes: List<String>,
): Boolean {
    val ext = fileName.substringAfterLast('.', "").lowercase(Locale.ROOT)
    if (ext in supportedFileTypes) return true
    if ("txt" in supportedFileTypes) {
        return mimeType.startsWith("text/") || ext in TEXT_FILE_EXTENSIONS
    }
    return false
}

fun sumKnowledgeBaseBytes(knowledgeBase: SkillKnowledgeBase?): Long =
    knowledgeBase?.files?.sumOf { it.sizeBytes } ?: 0L

fun buildReferenceKnowledgeFile(
    name: String,
    mimeType: String,
    sourceType: SkillKnowledgeSourceType,
    content: String,
    id: String = UUID.randomUUID().toString(),
    now: String = Instant.now().toString(),
): SkillKnowledgeFile = SkillKnowledgeFile(
    id = id,
    name = sanitizeKnowledgeFileName(name),
    mimeType = mimeType,
    sourceType = sourceType,
    content = content,
    charCount = codePointCount(content),
    createdAt = now,
    updatedAt = now,
)

fun buildLocalKnowledgeBaseFile(
    id: String,
    name: String,
    mimeType: String,
    sizeBytes: Long,
    ingestionMode: SkillKnowledgeIngestionMode,
    status: SkillKnowledgeFileStatus,
    extractedFrom: SkillKnowledgeExtractedFrom? = null,
    openAIFileId: String? = null,
    errorCode: SkillKnowledgeErrorCode? = null,
    createdAt: String? = null,
    updatedAt: String = Instant.now().toString(),
): SkillKnowledgeBaseFile = SkillKnowledgeBaseFile(
    id = id,
    name = sanitizeKnowledgeFileName(name),
    mimeType = mimeType,
    sizeBytes = sizeBytes,
    ingestionMode = ingestionMode,
    extractedFrom = extractedFrom,
    openAIFileId = openAIFileId,
    status = status,
    errorCode = errorCode,
    createdAt = createdAt ?: updatedAt,
    updatedAt = updatedAt,
)

fun upsertKnowledgeBase(
    knowledgeBase: SkillKnowledgeBase?,
    provider: String,
    retrievalModel: String,
    expiresAfterDays: Int,
    file: SkillKnowledgeBaseFile,
    vectorStoreId: String? = null,
): SkillKnowledgeBase {
    val files = (knowledgeBase?.files ?: emptyList()).toMutableList()
    val index = files.indexOfFirst { it.id == file.id }
    if (index >= 0) {
        files[index] = file
    } else {
        files += file
    }

    return SkillKnowledgeBase(
        provider = provider,
        retrievalModel = retrievalModel,
        vectorStoreId = vectorStoreId ?: knowledgeBase?.vectorStoreId.orEmpty(),
        expiresAfterDays = expiresAfterDays,
        files = files,
        updatedAt = Instant.now().toString(),
    )
}

fun removeKnowledgeBaseFile(
    knowledgeBase: SkillKnowledgeBase?,
    targetFileId: String,
): SkillKnowledgeBase? {
    if (knowledgeBase == null) return null
    val remaining = knowledgeBase.files.filterNot { it.id == targetFileId }
    if (remaining.isEmpty()) return null
    return knowledgeBase.copy(
        files = remaining,
        updatedAt = Instant.now().toString(),
    )
}

fun buildDraftKnowledgeCleanupPlan(
    originalKnowledgeBase: SkillKnowledgeBase?,
    currentKnowledgeBase: SkillKnowledgeBase?,
): SkillKnowledgeDraftCleanupPlan? {
    currentKnowledgeBase ?: return null

    val originalOpenAIFileIds = originalKnowledgeBase
        ?.files
        ?.mapNotNull { it.openAIFileId?.trim()?.takeIf(String::isNotEmpty) }
        ?.toSet()
        ?: emptySet()
    val openAIFileIds = currentKnowledgeBase.files
        .mapNotNull { it.openAIFileId?.trim()?.takeIf(String::isNotEmpty) }
        .filterNot { it in originalOpenAIFileIds }

    if (openAIFileIds.isEmpty()) return null

    return SkillKnowledgeDraftCleanupPlan(
        vectorStoreId = currentKnowledgeBase.vectorStoreId,
        deleteVectorStore = originalKnowledgeBase == null && currentKnowledgeBase.vectorStoreId.isNotBlank(),
        openAIFileIds = openAIFileIds,
    )
}

fun requiresRemoteKnowledgeCleanup(
    originalKnowledgeBase: SkillKnowledgeBase?,
    currentKnowledgeBase: SkillKnowledgeBase?,
): Boolean {
    originalKnowledgeBase ?: return false

    val originalOpenAIFileIds = originalKnowledgeBase.files
        .mapNotNull { it.openAIFileId?.trim()?.takeIf(String::isNotEmpty) }
        .toSet()
    val currentOpenAIFileIds = currentKnowledgeBase
        ?.files
        ?.mapNotNull { it.openAIFileId?.trim()?.takeIf(String::isNotEmpty) }
        ?.toSet()
        ?: emptySet()
    if (originalOpenAIFileIds.any { it !in currentOpenAIFileIds }) {
        return true
    }

    return originalKnowledgeBase.vectorStoreId.isNotBlank() &&
        originalKnowledgeBase.vectorStoreId != currentKnowledgeBase?.vectorStoreId.orEmpty()
}

fun buildKnowledgeUploadPayload(
    data: ByteArray,
    fileName: String,
    mimeType: String,
    sizeBytes: Long,
): SkillKnowledgeUploadPayload {
    val lowercasedName = fileName.lowercase(Locale.ROOT)
    val isXlsx = lowercasedName.endsWith(".xlsx") || mimeType.lowercase(Locale.ROOT).contains("spreadsheetml.sheet")
    return SkillKnowledgeUploadPayload(
        data = data,
        uploadFileName = sanitizeKnowledgeFileName(fileName),
        displayName = sanitizeKnowledgeFileName(fileName),
        displayMimeType = mimeType,
        displaySizeBytes = sizeBytes,
        ingestionMode = if (isXlsx) {
            SkillKnowledgeIngestionMode.EXTRACTED_TEXT
        } else {
            SkillKnowledgeIngestionMode.NATIVE_FILE
        },
        extractedFrom = if (isXlsx) SkillKnowledgeExtractedFrom.XLSX else null,
    )
}

fun SkillKnowledgeBase?.normalizeForComparison(): SkillKnowledgeBase? =
    this?.copy(
        files = files
            .map { it.normalizeTransientStatusForComparison() }
            .sortedBy { it.id },
        updatedAt = null,
    )

private fun SkillKnowledgeBaseFile.normalizeTransientStatusForComparison(): SkillKnowledgeBaseFile =
    if (status == SkillKnowledgeFileStatus.INDEXING) {
        copy(status = SkillKnowledgeFileStatus.READY, updatedAt = null)
    } else {
        copy(updatedAt = null)
    }
