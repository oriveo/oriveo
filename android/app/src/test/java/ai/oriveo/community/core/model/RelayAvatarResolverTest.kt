package ai.oriveo.community.core.model

import java.io.File
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Relay avatar: the fixture `shared/test-fixtures/relay/relay-avatar.v1.json` drives production
 * [RelayAvatarResolver.resolve] per caseId; the brand table matches the fixture entry by entry; five surfaces go through the same function (BOARD-AVATAR-01).
 */
class RelayAvatarResolverTest {

    private val fixture: JsonObject = Json.parseToJsonElement(
        generateSequence(File(System.getProperty("user.dir") ?: ".").absoluteFile) { it.parentFile }
            .map { File(it, "shared/test-fixtures/relay/relay-avatar.v1.json") }
            .first { it.isFile }
            .readText(Charsets.UTF_8),
    ).jsonObject

    private fun case(id: String): JsonObject =
        fixture.getValue("cases").jsonArray.map { it.jsonObject }.single { it.getValue("id").jsonPrimitive.content == id }

    private fun assertCase(id: String) {
        val c = case(id)
        val name = c.getValue("name").jsonPrimitive.content
        val url = c.getValue("url").jsonPrimitive.content
        val expected = c.getValue("expected").jsonObject
        // The models in the fixture only prove the model id does not take part: the production function does not even accept a model.
        val actual = RelayAvatarResolver.resolve(name, url)
        when (expected.getValue("kind").jsonPrimitive.content) {
            "brand" -> assertEquals(id, expected.getValue("brand").jsonPrimitive.content, (actual as RelayAvatarResult.Brand).id)
            "initial" -> assertEquals(id, RelayAvatarResult.Initial(expected.getValue("text").jsonPrimitive.content), actual)
            "generic" -> assertEquals(id, RelayAvatarResult.Generic, actual)
            else -> error("unknown kind in $id")
        }
    }

    @Test fun `RD3-AVATAR-openrouter_by_host`() = assertCase("openrouter_by_host")
    @Test fun `RD3-AVATAR-openrouter_by_name`() = assertCase("openrouter_by_name")
    @Test fun `RD3-AVATAR-siliconflow_by_host`() = assertCase("siliconflow_by_host")
    @Test fun `RD3-AVATAR-together_by_host`() = assertCase("together_by_host")
    @Test fun `RD3-AVATAR-groq_by_host`() = assertCase("groq_by_host")
    @Test fun `RD3-AVATAR-initial_latin`() = assertCase("initial_latin")
    @Test fun `RD3-AVATAR-initial_lowercase`() = assertCase("initial_lowercase")
    @Test fun `RD3-AVATAR-initial_cjk`() = assertCase("initial_cjk")
    @Test fun `RD3-AVATAR-initial_skips_symbols`() = assertCase("initial_skips_symbols")
    @Test fun `RD3-AVATAR-model_ids_ignored`() = assertCase("model_ids_ignored")
    @Test fun `RD3-AVATAR-together_word_not_brand`() = assertCase("together_word_not_brand")
    @Test fun `RD3-AVATAR-oriveo_excluded`() = assertCase("oriveo_excluded")
    @Test fun `RD3-AVATAR-empty_name_uses_host`() = assertCase("empty_name_uses_host")
    @Test fun `RD3-AVATAR-nothing_usable`() = assertCase("nothing_usable")

    @Test
    fun `RD3-AVATAR fixture cases are all covered by this class`() {
        val ids = fixture.getValue("cases").jsonArray.map { it.jsonObject.getValue("id").jsonPrimitive.content }
        val covered = RelayAvatarResolverTest::class.java.declaredMethods.map { it.name }
            .filter { it.startsWith("RD3-AVATAR-") }
            .map { it.removePrefix("RD3-AVATAR-") }
            .toSet()
        assertEquals(ids.toSet(), covered)
    }

