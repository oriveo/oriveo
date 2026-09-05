package ai.oriveo.community.core.model

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class RelayConfigTest {

    private val json = Json { ignoreUnknownKeys = true }

    @Test
    fun `credentialFreePortableCopy strips credential carriers and URL metadata`() {
        val portable = RelayRequestedConfig(
            transport = RelayTransport.OpenAIResponses,
            headers = listOf(RelayKeyValue("X-Relay-Key", "secret")),
            queryParams = listOf(RelayKeyValue("api_key", "secret")),
            resolvedAPIBaseURL = "https://relay.example.com/prefix/v1?token=secret#fragment",
        ).credentialFreePortableCopy()

        assertNull(portable.headers)
        assertNull(portable.queryParams)
        assertEquals("https://relay.example.com/prefix/v1", portable.resolvedAPIBaseURL)
        assertEquals(
            "https://relay.example.com/request/v1",
            credentialFreeRelayEndpoint("https://relay.example.com/request/v1?key=secret#fragment"),
        )
    }

    @Test
    fun `unknown transport and auth values degrade without dropping the relay config`() {
        val decoded = json.decodeFromString<RelayRequestedConfig>(
            """{"transport":"future_transport","authMode":"future_auth","modelID":"model-a","transportKind":"future_wire"}""",
        )

        assertEquals(RelayTransport.Auto, decoded.transport)
        assertEquals(RelayAuthMode.Auto, decoded.authMode)
        assertEquals("model-a", decoded.modelID)
        assertEquals("future_wire", decoded.transportKind)
    }

    @Test
    fun `transportKind uses canonical wire name and accepts legacy Android alias`() {
        val legacy = json.decodeFromString<RelayRequestedConfig>(
            """{"transport":"auto","authMode":"auto","transportKindOverride":"openai_chat"}""",
        )
        assertEquals("openai_chat", legacy.transportKind)

        val encoded = json.parseToJsonElement(json.encodeToString(legacy)).jsonObject
        assertEquals("openai_chat", encoded["transportKind"]?.toString()?.trim('"'))
        assertNull(encoded["transportKindOverride"])
    }
}
