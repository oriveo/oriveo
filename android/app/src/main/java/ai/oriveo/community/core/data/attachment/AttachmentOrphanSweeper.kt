package ai.oriveo.community.core.data.attachment

import android.os.Process
import android.os.SystemClock
import android.util.Log
import ai.oriveo.community.core.data.dao.MessageDao
import ai.oriveo.community.core.model.Attachment
import ai.oriveo.community.core.util.normalizeUuid
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.coroutines.yield
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json

/**
 * The only place that deletes local attachment files.
 *
 * - The attachment directories (images / thumbnails / blobs) are shared by the whole device, so the reference set is
 *   read across **all** accounts: a key that another account or a conflict copy still references is always kept.
 * - Reference keys = an attachment's localImageId ∪ attachment.id ∪ rawContentRef, collecting both the raw and the
 *   normalised (upper-case UUID) form.
 * - If any part of the reference set fails to read (a paging error, an oversized row read incompletely, a JSON parse
 *   failure), nothing is deleted this round.
 * - The orphan sweep's grace period is measured from **this process's start time**: only files modified before
 *   "start time - [graceMillis]" are deleted, so a file written during this run (composer staging, generating,
 *   downloading) is never a candidate.
 * - At most [MAX_DELETIONS_PER_ROUND] deletions per round; more than [MASS_DELETION_MIN_CANDIDATES] orphan candidates
 *   that are over half of the stored keys count as abnormal and nothing is deleted this round.
 * - One log line per round: candidates / deleted / bytes (image + thumbnail + blob) / abort reason, with no file name
 *   or user content.
 * - Deletes files only: it writes no database rows. Everything runs on [ioDispatcher], at most [BATCH_SIZE] per
 *   batch, yielding between batches.
 */
