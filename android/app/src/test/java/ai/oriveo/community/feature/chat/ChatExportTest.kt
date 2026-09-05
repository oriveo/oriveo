package ai.oriveo.community.feature.chat

import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatMessageState
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.core.model.Conversation
import ai.oriveo.community.core.model.ProviderKind
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.text.DateFormat
import java.text.SimpleDateFormat
import java.util.Locale
import java.util.TimeZone

class ChatExportTest {

    @Test
    fun markdown_layout_aligns_across_platforms() {
        val conv = makeConversation(
            title = "Hello World",
            updatedAt = 1_700_000_100_000L,
            messages = listOf(
                makeMessage(role = ChatRole.User, text = "Hi"),
                makeMessage(
                    role = ChatRole.Assistant,
                    text = "Hello back",
                    providerName = "OpenAI",
                    modelName = "GPT-4o",
                ),
            ),
        )

        val md = ChatExport.markdown(conv, fixedFormatter())

        val expected = listOf(
            "# Hello World",
            "",
            "*2023-11-14 22:15*",
            "",
            "## User",
            "",
            "Hi",
            "",
            "## Assistant",
            "",
            "Hello back",
            "",
            "*Model: GPT-4o (OpenAI)*",
            "",
        ).joinToString("\n")

        assertEquals(expected, md)
    }

    @Test
    fun empty_title_falls_back_to_untitled() {
        val conv = makeConversation(
            title = "   ",
            messages = listOf(makeMessage(role = ChatRole.User, text = "hi")),
        )

        val md = ChatExport.markdown(conv, fixedFormatter())

        assertTrue(md.startsWith("# Untitled"))
    }

    @Test
    fun skips_model_line_when_model_name_empty() {
        val conv = makeConversation(
            title = "Test",
            messages = listOf(
                makeMessage(role = ChatRole.Assistant, text = "ok", providerName = "P", modelName = ""),
            ),
        )

        val md = ChatExport.markdown(conv, fixedFormatter())

        assertFalse(md.contains("*Model:"))
    }

    @Test
    fun sanitize_filename_strips_invalid_chars_and_trims() {
        val raw = "a".repeat(120) + "/?<>:"
        val sanitized = ChatExport.sanitizeFilename(raw)

        val invalid = setOf('/', '\\', '?', '%', '*', ':', '|', '"', '<', '>')
        assertTrue(sanitized.length <= 100)
        assertTrue(sanitized.all { it !in invalid })
    }

    @Test
    fun sanitize_filename_falls_back_when_empty() {
        assertEquals("conversation", ChatExport.sanitizeFilename(""))
        assertEquals("conversation", ChatExport.sanitizeFilename("   "))
    }

    private fun fixedFormatter(): DateFormat =
        SimpleDateFormat("yyyy-MM-dd HH:mm", Locale.US).apply {
            timeZone = TimeZone.getTimeZone("UTC")
        }

    private fun makeConversation(
        title: String = "Test",
        updatedAt: Long = 1_700_000_100_000L,
        messages: List<ChatMessage> = emptyList(),
    ): Conversation = Conversation(
        id = "conv-1",
        title = title,
        providerID = "provider-1",
        providerKind = ProviderKind.OpenAI,
        modelID = "gpt-4o",
        messages = messages,
        updatedAt = updatedAt,
    )

    private fun makeMessage(
        role: ChatRole,
        text: String,
        providerName: String = "OpenAI",
        modelName: String = "GPT-4o",
    ): ChatMessage = ChatMessage(
        id = java.util.UUID.randomUUID().toString(),
        role = role,
        text = text,
        providerKind = ProviderKind.OpenAI,
        providerName = providerName,
        modelName = modelName,
        state = ChatMessageState.Delivered,
    )
}
