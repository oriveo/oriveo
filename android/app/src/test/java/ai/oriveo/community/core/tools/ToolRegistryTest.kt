package ai.oriveo.community.core.tools

import kotlinx.serialization.json.buildJsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

class ToolRegistryTest {
    private fun definition(name: String) = ToolLoopToolDefinition(
        function = ToolLoopToolFunction(name = name, description = "d", parameters = buildJsonObject {}),
    )

    private fun entry(
        name: String,
        scope: ToolScope = ToolScope.Mcp,
        definition: ToolLoopToolDefinition? = null,
        execute: suspend (ToolLoopToolCall, ToolExecutionContext) -> ToolExecutionOutcome =
            { _, _ -> ToolExecutionOutcome("ok") },
    ): ToolRegistryEntry = object : ToolRegistryEntry {
        override val name = name
        override val scope = scope
        override val definition = definition
        override suspend fun execute(call: ToolLoopToolCall, context: ToolExecutionContext) =
            execute(call, context)
    }

    @Test
    fun `entry lookup hits registered names and misses unknown ones`() {
        val registry = ToolRegistry(listOf(entry("search", definition = definition("search"))))

        assertEquals("search", registry.entry("search")?.name)
        assertNull(registry.entry("read"))
        assertFalse(registry.isEmpty)
    }

    @Test
    fun `duplicate names keep the first entry and registration order`() {
        val first = entry("search", definition = definition("search"))
        val second = entry("search", scope = ToolScope.Web, definition = definition("search"))
        val registry = ToolRegistry(listOf(first, second, entry("list")))

        assertSame(first, registry.entry("search"))
        assertEquals(listOf("search", "list"), registry.names)
    }

    @Test
    fun `definitions follow registration order and skip entries without a definition`() {
        val registry = ToolRegistry(
            listOf(
                entry("search", definition = definition("search")),
                // Server-side built-in tools (Moonshot $web_search) have no local definition and do not go into the request body's tools.
                entry("web_search", scope = ToolScope.Web, definition = null),
                entry("list", definition = definition("list")),
            ),
        )

        assertEquals(listOf("search", "list"), registry.definitions.map { it.function.name })
        assertEquals(listOf("search", "web_search", "list"), registry.names)
    }

    @Test
    fun `empty registry has no entries or definitions`() {
        val registry = ToolRegistry.Empty

        assertTrue(registry.isEmpty)
        assertNull(registry.entry("anything"))
        assertTrue(registry.definitions.isEmpty())
    }
}
