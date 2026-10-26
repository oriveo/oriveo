package ai.oriveo.community.core.voice

import java.io.File
import java.nio.ByteBuffer
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class RecordingExporterTest {

    @get:Rule
    val tmp = TemporaryFolder()

    private val aac = File("src/test/resources/voice/sine-silence-16k.aac")
    private val frames = AdtsFormat.parse(aac.readBytes()).frames

    @Test
    fun `whole adts file remuxes to m4a with lc asc and 49 samples`() {
        val out = tmp.newFile("full.m4a")
        RecordingExporter.toM4a(aac, out)
        val bytes = out.readBytes()
        assertTrue("m4a size ${bytes.size} vs aac ${aac.length()}", bytes.size < aac.length() + 4096)

        assertEquals("ftyp", String(bytes, 4, 4, Charsets.US_ASCII))
        val top = topLevelBoxes(bytes)
        assertTrue("top level boxes: ${top.keys}", "moov" in top && "mdat" in top)
        val moov = top.getValue("moov")
        assertArrayEquals(byteArrayOf(0x14, 0x08), ascFromEsds(findBox(moov, "esds")))
        assertEquals(frames.map { it.payload.size }, stszEntries(findBox(moov, "stsz")))

        // Keep a copy so duration and format can be checked manually with afinfo.
        File("build/tmp/RecordingExporterTest").apply { mkdirs() }.resolve("full.m4a").writeBytes(bytes)
    }

    @Test
    fun `range is shifted by priming then cut on frame boundaries`() {
        // Recording time [1, 2] + 1600/16000 = file time [1.1, 2.1] -> frames [17.19, 32.81] -> frames 17..32, 16 frames.
        val primed = tmp.newFile("primed.m4a")
        RecordingExporter.toM4a(aac, primed, 1.0..2.0, primingFrames = 1600)
        val primedSizes = stszEntries(findBox(topLevelBoxes(primed.readBytes()).getValue("moov"), "stsz"))
        assertEquals(16, primedSizes.size)
        assertEquals(frames.subList(17, 33).map { it.payload.size }, primedSizes)

        // No priming: file time [1, 2] -> frames [15.625, 31.25] -> frames 15..31, 17 frames.
        val unprimed = tmp.newFile("unprimed.m4a")
        RecordingExporter.toM4a(aac, unprimed, 1.0..2.0, primingFrames = 0)
        val unprimedSizes = stszEntries(findBox(topLevelBoxes(unprimed.readBytes()).getValue("moov"), "stsz"))
        assertEquals(17, unprimedSizes.size)
        assertEquals(frames.subList(15, 32).map { it.payload.size }, unprimedSizes)
    }

    @Test
    fun `out of bounds or empty range throws dedicated error`() {
        val cases = listOf(
            -0.1..1.0 to RecordingExportException.Reason.OUT_OF_BOUNDS,
            // File is 3.136 s; minus 0.1 s priming, the recording is 3.036 s.
            1.0..3.1 to RecordingExportException.Reason.OUT_OF_BOUNDS,
            1.0..1.0 to RecordingExportException.Reason.EMPTY_RANGE,
            2.0..1.0 to RecordingExportException.Reason.EMPTY_RANGE,
        )
        for ((range, reason) in cases) {
            val out = File(tmp.root, "bad-${range.start}-${range.endInclusive}.m4a")
            try {
                RecordingExporter.toM4a(aac, out, range, primingFrames = 1600)
                fail("expected RecordingExportException for $range")
            } catch (e: RecordingExportException) {
                assertEquals("range $range", reason, e.reason)
            }
            assertFalse("no output for $range", out.exists())
        }
        // Ending exactly at the end of the recording is not out of range: file time [0.1, 3.136] -> frames 1..48.
        val edge = tmp.newFile("edge.m4a")
        RecordingExporter.toM4a(aac, edge, 0.0..3.036, primingFrames = 1600)
        assertEquals(frames.subList(1, 49).map { it.payload.size }, stszEntries(findBox(topLevelBoxes(edge.readBytes()).getValue("moov"), "stsz")))
    }

    @Test
    fun `late range of long recording starts at frame index not bitrate estimate`() {
        // Build 12500 frames (800 s, over 13 minutes): copy the fixture payloads round-robin (keeping VBR frame-length differences),
        // and write the source frame index into the first 4 bytes of each payload, then read the first frame index straight from mdat after export.
        val frameCount = 12_500
        val payloads = List(frameCount) { i ->
            val src = frames[i % frames.size].payload
            src.copyOf(maxOf(src.size, 4)).also { ByteBuffer.wrap(it).putInt(0, i) }
        }
        val long = tmp.newFile("long.aac")
        long.outputStream().use { os ->
            for (payload in payloads) {
                os.write(AdtsFormat.header(payload.size))
                os.write(payload)
            }
        }

        // Recording time [593.075, 791.0] + 0.1 s priming -> samples [9490800, 12657600] -> frames [9268.36, 12360.94] -> frames 9268..12360.
        val out = tmp.newFile("late.m4a")
        RecordingExporter.toM4a(long, out, 593.075..791.0, primingFrames = 1600)
        val top = topLevelBoxes(out.readBytes())
        val sizes = stszEntries(findBox(top.getValue("moov"), "stsz"))
        val expected = payloads.subList(9268, 12361)
        assertEquals(3093, sizes.size)
        assertEquals(expected.map { it.size }, sizes)
        val mdat = top.getValue("mdat")
        assertArrayEquals(expected.fold(ByteArray(0)) { acc, b -> acc + b }, mdat)
        assertEquals(9268, ByteBuffer.wrap(mdat).getInt(0))

        // Start and duration errors are both within 1 frame (64 ms).
        val frameSeconds = AdtsStream.SAMPLES_PER_FRAME / 16_000.0
        val startSeconds = 9268 * frameSeconds - 0.1
        assertTrue("start $startSeconds", startSeconds <= 593.075 && 593.075 - startSeconds < frameSeconds)
        val durationSeconds = sizes.size * frameSeconds
        assertTrue("duration $durationSeconds", kotlin.math.abs(durationSeconds - (791.0 - 593.075)) <= frameSeconds)
    }

    private fun topLevelBoxes(bytes: ByteArray): Map<String, ByteArray> {
        val boxes = linkedMapOf<String, ByteArray>()
        val buf = ByteBuffer.wrap(bytes)
        var pos = 0
        while (pos + 8 <= bytes.size) {
            var size = buf.getInt(pos).toLong() and 0xFFFFFFFFL
            var header = 8
            if (size == 1L) {
                size = buf.getLong(pos + 8)
                header = 16
            } else if (size == 0L) {
                size = (bytes.size - pos).toLong()
            }
            val type = String(bytes, pos + 4, 4, Charsets.US_ASCII)
            boxes.putIfAbsent(type, bytes.copyOfRange(pos + header, (pos + size).toInt()))
            pos += size.toInt()
        }
        return boxes
    }

    /** Finds a descendant box by fourcc in the container content and returns its content (without the 8-byte header). */
    private fun findBox(container: ByteArray, type: String): ByteArray {
        val fourcc = type.toByteArray(Charsets.US_ASCII)
        for (i in 4..container.size - 4) {
            if (container.copyOfRange(i, i + 4).contentEquals(fourcc)) {
                val size = ByteBuffer.wrap(container).getInt(i - 4)
                return container.copyOfRange(i + 4, i - 4 + size)
            }
        }
        throw AssertionError("box $type not found")
    }

    /** esds: skips version/flags and looks for DecoderSpecificInfo (tag 0x05) among the descriptors. */
    private fun ascFromEsds(esds: ByteArray): ByteArray {
        var i = 4
        while (i < esds.size) {
            val tag = esds[i].toInt() and 0xFF
            var j = i + 1
            var length = 0
            do {
                val b = esds[j++].toInt() and 0xFF
                length = (length shl 7) or (b and 0x7F)
            } while (b and 0x80 != 0)
            when (tag) {
                0x05 -> return esds.copyOfRange(j, j + length)
                0x03 -> i = j + 3 // ES_ID(2) + flags(1), followed by child descriptors
                0x04 -> i = j + 13 // DecoderConfigDescriptor is a fixed 13 bytes, followed by child descriptors
                else -> i = j + length
            }
        }
        throw AssertionError("DecoderSpecificInfo not found")
    }

    private fun stszEntries(stsz: ByteArray): List<Int> {
        val buf = ByteBuffer.wrap(stsz)
        val sampleSize = buf.getInt(4)
        val count = buf.getInt(8)
        return if (sampleSize != 0) List(count) { sampleSize } else List(count) { buf.getInt(12 + it * 4) }
    }
}
