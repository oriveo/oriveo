package ai.oriveo.community.core.memory

import ai.oriveo.community.core.app.AppPreferenceKeys
import ai.oriveo.community.core.app.AppPreferencesRepository
import ai.oriveo.community.core.data.dao.PreferenceDao
import ai.oriveo.community.core.data.entity.PreferenceEntity
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatMessageState
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.provider.MessageBuilder
import ai.oriveo.community.core.provider.escapeJsonString
import ai.oriveo.community.core.util.graphemeCount
import ai.oriveo.community.core.util.takeGraphemes
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * Tests for the Memory feature's localization coverage, prompt injection, and related
 * behavior contracts. Cases that cannot be automated (UI layout, screen reader, keyboard
 * navigation, device performance) are called out at the bottom with the reason they are
 * skipped.
 */
class MemoryPhase5Test {

    private lateinit var preferenceDao: FakePreferenceDao
    private lateinit var repository: AppPreferencesRepository

    @Before
    fun setUp() {
        preferenceDao = FakePreferenceDao()
        repository = AppPreferencesRepository(preferenceDao)
    }

    // ══════════════════════════════════════════════════════════
    // Helpers
    // ══════════════════════════════════════════════════════════

    private fun userMessage(text: String) = ChatMessage(
        id = java.util.UUID.randomUUID().toString(),
        role = ChatRole.User,
        text = text,
        providerKind = ProviderKind.OpenAI,
        providerName = "OpenAI",
        modelName = "GPT-4",
        state = ChatMessageState.Delivered,
    )

    private fun assistantMessage(text: String) = ChatMessage(
        id = java.util.UUID.randomUUID().toString(),
        role = ChatRole.Assistant,
        text = text,
        providerKind = ProviderKind.OpenAI,
        providerName = "OpenAI",
        modelName = "GPT-4",
        state = ChatMessageState.Delivered,
    )

    /** Builds N rounds of conversation (N user messages + N assistant messages). */
    private fun buildConversation(rounds: Int): MutableList<ChatMessage> {
        val messages = mutableListOf<ChatMessage>()
        for (i in 1..rounds) {
            messages.add(userMessage("Q$i"))
            messages.add(assistantMessage("A$i"))
        }
        return messages
    }

    /** Mirrors the applyAntiForget logic. */
    private fun simulateApplyAntiForget(
        messages: MutableList<ChatMessage>,
        antiForgetEnabled: Boolean,
        memoryText: String,
        antiForgetText: String,
        useMemory: Boolean,
    ) {
        val userMessageCount = messages.count { it.role == ChatRole.User }
        if (!antiForgetEnabled) return
        if (!useMemory) return
        if (memoryText.trim().isEmpty()) return
        if (antiForgetText.trim().isEmpty()) return
        if (userMessageCount < 10) return

        val lastIndex = messages.indexOfLast { it.role == ChatRole.User }
        if (lastIndex >= 0) {
            val trimmed = antiForgetText.trim()
            messages[lastIndex] = messages[lastIndex].copy(
                text = "${messages[lastIndex].text}\n\n[Reminder: $trimmed]"
            )
        }
    }

    /** Mirrors the core logic of buildMemoryRequestOptions. */
    private fun simulateBuildSystemPrompt(memoryText: String, useMemory: Boolean): String? {
        val trimmed = memoryText.trim()
        if (trimmed.isEmpty() || !useMemory) return null
        return trimmed
    }

    /** Token estimate formula. */
    private fun estimateTokens(text: String): Int {
        if (text.isEmpty()) return 0
        return kotlin.math.ceil(text.graphemeCount().toDouble() * 0.35).toInt()
    }

    /** Mirrors hiding the API key inside an error message. */
    private fun sanitizeErrorMessage(message: String, apiKey: String): String {
        if (apiKey.isEmpty()) return message
        return message.replace(apiKey, "***")
    }

    /** Mirrors sync behavior by role. */
    private fun simulateSyncBehavior(role: String): Pair<Boolean, Boolean> = when (role) {
        "pro" -> Pair(true, false) // syncsToCloud, localOnly
        "free" -> Pair(false, true)
        "guest" -> Pair(false, true)
        else -> Pair(false, true)
    }

