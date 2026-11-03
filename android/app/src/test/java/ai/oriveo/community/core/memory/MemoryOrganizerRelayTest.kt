package ai.oriveo.community.core.memory

import ai.oriveo.community.core.data.repository.ProviderRepository
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.ChatRequestOptions
import ai.oriveo.community.core.model.ModelCapability
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderChatResult
import ai.oriveo.community.core.model.ProviderConnectionState
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.RelayConnectionSecurityMode
import ai.oriveo.community.core.model.RelayRequestedConfig
import ai.oriveo.community.core.model.RelayTransport
import ai.oriveo.community.core.model.StreamEvent
import ai.oriveo.community.core.provider.ProviderService
import io.mockk.coEvery
import io.mockk.every
import io.mockk.mockk
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Test

class MemoryOrganizerRelayTest {

    @Test
    fun relay_local_http_options() = runBlocking {
        val model = AIModel(id = "m-1", name = "Model", isDefault = true, capabilities = listOf(ModelCapability.Text))
        val provider = Provider(
            id = "relay-local",
            kind = ProviderKind.Relay,
            status = ProviderConnectionState.Connected,
            apiKey = "local-key",
            baseUrlText = "http://127.0.0.1:8080",
            models = listOf(model),
            catalogModels = listOf(model),
            relayRequested = RelayRequestedConfig(
                transport = RelayTransport.OpenAIChatCompletions,
                securityMode = RelayConnectionSecurityMode.LocalHttp,
            ),
        )
        val sent = mutableListOf<ChatRequestOptions>()
        val providerService = mockk<ProviderService>()
        coEvery { providerService.sendMessage(any(), any(), any(), any(), any(), any(), any(), any()) } answers {
            sent += arg<ChatRequestOptions>(7)
            StreamEvent.Done(ProviderChatResult(text = "[]"))
        }
        val providerRepository = mockk<ProviderRepository>()
        every { providerRepository.serviceFor(any<Provider>(), any()) } returns providerService

        MemoryOrganizer.forModel(providerRepository, provider, model).reply("Likes hiking on weekends")

        assertEquals("organize sends exactly once", 1, sent.size)
        val options = sent.single()
        assertEquals(provider.relayRequested, options.relayRequested)
        assertEquals(RelayTransport.OpenAIChatCompletions, options.relayRouteTransport)
        assertEquals("http://127.0.0.1:8080/v1", options.relayRouteAPIRoot)
    }
}
