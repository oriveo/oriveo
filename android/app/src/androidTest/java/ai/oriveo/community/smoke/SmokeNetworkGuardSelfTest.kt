package ai.oriveo.community.smoke

import androidx.test.ext.junit.runners.AndroidJUnit4
import java.io.IOException
import java.net.HttpURLConnection
import java.net.InetAddress
import java.net.URL
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Self-check of [SmokeNetworkGuard] on the platform HttpURLConnection (OkHttp2), the client that used to fall back to a
 * direct connection after the guard's refused proxy port. Only meaningful in a smoke run (`-e smoke true`).
 */
@RunWith(AndroidJUnit4::class)
class SmokeNetworkGuardSelfTest {
    private val server = MockWebServer()

    @Before
    fun setUp() {
        assertTrue("guard must be enabled (run through scripts/smoke-e2e-android.sh)", SmokeNetworkGuard.enabled)
        SmokeNetworkGuard.reset()
    }

    @After
    fun tearDown() {
        server.shutdown()
        SmokeNetworkGuard.reset()
    }

    @Test
    fun hurlconnection_external_blocked() {
        val connection = URL("https://$EXTERNAL_HOST/").openConnection() as HttpURLConnection
        connection.connectTimeout = 5_000
        connection.readTimeout = 5_000
        try {
            val code = connection.responseCode
            fail("external request must not succeed, got HTTP $code")
        } catch (expected: IOException) {
            // Failing through the fake proxy is the point; a direct connection would have answered.
        } finally {
            connection.disconnect()
        }
        val blocked = SmokeNetworkGuard.blocked()
        assertTrue("blocked must record $EXTERNAL_HOST: $blocked", blocked.any { it.startsWith("$EXTERNAL_HOST ") })
        val proxied = SmokeNetworkGuard.proxied()
        assertTrue("request must reach the fake proxy, not go direct: $proxied", EXTERNAL_HOST in proxied)
    }

    @Test
    fun loopback_allowed() {
        server.enqueue(MockResponse().setResponseCode(200).setBody("ok"))
        server.start(InetAddress.getByName(FakeProviderServer.LOOPBACK_HOST), 0)
        val url = URL("http://${FakeProviderServer.LOOPBACK_HOST}:${server.port}/ping")
        val connection = url.openConnection() as HttpURLConnection
        connection.connectTimeout = 5_000
        connection.readTimeout = 5_000
        try {
            assertEquals(200, connection.responseCode)
            assertEquals("ok", connection.inputStream.bufferedReader().use { it.readText() })
        } finally {
            connection.disconnect()
        }
        assertEquals(1, server.requestCount)
        assertTrue("loopback must be allowed: ${SmokeNetworkGuard.allowed()}", FakeProviderServer.LOOPBACK_HOST in SmokeNetworkGuard.allowed())
        assertTrue("loopback must not be blocked: ${SmokeNetworkGuard.blocked()}", SmokeNetworkGuard.blocked().isEmpty())
        // Background app traffic may be proxied meanwhile; only the loopback target itself must not be.
        val proxied = SmokeNetworkGuard.proxied()
        assertTrue("loopback must not be proxied: $proxied", FakeProviderServer.LOOPBACK_HOST !in proxied)
    }

    private companion object {
        const val EXTERNAL_HOST = "example.com"
    }
}