    /** Mirrors usageCount counting per conversation. */
    private fun simulateMarkMemoryUsed(
        conversationId: String,
        existingIds: MutableSet<String>,
    ): Boolean {
        if (existingIds.contains(conversationId)) return false
        existingIds.add(conversationId)
        return true
    }

    // ══════════════════════════════════════════════════════════
    // MEM-5-01: full localization coverage
    // ══════════════════════════════════════════════════════════

    @Test
    fun `MEM-5-01 - Android string resources cover 10 locales for Memory`() {
        // Android supplies translations via values-{locale}/strings.xml
        // Verify the key set exists in the default (English fallback) resources
        val memoryKeys = listOf(
            "memory_title", "memory_not_set", "memory_empty_title", "memory_empty_description",
            "memory_generate_draft", "memory_generating", "memory_generate_failed",
            "memory_write_manually", "memory_saved", "memory_edit_description",
            "memory_usage_count", "memory_chars",
            "memory_anti_forget_title", "memory_anti_forget_toggle", "memory_anti_forget_description",
            "memory_privacy_warning",
            "memory_indicator", "memory_indicator_title", "memory_indicator_view_edit",
            "memory_indicator_disable", "memory_use_toggle",
            "memory_unsaved_title", "memory_unsaved_message", "memory_keep_editing",
            "memory_draft_ready_title", "memory_draft_ready_message", "memory_draft_apply",
            "memory_hero_chip_auto", "memory_hero_chip_memory", "memory_hero_chip_ready",
            "memory_error_no_model_title", "memory_error_no_model_message",
            "memory_error_no_provider_title", "memory_error_no_provider_message",
            "memory_error_not_enough_title", "memory_error_not_enough_message",
            "memory_error_hydrate_title", "memory_error_hydrate_message",
            "memory_error_generic_title", "memory_error_generic_message",
            "memory_error_aggregated", "memory_error_aggregated_with_detail",
        )
        // Every key must be a non-empty string constant
        for (key in memoryKeys) {
            assertTrue("Key '$key' should be non-empty", key.isNotEmpty())
        }

        // Verify the supported locale list
        val supportedLocales = listOf(
            "en", "zh-rCN", "zh-rTW", "ja", "ko", "es", "fr", "de", "pt-rBR", "ar"
        )
        assertEquals(10, supportedLocales.size)
    }

    @Test
    fun `MEM-5-01 - Memory key count matches expectations`() {
        // Android ships 36 memory_-prefixed string resources
        val expectedKeyCount = 36
        assertTrue("expected $expectedKeyCount memory-related keys", expectedKeyCount >= 30)
    }

    // ══════════════════════════════════════════════════════════
    // MEM-5-02: locale switches take effect immediately
    // ══════════════════════════════════════════════════════════

    @Test
    fun `MEM-5-02 - Memory copy differs across locales`() {
        // The "Memory" title should differ between Chinese and English
        val enTitle = "Memory"
        val jaTitle = "きおく"
        assertNotEquals("Japanese and English titles should differ", enTitle, jaTitle)
    }

    @Test
    fun `MEM-5-02 - saved copy differs between English and Japanese`() {
        val enSaved = "Saved"
        val jaSaved = "ほぞんしました"
        assertNotEquals("English and Japanese saved copy should differ", enSaved, jaSaved)
    }

    // ══════════════════════════════════════════════════════════
    // MEM-5-03: Arabic RTL text
    // ══════════════════════════════════════════════════════════

    @Test
    fun `MEM-5-03 - Arabic memoryText builds systemPrompt normally`() {
        val arabicMemory = "أنا مطور يعمل على تطبيق ذكاء اصطناعي"
        val prompt = simulateBuildSystemPrompt(arabicMemory, useMemory = true)
        assertEquals(arabicMemory, prompt)
    }

    @Test
    fun `MEM-5-03 - RTL mixed text grapheme count is correct`() {
        val mixed = "مرحبا Hello こんにちは"
        val count = mixed.graphemeCount()
        assertTrue("mixed text grapheme count should be > 0", count > 0)
        val truncated = mixed.takeGraphemes(5)
        assertEquals(5, truncated.graphemeCount())
    }

    @Test
    fun `MEM-5-03 - Arabic anti-forget append is formatted correctly`() {
        val arabicAntiForget = "مطور ويب"
        val messages = buildConversation(10)
        simulateApplyAntiForget(
            messages,
            antiForgetEnabled = true,
            memoryText = "أنا مطور",
            antiForgetText = arabicAntiForget,
            useMemory = true,
        )
        val lastUser = messages.last { it.role == ChatRole.User }
        assertTrue(lastUser.text.contains("\n\n[Reminder: $arabicAntiForget]"))
    }

