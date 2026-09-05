package ai.oriveo.community.core.provider

import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.http.HttpStatusCode
import io.ktor.http.headersOf
import kotlinx.coroutines.test.runTest
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * Unit tests for the BYOK key validation verdict. Pins the three branches plus the decisive
 * bad-key signal for each provider. The verdict looks only at the HTTP status code and the
 * body text; nothing else is parsed.
 */
class ProviderKeyValidatorTest {

    // The validate() integration tests rely on 'metadata empty means fall back to the default
    // contract (list_models + bearer + 401)', so the shared table is cleared before and after
    // to keep provider validation left over from other tests from leaking in.
    @Before
    fun setUp() = MetadataTestFixtures.clear()

    @After
    fun tearDown() = MetadataTestFixtures.clear()

    private fun signal(status: Int, bodyIncludes: List<String> = emptyList()) =
        MetadataClient.InvalidKeySignal(status = status, bodyIncludes = bodyIncludes)

    private fun judge(status: Int, body: String, signals: List<MetadataClient.InvalidKeySignal>) =
        ProviderKeyValidator.judge(statusCode = status, body = body, signals = signals)

    // Basics of the three branches.

    @Test
    fun `2xx is VALID regardless of body or signals`() {
        assertTrue(judge(200, """{"data":[]}""", listOf(signal(401))).isValid)
        // A signal that matches on status must still not misjudge a 2xx; 2xx always wins.
        assertTrue(judge(204, "", listOf(signal(204))).isValid)
    }

    @Test
    fun `status-only signal matches INVALID`() {
        val result = judge(401, """{"error":"unauthorized"}""", listOf(signal(401)))
        assertEquals(ProviderKeyValidator.Result.Invalid(401), result)
    }

    @Test
    fun `unmatched status (404 429 5xx 403) is UNVERIFIED`() {
        val signals = listOf(signal(401))
        assertTrue(judge(404, "not found", signals).isUnverified)
        assertTrue(judge(429, "rate limited", signals).isUnverified)
        assertTrue(judge(500, "boom", signals).isUnverified)
        // Status matches but is not in the signal list (403 is undeclared, say) -> UNVERIFIED.
        // An unknown status is never reported as invalid.
        assertTrue(judge(403, "forbidden", signals).isUnverified)
    }

    // bodyIncludes has AND semantics.

    @Test
    fun `bodyIncludes is AND - all must match for INVALID`() {
        val signals = listOf(signal(400, listOf("API key not valid", "INVALID_ARGUMENT")))
        // Both needles present -> INVALID.
        assertEquals(
            ProviderKeyValidator.Result.Invalid(400),
            judge(400, """{"error":{"message":"API key not valid","status":"INVALID_ARGUMENT"}}""", signals),
        )
        // Only one needle present -> UNVERIFIED, because the AND is not satisfied.
        assertTrue(judge(400, """{"error":{"message":"API key not valid"}}""", signals).isUnverified)
        // Neither needle present -> UNVERIFIED.
        assertTrue(judge(400, "bad request", signals).isUnverified)
    }

    @Test
    fun `bodyIncludes is case sensitive substring match`() {
        val signals = listOf(signal(400, listOf("Incorrect API key")))
        assertEquals(
            ProviderKeyValidator.Result.Invalid(400),
            judge(400, "Incorrect API key provided", signals),
        )
        // Different case -> no match -> UNVERIFIED.
        assertTrue(judge(400, "incorrect api key provided", signals).isUnverified)
    }

    @Test
    fun `empty bodyIncludes equals status-only`() {
        val signals = listOf(signal(401, emptyList()))
        assertEquals(ProviderKeyValidator.Result.Invalid(401), judge(401, "anything", signals))
    }

    // The bad-key case that matters for each provider.

    @Test
    fun `OpenAI DeepSeek Groq 401 is INVALID`() {
        val signals = listOf(signal(401))
        assertEquals(
            ProviderKeyValidator.Result.Invalid(401),
            judge(401, """{"error":{"code":"invalid_api_key"}}""", signals),
        )
    }

    @Test
    fun `Grok 400 Incorrect API key is INVALID and 401 is INVALID`() {
        // Grok answers a bad key with 400 and "Incorrect API key provided".
        val signals = listOf(
            signal(400, listOf("Incorrect API key", "invalid argument")),
            signal(401),
        )
        assertEquals(
            ProviderKeyValidator.Result.Invalid(400),
            judge(400, "Incorrect API key provided as invalid argument", signals),
        )
        assertEquals(ProviderKeyValidator.Result.Invalid(401), judge(401, "unauthorized", signals))
        // 400 but the body has only one needle -> the AND fails -> UNVERIFIED, so a working key
        // is never killed off.
        assertTrue(judge(400, "Incorrect API key provided", signals).isUnverified)
    }

