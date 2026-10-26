package ai.oriveo.community.core.voice

import ai.oriveo.community.core.mcp.mcpSha256Hex
import ai.oriveo.community.core.model.ProviderKind
import java.io.File
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class SpeechAudioCacheTest {

    @get:Rule
    val temp = TemporaryFolder()

    private fun key(text: String = "hello", speed: Double = 1.0) = SpeechCacheKey(
        text = text,
        providerKind = ProviderKind.OpenAI,
        model = "gpt-4o-mini-tts",
        voice = "alloy",
        effectiveSpeed = speed,
        language = "en",
        outputFormat = "mp3",
    )

    @Test
    fun `hit returns stored bytes and refreshes mtime`() = runTest {
        var clock = 1_000_000L
        val dir = File(temp.root, "voice-tts")
        val cache = SpeechAudioCache(dir, maxBytes = 1_000, now = { clock })
        val bytes = byteArrayOf(1, 2, 3, 4)
        val written = cache.write(key(), bytes)
        assertNotNull(written)
        assertNull(cache.read(key(text = "other")))

        clock = 5_000_000L
        val hit = cache.read(key())
        assertNotNull(hit)
        assertArrayEquals(bytes, hit!!.readBytes())
        assertEquals(5_000_000L, hit.lastModified())
        assertEquals(listOf(hit.name), dir.listFiles()!!.map { it.name })
    }

    @Test
    fun `evicts oldest until under cap`() = runTest {
        var clock = 1_000_000L
        val dir = temp.newFolder("voice-tts")
        val cache = SpeechAudioCache(dir, maxBytes = 250, now = { clock })
        val a = cache.write(key("a"), ByteArray(100))!!
        clock += 10_000
        val b = cache.write(key("b"), ByteArray(100))!!
        clock += 10_000
        // Reading a once makes a the most recently used and b the oldest.
        assertNotNull(cache.read(key("a")))
        clock += 10_000
        val c = cache.write(key("c"), ByteArray(100))!!

        assertTrue(a.isFile)
        assertFalse(b.exists())
        assertTrue(c.isFile)
        assertNull(cache.read(key("b")))
        assertTrue(dir.listFiles()!!.sumOf { it.length() } <= 250)
    }

    @Test
    fun `single item over cap is not written`() = runTest {
        val dir = temp.newFolder("voice-tts")
        val cache = SpeechAudioCache(dir, maxBytes = 100)
        assertNotNull(cache.write(key("small"), ByteArray(50)))
        assertNull(cache.write(key("big"), ByteArray(101)))
        assertNull(cache.read(key("big")))
        // An oversized entry must not evict existing cache entries.
        assertNotNull(cache.read(key("small")))
        assertEquals(1, dir.listFiles()!!.size)
    }

    @Test
    fun `trim deletes stale temp files older than an hour`() = runTest {
        // Previously, partial .tmp-* cache files and voice-tts-* temp audio left behind by a killed process were never cleaned up
        val clock = 10_000_000L
        val dir = temp.newFolder("voice-tts")
        val cache = SpeechAudioCache(dir, maxBytes = 1_000, now = { clock })
        val staleWrite = File(dir, ".tmp-1.tmp").apply { writeBytes(ByteArray(10)) }
        val staleAudio = cache.createAudioTempFile(".mp3").apply { writeBytes(ByteArray(10)) }
        val freshAudio = cache.createAudioTempFile(".mp3").apply { writeBytes(ByteArray(10)) }
        staleWrite.setLastModified(clock - 3_600_001L)
        staleAudio.setLastModified(clock - 3_600_001L)
        freshAudio.setLastModified(clock - 60_000L)

        val written = cache.write(key(), byteArrayOf(1, 2, 3))!!

        assertFalse(staleWrite.exists())
        assertFalse(staleAudio.exists())
        assertTrue(freshAudio.isFile)
        assertEquals(setOf(written.name, freshAudio.name), dir.listFiles()!!.map { it.name }.toSet())
    }

    @Test
    fun `io failure is a miss`() = runTest {
        // The cache directory path is occupied by a regular file: the directory cannot be created, so reads and writes must be cache misses rather than throw.
        val blocker = temp.newFile("voice-tts")
        val cache = SpeechAudioCache(blocker, maxBytes = 1_000)
        assertNull(cache.write(key(), byteArrayOf(1, 2, 3)))
        assertNull(cache.read(key()))
        assertTrue(blocker.isFile)
    }

    @Test
    fun `key uses effective speed with two decimals`() {
        val base = key(speed = 1.0)
        val expected = mcpSha256Hex(
            listOf(mcpSha256Hex("hello"), "openAI", "gpt-4o-mini-tts", "alloy", "1.00", "en").joinToString("\n"),
        ) + ".mp3"
        assertEquals(expected, base.fileName)
        assertEquals(base.fileName, key(speed = 1.004).fileName)
        assertNotEquals(base.fileName, key(speed = 1.25).fileName)
        assertTrue(key(speed = 1.25).fileName.startsWith(
            mcpSha256Hex(listOf(mcpSha256Hex("hello"), "openAI", "gpt-4o-mini-tts", "alloy", "1.25", "en").joinToString("\n")),
        ))
    }
}
