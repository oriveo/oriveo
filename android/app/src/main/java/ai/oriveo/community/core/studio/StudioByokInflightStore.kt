package ai.oriveo.community.core.studio

import android.content.Context
import java.io.File
import java.io.IOException
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.put

/**
 * BYOK in-flight markers: one `<roundId>.json` per round written right before its request is sent and
 * deleted on a terminal state. A marker left behind means the process died mid-round; launch
 * reconciliation turns it into interrupted / failed_timeout via [StudioByokTasks.reconcile].
 * Default location `noBackupFilesDir/studio/byok-inflight`. All file IO runs on [Dispatchers.IO].
 */
class StudioByokInflightStore(private val dir: File) {
    constructor(context: Context) : this(File(context.applicationContext.noBackupFilesDir, DIR_PATH))

    private class Marker(val startedAtMs: Long, val timeoutSeconds: Int?)

    /** Atomically writes the marker; returns false for an invalid [roundId] or a failed write. */
    suspend fun mark(roundId: String, startedAtMs: Long, timeoutSeconds: Int?): Boolean {
        if (!isValidRoundId(roundId)) return false
        val text = buildJsonObject {
            put("startedAtMs", startedAtMs)
            put("timeoutSeconds", timeoutSeconds)
        }.toString()
        return withContext(Dispatchers.IO) {
            try {
                dir.mkdirs()
                val file = File(dir, roundId + SUFFIX)
                val tmp = File(dir, roundId + SUFFIX + TMP_SUFFIX)
                tmp.writeText(text, Charsets.UTF_8)
                Files.move(tmp.toPath(), file.toPath(), StandardCopyOption.REPLACE_EXISTING, StandardCopyOption.ATOMIC_MOVE)
                true
            } catch (_: IOException) {
                false
            }
        }
    }

    /** Deletes the marker of [roundId], if any. */
    suspend fun clear(roundId: String) {
        if (!isValidRoundId(roundId)) return
        withContext(Dispatchers.IO) { File(dir, roundId + SUFFIX).delete() }
    }

    /**
     * Reconciles and deletes every leftover marker, sorted by round id. Each one is a running round with
     * no response and no live transfer; an unreadable marker counts as interrupted. Leftover temp files
     * (the process died before the marker landed, so before the request was sent) are deleted silently.
     */
    suspend fun reconcileInterrupted(nowMs: Long): List<Pair<String, StudioByokTasks.ReconcileAction>> =
        withContext(Dispatchers.IO) {
            val entries = dir.listFiles() ?: return@withContext emptyList()
            val results = ArrayList<Pair<String, StudioByokTasks.ReconcileAction>>()
            for (file in entries.sortedBy { it.name }) {
                val name = file.name
                if (name.endsWith(SUFFIX + TMP_SUFFIX)) {
                    if (isValidRoundId(name.removeSuffix(SUFFIX + TMP_SUFFIX))) file.delete()
                    continue
                }
                if (!name.endsWith(SUFFIX)) continue
                val roundId = name.removeSuffix(SUFFIX)
                if (!isValidRoundId(roundId) || !file.isFile) continue
                val marker = readMarker(file)
                val action = if (marker == null) {
                    StudioByokTasks.ReconcileAction.INTERRUPTED
                } else {
                    StudioByokTasks.reconcile(
                        status = STATUS_RUNNING,
                        startedAtMs = marker.startedAtMs,
                        nowMs = nowMs,
                        timeoutSeconds = marker.timeoutSeconds,
                        responseReceived = false,
                        transferActive = false,
                    )
                }
                file.delete()
                results += roundId to action
            }
            results
        }

    private fun readMarker(file: File): Marker? {
        val text = try {
            file.readText(Charsets.UTF_8)
        } catch (_: IOException) {
            return null
        }
        val root = runCatching { Json.parseToJsonElement(text) }.getOrNull() as? JsonObject ?: return null
        val startedAtMs = (root["startedAtMs"] as? JsonPrimitive)?.takeIf { !it.isString }?.longOrNull ?: return null
        val timeoutSeconds = when (val raw = root["timeoutSeconds"]) {
            null, JsonNull -> null
            is JsonPrimitive -> raw.takeIf { !it.isString }?.intOrNull ?: return null
            else -> return null
        }
        return Marker(startedAtMs, timeoutSeconds)
    }

    companion object {
        const val DIR_PATH = "studio/byok-inflight"
        private const val SUFFIX = ".json"
        private const val TMP_SUFFIX = ".tmp"
        private const val STATUS_RUNNING = "running"
        private val ROUND_ID = Regex("[A-Za-z0-9_-]+")

        private fun isValidRoundId(roundId: String): Boolean = ROUND_ID.matches(roundId)
    }
}
