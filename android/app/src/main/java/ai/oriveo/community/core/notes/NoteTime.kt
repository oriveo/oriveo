package ai.oriveo.community.core.notes

import java.time.Instant
import java.time.ZoneOffset
import java.time.temporal.ChronoUnit

object NoteTime {

    fun nowIso(): String = Instant.now().truncatedTo(ChronoUnit.MILLIS).toString()

    fun millisToIso(millis: Long): String =
        Instant.ofEpochMilli(millis).truncatedTo(ChronoUnit.MILLIS).toString()

    fun isoToMillisOrNull(iso: String?): Long? =
        if (iso.isNullOrBlank()) null else runCatching { Instant.parse(iso).toEpochMilli() }.getOrNull()

    fun isoNewer(remote: String?, local: String?): Boolean {
        val r = isoToMillisOrNull(remote) ?: return false
        val l = isoToMillisOrNull(local) ?: return true
        return r > l
    }

    fun isoToDate(iso: String?): String {
        val millis = isoToMillisOrNull(iso) ?: return ""
        return Instant.ofEpochMilli(millis).atOffset(ZoneOffset.UTC).toLocalDate().toString()
    }
}
