package ai.oriveo.community.core.data.remote

import ai.oriveo.community.core.mcp.McpRuntimeConfig
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The `mcpRuntimeConfig` block of the model catalog becomes the MCP runtime limits. Payloads go through the same
 * decode / publish boundary as a catalog fetched from the network.
 */
class MetadataMcpRuntimeConfigTest {

    private fun client(payload: String?): MetadataClient = MetadataClient().also { client ->
        payload?.let { client.loadNetworkPayloadForTesting(it, "etag-mcp") }
    }

    @Test
    fun `the config in the catalog replaces the built-in fallback`() {
        val config = client(
            """
            {"version":1,"providers":{},"mcpRuntimeConfig":{"version":3,"enabled":true,"maxServers":7,
              "maxToolsPerRequest":12,"maxToolDefinitionBytes":8192,"maxResultChars":5000,
              "callTimeoutSeconds":30,"maxSteps":4}}
            """.trimIndent(),
        ).mcpRuntimeConfig()

        assertEquals(
            McpRuntimeConfig(
                version = 3, enabled = true, maxServers = 7, maxToolsPerRequest = 12, maxToolDefinitionBytes = 8192,
                maxResultChars = 5000, callTimeoutSeconds = 30.0, maxSteps = 4,
            ),
            config,
        )
    }

    @Test
    fun `a catalog carrying the default values decodes to the built-in fallback`() {
        val config = client(
            """
            {"version":1,"providers":{},"mcpRuntimeConfig":{"version":1,"enabled":true,"maxServers":20,
              "maxToolsPerRequest":40,"maxToolDefinitionBytes":16384,"maxResultChars":24000,
              "callTimeoutSeconds":60,"maxSteps":6}}
            """.trimIndent(),
        ).mcpRuntimeConfig()

        assertEquals(McpRuntimeConfig.fallback, config)
    }

    @Test
    fun `enabled false is carried through so the entry can hide`() {
        val config = client("""{"version":1,"providers":{},"mcpRuntimeConfig":{"enabled":false}}""").mcpRuntimeConfig()

        assertFalse(config.enabled)
        assertEquals("fields that were not delivered use the fallback value", McpRuntimeConfig.fallback.maxServers, config.maxServers)
    }

    @Test
    fun `a snapshot without the section or no snapshot at all falls back without disabling the feature`() {
        assertEquals(McpRuntimeConfig.fallback, client("""{"version":1,"providers":{}}""").mcpRuntimeConfig())
        assertEquals(McpRuntimeConfig.fallback, client(null).mcpRuntimeConfig())
        assertTrue(McpRuntimeConfig.fallback.enabled)
    }

    @Test
    fun `out of range values are clamped instead of discarding the whole section`() {
        val config = client(
            """{"version":1,"providers":{},"mcpRuntimeConfig":{"maxServers":0,"maxSteps":99,"callTimeoutSeconds":1}}""",
        ).mcpRuntimeConfig()

        assertEquals(1, config.maxServers)
        assertEquals(8, config.maxSteps)
        assertEquals(5.0, config.callTimeoutSeconds, 0.0)
    }

    /** Writing the cache to disk and reading it back (the cold-start path) must not drop this block. */
    @Test
    fun `the section survives the persisted cache payload`() {
        val seed = client("""{"version":1,"providers":{},"mcpRuntimeConfig":{"enabled":false,"maxServers":3}}""")
        val cached = requireNotNull(seed.encodedCachePayloadForTesting())

        assertTrue("the cached payload must contain this block - $cached", "\"mcpRuntimeConfig\"" in cached)
        val restored = client(cached).mcpRuntimeConfig()
        assertFalse(restored.enabled)
        assertEquals(3, restored.maxServers)
    }
}