    @Test
    fun `Gemini 400 API key not valid is INVALID and 403 is INVALID`() {
        // Gemini answers a bad key with 400 plus "API key not valid" / "INVALID_ARGUMENT", and
        // additionally signals 403.
        val signals = listOf(
            signal(400, listOf("API key not valid", "INVALID_ARGUMENT")),
            signal(403),
        )
        assertEquals(
            ProviderKeyValidator.Result.Invalid(400),
            judge(400, """{"error":{"message":"API key not valid. INVALID_ARGUMENT"}}""", signals),
        )
        assertEquals(ProviderKeyValidator.Result.Invalid(403), judge(403, "PERMISSION_DENIED", signals))
        // A good key gets a 200 -> VALID.
        assertTrue(judge(200, """{"models":[]}""", signals).isValid)
    }

    @Test
    fun `OpenRouter key probe 401 is INVALID`() {
        // OpenRouter's /models is public and returns 200, so probePath is /key instead; a bad key
        // gets a 401 there.
        val signals = listOf(signal(401))
        assertEquals(
            ProviderKeyValidator.Result.Invalid(401),
            judge(401, """{"error":{"message":"No auth credentials found"}}""", signals),
        )
        // A good key gets a 200 from /key -> VALID.
        assertTrue(judge(200, """{"data":{"limit":null,"usage":0}}""", signals).isValid)
    }

    @Test
    fun `MiniMax only looks at HTTP status not provider internal code`() {
        val signals = listOf(signal(401))
        // MiniMax reliably answers a bad key with HTTP 401; the base_resp.status_code in the body
        // (1004, 2049) is deliberately ignored.
        val body = """{"base_resp":{"status_code":2049,"status_msg":"invalid api key"}}"""
        assertEquals(ProviderKeyValidator.Result.Invalid(401), judge(401, body, signals))
        // Even when the body carries an internal error code, an HTTP 200 still means VALID; the
        // internal code is not parsed.
        assertTrue(judge(200, """{"base_resp":{"status_code":1004}}""", signals).isValid)
    }

    // URL construction.

    @Test
    fun `query_key appends key to query (Gemini)`() {
        val url = ProviderKeyValidator.buildProbeUrl(
            baseUrl = "https://generativelanguage.googleapis.com/v1beta",
            probePath = "/models",
            authMode = ProviderKeyValidator.AuthMode.QueryKey,
            apiKey = "AIza-secret",
        )
        assertEquals(
            "https://generativelanguage.googleapis.com/v1beta/models?key=AIza-secret",
            url,
        )
    }

    @Test
    fun `bearer and x_api_key leave query alone, openrouter key path joins`() {
        val bearer = ProviderKeyValidator.buildProbeUrl(
            baseUrl = "https://openrouter.ai/api/v1",
            probePath = "/key",
            authMode = ProviderKeyValidator.AuthMode.Bearer,
            apiKey = "sk-or-xxx",
        )
        assertEquals("https://openrouter.ai/api/v1/key", bearer)

        val anthropic = ProviderKeyValidator.buildProbeUrl(
            baseUrl = "https://api.anthropic.com/v1",
            probePath = "/models",
            authMode = ProviderKeyValidator.AuthMode.XApiKey,
            apiKey = "sk-ant-xxx",
        )
        assertEquals("https://api.anthropic.com/v1/models", anthropic)
    }

    @Test
    fun `slash normalization collapses trailing and leading slash`() {
        val url = ProviderKeyValidator.buildProbeUrl(
            baseUrl = "https://api.openai.com/v1/",
            probePath = "/models",
            authMode = ProviderKeyValidator.AuthMode.Bearer,
            apiKey = "sk-xxx",
        )
        assertEquals("https://api.openai.com/v1/models", url)
    }

    @Test
    fun `scheme-less base url gets https prefix`() {
        val url = ProviderKeyValidator.buildProbeUrl(
            baseUrl = "api.openai.com/v1",
            probePath = "/models",
            authMode = ProviderKeyValidator.AuthMode.Bearer,
            apiKey = "sk-xxx",
        )
        assertEquals("https://api.openai.com/v1/models", url)
    }

    // Version de-duplication against the real contract probePath.
    // The contract sets probePath=`/v1/models` for Anthropic and `/v1beta/models` for Gemini.
    // The baseUrlText for those two official providers is currently a bare host with no
    // version segment, so the version is de-duplicated before joining. That keeps the result
    // correct whether or not the base carries a version, which also covers a user-supplied
    // base that already has one.

