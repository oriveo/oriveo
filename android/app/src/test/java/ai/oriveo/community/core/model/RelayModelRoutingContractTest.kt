package ai.oriveo.community.core.model

import ai.oriveo.community.core.data.entity.ProviderEntity
import ai.oriveo.community.core.data.mapper.ProviderMapper
import ai.oriveo.community.core.provider.RelayEndpointResolver
import kotlinx.serialization.ExperimentalSerializationApi
import kotlinx.serialization.descriptors.elementNames
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.nio.file.Files
import java.nio.file.Paths

/**
 * Cross-platform contract for Relay 2.0 model-level fields and the single resolver function (`shared/test-fixtures/relay/portable-config.v1.json`
 * `modelFields` / `modelCases` / `resolveCases`).
 *
 * All decoding and encoding go through the production on-device storage path [ProviderMapper] (the Room JSON columns use its Json instance),
 * final objects are not hand-built.
 */
class RelayModelRoutingContractTest {
    private val fixture: JsonObject by lazy {
        var dir = Paths.get("").toAbsolutePath()
        repeat(8) {
            val candidate = dir.resolve("shared/test-fixtures/relay/portable-config.v1.json")
            if (Files.exists(candidate)) {
                return@lazy Json.parseToJsonElement(
                    String(Files.readAllBytes(candidate), Charsets.UTF_8),
                ).jsonObject
            }
            dir = dir.parent ?: return@repeat
        }
        throw IllegalStateException("portable-config.v1.json not found")
    }

    private val modelFields: JsonObject get() = fixture.getValue("modelFields").jsonObject

    private fun JsonObject.strings(key: String): List<String> =
        getValue(key).jsonArray.map { it.jsonPrimitive.content }

    private fun JsonObject.cases(key: String): List<JsonObject> =
        getValue(key).jsonArray.map { it.jsonObject }

    private val relayModelKeys: Set<String> get() = modelFields.strings("all").toSet()

    private fun baselineEntity(): ProviderEntity = with(ProviderMapper) {
        Provider(
            id = "11111111-1111-4111-8111-111111111111",
            kind = ProviderKind.Relay,
            baseUrlText = "https://relay.example.com",
            models = listOf(AIModel(id = "model-a", name = "Model A")),
        ).toEntity()
    }

    /** Overlay the Relay 2.0 keys from the fixture onto the baseline model JSON produced by the production encoder, then read it back as a Provider through the production decoder. */
    private fun decodeProvider(
        modelOverlay: JsonObject,
        baseURL: String? = null,
        relayRequested: JsonObject? = null,
    ): Provider {
        val entity = baselineEntity()
        val baseline = Json.parseToJsonElement(entity.modelsJson).jsonArray.single().jsonObject
        val overlaid = JsonObject(baseline + modelOverlay.filterKeys { !it.startsWith("$") })
        return with(ProviderMapper) {
            entity.copy(
                modelsJson = JsonArray(listOf(overlaid)).toString(),
                baseUrlText = baseURL ?: entity.baseUrlText,
                relayRequestedJson = relayRequested?.toString(),
            ).toDomain()
        }
    }

    /** The Relay 2.0 keys in the model JSON after the production encoder writes back to on-device storage. */
    private fun storedRelayModelFields(provider: Provider): List<JsonObject> {
        val stored = with(ProviderMapper) { provider.toEntity() }.modelsJson
        return Json.parseToJsonElement(stored).jsonArray.map { element ->
            JsonObject(element.jsonObject.filterKeys { it in relayModelKeys })
        }
    }