    @Test
    fun `RD3-AVATAR brand table matches the fixture`() {
        val brands = fixture.getValue("brands").jsonArray.map { it.jsonObject }
        assertEquals(
            brands.map { it.getValue("id").jsonPrimitive.content to it.getValue("keywords").jsonArray.map { k -> k.jsonPrimitive.content } },
            RelayAvatarResolver.BRANDS.map { it.id to it.keywords },
        )
        assertEquals(
            fixture.getValue("excludeKeywords").jsonArray.map { it.jsonPrimitive.content },
            RelayAvatarResolver.EXCLUDE_KEYWORDS,
        )
        // Brands always resolve to existing official brand resources (no backplate); no new resources.
        assertEquals(
            listOf(ProviderKind.OpenRouter, ProviderKind.SiliconFlow, ProviderKind.Together, ProviderKind.Fireworks, ProviderKind.Groq),
            RelayAvatarResolver.BRANDS.map { it.kind },
        )
    }

    @Test
    fun `RD3-AVATAR provider overload uses the custom name and base url and skips local connections`() {
        val relay = Provider(
            id = "r",
            kind = ProviderKind.Relay,
            customName = "",
            baseUrlText = "https://api.myrelay.dev/v1",
            relayKind = RelayKind.AnthropicCompatible,
            models = listOf(AIModel(id = "claude-sonnet-4-5", name = "Claude Sonnet 4.5")),
        )
        assertTrue(RelayAvatarResolver.appliesTo(relay))
        // When the name is empty use the host, not the "Relay (host)" display name as a fallback, and do not look at relayKind / model id either.
        assertEquals(RelayAvatarResult.Initial("M"), RelayAvatarResolver.resolve(relay.customName.orEmpty(), relay.baseUrlText.orEmpty()))
        // The connection-level entry point adds the icon layer (relay-avatar-icon.v1.json): without a brand match it draws the default icon by connection id.
        assertTrue(RelayAvatarResolver.resolve(relay, choice = null) is RelayAvatarResult.Icon)
        val local = relay.copy(relayRequested = RelayRequestedConfig(engineProfile = "ollama"))
        assertTrue("a local connection does not use this function", !RelayAvatarResolver.appliesTo(local))
        assertTrue("an official provider does not use this function", !RelayAvatarResolver.appliesTo(Provider(id = "o", kind = ProviderKind.OpenAI)))
    }

    /** BOARD-AVATAR-01: all five surfaces draw the same Composable, which obtains its result only through the same resolver function. */
    @Test
    fun `BOARD-AVATAR-01 five surfaces draw the same resolver result`() {
        val avatarSource = source("core/model/RelayAvatar.kt")
        assertTrue("the Composable obtains its result only through the resolver function", "RelayAvatarResolver.resolve(provider, choice)" in avatarSource)
        mapOf(
            "feature/modelpicker/ModelPickerSheet.kt" to "model picker group header",
            "feature/chat/components/ChatToolbar.kt" to "chat top bar",
            "feature/chat/components/MessageBubble.kt" to "message header",
            "feature/providers/detail/RelayDetailBoardView.kt" to "detail header",
            "ui/component/ProviderListCard.kt" to "provider list",
        ).forEach { (file, surface) ->
            val text = source(file)
            assertTrue("$surface must draw RelayAvatar", "RelayAvatar(" in text)
            assertTrue("$surface must use the same criterion to decide whether to show the avatar", "RelayAvatarResolver.appliesTo(" in text)
        }
        val provider = Provider(id = "r", kind = ProviderKind.Relay, customName = "OpenRouter \u5907\u7528", baseUrlText = "https://proxy.example.com/v1")
        val results = List(5) { RelayAvatarResolver.resolve(provider) }
        assertEquals(1, results.toSet().size)
        assertEquals("openrouter", (results.first() as RelayAvatarResult.Brand).id)
    }

    private fun source(relative: String): String {
        val direct = File("src/main/java/ai/oriveo/community/$relative")
        if (direct.exists()) return direct.readText()
        return File("app/src/main/java/ai/oriveo/community/$relative").readText()
    }
}
