package ai.oriveo.community.core.model

import ai.oriveo.community.R
import java.io.File
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Before
import org.junit.Test

/**
 * Default relay avatar icon layer: fixture `shared/test-fixtures/relay/relay-avatar-icon.v1.json` drives the production
 * [RelayAvatarResolver.resolve] (four inputs: providerId / name / url / choice) and [RelayAvatarResolver.pickerCells] case by case;
 * the choice store [RelayAvatarChoiceStore] uses an in-memory persistence double. The base layer (relay-avatar.v1.json) is pinned by [RelayAvatarResolverTest].
 */
class RelayAvatarIconTest {

    private val fixture: JsonObject = Json.parseToJsonElement(
        generateSequence(File(System.getProperty("user.dir") ?: ".").absoluteFile) { it.parentFile }
            .map { File(it, "shared/test-fixtures/relay/relay-avatar-icon.v1.json") }
            .first { it.isFile }
            .readText(Charsets.UTF_8),
    ).jsonObject

    private val persisted = mutableMapOf<String, String>()

    @Before fun setUp() {
        persisted.clear()
        RelayAvatarChoiceStore.configurePersistenceForTesting(emptyMap()) { key, value ->
            if (value == null) persisted.remove(key) else persisted[key] = value
        }
    }

    @After fun tearDown() = RelayAvatarChoiceStore.resetForTesting()

    private fun section(name: String, id: String): JsonObject =
        fixture.getValue(name).jsonArray.map { it.jsonObject }.single { it.getValue("id").jsonPrimitive.content == id }

    private fun JsonObject.text(key: String): String = getValue(key).jsonPrimitive.content

    private fun assertCase(id: String) {
        val c = section("cases", id)
        val providerId = c.text("providerId")
        c["hash"]?.let { hash ->
            val actual = "0x%08x".format(RelayAvatarResolver.fnv1a32(RelayAvatarResolver.choiceKey(providerId)))
            assertEquals("$id hash", hash.jsonPrimitive.content, actual)
        }
        val actual = RelayAvatarResolver.resolve(providerId, c.text("name"), c.text("url"), c["choice"]?.jsonPrimitive?.content)
        val expected = c.getValue("expected").jsonObject
        when (expected.text("kind")) {
            "icon" -> assertEquals(id, expected.text("icon"), (actual as RelayAvatarResult.Icon).icon.id)
            "brand" -> assertEquals(id, expected.text("brand"), (actual as RelayAvatarResult.Brand).id)
            "initial" -> assertEquals(id, RelayAvatarResult.Initial(expected.text("text")), actual)
            "generic" -> assertEquals(id, RelayAvatarResult.Generic, actual)
            else -> error("unknown kind in $id")
        }
    }

    private fun assertPicker(id: String) {
        val c = section("pickerCases", id)
        assertEquals(
            id,
            c.getValue("cells").jsonArray.map { it.jsonPrimitive.content },
            RelayAvatarResolver.pickerCells(c.text("name"), c.text("url")).map { it.token },
        )
    }

    @Test fun `RELAY-AVATAR-ICON-default_uuid_upper`() = assertCase("default_uuid_upper")
    @Test fun `RELAY-AVATAR-ICON-default_uuid_lower_same`() = assertCase("default_uuid_lower_same")
    @Test fun `RELAY-AVATAR-ICON-default_trims_ascii_space`() = assertCase("default_trims_ascii_space")
    @Test fun `RELAY-AVATAR-ICON-default_relay_1`() = assertCase("default_relay_1")
    @Test fun `RELAY-AVATAR-ICON-default_relay_4`() = assertCase("default_relay_4")
    @Test fun `RELAY-AVATAR-ICON-default_relay_10`() = assertCase("default_relay_10")
    @Test fun `RELAY-AVATAR-ICON-default_non_ascii_id`() = assertCase("default_non_ascii_id")
    @Test fun `RELAY-AVATAR-ICON-default_when_base_generic`() = assertCase("default_when_base_generic")
    @Test fun `RELAY-AVATAR-ICON-brand_beats_default`() = assertCase("brand_beats_default")
    @Test fun `RELAY-AVATAR-ICON-choice_icon_beats_brand`() = assertCase("choice_icon_beats_brand")
    @Test fun `RELAY-AVATAR-ICON-choice_icon_beats_default`() = assertCase("choice_icon_beats_default")
    @Test fun `RELAY-AVATAR-ICON-choice_letter`() = assertCase("choice_letter")
    @Test fun `RELAY-AVATAR-ICON-choice_letter_beats_brand`() = assertCase("choice_letter_beats_brand")
    @Test fun `RELAY-AVATAR-ICON-choice_letter_without_initial`() = assertCase("choice_letter_without_initial")
    @Test fun `RELAY-AVATAR-ICON-unknown_choice_ignored`() = assertCase("unknown_choice_ignored")
    @Test fun `RELAY-AVATAR-ICON-brand_value_not_a_choice`() = assertCase("brand_value_not_a_choice")
    @Test fun `RELAY-AVATAR-ICON-empty_id_keeps_base`() = assertCase("empty_id_keeps_base")
    @Test fun `RELAY-AVATAR-ICON-empty_id_keeps_base_generic`() = assertCase("empty_id_keeps_base_generic")

