package ai.oriveo.community.feature.providers.relay

import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.ProviderServiceError
import ai.oriveo.community.core.model.RelayAuthMode
import ai.oriveo.community.core.model.RelayKeyValue
import ai.oriveo.community.core.model.RelayKind
import ai.oriveo.community.core.model.RelayRequestedConfig
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class RelayEditFailurePresenterTest {
    @Test
    fun `presentation preserves endpoint and status while redacting key header and query secrets`() {
        
        val apiKey = "k1"
        val headerSecret = "h1"
        val querySecret = "q1"
        val endpointSecret = "e1"
        val candidate = Provider(
            id = "relay-1",
            kind = ProviderKind.Relay,
            apiKey = apiKey,
            baseUrlText = "https://relay.example/v1?api_key=$endpointSecret",
            relayKind = RelayKind.Custom,
            models = listOf(AIModel(id = "model-1", name = "model-1", isDefault = true)),
            relayRequested = RelayRequestedConfig(
                authMode = RelayAuthMode.Bearer,
                modelID = "model-1",
                headers = listOf(RelayKeyValue("Authorization", "Bearer $headerSecret")),
                queryParams = listOf(RelayKeyValue("api_key", querySecret)),
            ),
        )
        val error = ProviderServiceError.RelayUpstream(
            statusCode = 401,
            guidance = "unauthorized",
            detail = """{"key":"$apiKey","header":"$headerSecret","query":"$querySecret"}""",
        )

        
        val presentation = RelayEditFailurePresenter.present(candidate, error)

        assertEquals(401, presentation.statusCode)
        assertEquals(0, presentation.automaticRetryCount)
        assertTrue(presentation.endpoint.startsWith("https://relay.example/v1"))
        val rendered = listOf(presentation.endpoint, presentation.upstreamJson.orEmpty()).joinToString("\n")
        listOf(apiKey, headerSecret, querySecret, endpointSecret).forEach { secret ->
            assertFalse(rendered.contains(secret))
        }
        assertTrue(
            presentation.upstreamJson.orEmpty().contains(
                ai.oriveo.community.core.provider.RelayEndpointPolicy.REDACTED_PLACEHOLDER,
            ),
        )
    }

    @Test
    fun `uncontrolled non json upstream body is omitted`() {
        val candidate = Provider(id = "relay-1", kind = ProviderKind.Relay)
        val presentation = RelayEditFailurePresenter.present(
            candidate,
            ProviderServiceError.Upstream(502, "plain-text upstream body"),
        )

        assertEquals(502, presentation.statusCode)
        assertNull(presentation.upstreamJson)
    }
}
