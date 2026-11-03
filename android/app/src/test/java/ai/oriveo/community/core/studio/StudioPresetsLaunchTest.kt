package ai.oriveo.community.core.studio

import java.io.File
import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.Paths
import java.security.MessageDigest
import java.util.concurrent.CopyOnWriteArrayList
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Launch entry of studio presets: a hidden entry never touches the store, a visible one refreshes
 * with the locale resolved against the snapshot locales, and only a replaced refresh prunes the
 * sample cache to the current styles' samples. Real store and cache, fake transport and
 * downloader.
 */
class StudioPresetsLaunchTest {
    private fun findUp(vararg relative: String): Path =
        generateSequence(Paths.get("").toAbsolutePath().normalize()) { it.parent }
            .take(8)
            .flatMap { dir -> relative.asSequence().map { dir.resolve(it) } }
            .firstOrNull { Files.exists(it) }
            ?: error("${relative.first()} not found")

    /** Production snapshot loader with asset paths mapped onto src/main/assets. */
    private val snapshotReader: () -> String? = StudioPresets.snapshotReader { path ->
        findUp(
            "src/main/assets/$path",
            "app/src/main/assets/$path",
            "\u5e94\u7528/oriveo-android/app/src/main/assets/$path",
        ).toFile().inputStream()
    }

    private val asset: String = snapshotReader()!!

    private val locales: () -> List<String> = { StudioPresetsLaunch.snapshotLocales(snapshotReader) }

    private class Request(val locale: String, val ifNoneMatch: String?)

    private class FakeTransport {
        val requests = CopyOnWriteArrayList<Request>()
        var next: suspend () -> StudioPresets.Response = { StudioPresets.Response(500, null, null) }

        suspend fun fetch(locale: String, ifNoneMatch: String?): StudioPresets.Response {
            requests += Request(locale, ifNoneMatch)
            return next()
        }
    }

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

    private fun store(transport: FakeTransport, now: Long = T0): StudioPresetsStore {
        val file = Files.createTempDirectory("studio-presets").resolve(StudioPresetsStore.FILE_PATH).toFile()
        return StudioPresetsStore(file, transport::fetch, snapshotReader, { now })
    }

    private fun cache(dir: File, downloader: FakeDownloader) =
        StudioPresetSampleCache(dir, { BASE }, downloader::download)

    private fun sample(bytes: ByteArray): StudioPresets.Sample =
        StudioPresets.Sample("/api/studio/presets/samples/r2/${sha256Hex(bytes).take(8)}.webp", 512, 512, sha256Hex(bytes))

    /** Server envelope for [tag] from the snapshot, revision [revision], first style carrying [sample]. */
    private fun networkBody(tag: String, revision: String, sample: StudioPresets.Sample?): String {
        val envelope = StudioPresets.localize(Json.parseToJsonElement(asset).jsonObject, tag)
        val data = envelope.getValue("data").jsonObject
        val styles = data.getValue("styles").jsonArray.mapIndexed { index, style ->
            if (index != 0 || sample == null) {
                style
            } else {
                val wire = JsonObject(
                    mapOf(
                        "url" to JsonPrimitive(sample.url),
                        "width" to JsonPrimitive(sample.width),
                        "height" to JsonPrimitive(sample.height),
                        "sha256" to JsonPrimitive(sample.sha256),
                    ),
                )
                JsonObject(style.jsonObject + ("sample" to wire))
            }
        }
        val next = data + mapOf("revision" to JsonPrimitive(revision), "styles" to JsonArray(styles))
        return JsonObject(envelope + ("data" to JsonObject(next))).toString()
    }

    /** Stores [bytes] in the cache through the production miss path. */
    private suspend fun seed(dir: File, bytes: ByteArray): StudioPresets.Sample {
        val sample = sample(bytes)
        val downloader = FakeDownloader().apply { next = { bytes } }
        assertEquals("seeded bytes", bytes.toList(), cache(dir, downloader).data(sample)?.toList())
        return sample
    }

    /** Whether [sample] is still cached: a hit makes no download request. */
    private suspend fun cached(dir: File, sample: StudioPresets.Sample): Boolean {
        val downloader = FakeDownloader()
        cache(dir, downloader).data(sample)
        return downloader.urls.isEmpty()
    }

