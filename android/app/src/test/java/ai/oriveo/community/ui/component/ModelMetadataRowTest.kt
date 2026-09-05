package ai.oriveo.community.ui.component

import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.ModelCapability
import org.junit.Assert.assertEquals
import org.junit.Test

class ModelMetadataRowTest {
    @Test
    fun `compact visible capabilities keep web search visible when supported`() {
        val model = AIModel(
            id = "openai/gpt-4o",
            name = "GPT-4o",
            capabilities = listOf(
                ModelCapability.Text,
                ModelCapability.Image,
                ModelCapability.File,
                ModelCapability.Web,
            ),
        )

        assertEquals(
            listOf(ModelCapability.Image, ModelCapability.Web),
            model.visibleMetadataCapabilities(maxCapabilities = 2),
        )
    }

    @Test
    fun `internal capabilities never enter metadata rendering`() {
        val model = AIModel(
            id = "managed/native-pdf",
            name = "Managed Native PDF",
            capabilities = listOf(
                ModelCapability.Text,
                ModelCapability.NativePdf,
                ModelCapability.Unknown,
                ModelCapability.File,
            ),
        )

        assertEquals(
            listOf(ModelCapability.File),
            model.visibleMetadataCapabilities(maxCapabilities = 3),
        )
    }

    @Test
    fun `model facts tool call is an ephemeral display badge and does not mutate capabilities`() {
        val model = AIModel(
            id = "grok-4.6",
            name = "Grok 4.6",
            capabilities = listOf(ModelCapability.Text, ModelCapability.Reasoning),
        )

        assertEquals(
            listOf(ModelCapability.Reasoning, ModelCapability.ToolCall),
            model.visibleMetadataCapabilities(maxCapabilities = 3, modelFactsToolCall = true),
        )
        assertEquals(listOf(ModelCapability.Text, ModelCapability.Reasoning), model.capabilities)
    }
}
