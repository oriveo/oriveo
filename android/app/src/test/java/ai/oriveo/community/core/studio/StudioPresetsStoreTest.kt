package ai.oriveo.community.core.studio

import com.sun.net.httpserver.HttpServer
import java.io.File
import java.io.IOException
import java.net.InetAddress
import java.net.InetSocketAddress
import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.Paths
import java.util.concurrent.CopyOnWriteArrayList
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Store behaviour of studio_presets.v1 on Android: offline snapshot fallback, file persistence of
 * replaced bodies, the 6 hour throttle with If-None-Match, failures leaving the cache alone,
 * self-healing of a broken body, single-flight refreshes, the body size cap and the HTTP request.
 */
class StudioPresetsStoreTest {
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

    private val snapshotRevision: String =
        (Json.parseToJsonElement(asset).jsonObject["revision"] as JsonPrimitive).content

    /** A Server envelope for [tag] built from the snapshot, with its revision swapped to [revision]. */
    private fun networkBody(tag: String, revision: String): String {
        val envelope = StudioPresets.localize(Json.parseToJsonElement(asset).jsonObject, tag)
        val data = envelope.getValue("data").jsonObject
        return JsonObject(envelope + ("data" to JsonObject(data + ("revision" to JsonPrimitive(revision))))).toString()
    }

    private class Request(val locale: String, val ifNoneMatch: String?)

    private class FakeTransport {
        val requests = mutableListOf<Request>()
        var next: suspend () -> StudioPresets.Response = { StudioPresets.Response(500, null, null) }

        suspend fun fetch(locale: String, ifNoneMatch: String?): StudioPresets.Response {
            requests += Request(locale, ifNoneMatch)
            return next()
        }
    }

    private fun newFile(): File =
        Files.createTempDirectory("studio-presets").resolve(StudioPresetsStore.FILE_PATH).toFile()

    private fun store(file: File, transport: FakeTransport, now: Long = T0) =
        StudioPresetsStore(file, transport::fetch, snapshotReader, { now })

    private fun stored(file: File): JsonObject = Json.parseToJsonElement(file.readText()).jsonObject

    private fun offline(tag: String): StudioPresets.Presets =
        (StudioPresets.parseSnapshot(asset, tag) as StudioPresets.DecodeResult.Success).presets

    /** Seeds a replaced "en" cache at [T0] with etag "r2". */
    private fun seeded(file: File, transport: FakeTransport): StudioPresetsStore = runBlocking {
        transport.next = { StudioPresets.Response(200, "\"r2\"", networkBody("en", REVISION_2)) }
        val store = store(file, transport)
        assertEquals("seed outcome", StudioPresets.Outcome.REPLACED, store.refreshIfNeeded("en", T0))
        store
    }

    /** Rewrites the persisted body of [file], keeping its cache record. */
    private fun replaceBody(file: File, body: String?) {
        val root = stored(file)
        val next = if (body == null) JsonObject(root - "body") else JsonObject(root + ("body" to JsonPrimitive(body)))
        file.writeText(next.toString())
    }

    @Test
    fun offlineFallsBackToSnapshot() = runBlocking {
        val file = newFile()
        val transport = FakeTransport()
        val presets = store(file, transport).current("zh-Hans")
        assertNotNull("offline presets for zh-Hans", presets)
        assertEquals("offline equals decode(localize(snapshot))", offline("zh-Hans"), presets)
        assertEquals("offline revision", snapshotRevision, presets!!.revision)
        assertEquals("offline locale", "zh-Hans", presets.locale)
        assertEquals("first style name localized", "\u5199\u5b9e\u6444\u5f71", presets.styles.first().displayName)
        assertEquals("current never fetches", 0, transport.requests.size)

        // A persisted body that no longer decodes falls back to the snapshot as well.
        val broken = newFile()
        seeded(broken, transport)
        replaceBody(broken, "{not json")
        assertEquals("undecodable body falls back", offline("en"), store(broken, FakeTransport()).current("en"))

        val unreadable = StudioPresetsStore(newFile(), transport::fetch, { throw IOException("no asset") }, { T0 })
        assertNull("unreadable snapshot gives null", unreadable.current("en"))
    }

