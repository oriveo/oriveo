package ai.oriveo.community.core.voice

import ai.oriveo.community.core.model.ProviderKind
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.MockRequestHandleScope
import io.ktor.client.engine.mock.respond
import io.ktor.client.request.HttpRequestData
import io.ktor.client.request.HttpResponseData
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpStatusCode
import io.ktor.http.headersOf
import java.io.File
import java.io.IOException
import java.nio.file.Files
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class VoiceCatalogClientTest {

    private val cacheDir: File = Files.createTempDirectory("voice-catalog").toFile().resolve("voice")
    private val cacheFile: File get() = File(cacheDir, VoiceCatalogClient.CACHE_FILE_NAME)

    /** Real contract fixture (including data.view = "voice"). */
    private val contractBody: String =
        workspaceFile("shared/model-contracts/voice_catalog_contract.v2.json").readText()

    private val expectedCatalog: VoiceCatalog =
        VoiceCatalogDecoder.decode(Json.parseToJsonElement(contractBody).jsonObject["data"])

    private val requests = mutableListOf<HttpRequestData>()

    @After
    fun tearDown() {
        cacheDir.parentFile?.deleteRecursively()
    }

    private var now = 1_000_000L

    private fun client(handler: suspend MockRequestHandleScope.(HttpRequestData) -> HttpResponseData): VoiceCatalogClient {
        val engine = MockEngine { request ->
            requests += request
            handler(request)
        }
        return VoiceCatalogClient(HttpClient(engine), "https://meta.example.com/", cacheDir, clock = { now })
    }

    private fun MockRequestHandleScope.ok(body: String = contractBody, eTag: String? = "\"v1\"") = respond(
        content = body,
        status = HttpStatusCode.OK,
        headers = if (eTag != null) {
            headersOf(HttpHeaders.ContentType to listOf("application/json"), HttpHeaders.ETag to listOf(eTag))
        } else {
            headersOf(HttpHeaders.ContentType, "application/json")
        },
    )

    private fun MockRequestHandleScope.status(code: HttpStatusCode) = respond(content = "", status = code)

    /** Seeds the cache with a 200 first and returns the client after seeding. */
    private suspend fun seeded(): VoiceCatalogClient {
        val seed = client { ok() }
        assertEquals(VoiceCatalogState.Available(expectedCatalog), seed.refresh())
        assertTrue(cacheFile.isFile)
        requests.clear()
        return seed
    }

    @Test
    fun `200 decodes catalog and writes cache`() = runTest {
        val client = client { ok() }

        val state = client.refresh()

        assertEquals(VoiceCatalogState.Available(expectedCatalog), state)
        val catalog = (state as VoiceCatalogState.Available).catalog
        assertTrue(catalog.entries(ProviderKind.Grok, VoiceDirection.Stt).isNotEmpty())
        assertEquals(1, requests.size)
        assertEquals("/api/metadata", requests.single().url.encodedPath)
        assertEquals("voice", requests.single().url.parameters["view"])
        assertNull(requests.single().headers[HttpHeaders.IfNoneMatch])
        assertTrue(cacheFile.isFile)
        assertEquals("\"v1\"", cachedETag())
    }

    @Test
    fun `sends If-None-Match and 304 reuses cache`() = runTest {
        seeded()
        val client = client { status(HttpStatusCode.NotModified) }

        val state = client.refresh()

        assertEquals("\"v1\"", requests.single().headers[HttpHeaders.IfNoneMatch])
        assertEquals(VoiceCatalogState.Available(expectedCatalog), state)
        assertTrue(cacheFile.isFile)
    }

    @Test
    fun `404 is unavailable and deletes cache`() = runTest {
        seeded()
        val client = client { status(HttpStatusCode.NotFound) }

        assertEquals(VoiceCatalogState.Unavailable, client.refresh())
        assertFalse(cacheFile.exists())
        assertNull(client.loadCached())
    }

    @Test
    fun `5xx keeps previous cache`() = runTest {
        seeded()
        val client = client { status(HttpStatusCode.ServiceUnavailable) }

        assertEquals(VoiceCatalogState.Available(expectedCatalog), client.refresh())
        assertTrue(cacheFile.isFile)
    }

    @Test
    fun `network error keeps previous cache`() = runTest {
        seeded()
        val client = client { throw IOException("offline") }

        assertEquals(VoiceCatalogState.Available(expectedCatalog), client.refresh())
        assertTrue(cacheFile.isFile)
    }

    @Test
    fun `failure without cache is loadFailed`() = runTest {
        assertEquals(VoiceCatalogState.LoadFailed, client { status(HttpStatusCode.InternalServerError) }.refresh())
        assertEquals(VoiceCatalogState.LoadFailed, client { throw IOException("offline") }.refresh())
        assertEquals(VoiceCatalogState.LoadFailed, client { status(HttpStatusCode.NotModified) }.refresh())
        assertFalse(cacheFile.exists())
    }

    @Test
    fun `data view other than voice is a failure`() = runTest {
        val root = Json.parseToJsonElement(contractBody).jsonObject
        val data = root["data"]!!.jsonObject
        val wrongView = JsonObject(root + ("data" to JsonObject(data + ("view" to JsonPrimitive("lean"))))).toString()
        val missingView = JsonObject(root + ("data" to JsonObject(data - "view"))).toString()

        assertEquals(VoiceCatalogState.LoadFailed, client { ok(body = wrongView) }.refresh())
        assertEquals(VoiceCatalogState.LoadFailed, client { ok(body = missingView) }.refresh())
        assertFalse(cacheFile.exists())

        seeded()
        assertEquals(VoiceCatalogState.Available(expectedCatalog), client { ok(body = wrongView, eTag = "\"v2\"") }.refresh())
        assertEquals("\"v1\"", cachedETag())
    }

    @Test
    fun `new instance cold reads cache`() = runTest {
        seeded()

        val cold = VoiceCatalogClient(HttpClient(MockEngine { error("must not hit network") }), "https://meta.example.com", cacheDir)

        assertEquals(expectedCatalog, cold.loadCached())
    }

    @Test
    fun `state flow publishes cached then refreshed`() = runTest {
        seeded()
        val client = client { status(HttpStatusCode.NotFound) }
        assertNull(client.state.value)

        client.loadCached()
        assertEquals(VoiceCatalogState.Available(expectedCatalog), client.state.value)

        client.refresh()
        assertEquals(VoiceCatalogState.Unavailable, client.state.value)
    }

    @Test
    fun `ensureFresh refreshes when stale or empty`() = runTest {
        val gate = CompletableDeferred<Unit>()
        val client = client {
            gate.await()
            ok()
        }

        // state is null: two concurrent calls send only one request.
        val results = List(2) { async { client.ensureFresh() } }
        gate.complete(Unit)
        results.awaitAll().forEach { assertEquals(VoiceCatalogState.Available(expectedCatalog), it) }
        assertEquals(1, requests.size)
        assertNull(requests.single().headers[HttpHeaders.IfNoneMatch])

        // After 10 minutes: refresh again with the ETag.
        requests.clear()
        now += VoiceCatalogClient.STALE_AFTER_MS
        client.ensureFresh()
        assertEquals(1, requests.size)
        assertEquals("\"v1\"", requests.single().headers[HttpHeaders.IfNoneMatch])

        // Only cold-read the cache, never refreshed: still refresh.
        requests.clear()
        val cold = client { ok() }
        cold.loadCached()
        cold.ensureFresh()
        assertEquals(1, requests.size)
    }

    @Test
    fun `ensureFresh skips within ten minutes`() = runTest {
        val client = client { ok() }
        client.ensureFresh()
        requests.clear()

        now += VoiceCatalogClient.STALE_AFTER_MS - 1
        assertEquals(VoiceCatalogState.Available(expectedCatalog), client.ensureFresh())
        assertTrue(requests.isEmpty())
    }

    private fun cachedETag(): String? =
        (Json.parseToJsonElement(cacheFile.readText()).jsonObject["etag"] as? JsonPrimitive)?.content

    private fun workspaceFile(relative: String): File {
        var dir: File? = File("").absoluteFile
        while (dir != null) {
            val candidate = File(dir, relative)
            if (candidate.exists()) return candidate
            dir = dir.parentFile
        }
        throw IllegalStateException("Cannot find $relative")
    }
}
