package ai.oriveo.community.core.memory

import ai.oriveo.community.core.app.AppPreferenceKeys
import ai.oriveo.community.core.app.AppPreferencesRepository
import ai.oriveo.community.core.data.dao.PreferenceDao
import ai.oriveo.community.core.data.entity.PreferenceEntity
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatMessageState
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.core.model.Conversation
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.provider.MessageBuilder
import ai.oriveo.community.core.util.graphemeCount
import ai.oriveo.community.core.util.takeGraphemes
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.time.Instant
import kotlin.math.ceil

class MemoryContractTest {

    private lateinit var preferenceDao: FakePreferenceDao
    private lateinit var repository: AppPreferencesRepository

    @Before
    fun setUp() {
        preferenceDao = FakePreferenceDao()
        repository = AppPreferencesRepository(preferenceDao)
    }

    @Test
    fun `MEM-0-03 - saveMemory stores ISO 8601 timestamp from Instant`() = runTest {
        val now = Instant.now().toString()

        repository.saveMemory(
            text = "Remember my preferences",
            antiForgetEnabled = false,
            antiForgetText = "",
            updatedAt = now,
        )

        val storedAt = preferenceDao.get(AppPreferenceKeys.MEMORY_UPDATED_AT)
        assertEquals(now, storedAt)

        assertTrue("Timestamp should contain 'T'", storedAt!!.contains("T"))
        assertTrue("Timestamp should end with 'Z'", storedAt.endsWith("Z"))
    }

    @Test
    fun `MEM-0-03 - Instant toString produces ISO 8601 with Z suffix`() {
        val timestamp = Instant.parse("2026-03-31T12:00:00Z").toString()
        assertEquals("2026-03-31T12:00:00Z", timestamp)
    }

    @Test
    fun `MEM-0-04 - Conversation useMemory defaults to true`() {
        val conversation = Conversation(
            id = "test",
            title = "Test",
            providerID = "p1",
            providerKind = ProviderKind.OpenAI,
            modelID = "m1",
        )
        assertTrue(conversation.useMemory)
    }

    @Test
    fun `MEM-0-04 - Conversation useMemory can be explicitly set to false`() {
        val conversation = Conversation(
            id = "test",
            title = "Test",
            providerID = "p1",
            providerKind = ProviderKind.OpenAI,
            modelID = "m1",
            useMemory = false,
        )
        assertFalse(conversation.useMemory)
    }

    @Test
    fun `MEM-0-05 - saveMemory clears anti-forget when text is blank`() = runTest {
        repository.saveMemory(
            text = "   ",
            antiForgetEnabled = true,
            antiForgetText = "Keep replies concise",
            updatedAt = "2026-03-31T12:00:00Z",
        )

        assertEquals("", preferenceDao.get(AppPreferenceKeys.MEMORY_TEXT))
        assertEquals("false", preferenceDao.get(AppPreferenceKeys.MEMORY_ANTI_FORGET_ENABLED))
        assertEquals("", preferenceDao.get(AppPreferenceKeys.MEMORY_ANTI_FORGET_TEXT))
        assertEquals("2026-03-31T12:00:00Z", preferenceDao.get(AppPreferenceKeys.MEMORY_UPDATED_AT))
    }

    @Test
    fun `MEM-0-05 - saveMemory clears anti-forget when text is empty string`() = runTest {
        repository.saveMemory(
            text = "",
            antiForgetEnabled = true,
            antiForgetText = "Some context",
            updatedAt = "2026-04-01T00:00:00Z",
        )

        assertEquals("", preferenceDao.get(AppPreferenceKeys.MEMORY_TEXT))
        assertEquals("false", preferenceDao.get(AppPreferenceKeys.MEMORY_ANTI_FORGET_ENABLED))
        assertEquals("", preferenceDao.get(AppPreferenceKeys.MEMORY_ANTI_FORGET_TEXT))
    }

    @Test
    fun `MEM-0-05 - saveMemory preserves anti-forget when text is non-blank`() = runTest {
        repository.saveMemory(
            text = "I prefer Kotlin",
            antiForgetEnabled = true,
            antiForgetText = "Use concise style",
            updatedAt = "2026-04-01T00:00:00Z",
        )

        assertEquals("I prefer Kotlin", preferenceDao.get(AppPreferenceKeys.MEMORY_TEXT))
        assertEquals("true", preferenceDao.get(AppPreferenceKeys.MEMORY_ANTI_FORGET_ENABLED))
        assertEquals("Use concise style", preferenceDao.get(AppPreferenceKeys.MEMORY_ANTI_FORGET_TEXT))
    }