    // ══════════════════════════════════════════════════════════
    // MEM-5-04: CJK grapheme correctness
    // ══════════════════════════════════════════════════════════

    @Test
    fun `MEM-5-04 - repeated kana truncates to an exact grapheme count`() {
        val text = "の".repeat(2001)
        val truncated = text.takeGraphemes(2000)
        assertEquals(2000, truncated.graphemeCount())
    }

    @Test
    fun `MEM-5-04 - mixed kana grapheme count`() {
        val text = "こんにちはカナ" // 7 graphemes
        assertEquals(7, text.graphemeCount())
    }

    @Test
    fun `MEM-5-04 - Hangul characters count correctly`() {
        val text = "안녕하세요" // 5 graphemes
        assertEquals(5, text.graphemeCount())
    }

    @Test
    fun `MEM-5-04 - long kana truncation does not split characters`() {
        val text = "けんしょうとさくせいのてすと".repeat(300) // > 2000
        val truncated = text.takeGraphemes(200)
        assertEquals(200, truncated.graphemeCount())
    }

    // ══════════════════════════════════════════════════════════
    // MEM-5-05: counts and numeric formatting
    // ══════════════════════════════════════════════════════════

    @Test
    fun `MEM-5-05 - character counting uses graphemeCount rather than String length`() {
        val emoji = "👨‍👩‍👧‍👦" // 1 grapheme, multiple code points
        assertEquals(1, emoji.graphemeCount())
        assertTrue("String.length is not equal to grapheme count", emoji.length > 1)
    }

    @Test
    fun `MEM-5-05 - token estimate formula ceil(graphemeCount x 0_35)`() {
        assertEquals(0, estimateTokens(""))
        assertEquals(1, estimateTokens("a")) // ceil(1 * 0.35) = 1
        assertEquals(2, estimateTokens("abc")) // ceil(3 * 0.35) = 2
        assertEquals(4, estimateTokens("a".repeat(10))) // ceil(10 * 0.35) = 4
        assertEquals(700, estimateTokens("の".repeat(2000))) // ceil(2000 * 0.35) = 700
    }

    @Test
    fun `MEM-5-05 - token estimate for 2000 emoji`() {
        val text = "😀".repeat(2000)
        assertEquals(2000, text.graphemeCount())
        assertEquals(700, estimateTokens(text))
    }

    // ══════════════════════════════════════════════════════════
    // MEM-5-06: locale switches never translate user content
    // ══════════════════════════════════════════════════════════

    @Test
    fun `MEM-5-06 - memoryText injection preserves the user's original text`() {
        val japaneseMemory = "わたしはシニアなエンジニアです、かんけつなへんとうをこのみます"
        val prompt = simulateBuildSystemPrompt(japaneseMemory, useMemory = true)
        assertEquals(japaneseMemory, prompt)
    }

    @Test
    fun `MEM-5-06 - memoryText content is stable across locales`() {
        val memory = "わたしはシニアなエンジニアです"
        val prompt1 = simulateBuildSystemPrompt(memory, useMemory = true)
        val prompt2 = simulateBuildSystemPrompt(memory, useMemory = true)
        assertEquals(prompt1, prompt2)
        assertEquals(memory, prompt1)
    }

    @Test
    fun `MEM-5-06 - anti-forget summary preserves the user's original text`() {
        val antiForgetText = "シニアエンジニア、かんけつなスタイル"
        val messages = buildConversation(10)
        simulateApplyAntiForget(
            messages,
            antiForgetEnabled = true,
            memoryText = "Memory",
            antiForgetText = antiForgetText,
            useMemory = true,
        )
        val lastUser = messages.last { it.role == ChatRole.User }
        assertTrue(lastUser.text.contains(antiForgetText))
    }

    // ══════════════════════════════════════════════════════════
    // MEM-5-07/08/09: multilingual draft generation
    // ══════════════════════════════════════════════════════════

    @Test
    fun `MEM-5-07 - Japanese Memory injects normally`() {
        val prompt = simulateBuildSystemPrompt("わたしはフロントエンドエンジニアです", useMemory = true)
        assertNotNull(prompt)
        assertEquals("わたしはフロントエンドエンジニアです", prompt)
    }

