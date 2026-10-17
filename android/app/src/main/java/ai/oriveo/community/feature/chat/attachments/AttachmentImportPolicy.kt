package ai.oriveo.community.feature.chat.attachments

import android.content.ContentResolver
import android.net.Uri
import android.provider.OpenableColumns
import ai.oriveo.community.core.attachments.ExtractionFileKind
import ai.oriveo.community.core.attachments.ExtractionFileTypes
import ai.oriveo.community.core.attachments.MAX_MOBILE_ATTACHMENT_BYTES

object AttachmentImportPolicy {
    /**
     * Hard 25MB ceiling to keep the Android heap out of OOM territory.
     *
     * Base64 encoding a large file and then serializing it into JSON allocates several copies of
     * it at once, which is enough to get the process killed.
     */
    const val MAX_ATTACHMENT_BYTES = MAX_MOBILE_ATTACHMENT_BYTES

    private val videoExtensions = setOf(
        "mp4", "mov", "mpeg", "mpg", "avi", "flv", "webm", "wmv", "3gp",
    )

    private val supportedMimeTypes = setOf(
        "text/plain",
        "text/csv",
        "text/markdown",
        "text/html",
        "text/css",
        "text/xml",
        "text/javascript",
        "application/json",
        "application/xml",
        "application/javascript",
        "application/typescript",
        "application/x-yaml",
        "application/x-sh",
        "application/pdf",
        "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        "application/vnd.openxmlformats-officedocument.presentationml.presentation",
        "application/vnd.oasis.opendocument.text",
        "application/vnd.oasis.opendocument.spreadsheet",
        "application/vnd.oasis.opendocument.presentation",
        "application/rtf",
        "text/rtf",
        "application/epub+zip",
        "video/mp4",
        "video/mpeg",
        "video/quicktime",
        "video/x-msvideo",
        "video/x-flv",
        "video/webm",
        "video/x-ms-wmv",
        "video/3gpp",
    )

    /**
     * Used only by the "pick a video" entry point, which is launched only when the active model
     * reports video attachment support. No provider currently advertises it, so in practice this
     * is unreachable; it stays here so nothing has to be reconstructed when one does.
     */
    val videoPickerMimeTypes = arrayOf("video/*")

    /**
     * Mime allow list for the "pick a file" entry point, deliberately without video.
     *
     * It used to carry a video wildcard, so the file picker let the user choose a 25MB video, read
     * the whole thing, and only then reject it as an attachment conflict: 25MB of heap spent to
     * produce an error message.
     */
    val pickerMimeTypes = arrayOf(
        "application/pdf",
        "text/*",
        "application/json",
        "application/xml",
        "application/javascript",
        "application/typescript",
        "application/x-yaml",
        "application/x-sh",
        "application/rtf",
        "text/rtf",
        "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        "application/vnd.openxmlformats-officedocument.presentationml.presentation",
        "application/vnd.oasis.opendocument.text",
        "application/vnd.oasis.opendocument.spreadsheet",
        "application/vnd.oasis.opendocument.presentation",
        "application/epub+zip",
    )

    fun fileNameFor(contentResolver: ContentResolver, uri: Uri): String {
        val displayName = contentResolver.query(
            uri,
            arrayOf(OpenableColumns.DISPLAY_NAME),
            null,
            null,
            null,
        )?.use { cursor ->
            val index = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
            if (index >= 0 && cursor.moveToFirst()) cursor.getString(index) else null
        }

        return displayName
            ?.trim()
            ?.takeIf { it.isNotEmpty() }
            ?: uri.lastPathSegment
                ?.substringAfterLast('/')
                ?.trim()
                ?.takeIf { it.isNotEmpty() }
            ?: "file"
    }

    fun byteSizeFor(contentResolver: ContentResolver, uri: Uri): Long? {
        return contentResolver.query(
            uri,
            arrayOf(OpenableColumns.SIZE),
            null,
            null,
            null,
        )?.use { cursor ->
            val index = cursor.getColumnIndex(OpenableColumns.SIZE)
            if (index >= 0 && cursor.moveToFirst()) cursor.getLong(index).takeIf { it >= 0L } else null
        }
    }

    fun isWithinSizeLimit(byteCount: Long): Boolean =
        byteCount <= MAX_ATTACHMENT_BYTES