    @OptIn(ExperimentalSerializationApi::class)
    @Test
    fun `RL2-DATA-01 model fields are registered and every modelCase round-trips through local storage`() {
        assertEquals(1, fixture.getValue("version").jsonPrimitive.content.toInt())
        assertEquals(modelFields.strings("all").toSet(), RELAY_MODEL_FIELDS)
        assertEquals(modelFields.strings("portable").toSet(), PORTABLE_RELAY_MODEL_FIELDS)
        assertEquals(modelFields.strings("localOnly").toSet(), LOCAL_ONLY_RELAY_MODEL_FIELDS)
        assertTrue(
            "AIModel must really declare these fields",
            AIModel.serializer().descriptor.elementNames.toSet().containsAll(RELAY_MODEL_FIELDS),
        )
        assertEquals(modelFields.strings("transportSources"), RelayTransportSource.entries.map { it.value })
        assertEquals(modelFields.strings("capabilityOverrideKeys"), RelayCapabilityOverrides.KEYS)
        assertEquals(modelFields.strings("capabilityOverrideSources"), RelayCapabilityOverrides.SOURCES)
        assertEquals(modelFields.strings("engineDeclarationKeys"), EngineDeclaration.KEYS)
        assertEquals(
            fixture.strings("allFields").toSortedSet(),
            RelayRequestedConfig.serializer().descriptor.elementNames.toSortedSet(),
        )
        assertEquals(fixture.strings("portableFields").toSortedSet(), PORTABLE_RELAY_REQUESTED_FIELDS.toSortedSet())

        val cases = fixture.cases("modelCases")
        assertEquals(13, cases.size)
        for (case in cases) {
            val caseId = case.getValue("caseId").jsonPrimitive.content
            val expect = case.getValue("expect").jsonObject
            val provider = decodeProvider(case.getValue("model").jsonObject)
            val model = provider.models.single()

            assertEquals("$caseId: relayTransport", expect["relayTransport"]?.jsonPrimitive?.content, model.relayTransport?.value)
            assertEquals(
                "$caseId: relayTransportSource",
                expect["relayTransportSource"]?.jsonPrimitive?.content,
                model.relayTransportSource?.value,
            )
            assertEquals(
                "$caseId: relayCapabilityOverrides existence",
                expect.containsKey("relayCapabilityOverrides"),
                model.relayCapabilityOverrides != null,
            )
            assertEquals(
                "$caseId: engineDeclaration existence",
                expect.containsKey("engineDeclaration"),
                model.engineDeclaration != null,
            )
            assertEquals("$caseId: keys written back to on-device storage", expect, storedRelayModelFields(provider).single())
        }
    }

    /**
     * The `model` of resolveCases is an **in-memory input** of the resolver, giving a protocol without a source; it is not a persisted JSON
     * (persisted decoding drops a protocol without a source, which is what modelCases covers). So the connection config goes through the production decoder,
     * and the model-level protocol is set directly on the decoded model.
     */
    private fun resolveProvider(case: JsonObject): Provider {
        val provider = case.getValue("provider").jsonObject
        val decoded = decodeProvider(
            modelOverlay = JsonObject(emptyMap()),
            baseURL = provider.getValue("baseURL").jsonPrimitive.content,
            relayRequested = provider["relayRequested"]?.jsonObject,
        )
        val modelTransport = case.getValue("model").jsonObject["relayTransport"]?.jsonPrimitive?.content
            ?: return decoded
        return decoded.copy(
            models = decoded.models.map { model ->
                model.copy(relayTransport = RelayTransport.entries.single { it.value == modelTransport })
            },
        )
    }

    @Test
    fun `RL2-RESOLVE-01 effectiveTransport matches every resolveCase`() {
        val cases = fixture.cases("resolveCases")
        assertEquals(13, cases.size)
        for (case in cases) {
            val caseId = case.getValue("caseId").jsonPrimitive.content
            val provider = resolveProvider(case)
            assertEquals(
                caseId,
                case.getValue("expect").jsonObject.getValue("effectiveTransport").jsonPrimitive.content,
                RelayEndpointResolver.effectiveTransport(provider, provider.models.single()).value,
            )
        }
    }

