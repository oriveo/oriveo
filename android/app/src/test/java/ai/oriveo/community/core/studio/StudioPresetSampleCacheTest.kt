package ai.oriveo.community.core.studio

import java.io.File
import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.Paths
import java.security.MessageDigest
import java.util.Base64
import java.util.concurrent.CopyOnWriteArrayList
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Style sample cache keyed by sample.sha256: fixture cases for the pure helpers, then the
 * hit / miss / mismatch / in-flight / prune / unreadable paths against a temp directory and a
 * fake downloader.
 */
class StudioPresetSampleCacheTest {
    private fun findUp(relative: String): Path =
        generateSequence(Paths.get("").toAbsolutePath().normalize()) { it.parent }
            .take(8)
            .map { it.resolve(relative) }
            .firstOrNull { Files.exists(it) }
            ?: error("$relative not found")

    private val sharedDir = String(charArrayOf(0x5171.toChar(), 0x4eab.toChar()))

    private val sampleCache: JsonObject by lazy {
        Json.parseToJsonElement(findUp("$sharedDir/studio-contracts/studio_presets.v1.json").toFile().readText())
            .jsonObject.getValue("clientCases").jsonObject.getValue("sampleCache").jsonObject
    }

    private fun cases(name: String): List<JsonObject> =
        sampleCache.getValue(name).jsonArray.map { it.jsonObject }.also { assertTrue("$name is empty", it.isNotEmpty()) }

    private class FakeDownloader {
        val urls = CopyOnWriteArrayList<String>()
        var next: suspend (String) -> ByteArray? = { null }

        suspend fun download(url: String): ByteArray? {
            urls += url
            return next(url)
        }
    }