    @Test
    fun hiddenEntrySkipsRefresh() = runBlocking {
        val dir = Files.createTempDirectory("studio-samples").toFile()
        val kept = seed(dir, "kept sample".toByteArray())
        val transport = FakeTransport().apply {
            next = { StudioPresets.Response(200, "\"r2\"", networkBody("en", REVISION_2, null)) }
        }
        var localesRead = 0
        val outcome = StudioPresetsLaunch.run(false, "ja", store(transport), cache(dir, FakeDownloader())) {
            localesRead += 1
            locales()
        }
        assertNull("hidden entry returns null", outcome)
        assertEquals("hidden entry sends no request", 0, transport.requests.size)
        assertEquals("hidden entry does not read locales", 0, localesRead)
        assertEquals("hidden entry keeps samples", true, cached(dir, kept))
    }

    @Test
    fun visibleEntryRefreshesWithLocale() = runBlocking {
        assertEquals("snapshot has 16 locales", 16, locales().size)
        val dir = Files.createTempDirectory("studio-samples").toFile()
        for ((tag, expected) in listOf("zh-Hant" to "zh-Hant", "pt-BR" to "pt-BR", "fr-CA" to "fr", "en" to "en")) {
            val transport = FakeTransport()
            val outcome = StudioPresetsLaunch.run(true, tag, store(transport), cache(dir, FakeDownloader()), locales)
            assertEquals("outcome for $tag", StudioPresets.Outcome.FAILED, outcome)
            assertEquals("requested locales for $tag", listOf(expected), transport.requests.map { it.locale })
            assertNull("first request has no If-None-Match for $tag", transport.requests.single().ifNoneMatch)
        }
    }

    @Test
    fun replacedPrunesToCurrentSamples() = runBlocking {
        val dir = Files.createTempDirectory("studio-samples").toFile()
        val kept = seed(dir, "kept sample".toByteArray())
        val stale = seed(dir, "stale sample".toByteArray())
        val transport = FakeTransport().apply {
            next = { StudioPresets.Response(200, "\"r2\"", networkBody("ja", REVISION_2, kept)) }
        }
        val store = store(transport)
        val outcome = StudioPresetsLaunch.run(true, "ja", store, cache(dir, FakeDownloader()), locales)
        assertEquals("outcome", StudioPresets.Outcome.REPLACED, outcome)
        assertEquals("current samples", listOf(kept.sha256), store.current("ja")!!.styles.mapNotNull { it.sample?.sha256 })
        assertEquals("current sample stays cached", true, cached(dir, kept))
        assertEquals("stale sample pruned", false, cached(dir, stale))
    }

    @Test
    fun nonReplacedKeepsSamples() = runBlocking {
        val dir = Files.createTempDirectory("studio-samples").toFile()
        val kept = seed(dir, "kept sample".toByteArray())
        val stale = seed(dir, "stale sample".toByteArray())

        val failing = FakeTransport()
        val failed = StudioPresetsLaunch.run(true, "en", store(failing), cache(dir, FakeDownloader()), locales)
        assertEquals("failed outcome", StudioPresets.Outcome.FAILED, failed)

        // A store refreshed moments ago is throttled: no request, cache untouched.
        val transport = FakeTransport().apply {
            next = { StudioPresets.Response(200, "\"r2\"", networkBody("en", REVISION_2, kept)) }
        }
        val store = store(transport)
        assertEquals("seed outcome", StudioPresets.Outcome.REPLACED, store.refreshIfNeeded("en", T0))
        val throttled = StudioPresetsLaunch.run(true, "en", store, cache(dir, FakeDownloader()), locales)
        assertEquals("throttled outcome", StudioPresets.Outcome.THROTTLED, throttled)
        assertEquals("throttled sends no request", 1, transport.requests.size)

        assertEquals("kept sample stays cached", true, cached(dir, kept))
        assertEquals("stale sample stays cached", true, cached(dir, stale))
    }

    private companion object {
        const val BASE = "https://api.oriveoai.com"
        const val T0 = 1_800_000_000_000L
        const val REVISION_2 = "2026-11-01.2"
    }
}