    @Test
    fun `RL2-RESOLVE-02 effectiveAPIRoot matches every resolveCase`() {
        val cases = fixture.cases("resolveCases")
        assertEquals(13, cases.size)
        for (case in cases) {
            val caseId = case.getValue("caseId").jsonPrimitive.content
            val provider = resolveProvider(case)
            assertEquals(
                caseId,
                case.getValue("expect").jsonObject.getValue("effectiveAPIRoot").jsonPrimitive.content,
                RelayEndpointResolver.effectiveAPIRoot(provider, provider.models.single()),
            )
        }
    }

    @Test
    fun `RL2-MIGRATE-02 relay model fields stay on device and never reach Firestore`() {
        fun case(id: String) = fixture.cases("modelCases").first { it.getValue("caseId").jsonPrimitive.content == id }
        val three = case("all_three_fields_round_trip")
        val engine = case("engine_declaration_round_trips")
        // The four device-only fields are overlaid on the same model, and one assertion checks none of them goes to the cloud.
        val full = JsonObject(
            mapOf(
                "model" to JsonObject(three.getValue("model").jsonObject + engine.getValue("model").jsonObject),
                "expect" to JsonObject(three.getValue("expect").jsonObject + engine.getValue("expect").jsonObject),
            ),
        )
        val decoded = decodeProvider(full.getValue("model").jsonObject)
        val provider = decoded.copy(models = decoded.models + AIModel(id = "model-b", name = "Model B"))
        val carrier = provider.models.first()
        // First confirm the subject really carries the four fields, otherwise the "cloud has none of these keys" check below is vacuous.
        assertNotNull(carrier.relayTransport)
        assertNotNull(carrier.relayTransportSource)
        assertNotNull(carrier.relayCapabilityOverrides)
        assertNotNull(carrier.engineDeclaration)


        val restored = with(ProviderMapper) { provider.toEntity().toDomain() }
        assertEquals(carrier.relayTransport, restored.models.first().relayTransport)
        assertEquals(carrier.relayTransportSource, restored.models.first().relayTransportSource)
        assertEquals(carrier.relayCapabilityOverrides, restored.models.first().relayCapabilityOverrides)
        assertEquals(carrier.engineDeclaration, restored.models.first().engineDeclaration)
        val stored = storedRelayModelFields(restored)
        assertEquals(full.getValue("expect").jsonObject, stored.first())
        assertEquals(JsonObject(emptyMap()), stored.last())
    }

    /**
     * Three multi-key fields: production decoding drops badly shaped fields one by one without breaking the whole model, on-device storage round-trips them unchanged, and the production Firestore write omits them.
     */
    @Test
    fun `RL2-DATA-03 multi-key model fields decode leniently and never reach Firestore`() {
        val good = decodeProvider(
            Json.parseToJsonElement(
                """{"relayKeyID":"k-b","relayListedByKeyIDs":["initial","k-b"],"relayDeniedKeyID":"initial"}""",
            ).jsonObject,
        )
        val model = good.models.single()
        assertEquals("k-b", model.relayKeyID)
        assertEquals(listOf("initial", "k-b"), model.relayListedByKeyIDs)
        assertEquals("initial", model.relayDeniedKeyID)
        assertEquals(
            Json.parseToJsonElement(
                """{"relayKeyID":"k-b","relayListedByKeyIDs":["initial","k-b"],"relayDeniedKeyID":"initial"}""",
            ).jsonObject,
            storedRelayModelFields(good).single(),
        )

        val bad = decodeProvider(
            Json.parseToJsonElement("""{"relayKeyID":7,"relayListedByKeyIDs":["initial",3],"relayDeniedKeyID":{"x":1}}""").jsonObject,
        ).models.single()
        assertEquals("model-a", bad.id)
        assertEquals(null, bad.relayKeyID)
        assertEquals(null, bad.relayListedByKeyIDs)
        assertEquals(null, bad.relayDeniedKeyID)

    }
}