    private fun sha256Hex(bytes: ByteArray): String =
        MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }

    private fun newDir(): File = Files.createTempDirectory("studio-samples").toFile()

    private fun cache(dir: File, downloader: FakeDownloader, base: String = BASE) =
        StudioPresetSampleCache(dir, { base }, downloader::download)

    private fun sample(bytes: ByteArray, url: String = "/api/studio/presets/samples/r1/${sha256Hex(bytes).take(8)}.webp") =
        StudioPresets.Sample(url, 640, 480, sha256Hex(bytes))

    @Test
    fun fixtureResolveUrl() {
        for (case in cases("resolveUrl")) {
            val input = case.getValue("input").jsonObject
            val expect = case.getValue("expect").jsonPrimitive.contentOrNull
            val actual = StudioPresetSampleCache.resolveSampleUrl(
                input.getValue("baseUrl").jsonPrimitive.content,
                input.getValue("url").jsonPrimitive.content,
            )
            assertEquals(case.getValue("caseId").jsonPrimitive.content, expect, actual)
        }
    }

    @Test
    fun fixtureVerify() {
        for (case in cases("verify")) {
            val input = case.getValue("input").jsonObject
            val bytes = Base64.getDecoder().decode(input.getValue("bytesBase64").jsonPrimitive.content)
            val ok = StudioPresetSampleCache.verify(bytes, input.getValue("sha256").jsonPrimitive.content)
            assertEquals(case.getValue("caseId").jsonPrimitive.content, case.getValue("expect").jsonPrimitive.content, if (ok) "ok" else "sha_mismatch")
        }
    }

    @Test
    fun policyMaxBytes() {
        val expected = sampleCache.getValue("policy").jsonObject.getValue("maxBytes").jsonPrimitive.long
        assertEquals("maxBytes mirrors policy.maxBytes", expected, StudioPresetSampleCache.MAX_BYTES)
    }

    @Test
    fun hitSkipsNetwork() = runBlocking {
        val dir = newDir()
        val bytes = "stored sample".toByteArray()
        val entry = sample(bytes)
        File(dir, entry.sha256).writeBytes(bytes)
        val downloader = FakeDownloader()
        assertArrayEquals("hit returns stored bytes", bytes, cache(dir, downloader).data(entry))
        assertEquals("hit makes no request", 0, downloader.urls.size)
    }

    @Test
    fun missDownloadsAndStores() = runBlocking {
        val dir = newDir()
        val bytes = "fresh sample".toByteArray()
        val entry = sample(bytes)
        val downloader = FakeDownloader().apply { next = { bytes } }
        val cache = cache(dir, downloader, "$BASE/")
        assertArrayEquals("miss returns downloaded bytes", bytes, cache.data(entry))
        assertEquals("miss requests the resolved url", listOf(BASE + entry.url), downloader.urls.toList())
        assertArrayEquals("stored under cacheDir/<sha>", bytes, File(dir, entry.sha256).readBytes())
        assertEquals("no temp file left behind", listOf(entry.sha256), dir.list()!!.toList())
        assertArrayEquals("second read is a hit", bytes, cache.data(entry))
        assertEquals("second read makes no request", 1, downloader.urls.size)
    }

    @Test
    fun shaMismatchNotStored() = runBlocking {
        val dir = newDir()
        val entry = sample("expected sample".toByteArray())
        val downloader = FakeDownloader().apply { next = { "tampered sample".toByteArray() } }
        val cache = cache(dir, downloader)
        assertNull("mismatch returns null", cache.data(entry))
        assertFalse("mismatch is not stored", File(dir, entry.sha256).exists())
        assertEquals("nothing written", 0, dir.list()!!.size)
        assertNull("still a miss", cache.data(entry))
        assertEquals("each miss downloads again", 2, downloader.urls.size)
    }

    @Test
    fun unresolvableUrlSkipsNetwork() = runBlocking {
        val dir = newDir()
        val bytes = "sample".toByteArray()
        val downloader = FakeDownloader().apply { next = { bytes } }
        assertNull("plain http rejected", cache(dir, downloader).data(sample(bytes, "http://cdn.example.com/a.webp")))
        assertNull("bare relative rejected", cache(dir, downloader).data(sample(bytes, "api/studio/a.webp")))
        assertNull("empty base rejected", cache(dir, downloader, "").data(sample(bytes)))
        assertEquals("no request for unresolvable urls", 0, downloader.urls.size)
        assertEquals("nothing written", 0, dir.list()!!.size)
    }

    @Test
    fun concurrentSameKeyDownloadsOnce() = runBlocking {
        val dir = newDir()
        val bytes = "shared sample".toByteArray()
        val entry = sample(bytes)
        val started = CompletableDeferred<Unit>()
        val gate = CompletableDeferred<Unit>()
        val downloader = FakeDownloader().apply {
            next = {
                started.complete(Unit)
                gate.await()
                bytes
            }
        }
        val cache = cache(dir, downloader)
        withTimeout(10_000) {
            val first = async { cache.data(entry) }
            started.await()
            val second = async { cache.data(entry) }
            delay(300)
            gate.complete(Unit)
            assertArrayEquals("first caller gets bytes", bytes, first.await())
            assertArrayEquals("second caller gets the same bytes", bytes, second.await())
        }
        assertEquals("one download for one key in flight", 1, downloader.urls.size)

        val cancelDir = newDir()
        val cancelStarted = CompletableDeferred<Unit>()
        val cancelGate = CompletableDeferred<Unit>()
        val cancelDownloader = FakeDownloader().apply {
            next = {
                cancelStarted.complete(Unit)
                cancelGate.await()
                bytes
            }
        }
        val cancelCache = cache(cancelDir, cancelDownloader)
        withTimeout(10_000) {
            val owner = async { cancelCache.data(entry) }
            cancelStarted.await()
            val waiter = async { cancelCache.data(entry) }
            delay(300)
            owner.cancel()
            cancelGate.complete(Unit)
            assertArrayEquals("waiter gets bytes after the first caller is cancelled", bytes, waiter.await())
        }
        assertEquals("cancelling the first caller does not restart the download", 1, cancelDownloader.urls.size)
        assertArrayEquals("shared download still stores the entry", bytes, File(cancelDir, entry.sha256).readBytes())
    }

    @Test
    fun pruneKeepsOnlyGiven() = runBlocking {
        val dir = newDir()
        val kept = "kept sample".toByteArray()
        val dropped = "dropped sample".toByteArray()
        val downloader = FakeDownloader().apply { next = { url -> if (url.endsWith(sample(kept).url)) kept else dropped } }
        val cache = cache(dir, downloader)
        assertArrayEquals(kept, cache.data(sample(kept)))
        assertArrayEquals(dropped, cache.data(sample(dropped)))
        cache.prune(setOf(sha256Hex(kept)))
        assertEquals("only the kept key remains", listOf(sha256Hex(kept)), dir.list()!!.toList())
        assertArrayEquals("kept entry is still a hit", kept, cache.data(sample(kept)))
        assertEquals("kept hit makes no request", 2, downloader.urls.size)
        assertArrayEquals("pruned entry downloads again", dropped, cache.data(sample(dropped)))
        assertEquals("pruned entry refetched", 3, downloader.urls.size)
    }

    @Test
    fun unreadableEntryRefetches() = runBlocking {
        val dir = newDir()
        val bytes = "replacement sample".toByteArray()
        val entry = sample(bytes)
        val unreadable = File(dir, entry.sha256).apply { mkdirs() }
        File(unreadable, "junk").writeBytes(byteArrayOf(1, 2, 3))
        val downloader = FakeDownloader().apply { next = { bytes } }
        assertArrayEquals("unreadable entry refetched", bytes, cache(dir, downloader).data(entry))
        assertEquals("refetch makes one request", 1, downloader.urls.size)
        assertTrue("entry replaced by a regular file", File(dir, entry.sha256).isFile)
        assertArrayEquals("replacement stored", bytes, File(dir, entry.sha256).readBytes())
    }

    private companion object {
        const val BASE = "https://api.oriveoai.com"
    }
}