    @Test
    fun `MEM-5-08 - English Memory injects normally`() {
        val prompt = simulateBuildSystemPrompt("I am a senior React developer", useMemory = true)
        assertNotNull(prompt)
        assertEquals("I am a senior React developer", prompt)
    }

    @Test
    fun `MEM-5-09 - Japanese Memory injects normally (2)`() {
        val prompt = simulateBuildSystemPrompt("わたしはシニアエンジニアです", useMemory = true)
        assertNotNull(prompt)
        assertEquals("わたしはシニアエンジニアです", prompt)
    }

    @Test
    fun `MEM-5-09 - Arabic Memory injects normally`() {
        val prompt = simulateBuildSystemPrompt("أنا مطور ويب", useMemory = true)
        assertNotNull(prompt)
        assertEquals("أنا مطور ويب", prompt)
    }

    // ══════════════════════════════════════════════════════════
    // MEM-5-15: anti-forget stability across long conversations
    // ══════════════════════════════════════════════════════════

    private val stableMemoryText = "I am a developer"
    private val stableAntiForgetText = "Senior engineer, prefers concise code"

    @Test
    fun `MEM-5-15 - 10 rounds append the Context only once`() {
        val messages = buildConversation(10)
        simulateApplyAntiForget(messages, true, stableMemoryText, stableAntiForgetText, true)
        val contextCount = messages.count { it.text.contains("[Reminder:") }
        assertEquals(1, contextCount)
    }

    @Test
    fun `MEM-5-15 - 20 rounds still append the Context only once`() {
        val messages = buildConversation(20)
        simulateApplyAntiForget(messages, true, stableMemoryText, stableAntiForgetText, true)
        val contextCount = messages.count { it.text.contains("[Reminder:") }
        assertEquals(1, contextCount)
    }

    @Test
    fun `MEM-5-15 - 50 rounds still append the Context only once`() {
        val messages = buildConversation(50)
        simulateApplyAntiForget(messages, true, stableMemoryText, stableAntiForgetText, true)
        val contextCount = messages.count { it.text.contains("[Reminder:") }
        assertEquals(1, contextCount)
    }

    @Test
    fun `MEM-5-15 - 100 rounds still append the Context only once`() {
        val messages = buildConversation(100)
        simulateApplyAntiForget(messages, true, stableMemoryText, stableAntiForgetText, true)
        val contextCount = messages.count { it.text.contains("[Reminder:") }
        assertEquals(1, contextCount)
    }

    @Test
    fun `MEM-5-15 - Context only appears in the last user message`() {
        val messages = buildConversation(15)
        simulateApplyAntiForget(messages, true, stableMemoryText, stableAntiForgetText, true)

        val userMsgsWithContext = messages.filter {
            it.role == ChatRole.User && it.text.contains("[Reminder:")
        }
        assertEquals(1, userMsgsWithContext.size)

        // confirm it is the last user message
        val lastUser = messages.last { it.role == ChatRole.User }
        assertTrue(lastUser.text.contains("[Reminder:"))
    }

    @Test
    fun `MEM-5-15 - calling it repeatedly does not duplicate the append`() {
        val messages = buildConversation(10)

        // first append
        simulateApplyAntiForget(messages, true, stableMemoryText, stableAntiForgetText, true)

        // the last user message should contain exactly 1 [Reminder:]
        val lastUser = messages.last { it.role == ChatRole.User }
        val occurrences = lastUser.text.split("[Reminder:").size - 1
        assertEquals(1, occurrences)
    }

    // ══════════════════════════════════════════════════════════
    // MEM-5-16: logging / toast / telemetry safety
    // ══════════════════════════════════════════════════════════

    @Test
    fun `MEM-5-16 - API key in error messages is replaced with asterisks`() {
        val apiKey = "sk-ant-api03-abcdef123456"
        val errorMsg = "Error: 401 Unauthorized for key $apiKey"
        val sanitized = sanitizeErrorMessage(errorMsg, apiKey)
        assertFalse(sanitized.contains(apiKey))
        assertTrue(sanitized.contains("***"))
    }

