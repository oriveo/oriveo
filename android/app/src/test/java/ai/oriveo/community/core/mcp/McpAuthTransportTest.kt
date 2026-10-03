package ai.oriveo.community.core.mcp

import ai.oriveo.community.core.mcp.McpScriptedTransport.Companion.redirect
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.JsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/**
 * The production OAuth transport [McpHttpAuthTransport].
 *
 * These tests exercise the transport itself: it sends the requests, and the assertions look at what the
 * replay layer actually received. The authorizer's logic tests (`McpAuthorizerTest`) use a fake transport,
 * which cannot prove anything about the redirect and https constraints.
 */
class McpAuthTransportTest {

    private val scripted = McpScriptedTransport()

    private fun transport(timeoutMillis: Long = 10_000) = McpHttpAuthTransport(scripted, timeoutMillis)

    private val secretForm = listOf(
        McpFormField("grant_type", "authorization_code"),
        McpFormField("code", "ac_secret_code"),
        McpFormField("code_verifier", "verifier_secret"),
    )

    private fun okJson(text: String = """{"ok":true}""") = McpScriptedTransport.json(text, rewriteId = false)

    private suspend inline fun <reified T : Throwable> expectThrows(crossinline block: suspend () -> Unit) {
        try {
            block()
            fail("expected ${T::class.simpleName}")
        } catch (error: Throwable) {
            assertTrue("actual $error", error is T)
        }
    }

    @Test
    fun `token endpoint never follows redirects even same-origin`() = runBlocking {
        for (target in listOf("https://auth.example.com/token2", "https://evil.example/token")) {
            scripted.reset()
            scripted.enqueue(redirect(target), okJson())
            expectThrows<McpHttpException.RedirectRejected> { transport().postForm(TOKEN, secretForm) }
            val requests = scripted.requests()
            assertEquals(target, 1, requests.size)
            assertEquals(TOKEN, requests.single().url)
            assertTrue(requests.single().bodyText!!.contains("ac_secret_code"))
        }
    }

    @Test
    fun `registration endpoint never follows redirects`() = runBlocking {
        for (target in listOf("https://auth.example.com/register2", "https://evil.example/register")) {
            scripted.reset()
            scripted.enqueue(redirect(target), okJson())
            expectThrows<McpHttpException.RedirectRejected> { transport().postJson(REGISTRATION, McpClientMetadata.registrationBody(null)) }
            assertEquals(1, scripted.requests().size)
        }
    }

    @Test
    fun `metadata GET follows a same-origin https redirect`() = runBlocking {
        scripted.enqueue(redirect("https://auth.example.com/metadata.json"), okJson("""{"issuer":"https://auth.example.com"}"""))
        val response = transport().get(METADATA)
        assertEquals(200, response.status)
        assertTrue(String(response.body).contains("https://auth.example.com"))
        assertEquals(listOf("/.well-known/oauth-authorization-server", "/metadata.json"), scripted.requests().map { it.path })
        assertTrue(scripted.requests().all { it.method == "GET" })
    }

    @Test
    fun `metadata GET rejects cross-origin and downgrade redirects`() = runBlocking {
        for (target in listOf("https://evil.example/metadata.json", "http://auth.example.com/metadata.json")) {
            scripted.reset()
            scripted.enqueue(redirect(target), okJson("""{"issuer":"https://evil.example"}"""))
            expectThrows<McpHttpException.RedirectRejected> { transport().get(METADATA) }
            assertEquals(target, 1, scripted.requests().size)
        }
    }

    @Test
    fun `non-https oauth endpoints send nothing`() = runBlocking {
        scripted.setFallback(okJson())
        val insecure = "http://auth.example.com/token"
        expectThrows<McpHttpException.InsecureUrl> { transport().get(insecure) }
        expectThrows<McpHttpException.InsecureUrl> { transport().postForm(insecure, secretForm) }
        expectThrows<McpHttpException.InsecureUrl> { transport().postJson(insecure, JsonObject(emptyMap())) }
        assertTrue(scripted.requests().isEmpty())
    }

    @Test
    fun `response over 1 MB is aborted`() = runBlocking {
        scripted.enqueue(McpScriptedTransport.Stub(status = 200, body = ByteArray(McpHttpLimits.MAX_AUTH_RESPONSE_BYTES + 1) { 0x20 }, rewriteId = false))
        expectThrows<McpHttpException.BodyTooLarge> { transport().get(METADATA) }
    }

    @Test
    fun `deadline applies and closes the connection`() = runBlocking {
        scripted.enqueue(okJson().copy(delayMillis = 5_000))
        expectThrows<McpAuthTimeoutException> { transport(timeoutMillis = 300).get(METADATA) }
        assertTrue(McpClientHarness.eventually { scripted.abortedRequests().isNotEmpty() })
    }

    @Test
    fun `form encoding percent-encodes everything outside unreserved and response headers are lowercased`() = runBlocking {
        scripted.enqueue(
            McpScriptedTransport.Stub(
                status = 200,
                headers = mapOf("Content-Type" to "application/json", "WWW-Authenticate" to "Bearer"),
                body = "{}".toByteArray(),
                rewriteId = false,
            ),
        )
        val form = listOf(McpFormField("resource", "https://mcp.example.com/mcp?a=b&c"), McpFormField("scope", "files:read files:write"))
        val response = transport().postForm(TOKEN, form)
        assertEquals("Bearer", response.headers["www-authenticate"])
        assertEquals("application/json", response.contentType)
        val sent = scripted.requests().single()
        assertEquals("resource=https%3A%2F%2Fmcp.example.com%2Fmcp%3Fa%3Db%26c&scope=files%3Aread%20files%3Awrite", sent.bodyText)
        assertEquals("application/x-www-form-urlencoded", sent.header("Content-Type"))
    }

    companion object {
        const val TOKEN = "https://auth.example.com/token"
        const val REGISTRATION = "https://auth.example.com/register"
        const val METADATA = "https://auth.example.com/.well-known/oauth-authorization-server"
    }
}
