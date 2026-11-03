package ai.oriveo.community.core.studio

import java.io.InterruptedIOException
import java.util.concurrent.TimeUnit
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Test

/** Studio call-level total timeout. */
class StudioHttpTransportTest {
    private val server = MockWebServer().also { it.start() }

    @After
    fun tearDown() {
        server.shutdown()
    }

    @Test
    fun `missing or non-positive timeout falls back to 180 seconds`() {
        assertEquals(180, StudioHttpTransport.totalTimeoutSeconds(null))
        assertEquals(180, StudioHttpTransport.totalTimeoutSeconds(0))
        assertEquals(180, StudioHttpTransport.totalTimeoutSeconds(-5))
        assertEquals(120, StudioHttpTransport.totalTimeoutSeconds(120))
        assertEquals(180, StudioHttpTransport.totalTimeoutSeconds(240))
    }

    @Test
    fun `call carries the total timeout from the profile`() {
        val transport = StudioHttpTransport(OkHttpClient(), isCompiledIn = true)
        val request = Request.Builder().url(server.url("/v1/images/generations")).build()
        assertEquals(TimeUnit.SECONDS.toNanos(120), transport.newCall(request, 120)!!.timeout().timeoutNanos())
        assertEquals(TimeUnit.SECONDS.toNanos(180), transport.newCall(request, 240)!!.timeout().timeoutNanos())
        assertEquals(TimeUnit.SECONDS.toNanos(180), transport.newCall(request, null)!!.timeout().timeoutNanos())
    }

    @Test
    fun `slow body that never stalls the socket still hits the total timeout`() {
        // Each chunk arrives well inside the read timeout, so only a call-level budget stops it.
        server.enqueue(
            MockResponse().setResponseCode(200).setBody("x".repeat(64))
                .throttleBody(8, 400, TimeUnit.MILLISECONDS),
        )
        val client = OkHttpClient.Builder().readTimeout(10, TimeUnit.SECONDS).build()
        val transport = StudioHttpTransport(client, isCompiledIn = true)
        val request = Request.Builder().url(server.url("/v1/images/generations")).build()
        val error = assertThrows(InterruptedIOException::class.java) {
            transport.execute(request, timeoutSeconds = 1)!!.use { it.body.string() }
        }
        assertEquals("timeout", error.message)
    }

    @Test
    fun `fast response completes within the budget`() {
        server.enqueue(MockResponse().setResponseCode(200).setBody("{\"data\":[]}"))
        val transport = StudioHttpTransport(OkHttpClient(), isCompiledIn = true)
        val request = Request.Builder().url(server.url("/v1/images/generations")).build()
        transport.execute(request, timeoutSeconds = 5)!!.use { assertEquals("{\"data\":[]}", it.body.string()) }
    }

    @Test
    fun `compiled out builds no call and sends nothing`() {
        val transport = StudioHttpTransport(OkHttpClient(), isCompiledIn = false)
        val request = Request.Builder().url(server.url("/")).build()
        assertNull(transport.newCall(request, null))
        assertNull(transport.execute(request, null))
        assertEquals(0, server.requestCount)
    }
}
