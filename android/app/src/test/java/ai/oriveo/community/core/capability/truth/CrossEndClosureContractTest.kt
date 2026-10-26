package ai.oriveo.community.core.capability.truth

import ai.oriveo.community.core.capability.InputNegativeCache
import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.data.remote.MetadataPayloadSchemaValidator
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.AttachmentSupportInfo
import ai.oriveo.community.core.model.LastUsedModelRef
import ai.oriveo.community.core.model.ModelCapability
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderAuthMode
import ai.oriveo.community.core.model.ProviderConnectionState
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.RelayRequestedConfig
import ai.oriveo.community.core.model.RelayTransport
import ai.oriveo.community.core.model.resolveActiveModel
import ai.oriveo.community.core.model.resolveNewChat
import ai.oriveo.community.core.provider.CapabilityEvidenceFacade
import ai.oriveo.community.core.provider.MetadataTestFixtures
import ai.oriveo.community.core.provider.relay.RelayNegativeCache
import java.io.File
import java.time.Instant
import java.util.zip.GZIPInputStream
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The shared fixture `shared/test-fixtures/capability/cross-end-closure.v1.json`, consumed case by case on Android
 * as `CLOSURE_<id>` tests; the fixture `$comment` is the authority for the rules:
 * - dateTimeCases: the production [MetadataPayloadSchemaValidator] accepts or rejects the envelope `generatedAt` (schema `format: date-time`);
 * - bundledInputCases: the verdict is published through the production decode / publish with the bundled-snapshot state on, and
 *   [resolveInputCapabilityProjections] projects it as decided, never downgrading unavailable / kill switch to unknown
 *   (this platform's input projection does not read the snapshot state, and the test turns the switch on to lock that in);
 * - newChatDefaultCases: the production [resolveActiveModel] picks the model for a new chat (last used, then catalog default,
 *   then the first available; retired or disabled models are never picked and the connection isDefault is not read);
 * - newChatAcrossConnectionsCases: the same resolver across connections (when the primary connection has nothing available
 *   it takes the next connection in order, and returns empty when none has anything);
 * - relayVideoEnvelopeCases: Relay input projection, where the envelope does not decide video and an absent envelope is not a rejection.
 */
class CrossEndClosureContractTest {
    private val now: Instant = Instant.parse("2026-10-20T00:00:00Z")
    private val cache = InputNegativeCache(InputNegativeCache.MemoryStore()) { now.epochSecond }
    private val relayCache = RelayNegativeCache(RelayNegativeCache.MemoryStore())
    private val fixture: JsonObject = Json.parseToJsonElement(
        workspaceFile("shared/test-fixtures/capability/cross-end-closure.v1.json").readText(),
    ).jsonObject

    @After
    fun tearDown() {
        MetadataTestFixtures.clear()
    }

    private fun cases(section: String): List<JsonObject> =
        fixture.getValue(section).jsonObject.getValue("cases").jsonArray.map { it.jsonObject }

    private fun case(section: String, id: String): JsonObject = cases(section).single { it.text("id") == id }

    private fun JsonObject.text(key: String): String? = this[key]?.takeUnless { it is JsonNull }?.jsonPrimitive?.content

    @Test
    fun `every fixture case naming android has exactly one CLOSURE test here`() {
        // Take the full set from the current fixture: every id in a section whose appliesTo contains android needs a CLOSURE_<id> test, and this class has no id the fixture lacks.
        val sections = fixture.filterValues { section ->
            ((section as? JsonObject)?.get("appliesTo") as? JsonArray)
                ?.any { it.jsonPrimitive.content == "android" } == true
        }.keys
        assertTrue(sections.toString(), sections.isNotEmpty())
        val fixtureIds = sections.flatMap { section -> cases(section).map { it.text("id")!! } }
        assertEquals("duplicate ids", fixtureIds.size, fixtureIds.toSet().size)
        val testIds = javaClass.declaredMethods.filter { it.isAnnotationPresent(Test::class.java) }
            .map { it.name }.filter { it.startsWith("CLOSURE_") }.map { it.removePrefix("CLOSURE_") }.toSet()
        assertEquals(fixtureIds.toSet(), testIds)
    }


    // ── dateTimeCases ──

    private val validator by lazy {
        MetadataPayloadSchemaValidator(
            Json.parseToJsonElement(workspaceFile("shared/model-contracts/metadata_payload.v2.schema.json").readText()),
        )
    }

    private val validEnvelope: JsonObject by lazy {
        Json.parseToJsonElement(workspaceFile("shared/model-contracts/metadata_payload.v2.cases.json").readText())
            .jsonObject.getValue("catalogCases").jsonArray.map { it.jsonObject }
            .single { it.text("name") == "valid_models_all_kept" }
            .getValue("data").jsonObject
    }

    private fun assertDateTimeCase(id: String) {
        val raw = case("dateTimeCases", id)
        val value = raw.text("value")!!
        assertNull("baseline envelope must be valid", validator.decode(validEnvelope).envelopeError)
        val error = validator.decode(JsonObject(validEnvelope + ("generatedAt" to JsonPrimitive(value)))).envelopeError
        if (raw.getValue("valid").jsonPrimitive.boolean) {
            assertNull("$id $value", error)
        } else {
            assertNotNull("$id $value", error)
        }
    }

    @Test fun CLOSURE_dt_utc_z() = assertDateTimeCase("dt_utc_z")
    @Test fun CLOSURE_dt_fraction_offset() = assertDateTimeCase("dt_fraction_offset")
    @Test fun CLOSURE_dt_lowercase_t_z() = assertDateTimeCase("dt_lowercase_t_z")
    @Test fun CLOSURE_dt_space_separator() = assertDateTimeCase("dt_space_separator")
    @Test fun CLOSURE_dt_offset_without_colon() = assertDateTimeCase("dt_offset_without_colon")
    @Test fun CLOSURE_dt_no_time_zone() = assertDateTimeCase("dt_no_time_zone")
    @Test fun CLOSURE_dt_hour_29() = assertDateTimeCase("dt_hour_29")
    @Test fun CLOSURE_dt_minute_60() = assertDateTimeCase("dt_minute_60")
    @Test fun CLOSURE_dt_offset_hour_24() = assertDateTimeCase("dt_offset_hour_24")
    @Test fun CLOSURE_dt_offset_minute_60() = assertDateTimeCase("dt_offset_minute_60")
    @Test fun CLOSURE_dt_feb_29_non_leap_year() = assertDateTimeCase("dt_feb_29_non_leap_year")
    @Test fun CLOSURE_dt_feb_29_leap_year() = assertDateTimeCase("dt_feb_29_leap_year")
    @Test fun CLOSURE_dt_month_13() = assertDateTimeCase("dt_month_13")
    @Test fun CLOSURE_dt_leap_second_utc_2359() = assertDateTimeCase("dt_leap_second_utc_2359")
    @Test fun CLOSURE_dt_leap_second_negative_offset_is_utc_2359() =
        assertDateTimeCase("dt_leap_second_negative_offset_is_utc_2359")
    @Test fun CLOSURE_dt_leap_second_positive_offset_not_utc_2359() =
        assertDateTimeCase("dt_leap_second_positive_offset_not_utc_2359")
    @Test fun CLOSURE_dt_leap_second_midday() = assertDateTimeCase("dt_leap_second_midday")
    @Test fun CLOSURE_dt_date_only() = assertDateTimeCase("dt_date_only")

    // ── bundledInputCases ──

    /** The deepseek entry of the bundled snapshot with the capabilityControls[key] of deepseek-flash replaced by the fixture verdict, published through the production decode / publish. */
    private fun bundledClient(key: String, verdict: JsonObject): MetadataClient {
        val providers = bundledPayload().getValue("providers").jsonObject
        val entry = providers.getValue("deepseek").jsonObject
        val models = entry.getValue("models").jsonObject
        val flash = models.getValue(BUNDLED_MODEL).jsonObject
        val controls = flash["capabilityControls"]?.jsonObject ?: JsonObject(emptyMap())
        val editedFlash = JsonObject(flash + ("capabilityControls" to JsonObject(controls + (key to verdict))))
        val payload = buildJsonObject {
            put("version", 1)
            put("contractVersion", 1)
            put("providers", buildJsonObject {
                put("deepseek", JsonObject(entry + ("models" to JsonObject(models + (BUNDLED_MODEL to editedFlash)))))
            })
        }
        return MetadataClient().apply {
            loadNetworkPayloadForTesting(payload.toString(), "\"closure-bundled\"")
            MetadataClient::class.java.getDeclaredField("bundledSnapshotActive")
                .apply { isAccessible = true }
                .setBoolean(this, true)
        }
    }

    private fun assertBundledInputCase(id: String) {
        val raw = case("bundledInputCases", id)
        assertEquals(id, "bundled", raw.text("catalogSource"))
        assertEquals(id, "official", raw.text("connection"))
        val key = raw.text("key")!!
        val client = bundledClient(key, raw.getValue("verdict").jsonObject)
        assertTrue(id, client.isBundledSnapshotActive)
        val projections = requireNotNull(
            resolveInputCapabilityProjections(
                provider = Provider(id = "official-deepseek", kind = ProviderKind.DeepSeek),
                model = AIModel(id = BUNDLED_MODEL, name = BUNDLED_MODEL),
                metadataClient = client,
                negativeCache = cache,
                now = now,
            ),
        )
        assertEquals(id, raw.getValue("expect").jsonObject, projections[key].toJson())
    }

    @Test fun CLOSURE_bundled_unavailable_model_absent_stays_disabled() =
        assertBundledInputCase("bundled_unavailable_model_absent_stays_disabled")
    @Test fun CLOSURE_bundled_kill_switch_stays_disabled() = assertBundledInputCase("bundled_kill_switch_stays_disabled")
    @Test fun CLOSURE_bundled_auto_available_visible() = assertBundledInputCase("bundled_auto_available_visible")
    @Test fun CLOSURE_bundled_unknown_hints_once() = assertBundledInputCase("bundled_unknown_hints_once")

    // ── newChatDefaultCases ──

    /** Writes the fixture catalog into the global MetadataClient (openAI only); among the enabled models the one named by connectionDefaultModelId is marked isDefault (this platform's model pick does not read it). */
    private fun assertNewChatDefaultCase(id: String) {
        val raw = case("newChatDefaultCases", id)
        val catalog = raw.getValue("catalog").jsonObject
        val catalogModels = catalog.getValue("models").jsonArray.map { it.jsonObject }
        MetadataTestFixtures.applyRaw(
            buildJsonObject {
                put("version", 1)
                put("contractVersion", 1)
                put("providers", buildJsonObject {
                    put("openAI", buildJsonObject {
                        catalog.text("defaultModelId")?.let { put("defaultModelId", it) }
                        put("retiredModels", catalog.getValue("retiredModels"))
                        put("resolveMap", catalog.getValue("resolveMap"))
                        put("models", buildJsonObject {
                            catalogModels.forEach { model ->
                                put(model.text("id")!!, buildJsonObject {
                                    put("canonicalModelId", model.text("id"))
                                    put("displayName", model.text("displayName"))
                                    model["lifecycle"]?.takeUnless { it is JsonNull }?.let { put("lifecycle", it) }
                                })
                            }
                        })
                    })
                })
            }.toString(),
        )
        val connectionDefault = raw.text("connectionDefaultModelId")
        val canonicalIds = raw["userModelCanonicalIds"]?.takeUnless { it is JsonNull }?.jsonObject
            ?.mapValues { it.value.jsonPrimitive.content }
            .orEmpty()
        val models = raw.getValue("userModels").jsonArray.map { element ->
            val modelId = element.jsonPrimitive.content
            AIModel(id = modelId, name = modelId, isDefault = modelId == connectionDefault, canonicalModelId = canonicalIds[modelId])
        }
        val provider = Provider(
            id = "provider-closure",
            kind = ProviderKind.OpenAI,
            status = ProviderConnectionState.Connected,
            models = models,
            catalogModels = models,
            apiKey = "sk-test",
            apiKeyPreview = "sk-...test",
        )
        val lastUsed = raw.text("lastUsedModelId")?.let { LastUsedModelRef(provider.id, it) }

        val resolution = resolveNewChat(listOf(provider), lastUsed, now = now)

        val expect = raw.getValue("expect").jsonObject
        assertEquals("$id modelId", expect.text("modelId"), resolution.selection?.model?.id)
        // When nothing is available no chat is opened (selection is empty), and the hint still comes with the result.
        assertEquals("$id hint", expect.text("hint"), resolution.hint?.wire)
        assertEquals("$id selection hint", resolution.selection?.let { expect.text("hint") }, resolution.selection?.hint?.wire)
        assertEquals("$id public resolver", resolution.selection, resolveActiveModel(listOf(provider), lastUsed, now = now))
    }

    @Test fun CLOSURE_last_used_available_beats_connection_default() =
        assertNewChatDefaultCase("last_used_available_beats_connection_default")
    @Test fun CLOSURE_connection_default_retired_falls_to_catalog_default() =
        assertNewChatDefaultCase("connection_default_retired_falls_to_catalog_default")
    @Test fun CLOSURE_connection_default_not_enabled_skipped() =
        assertNewChatDefaultCase("connection_default_not_enabled_skipped")
    @Test fun CLOSURE_all_enabled_retired_returns_none() =
        assertNewChatDefaultCase("all_enabled_retired_returns_none")
    @Test fun CLOSURE_last_used_retired_skips_connection_default() =
        assertNewChatDefaultCase("last_used_retired_skips_connection_default")
    @Test fun CLOSURE_no_last_used_ignores_connection_default() =
        assertNewChatDefaultCase("no_last_used_ignores_connection_default")
    @Test fun CLOSURE_enabled_model_missing_from_catalog_skipped() =
        assertNewChatDefaultCase("enabled_model_missing_from_catalog_skipped")
    @Test fun CLOSURE_last_used_retired_and_all_enabled_retired_returns_none() =
        assertNewChatDefaultCase("last_used_retired_and_all_enabled_retired_returns_none")
    @Test fun CLOSURE_last_used_disabled_by_user_no_hint() =
        assertNewChatDefaultCase("last_used_disabled_by_user_no_hint")
    @Test fun CLOSURE_last_used_disabled_and_retired_hints() =
        assertNewChatDefaultCase("last_used_disabled_and_retired_hints")
    @Test fun CLOSURE_last_used_missing_with_shut_down_canonical_skipped() =
        assertNewChatDefaultCase("last_used_missing_with_shut_down_canonical_skipped")

    // ── newChatAcrossConnectionsCases ──

    /** The fixture connection id is this platform's provider id, and connection order is list order (all connected, the first is the primary); each catalog is written into the global MetadataClient. */
    private fun assertNewChatAcrossConnectionsCase(id: String) {
        val raw = case("newChatAcrossConnectionsCases", id)
        val connections = raw.getValue("connections").jsonArray.map { it.jsonObject }
        fun kindOf(connectionId: String): ProviderKind = when (connectionId) {
            "deepseek" -> ProviderKind.DeepSeek
            "openai" -> ProviderKind.OpenAI
            else -> error("unmapped fixture connection $connectionId")
        }
        fun metadataKey(kind: ProviderKind): String = if (kind == ProviderKind.DeepSeek) "deepseek" else "openAI"
        MetadataTestFixtures.applyRaw(
            buildJsonObject {
                put("version", 1)
                put("contractVersion", 1)
                put("providers", buildJsonObject {
                    connections.forEach { connection ->
                        // A connection without a catalog (catalog: null) writes none.
                        val catalog = connection["catalog"] as? JsonObject ?: return@forEach
                        put(metadataKey(kindOf(connection.text("id")!!)), buildJsonObject {
                            catalog.text("defaultModelId")?.let { put("defaultModelId", it) }
                            put("retiredModels", catalog.getValue("retiredModels"))
                            put("resolveMap", catalog.getValue("resolveMap"))
                            put("models", buildJsonObject {
                                catalog.getValue("models").jsonArray.map { it.jsonObject }.forEach { model ->
                                    put(model.text("id")!!, buildJsonObject {
                                        put("canonicalModelId", model.text("id"))
                                        put("displayName", model.text("displayName"))
                                    })
                                }
                            })
                        })
                    }
                })
            }.toString(),
        )
        val providers = connections.map { connection ->
            val connectionId = connection.text("id")!!
            val models = connection.getValue("userModels").jsonArray.map { element ->
                val modelId = element.jsonPrimitive.content
                AIModel(id = modelId, name = modelId)
            }
            // missingCredential: the key is missing on this platform (effectiveStatusKind = NeedsKey); issue: an error state while the credential is present.
            val missingCredential = connection["missingCredential"]?.jsonPrimitive?.boolean == true
            Provider(
                id = connectionId,
                kind = kindOf(connectionId),
                status = if (connection["issue"]?.jsonPrimitive?.boolean == true) {
                    ProviderConnectionState.Issue("Rate limited")
                } else {
                    ProviderConnectionState.Connected
                },
                models = models,
                catalogModels = models,
                apiKey = if (missingCredential) "" else "sk-test",
                apiKeyPreview = if (missingCredential) "" else "sk-...test",
            )
        }
        val lastUsed = (raw["lastUsedRef"] as? JsonObject)?.let { ref ->
            LastUsedModelRef(ref.text("connectionId")!!, ref.text("modelId")!!)
        }

        val resolved = resolveActiveModel(providers, lastUsed, now = now)

        val expect = raw.getValue("expect").jsonObject
        assertEquals("$id connectionId", expect.text("connectionId"), resolved?.provider?.id)
        assertEquals("$id modelId", expect.text("modelId"), resolved?.model?.id)
        assertEquals("$id hint", expect.text("hint"), resolved?.hint?.wire)
    }

    @Test fun CLOSURE_first_connection_all_retired_moves_to_next() =
        assertNewChatAcrossConnectionsCase("first_connection_all_retired_moves_to_next")
    @Test fun CLOSURE_last_used_on_second_connection_wins() =
        assertNewChatAcrossConnectionsCase("last_used_on_second_connection_wins")
    @Test fun CLOSURE_last_used_retired_on_dead_connection_moves_on() =
        assertNewChatAcrossConnectionsCase("last_used_retired_on_dead_connection_moves_on")
    @Test fun CLOSURE_no_connection_usable_returns_none() =
        assertNewChatAcrossConnectionsCase("no_connection_usable_returns_none")
    @Test fun CLOSURE_last_used_retired_falls_back_within_its_connection_first() =
        assertNewChatAcrossConnectionsCase("last_used_retired_falls_back_within_its_connection_first")
    @Test fun CLOSURE_last_used_on_connection_missing_credential_skipped_no_hint() =
        assertNewChatAcrossConnectionsCase("last_used_on_connection_missing_credential_skipped_no_hint")
    @Test fun CLOSURE_errored_first_connection_keeps_list_order() =
        assertNewChatAcrossConnectionsCase("errored_first_connection_keeps_list_order")

    /** Catalog not loaded and the last used model is no longer enabled: take the first enabled model through the fallback chain, and an isDefault the client wrote automatically does not override it. */
    @Test fun newChatFallback_catalogNotLoaded_staleLastUsedIgnoresAutoWrittenDefault() {
        MetadataTestFixtures.clear()
        val models = listOf(
            AIModel(id = "gpt-a", name = "gpt-a"),
            AIModel(id = "gpt-b", name = "gpt-b", isDefault = true),
        )
        val provider = Provider(
            id = "provider-fallback",
            kind = ProviderKind.OpenAI,
            status = ProviderConnectionState.Connected,
            models = models,
            catalogModels = models,
            apiKey = "sk-test",
            apiKeyPreview = "sk-...test",
        )

        val resolved = resolveActiveModel(listOf(provider), LastUsedModelRef(provider.id, "gpt-removed"), now = now)

        assertEquals("gpt-a", resolved?.model?.id)
        assertNull(resolved?.hint)
    }

    /** Catalog not loaded and no last used model: take the first enabled model, not the one the connection marks isDefault. */
    @Test fun newChatFallback_catalogNotLoaded_noLastUsedIgnoresConnectionDefault() {
        MetadataTestFixtures.clear()
        val models = listOf(
            AIModel(id = "gpt-a", name = "gpt-a"),
            AIModel(id = "gpt-b", name = "gpt-b", isDefault = true),
        )
        val provider = Provider(
            id = "provider-fallback",
            kind = ProviderKind.OpenAI,
            status = ProviderConnectionState.Connected,
            models = models,
            catalogModels = models,
            apiKey = "sk-test",
            apiKeyPreview = "sk-...test",
        )

        val resolved = resolveActiveModel(listOf(provider), lastUsedModelRef = null, now = now)

        assertEquals("gpt-a", resolved?.model?.id)
    }

    // ── relayVideoEnvelopeCases ──

    private fun assertRelayVideoEnvelopeCase(id: String) {
        val raw = case("relayVideoEnvelopeCases", id)
        assertEquals(id, "relay", raw.text("connection"))
        // Connection evidence is null: the separate MetadataClient holds no probe or declaration.
        assertEquals(id, JsonNull, raw.getValue("connectionEvidence"))
        val transport = RELAY_TRANSPORTS.getValue(raw.text("firstSend")!!)
        val model = AIModel(id = "closure-relay-model", name = "closure-relay-model", capabilities = listOf(ModelCapability.Text))
        val provider = Provider(
            id = "closure-relay",
            kind = ProviderKind.Relay,
            relayRequested = RelayRequestedConfig(transport = transport),
            models = listOf(model),
        )
        // Fixture envelope null means the envelope is absent: it is not passed explicitly and goes through production resolution by the current connection (which cannot resolve in a unit test).
        val envelope = (raw.getValue("envelope") as? JsonObject)?.let {
            AttachmentSupportInfo(
                image = it.getValue("image").jsonPrimitive.boolean,
                nativeFile = it.getValue("nativeFile").jsonPrimitive.boolean,
                textFileInline = false,
            )
        }
        val identity = CapabilityEvidenceFacade.QueryIdentity(
            partitionId = "partition",
            connectionInstanceId = provider.id,
            connectionGeneration = "1",
            credentialEpoch = "1",
            providerKind = ProviderKind.Relay.rawValue,
            authMode = ProviderAuthMode.ApiKey.rawValue,
            modelId = model.id,
            effectiveTransport = transport.value,
            endpointFingerprint = "fingerprint",
        )
        val projections = requireNotNull(
            resolveInputCapabilityProjections(
                provider = provider,
                model = model,
                relayIdentity = identity,
                relayAttachmentSupport = envelope,
                metadataClient = MetadataClient(),
                negativeCache = cache,
                relayNegativeCache = relayCache,
                now = now,
            ),
        )
        assertEquals(id, raw.getValue("expect").jsonObject, projections[raw.text("key")!!].toJson())
    }

    @Test fun CLOSURE_relay_video_chat_envelope_has_no_video_bit() =
        assertRelayVideoEnvelopeCase("relay_video_chat_envelope_has_no_video_bit")
    @Test fun CLOSURE_relay_video_messages_not_implemented() =
        assertRelayVideoEnvelopeCase("relay_video_messages_not_implemented")
    @Test fun CLOSURE_relay_video_envelope_missing_not_rejection() =
        assertRelayVideoEnvelopeCase("relay_video_envelope_missing_not_rejection")
    @Test fun CLOSURE_relay_vision_envelope_missing_not_rejection() =
        assertRelayVideoEnvelopeCase("relay_vision_envelope_missing_not_rejection")

    // ── shared ──

    private fun CapabilityEvidenceFacade.InputCapabilityProjection.toJson(): JsonObject = buildJsonObject {
        put("visible", JsonPrimitive(visible))
        put("editable", JsonPrimitive(editable))
        put("outbound", Json.encodeToJsonElement(CapabilityEvidenceFacade.InputCapabilityOutbound.serializer(), outbound))
        put("hint", hint?.let { Json.encodeToJsonElement(CapabilityEvidenceFacade.InputCapabilityHint.serializer(), it) } ?: JsonNull)
        put(
            "disabledReason",
            disabledReason?.let {
                Json.encodeToJsonElement(CapabilityEvidenceFacade.InputCapabilityDisabledReason.serializer(), it)
            } ?: JsonNull,
        )
    }

    private fun bundledPayload(): JsonObject {
        val file = workspaceFile("shared/model-contracts/bundled-metadata.v2.json.gz")
        val text = GZIPInputStream(file.inputStream()).bufferedReader().use { it.readText() }
        return Json.parseToJsonElement(text).jsonObject
    }

    private fun workspaceFile(relative: String): File {
        var dir: File? = File("").absoluteFile
        while (dir != null) {
            val candidate = File(dir, relative)
            if (candidate.exists()) return candidate
            dir = dir.parentFile
        }
        throw IllegalStateException("not found: $relative")
    }

    private companion object {
        const val BUNDLED_MODEL = "deepseek-flash"

        val RELAY_TRANSPORTS = mapOf(
            "chat" to RelayTransport.OpenAIChatCompletions,
            "responses" to RelayTransport.OpenAIResponses,
            "messages" to RelayTransport.AnthropicMessages,
        )
    }
}
