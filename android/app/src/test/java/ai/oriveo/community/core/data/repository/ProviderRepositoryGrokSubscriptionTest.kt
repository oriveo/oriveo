package ai.oriveo.community.core.data.repository

import ai.oriveo.community.core.data.dao.ProviderDao
import ai.oriveo.community.core.data.entity.ProviderEntity
import ai.oriveo.community.core.data.remote.MetadataRefreshEventBus
import ai.oriveo.community.core.model.ProviderAuthMode
import ai.oriveo.community.core.model.ProviderConnectionState
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.provider.AnthropicService
import ai.oriveo.community.core.provider.DeepSeekService
import ai.oriveo.community.core.provider.FireworksService
import ai.oriveo.community.core.provider.GeminiService
import ai.oriveo.community.core.provider.GrokService
import ai.oriveo.community.core.provider.GroqService
import ai.oriveo.community.core.provider.MetadataTestFixtures
import ai.oriveo.community.core.provider.MiniMaxService
import ai.oriveo.community.core.provider.MistralService
import ai.oriveo.community.core.provider.MoonshotService
import ai.oriveo.community.core.provider.OpenAIService
import ai.oriveo.community.core.provider.OpenRouterService
import ai.oriveo.community.core.provider.QwenService
import ai.oriveo.community.core.provider.RelayService
import ai.oriveo.community.core.provider.SiliconFlowService
import ai.oriveo.community.core.provider.TogetherService
import ai.oriveo.community.core.provider.ZhipuService
import ai.oriveo.community.core.provider.grok.GrokSubscriptionTokens
import ai.oriveo.community.core.security.SecureKeyStore
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpStatusCode
import io.ktor.http.headersOf
import io.mockk.coEvery
import io.mockk.every
import io.mockk.mockk
import io.mockk.slot
import kotlinx.coroutines.test.runTest
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * The three lifecycle paths of a subscription instance: register, re-fetch and delete.
 *
 * The key assertions all land on objects the production path actually produces: the catalog URL comes from the request the repository
 * really sent, the provider from the return value of `registerProvider`, and the credential from the payload written into the KeyStore.
 */
class ProviderRepositoryGrokSubscriptionTest {

    private val dao = mockk<ProviderDao>()
    private val secureKeyStore = mockk<SecureKeyStore>()

    private val requestedUrls = mutableListOf<String>()
    private val requestedAuthHeaders = mutableListOf<String?>()
    private val requestedClientVersions = mutableListOf<String?>()
    private val subscriptionStore = mutableMapOf<String, String>()
    private val writes = mutableListOf<ProviderEntity>()

    private lateinit var repository: ProviderRepository

    @Before
    fun setUp() {
        MetadataTestFixtures.applyRaw(METADATA_WITH_SUBSCRIPTION_AUTH)

        coEvery { dao.getAll(any()) } returns emptyList()
        coEvery { secureKeyStore.getApiKey(any(), any()) } returns ""
        every { secureKeyStore.saveApiKey(any(), any(), any()) } returns Unit
        every { secureKeyStore.deleteApiKey(any(), any()) } returns Unit
        every { secureKeyStore.beginCapabilityConnection(any(), any()) } returns
            SecureKeyStore.CapabilityEpochs("cg", "ce")
        every { secureKeyStore.advanceCapabilityConnection(any(), any()) } returns
            SecureKeyStore.CapabilityEpochs("cg2", "ce2")
        every { secureKeyStore.advanceCapabilityConnectionGeneration(any(), any()) } returns
            SecureKeyStore.CapabilityEpochs("cg3", "ce")

        val payload = slot<String>()
        val savedProviderId = slot<String>()
        every {
            secureKeyStore.saveSubscriptionCredential(any(), capture(savedProviderId), capture(payload))
        } answers { subscriptionStore[savedProviderId.captured] = payload.captured }
        every { secureKeyStore.loadSubscriptionCredential(any(), any()) } answers {
            subscriptionStore[secondArg()]
        }
        every { secureKeyStore.deleteSubscriptionCredential(any(), any()) } answers {
            subscriptionStore.remove(secondArg<String>())
            Unit
        }

        var persisted: ProviderEntity? = null
        coEvery { dao.getById(any(), any()) } answers {
            persisted?.takeIf { it.accountId == firstArg<String>() && it.id == secondArg<String>() }
        }
        coEvery { dao.upsert(any()) } answers {
            persisted = firstArg()
            writes += firstArg<ProviderEntity>()
        }
        coEvery { dao.deleteById(any(), any()) } answers { persisted = null; Unit }

        repository = ProviderRepository(
            dao = dao,
            secureKeyStore = secureKeyStore,
            openRouterService = mockk<OpenRouterService>(),
            openAIService = mockk<OpenAIService>(),
            deepSeekService = mockk<DeepSeekService>(),
            grokService = mockk<GrokService>(),
            anthropicService = mockk<AnthropicService>(),
            geminiService = mockk<GeminiService>(),
            groqService = mockk<GroqService>(),
            togetherService = mockk<TogetherService>(),
            fireworksService = mockk<FireworksService>(),
            miniMaxService = mockk<MiniMaxService>(),
            zhipuService = mockk<ZhipuService>(),
            qwenService = mockk<QwenService>(),
            moonshotService = mockk<MoonshotService>(),
            mistralService = mockk<MistralService>(),
            siliconFlowService = mockk<SiliconFlowService>(),
            relayService = mockk<RelayService>(),
            metadataRefreshEventBus = MetadataRefreshEventBus(debounceMillis = 0),
            httpClient = HttpClient(
                MockEngine { request ->
                    requestedUrls += request.url.toString()
                    requestedAuthHeaders += request.headers[HttpHeaders.Authorization]
                    requestedClientVersions += request.headers["x-grok-client-version"]
                    respond(
                        """{"data":[{"id":"grok-4.6"},{"id":"grok-4.5"}]}""",
                        HttpStatusCode.OK,
                        headersOf(HttpHeaders.ContentType, "application/json"),
                    )
                }
            ),
        )
    }

