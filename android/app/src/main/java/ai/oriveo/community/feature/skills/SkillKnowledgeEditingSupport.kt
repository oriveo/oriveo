package ai.oriveo.community.feature.skills

import ai.oriveo.community.core.model.SkillKnowledgeErrorCode
import ai.oriveo.community.core.model.SkillKnowledgeFile
import ai.oriveo.community.core.model.SkillKnowledgeSourceType
import java.time.Instant
import java.util.UUID
import kotlin.math.max

const val MAX_REFERENCE_FILE_SIZE_BYTES = 3L * 1024 * 1024
const val MAX_KNOWLEDGE_FILE_NAME_LENGTH = 120

/** How many reference files one skill may carry. */
const val MAX_REFERENCE_FILES = 5

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