    @Test
    fun replacedPersistsAcrossInstances() = runBlocking {
        val file = newFile()
        val transport = FakeTransport()
        seeded(file, transport)
        assertEquals("first fetch locale", "en", transport.requests.single().locale)
        assertNull("first fetch has no If-None-Match", transport.requests.single().ifNoneMatch)
        val cache = stored(file).getValue("cache").jsonObject
        assertEquals("persisted cache revision", REVISION_2, cache.getValue("revision").jsonPrimitive.content)
        assertEquals("persisted cache etag", "\"r2\"", cache.getValue("etag").jsonPrimitive.content)

        val reopened = store(file, FakeTransport())
        val presets = reopened.current("en")
        assertEquals("persisted revision", REVISION_2, presets?.revision)
        assertEquals("persisted styles", offline("en").styles, presets?.styles)
        assertEquals("other locale uses snapshot", offline("ja"), reopened.current("ja"))
    }

    @Test
    fun throttledWithinSixHours() = runBlocking {
        val file = newFile()
        val transport = FakeTransport()
        val store = seeded(file, transport)
        val sixHours = StudioPresets.REFRESH_INTERVAL_MS

        assertEquals("throttled just before 6h", StudioPresets.Outcome.THROTTLED, store.refreshIfNeeded("en", T0 + sixHours - 1))
        assertEquals("no request while throttled", 1, transport.requests.size)

        transport.next = { StudioPresets.Response(200, "\"r2\"", networkBody("en", REVISION_2)) }
        assertEquals("same revision is unchanged", StudioPresets.Outcome.UNCHANGED, store.refreshIfNeeded("en", T0 + sixHours))
        assertEquals("fetched at 6h", 2, transport.requests.size)
        assertEquals("If-None-Match carries etag", "\"r2\"", transport.requests.last().ifNoneMatch)

        // The default clock argument comes from the injected clock; checkedAtMs moved to T0 + 6h.
        assertEquals(
            "throttled by injected clock",
            StudioPresets.Outcome.THROTTLED,
            store(file, transport, now = T0 + sixHours + 1).refreshIfNeeded("en"),
        )
        assertEquals("still two requests", 2, transport.requests.size)
    }

    @Test
    fun notModifiedKeepsBody() = runBlocking {
        val file = newFile()
        val transport = FakeTransport()
        val store = seeded(file, transport)
        val at = T0 + StudioPresets.REFRESH_INTERVAL_MS

        transport.next = { StudioPresets.Response(304, null, null) }
        assertEquals("304 outcome", StudioPresets.Outcome.NOT_MODIFIED, store.refreshIfNeeded("en", at))
        assertEquals("body kept after 304", REVISION_2, store.current("en")?.revision)
        val cache = stored(file).getValue("cache").jsonObject
        assertEquals("etag kept after 304", "\"r2\"", cache.getValue("etag").jsonPrimitive.content)
        assertEquals("checkedAtMs moved", at, cache.getValue("checkedAtMs").jsonPrimitive.long)
        assertEquals("body kept on disk", REVISION_2, store(file, FakeTransport()).current("en")?.revision)

        assertEquals("throttled after 304", StudioPresets.Outcome.THROTTLED, store.refreshIfNeeded("en", at + 1))
        assertEquals("two requests", 2, transport.requests.size)
    }

    @Test
    fun failureKeepsCache() = runBlocking {
        val file = newFile()
        val transport = FakeTransport()
        val store = seeded(file, transport)
        val at = T0 + StudioPresets.REFRESH_INTERVAL_MS
        val before = file.readText()

        transport.next = { throw IOException("offline") }
        assertEquals("IOException is a failure", StudioPresets.Outcome.FAILED, store.refreshIfNeeded("en", at))
        transport.next = { StudioPresets.Response(500, null, null) }
        assertEquals("500 is a failure", StudioPresets.Outcome.FAILED, store.refreshIfNeeded("en", at + 1))
        transport.next = { StudioPresets.Response(200, "\"r3\"", "{\"code\":0,\"data\":{}}") }
        assertEquals("bad body is invalid", StudioPresets.Outcome.INVALID, store.refreshIfNeeded("en", at + 2))

        assertEquals("failures never write", before, file.readText())
        assertEquals("cache body kept", REVISION_2, store.current("en")?.revision)
        assertEquals("failures are not throttled", 4, transport.requests.size)
    }

