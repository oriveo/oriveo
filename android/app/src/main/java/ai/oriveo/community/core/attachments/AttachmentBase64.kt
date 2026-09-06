package ai.oriveo.community.core.attachments

import java.io.ByteArrayOutputStream
import java.util.Base64

private val NATIVE_CAPABLE_MIMES = setOf(
    "application/pdf",
    "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
    "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
    "application/vnd.openxmlformats-officedocument.presentationml.presentation",
    "application/rtf",
    "text/rtf",
    "application/vnd.oasis.opendocument.text",
    "application/vnd.oasis.opendocument.spreadsheet",
    "application/vnd.oasis.opendocument.presentation",
)

fun shouldPersistOriginalBase64(mime: String): Boolean {
    return mime.lowercase() in NATIVE_CAPABLE_MIMES
}

fun streamingBase64(bytes: ByteArray): String {
    return ByteArrayOutputStream(bytes.size * 4 / 3 + 16).use { out ->
        Base64.getEncoder().wrap(out).use { it.write(bytes) }
        out.toString("US-ASCII")
    }
}
