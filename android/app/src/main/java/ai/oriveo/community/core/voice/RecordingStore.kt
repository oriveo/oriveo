package ai.oriveo.community.core.voice

import android.content.Context
import java.io.File
import java.security.MessageDigest
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/** Slot status, stored in the sidecar as lowercase text. */
@Serializable
enum class RecordingSlotStatus {
    @SerialName("recording") Recording,
    @SerialName("ready") Ready,
    @SerialName("interrupted") Interrupted,
    @SerialName("failed") Failed,
}

/** The `.json` sidecar named like the `.aac`; createdAt is epoch milliseconds; an older sidecar without primingFrames uses [RecordingWriter.DEFAULT_PRIMING_FRAMES]. */
@Serializable
data class RecordingSlotMeta(
    val slotKey: String,
    val createdAt: Long,
    val status: RecordingSlotStatus,
    val durationSec: Double,
    val envelope: List<Double?>,
    val engine: String,
    val primingFrames: Int = RecordingWriter.DEFAULT_PRIMING_FRAMES,
)

class RecordingSlotOccupiedException(val slotKey: String) : IllegalStateException("recording slot occupied: $slotKey")

/** Startup sweep result: number deleted as expired, number lost (sidecar present, audio missing), and number recovered as interrupted after a crash. */
data class RecordingSweepResult(val expired: Int, val lost: Int, val recovered: Int)

/** Discard result: when undoable is true the files are in the recycle area, waiting for the caller to call [RecordingStore.commitDiscard] or [RecordingStore.undoDiscard]. */
data class RecordingDiscardResult(val slotKey: String, val undoable: Boolean)

/**
 * Store for slots awaiting transcription: one slot per conversation / home draft; recordings are persisted as they are captured and deleted only on successful transcription or discard.
 * File name = lowercase hex of SHA-256(key); the `.aac` is written frame by frame by [RecordingWriter] and the `.json` sidecar is replaced atomically.
 * Recordings longer than 5 seconds go to the `discarded/` recycle area when discarded and can be undone. The whole voice/ directory is excluded from backups.
 * Whenever a slot leaves the root directory (success / discard / expiry) the sidecar is handled before the audio, so a kill midway never leaves "sidecar present, audio missing" that would be misjudged as lost.
 * [onLost] is called once, with the lost count, only when [sweepOnLaunch] finds lost recordings.
 */