    @Test
    fun localeChangeRefetches() = runBlocking {
        val file = newFile()
        val transport = FakeTransport()
        val store = seeded(file, transport)

        transport.next = { StudioPresets.Response(200, "\"j1\"", networkBody("ja", REVISION_2)) }
        assertEquals("ja replaced", StudioPresets.Outcome.REPLACED, store.refreshIfNeeded("ja", T0 + 1))
        val request = transport.requests.last()
        assertEquals("locale in request", "ja", request.locale)
        assertNull("no If-None-Match across locales", request.ifNoneMatch)
        assertEquals("ja from cache", "ja", store.current("ja")?.locale)
        assertEquals("ja revision from cache", REVISION_2, store.current("ja")?.revision)
        assertEquals("en falls back to snapshot", offline("en"), store.current("en"))
    }

    @Test
    fun corruptBodyRefetchesWithoutEtag() = runBlocking {
        for (body in listOf<String?>("{not json", null)) {
            val label = if (body == null) "missing body" else "undecodable body"
            val file = newFile()
            val transport = FakeTransport()
            seeded(file, transport)
            replaceBody(file, body)

            val reopened = store(file, transport, now = T0 + 1)
            assertEquals("$label: snapshot served", offline("en"), reopened.current("en"))
            transport.next = { StudioPresets.Response(200, "\"r4\"", networkBody("en", REVISION_2)) }
            assertEquals("$label: refetched at once", StudioPresets.Outcome.REPLACED, reopened.refreshIfNeeded("en"))
            assertEquals("$label: two requests", 2, transport.requests.size)
            assertNull("$label: no If-None-Match", transport.requests.last().ifNoneMatch)
            assertEquals("$label: healed body", REVISION_2, store(file, FakeTransport()).current("en")?.revision)
        }
    }

    @Test
    fun concurrentRefreshSharesOneRequest() = runBlocking {
        val file = newFile()
        val transport = FakeTransport()
        val entered = CompletableDeferred<Unit>()
        val gate = CompletableDeferred<Unit>()
        transport.next = {
            entered.complete(Unit)
            gate.await()
            StudioPresets.Response(200, "\"r2\"", networkBody("en", REVISION_2))
        }
        val store = store(file, transport)
        val first = async { store.refreshIfNeeded("en", T0) }
        val second = async { store.refreshIfNeeded("en", T0) }
        entered.await()
        gate.complete(Unit)
        assertEquals("first caller outcome", StudioPresets.Outcome.REPLACED, first.await())
        assertEquals("second caller shares the result", StudioPresets.Outcome.REPLACED, second.await())
        assertEquals("one request for both callers", 1, transport.requests.size)
        assertEquals("later call is throttled", StudioPresets.Outcome.THROTTLED, store.refreshIfNeeded("en", T0 + 1))
        assertEquals("still one request", 1, transport.requests.size)
    }

    @Test
    fun differentLocaleRefreshWaitsForInFlight() = runBlocking {
        val file = newFile()
        val transport = FakeTransport()
        val jaEntered = CompletableDeferred<Unit>()
        val deEntered = CompletableDeferred<Unit>()
        val gate = CompletableDeferred<Unit>()
        transport.next = {
            if (transport.requests.last().locale == "ja") {
                jaEntered.complete(Unit)
                gate.await()
                StudioPresets.Response(200, "\"j1\"", networkBody("ja", REVISION_2))
            } else {
                deEntered.complete(Unit)
                StudioPresets.Response(500, null, null)
            }
        }
        val store = store(file, transport)
        val ja = async { store.refreshIfNeeded("ja", T0) }
        jaEntered.await()
        val de = async { store.refreshIfNeeded("de", T0) }
        assertNull("de does not fetch while ja is in flight", withTimeoutOrNull(300) { deEntered.await() })
        assertEquals("one request before the gate opens", 1, transport.requests.size)

        gate.complete(Unit)
        assertEquals("ja keeps its own outcome", StudioPresets.Outcome.REPLACED, ja.await())
        assertEquals("de plans and fetches on its own", StudioPresets.Outcome.FAILED, de.await())
        assertEquals("requests in order", listOf("ja", "de"), transport.requests.map { it.locale })
        assertNull("de request has no If-None-Match", transport.requests.last().ifNoneMatch)
        assertEquals("ja cache survives the de failure", "ja", store.current("ja")?.locale)
        assertEquals("ja revision from cache", REVISION_2, store.current("ja")?.revision)
    }