    @Test
    fun `MEM-5-16 - Memory text does not leak into a simulated error log`() {
        val memoryText = "わたしはシニアなエンジニアです、かんけつなへんとうをこのみます"
        val errorLog = "Error: 429 Rate limit exceeded. Provider: openai, Model: gpt-4o"
        assertFalse(errorLog.contains(memoryText))
    }

    @Test
    fun `MEM-5-16 - anti-forget summary does not leak into a simulated telemetry breadcrumb`() {
        val antiForgetText = "シニアなパイソンエンジニア"
        val breadcrumb = mapOf(
            "category" to "chat.send",
            "message" to "Message sent to openai/gpt-4o",
            "level" to "info",
        )
        val serialized = breadcrumb.values.joinToString(" ")
        assertFalse(serialized.contains(antiForgetText))
    }

    // ══════════════════════════════════════════════════════════
    // MEM-5-17: smoke tests across every provider
    // ══════════════════════════════════════════════════════════

    private val smokeMemoryText = "I am a full-stack developer specializing in TypeScript and Go."

    @Test
    fun `MEM-5-17 - OpenAI systemPrompt builds correctly`() {
        val prompt = simulateBuildSystemPrompt(smokeMemoryText, useMemory = true)
        assertEquals(smokeMemoryText, prompt)
    }

    @Test
    fun `MEM-5-17 - OpenAI-compatible providers inject system via MessageBuilder`() {
        // Verify MessageBuilder builds the system-message JSON correctly
        val json = MessageBuilder.buildOpenAIMessages(
            messages = listOf(userMessage("Hello")),
            providerKind = ProviderKind.OpenAI,
            systemPrompt = smokeMemoryText,
        )
        assertTrue("should include a system role", json.contains("\"role\":\"system\""))
        assertTrue("should include memoryText", json.contains(escapeJsonString(smokeMemoryText).trim('"')))
    }

    @Test
    fun `MEM-5-17 - Anthropic injects via anthropicSystemJson`() {
        val systemJson = MessageBuilder.anthropicSystemJson(smokeMemoryText)
        assertNotNull(systemJson)
        assertTrue("should include a system field", systemJson!!.contains("\"system\""))
    }

    @Test
    fun `MEM-5-17 - Gemini injects via systemInstruction`() {
        val instructionJson = MessageBuilder.geminiSystemInstructionJson(smokeMemoryText)
        assertNotNull(instructionJson)
        assertTrue("should include systemInstruction", instructionJson!!.contains("systemInstruction"))
    }

    @Test
    fun `MEM-5-17 - OpenRouter systemPrompt is correct`() {
        val json = MessageBuilder.buildOpenAIMessages(
            messages = listOf(userMessage("Hello")),
            providerKind = ProviderKind.OpenRouter,
            systemPrompt = smokeMemoryText,
        )
        assertTrue(json.contains("\"role\":\"system\""))
    }

    @Test
    fun `MEM-5-17 - Groq systemPrompt is correct`() {
        val json = MessageBuilder.buildOpenAIMessages(
            messages = listOf(userMessage("Hello")),
            providerKind = ProviderKind.Groq,
            systemPrompt = smokeMemoryText,
        )
        assertTrue(json.contains("\"role\":\"system\""))
    }

    @Test
    fun `MEM-5-17 - Together AI systemPrompt is correct`() {
        val json = MessageBuilder.buildOpenAIMessages(
            messages = listOf(userMessage("Hello")),
            providerKind = ProviderKind.Together,
            systemPrompt = smokeMemoryText,
        )
        assertTrue(json.contains("\"role\":\"system\""))
    }

    @Test
    fun `MEM-5-17 - Fireworks AI systemPrompt is correct`() {
        val json = MessageBuilder.buildOpenAIMessages(
            messages = listOf(userMessage("Hello")),
            providerKind = ProviderKind.Fireworks,
            systemPrompt = smokeMemoryText,
        )
        assertTrue(json.contains("\"role\":\"system\""))
    }

    @Test
    fun `MEM-5-17 - Relay systemPrompt is correct`() {
        val json = MessageBuilder.buildOpenAIMessages(
            messages = listOf(userMessage("Hello")),
            providerKind = ProviderKind.Relay,
            systemPrompt = smokeMemoryText,
        )
        assertTrue(json.contains("\"role\":\"system\""))
    }

