package ai.oriveo.community.feature.chat.attachments

import android.content.ContentResolver
import android.net.Uri
import android.provider.OpenableColumns
import ai.oriveo.community.core.attachments.MAX_MOBILE_ATTACHMENT_BYTES

object AttachmentImportPolicy {
    /**
     * Hard 25MB ceiling to keep the Android heap out of OOM territory.
     *
     * Base64 encoding a large file and then serializing it into JSON allocates several copies of
     * it at once, which is enough to get the process killed.
     */
    const val MAX_ATTACHMENT_BYTES = MAX_MOBILE_ATTACHMENT_BYTES

    private val textExtensions = setOf(
        "txt", "csv", "md", "json", "xml", "html", "css",
        "js", "ts", "jsx", "tsx", "py", "rb", "go", "rs",
        "java", "kt", "swift", "c", "cpp", "h", "hpp",
        "sh", "bash", "zsh", "yaml", "yml", "toml", "ini",
        "env", "log", "sql", "graphql", "proto",
    )

    private val officeExtensions = setOf(
        "docx", "xlsx", "pptx", "odt", "ods", "odp", "rtf",
        "epub",
    )

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
        "application/epub+zip",   // Phase 3 
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

    fun isWithinSizeLimit(byteCount: Int): Boolean =
        isWithinSizeLimit(byteCount.toLong())

    fun isOversized(byteCount: Long?): Boolean =
        byteCount != null && !isWithinSizeLimit(byteCount)

    fun isSupportedFile(fileName: String, detectedMimeType: String?): Boolean {
        val ext = fileExtension(fileName)
        if (ext.isNotEmpty()) {
            return ext == "pdf" || textExtensions.contains(ext) || officeExtensions.contains(ext) || videoExtensions.contains(ext)
        }

        return isSupportedMimeType(normalizeMimeType(detectedMimeType))
    }

    fun resolveMimeType(fileName: String, detectedMimeType: String?): String {
        val ext = fileExtension(fileName)
        if (ext.isNotEmpty()) {
            return fallbackMimeType(ext)
        }

        val normalizedMime = normalizeMimeType(detectedMimeType)
        return if (isSupportedMimeType(normalizedMime)) normalizedMime else "application/octet-stream"
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
            else -> "application/octet-stream"
        }
    }

    private fun fileExtension(fileName: String): String =
        fileName.substringAfterLast('.', "").lowercase()

    private fun normalizeMimeType(mimeType: String?): String =
        mimeType?.trim()?.lowercase().orEmpty()

    private fun isSupportedMimeType(mimeType: String): Boolean {
        if (mimeType.isEmpty()) return false
        return supportedMimeTypes.contains(mimeType)
    }
}