    @Test
    fun oversizedBodyIsInvalid() = runBlocking {
        val file = newFile()
        val transport = FakeTransport()
        val base = networkBody("en", REVISION_2)
        val padding = StudioPresetsStore.MAX_BODY_BYTES - base.toByteArray().size + 1
        // Trailing JSON whitespace keeps the body decodable, so only the size makes it invalid.
        val oversized = base + " ".repeat(padding)
        transport.next = { StudioPresets.Response(200, "\"big\"", oversized) }
        assertEquals("over 1 MiB is invalid", StudioPresets.Outcome.INVALID, store(file, transport).refreshIfNeeded("en", T0))
        assertEquals("nothing persisted", false, file.exists())

        val atLimit = base + " ".repeat(padding - 1)
        transport.next = { StudioPresets.Response(200, "\"fit\"", atLimit) }
        assertEquals("exactly 1 MiB is accepted", StudioPresets.Outcome.REPLACED, store(file, transport).refreshIfNeeded("en", T0))
    }

    @Test
    fun transportSendsConditionalRequest() {
        class Seen(val path: String, val query: String?, val ifNoneMatch: String?, val accept: String?)
        val seen = CopyOnWriteArrayList<Seen>()
        val server = HttpServer.create(InetSocketAddress(InetAddress.getLoopbackAddress(), 0), 0)
        server.createContext("/") { exchange ->
            val inm = exchange.requestHeaders.getFirst("If-None-Match")
            seen += Seen(exchange.requestURI.rawPath, exchange.requestURI.rawQuery, inm, exchange.requestHeaders.getFirst("Accept"))
            if (inm != null) {
                exchange.responseHeaders.add("ETag", "W/\"r3\"")
                exchange.sendResponseHeaders(304, -1)
            } else {
                val bytes = "{\"code\":0}".toByteArray()
                exchange.responseHeaders.add("ETag", "\"r4\"")
                exchange.sendResponseHeaders(200, bytes.size.toLong())
                exchange.responseBody.use { it.write(bytes) }
            }
            exchange.close()
        }
        server.start()
        try {
            val transport = HttpStudioPresetsTransport { "http://127.0.0.1:${server.address.port}/" }
            val tag = "zh_Hant-TW.~ /\u00e9"
            val notModified = runBlocking { transport.fetch(tag, "\"r2\"") }
            assertEquals("304 status", 304, notModified.status)
            assertEquals("ETag read verbatim", "W/\"r3\"", notModified.etag)
            assertNull("304 has no body", notModified.body)
            val first = seen.single()
            assertEquals("path", "/api/studio/presets", first.path)
            assertEquals("RFC 3986 query encoding", "locale=zh_Hant-TW.~%20%2F%C3%A9", first.query)
            assertEquals("If-None-Match sent", "\"r2\"", first.ifNoneMatch)
            assertEquals("Accept", "application/json", first.accept)

            val ok = runBlocking { transport.fetch("en", null) }
            assertEquals("200 status", 200, ok.status)
            assertEquals("200 ETag", "\"r4\"", ok.etag)
            assertEquals("200 body", "{\"code\":0}", ok.body)
            assertNull("no If-None-Match without etag", seen.last().ifNoneMatch)
        } finally {
            server.stop(0)
        }
    }

    private companion object {
        const val T0 = 1_800_000_000_000L
        const val REVISION_2 = "2026-11-01.1"
    }
}
