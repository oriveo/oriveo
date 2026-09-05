package ai.oriveo.community.core.data.repository

import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.RelayAuthMode
import ai.oriveo.community.core.model.RelayConnectionSecurityMode
import ai.oriveo.community.core.model.RelayRequestedConfig
import ai.oriveo.community.core.model.RelayTransport
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class RelayCapabilityGenerationPolicyTest {
    private val relay = Provider(
        id = "relay-1",
        kind = ProviderKind.Relay,
        baseUrlText = "https://relay.example/v1",
        relayRequested = RelayRequestedConfig(
            transport = RelayTransport.OpenAIChatCompletions,
            authMode = RelayAuthMode.Bearer,
            securityMode = RelayConnectionSecurityMode.RemoteHttps,
            resolvedAPIBaseURL = "https://relay.example/v1",
        ),
    )

    @Test
    fun `endpoint auth security and transport changes advance connection generation`() {
        assertTrue(relayConnectionSemanticsChanged(relay, relay.copy(baseUrlText = "https://new.example/v1")))
        assertTrue(relayConnectionSemanticsChanged(relay, relay.copy(
            relayRequested = relay.relayRequested!!.copy(authMode = RelayAuthMode.None),
        )))
        assertTrue(relayConnectionSemanticsChanged(relay, relay.copy(
            relayRequested = relay.relayRequested!!.copy(securityMode = RelayConnectionSecurityMode.PrivateVpn),
        )))
        assertTrue(relayConnectionSemanticsChanged(relay, relay.copy(
            relayRequested = relay.relayRequested!!.copy(transport = RelayTransport.OpenAIResponses),
        )))
    }

    @Test
    fun `name and enabled model edits do not advance connection generation`() {
        assertFalse(relayConnectionSemanticsChanged(relay, relay.copy(customName = "Renamed")))
        assertFalse(relayConnectionSemanticsChanged(relay, relay.copy(
            models = listOf(AIModel(id = "another", name = "another")),
        )))
    }

}