    @After
    fun tearDown() {
        MetadataTestFixtures.clear()
    }

    /**
     * When a subscription instance is registered, the catalog must be fetched live over the subscription channel.
     *
     * The official metadata-only path would fill in the `api.x.ai` catalog, which was measured on 2026-08-19 to have zero overlap with
     * the subscription one: every model the user picks from that list would not exist on this channel, so the first message fails.
     */
    @Test
    fun `registering a subscription instance fetches the catalog from the subscription modelsUrl and stores credentials in a separate namespace`() = runTest {
        val tokens = GrokSubscriptionTokens(
            accessToken = "access-token",
            refreshToken = "refresh-token",
            expiresAt = System.currentTimeMillis() + 6 * 3600 * 1000L,
        )

        val provider = repository.registerProvider(
            kind = ProviderKind.Grok,
            apiKey = tokens.accessToken,
            baseUrl = "https://api.x.ai/v1",
            authMode = ProviderAuthMode.Subscription,
            subscriptionTokens = tokens,
        )

        assertEquals(ProviderAuthMode.Subscription, provider.authMode)
        assertEquals(listOf("grok-4.6", "grok-4.5"), provider.catalogModels.map { it.id })
        assertEquals(listOf("grok-4.6", "grok-4.5"), provider.models.map { it.id })
        // A subscription connection has no key to show: a run of mask dots would make the user think a key is still stored.
        assertEquals("", provider.apiKeyPreview)
        assertTrue(provider.status is ProviderConnectionState.Connected)

        // Only the subscription catalog was hit; no key validation probe doomed to fail was made against api.x.ai.
        assertEquals(listOf("https://cli-chat-proxy.grok.com/v1/models"), requestedUrls)
        assertEquals(listOf("Bearer access-token"), requestedAuthHeaders)
        assertEquals(listOf("1.0.4"), requestedClientVersions)

        // The whole credential lands in a separate namespace instead of being stuffed into the apiKey slot.
        val stored = subscriptionStore[provider.id]
        assertNotNull(stored)
        assertTrue(stored!!.contains("refresh-token"))
    }