class RecordingStore(
    val root: File,
    private val clock: () -> Long = System::currentTimeMillis,
    private val onLost: (Int) -> Unit = {},
    private val decoder: AacDecoder = MediaCodecAacDecoder(),
) {
    private val discardedDir = File(root, DISCARDED_DIR)

    /** Opens a slot: creates the `.aac` and a sidecar in recording status and returns a write handle; if the key already has a slot, throws [RecordingSlotOccupiedException]. */
    @Synchronized
    fun open(slotKey: String, engine: String, encoder: AacEncoder): RecordingSlot {
        val audio = audioFile(slotKey)
        val sidecar = sidecarFile(slotKey)
        if (audio.exists() || sidecar.exists()) {
            encoder.release()
            throw RecordingSlotOccupiedException(slotKey)
        }
        root.mkdirs()
        val writer = try {
            RecordingWriter(audio, encoder)
        } catch (error: Throwable) {
            encoder.release()
            throw error
        }
        val meta = RecordingSlotMeta(
            slotKey = slotKey,
            createdAt = clock(),
            status = RecordingSlotStatus.Recording,
            durationSec = 0.0,
            envelope = emptyList(),
            engine = engine,
            primingFrames = writer.primingFrames,
        )
        try {
            writeSidecar(sidecar, meta)
        } catch (error: Throwable) {
            writer.close()
            audio.delete()
            throw error
        }
        return RecordingSlot(this, meta, audio, writer)
    }

    fun audioFile(slotKey: String): File = File(root, fileStem(slotKey) + AUDIO_EXTENSION)

    fun sidecarFile(slotKey: String): File = File(root, fileStem(slotKey) + SIDECAR_EXTENSION)

    @Synchronized
    fun read(slotKey: String): RecordingSlotMeta? = readSidecar(sidecarFile(slotKey))

    @Synchronized
    fun isOccupied(slotKey: String): Boolean = audioFile(slotKey).exists() || sidecarFile(slotKey).exists()

    /** Changes the status (interrupted / failed etc.) and leaves other fields alone; returns false if the slot does not exist. */
    @Synchronized
    fun updateStatus(slotKey: String, status: RecordingSlotStatus): Boolean {
        val sidecar = sidecarFile(slotKey)
        val meta = readSidecar(sidecar) ?: return false
        writeSidecar(sidecar, meta.copy(status = status))
        return true
    }

    /** Recording interrupted: marks the sidecar interrupted, which stays interrupted after reopening; returns false if the slot does not exist. */
    fun markInterrupted(slotKey: String): Boolean = updateStatus(slotKey, RecordingSlotStatus.Interrupted)

    /** Slot is older than 7 days (the startup sweep deletes it as expired, and reads at runtime also treat it as expired); the threshold is defined only by [DictationRules.isPendingExpired]. */
    fun isExpired(meta: RecordingSlotMeta, now: Long = clock()): Boolean =
        DictationRules.isPendingExpired((now - meta.createdAt) / MILLIS_PER_SECOND)

    /** Transcription succeeded: deletes the sidecar first, then the `.aac`. */
    @Synchronized
    fun complete(slotKey: String) {
        sidecarFile(slotKey).delete()
        audioFile(slotKey).delete()
    }

    /**
     * Startup sweep: clears leftovers in the recycle area and half-written temp files; deletes slots older than 7 days and counts them as expired; counts a slot with sidecar present but audio missing as lost and removes the sidecar;
     * orphan audio without a sidecar and unparseable sidecars are removed without counting; a sidecar still in recording status (interrupted by a crash) gets its duration filled in from the audio,
     * its envelope recomputed by decoding, and is switched to interrupted. If decoding fails the envelope is left empty without blocking recovery (transcription then falls back to hard-cut segments).
     */
    @Synchronized
    fun sweepOnLaunch(): RecordingSweepResult {
        discardedDir.deleteRecursively()
        val files = root.listFiles()?.filter { it.isFile } ?: emptyList()
        files.filter { it.name.endsWith(TEMP_SUFFIX) }.forEach { it.delete() }
        val now = clock()
        var expired = 0
        var lost = 0
        var recovered = 0
        for (sidecar in files.filter { it.name.endsWith(SIDECAR_EXTENSION) }) {
            val audio = File(root, sidecar.name.removeSuffix(SIDECAR_EXTENSION) + AUDIO_EXTENSION)
            val meta = readSidecar(sidecar)
            when {
                meta == null -> {
                    sidecar.delete()
                    audio.delete()
                }
                isExpired(meta, now) -> {
                    sidecar.delete()
                    audio.delete()
                    expired++
                }
                !audio.exists() -> {
                    sidecar.delete()
                    lost++
                }
                meta.status == RecordingSlotStatus.Recording -> {
                    val stream = AdtsFormat.parse(audio.readBytes())
                    // Same basis as the PCM duration of a normally finished recording: subtract the encoder priming frames.
                    val sampleRate = stream.sampleRate
                    val recoveredSamples = if (sampleRate == null) {
                        0L
                    } else {
                        (stream.frames.size.toLong() * AdtsStream.SAMPLES_PER_FRAME - meta.primingFrames).coerceAtLeast(0L)
                    }
                    val recoveredSec = if (sampleRate == null) 0.0 else recoveredSamples.toDouble() / sampleRate
                    val envelope = if (sampleRate == null) {
                        emptyList()
                    } else {
                        recoverEnvelope(audio, sampleRate, meta.primingFrames, recoveredSamples)
                    }
                    writeSidecar(
                        sidecar,
                        meta.copy(
                            status = RecordingSlotStatus.Interrupted,
                            durationSec = recoveredSec,
                            envelope = envelope,
                        ),
                    )
                    recovered++
                }
            }
        }
        for (audio in files.filter { it.name.endsWith(AUDIO_EXTENSION) }) {
            val sidecar = File(root, audio.name.removeSuffix(AUDIO_EXTENSION) + SIDECAR_EXTENSION)
            if (!sidecar.exists()) audio.delete()
        }
        if (lost > 0) onLost(lost)
        return RecordingSweepResult(expired = expired, lost = lost, recovered = recovered)
    }

    /** Discard: moves the slot to the recycle area (undoable) if duration > 5 s, otherwise deletes it directly; returns null if the slot does not exist. */
    @Synchronized
    fun discard(slotKey: String): RecordingDiscardResult? {
        val audio = audioFile(slotKey)
        val sidecar = sidecarFile(slotKey)
        if (!audio.exists() && !sidecar.exists()) return null
        val duration = readSidecar(sidecar)?.durationSec ?: 0.0
        if (!DictationRules.shouldOfferDiscardUndo(duration)) {
            sidecar.delete()
            audio.delete()
            return RecordingDiscardResult(slotKey, undoable = false)
        }
        discardedDir.mkdirs()
        val binAudio = File(discardedDir, audio.name)
        val binSidecar = File(discardedDir, sidecar.name)
        binAudio.delete()
        binSidecar.delete()
        val moved = (!sidecar.exists() || sidecar.renameTo(binSidecar)) && (!audio.exists() || audio.renameTo(binAudio))
        if (!moved) {
            sidecar.delete()
            audio.delete()
            binAudio.delete()
            binSidecar.delete()
            return RecordingDiscardResult(slotKey, undoable = false)
        }
        return RecordingDiscardResult(slotKey, undoable = true)
    }

    /** Undo discard: moves it back as it was; returns false if the recycle area no longer has the slot or the original spot has been taken by a new slot. */
    @Synchronized
    fun undoDiscard(slotKey: String): Boolean {
        val audio = audioFile(slotKey)
        val sidecar = sidecarFile(slotKey)
        val binAudio = File(discardedDir, audio.name)
        val binSidecar = File(discardedDir, sidecar.name)
        if (!binAudio.exists() && !binSidecar.exists()) return false
        if (audio.exists() || sidecar.exists()) return false
        val restored = (!binAudio.exists() || binAudio.renameTo(audio)) && (!binSidecar.exists() || binSidecar.renameTo(sidecar))
        return restored
    }

    /** Undo window ended: removes this slot from the recycle area, after which undo no longer works. */
    @Synchronized
    fun commitDiscard(slotKey: String) {
        File(discardedDir, audioFile(slotKey).name).delete()
        File(discardedDir, sidecarFile(slotKey).name).delete()
    }

    @Synchronized
    internal fun finalizeSlot(slot: RecordingSlot, status: RecordingSlotStatus) {
        val sidecar = sidecarFile(slot.slotKey)
        val current = readSidecar(sidecar) ?: slot.initialMeta
        writeSidecar(
            sidecar,
            current.copy(
                status = status,
                durationSec = slot.writer.durationSec,
                envelope = slot.writer.envelope,
                primingFrames = slot.writer.primingFrames,
            ),
        )
    }

    /**
     * Recomputes the envelope of a crash-interrupted recording by decoding: skips the first [primingFrames] samples, then splits into 50 ms windows (aligned with the recording timeline of a normally finished recording),
     * taking at most [totalSamples] samples so the window count matches the recovered duration. Returns an empty envelope if decoding fails.
     */
    private fun recoverEnvelope(audio: File, sampleRate: Int, primingFrames: Int, totalSamples: Long): List<Double?> {
        if (totalSamples <= 0L) return emptyList()
        val accumulator = EnvelopeAccumulator(sampleRate)
        var skipped = 0L
        var taken = 0L
        var lowByte = -1
        return try {
            decoder.decode(audio, null) { bytes ->
                for (byte in bytes) {
                    if (lowByte < 0) {
                        lowByte = byte.toInt() and 0xFF
                        continue
                    }
                    val sample = ((byte.toInt() shl 8) or lowByte).toShort()
                    lowByte = -1
                    if (skipped < primingFrames) {
                        skipped++
                    } else {
                        accumulator.add(sample)
                        taken++
                        if (taken >= totalSamples) return@decode false
                    }
                }
                true
            }
            accumulator.envelope
        } catch (error: Exception) {
            emptyList()
        }
    }

    private fun readSidecar(file: File): RecordingSlotMeta? {
        if (!file.exists()) return null
        return runCatching { json.decodeFromString(RecordingSlotMeta.serializer(), file.readText()) }.getOrNull()
    }

    private fun writeSidecar(file: File, meta: RecordingSlotMeta) {
        val temp = File(file.parentFile, file.name + TEMP_SUFFIX)
        temp.writeText(json.encodeToString(RecordingSlotMeta.serializer(), meta))
        if (!temp.renameTo(file)) {
            temp.delete()
            error("failed to write recording sidecar ${file.name}")
        }
    }

    companion object {
        const val HOME_DRAFT_KEY = "draft:home"
        const val DISCARDED_DIR = "discarded"
        const val AUDIO_EXTENSION = ".aac"
        const val SIDECAR_EXTENSION = ".json"
        private const val TEMP_SUFFIX = ".tmp"

        private const val MILLIS_PER_SECOND = 1000.0
        private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

        /** Production root directory `filesDir/voice/pending/`. */
        fun production(context: Context): RecordingStore = RecordingStore(File(context.filesDir, "voice/pending"))

        fun fileStem(slotKey: String): String =
            MessageDigest.getInstance("SHA-256").digest(slotKey.toByteArray(Charsets.UTF_8))
                .joinToString("") { "%02x".format(it) }
    }
}

/** Write handle after a slot is opened: feed PCM, and [finish] closes the file and writes the duration and envelope into the sidecar. */
class RecordingSlot internal constructor(
    private val store: RecordingStore,
    internal val initialMeta: RecordingSlotMeta,
    val audioFile: File,
    internal val writer: RecordingWriter,
) : PcmSink {
    val slotKey: String get() = initialMeta.slotKey

    val durationSec: Double get() = writer.durationSec

    override fun onPcm(samples: ShortArray, count: Int) = writer.onPcm(samples, count)

    fun write(samples: ShortArray, count: Int = samples.size) = writer.write(samples, count)

    /** Closes the file and finalizes the sidecar; defaults to ready, pass the matching status for interrupted / failed. */
    fun finish(status: RecordingSlotStatus = RecordingSlotStatus.Ready) {
        try {
            writer.close()
        } finally {
            store.finalizeSlot(this, status)
        }
    }
}
