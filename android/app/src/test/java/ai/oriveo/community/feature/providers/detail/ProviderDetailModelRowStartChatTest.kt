package ai.oriveo.community.feature.providers.detail

import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * A model row on the detail page shows a disabled state when the credential is missing. The only criterion is
 * ProviderDetailViewModel.modelRowStartChatID (the criterion itself is locked by ProviderDetailViewModelTest);
 * this test locks that it is passed all the way to the row component, so the title tap and the chat button are
 * both disabled by it rather than by model.isAvailable alone (which left the button lit with no response when the key was missing).
 */
class ProviderDetailModelRowStartChatTest {

    private val detailScreen = source("ProviderDetailScreen.kt")
    private val enabledModels = source("ProviderDetailEnabledModels.kt")

    @Test
    fun `detail screen passes modelRowStartChatID as the row start-chat criterion`() {
        assertTrue(
            "the row start-chat criterion must come from modelRowStartChatID (the same criterion the tap uses)",
            detailScreen.contains("canStartChat = { model -> viewModel.modelRowStartChatID(currentProvider, model) != null }"),
        )
    }

    @Test
    fun `enabled model rows disable title tap and chat button by the criterion`() {
        val row = enabledModels.slice(from = "private fun EnabledModelRow(", to = "private fun EnabledRowChatButton(")
        assertTrue(row.contains("canStartChat: Boolean,"))
        assertTrue(row.contains(".clickable(enabled = canStartChat, onClick = onStartChat)"))
        assertTrue(row.contains("EnabledRowChatButton(available = canStartChat, onClick = onStartChat)"))
        assertTrue(row.contains("RelayCatalogRowTap.StartChat -> if (canStartChat) onStartChat()"))
        assertFalse("the chat button must not be disabled by model availability alone", row.contains("available = model.isAvailable"))
        assertFalse(row.contains(".clickable(enabled = model.isAvailable"))
    }

    @Test
    fun `the row list forwards the criterion per model`() {
        val list = enabledModels.slice(from = "fun LazyListScope.providerDetailEnabledModels(", to = "private fun EnabledModelRow(")
        assertTrue("the row must receive the criterion per model", Regex("canStartChat = canStartChat\\(model\\)").findAll(list).count() == 1)
    }

    private fun source(name: String): String =
        File("src/main/java/ai/oriveo/community/feature/providers/detail/$name").readText()

    private fun String.slice(from: String, to: String): String {
        val start = indexOf(from)
        require(start >= 0) { "Missing start boundary: $from" }
        val end = indexOf(to, start + from.length)
        require(end >= 0) { "Missing end boundary: $to" }
        return substring(start, end)
    }
}
