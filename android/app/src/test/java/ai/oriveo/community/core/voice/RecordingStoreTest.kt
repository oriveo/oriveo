package ai.oriveo.community.core.voice

import java.io.File
import java.io.IOException
import java.security.MessageDigest
import kotlin.math.ceil
import kotlin.math.log10
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class RecordingStoreTest {
    /** The 7-day lifetime comes from DictationRules.PENDING_RETENTION_SEC (604800 s). */
    private val RETENTION_MILLIS = (DictationRules.PENDING_RETENTION_SEC * 1000).toLong()


    @get:Rule
    val temp = TemporaryFolder()

    /** Emits one 16-byte AU per 1024 samples. */
    private class FakeEncoder(override val encoderDelay: Int? = 2112) : AacEncoder {
        private var pending = 0
        private var index = 0

        override fun encode(samples: ShortArray, count: Int): List<AacEncodedUnit> {
            pending += count
            val out = mutableListOf<AacEncodedUnit>()
            while (pending >= 1024) {
                pending -= 1024
                out += unit()
            }
            return out
        }

        override fun finish(): List<AacEncodedUnit> {
            if (pending == 0) return emptyList()
            pending = 0
            return listOf(unit())
        }

        override fun release() = Unit

        private fun unit(): AacEncodedUnit {
            val i = index++
            return AacEncodedUnit(ByteArray(16) { (i * 7 + it).toByte() }, isCodecConfig = false)
        }
    }

    /** Fake decoder: converts the samples in [pcm] to little-endian bytes and feeds them in odd-sized chunks (to verify samples are stitched across chunks); when [failure] is set, feeds one chunk and then throws. */
    private class FakeDecoder(
        private val failure: IOException? = null,
        private val pcm: (File) -> ShortArray = { file ->
            ShortArray(AdtsFormat.parse(file.readBytes()).frames.size * AdtsStream.SAMPLES_PER_FRAME) { 1000 }
        },
    ) : AacDecoder {
        val calls = mutableListOf<Pair<File, ClosedFloatingPointRange<Double>?>>()

        override fun decode(file: File, range: ClosedFloatingPointRange<Double>?, sink: (ByteArray) -> Boolean) {
            calls += file to range
            val samples = pcm(file)
            val bytes = ByteArray(samples.size * 2)
            for ((i, sample) in samples.withIndex()) {
                bytes[2 * i] = (sample.toInt() and 0xFF).toByte()
                bytes[2 * i + 1] = (sample.toInt() shr 8).toByte()
            }
            var offset = 0
            while (offset < bytes.size) {
                val end = minOf(offset + 999, bytes.size)
                if (!sink(bytes.copyOfRange(offset, end))) return
                offset = end
                if (failure != null) throw failure
            }
        }
    }

    private fun store(root: File = File(temp.root, "voice/pending")) = RecordingStore(root, clock = { 1_700_000_000_000L })

    private fun record(store: RecordingStore, key: String, samples: Int): RecordingSlot {
        val slot = store.open(key, engine = "cloud", encoder = FakeEncoder())
        slot.write(ShortArray(samples) { if (it % 2 == 0) 1000 else -1000 })
        slot.finish()
        return slot
    }

    private fun sha256(text: String) =
        MessageDigest.getInstance("SHA-256").digest(text.toByteArray()).joinToString("") { "%02x".format(it) }

    @Test fun `open writes aac and sidecar named by sha256 of key`() {
        val store = store()
        val slot = store.open("conv-1", engine = "cloud", encoder = FakeEncoder())
        val stem = sha256("conv-1")
        val audio = File(store.root, "$stem.aac")
        val sidecar = File(store.root, "$stem.json")
        assertTrue(audio.exists())
        assertTrue(sidecar.exists())
        val opened = Json.parseToJsonElement(sidecar.readText()).jsonObject
        assertEquals("conv-1", opened["slotKey"]!!.jsonPrimitive.content)
        assertEquals("recording", opened["status"]!!.jsonPrimitive.content)
        assertEquals(1_700_000_000_000L, opened["createdAt"]!!.jsonPrimitive.content.toLong())
        assertEquals("cloud", opened["engine"]!!.jsonPrimitive.content)
        assertEquals(2112, opened["primingFrames"]!!.jsonPrimitive.content.toInt())

        slot.write(ShortArray(16_000) { 1000 })
        slot.finish()
        assertTrue(audio.length() > 0)
        val ready = Json.parseToJsonElement(sidecar.readText()).jsonObject
        assertEquals("ready", ready["status"]!!.jsonPrimitive.content)
        assertEquals(1.0, ready["durationSec"]!!.jsonPrimitive.content.toDouble(), 1e-9)
        assertEquals(20, ready["envelope"]!!.jsonArray.size)
    }

    @Test fun `complete deletes aac and sidecar`() {
        val store = store()
        val slot = record(store, RecordingStore.HOME_DRAFT_KEY, 16_000)
        val sidecar = store.sidecarFile(RecordingStore.HOME_DRAFT_KEY)
        assertTrue(slot.audioFile.exists())
        store.complete(RecordingStore.HOME_DRAFT_KEY)
        assertFalse(slot.audioFile.exists())
        assertFalse(sidecar.exists())
        assertFalse(store.isOccupied(RecordingStore.HOME_DRAFT_KEY))
    }

    @Test fun `opening an occupied key throws`() {
        val store = store()
        record(store, "conv-1", 1024)
        try {
            store.open("conv-1", engine = "cloud", encoder = FakeEncoder())
            fail("expected occupied")
        } catch (error: RecordingSlotOccupiedException) {
            assertEquals("conv-1", error.slotKey)
        }
        store.open("conv-2", engine = "cloud", encoder = FakeEncoder()).finish()
    }

    @Test fun `discard longer than five seconds goes to recycle bin and undo restores verbatim`() {
        val store = store()
        val slot = record(store, "conv-1", 80_001)
        val sidecar = store.sidecarFile("conv-1")
        val audioBytes = slot.audioFile.readBytes()
        val sidecarBytes = sidecar.readBytes()

        val result = store.discard("conv-1")
        assertNotNull(result)
        assertTrue(result!!.undoable)
        assertFalse(slot.audioFile.exists())
        assertFalse(sidecar.exists())
        assertTrue(File(store.root, "discarded/${slot.audioFile.name}").exists())

        assertTrue(store.undoDiscard("conv-1"))
        assertArrayEquals(audioBytes, slot.audioFile.readBytes())
        assertArrayEquals(sidecarBytes, sidecar.readBytes())
        assertEquals(RecordingSlotStatus.Ready, store.read("conv-1")!!.status)
    }

    @Test fun `commit discard makes undo ineffective`() {
        val store = store()
        val slot = record(store, "conv-1", 96_000)
        assertTrue(store.discard("conv-1")!!.undoable)
        store.commitDiscard("conv-1")
        assertFalse(store.undoDiscard("conv-1"))
        assertFalse(slot.audioFile.exists())
        assertFalse(File(store.root, "discarded/${slot.audioFile.name}").exists())
    }

    @Test fun `discard of exactly five seconds deletes without undo`() {
        val store = store()
        val slot = record(store, "conv-1", 80_000)
        assertEquals(5.0, store.read("conv-1")!!.durationSec, 0.0)
        val result = store.discard("conv-1")
        assertFalse(result!!.undoable)
        assertFalse(slot.audioFile.exists())
        assertFalse(store.sidecarFile("conv-1").exists())
        assertFalse(File(store.root, "discarded/${slot.audioFile.name}").exists())
        assertFalse(store.undoDiscard("conv-1"))
    }

    private class Launch(root: File, start: Long = 1_700_000_000_000L, val decoder: AacDecoder = FakeDecoder()) {
        var now = start
        val lostCalls = mutableListOf<Int>()
        val store = RecordingStore(root, clock = { now }, onLost = { lostCalls += it }, decoder = decoder)

        /** Simulates a restart: creates a new store on the same root, sharing the clock, lost-callback record and decoder. */
        fun relaunch(): RecordingStore =
            RecordingStore(store.root, clock = { now }, onLost = { lostCalls += it }, decoder = decoder)
    }

    private fun launch(decoder: AacDecoder = FakeDecoder()) = Launch(File(temp.root, "voice/pending"), decoder = decoder)

    @Test fun `launch sweep keeps a seven day old slot and expires older ones without counting lost`() {
        val launch = launch()
        record(launch.store, "old", 1024)
        launch.now += 1
        record(launch.store, "keep", 1024)
        launch.now += RETENTION_MILLIS

        val result = launch.relaunch().sweepOnLaunch()

        assertEquals(RecordingSweepResult(expired = 1, lost = 0, recovered = 0), result)
        assertFalse(launch.store.isOccupied("old"))
        assertEquals(RecordingSlotStatus.Ready, launch.store.read("keep")!!.status)
        assertTrue(launch.store.audioFile("keep").exists())
        assertEquals(emptyList<Int>(), launch.lostCalls)
    }

    @Test fun `launch sweep clears recycle bin residue without counting lost`() {
        val launch = launch()
        val slot = record(launch.store, "conv-1", 96_000)
        assertTrue(launch.store.discard("conv-1")!!.undoable)
        assertTrue(File(launch.store.root, "discarded/${slot.audioFile.name}").exists())

        val result = launch.relaunch().sweepOnLaunch()

        assertEquals(0, result.lost)
        assertFalse(File(launch.store.root, "discarded").exists())
        assertFalse(launch.store.undoDiscard("conv-1"))
        assertEquals(emptyList<Int>(), launch.lostCalls)
    }

    @Test fun `externally deleted audio reports lost once and clears the sidecar`() {
        val launch = launch()
        val slot = record(launch.store, "conv-1", 16_000)
        assertTrue(slot.audioFile.delete())

        val first = launch.relaunch().sweepOnLaunch()
        val second = launch.relaunch().sweepOnLaunch()

        assertEquals(1, first.lost)
        assertEquals(0, second.lost)
        assertEquals(listOf(1), launch.lostCalls)
        assertFalse(launch.store.sidecarFile("conv-1").exists())
        assertFalse(launch.store.isOccupied("conv-1"))
    }

    @Test fun `orphan audio and corrupt sidecars are cleared without counting lost`() {
        val launch = launch()
        val root = launch.store.root
        root.mkdirs()
        val orphan = File(root, sha256("orphan") + ".aac").apply { writeBytes(ByteArray(32) { 1 }) }
        val corruptAlone = File(root, sha256("corrupt-alone") + ".json").apply { writeText("{not json") }
        val corruptSidecar = File(root, sha256("corrupt") + ".json").apply { writeText("[]") }
        val corruptAudio = File(root, sha256("corrupt") + ".aac").apply { writeBytes(ByteArray(32) { 2 }) }

        val result = launch.relaunch().sweepOnLaunch()

        assertEquals(RecordingSweepResult(expired = 0, lost = 0, recovered = 0), result)
        listOf(orphan, corruptAlone, corruptSidecar, corruptAudio).forEach { assertFalse(it.name, it.exists()) }
        assertEquals(emptyList<Int>(), launch.lostCalls)
    }

    @Test fun `complete discard and expiry flows never count lost`() {
        val launch = launch()
        record(launch.store, "done", 16_000)
        launch.store.complete("done")
        record(launch.store, "short", 16_000)
        assertFalse(launch.store.discard("short")!!.undoable)
        record(launch.store, "long-committed", 96_000)
        assertTrue(launch.store.discard("long-committed")!!.undoable)
        launch.store.commitDiscard("long-committed")
        record(launch.store, "long-pending", 96_000)
        assertTrue(launch.store.discard("long-pending")!!.undoable)
        record(launch.store, "stale", 16_000)
        launch.now += RETENTION_MILLIS + 1

        val result = launch.relaunch().sweepOnLaunch()

        assertEquals(RecordingSweepResult(expired = 1, lost = 0, recovered = 0), result)
        assertEquals(emptyList<Int>(), launch.lostCalls)
        assertTrue(launch.store.root.listFiles()!!.isEmpty())
    }

    @Test fun `slot still recording after a crash is recovered as interrupted with duration from the file`() {
        val launch = launch()
        val slot = launch.store.open("conv-1", engine = "cloud", encoder = FakeEncoder())
        slot.write(ShortArray(16_000) { 1000 })
        // No finish: simulates a killed process, so the sidecar stays recording with duration 0.
        assertEquals(RecordingSlotStatus.Recording, launch.store.read("conv-1")!!.status)
        assertEquals(15, AdtsFormat.parse(slot.audioFile.readBytes()).frames.size)
        // 15 frames x 1024 - sidecar primingFrames 2112 = 13248 samples.
        val expected = (15 * 1024 - 2112) / 16_000.0

        val result = launch.relaunch().sweepOnLaunch()

        assertEquals(RecordingSweepResult(expired = 0, lost = 0, recovered = 1), result)
        val meta = launch.store.read("conv-1")!!
        assertEquals(RecordingSlotStatus.Interrupted, meta.status)
        assertEquals(expected, meta.durationSec, 1e-9)
        // The fake decoder yields amplitude 1000 throughout: 13248 samples -> ceil(13248 / 800) = 17 windows, each 20*log10(1000 / 32768).
        assertEquals(17, meta.envelope.size)
        meta.envelope.forEach { assertEquals(20 * log10(1000 / 32768.0), it!!, 1e-6) }
        assertTrue(slot.audioFile.exists())
        assertEquals(emptyList<Int>(), launch.lostCalls)

        assertEquals(0, launch.relaunch().sweepOnLaunch().recovered)
        assertEquals(RecordingSlotStatus.Interrupted, launch.store.read("conv-1")!!.status)
    }

    @Test fun `crash recovery recomputes the envelope from decoded pcm after skipping priming`() {
        // The first 2112 priming samples are full scale (the first window would be non-null if they were not skipped); then the first 50 ms window and the 6th window are digital silence and the rest have amplitude 1000.
        val decoder = FakeDecoder { file ->
            val total = AdtsFormat.parse(file.readBytes()).frames.size * AdtsStream.SAMPLES_PER_FRAME
            ShortArray(total) { i ->
                val t = i - 2112
                when {
                    t < 0 -> 30_000
                    t < 800 || t in 4000 until 4800 -> 0
                    else -> 1000
                }.toShort()
            }
        }
        val launch = launch(decoder)
        val slot = launch.store.open("conv-1", engine = "cloud", encoder = FakeEncoder())
        slot.write(ShortArray(16_000) { 1000 })

        assertEquals(1, launch.relaunch().sweepOnLaunch().recovered)

        val meta = launch.store.read("conv-1")!!
        assertEquals(RecordingSlotStatus.Interrupted, meta.status)
        assertEquals(listOf(slot.audioFile to null), decoder.calls)
        assertEquals(ceil(meta.durationSec / DictationRules.WINDOW_SEC).toInt(), meta.envelope.size)
        assertEquals(17, meta.envelope.size)
        assertNull(meta.envelope[0])
        assertNull(meta.envelope[5])
        val loud = 20 * log10(1000 / 32768.0)
        meta.envelope.withIndex().filter { it.index != 0 && it.index != 5 }
            .forEach { assertEquals(loud, it.value!!, 1e-6) }
    }

    @Test fun `crash recovery keeps an empty envelope when decoding fails`() {
        val launch = launch(FakeDecoder(failure = IOException("aac decode failed")))
        val slot = launch.store.open("conv-1", engine = "cloud", encoder = FakeEncoder())
        slot.write(ShortArray(16_000) { 1000 })

        val result = launch.relaunch().sweepOnLaunch()

        assertEquals(RecordingSweepResult(expired = 0, lost = 0, recovered = 1), result)
        val meta = launch.store.read("conv-1")!!
        assertEquals(RecordingSlotStatus.Interrupted, meta.status)
        assertEquals((15 * 1024 - 2112) / 16_000.0, meta.durationSec, 1e-9)
        assertEquals(emptyList<Double?>(), meta.envelope)
        assertTrue(slot.audioFile.exists())
        assertEquals(emptyList<Int>(), launch.lostCalls)
    }

    @Test fun `crash recovery does not subtract priming when the sidecar records zero`() {
        val launch = launch()
        val slot = launch.store.open("conv-1", engine = "cloud", encoder = FakeEncoder(encoderDelay = 0))
        slot.write(ShortArray(16_000) { 1000 })
        assertEquals(0, launch.store.read("conv-1")!!.primingFrames)

        launch.relaunch().sweepOnLaunch()

        val meta = launch.store.read("conv-1")!!
        assertEquals(RecordingSlotStatus.Interrupted, meta.status)
        assertEquals(15 * 1024 / 16_000.0, meta.durationSec, 1e-9)
    }

    @Test fun `crash recovery falls back to default priming when the sidecar lacks it`() {
        val launch = launch()
        val slot = launch.store.open("conv-1", engine = "cloud", encoder = FakeEncoder())
        slot.write(ShortArray(16_000) { 1000 })
        val sidecar = launch.store.sidecarFile("conv-1")
        val legacy = Json.parseToJsonElement(sidecar.readText()).jsonObject.filterKeys { it != "primingFrames" }
        sidecar.writeText(JsonObject(legacy).toString())

        assertEquals(1, launch.relaunch().sweepOnLaunch().recovered)

        val meta = launch.store.read("conv-1")!!
        assertEquals(RecordingSlotStatus.Interrupted, meta.status)
        assertEquals((15 * 1024 - RecordingWriter.DEFAULT_PRIMING_FRAMES) / 16_000.0, meta.durationSec, 1e-9)
    }

    @Test fun `mark interrupted survives a relaunch`() {
        val launch = launch()
        record(launch.store, "conv-1", 16_000)
        assertTrue(launch.store.markInterrupted("conv-1"))
        assertFalse(launch.store.markInterrupted("missing"))

        val reopened = launch.relaunch()
        val result = reopened.sweepOnLaunch()

        assertEquals(RecordingSweepResult(expired = 0, lost = 0, recovered = 0), result)
        val meta = reopened.read("conv-1")!!
        assertEquals(RecordingSlotStatus.Interrupted, meta.status)
        assertEquals(1.0, meta.durationSec, 1e-9)
        assertEquals(20, meta.envelope.size)
    }

    @Test fun `backup and device transfer exclude voice directory`() {
        val root = File(System.getProperty("user.dir")).absoluteFile
        val legacy = File(root, "src/main/res/xml/backup_rules.xml").readText()
        val modern = File(root, "src/main/res/xml/data_extraction_rules.xml").readText()
        val pattern = Regex("domain=\"file\" path=\"voice/\"")
        assertEquals("legacy cloud backup excludes voice/", 1, pattern.findAll(legacy).count())
        assertEquals("cloud plus device-transfer exclude voice/", 2, pattern.findAll(modern).count())
    }
}