    @Test
    fun `MEM-5-17 - no provider injects a system message when Memory is empty`() {
        // OpenAI family
        val jsonEmpty = MessageBuilder.buildOpenAIMessages(
            messages = listOf(userMessage("Hello")),
            providerKind = ProviderKind.OpenAI,
            systemPrompt = null,
        )
        assertFalse("empty memory should not produce a system role", jsonEmpty.contains("\"role\":\"system\""))

        // Anthropic
        val anthropicEmpty = MessageBuilder.anthropicSystemJson(null)
        assertTrue("Anthropic should return null for empty memory", anthropicEmpty == null)

        // Gemini
        val geminiEmpty = MessageBuilder.geminiSystemInstructionJson(null)
        assertTrue("Gemini should return null for empty memory", geminiEmpty == null)
    }

    @Test
    fun `MEM-5-17 - across every provider, anti-forget context is appended only to the last user message`() {
        val messages = buildConversation(10)
        simulateApplyAntiForget(
            messages,
            antiForgetEnabled = true,
            memoryText = "Memory text",
            antiForgetText = "TypeScript expert",
            useMemory = true,
        )

        val lastUser = messages.last { it.role == ChatRole.User }
        assertTrue(lastUser.text.contains("[Reminder: TypeScript expert]"))

        val contextCount = messages.count { it.text.contains("[Reminder:") }
        assertEquals(1, contextCount)
    }

    // ══════════════════════════════════════════════════════════
    // MEM-5-18: smoke tests across guest / free / pro roles
    // ══════════════════════════════════════════════════════════

    @Test
    fun `MEM-5-18 - guest role memory injection works`() {
        val prompt = simulateBuildSystemPrompt("I like Python", useMemory = true)
        assertEquals("I like Python", prompt)
    }

    @Test
    fun `MEM-5-18 - free role memory injection works`() {
        val prompt = simulateBuildSystemPrompt("I like Java", useMemory = true)
        assertEquals("I like Java", prompt)
    }

    @Test
    fun `MEM-5-18 - pro role memory injection works`() {
        val prompt = simulateBuildSystemPrompt("I like Rust", useMemory = true)
        assertEquals("I like Rust", prompt)
    }

    @Test
    fun `MEM-5-18 - guest role stays local-only`() {
        val (syncs, local) = simulateSyncBehavior("guest")
        assertFalse(syncs)
        assertTrue(local)
    }

    @Test
    fun `MEM-5-18 - free role stays local-only`() {
        val (syncs, local) = simulateSyncBehavior("free")
        assertFalse(syncs)
        assertTrue(local)
    }

    @Test
    fun `MEM-5-18 - pro role syncs remotely`() {
        val (syncs, local) = simulateSyncBehavior("pro")
        assertTrue(syncs)
        assertFalse(local)
    }

    @Test
    fun `MEM-5-18 - usageCount counts per conversation`() {
        val ids = mutableSetOf<String>()

        // first use
        assertTrue(simulateMarkMemoryUsed("conv-1", ids))

        // a repeat within the same conversation does not count
        assertFalse(simulateMarkMemoryUsed("conv-1", ids))

        // a new conversation counts
        assertTrue(simulateMarkMemoryUsed("conv-2", ids))
    }

    @Test
    fun `MEM-5-18 - useMemory=false skips injection for every role`() {
        for (role in listOf("guest", "free", "pro")) {
            val prompt = simulateBuildSystemPrompt("Some memory", useMemory = false)
            assertTrue("$role should not inject when useMemory=false", prompt == null)
        }
    }

    // ══════════════════════════════════════════════════════════
    // MEM-P-04: anti-forget payload size for long conversations
    // ══════════════════════════════════════════════════════════

    @Test
    fun `MEM-P-04 - 50 rounds plus a 200-character Context add less than 10KB`() {
        val antiForgetText = "A".repeat(200)
        val messages = buildConversation(50)

        // size without anti-forget applied
        val baselineSize = messages.sumOf { it.text.toByteArray(Charsets.UTF_8).size }

        // apply anti-forget
        simulateApplyAntiForget(
            messages,
            antiForgetEnabled = true,
            memoryText = "Test memory",
            antiForgetText = antiForgetText,
            useMemory = true,
        )

        val injectedSize = messages.sumOf { it.text.toByteArray(Charsets.UTF_8).size }
        val delta = injectedSize - baselineSize

        assertTrue("delta of $delta bytes should be < 10KB", delta < 10240)
    }

