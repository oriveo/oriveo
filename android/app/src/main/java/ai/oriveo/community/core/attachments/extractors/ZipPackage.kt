package ai.oriveo.community.core.attachments.extractors

import ai.oriveo.community.core.attachments.ExtractionDeadline
import ai.oriveo.community.core.attachments.ExtractionErrorCode
import ai.oriveo.community.core.attachments.ExtractionException
import ai.oriveo.community.core.util.InputSizeLimitExceededException
import ai.oriveo.community.core.util.readBytesLimited
import java.io.ByteArrayInputStream
import java.util.zip.ZipInputStream

/**
 * Zip reader shared by OOXML / ODF / EPUB: on open, walk once and record all entry names, then read entries on demand (cached after reading).
 * Decompression budgets reuse [archiveTotalBudgetBytes] / [archiveEntryBudgetBytes] (attachment extraction spec section 15),
 * and the deadline is checked once per zip entry walked (section 14).
 */
internal class ZipPackage private constructor(
    private val data: ByteArray,
    private val deadline: ExtractionDeadline,
    private val label: String,
) {
    /** All entry names (including directory entries), in zip order. */
    val names: List<String>

    private val nameSet: Set<String>
    private val cache = HashMap<String, ByteArray>()
    private var totalBytes = 0L
    private val totalBudget = archiveTotalBudgetBytes()
    private val entryBudget = archiveEntryBudgetBytes()

    init {
        val collected = ArrayList<String>()
        walk { name, _ ->
            collected += name
            false
        }
        names = collected
        nameSet = collected.toHashSet()
    }

    /** Section 4A: match entries exactly first, then case-insensitively; returns null if not found. */
    fun find(path: String): String? =
        path.takeIf { it in nameSet } ?: names.firstOrNull { it.equals(path, ignoreCase = true) }

    /** Read one entry (located via [find] first); returns null if it does not exist or is a directory. */
    fun read(path: String): ByteArray? {
        val name = find(path) ?: return null
        return readAll(listOf(name))[name]
    }

    /** Read several entries in one pass (located via [find]), returning actual entry name -> bytes. */
    fun readAll(paths: Collection<String>): Map<String, ByteArray> {
        val wanted = paths.mapNotNull(::find).toSet()
        val missing = wanted.filterTo(HashSet()) { it !in cache }
        if (missing.isNotEmpty()) {
            walk { name, isDirectory ->
                !isDirectory && name in missing && name !in cache
            }
        }
        return wanted.mapNotNull { name -> cache[name]?.let { name to it } }.toMap()
    }

    /** Walk the zip once; entries for which [want] returns true are read into the cache (subject to total and per-entry budgets). */
    private fun walk(want: (name: String, isDirectory: Boolean) -> Boolean) {
        try {
            ZipInputStream(ByteArrayInputStream(data)).use { zis ->
                var entry = zis.nextEntry
                var count = 0
                while (entry != null) {
                    deadline.check()
                    if (++count > MAX_ARCHIVE_ENTRY_COUNT) throw archiveTooLarge()
                    if (want(entry.name, entry.isDirectory)) {
                        val bytes = zis.readBytesLimited(minOf(entryBudget, totalBudget - totalBytes))
                        totalBytes += bytes.size
                        cache[entry.name] = bytes
                    }
                    zis.closeEntry()
                    entry = zis.nextEntry
                }
            }
        } catch (_: InputSizeLimitExceededException) {
            throw archiveTooLarge()
        }
    }

    private fun archiveTooLarge(): ExtractionException =
        ExtractionException(ExtractionErrorCode.FileTooLarge, "Expanded $label archive exceeds safety limits")

    companion object {
        /** Open the zip; if there is not a single entry (not a zip), report `corrupted_file`. */
        @Throws(ExtractionException::class)
        fun open(data: ByteArray, deadline: ExtractionDeadline, label: String): ZipPackage {
            val zip = ZipPackage(data, deadline, label)
            if (zip.names.isEmpty()) throw ExtractionException(ExtractionErrorCode.CorruptedFile)
            return zip
        }
    }
}

/** OOXML relationships (attachment extraction spec section 4A). */
internal class OoxmlRelationship(val id: String, val type: String, val target: String)

internal object OoxmlRelationships {
    /** The relationships file of part `a/b/c.xml` is `a/b/_rels/c.xml.rels`; the package root (empty string) is `_rels/.rels`. */
    fun relsPath(part: String): String {
        val dir = part.substringBeforeLast('/', "")
        val file = part.substringAfterLast('/')
        return if (dir.isEmpty()) "_rels/$file.rels" else "$dir/_rels/$file.rels"
    }

    /** Read the relationships of [part] (Target already resolved to an in-package path, External ignored); returns an empty table if there is no relationships file. */
    fun read(zip: ZipPackage, part: String): List<OoxmlRelationship> {
        val bytes = zip.read(relsPath(part)) ?: return emptyList()
        val root = XmlParts.tree(bytes)
        return root.elements("Relationship").mapNotNull { rel ->
            if (rel.attr("TargetMode")?.equals("External", ignoreCase = true) == true) return@mapNotNull null
            val target = rel.attr("Target") ?: return@mapNotNull null
            OoxmlRelationship(rel.attr("Id").orEmpty(), rel.attr("Type").orEmpty(), resolve(part, target))
        }
    }

    /** A relative path is resolved against the directory of the source part (handling `.` and `..`); a leading `/` is stripped for paths starting with `/`. */
    fun resolve(sourcePart: String, target: String): String {
        if (target.startsWith("/")) return target.trimStart('/')
        val segments = sourcePart.split('/').dropLast(1).filter { it.isNotEmpty() }.toMutableList()
        for (segment in target.split('/')) {
            when (segment) {
                "", "." -> Unit
                ".." -> if (segments.isNotEmpty()) segments.removeAt(segments.lastIndex)
                else -> segments += segment
            }
        }
        return segments.joinToString("/")
    }

    /** Target of the first relationship whose Type ends with [suffix]. */
    fun List<OoxmlRelationship>.targetOf(suffix: String): String? = firstOrNull { it.type.endsWith(suffix) }?.target

    /** The main part pointed to by the package root's officeDocument relationship; use [fallback] if not found. */
    fun mainPart(zip: ZipPackage, fallback: String): String =
        read(zip, "").targetOf("/officeDocument")?.takeIf { zip.find(it) != null } ?: fallback
}