    @Test
    fun `Anthropic bare host base plus versioned probePath joins once`() {
        // Bare host plus a versioned probePath -> nothing to de-duplicate, join directly -> /v1/models.
        val url = ProviderKeyValidator.buildProbeUrl(
            baseUrl = "https://api.anthropic.com",
            probePath = "/v1/models",
            authMode = ProviderKeyValidator.AuthMode.XApiKey,
            apiKey = "sk-ant-xxx",
        )
        assertEquals("https://api.anthropic.com/v1/models", url)
    }

    @Test
    fun `Anthropic versioned base plus versioned probePath does not double-write`() {
        // A versioned base plus a versioned probePath -> de-duplicated, so /v1 is written once.
        val url = ProviderKeyValidator.buildProbeUrl(
            baseUrl = "https://api.anthropic.com/v1",
            probePath = "/v1/models",
            authMode = ProviderKeyValidator.AuthMode.XApiKey,
            apiKey = "sk-ant-xxx",
        )
        assertEquals("https://api.anthropic.com/v1/models", url)
    }

    @Test
    fun `OpenAI versioned base plus bare models probePath does not dedup`() {
        // probePath does not start with basePath (/models vs /v1) -> nothing is trimmed, plain join.
        val url = ProviderKeyValidator.buildProbeUrl(
            baseUrl = "https://api.openai.com/v1",
            probePath = "/models",
            authMode = ProviderKeyValidator.AuthMode.Bearer,
            apiKey = "sk-xxx",
        )
        assertEquals("https://api.openai.com/v1/models", url)
    }

    @Test
    fun `Gemini bare host plus versioned probePath joins once with key query`() {
        // Gemini bare host plus a versioned probePath -> /v1beta/models, with ?key= appended.
        val url = ProviderKeyValidator.buildProbeUrl(
            baseUrl = "https://generativelanguage.googleapis.com",
            probePath = "/v1beta/models",
            authMode = ProviderKeyValidator.AuthMode.QueryKey,
            apiKey = "AIza-secret",
        )
        assertEquals(
            "https://generativelanguage.googleapis.com/v1beta/models?key=AIza-secret",
            url,
        )
    }

    @Test
    fun `Gemini versioned base plus versioned probePath dedup keeps key query`() {
        // A base carrying /v1beta plus a versioned probePath -> de-duplicated, and query_key is
        // still appended.
        val url = ProviderKeyValidator.buildProbeUrl(
            baseUrl = "https://generativelanguage.googleapis.com/v1beta",
            probePath = "/v1beta/models",
            authMode = ProviderKeyValidator.AuthMode.QueryKey,
            apiKey = "AIza-secret",
        )
        assertEquals(
            "https://generativelanguage.googleapis.com/v1beta/models?key=AIza-secret",
            url,
        )
    }

    @Test
    fun `OpenRouter api v1 base plus key probePath does not dedup`() {
        // basePath=/api/v1 and probePath=/key does not start with /api/v1 -> nothing is trimmed.
        val url = ProviderKeyValidator.buildProbeUrl(
            baseUrl = "https://openrouter.ai/api/v1",
            probePath = "/key",
            authMode = ProviderKeyValidator.AuthMode.Bearer,
            apiKey = "sk-or-xxx",
        )
        assertEquals("https://openrouter.ai/api/v1/key", url)
    }

    @Test
    fun `Qwen compatible-mode base plus models probePath does not dedup`() {
        // basePath=/compatible-mode/v1 and probePath=/models does not start with it -> nothing
        // is trimmed.
        val url = ProviderKeyValidator.buildProbeUrl(
            baseUrl = "https://dashscope.aliyuncs.com/compatible-mode/v1",
            probePath = "/models",
            authMode = ProviderKeyValidator.AuthMode.Bearer,
            apiKey = "sk-qwen-xxx",
        )
        assertEquals("https://dashscope.aliyuncs.com/compatible-mode/v1/models", url)
    }

    // Assembling the auth headers.

    @Test
    fun `authMode bearer yields Authorization Bearer`() {
        val headers = ProviderKeyValidator.authHeaders(
            ProviderKeyValidator.AuthMode.Bearer,
            ProviderKeyValidator.HeaderProfile.None,
            "k1",
        ).toMap()
        assertEquals("Bearer k1", headers["Authorization"])
        assertNull(headers["x-api-key"])
    }