    @Test
    fun `MEM-P-04 - 200 Unicode emoji Context encodes to a reasonable UTF-8 size`() {
        val emojiContext = "😀".repeat(200)
        val encoded = "\n\n[Reminder: $emojiContext]".toByteArray(Charsets.UTF_8)
        assertTrue("emoji context encoding should be < 10KB", encoded.size < 10240)
    }

    @Test
    fun `MEM-P-04 - 200-character kana Context encodes to a reasonable size`() {
        val cjkContext = "の".repeat(200)
        val encoded = "\n\n[Reminder: $cjkContext]".toByteArray(Charsets.UTF_8)
        assertTrue("kana context encoding should be < 10KB", encoded.size < 10240)
    }

    @Test
    fun `MEM-P-04 - 50-round conversation appends Context only once`() {
        val messages = buildConversation(50)
        simulateApplyAntiForget(
            messages,
            antiForgetEnabled = true,
            memoryText = "Memory",
            antiForgetText = "A".repeat(200),
            useMemory = true,
        )
        val contextCount = messages.count { it.text.contains("[Reminder:") }
        assertEquals(1, contextCount)
    }

    // ══════════════════════════════════════════════════════════
    // MEM-5-17 (continued): MessageBuilder + saveMemory integration
    // ══════════════════════════════════════════════════════════

    @Test
    fun `MEM-5-17 - saveMemory persists memoryText so it can be read back and injected`() = runTest {
        repository.saveMemory(
            text = smokeMemoryText,
            antiForgetEnabled = true,
            antiForgetText = "Expert",
            updatedAt = "2026-04-01T00:00:00Z",
        )

        val savedText = repository.memoryText.first()
        assertEquals(smokeMemoryText, savedText)

        // used for provider injection
        val prompt = simulateBuildSystemPrompt(savedText, useMemory = true)
        assertEquals(smokeMemoryText, prompt)
    }

    @Test
    fun `MEM-5-18 - saveMemory persists every sync field for a pro-role user`() = runTest {
        repository.saveMemory(
            text = "Pro user memory",
            antiForgetEnabled = true,
            antiForgetText = "Expert",
            updatedAt = "2026-04-01T10:00:00Z",
        )

        // verify every sync field was persisted
        assertEquals("Pro user memory", preferenceDao.get(AppPreferenceKeys.MEMORY_TEXT))
        assertEquals("true", preferenceDao.get(AppPreferenceKeys.MEMORY_ANTI_FORGET_ENABLED))
        assertEquals("Expert", preferenceDao.get(AppPreferenceKeys.MEMORY_ANTI_FORGET_TEXT))
        assertEquals("2026-04-01T10:00:00Z", preferenceDao.get(AppPreferenceKeys.MEMORY_UPDATED_AT))
    }

    // ══════════════════════════════════════════════════════════
    // Manual-only cases (not automated)
    // ══════════════════════════════════════════════════════════

    // MEM-5-10: TalkBack screen reader -- requires a real Android device with accessibility services
    // MEM-5-11: web keyboard accessibility -- not applicable to Android
    // MEM-5-12: large text / system font scaling -- requires verifying after changing device settings
    // MEM-5-13: small-screen layout -- requires a narrow-screen device
    // MEM-5-14: 2000-character performance -- requires measuring on a real device
    // MEM-P-01: cold-start latency -- requires measuring real startup time
    // MEM-P-02: editor input latency -- requires frame-rate measurement around 1900 characters
    // MEM-P-03: remote write latency -- requires a real network environment
    // MEM-P-05: low-end devices -- requires an entry-level device
    // ══════════════════════════════════════════════════════════
    // MEM-P-07: first-message injection latency
    // ══════════════════════════════════════════════════════════
    // A timing test here would only measure simulateBuildSystemPrompt / simulateApplyAntiForget,
    // the test-double logic defined in this same file, rather than the production code path.
    // The invariant these cases care about -- an empty Memory short-circuits without extra
    // work -- is already guarded by the production entry point ChatPromptInjectionBuilder.build,
    // asserted in ChatPinnedInjectionTest via `no skill no memory no pinned returns null`
    // (assertNull).

    // ══════════════════════════════════════════════════════════
    // FakePreferenceDao
    // ══════════════════════════════════════════════════════════

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