class AttachmentOrphanSweeper(
    private val messageDao: MessageDao,
    private val attachmentStore: AttachmentStore,
    private val launchTimeMillis: () -> Long = ::processStartWallClockMillis,
    private val graceMillis: Long = DEFAULT_GRACE_MILLIS,
    private val ioDispatcher: CoroutineDispatcher = Dispatchers.IO,
    /** Sink for the per-round log line; tests inject one to assert the byte accounting. */
    private val log: (String) -> Unit = { line -> Log.i(TAG, line) },
) {
    private val json = Json { ignoreUnknownKeys = true; coerceInputValues = true }

    /**
     * Deletes the attachment files (image + thumbnail + blob) among the candidate keys that no message references any more.
     * Call it only after the transaction that deleted the message rows has committed. Returns the number of keys handled;
     * 0 when the reference set could not be read. Keys beyond the per-round cap are left for the next launch's orphan sweep.
     */
    suspend fun purgeUnreferencedAttachments(candidates: Collection<String>): Int = withContext(ioDispatcher) {
        val keys = candidates.filterTo(LinkedHashSet()) { isDeletableKey(it) }
        if (keys.isEmpty()) return@withContext 0
        val references = readReferenceKeys().getOrElse { error ->
            logRound(ROUND_PURGE, keys.size, 0, 0L, "references_unavailable:${error.javaClass.simpleName}")
            return@withContext 0
        }
        val unreferenced = keys.filterNot { isReferenced(it, references) }
        val (deleted, bytes) = deleteInBatches(unreferenced.take(MAX_DELETIONS_PER_ROUND))
        logRound(ROUND_PURGE, unreferenced.size, deleted, bytes, capReason(unreferenced.size))
        deleted
    }

    /**
     * Orphan sweep at launch: candidates = every key in the attachment directories - the reference set; avatars
     * ([AVATAR_PREFIX]) and files modified after "start time - [graceMillis]" are skipped (an attachment just written
     * whose message row is not in the database yet must not be deleted by mistake). Returns the number of keys handled.
     */
    suspend fun sweepOnLaunch(): Int = withContext(ioDispatcher) {
        val stored = runCatching { attachmentStore.listStoredKeys() }
            .onFailure { error -> if (error is CancellationException) throw error }
            .getOrElse { error ->
                logRound(ROUND_SWEEP, 0, 0, 0L, "listing_failed:${error.javaClass.simpleName}")
                return@withContext 0
            }
        val cutoff = launchTimeMillis() - graceMillis
        val aged = stored
            // An unreadable modification time (File.lastModified returns 0) is skipped, not treated as very old.
            .filter { it.lastModifiedMillis > 0L && it.lastModifiedMillis < cutoff && isDeletableKey(it.key) }
            .map { it.key }
        if (aged.isEmpty()) {
            logRound(ROUND_SWEEP, 0, 0, 0L, null)
            return@withContext 0
        }
        val references = readReferenceKeys().getOrElse { error ->
            logRound(ROUND_SWEEP, aged.size, 0, 0L, "references_unavailable:${error.javaClass.simpleName}")
            return@withContext 0
        }
        val orphans = aged.filterNot { isReferenced(it, references) }
        if (orphans.size > MASS_DELETION_MIN_CANDIDATES && orphans.size * 2 > stored.size) {
            logRound(ROUND_SWEEP, orphans.size, 0, 0L, "mass_deletion:stored=${stored.size}")
            return@withContext 0
        }
        val (deleted, bytes) = deleteInBatches(orphans.take(MAX_DELETIONS_PER_ROUND))
        logRound(ROUND_SWEEP, orphans.size, deleted, bytes, capReason(orphans.size))
        deleted
    }

    /** The reference set holds raw and normalised values; the candidate key is looked up in both forms, so the same UUID in a different case counts as referenced. */
    private fun isReferenced(key: String, references: Set<String>): Boolean =
        key in references || normalizeUuid(key) in references

    private fun isDeletableKey(key: String): Boolean =
        key.isNotBlank() && !key.startsWith(AVATAR_PREFIX) && AttachmentStore.isSafeImageId(key)

    private fun capReason(candidateCount: Int): String? =
        if (candidateCount > MAX_DELETIONS_PER_ROUND) "capped:$MAX_DELETIONS_PER_ROUND" else null

    private fun logRound(round: String, candidates: Int, deleted: Int, bytes: Long, abortReason: String?) {
        log("$round candidates=$candidates deleted=$deleted bytes=$bytes reason=${abortReason ?: "none"}")
    }

    /** Returns (keys handled, freed bytes of image + thumbnail + blob). */
    private suspend fun deleteInBatches(keys: List<String>): Pair<Int, Long> {
        var bytes = 0L
        keys.chunked(BATCH_SIZE).forEach { batch ->
            batch.forEach { key ->
                bytes += attachmentStore.imageSizeBytes(key) + attachmentStore.thumbnailSizeBytes(key) +
                    attachmentStore.blobSizeBytes(key)
                attachmentStore.delete(key)
                attachmentStore.deleteBlob(key)
            }
            yield()
        }
        return keys.size to bytes
    }

    /** The reference set across all accounts; any part failing to read returns a failure (the caller deletes nothing this round). */
    private suspend fun readReferenceKeys(): Result<Set<String>> = try {
        val references = HashSet<String>()
        var afterRowId = Long.MIN_VALUE
        while (true) {
            val page = messageDao.readAttachmentsJsonPageAllAccounts(afterRowId, OVERSIZED_THRESHOLD_CHARS, PAGE_SIZE)
            if (page.isEmpty()) break
            page.forEach { row -> collectReferences(row.attachmentsJson, references) }
            afterRowId = page.last().rowId
            if (page.size < PAGE_SIZE) break
            yield()
        }
        messageDao.findOversizedAttachmentsJsonRows(OVERSIZED_THRESHOLD_CHARS).forEach { row ->
            collectReferences(readFullChunked(row.accountId, row.id, row.len), references)
        }
        Result.success(references)
    } catch (error: CancellationException) {
        throw error
    } catch (error: Exception) {
        Result.failure(error)
    }

    private suspend fun readFullChunked(accountId: String, id: String, totalLen: Int): String {
        val builder = StringBuilder(totalLen.coerceAtLeast(0))
        var start = 1 // SQLite substr is 1-indexed
        while (start <= totalLen) {
            val chunk = messageDao.readAttachmentsJsonChunk(accountId, id, start, CHUNK_SIZE_CHARS)
            // An empty chunk before reaching the end reported by length() means the row changed concurrently or the read failed; treat it as a failed read.
            check(!chunk.isNullOrEmpty()) { "oversized attachmentsJson row read incompletely" }
            builder.append(chunk)
            start += CHUNK_SIZE_CHARS
        }
        return builder.toString()
    }

    /** A parse failure is thrown on purpose: without parsing we cannot know what the row references, so it counts as a failed read. */
    private fun collectReferences(raw: String, into: MutableSet<String>) {
        if (raw.isBlank()) return
        json.decodeFromString(ListSerializer(Attachment.serializer()), raw).forEach { attachment ->
            // Collect raw and normalised (upper-case UUID) forms: the on-disk key and the JSON may differ in case.
            listOfNotNull(attachment.id, attachment.localImageId, attachment.rawContentRef).forEach { key ->
                into += key
                into += normalizeUuid(key)
            }
        }
    }

    companion object {
        private const val TAG = "AttachmentOrphanSweeper"

        private const val ROUND_SWEEP = "orphan_sweep"
        private const val ROUND_PURGE = "purge"

        const val BATCH_SIZE = 200
        const val MAX_DELETIONS_PER_ROUND = 500
        const val MASS_DELETION_MIN_CANDIDATES = 200
        const val DEFAULT_GRACE_MILLIS = 24L * 60 * 60 * 1000
        const val AVATAR_PREFIX = "user-avatar-"

        /** Rows longer than this many characters are read in chunks instead of as a whole column (same threshold as MessageAttachmentRepairTask). */
        const val OVERSIZED_THRESHOLD_CHARS = 200_000
        const val CHUNK_SIZE_CHARS = 200_000
        private const val PAGE_SIZE = 200
    }
}

/** This process's start time (wall-clock milliseconds): the current wall clock minus how long the process has been running on the monotonic clock. */
private fun processStartWallClockMillis(): Long =
    System.currentTimeMillis() - (SystemClock.elapsedRealtime() - Process.getStartElapsedRealtime())