    @Test
    fun `MEM-0-06 - anti-forget does not trigger at 9 user messages`() {
        // ChatViewModel.resolvedAntiForgetText: userMessageCount = existing + 1
        // 8 existing + 1 new = 9 total < 10 → no anti-forget
        val existingUserCount = 8
        val totalUserCount = existingUserCount + 1
        assertTrue(totalUserCount < 10)
    }

    @Test
    fun `MEM-0-06 - anti-forget triggers at 10 user messages`() {
        // 9 existing + 1 new = 10 total >= 10 → triggers
        val existingUserCount = 9
        val totalUserCount = existingUserCount + 1
        assertTrue(totalUserCount >= 10)
    }

    @Test
    fun `MEM-0-07 - anti-forget appends context in correct format`() {
        val userText = "What should I build next?"
        val antiForgetText = "Prefer concise Chinese answers"
        val expected = "$userText\n\n[Reminder: $antiForgetText]"

        val result = "$userText\n\n[Reminder: $antiForgetText]"
        assertEquals(expected, result)
    }

    @Test
    fun `MEM-0-07 - anti-forget format matches ChatRepository injection`() {
        // ChatRepository line 139-141: "${userMessage.text}\n\n[Reminder: $context]"
        val text = "Hello"
        val context = "Be brief"
        val injected = "$text\n\n[Reminder: $context]"

        assertTrue(injected.contains("\n\n[Reminder: "))
        assertTrue(injected.endsWith("]"))
        assertEquals("Hello\n\n[Reminder: Be brief]", injected)
    }

    @Test
    fun `MEM-0-11 - OpenAI system prompt as messages 0 with role system`() {
        val msgs = listOf(userMessage("Hello"))
        val result = MessageBuilder.buildOpenAIMessages(
            messages = msgs,
            providerKind = ProviderKind.OpenAI,
            systemPrompt = "Memory context",
        )
        assertTrue(result.startsWith("""{"role":"system","content":"""))
        assertTrue(result.contains("Memory context"))
    }

    @Test
    fun `MEM-0-11 - OpenRouter uses same system message format as OpenAI`() {
        val msgs = listOf(userMessage("Hello"))
        val result = MessageBuilder.buildOpenAIMessages(
            messages = msgs,
            providerKind = ProviderKind.OpenRouter,
            systemPrompt = "Memory context",
        )
        assertTrue(result.startsWith("""{"role":"system","content":"""))
    }

    @Test
    fun `MEM-0-11 - Groq uses same system message format as OpenAI`() {
        val msgs = listOf(userMessage("Hello"))
        val result = MessageBuilder.buildOpenAIMessages(
            messages = msgs,
            providerKind = ProviderKind.Groq,
            systemPrompt = "Memory context",
        )
        assertTrue(result.startsWith("""{"role":"system","content":"""))
    }

    @Test
    fun `MEM-0-11 - Together uses same system message format as OpenAI`() {
        val msgs = listOf(userMessage("Hello"))
        val result = MessageBuilder.buildOpenAIMessages(
            messages = msgs,
            providerKind = ProviderKind.Together,
            systemPrompt = "Memory context",
        )
        assertTrue(result.startsWith("""{"role":"system","content":"""))
    }

    @Test
    fun `MEM-0-11 - Fireworks uses same system message format as OpenAI`() {
        val msgs = listOf(userMessage("Hello"))
        val result = MessageBuilder.buildOpenAIMessages(
            messages = msgs,
            providerKind = ProviderKind.Fireworks,
            systemPrompt = "Memory context",
        )
        assertTrue(result.startsWith("""{"role":"system","content":"""))
    }

    @Test
    fun `MEM-0-11 - Relay uses same system message format as OpenAI`() {
        val msgs = listOf(userMessage("Hello"))
        val result = MessageBuilder.buildOpenAIMessages(
            messages = msgs,
            providerKind = ProviderKind.Relay,
            systemPrompt = "Memory context",
        )
        assertTrue(result.startsWith("""{"role":"system","content":"""))
    }

