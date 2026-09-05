package ai.oriveo.community.core.data.repair

import android.util.Log
import ai.oriveo.community.core.attachments.AttachmentSlimmer
import ai.oriveo.community.core.data.attachment.AttachmentStore
import ai.oriveo.community.core.data.dao.MessageDao
import ai.oriveo.community.core.data.dao.PreferenceDao
import ai.oriveo.community.core.data.entity.OversizedAttachmentsJsonRow
import ai.oriveo.community.core.data.entity.PreferenceEntity
import ai.oriveo.community.core.model.Attachment
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json


class MessageAttachmentRepairTask(
    private val messageDao: MessageDao,
    private val preferenceDao: PreferenceDao,
    private val attachmentStore: AttachmentStore,
) {
    private val json = Json { ignoreUnknownKeys = true; coerceInputValues = true }

    suspend fun runIfNeeded() {
        try {
            if (preferenceDao.get(PREF_KEY) == PREF_DONE_VALUE) return
            val failedRows = withContext(Dispatchers.IO) {
                var failures = 0
                val oversizedRows = messageDao.findOversizedAttachmentsJsonRows(ATTACHMENTS_THRESHOLD_CHARS)
                for (row in oversizedRows) {
                    runCatching { repairRow(row) }.onFailure { error ->
                        failures++
                        Log.e(TAG, "repair row ${row.id} failed: ${error.message}", error)
                        reportError(error)
                    }
                }
                failures
            }
            
            
            if (failedRows == 0) {
                preferenceDao.set(PreferenceEntity(PREF_KEY, PREF_DONE_VALUE))
            } else {
                Log.w(TAG, "$failedRows row(s) failed to repair; will retry on next launch")
            }
        } catch (error: Exception) {
            
            Log.e(TAG, "attachment repair task aborted: ${error.message}", error)
            reportError(error)
        }
    }

    private suspend fun repairRow(row: OversizedAttachmentsJsonRow) {
        val raw = readFullChunked(row.accountId, row.id, row.len) ?: return
        val repaired = repairAttachmentsJson(raw)
        messageDao.updateAttachmentsJson(row.accountId, row.id, repaired)
    }

    private suspend fun readFullChunked(accountId: String, id: String, totalLen: Int): String? {
        if (totalLen <= 0) return null
        val builder = StringBuilder(totalLen)
        // SQLite substr 1-indexed
        var start = 1
        while (start <= totalLen) {
            val chunk = messageDao.readAttachmentsJsonChunk(accountId, id, start, CHUNK_SIZE_CHARS)
            if (chunk.isNullOrEmpty()) break
            builder.append(chunk)
            start += CHUNK_SIZE_CHARS
        }
        return builder.toString()
    }

    
    internal suspend fun repairAttachmentsJson(raw: String): String? {
        val attachments = runCatching { json.decodeFromString<List<Attachment>>(raw) }.getOrNull()
            ?: return null
        if (attachments.isEmpty()) return raw
        val slimmed = attachments.map { attachment -> slimOne(attachment) }
        return runCatching { json.encodeToString(slimmed) }.getOrDefault(null)
    }

    private suspend fun slimOne(attachment: Attachment): Attachment =
        runCatching {
            AttachmentSlimmer.slim(
                attachment = attachment,
                saveImage = { bytes -> attachmentStore.saveImage(bytes, attachment.mimeType) },
                saveBlob = { bytes -> attachmentStore.saveBlob(bytes) },
            )
        }.getOrDefault(attachment)

    private fun reportError(error: Throwable) {
        runCatching {
        }
    }

    companion object {
        private const val TAG = "AttachmentRowRepair"

        
        const val ATTACHMENTS_THRESHOLD_CHARS = 200_000

        
        const val CHUNK_SIZE_CHARS = 200_000

        const val PREF_KEY = "attachment_row_repair_v1"
        const val PREF_DONE_VALUE = "done"
    }
}
