package ai.oriveo.community.core.provider

import ai.oriveo.community.core.model.ProviderKind
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.http.HttpStatusCode
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Test

class OpenAICompatibleMetadataServicesTest {

    private val json = Json { ignoreUnknownKeys = true }

    @After
    fun tearDown() {
        MetadataTestFixtures.clear()
    }

    @Test
    fun `groq syncProvider uses normalized custom base url and preferred model`() = runTest {
        verifySyncProviderWithCustomBaseUrl(
            providerKind = ProviderKind.Groq,
            preferredModelId = "llama-3.3-70b-versatile",
            customBaseUrl = "groq.example/openai/v1/",
            serviceFactory = { client -> GroqService(client, json) },
        )
    }

    @Test
    fun `together syncProvider uses normalized custom base url and preferred model`() = runTest {
        verifySyncProviderWithCustomBaseUrl(
            providerKind = ProviderKind.Together,
            preferredModelId = "meta-llama/Llama-3.3-70B-Instruct-Turbo",
            customBaseUrl = "together.example/v1/",
            serviceFactory = { client -> TogetherService(client, json) },
        )
    }

    @Test
    fun `fireworks syncProvider uses normalized custom base url and preferred model`() = runTest {
        verifySyncProviderWithCustomBaseUrl(
            providerKind = ProviderKind.Fireworks,
            preferredModelId = "accounts/fireworks/models/llama4-maverick-instruct-basic",
            customBaseUrl = "fireworks.example/inference/v1/",
            serviceFactory = { client -> FireworksService(client, json) },
        )
    }

    
    

    private suspend fun verifySyncProviderWithCustomBaseUrl(
        providerKind: ProviderKind,
        preferredModelId: String,
        customBaseUrl: String,
        serviceFactory: (HttpClient) -> ProviderService,
    ) {
        MetadataTestFixtures.applyProviders(
            MetadataTestFixtures.ProviderSpec(
                providerKind = providerKind,
                defaultModelId = preferredModelId,
                resolveMap = mapOf(preferredModelId to preferredModelId),
                models = listOf(
                    MetadataTestFixtures.ModelSpec(preferredModelId, displayName = preferredModelId),
                ),
            )
        )

        val requestedUrls = mutableListOf<String>()
        val client = HttpClient(
            MockEngine { request ->
                requestedUrls += request.url.toString()
                respond("{}", HttpStatusCode.OK)
            }
        )
        val service = serviceFactory(client)
        val result = service.syncProvider(
            apiKey = "sk-test",
            preferredModelID = " $preferredModelId ",
            baseUrl = customBaseUrl,
        )

        
        assertEquals(emptyList<String>(), requestedUrls)
        assertEquals(0, result.models.size)
    }

}
