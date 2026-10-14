package ai.oriveo.community.di

import io.ktor.client.engine.KTOR_DEFAULT_USER_AGENT
import okhttp3.Interceptor
import okhttp3.OkHttpClient
import okhttp3.Protocol
import okhttp3.Request
import okhttp3.Response
import okhttp3.ResponseBody.Companion.toResponseBody
import org.junit.Assert.assertEquals
import org.junit.Test

/** Regression: the OkHttp interceptor used to overwrite the UA unconditionally, which made the Relay customUserAgent and the Codex identity UA ineffective on the wire. */
@OptIn(io.ktor.utils.io.InternalAPI::class)
class NativeUserAgentInterceptorTest {
    private val native = "Oriveo/9.9.9 (Android 15)"

    private fun outboundUserAgent(userAgent: String?): String? {
        var seen: String? = null
        // The terminal interceptor answers in place, so the request never leaves the process
        val terminal = Interceptor { chain ->
            seen = chain.request().header("User-Agent")
            Response.Builder()
                .request(chain.request())
                .protocol(Protocol.HTTP_1_1)
                .code(200)
                .message("OK")
                .body("".toResponseBody(null))
                .build()
        }
        val client = OkHttpClient.Builder()
            .addInterceptor(nativeUserAgentInterceptor { native })
            .addInterceptor(terminal)
            .build()
        val request = Request.Builder().url("https://relay.example.com/v1/chat/completions")
            .apply { userAgent?.let { header("User-Agent", it) } }
            .build()
        client.newCall(request).execute().close()
        return seen
    }

    @Test
    fun `custom user agent survives the interceptor`() {
        assertEquals("my-relay-client/1.0", outboundUserAgent("my-relay-client/1.0"))
        assertEquals(
            "codex_cli_rs/0.162.1 (Oriveo Android)",
            outboundUserAgent("codex_cli_rs/0.162.1 (Oriveo Android)"),
        )
    }

    @Test
    fun `missing or ktor default user agent becomes NativeUserAgent`() {
        assertEquals(native, outboundUserAgent(null))
        assertEquals(native, outboundUserAgent(KTOR_DEFAULT_USER_AGENT))
    }
}
