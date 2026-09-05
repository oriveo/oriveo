package ai.oriveo.community.core.provider.relay

import ai.oriveo.community.core.model.RelayAuthMode
import ai.oriveo.community.core.model.RelayKeyValue
import ai.oriveo.community.core.model.RelayRequestedConfig
import org.junit.Assert.assertEquals
import org.junit.Test

class RelayQueryPolicyTest {
    @Test fun `auth none keeps protocol query but injects no key or custom query`() {
        val requested = RelayRequestedConfig(
            authMode = RelayAuthMode.None,
            queryParams = listOf(RelayKeyValue("api_key", "secret"), RelayKeyValue("custom", "value")),
        )
        assertEquals(
            listOf("alt" to "sse"),
            buildRelayQueryPairs(
                protocolQuery = listOf("alt" to "sse"),
                requested = requested,
                authMode = RelayAuthMode.None,
                apiKey = "must-not-appear",
                includeCustomQuery = true,
            ),
        )
    }
}