    @Test fun `RELAY-AVATAR-PICKER-picker_with_brand`() = assertPicker("picker_with_brand")
    @Test fun `RELAY-AVATAR-PICKER-picker_no_brand`() = assertPicker("picker_no_brand")
    @Test fun `RELAY-AVATAR-PICKER-picker_no_letter`() = assertPicker("picker_no_letter")

    @Test
    fun `RELAY-AVATAR-ICON fixture cases and picker cases are all covered by this class`() {
        val methods = RelayAvatarIconTest::class.java.declaredMethods.map { it.name }
        listOf("cases" to "RELAY-AVATAR-ICON-", "pickerCases" to "RELAY-AVATAR-PICKER-").forEach { (name, prefix) ->
            val ids = fixture.getValue(name).jsonArray.map { it.jsonObject.text("id") }.toSet()
            assertEquals(name, ids, methods.filter { it.startsWith(prefix) }.map { it.removePrefix(prefix) }.toSet())
        }
    }

    @Test
    fun `RELAY-AVATAR-GLYPH-01 icon table matches the fixture order, original drawables and palette tokens`() {
        val icons = fixture.getValue("icons").jsonArray.map { it.jsonObject }
        assertEquals(
            icons.map { it.text("id") to it.text("palette") },
            RelayAvatarIcon.entries.map { it.id to it.palette },
        )
        RelayAvatarIcon.entries.forEach { icon ->
            // Every id resolves to its original icon resource, and the enum references exactly that resource.
            val name = "relay_avatar_${icon.id.replace('-', '_')}"
            assertEquals(name, R.drawable::class.java.getField(name).getInt(null), icon.drawable)
            val label = "relay_avatar_icon_${icon.id.replace('-', '_')}"
            assertEquals(label, R.string::class.java.getField(label).getInt(null), icon.labelRes)
        }
        assertEquals(fixture.text("letterChoice"), RelayAvatarChoiceStore.LETTER)
    }

    @Test
    fun `RELAY-AVATAR-STORE-01 picking an icon makes the same connection resolve to it`() {
        val relay = Provider(id = "relay-1", kind = ProviderKind.Relay, customName = "Relay one", baseUrlText = "https://r1.example.com")
        assertEquals(RelayAvatarResult.Icon(RelayAvatarIcon.RelayBell), RelayAvatarResolver.resolve(relay))
        val kite = RelayAvatarResolver.pickerCells(relay.customName.orEmpty(), relay.baseUrlText.orEmpty())
            .single { it.token == "kite" }
        RelayAvatarChoiceStore.select(relay.id, kite.choice)
        assertEquals(RelayAvatarResult.Icon(RelayAvatarIcon.Kite), RelayAvatarResolver.resolve(relay))
        // The same id with different case / surrounding whitespace reads the same choice; the unified entry point follows too.
        assertEquals("kite", RelayAvatarChoiceStore.choices.value[RelayAvatarResolver.choiceKey(" RELAY-1 ")])
        assertEquals(
            ConnectionAvatarSpec.Relay(RelayAvatarResult.Icon(RelayAvatarIcon.Kite)),
            ConnectionAvatarSpec.of(relay, ProviderKind.Relay),
        )
        assertEquals(mapOf("relay-1" to "kite"), persisted)

        val letter = RelayAvatarResolver.pickerCells(relay.customName.orEmpty(), relay.baseUrlText.orEmpty()).last()
        RelayAvatarChoiceStore.select(relay.id, letter.choice)
        assertEquals(RelayAvatarResult.Initial("R"), RelayAvatarResolver.resolve(relay))
        assertEquals(mapOf("relay-1" to "letter"), persisted)
    }

    @Test
    fun `RELAY-AVATAR-STORE-02 picking the brand cell deletes the stored choice`() {
        val relay = Provider(id = "relay-2", kind = ProviderKind.Relay, customName = "My backup", baseUrlText = "https://openrouter.ai/api/v1")
        RelayAvatarChoiceStore.select(relay.id, "kite")
        assertEquals(RelayAvatarResult.Icon(RelayAvatarIcon.Kite), RelayAvatarResolver.resolve(relay))
        val brand = RelayAvatarResolver.pickerCells(relay.customName.orEmpty(), relay.baseUrlText.orEmpty()).first()
        assertEquals("brand:openrouter", brand.token)
        assertNull(brand.choice)
        RelayAvatarChoiceStore.select(relay.id, brand.choice)
        assertNull(RelayAvatarChoiceStore.choice(relay.id))
        assertEquals(emptyMap<String, String>(), persisted)
        assertEquals("openrouter", (RelayAvatarResolver.resolve(relay) as RelayAvatarResult.Brand).id)
    }
}