    /**
     * The megabyte figure shown in a size limit message. The unit stays in each language's string
     * (fr "Mo", ru "МБ"); only the number comes from here. A limit that is not a whole megabyte is
     * rounded down, since rounding up would state a size that cannot actually be attached, and the
     * result is at least 1.
     */
    fun sizeLimitMegabytes(bytes: Long): Int =
        (bytes / (1024L * 1024L)).coerceIn(1L, Int.MAX_VALUE.toLong()).toInt()

    fun isWithinSizeLimit(byteCount: Int): Boolean =
        isWithinSizeLimit(byteCount.toLong())

    fun isOversized(byteCount: Long?): Boolean =
        byteCount != null && !isWithinSizeLimit(byteCount)

    /**
     * Types other than video use the same classification function as the extractor (attachment extraction spec section 2: classify by extension if recognized,
     * only look at the mime if unknown or empty). Legacy formats are blocked first by the caller with a dedicated prompt and do not count as supported here.
     */
    fun isSupportedFile(fileName: String, detectedMimeType: String?): Boolean {
        val ext = fileExtension(fileName)
        if (videoExtensions.contains(ext)) return true
        val normalizedMime = normalizeMimeType(detectedMimeType)
        if (ext.isEmpty() && normalizedMime.startsWith("video/") && isSupportedMimeType(normalizedMime)) return true

        val kind = ExtractionFileTypes.classify(fileName, detectedMimeType)
        return kind != ExtractionFileKind.Unsupported && kind != ExtractionFileKind.Legacy
    }

    fun resolveMimeType(fileName: String, detectedMimeType: String?): String {
        val ext = fileExtension(fileName)
        if (ext.isNotEmpty()) {
            val byExtension = fallbackMimeType(ext)
            if (byExtension != OCTET_STREAM) return byExtension
        }

        val normalizedMime = normalizeMimeType(detectedMimeType)
        if (isSupportedMimeType(normalizedMime)) return normalizedMime
        // Not in the list but recognized as text by section 2 (text extensions, file names like Dockerfile, any text/*): hand to the extractor as plain text.
        return if (ExtractionFileTypes.classify(fileName, detectedMimeType) == ExtractionFileKind.Text) {
            "text/plain"
        } else {
            OCTET_STREAM
        }
    }

    fun fallbackMimeType(ext: String): String {
        return when (ext.lowercase()) {
            "txt", "log", "ini", "env", "sh", "bash", "zsh",
            "js", "ts", "jsx", "tsx", "py", "rb", "go", "rs",
            "java", "kt", "swift", "c", "cpp", "h", "hpp",
            "toml", "graphql", "proto", "sql" -> "text/plain"
            "csv" -> "text/csv"
            "md" -> "text/markdown"
            "json" -> "application/json"
            "xml" -> "application/xml"
            "html" -> "text/html"
            "css" -> "text/css"
            "yaml", "yml" -> "application/x-yaml"
            "pdf" -> "application/pdf"
            "docx" -> "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
            "xlsx" -> "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
            "pptx" -> "application/vnd.openxmlformats-officedocument.presentationml.presentation"
            "odt" -> "application/vnd.oasis.opendocument.text"
            "ods" -> "application/vnd.oasis.opendocument.spreadsheet"
            "odp" -> "application/vnd.oasis.opendocument.presentation"
            "rtf" -> "application/rtf"
            "epub" -> "application/epub+zip"
            "mp4" -> "video/mp4"
            "mov" -> "video/quicktime"
            "mpeg", "mpg" -> "video/mpeg"
            "avi" -> "video/x-msvideo"
            "flv" -> "video/x-flv"
            "webm" -> "video/webm"
            "wmv" -> "video/x-ms-wmv"
            "3gp" -> "video/3gpp"
            else -> OCTET_STREAM
        }
    }

    private const val OCTET_STREAM = "application/octet-stream"

    private fun fileExtension(fileName: String): String =
        fileName.substringAfterLast('.', "").lowercase()

    private fun normalizeMimeType(mimeType: String?): String =
        mimeType?.trim()?.lowercase().orEmpty()

    private fun isSupportedMimeType(mimeType: String): Boolean {
        if (mimeType.isEmpty()) return false
        return supportedMimeTypes.contains(mimeType)
    }
}