    @Test
    fun `authMode x_api_key with anthropic profile yields x-api-key plus version`() {
        val headers = ProviderKeyValidator.authHeaders(
            ProviderKeyValidator.AuthMode.XApiKey,
            ProviderKeyValidator.HeaderProfile.AnthropicV2023,
            "k2",
        ).toMap()
        assertEquals("k2", headers["x-api-key"])
        assertEquals("2023-06-01", headers["anthropic-version"])
        assertNull(headers["Authorization"])
    }

    @Test
    fun `headerProfile openrouter adds HTTP-Referer and X-Title with bearer`() {
        val headers = ProviderKeyValidator.authHeaders(
            ProviderKeyValidator.AuthMode.Bearer,
            ProviderKeyValidator.HeaderProfile.OpenRouter,
            "k3",
        ).toMap()
        assertEquals("Bearer k3", headers["Authorization"])
        assertEquals("https://github.com/oriveo/oriveo", headers["HTTP-Referer"])
        assertEquals("Oriveo", headers["X-Title"])
    }

    @Test
    fun `authMode query_key adds no auth header`() {
        val headers = ProviderKeyValidator.authHeaders(
            ProviderKeyValidator.AuthMode.QueryKey,
            ProviderKeyValidator.HeaderProfile.None,
            "k4",
        ).toMap()
        assertNull(headers["Authorization"])
        assertNull(headers["x-api-key"])
    }

    // Tolerance when parsing the contract enums.

    @Test
    fun `unknown enum raw values resolve to null and known ones map`() {
        assertNull(ProviderKeyValidator.AuthMode.fromRaw("magic"))
        assertNull(ProviderKeyValidator.AuthMode.fromRaw(null))
        assertNull(ProviderKeyValidator.AuthMode.fromRaw("  "))
        assertNull(ProviderKeyValidator.HeaderProfile.fromRaw("magic"))
        assertEquals(ProviderKeyValidator.AuthMode.Bearer, ProviderKeyValidator.AuthMode.fromRaw("bearer"))
        assertEquals(ProviderKeyValidator.AuthMode.XApiKey, ProviderKeyValidator.AuthMode.fromRaw("x_api_key"))
        assertEquals(ProviderKeyValidator.AuthMode.QueryKey, ProviderKeyValidator.AuthMode.fromRaw("query_key"))
        assertEquals(
            ProviderKeyValidator.HeaderProfile.AnthropicV2023,
            ProviderKeyValidator.HeaderProfile.fromRaw("anthropic_v2023_06_01"),
        )
        assertEquals(
            ProviderKeyValidator.HeaderProfile.OpenRouter,
            ProviderKeyValidator.HeaderProfile.fromRaw("openrouter"),
        )
    }

    // validate() integration over MockEngine: default contract, end-to-end verdict, header
    // injection.

    private fun officialProvider(kind: ProviderKind) = Provider(
        id = "11111111-1111-1111-1111-111111111111",
        kind = kind,
        apiKey = "sk-test",
        baseUrlText = kind.defaultBaseUrl,
    )

    @Test
    fun `validate maps 200 to VALID and sends bearer header to models endpoint`() = runTest {
        var capturedUrl = ""
        var capturedAuth: String? = null
        val client = HttpClient(
            MockEngine { request ->
                capturedUrl = request.url.toString()
                capturedAuth = request.headers["Authorization"]
                respond("""{"data":[]}""", HttpStatusCode.OK, headersOf("Content-Type", "application/json"))
            }
        )

        val result = ProviderKeyValidator.validate(officialProvider(ProviderKind.OpenAI), "sk-test", client)

        assertTrue(result.isValid)
        // Default contract when metadata is empty: probePath=/models and baseUrl comes from the
        // user's baseUrlText, api.openai.com/v1.
        assertTrue("probe URL was $capturedUrl", capturedUrl.endsWith("/v1/models"))
        assertEquals("Bearer sk-test", capturedAuth)
    }

    @Test
    fun `validate maps 401 to INVALID via default contract`() = runTest {
        val client = HttpClient(
            MockEngine {
                respond("""{"error":"unauthorized"}""", HttpStatusCode.Unauthorized)
            }
        )
        val result = ProviderKeyValidator.validate(officialProvider(ProviderKind.OpenAI), "bad", client)
        assertEquals(ProviderKeyValidator.Result.Invalid(401), result)
    }

    @Test
    fun `validate maps unmatched 500 to UNVERIFIED (innocent until proven)`() = runTest {
        val client = HttpClient(
            MockEngine {
                respond("server error", HttpStatusCode.InternalServerError)
            }
        )
        val result = ProviderKeyValidator.validate(officialProvider(ProviderKind.OpenAI), "sk-test", client)
        assertTrue(result.isUnverified)
        assertFalse(result.isInvalid)
    }
}
