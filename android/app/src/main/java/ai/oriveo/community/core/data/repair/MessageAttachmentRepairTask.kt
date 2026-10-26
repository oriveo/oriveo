package ai.oriveo.community.core.data.repair

import android.util.Log
import ai.oriveo.community.core.attachments.AttachmentSlimmer
import ai.oriveo.community.core.data.attachment.AttachmentStore
import ai.oriveo.community.core.data.dao.MessageDao
import ai.oriveo.community.core.data.dao.PreferenceDao
import ai.oriveo.community.core.data.entity.OversizedAttachmentsJsonRow
import ai.oriveo.community.core.data.entity.PreferenceEntity
import ai.oriveo.community.core.data.repository.streaming.StreamingImageProcessor
import ai.oriveo.community.core.model.Attachment
import ai.oriveo.community.core.model.AttachmentKind
import ai.oriveo.community.core.provider.MessageBuilder
import ai.oriveo.community.core.util.generateUuidString
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

class MessageAttachmentRepairTask(
    private val messageDao: MessageDao,
    private val preferenceDao: PreferenceDao,
    private val attachmentStore: AttachmentStore,
    private val chunkSizeChars: Int = CHUNK_SIZE_CHARS,
) {
    private val json = Json { ignoreUnknownKeys = true; coerceInputValues = true }

    suspend fun runIfNeeded() {
        repairAttachmentsIfNeeded()
        repairInlineImageTextIfNeeded()
    }

    private suspend fun repairAttachmentsIfNeeded() {
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

    /**
     * Second kind of corrupt row: a streaming partial wrote a generated image that the upstream inlined in the text (`![](data:image/...;base64,...)`)
     * verbatim into `messages.text`; one image pushes the whole row past the CursorWindow, generation then fails and the inline-image extraction on completion never runs.
     * Reads the text in chunks, saves complete images as attachments, strips truncated ones, and writes text and attachment metadata back together.
     * Has its own completion marker separate from the attachment repair: existing installs already wrote that marker, and it must not skip this pass.
     */
    private suspend fun repairInlineImageTextIfNeeded() {
        try {
            if (preferenceDao.get(TEXT_PREF_KEY) == PREF_DONE_VALUE) return
            val failedRows = withContext(Dispatchers.IO) {
                var failures = 0
                for (row in messageDao.findOversizedInlineImageTextRows(TEXT_THRESHOLD_CHARS)) {
                    runCatching { repairTextRow(row) }.onFailure { error ->
                        failures++
                        Log.e(TAG, "repair text row ${row.id} failed: ${error.message}", error)
                        reportError(error)
                    }
                }
                failures
            }
            if (failedRows == 0) {
                preferenceDao.set(PreferenceEntity(TEXT_PREF_KEY, PREF_DONE_VALUE))
            } else {
                Log.w(TAG, "$failedRows text row(s) failed to repair; will retry on next launch")
            }
        } catch (error: Exception) {
            Log.e(TAG, "inline image text repair aborted: ${error.message}", error)
            reportError(error)
        }
    }

    private suspend fun repairTextRow(row: OversizedAttachmentsJsonRow) {
        val text = readChunked(row.len) { start, length -> messageDao.readTextChunk(row.accountId, row.id, start, length) }
            ?: return
        val existingJson = messageDao.attachmentsJsonLength(row.accountId, row.id)?.let { len ->
            readChunked(len) { start, length -> messageDao.readAttachmentsJsonChunk(row.accountId, row.id, start, length) }
        }
        val existing = existingJson?.let { raw ->
            runCatching { json.decodeFromString<List<Attachment>>(raw) }.getOrNull()
        }.orEmpty()
        val (cleaned, inlineImages) = MessageBuilder.extractInlineImages(text)
        val extracted = inlineImages.map { (mime, data) ->
            slimOne(
                Attachment(
                    id = generateUuidString(),
                    kind = AttachmentKind.Image,
                    fileName = "inline_image",
                    mimeType = mime,
                    base64Data = data,
                ),
            )
        }
        // If saving fails (disk full, etc.) the whole row is left for a retry on next launch; the images must not be removed from the text first. Undecodable base64 has nothing worth keeping.
        check(extracted.none { it.base64Data != null }) { "inline image save failed" }
        val savedImages = extracted.filter { it.localImageId != null }
        val repairedText = StreamingImageProcessor.stripInlineImageData(cleaned)
        val merged = existing.map { slimOne(it) } + savedImages
        val mergedJson = if (merged.isEmpty()) existingJson else json.encodeToString(merged)
        messageDao.updateTextAndAttachmentsJson(row.accountId, row.id, repairedText, mergedJson)
    }

    private suspend fun readChunked(totalLen: Int, readChunk: suspend (start: Int, length: Int) -> String?): String? {
        if (totalLen <= 0) return null
        val builder = StringBuilder(totalLen)
        var start = 1
        while (start <= totalLen) {
            val chunk = readChunk(start, chunkSizeChars)
            if (chunk.isNullOrEmpty()) break
            builder.append(chunk)
            start += chunkSizeChars
        }
        return builder.toString()
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
                saveImage = { bytes -> attachmentStore.saveOriginalImage(bytes) },
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

        /** Text length above which a row may carry inline generated images: far below the CursorWindow limit; ordinary long answers rarely exceed it, and the row must also contain a data URI. */
        const val TEXT_THRESHOLD_CHARS = 200_000

        const val PREF_KEY = "attachment_row_repair_v1"
        const val TEXT_PREF_KEY = "message_text_inline_image_repair_v1"
        const val PREF_DONE_VALUE = "done"
    }
}