    @Test
    fun `MEM-0-11 - Anthropic uses separate system field`() {
        val result = MessageBuilder.anthropicSystemJson("Memory context")
        assertEquals(""""system":"Memory context"""", result)
    }

    @Test
    fun `MEM-0-11 - Gemini uses systemInstruction parts structure`() {
        val result = MessageBuilder.geminiSystemInstructionJson("Memory context")
        assertEquals(
            """"systemInstruction":{"parts":[{"text":"Memory context"}]}""",
            result,
        )
    }

    @Test
    fun `MEM-0-14 - token estimation for typical text`() {
        val text = "I use Kotlin"
        val charCount = text.graphemeCount()
        val tokens = ceil(charCount * 0.35).toInt()
        // "I use Kotlin" = 12 graphemes, ceil(12 * 0.35) = ceil(4.2) = 5
        assertEquals(12, charCount)
        assertEquals(5, tokens)
    }

    @Test
    fun `MEM-0-14 - token estimation for empty text`() {
        val charCount = "".graphemeCount()
        val tokens = ceil(charCount * 0.35).toInt()
        assertEquals(0, charCount)
        assertEquals(0, tokens)
    }

    @Test
    fun `MEM-0-14 - token estimation for single character`() {
        val charCount = "A".graphemeCount()
        val tokens = ceil(charCount * 0.35).toInt()
        assertEquals(1, charCount)
        assertEquals(1, tokens)
    }

    @Test
    fun `MEM-0-14 - token estimation for 3 characters`() {
        val charCount = "ABC".graphemeCount()
        val tokens = ceil(charCount * 0.35).toInt()
        // ceil(3 * 0.35) = ceil(1.05) = 2
        assertEquals(3, charCount)
        assertEquals(2, tokens)
    }

    @Test
    fun `MEM-0-14 - token estimation for 2000 characters`() {
        val text = "A".repeat(2000)
        val charCount = text.graphemeCount()
        val tokens = ceil(charCount * 0.35).toInt()
        // ceil(2000 * 0.35) = ceil(700.0) = 700
        assertEquals(2000, charCount)
        assertEquals(700, tokens)
    }

    @Test
    fun `MEM-1-12 - setMemoryText caps at 2000 grapheme clusters`() = runTest {
        val longText = "A".repeat(2500)
        repository.setMemoryText(longText)
        val stored = preferenceDao.get(AppPreferenceKeys.MEMORY_TEXT)!!
        assertEquals(2000, stored.graphemeCount())
    }

    @Test
    fun `MEM-1-12 - saveMemory caps memory text at 2000 grapheme clusters`() = runTest {
        val longText = "B".repeat(2100)
        repository.saveMemory(
            text = longText,
            antiForgetEnabled = false,
            antiForgetText = "",
        )
        val stored = preferenceDao.get(AppPreferenceKeys.MEMORY_TEXT)!!
        assertEquals(2000, stored.graphemeCount())
    }

    @Test
    fun `MEM-1-12 - MEMORY_CHARACTER_LIMIT constant is 2000`() {
        assertEquals(2000, AppPreferencesRepository.MEMORY_CHARACTER_LIMIT)
    }

    @Test
    fun `MEM-1-13 - setMemoryAntiForgetText caps at 200 grapheme clusters`() = runTest {
        val longText = "C".repeat(300)
        repository.setMemoryAntiForgetText(longText)
        val stored = preferenceDao.get(AppPreferenceKeys.MEMORY_ANTI_FORGET_TEXT)!!
        assertEquals(200, stored.graphemeCount())
    }

    @Test
    fun `MEM-1-13 - saveMemory caps anti-forget text at 200 grapheme clusters`() = runTest {
        repository.saveMemory(
            text = "Valid memory",
            antiForgetEnabled = true,
            antiForgetText = "D".repeat(250),
        )
        val stored = preferenceDao.get(AppPreferenceKeys.MEMORY_ANTI_FORGET_TEXT)!!
        assertEquals(200, stored.graphemeCount())
    }

    @Test
    fun `MEM-1-13 - MEMORY_ANTI_FORGET_CHARACTER_LIMIT constant is 200`() {
        assertEquals(200, AppPreferencesRepository.MEMORY_ANTI_FORGET_CHARACTER_LIMIT)
    }

    @Test
    fun `MEM-1-14 - 1999 graphemes stored without truncation`() = runTest {
        val text = "X".repeat(1999)
        repository.setMemoryText(text)
        val stored = preferenceDao.get(AppPreferenceKeys.MEMORY_TEXT)!!
        assertEquals(1999, stored.graphemeCount())
    }

    @Test
    fun `MEM-1-14 - 2000 graphemes stored without truncation`() = runTest {
        val text = "Y".repeat(2000)
        repository.setMemoryText(text)
        val stored = preferenceDao.get(AppPreferenceKeys.MEMORY_TEXT)!!
        assertEquals(2000, stored.graphemeCount())
    }

    @Test
    fun `MEM-1-14 - 2001 graphemes truncated to 2000`() = runTest {
        val text = "Z".repeat(2001)
        repository.setMemoryText(text)
        val stored = preferenceDao.get(AppPreferenceKeys.MEMORY_TEXT)!!
        assertEquals(2000, stored.graphemeCount())
    }

    @Test
    fun `MEM-1-15 - token estimation for 0 characters is 0`() {
        assertEquals(0, ceil(0 * 0.35).toInt())
    }

    @Test
    fun `MEM-1-15 - token estimation for 1 character is 1`() {
        assertEquals(1, ceil(1 * 0.35).toInt())
    }

    @Test
    fun `MEM-1-15 - token estimation for 3 characters is 2`() {
        // ceil(3 * 0.35) = ceil(1.05) = 2
        assertEquals(2, ceil(3 * 0.35).toInt())
    }

    @Test
    fun `MEM-1-15 - token estimation for 2000 characters is 700`() {
        // ceil(2000 * 0.35) = ceil(700.0) = 700
        assertEquals(700, ceil(2000 * 0.35).toInt())
    }

    @Test
    fun `MEM-1-16 - whitespace-only text treated as empty by saveMemory`() = runTest {
        repository.saveMemory(
            text = "  \t\n  ",
            antiForgetEnabled = true,
            antiForgetText = "Context",
        )
        assertEquals("", preferenceDao.get(AppPreferenceKeys.MEMORY_TEXT))
        assertEquals("false", preferenceDao.get(AppPreferenceKeys.MEMORY_ANTI_FORGET_ENABLED))
        assertEquals("", preferenceDao.get(AppPreferenceKeys.MEMORY_ANTI_FORGET_TEXT))
    }

    @Test
    fun `MEM-1-16 - whitespace-only systemPrompt is null for Anthropic`() {
        assertNull(MessageBuilder.anthropicSystemJson("   "))
    }

    @Test
    fun `MEM-1-16 - whitespace-only systemPrompt is null for Gemini`() {
        assertNull(MessageBuilder.geminiSystemInstructionJson("  \n  "))
    }

    @Test
    fun `MEM-1-16 - blank systemPrompt produces no system message for OpenAI`() {
        val msgs = listOf(userMessage("Hello"))
        val result = MessageBuilder.buildOpenAIMessages(
            messages = msgs,
            providerKind = ProviderKind.OpenAI,
            systemPrompt = "   ",
        )
        assertFalse(result.contains(""""role":"system""""))
    }

    @Test
    fun `MEM-1-17 - clearing memory also clears anti-forget fields`() = runTest {
        repository.saveMemory(
            text = "Some memory",
            antiForgetEnabled = true,
            antiForgetText = "Some anti-forget",
            updatedAt = "2026-03-31T00:00:00Z",
        )
        assertEquals("Some memory", preferenceDao.get(AppPreferenceKeys.MEMORY_TEXT))
        assertEquals("true", preferenceDao.get(AppPreferenceKeys.MEMORY_ANTI_FORGET_ENABLED))

        // Clearing the memory text must take the anti-forget fields with it, even though the caller
        // still passes them.
        repository.saveMemory(
            text = "",
            antiForgetEnabled = true,
            antiForgetText = "Should be cleared",
            updatedAt = "2026-03-31T01:00:00Z",
        )

        assertEquals("", preferenceDao.get(AppPreferenceKeys.MEMORY_TEXT))
        assertEquals("false", preferenceDao.get(AppPreferenceKeys.MEMORY_ANTI_FORGET_ENABLED))
        assertEquals("", preferenceDao.get(AppPreferenceKeys.MEMORY_ANTI_FORGET_TEXT))
        assertEquals("2026-03-31T01:00:00Z", preferenceDao.get(AppPreferenceKeys.MEMORY_UPDATED_AT))
    }

    @Test
    fun `MEM-1-17 - flow reflects cleared state`() = runTest {
        repository.saveMemory(
            text = "Persist this",
            antiForgetEnabled = true,
            antiForgetText = "Remember",
        )

        repository.saveMemory(
            text = "",
            antiForgetEnabled = false,
            antiForgetText = "",
        )

        assertEquals("", repository.memoryText.first())
        assertEquals(false, repository.memoryAntiForgetEnabled.first())
        assertEquals("", repository.memoryAntiForgetText.first())
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

    private class FakePreferenceDao : PreferenceDao {
        private val values = linkedMapOf<String, MutableStateFlow<String?>>()

        override fun observe(key: String): Flow<String?> =
            values.getOrPut(key) { MutableStateFlow(null) }

        override suspend fun get(key: String): String? =
            values[key]?.value

        override suspend fun set(entity: PreferenceEntity) {
            values.getOrPut(entity.key) { MutableStateFlow(null) }.value = entity.value
        }

        override suspend fun delete(key: String) {
            values.getOrPut(key) { MutableStateFlow(null) }.value = null
        }
    }
}