    /**
     * When the catalog cannot be fetched, clear it and show a clear message instead of keeping the official catalog.
     * Keeping it would hand the user a list of dead entries where every pick fails with an obscure error.
     */
    @Test
    fun `a failed subscription catalog fetch clears the catalog and writes back catalogUnavailable`() = runTest {
        val failing = ProviderRepository(
            dao = dao,
            secureKeyStore = secureKeyStore,
            openRouterService = mockk<OpenRouterService>(),
            openAIService = mockk<OpenAIService>(),
            deepSeekService = mockk<DeepSeekService>(),
            grokService = mockk<GrokService>(),
            anthropicService = mockk<AnthropicService>(),
            geminiService = mockk<GeminiService>(),
            groqService = mockk<GroqService>(),
            togetherService = mockk<TogetherService>(),
            fireworksService = mockk<FireworksService>(),
            miniMaxService = mockk<MiniMaxService>(),
            zhipuService = mockk<ZhipuService>(),
            qwenService = mockk<QwenService>(),
            moonshotService = mockk<MoonshotService>(),
            mistralService = mockk<MistralService>(),
            siliconFlowService = mockk<SiliconFlowService>(),
            relayService = mockk<RelayService>(),
            metadataRefreshEventBus = MetadataRefreshEventBus(debounceMillis = 0),
            httpClient = HttpClient(
                MockEngine { respond("nope", HttpStatusCode.ServiceUnavailable) }
            ),
        )

        val provider = failing.registerProvider(
            kind = ProviderKind.Grok,
            apiKey = "access-token",
            baseUrl = "https://api.x.ai/v1",
            authMode = ProviderAuthMode.Subscription,
            subscriptionTokens = GrokSubscriptionTokens(accessToken = "access-token"),
        )

        assertTrue(provider.catalogModels.isEmpty())
        assertEquals(
            ProviderRepository.SUBSCRIPTION_CATALOG_UNAVAILABLE_MESSAGE,
            provider.lastError,
        )
    }

    /**
     * This is the only provider deletion path; missing it would leave behind an OAuth token that still works.
     */
    @Test
    fun `deleting a subscription instance also clears the subscription credential`() = runTest {
        val provider = repository.registerProvider(
            kind = ProviderKind.Grok,
            apiKey = "access-token",
            baseUrl = "https://api.x.ai/v1",
            authMode = ProviderAuthMode.Subscription,
            subscriptionTokens = GrokSubscriptionTokens(accessToken = "access-token"),
        )
        assertNotNull(subscriptionStore[provider.id])

        repository.deleteProvider(provider.id)

        assertNull("No usable OAuth token may remain after the provider is deleted", subscriptionStore[provider.id])
    }

    /**
     * Fallback after the kill switch is turned off: entering a real key switches back to API Key mode.
     *
     * Switching back must clear the subscription credential and hand the catalog back to the official metadata; keeping them would leave
     * both a token that still works and a dead catalog containing only grok-4.6/4.5.
     */
    @Test
    fun `entering a real key on a subscription instance switches back to API Key and clears the subscription credential`() = runTest {
        val provider = repository.registerProvider(
            kind = ProviderKind.Grok,
            apiKey = "access-token",
            baseUrl = "https://api.x.ai/v1",
            authMode = ProviderAuthMode.Subscription,
            subscriptionTokens = GrokSubscriptionTokens(accessToken = "access-token"),
        )
        assertNotNull(subscriptionStore[provider.id])

        repository.updateApiKey(provider.id, "xai-real-key")

        val persisted = writes.last()
        assertEquals(ProviderAuthMode.ApiKey.rawValue, persisted.authMode)
        assertNull("No usable OAuth token may remain after switching back to API Key", subscriptionStore[provider.id])
    }

    private companion object {
        /** Same shape as what production serves; only the fields this test needs are kept. */
        val METADATA_WITH_SUBSCRIPTION_AUTH = """
        {
          "version": 1,
          "providers": {},
          "providerConfigs": [
            {
              "kind": "grok",
              "displayName": "Grok",
              "defaultBaseURL": "https://api.x.ai/v1",
              "protocolFeatures": {
                "authMethod": "bearer",
                "subscriptionAuth": {
                  "enabled": true,
                  "flow": "oauth_device_code",
                  "clientId": "b1a00492-073a-47ea-816f-4c329264a828",
                  "scopes": "openid profile email offline_access grok-cli:access api:access",
                  "deviceAuthorizationEndpoint": "https://auth.x.ai/oauth2/device/code",
                  "tokenEndpoint": "https://auth.x.ai/oauth2/token",
                  "revocationEndpoint": "https://auth.x.ai/oauth2/revoke",
                  "trustedAuthHosts": ["auth.x.ai"],
                  "trustedVerificationHosts": ["accounts.x.ai", "x.ai"],
                  "resourceBaseURL": "https://cli-chat-proxy.grok.com/v1",
                  "requiredHeaders": {"x-grok-client-version": "1.0.4"},
                  "modelsPath": "/models",
                  "chatPath": "/chat/completions"
                }
              }
            }
          ]
        }
        """.trimIndent()
    }
}
