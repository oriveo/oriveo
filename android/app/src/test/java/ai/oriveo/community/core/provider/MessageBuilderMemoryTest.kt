package ai.oriveo.community.core.provider

import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatMessageState
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.core.model.ProviderKind
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Memory injection format tests for MessageBuilder.
 *
 * Covers the system prompt injection format of each provider, plus the handling of special characters: quotes,
 * newlines, backslashes and non-ASCII text.
 */
class MessageBuilderMemoryTest {

    // ── buildOpenAIMessages: system prompt → messages[0] with role system ──

    @Test
    fun `buildOpenAIMessages prepends system message with memory text`() {
        val msgs = listOf(userMessage("Hello"))
        val result = MessageBuilder.buildOpenAIMessages(
            messages = msgs,
            providerKind = ProviderKind.OpenAI,
            systemPrompt = "User prefers Kotlin and Go",
        )

        // The system message comes first
        assertTrue(result.startsWith("""{"role":"system","content":"""))
        assertTrue(result.contains("User prefers Kotlin and Go"))
        // and the user message follows it
        assertTrue(result.contains("""{"role":"user","content":"Hello"}"""))
    }

    @Test
    fun `buildOpenAIMessages with null systemPrompt has no system message`() {
        val msgs = listOf(userMessage("Hello"))
        val result = MessageBuilder.buildOpenAIMessages(
            messages = msgs,
            providerKind = ProviderKind.OpenAI,
            systemPrompt = null,
        )
        assertTrue(result.startsWith("""{"role":"user""""))
    }

    @Test
    fun `buildOpenAIMessages with blank systemPrompt has no system message`() {
        val msgs = listOf(userMessage("Hello"))
        val result = MessageBuilder.buildOpenAIMessages(
            messages = msgs,
            providerKind = ProviderKind.OpenAI,
            systemPrompt = "  ",
        )
        assertTrue(result.startsWith("""{"role":"user""""))
    }

    @Test
    fun `buildOpenAIMessages trims system prompt whitespace`() {
        val msgs = listOf(userMessage("Hi"))
        val result = MessageBuilder.buildOpenAIMessages(
            messages = msgs,
            providerKind = ProviderKind.OpenAI,
            systemPrompt = "  Be concise  ",
        )
        assertTrue(result.contains("Be concise"))
        // Confirm there is no leading or trailing whitespace
        assertTrue(result.contains(""""content":"Be concise""""))
    }

    // -- special character handling (OpenAI format) --

    @Test
    fun `buildOpenAIMessages escapes double quotes in system prompt`() {
        val msgs = listOf(userMessage("Hi"))
        val result = MessageBuilder.buildOpenAIMessages(
            messages = msgs,
            providerKind = ProviderKind.OpenAI,
            systemPrompt = """User said "hello"""",
        )
        assertTrue(result.contains("""\""""))
    }

    @Test
    fun `buildOpenAIMessages escapes newlines in system prompt`() {
        val msgs = listOf(userMessage("Hi"))
        val result = MessageBuilder.buildOpenAIMessages(
            messages = msgs,
            providerKind = ProviderKind.OpenAI,
            systemPrompt = "Line1\nLine2",
        )
        assertTrue(result.contains("\\n"))
    }

    @Test
    fun `buildOpenAIMessages escapes backslashes in system prompt`() {
        val msgs = listOf(userMessage("Hi"))
        val result = MessageBuilder.buildOpenAIMessages(
            messages = msgs,
            providerKind = ProviderKind.OpenAI,
            systemPrompt = "Path: C:\\Users\\test",
        )
        assertTrue(result.contains("\\\\"))
    }

    @Test
    fun `buildOpenAIMessages handles unicode in system prompt`() {
        val msgs = listOf(userMessage("Hi"))
        val result = MessageBuilder.buildOpenAIMessages(
            messages = msgs,
            providerKind = ProviderKind.OpenAI,
            systemPrompt = "\u7528\u6237\u504f\u597d\u4e2d\u6587\u56de\u590d \uD83D\uDE80",
        )
        assertTrue(result.contains("\u7528\u6237\u504f\u597d\u4e2d\u6587\u56de\u590d"))
    }

    // -- anthropicSystemJson: a standalone system field --

    @Test
    fun `anthropicSystemJson produces correct format`() {
        val result = MessageBuilder.anthropicSystemJson("Memory: user likes cats")
        assertEquals(""""system":"Memory: user likes cats"""", result)
    }

    @Test
    fun `anthropicSystemJson returns null for null input`() {
        assertNull(MessageBuilder.anthropicSystemJson(null))
    }

    @Test
    fun `anthropicSystemJson returns null for blank input`() {
        assertNull(MessageBuilder.anthropicSystemJson(""))
        assertNull(MessageBuilder.anthropicSystemJson("   "))
    }

    @Test
    fun `anthropicSystemJson trims whitespace`() {
        val result = MessageBuilder.anthropicSystemJson("  Be concise  ")
        assertEquals(""""system":"Be concise"""", result)
    }

    @Test
    fun `anthropicSystemJson escapes double quotes`() {
        val result = MessageBuilder.anthropicSystemJson("""Call me "Boss"""")
        assertTrue(result!!.contains("""\""""))
    }

    @Test
    fun `anthropicSystemJson escapes newlines`() {
        val result = MessageBuilder.anthropicSystemJson("Line1\nLine2")
        assertTrue(result!!.contains("\\n"))
    }

    @Test
    fun `anthropicSystemJson escapes backslashes`() {
        val result = MessageBuilder.anthropicSystemJson("C:\\path\\to")
        assertTrue(result!!.contains("\\\\"))
    }

    @Test
    fun `anthropicSystemJson handles unicode`() {
        val result = MessageBuilder.anthropicSystemJson("\u7528\u6237\u504f\u597d\uff1a\u7b80\u6d01 \uD83D\uDC3E")
        assertTrue(result!!.contains("\u7528\u6237\u504f\u597d\uff1a\u7b80\u6d01"))
    }

    // ── geminiSystemInstructionJson: systemInstruction.parts[0].text ──

    @Test
    fun `geminiSystemInstructionJson produces correct nested structure`() {
        val result = MessageBuilder.geminiSystemInstructionJson("Memory: user likes cats")
        assertEquals(
            """"systemInstruction":{"parts":[{"text":"Memory: user likes cats"}]}""",
            result,
        )
    }

    @Test
    fun `geminiSystemInstructionJson returns null for null input`() {
        assertNull(MessageBuilder.geminiSystemInstructionJson(null))
    }

    @Test
    fun `geminiSystemInstructionJson returns null for blank input`() {
        assertNull(MessageBuilder.geminiSystemInstructionJson(""))
        assertNull(MessageBuilder.geminiSystemInstructionJson("   "))
    }

    @Test
    fun `geminiSystemInstructionJson trims whitespace`() {
        val result = MessageBuilder.geminiSystemInstructionJson("  Be concise  ")
        assertTrue(result!!.contains(""""text":"Be concise""""))
    }

    @Test
    fun `geminiSystemInstructionJson escapes double quotes`() {
        val result = MessageBuilder.geminiSystemInstructionJson("""Say "hi"""")
        assertTrue(result!!.contains("""\""""))
    }

    @Test
    fun `geminiSystemInstructionJson escapes newlines`() {
        val result = MessageBuilder.geminiSystemInstructionJson("Line1\nLine2")
        assertTrue(result!!.contains("\\n"))
    }

    @Test
    fun `geminiSystemInstructionJson escapes backslashes`() {
        val result = MessageBuilder.geminiSystemInstructionJson("C:\\dir")
        assertTrue(result!!.contains("\\\\"))
    }

    @Test
    fun `geminiSystemInstructionJson handles unicode`() {
        val result = MessageBuilder.geminiSystemInstructionJson("\u7528\u6237\uff1a\u4f7f\u7528\u4e2d\u6587\u56de\u7b54")
        assertTrue(result!!.contains("\u7528\u6237\uff1a\u4f7f\u7528\u4e2d\u6587\u56de\u7b54"))
    }

    // -- consistency across providers --

    @Test
    fun `all OpenAI-compatible providers produce identical system message format`() {
        val providers = listOf(
            ProviderKind.OpenAI,
            ProviderKind.OpenRouter,
            ProviderKind.Groq,
            ProviderKind.Together,
            ProviderKind.Fireworks,
            ProviderKind.Relay,
        )
        val msgs = listOf(userMessage("test"))
        val systemPrompt = "Memory context"

        val results = providers.map { kind ->
            MessageBuilder.buildOpenAIMessages(
                messages = msgs,
                providerKind = kind,
                systemPrompt = systemPrompt,
            )
        }

        // The system message prefix must be identical across every OpenAI-compatible provider
        val systemPrefix = """{"role":"system","content":"Memory context"}"""
        results.forEachIndexed { index, result ->
            assertTrue(
                "Provider ${providers[index]} should start with system message",
                result.startsWith("""{"role":"system","content":"Memory context"}"""),
            )
        }
    }

    // ── Helper ──

    private fun userMessage(text: String) = ChatMessage(
        id = "msg-1",
        role = ChatRole.User,
        text = text,
        providerKind = ProviderKind.OpenAI,
        providerName = "OpenAI",
        modelName = "GPT-4o mini",
        state = ChatMessageState.Delivered,
    )
}
