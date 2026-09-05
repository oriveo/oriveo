package ai.oriveo.community.core.data.remote

import android.content.Context
import android.content.SharedPreferences
import ai.oriveo.community.core.data.dao.MetadataCacheDao
import ai.oriveo.community.core.data.entity.MetadataCacheEntity
import ai.oriveo.community.testing.TestSharedPreferences
import io.mockk.every
import io.mockk.just
import io.mockk.mockk
import io.mockk.runs
import io.mockk.verify
import java.io.IOException
import java.net.ConnectException
import java.net.SocketException
import java.net.SocketTimeoutException
import java.net.UnknownHostException
import javax.net.ssl.SSLException
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class MetadataClientR3BTest {

    @Test
    fun `cold initialize persists Room and later refresh sends If-None-Match`() = runTest {
        val prefs = TestSharedPreferences()
        val context = metadataContext(prefs)
        val dao = FakeMetadataCacheDao()
        val validators = mutableListOf<String?>()
        val responses = ArrayDeque(
            listOf(
                successResponse(version = 86, eTag = "\"etag-86\""),
                MetadataTransportResponse(304, "\"etag-86\"", null, 0),
            )
        )
        var now = 1_000L
        val client = MetadataClient(
            metadataCacheDao = dao,
            metadataTransport = MetadataTransport { validator ->
                validators += validator
                responses.removeFirst()
            },
            nowMillis = { now },
            failureReporter = { error("unexpected failure: $it") },
        )

        client.initialize(context)
        now = 2_000L
        client.refresh()

        assertEquals(listOf(null, "\"etag-86\""), validators)
        assertEquals(86, client.version)
        assertEquals(MetadataClient.MetadataSource.FreshNetwork, client.metadataSource)
        assertTrue(client.snapshotConfirmedThisSession)
        assertEquals(2, dao.upsertCount)
        assertEquals(86, dao.entity?.version)
        assertEquals(2_000L, dao.entity?.updatedAtMs)
        assertTrue(dao.entity?.payload.orEmpty().contains("\"eTag\":\"\\\"etag-86\\\"\""))
        assertFalse(prefs.contains(LEGACY_CACHE_KEY))
        assertFalse(prefs.contains(LEGACY_ETAG_KEY))
    }

    @Test
    fun `legacy SharedPreferences cache migrates once and stale refresh reuses ETag`() = runTest {
        val legacyPayload = legacyCachePayload(version = 41, contractVersion = 1, eTag = "\"legacy-etag\"")
        val prefs = TestSharedPreferences().apply {
            edit()
                .putString(LEGACY_CACHE_KEY, legacyPayload)
                .putString(LEGACY_ETAG_KEY, "\"legacy-etag\"")
                .commit()
        }
        val context = metadataContext(prefs)
        val dao = FakeMetadataCacheDao()
        val validators = mutableListOf<String?>()
        val client = MetadataClient(
            metadataCacheDao = dao,
            metadataTransport = MetadataTransport { validator ->
                validators += validator
                MetadataTransportResponse(304, "\"legacy-etag\"", null, 0)
            },
            nowMillis = { 100_000_000L },
            failureReporter = { error("unexpected failure: $it") },
        )

        client.initialize(context)

        assertEquals(listOf("\"legacy-etag\""), validators)
        assertEquals(41, client.version)
        assertEquals(MetadataClient.MetadataSource.CachedOffline, client.metadataSource)
        assertTrue(client.snapshotConfirmedThisSession)
        assertEquals(2, dao.upsertCount)
        assertNotNull(dao.entity)
        assertFalse(prefs.contains(LEGACY_CACHE_KEY))
        assertFalse(prefs.contains(LEGACY_ETAG_KEY))
    }

    @Test
    fun `fresh migrated cache refreshes in background with ETag`() = runTest {
        val legacyPayload = legacyCachePayload(version = 42, contractVersion = 1, eTag = "\"fresh-etag\"")
        val prefs = TestSharedPreferences().apply {
            edit()
                .putString(LEGACY_CACHE_KEY, legacyPayload)
                .putString(LEGACY_ETAG_KEY, "\"fresh-etag\"")
                .commit()
        }
        val validators = mutableListOf<String?>()
        val client = MetadataClient(
            backgroundScope = this,
            ioDispatcher = StandardTestDispatcher(testScheduler),
            metadataCacheDao = FakeMetadataCacheDao(),
            metadataTransport = MetadataTransport { validator ->
                validators += validator
                MetadataTransportResponse(304, "\"fresh-etag\"", null, 0)
            },
            nowMillis = { 2L },
            failureReporter = { error("unexpected failure: $it") },
        )

        client.initialize(metadataContext(prefs))
        advanceUntilIdle()

        assertEquals(listOf("\"fresh-etag\""), validators)
        assertEquals(42, client.version)
        assertFalse(prefs.contains(LEGACY_CACHE_KEY))
        assertFalse(prefs.contains(LEGACY_ETAG_KEY))
    }

    @Test
    fun `out of window cache clears validator and takes cold path`() = runTest {
        val legacyPayload = legacyCachePayload(
            version = 50,
            contractVersion = MetadataClient.SUPPORTED_CONTRACT_VERSION + 2,
            eTag = "\"incompatible-etag\"",
        )
        val prefs = TestSharedPreferences().apply {
            edit()
                .putString(LEGACY_CACHE_KEY, legacyPayload)
                .putString(LEGACY_ETAG_KEY, "\"incompatible-etag\"")
                .commit()
        }
        val dao = FakeMetadataCacheDao()
        val validators = mutableListOf<String?>()
        val client = MetadataClient(
            metadataCacheDao = dao,
            metadataTransport = MetadataTransport { validator ->
                validators += validator
                successResponse(version = 51, eTag = "\"etag-51\"")
            },
            nowMillis = { 100_000_000L },
            failureReporter = { error("unexpected failure: $it") },
        )

        client.initialize(metadataContext(prefs))

        assertEquals(listOf(null), validators)
        assertEquals(51, client.version)
        assertEquals(1, dao.clearCount)
        // Old prefs are migrated first; a new snapshot is written after the stale-window cleanup.
        assertEquals(2, dao.upsertCount)
        assertFalse(prefs.contains(LEGACY_CACHE_KEY))
        assertFalse(prefs.contains(LEGACY_ETAG_KEY))
    }

    @Test
    fun `Room read cancellation propagates without fallback or reporting`() = runTest {
        val reports = mutableListOf<Map<String, String>>()
        val dao = FakeMetadataCacheDao().apply {
            readFailure = CancellationException("cancel read")
        }
        var transportCalls = 0
        val client = MetadataClient(
            metadataCacheDao = dao,
            metadataTransport = MetadataTransport {
                transportCalls += 1
                successResponse(version = 70, eTag = "\"etag-70\"")
            },
            failureReporter = { reports += it },
        )

        val cancelled = expectCancellation {
            client.initialize(metadataContext(TestSharedPreferences()))
        }

        assertEquals("cancel read", cancelled.message)
        assertEquals(0, transportCalls)
        assertTrue(reports.isEmpty())
    }

    @Test
    fun `corrupt Room clear cancellation propagates instead of falling through`() = runTest {
        val reports = mutableListOf<Map<String, String>>()
        val dao = FakeMetadataCacheDao(
            entity = MetadataCacheEntity(
                payload = "not-json",
                version = 70,
                contractVersion = 1,
                updatedAtMs = 1L,
            )
        ).apply {
            clearFailure = CancellationException("cancel clear")
        }
        var transportCalls = 0
        val client = MetadataClient(
            metadataCacheDao = dao,
            metadataTransport = MetadataTransport {
                transportCalls += 1
                successResponse(version = 71, eTag = "\"etag-71\"")
            },
            failureReporter = { reports += it },
        )

        val cancelled = expectCancellation {
            client.initialize(metadataContext(TestSharedPreferences()))
        }

        assertEquals("cancel clear", cancelled.message)
        assertEquals(0, transportCalls)
        assertEquals(listOf("cache_decode"), reports.map { it["phase"] })
    }

    @Test
    fun `legacy migration write cancellation propagates and keeps preferences`() = runTest {
        val legacyPayload = legacyCachePayload(version = 72, contractVersion = 1, eTag = "\"legacy-72\"")
        val prefs = TestSharedPreferences().apply {
            edit()
                .putString(LEGACY_CACHE_KEY, legacyPayload)
                .putString(LEGACY_ETAG_KEY, "\"legacy-72\"")
                .commit()
        }
        val reports = mutableListOf<Map<String, String>>()
        val dao = FakeMetadataCacheDao().apply {
            upsertFailure = CancellationException("cancel migration")
        }
        val client = MetadataClient(
            metadataCacheDao = dao,
            failureReporter = { reports += it },
        )

        val cancelled = expectCancellation {
            client.initialize(metadataContext(prefs))
        }

        assertEquals("cancel migration", cancelled.message)
        assertTrue(prefs.contains(LEGACY_CACHE_KEY))
        assertTrue(prefs.contains(LEGACY_ETAG_KEY))
        assertTrue(reports.isEmpty())
    }

    @Test
    fun `out of window Room clear exception reports but still clears prefs and cold fetches`() = runTest {
        val dao = FakeMetadataCacheDao()
        MetadataClient(
            metadataCacheDao = dao,
            metadataTransport = MetadataTransport {
                successResponse(
                    version = 73,
                    contractVersion = MetadataClient.SUPPORTED_CONTRACT_VERSION + 2,
                    eTag = "\"incompatible-73\"",
                )
            },
            nowMillis = { 1L },
            failureReporter = { error("unexpected producer failure: $it") },
        ).fetchMetadataForTesting()

        dao.clearFailure = IOException("Room path must not leak")
        val prefs = mockk<SharedPreferences>()
        val editor = mockk<SharedPreferences.Editor>(relaxed = true)
        every { prefs.edit() } returns editor
        every { editor.remove(any()) } returns editor
        val reports = mutableListOf<Map<String, String>>()
        val validators = mutableListOf<String?>()
        val client = MetadataClient(
            metadataCacheDao = dao,
            metadataTransport = MetadataTransport { validator ->
                validators += validator
                successResponse(version = 74, eTag = "\"etag-74\"")
            },
            nowMillis = { 100_000_000L },
            failureReporter = {
                reports += it
                throw IllegalStateException("reporter failure must not block cleanup")
            },
        )

        client.initialize(metadataContext(prefs))

        assertEquals(listOf(null), validators)
        assertEquals(74, client.version)
        assertEquals(1, dao.clearCount)
        assertEquals("cache_clear", reports.single()["phase"])
        assertEquals("IOException", reports.single()["exception_class"])
        assertFalse(reports.single().values.any { it.contains("Room path") })
        verify(exactly = 2) { editor.remove(LEGACY_CACHE_KEY) }
        verify(exactly = 2) { editor.remove(LEGACY_ETAG_KEY) }
    }

    @Test
    fun `out of window Room clear Error is reported and rethrown without fetching`() = runTest {
        val dao = FakeMetadataCacheDao()
        MetadataClient(
            metadataCacheDao = dao,
            metadataTransport = MetadataTransport {
                successResponse(
                    version = 75,
                    contractVersion = MetadataClient.SUPPORTED_CONTRACT_VERSION + 2,
                    eTag = "\"incompatible-75\"",
                )
            },
            nowMillis = { 1L },
            failureReporter = { error("unexpected producer failure: $it") },
        ).fetchMetadataForTesting()

        dao.clearFailure = AssertionError("fatal clear")
        val reports = mutableListOf<Map<String, String>>()
        var transportCalls = 0
        val client = MetadataClient(
            metadataCacheDao = dao,
            metadataTransport = MetadataTransport {
                transportCalls += 1
                successResponse(version = 76, eTag = "\"etag-76\"")
            },
            nowMillis = { 100_000_000L },
            failureReporter = { reports += it },
        )

        var rethrown: AssertionError? = null
        try {
            client.initialize(metadataContext(TestSharedPreferences()))
        } catch (error: AssertionError) {
            rethrown = error
        }

        assertEquals("fatal clear", rethrown?.message)
        assertEquals(0, transportCalls)
        assertEquals("cache_clear", reports.single()["phase"])
        assertEquals("AssertionError", reports.single()["exception_class"])
    }

    @Test
    fun `304 cache write exception is reported after confirmation without replacing snapshot`() = runTest {
        val dao = FakeMetadataCacheDao()
        MetadataClient(
            metadataCacheDao = dao,
            metadataTransport = MetadataTransport {
                successResponse(version = 77, eTag = "\"etag-77\"")
            },
            nowMillis = { 1L },
            failureReporter = { error("unexpected producer failure: $it") },
        ).fetchMetadataForTesting()
        val originalEntity = dao.entity
        dao.upsertFailure = IOException("database location must not leak")

        val reports = mutableListOf<Map<String, String>>()
        val client = MetadataClient(
            metadataCacheDao = dao,
            metadataTransport = MetadataTransport {
                MetadataTransportResponse(304, "\"etag-77\"", null, 0)
            },
            nowMillis = { 100_000_000L },
            failureReporter = { reports += it },
        )

        client.initialize(metadataContext(TestSharedPreferences()))

        assertEquals(77, client.version)
        assertTrue(client.snapshotConfirmedThisSession)
        assertEquals(originalEntity, dao.entity)
        assertEquals("cache_write", reports.single()["phase"])
        assertEquals("304", reports.single()["status"])
        assertEquals("IOException", reports.single()["exception_class"])
        assertFalse(reports.single().values.any { it.contains("database location") })
    }

    @Test
    fun `304 cache write cancellation propagates after confirming current snapshot`() = runTest {
        val dao = FakeMetadataCacheDao()
        MetadataClient(
            metadataCacheDao = dao,
            metadataTransport = MetadataTransport {
                successResponse(version = 78, eTag = "\"etag-78\"")
            },
            nowMillis = { 1L },
            failureReporter = { error("unexpected producer failure: $it") },
        ).fetchMetadataForTesting()
        dao.upsertFailure = CancellationException("cancel 304 write")

        val reports = mutableListOf<Map<String, String>>()
        val client = MetadataClient(
            metadataCacheDao = dao,
            metadataTransport = MetadataTransport {
                MetadataTransportResponse(304, "\"etag-78\"", null, 0)
            },
            nowMillis = { 100_000_000L },
            failureReporter = { reports += it },
        )

        val cancelled = expectCancellation {
            client.initialize(metadataContext(TestSharedPreferences()))
        }

        assertEquals("cancel 304 write", cancelled.message)
        assertEquals(78, client.version)
        assertTrue(client.snapshotConfirmedThisSession)
        assertTrue(reports.isEmpty())
    }

    @Test
    fun `bare and wrapped payloads share one wire decoder`() {
        val client = MetadataClient()

        client.loadNetworkPayloadForTesting(metadataPayload(version = 60), "etag-bare")
        assertEquals(60, client.version)

        client.loadNetworkPayloadForTesting(
            """{"code":0,"\u0064ata":${metadataPayload(version = 61)}}""",
            "etag-wrapped",
        )
        assertEquals(61, client.version)
    }

    @Test
    fun `http and decode failures report only bounded diagnostics`() = runTest {
        val reports = mutableListOf<Map<String, String>>()
        val secretBody = """{"data":{"providerConfigs":[{"displayName":"SECRET_SHOULD_NOT_LEAK"}]}}"""
        val responses = ArrayDeque(
            listOf(
                MetadataTransportResponse(503, null, null, 321),
                MetadataTransportResponse(200, null, secretBody, secretBody.toByteArray().size.toLong()),
            )
        )
        var now = 10L
        val client = MetadataClient(
            metadataTransport = MetadataTransport { responses.removeFirst() },
            nowMillis = { now.also { now += 7 } },
            failureReporter = { reports += it },
        )

        client.fetchMetadataForTesting()
        client.fetchMetadataForTesting()

        assertEquals(2, reports.size)
        assertEquals(
            setOf("phase", "duration_ms", "response_bytes", "status", "exception_class", "has_snapshot"),
            reports[0].keys,
        )
        // A cold-start first fetch failing means the user has no catalog at all yet, which must
        // be distinguishable from "background refresh failed but the existing catalog still works".
        assertEquals("false", reports[0]["has_snapshot"])
        assertEquals("fetch", reports[0]["phase"])
        assertEquals("503", reports[0]["status"])
        assertEquals("321", reports[0]["response_bytes"])
        assertEquals("MetadataHttpStatusException", reports[0]["exception_class"])
        assertEquals("decode", reports[1]["phase"])
        assertEquals("200", reports[1]["status"])
        assertTrue(reports[1]["exception_class"].orEmpty().contains("MissingFieldException"))
        assertFalse(reports.flatMap { it.values }.any { it.contains("SECRET_SHOULD_NOT_LEAK") })
        assertEquals(0, client.version)
    }

    @Test
    fun `transport exception is observed while Error is observed and rethrown`() = runTest {
        val exceptionReports = mutableListOf<Map<String, String>>()
        val exceptionClient = MetadataClient(
            metadataTransport = MetadataTransport { throw IOException("private host must not leak") },
            nowMillis = { 1L },
            failureReporter = { exceptionReports += it },
        )

        exceptionClient.fetchMetadataForTesting()

        assertEquals("fetch", exceptionReports.single()["phase"])
        assertEquals("none", exceptionReports.single()["status"])
        assertEquals("0", exceptionReports.single()["response_bytes"])
        assertEquals("IOException", exceptionReports.single()["exception_class"])
        assertFalse(exceptionReports.single().values.any { it.contains("private host") })

        val errorReports = mutableListOf<Map<String, String>>()
        val errorClient = MetadataClient(
            metadataTransport = MetadataTransport { throw AssertionError("fatal") },
            nowMillis = { 2L },
            failureReporter = {
                errorReports += it
                throw IllegalStateException("reporter failed")
            },
        )

        var rethrown: AssertionError? = null
        try {
            errorClient.fetchMetadataForTesting()
        } catch (error: AssertionError) {
            rethrown = error
        }
        assertNotNull(rethrown)
        assertEquals("fatal", rethrown?.message)
        assertEquals("AssertionError", errorReports.single()["exception_class"])
    }

    @Test
    fun `transient network transport failures stay out of the failure reporter`() = runTest {
        // Consistent with the global noise-reduction applied to error reports: a captured
        // message without a throwable slips past that filter, so reportFailure must filter out
        // user network flakiness on its own (a connection-reset SocketException from restrictive
        // network conditions was showing up as a warning in the error stream). Server-side
        // 4xx/5xx and decode failures are still reported, guarded by
        // `http and decode failures report only bounded diagnostics` above.
        val reports = mutableListOf<Map<String, String>>()
        val failures = ArrayDeque<Throwable>(
            listOf(
                SocketException("Connection reset"),
                UnknownHostException("api host"),
                SocketTimeoutException("read timed out"),
                ConnectException("Failed to connect"),
                SSLException("handshake aborted"),
                // okhttp/ktor commonly wrap the underlying socket exception another layer deep,
                // so the cause chain must be filtered too
                IOException("wrapped", SocketException("Connection reset by peer")),
            )
        )
        val total = failures.size
        val client = MetadataClient(
            metadataTransport = MetadataTransport { throw failures.removeFirst() },
            nowMillis = { 1L },
            failureReporter = { reports += it },
        )

        repeat(total) { client.fetchMetadataForTesting() }

        assertTrue(failures.isEmpty())
        assertTrue(reports.isEmpty())
        assertEquals(0, client.version)
    }

    @Test
    fun `oversized Room payload hydrates through chunked reads instead of one row read`() = runTest {
        // Older builds cached the full view (measured at 3.0MB in production) in
        // SharedPreferences. After migrating the whole blob into Room, every `SELECT *` exceeded
        // the CursorWindow limit and threw SQLiteBlobTooBigException -- the cache could never be
        // read back, and the same warning fired on every cold start.
        val prefs = TestSharedPreferences()
        val dao = FakeMetadataCacheDao(
            entity = MetadataCacheEntity(
                payload = oversizedRoomPayload(version = 90, eTag = "\"etag-90\""),
                version = 90,
                contractVersion = 1,
                updatedAtMs = 1L,
            )
        )
        val client = MetadataClient(
            metadataCacheDao = dao,
            metadataTransport = MetadataTransport { MetadataTransportResponse(304, "\"etag-90\"", null, 0) },
            nowMillis = { 100_000_000L },
            failureReporter = { error("unexpected failure: $it") },
        )

        client.initialize(metadataContext(prefs))

        assertEquals(90, client.version)
        assertEquals(MetadataClient.MetadataSource.CachedOffline, client.metadataSource)
        // Reading in a single chunk means this fixture never crossed the chunking threshold, so
        // it wouldn't actually be testing the real shape.
        assertTrue("an oversized payload must be retrieved in multiple chunks", dao.chunkReads > 1)
        // If it can be read back, the user's cache must not be discarded.
        assertEquals(0, dao.clearCount)
    }

    @Test
    fun `non-BMP payload survives chunked reassembly`() = runTest {
        // SQLite's length/substr count by code point, while Kotlin's String.length counts
        // UTF-16 units. Mixing the two causes the offset to drift with every non-BMP character,
        // reassembling into torn JSON.
        val prefs = TestSharedPreferences()
        val dao = FakeMetadataCacheDao(
            entity = MetadataCacheEntity(
                payload = oversizedRoomPayload(version = 91, eTag = "\"etag-91\"", filler = "🐾"),
                version = 91,
                contractVersion = 1,
                updatedAtMs = 1L,
            )
        )
        val client = MetadataClient(
            metadataCacheDao = dao,
            metadataTransport = MetadataTransport { MetadataTransportResponse(304, "\"etag-91\"", null, 0) },
            nowMillis = { 100_000_000L },
            failureReporter = { error("unexpected failure: $it") },
        )

        client.initialize(metadataContext(prefs))

        assertEquals(91, client.version)
        assertTrue(dao.chunkReads > 1)
    }

    @Test
    fun `failure reports group by phase and exception instead of by call site`() = runTest {
        // The same underlying message can otherwise get split into separate issues just because
        // the call stack differs. The grouping key must be determined only by phase + exception
        // type, and the assertions read from the tags reportFailure actually produces in production.
        val reports = mutableListOf<Map<String, String>>()
        // The step increases so the two failures get different duration_ms values -- a varying
        // tag must not split the same event into two groups.
        var tick = 0L
        var step = 0L
        val client = MetadataClient(
            metadataTransport = MetadataTransport { throw IOException("boom") },
            nowMillis = {
                tick.also {
                    step += 5
                    tick += step
                }
            },
            failureReporter = { reports += it },
        )

        client.fetchMetadataForTesting()
        client.fetchMetadataForTesting()

        assertEquals(2, reports.size)
        // Different durations, but the same event still groups together.
        assertTrue(reports[0]["duration_ms"] != reports[1]["duration_ms"])
        assertEquals(
            metadataFailureFingerprint(reports[0]),
            metadataFailureFingerprint(reports[1]),
        )
        assertEquals(
            listOf("metadata_client", "fetch", "IOException"),
            metadataFailureFingerprint(reports[0]),
        )
        // The title must say which step failed; a cache-read failure must not be labeled
        // "request failed" too.
        assertEquals("metadata fetch failed", metadataFailureMessage(reports[0]))
        assertEquals(
            "metadata cache_read failed",
            metadataFailureMessage(mapOf("phase" to "cache_read")),
        )
        assertEquals(
            listOf("metadata_client", "unknown", "unknown"),
            metadataFailureFingerprint(emptyMap()),
        )
    }

    /**
     * A valid RoomCacheEnvelope larger than [MetadataClient]'s chunking threshold (200_000
     * characters). The providers' displayName gets decoded/re-encoded as-is, making it the
     * cheapest controllable place to inflate; passing a non-BMP character as [filler] constructs
     * the "UTF-16 length != code point count" shape.
     */
    private fun oversizedRoomPayload(version: Int, eTag: String, filler: String = "x"): String {
        val blob = filler.repeat(6_000)
        val providers = (0 until 50).joinToString(",") { index ->
            """"provider$index":{"displayName":"$blob"}"""
        }
        val data = """{"version":$version,"contractVersion":1,"updatedAt":"2026-08-25T00:00:00Z","profiles":{},"providers":{$providers}}"""
        val encodedETag = eTag.replace("\"", "\\\"")
        return """{"data":$data,"timestamp":1,"eTag":"$encodedETag"}"""
    }

    private fun legacyCachePayload(version: Int, contractVersion: Int, eTag: String): String {
        val seed = MetadataClient()
        seed.loadNetworkPayloadForTesting(
            metadataPayload(version = version, contractVersion = contractVersion),
            eTag,
        )
        return requireNotNull(seed.encodedCachePayloadForTesting())
    }

    private fun metadataPayload(version: Int, contractVersion: Int = 1): String =
        """
        {
          "version": $version,
          "contractVersion": $contractVersion,
          "updatedAt": "2026-08-25T00:00:00Z",
          "profiles": {},
          "providers": {}
        }
        """.trimIndent()

    private fun successResponse(
        version: Int,
        eTag: String,
        contractVersion: Int = 1,
    ): MetadataTransportResponse {
        val body = metadataPayload(version, contractVersion)
        return MetadataTransportResponse(
            statusCode = 200,
            eTag = eTag,
            body = body,
            responseBytes = body.toByteArray().size.toLong(),
        )
    }

    private fun metadataContext(prefs: SharedPreferences): Context {
        val context = mockk<Context>()
        every { context.applicationContext } returns context
        every { context.getSharedPreferences(LEGACY_PREFS_NAME, Context.MODE_PRIVATE) } returns prefs
        return context
    }

    private suspend fun expectCancellation(block: suspend () -> Unit): CancellationException {
        try {
            block()
        } catch (cancelled: CancellationException) {
            return cancelled
        }
        throw AssertionError("expected CancellationException")
    }

    /**
     * Implements length/substr using SQLite's character (code point) semantics rather than
     * Kotlin's UTF-16 length -- faking it with UTF-16 semantics would make chunked reads "look
     * correct in the test but drift on real devices" for non-BMP characters.
     */
    private class FakeMetadataCacheDao(
        var entity: MetadataCacheEntity? = null,
    ) : MetadataCacheDao {
        var upsertCount = 0
        var clearCount = 0
        var readFailure: Throwable? = null
        var upsertFailure: Throwable? = null
        var clearFailure: Throwable? = null
        /** Number of chunked calls, proving a large payload didn't actually go through a single-row read. */
        var chunkReads = 0

        private fun payloadFor(key: String): String? =
            entity?.takeIf { it.key == key }?.payload

        override suspend fun payloadLength(key: String): Int? {
            readFailure?.let { throw it }
            val payload = payloadFor(key) ?: return null
            return payload.codePointCount(0, payload.length)
        }

        override suspend fun payloadChunk(start: Int, count: Int, key: String): String? {
            readFailure?.let { throw it }
            chunkReads += 1
            val payload = payloadFor(key) ?: return null
            val total = payload.codePointCount(0, payload.length)
            val startIndex = (start - 1).coerceIn(0, total)
            val endIndex = (startIndex + count).coerceAtMost(total)
            return payload.substring(
                payload.offsetByCodePoints(0, startIndex),
                payload.offsetByCodePoints(0, endIndex),
            )
        }

        override suspend fun upsert(entity: MetadataCacheEntity) {
            upsertCount += 1
            upsertFailure?.let { throw it }
            this.entity = entity
        }

        override suspend fun clear() {
            clearCount += 1
            clearFailure?.let { throw it }
            entity = null
        }
    }

    companion object {
        private const val LEGACY_PREFS_NAME = "oriveo_metadata"
        private const val LEGACY_CACHE_KEY = "oriveo:metadataCache"
        private const val LEGACY_ETAG_KEY = "oriveo:metadataETag"
    }
}
