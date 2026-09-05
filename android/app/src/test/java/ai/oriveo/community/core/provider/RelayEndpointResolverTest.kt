package ai.oriveo.community.core.provider

import ai.oriveo.community.core.model.RelayRequestedConfig
import ai.oriveo.community.core.model.RelayTransport
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class RelayEndpointResolverTest {
    @Test
    fun `full chat path is split into origin prefix version and transport`() {
        val descriptor = RelayEndpointResolver.describe(
            "https://user.example/proxy/v1/chat/completions",
        )

        assertEquals("https://user.example", descriptor.origin)
        assertEquals("/proxy", descriptor.pathPrefix)
        assertEquals("v1", descriptor.explicitVersion)
        assertEquals(RelayTransport.OpenAIChatCompletions, descriptor.explicitTransport)
        assertFalse(descriptor.containsEmbeddedQuery)
    }

    @Test
    fun `candidate order respects explicit version before fallback`() {
        val descriptor = RelayEndpointResolver.describe("relay.example/proxy/v1")
        val candidates = RelayEndpointResolver.candidates(
            descriptor,
            RelayTransport.GeminiGenerateContent,
        )

        assertEquals(
            listOf(
                "https://relay.example/proxy/v1",
                "https://relay.example/proxy/v1beta",
                "https://relay.example/proxy",
            ),
            candidates.map { it.apiBaseUrl },
        )
        assertEquals(RelayEndpointCandidateEvidence.ExplicitVersion, candidates.first().evidence)
    }

    @Test
    fun `models route is stripped without claiming a protocol`() {
        val descriptor = RelayEndpointResolver.describe("https://relay.example/v1/models")
        assertEquals("v1", descriptor.explicitVersion)
        assertNull(descriptor.explicitTransport)
    }

    @Test
    fun `embedded query is reported before discovery sends a request`() {
        val descriptor = RelayEndpointResolver.describe("https://relay.example/v1?key=secret")
        assertTrue(descriptor.containsEmbeddedQuery)
    }

    @Test
    fun `resolved api root wins over legacy version guessing`() {
        val resolved = RelayEndpointResolver.runtimeApiBaseUrl(
            rawBaseUrl = "https://relay.example/proxy",
            relayRequested = RelayRequestedConfig(resolvedAPIBaseURL = "https://relay.example/custom"),
            defaultVersion = "v1",
            acceptedVersions = setOf("v1"),
        )
        assertEquals("https://relay.example/custom", resolved)
    }
}
