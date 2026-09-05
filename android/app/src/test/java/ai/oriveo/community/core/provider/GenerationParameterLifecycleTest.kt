package ai.oriveo.community.core.provider

import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.CapabilityEvidenceIdentity
import ai.oriveo.community.core.model.ChatRequestOptions
import ai.oriveo.community.core.model.GenerationOverrideState
import ai.oriveo.community.core.model.GenerationParameterOverride
import ai.oriveo.community.core.model.GenerationParameterOverrides
import ai.oriveo.community.core.model.GenerationParameterPresetStore
import ai.oriveo.community.core.model.GenerationParameterProfileFingerprint
import ai.oriveo.community.core.model.GenerationParameterSettingsStore
import ai.oriveo.community.core.model.GenerationParameterSyncContract
import ai.oriveo.community.core.model.GenerationParameterSyncLedger
import ai.oriveo.community.core.model.GenerationParameterSyncPayload
import ai.oriveo.community.core.model.GenerationParameterSyncTombstone
import ai.oriveo.community.core.model.GenerationProfileRef
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.ReasoningMode
import ai.oriveo.community.core.model.RelayRequestedConfig
import ai.oriveo.community.core.model.RelayTransport
import ai.oriveo.community.core.provider.transport.TransportKind
import ai.oriveo.community.core.provider.relay.buildAnthropicBody
import ai.oriveo.community.core.provider.relay.buildOpenAIChatBody
import java.io.File
import java.nio.file.Files
import java.nio.file.Path
import javax.xml.parsers.DocumentBuilderFactory
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import org.w3c.dom.Element

/**
 * Lifecycle coverage: per-field revalidation, the dormant state, and what happens to an already recorded scope once
 * its transport is changed underneath it.
 *
 * Nothing in this file hand-writes a profile. Relay profiles are synthesised by the production
 * [LocalEngineGenerationProfiles], profiles in the published shape are decoded from catalog JSON by the production
 * `GenerationProfileRef` deserialiser, stored values always go in and come back out through the production
 * [GenerationParameterSettingsStore], and the final body is produced by the production `buildAnthropicBody`.
 */
class GenerationParameterLifecycleTest {

    private val json = Json { ignoreUnknownKeys = true }

    // -- shared fixture: the lifecycleCases table --------------------------

    @Test
    fun `shared lifecycle cases are answered by the production lifecycle predicate`() {
        val contract = json.decodeFromString<LifecycleFile>(contractText())
        assertTrue("lifecycleCases has fewer than 17 entries, the contract has been cut down", contract.lifecycleCases.size >= 17)
        // The older wording carved out a special exemption for a relay's local template. That is void: providerKind must
        // take no part in the decision. What is pinned here is the current rule itself, so going back to the old shape
        // turns this red.
        assertTrue(
            "lifecycleRules must state that providerKind plays no part in the pass decision",
            contract.lifecycleRules.lifecycle.any { it.contains("providerKind") },
        )
        // Check that the key entries are present without pinning an exact count; a wholesale deletion is already caught by
        // the size check above.
        val caseIds = contract.lifecycleCases.map { it.caseId }.toSet()
        listOf(
            "official.declared.accepted",
            "official.declared.accepted_unverified",
            "official.declared.unknown",
            "official.declared.unsupported",
            "official.declared.fixed",
            "official.declared.mode_dependent",
        ).forEach { assertTrue("lifecycleCases is missing $it", it in caseIds) }

        val failures = mutableListOf<String>()
        contract.lifecycleCases.forEach { item ->
            val kind = if (item.intent.providerKind == "relay") ProviderKind.Relay else ProviderKind.OpenAI
            val profile = item.intent.takeIf { it.declared }?.let {
                declaredProfile(it.parameterId, it.support.orEmpty(), it.wire)
            }
            // storedState is part of a case's intent: `value` and `omit` mean the user expressed this intent explicitly
            // (`inherit` does not), which is exactly hasExplicitValue. It used to be ignored here entirely, so the three
            // relaxation cases on the vendor side were never fed into the production projection at all.
            val projection = productionLifecycleProjection(
                parameterId = item.intent.parameterId,
                support = item.intent.support.orEmpty(),
                wire = item.intent.wire,
                relay = kind == ProviderKind.Relay,
                explicit = item.intent.storedState in setOf("value", "omit"),
            )
            val actual = GenerationParameterLifecycleRules.lifecycle(
                parameter = profile?.parameters?.firstOrNull(),
                wirePath = profile?.wire?.get(item.intent.parameterId),
                capabilityProjection = projection,
            )
            val expected = if (item.expect.lifecycle == "active") {
                GenerationParameterLifecycle.Active
            } else {
                GenerationParameterLifecycle.Dormant
            }
            if (actual != expected) failures += "${item.caseId}: lifecycle=$actual, want $expected"

            // The set-level view and the single-parameter predicate have to agree, because the panel and the send path both
            // go through the set-level one.
            if (profile != null) {
                val inActiveSet = item.intent.parameterId in
                    GenerationParameterLifecycleRules.activeParameterIds(profile, projection)
                if (inActiveSet != (expected == GenerationParameterLifecycle.Active)) {
                    failures += "${item.caseId}: activeParameterIds disagrees with the single-parameter predicate"
                }
            }
        }
        if (failures.isNotEmpty()) fail(failures.joinToString("\n"))
    }

    /**
     * The reverse boundary, landing on the outbound gate rather than on the lifecycle alone.
     *
     * Judging dormancy in the lifecycle only blocks the path the panel reads from; the request builders (AnthropicService,
     * QwenService, GeminiService and the rest) ask `permitsOutbound("generation_parameter/<id>")` instead. If `fixed` or
     * `mode_dependent` were flattened to unknown inside the facade and then let through by the explicit-value escape hatch,
     * the panel would say the parameter is not adjustable while the request carried it anyway - the exact gap between what
     * is shown and what actually happens that this is meant to close.
     *
     * `unsupported` is pinned alongside them: it is the hard boundary of the relaxation and never goes out, under any
     * providerKind.
     */
    @Test
    fun `official negatives never permit outbound even with an explicit value`() {
        listOf("unsupported", "fixed", "mode_dependent").forEach { support ->
            val key = "generation_parameter/temperature"
            val projection = productionLifecycleProjection(
                parameterId = "temperature",
                support = support,
                wire = "temperature",
                relay = false,
                explicit = true,
            )
            assertTrue(
                "official + $support + an explicit value is still judged outbound - the relaxation has been implemented as an unconditional yes",
                !projection.permitsOutbound(key),
            )
        }
    }

    /** The same tuple as a relay has to reach the same conclusion: providerKind plays no part in the pass decision. */
    @Test
    fun `official negatives are provider kind neutral`() {
        listOf("unsupported", "fixed", "mode_dependent").forEach { support ->
            val key = "generation_parameter/temperature"
            val projection = productionLifecycleProjection(
                parameterId = "temperature",
                support = support,
                wire = "temperature",
                relay = true,
                explicit = true,
            )
            assertTrue(
                "relay + $support + an explicit value is let through while official is not - providerKind has become a gate again",
                !projection.permitsOutbound(key),
            )
        }
    }

    @Test
    fun `relay unknown omit removes a field from the production chat body`() {
        val item = json.decodeFromString<LifecycleFile>(contractText()).lifecycleCases
            .first { it.caseId == "relay.declared.unknown_omit" }
        assertEquals("omit", item.intent.storedState)
        assertEquals("unknown", item.intent.support)
        assertEquals("active", item.expect.lifecycle)
        val profile = declaredProfile(item.intent.parameterId, item.intent.support.orEmpty(), item.intent.wire)

        val body = json.parseToJsonElement(buildOpenAIChatBody(
            modelID = "fixture-chat",
            messages = emptyList(),
            stream = true,
            reasoningMode = ReasoningMode.Automatic,
            requestOptions = ChatRequestOptions(
                temperature = 0.7f,
                generationParameters = GenerationParameterOverrides(mapOf(
                    "temperature" to GenerationParameterOverride(GenerationOverrideState.Omit),
                )),
                activeModel = AIModel(id = "fixture-chat", name = "fixture-chat", generationProfile = profile),
            ),
        )).jsonObject

        assertNull(body["temperature"])
    }

    @Test
    fun `active set never exceeds what the outbound gate would actually write`() {
        // The lifecycle form of the strong parity rule: the set the reader marks active must be a subset of what the
        // outbound gate would actually write into the body.
        val provider = relayProvider(RelayTransport.OpenAIChatCompletions)
        val profile = GenerationParameterAvailability.profile(provider, MODEL)
        assertNotNull("production profile synthesis returned null", profile)
        val active = GenerationParameterLifecycleRules.activeParameterIds(
            profile,
            relayLifecycleProjection(provider, MODEL, profile),
        )
        assertTrue("a relay local template must produce a non-empty profile", profile!!.parameters.isNotEmpty())
        profile.parameters.forEach { parameter ->
            val id = parameter.id ?: return@forEach
            assertEquals(
                "$id: the final-dispatch retained set must hold only parameters that carry a wire declaration",
                !profile.wire[id].isNullOrEmpty(),
                id in active,
            )
        }
    }

    // -- per-field revalidation --------------------------------------------

    @Test
    fun `profile change revalidates per parameter instead of dropping the whole record`() {
        val harness = Harness()
        val before = relayProvider(RelayTransport.OpenAIChatCompletions)
        val after = relayProvider(RelayTransport.AnthropicMessages)
        assertNotEquals(fingerprint(before), fingerprint(after))

        harness.settings.setModelDefaults(
            overrides("temperature" to 0.4, "frequency_penalty" to 0.5),
            providerID = PROVIDER_ID,
            modelID = MODEL.id,
            profileFingerprint = fingerprint(before),
        )

        // (1) The record has to still be readable. All-or-nothing invalidation at record level is exactly what threw this
        // away, and it is what left the orphaned scopes behind.
        val stored = harness.settings.modelDefaults(PROVIDER_ID, MODEL.id, fingerprint(after))
        assertEquals(
            setOf("temperature", "frequency_penalty"),
            stored?.values?.keys,
        )

        // (2) The decision is per field: temperature is still in the anthropic template, frequency_penalty is not.
        val partition = GenerationParameterLifecycleRules.partition(
            after, MODEL, stored!!, relayLifecycleProjection(after, MODEL),
        )
        assertEquals(setOf("temperature"), partition.active.values.keys)
        assertEquals(listOf("frequency_penalty"), partition.dormantIds)
        // (3) No silent substitution: the dormant value is kept verbatim, not clamped into some other number.
        assertEquals(
            JsonPrimitive(0.5),
            partition.dormant.values["frequency_penalty"]?.value,
        )
    }

    @Test
    fun `compatible values restore themselves once the profile matches again`() {
        val harness = Harness()
        val before = relayProvider(RelayTransport.OpenAIChatCompletions)
        harness.settings.setModelDefaults(
            overrides("temperature" to 0.4, "frequency_penalty" to 0.5),
            providerID = PROVIDER_ID,
            modelID = MODEL.id,
            profileFingerprint = fingerprint(before),
        )

        val corrected = relayProvider(RelayTransport.AnthropicMessages)
        assertEquals(
            listOf("frequency_penalty"),
            GenerationParameterLifecycleRules.partition(
                corrected,
                MODEL,
                harness.settings.modelDefaults(PROVIDER_ID, MODEL.id, fingerprint(corrected))!!,
                relayLifecycleProjection(corrected, MODEL),
            ).dormantIds,
        )

        // Change the transport back and the value returns on its own, because it was never deleted - only the predicate
        // flipped, and the user does not have to set it again.
        val restored = GenerationParameterLifecycleRules.partition(
            before,
            MODEL,
            harness.settings.modelDefaults(PROVIDER_ID, MODEL.id, fingerprint(before))!!,
            relayLifecycleProjection(before, MODEL),
        )
        assertEquals(emptyList<String>(), restored.dormantIds)
        assertEquals(setOf("temperature", "frequency_penalty"), restored.active.values.keys)
    }

    // -- dormant values never go out, and older records do not turn into orphans --

    @Test
    fun `dormant values are blocked at evaluation time and never reach the production body`() {
        val harness = Harness()
        val before = relayProvider(RelayTransport.OpenAIChatCompletions)
        val after = relayProvider(RelayTransport.AnthropicMessages)
        harness.settings.setModelDefaults(
            overrides("temperature" to 0.4, "frequency_penalty" to 0.5),
            providerID = PROVIDER_ID,
            modelID = MODEL.id,
            profileFingerprint = fingerprint(before),
        )

        val profile = GenerationParameterAvailability.profile(after, MODEL)!!
        val activeIds = GenerationParameterLifecycleRules.activeParameterIds(
            profile,
            relayLifecycleProjection(after, MODEL, profile),
        )

        // Passing no activeParameterIds means no filtering at all, which proves it really is this gate that stops dormant
        // values rather than something else dropping them along the way.
        val unfiltered = harness.settings.resolve(
            transient = null,
            providerID = PROVIDER_ID,
            modelID = MODEL.id,
            conversationID = CONVERSATION_ID,
            profileFingerprint = fingerprint(after),
        )
        assertEquals(setOf("temperature", "frequency_penalty"), unfiltered?.values?.keys)

        val resolved = harness.settings.resolve(
            transient = null,
            providerID = PROVIDER_ID,
            modelID = MODEL.id,
            conversationID = CONVERSATION_ID,
            profileFingerprint = fingerprint(after),
            activeParameterIds = activeIds,
        )
        assertEquals(setOf("temperature"), resolved?.values?.keys)

        // The final body comes out of the production relay builder.
        val body = json.parseToJsonElement(
            buildAnthropicBody(
                MODEL.id,
                emptyList(),
                true,
                ReasoningMode.Automatic,
                ChatRequestOptions(
                    generationParameters = resolved,
                    activeModel = MODEL.copy(generationProfile = profile),
                ),
                capabilityProjection = relayLifecycleProjection(after, MODEL, profile),
            ),
        ).jsonObject
        assertEquals(0.4, body["temperature"]?.jsonPrimitive?.doubleOrNull)
        assertNull(body["frequency_penalty"])
    }

    @Test
    fun `single transient values stay exempt from the dormant filter`() {
        // A transient value is produced by the UI in this very round against the current profile, so by definition it cannot
        // be stale. Blocking it as well would make the highest-priority scope fail for no reason. It is still subject to
        // the outbound gate downstream.
        val harness = Harness()
        val resolved = harness.settings.resolve(
            transient = overrides("frequency_penalty" to 0.5),
            providerID = PROVIDER_ID,
            modelID = MODEL.id,
            conversationID = CONVERSATION_ID,
            activeParameterIds = setOf("temperature"),
        )
        assertEquals(setOf("frequency_penalty"), resolved?.values?.keys)
    }

    @Test
    fun `transport change migrates the scope record instead of leaving an orphan`() {
        val harness = Harness()
        val before = relayProvider(RelayTransport.OpenAIChatCompletions)
        val after = relayProvider(RelayTransport.AnthropicMessages)
        harness.settings.setModelDefaults(
            overrides("temperature" to 0.4),
            providerID = PROVIDER_ID,
            modelID = MODEL.id,
            profileFingerprint = fingerprint(before),
        )
        harness.settings.setModelDefaults(
            overrides("temperature" to 0.9),
            providerID = PROVIDER_ID,
            modelID = MODEL.id,
            profileFingerprint = fingerprint(after),
        )

        // The record under the old fingerprint is merged away without leaving remains, and both fingerprints read back the
        // same latest value.
        val records = harness.settings.syncRecords()
            .filter { it.modelID == MODEL.id && it.conversationID == null }
        assertEquals(1, records.size)
        assertEquals(fingerprint(after), records.single().profileFingerprint)
        listOf(fingerprint(before), fingerprint(after)).forEach { probe ->
            assertEquals(
                JsonPrimitive(0.9),
                harness.settings.modelDefaults(PROVIDER_ID, MODEL.id, probe)?.values?.get("temperature")?.value,
            )
        }
    }

    // -- sync semantics: the envelope is unchanged and so are the tombstone rules --

    @Test
    fun `dormancy is device local - the sync envelope keeps schema version one and still carries the value`() {
        val harness = Harness()
        val before = relayProvider(RelayTransport.OpenAIChatCompletions)
        val after = relayProvider(RelayTransport.AnthropicMessages)
        harness.settings.setModelDefaults(
            overrides("temperature" to 0.4, "frequency_penalty" to 0.5),
            providerID = PROVIDER_ID,
            modelID = MODEL.id,
            profileFingerprint = fingerprint(before),
        )

        // Dormancy is derived on this device: not one extra field appears on the wire, and dormant values are still exported.
        val payload = harness.contract.exportPayload()
        assertEquals(1, payload.schemaVersion)
        assertEquals(setOf("temperature", "frequency_penalty"), payload.records.single().values.keys)
        assertTrue("the envelope must not contain any dormant field", !harness.contract.exportJSON().contains("dormant"))

        // The panel's clear action removes only the dormant half; values still in effect are left exactly as they were.
        val partition = GenerationParameterLifecycleRules.partition(
            after,
            MODEL,
            harness.settings.modelDefaults(PROVIDER_ID, MODEL.id, fingerprint(after))!!,
            relayLifecycleProjection(after, MODEL),
        )
        harness.settings.setModelDefaults(
            partition.active,
            providerID = PROVIDER_ID,
            modelID = MODEL.id,
            profileFingerprint = fingerprint(after),
        )
        assertEquals(setOf("temperature"), harness.contract.exportPayload().records.single().values.keys)

        // Clearing everything goes through the existing tombstone rules, so an older remote record does not come back to life.
        val recordID = harness.contract.exportPayload().records.single().recordId
        harness.settings.setModelDefaults(null, PROVIDER_ID, MODEL.id, fingerprint(after))
        assertTrue(harness.ledger.all().any { it.recordId == recordID })
        val revived = harness.contract.merge(
            GenerationParameterSyncPayload(
                records = listOf(
                    ai.oriveo.community.core.model.GenerationParameterSyncRecord(
                        recordId = recordID,
                        scope = "model_default",
                        providerId = PROVIDER_ID.lowercase(),
                        modelId = MODEL.id,
                        values = mapOf(
                            "temperature" to GenerationParameterOverride(
                                GenerationOverrideState.Value,
                                JsonPrimitive(0.4),
                            ),
                        ),
                        revision = 1,
                        mutationId = "device-stale",
                    ),
                ),
            ),
        )
        assertEquals(emptyList<String>(), revived.records.map { it.recordId })
    }

    @Test
    fun `remote tombstone still suppresses a record whose values are all dormant locally`() {
        val harness = Harness()
        val before = relayProvider(RelayTransport.OpenAIChatCompletions)
        harness.settings.setModelDefaults(
            overrides("frequency_penalty" to 0.5),
            providerID = PROVIDER_ID,
            modelID = MODEL.id,
            profileFingerprint = fingerprint(before),
        )
        val recordID = harness.contract.exportPayload().records.single().recordId
        harness.contract.merge(
            GenerationParameterSyncPayload(
                tombstones = listOf(GenerationParameterSyncTombstone(recordID, 9, "device-z")),
            ),
        )
        assertNull(harness.settings.modelDefaults(PROVIDER_ID, MODEL.id, fingerprint(before)))
    }

    // -- presets stored per field -------------------------------------------

    @Test
    fun `presets are not fingerprint bound and keep dormant values until the profile matches again`() {
        val harness = Harness()
        val before = relayProvider(RelayTransport.OpenAIChatCompletions)
        val after = relayProvider(RelayTransport.AnthropicMessages)
        assertNotEquals(fingerprint(before), fingerprint(after))

        // The panel's current values come from the production read and write chain, and which of them are dormant is decided
        // by the production partition rather than by the test.
        harness.settings.setModelDefaults(
            overrides("temperature" to 0.4, "frequency_penalty" to 0.5),
            providerID = PROVIDER_ID,
            modelID = MODEL.id,
            profileFingerprint = fingerprint(before),
        )
        val panelValues = harness.settings.modelDefaults(PROVIDER_ID, MODEL.id, fingerprint(after))!!
        assertEquals(
            listOf("frequency_penalty"),
            GenerationParameterLifecycleRules.partition(
                after, MODEL, panelValues, relayLifecycleProjection(after, MODEL),
            ).dormantIds,
        )

        val preset = harness.presets.save(
            name = "Precise",
            providerID = PROVIDER_ID,
            modelID = MODEL.id,
            profileFingerprint = fingerprint(after),
            values = panelValues,
        )
        assertEquals(
            "trimming a preset by this device's dormant verdict would let device A's profile switch off a value device B can send",
            JsonPrimitive(0.5),
            preset.values.values["frequency_penalty"]?.value,
        )

        // The fingerprint changed, yet the preset is still listed and can still be applied - under the old wording the whole
        // preset vanished at exactly this point.
        assertEquals(
            listOf(preset.id),
            harness.presets.list(PROVIDER_ID, MODEL.id, fingerprint(before)).map { it.id },
        )
        val applied = harness.presets.apply(preset, PROVIDER_ID, MODEL.id, fingerprint(before))!!
        harness.settings.setModelDefaults(applied, PROVIDER_ID, MODEL.id, fingerprint(before))

        // Once the profile is back on a template that declares the parameter, the previously dormant value goes out again on
        // its own, and the body comes from the production relay builder.
        val profile = GenerationParameterAvailability.profile(before, MODEL)!!
        val resolved = harness.settings.resolve(
            transient = null,
            providerID = PROVIDER_ID,
            modelID = MODEL.id,
            conversationID = CONVERSATION_ID,
            profileFingerprint = fingerprint(before),
            activeParameterIds = GenerationParameterLifecycleRules.activeParameterIds(
                profile,
                relayLifecycleProjection(before, MODEL, profile),
            ),
        )
        val body = json.parseToJsonElement(
            buildOpenAIChatBody(
                MODEL.id,
                emptyList(),
                true,
                ReasoningMode.Automatic,
                ChatRequestOptions(
                    generationParameters = resolved,
                    activeModel = MODEL.copy(generationProfile = profile),
                ),
                capabilityProjection = relayLifecycleProjection(before, MODEL, profile),
            ),
        ).jsonObject
        assertEquals(0.5, body["frequency_penalty"]?.jsonPrimitive?.doubleOrNull)

        // Crossing models still stays inside a single provider and uses the portable semantic mapping, as the contract requires.
        assertNull(harness.presets.apply(preset, PROVIDER_ID, "another-model", fingerprint(before)))
        assertTrue(
            harness.presets.list(PROVIDER_ID, "another-model", fingerprint(before), setOf("top_p")).isEmpty(),
        )

        // The ruling has to live in the shared fixture; deleting it from there should turn this red.
        assertTrue(
            "lifecycleRules.presets has been cut down",
            json.decodeFromString<LifecycleFile>(contractText()).lifecycleRules.presets.size >= 4,
        )
    }

    // -- copy discipline ------------------------------------------------------

    @Test
    fun `dormant copy ships in all 16 locales and never leaks an implementation word`() {
        val res = File(androidRoot, "app/src/main/res")
        val localeDirs = res.listFiles().orEmpty()
            .filter { it.isDirectory && it.name.startsWith("values") && it.name != "values-night" }
            .filter { File(it, "strings.xml").exists() }
        assertEquals("Unexpected locale count", 16, localeDirs.size)

        val factory = DocumentBuilderFactory.newInstance()
        val failures = mutableListOf<String>()
        localeDirs.forEach { directory ->
            val nodes = factory.newDocumentBuilder().parse(File(directory, "strings.xml"))
                .getElementsByTagName("string")
            val byName = (0 until nodes.length)
                .map { nodes.item(it) as Element }
                .associate { it.getAttribute("name") to it.textContent.orEmpty() }
            DORMANT_KEYS.forEach { key ->
                val value = byName[key].orEmpty()
                if (value.isBlank()) {
                    failures += "${directory.name}/$key: missing translation"
                    return@forEach
                }
                // The user-facing wording is always along the lines of "kept, currently not in effect"; an implementation
                // word must never leak through, in any language.
                FORBIDDEN_WORDS.forEach { word ->
                    if (value.contains(word, ignoreCase = true)) {
                        failures += "${directory.name}/$key: contains the implementation word \"$word\""
                    }
                }
                if (key in COUNTED_KEYS && !value.contains("%1\$d")) {
                    failures += "${directory.name}/$key: the %1\$d count placeholder is missing or broken"
                }
            }
        }
        assertTrue(failures.joinToString("\n"), failures.isEmpty())
    }

    // ── fixtures ───────────────────────────────────────────────────────────

    private class Harness {
        var settingsPayload: String? = null
        var presetPayload: String? = null
        var tombstonePayload: String? = null
        val ledger = GenerationParameterSyncLedger(
            readPayload = { tombstonePayload },
            writePayload = { tombstonePayload = it },
        )
        val settings = GenerationParameterSettingsStore(
            readPayload = { settingsPayload },
            writePayload = { settingsPayload = it },
            putTombstone = { recordID, revision -> ledger.put(recordID, revision) },
            clearTombstone = { recordID -> ledger.clear(recordID) },
        )
        val presets = GenerationParameterPresetStore(
            readPayload = { presetPayload },
            writePayload = { presetPayload = it },
        )
        val contract = GenerationParameterSyncContract(settings, presets, ledger)
    }

    private fun relayProvider(transport: RelayTransport): Provider = Provider(
        id = PROVIDER_ID,
        kind = ProviderKind.Relay,
        models = listOf(MODEL),
        baseUrlText = "https://relay.example/v1",
        relayRequested = RelayRequestedConfig(transport = transport),
    )

    /** The lifecycle/UI projection uses the same resolved profile and final endpoint as dispatch. */
    private fun relayLifecycleProjection(
        provider: Provider,
        model: AIModel,
        profile: GenerationProfileRef? = GenerationParameterAvailability.profile(provider, model),
    ): CapabilityEvidenceProductionAdapter.Projection {
        val requestModel = model.copy(generationProfile = profile)
        val transport = provider.relayRequested?.transport ?: RelayTransport.Auto
        val finalUrl = when (transport) {
            RelayTransport.OpenAIChatCompletions -> "https://relay.example/v1/chat/completions"
            RelayTransport.OpenAIResponses -> "https://relay.example/v1/responses"
            RelayTransport.AnthropicMessages -> "https://relay.example/v1/messages"
            RelayTransport.GeminiGenerateContent ->
                "https://relay.example/v1beta/models/${requestModel.id}:generateContent"
            RelayTransport.LlamaCppNative -> "https://relay.example/completion"
            RelayTransport.Auto -> error("lifecycle test must select a concrete transport")
        }
        val identity = CapabilityEvidenceProductionAdapter.dispatchIdentity(
            CapabilityEvidenceIdentity("test", provider.id, "1", "1", ProviderKind.Relay.rawValue),
            requestModel,
            transport,
            finalUrl,
        )
        val keys = profile?.parameters.orEmpty().mapNotNull { parameter ->
            parameter.id?.takeIf(String::isNotBlank)?.let { "generation_parameter/$it" }
        }.toSet()
        return CapabilityEvidenceProductionAdapter.dispatchCapabilityProjection(
            requestModel, provider.relayRequested, identity, keys, keys,
        )
    }

    private fun fingerprint(provider: Provider): String =
        GenerationParameterProfileFingerprint.make(provider, MODEL)

    private fun overrides(vararg entries: Pair<String, Double>): GenerationParameterOverrides =
        GenerationParameterOverrides(
            entries.associate { (id, value) ->
                id to GenerationParameterOverride(GenerationOverrideState.Value, JsonPrimitive(value))
            },
        )

    /** The profile is decoded by the production deserialiser from the shape the catalog publishes, so the test never hand-writes a `GenerationProfileRef`. */
    private fun declaredProfile(parameterId: String, support: String, wire: String?): GenerationProfileRef {
        val wireSection = wire?.let { """"wire":{${JsonPrimitive(parameterId)}:${JsonPrimitive(it)}},""" }.orEmpty()
        return json.decodeFromString(
            """
            {"template":"openai_chat_completions",
             $wireSection
             "parameters":[{"id":${JsonPrimitive(parameterId)},
                            "support":${JsonPrimitive(support)},
                            "source":"authoritative_metadata"}]}
            """.trimIndent(),
        )
    }

    /**
     * Lifecycle cases deliberately cross the same production boundary as the UI/send paths.
     * Relay owns its declaration and needs a complete dispatch identity; official models are
     * decoded through MetadataClient's 200-publication path instead of constructing Decisions.
     */
    private fun productionLifecycleProjection(
        parameterId: String,
        support: String,
        wire: String?,
        relay: Boolean,
        explicit: Boolean = true,
    ): CapabilityEvidenceProductionAdapter.Projection {
        val key = "generation_parameter/$parameterId"
        val explicitKeys = if (explicit) setOf(key) else emptySet()
        if (relay) {
            val provider = relayProvider(RelayTransport.OpenAIChatCompletions)
            val model = AIModel(
                id = MODEL.id,
                name = MODEL.name,
                generationProfile = declaredProfile(parameterId, support, wire),
            )
            val identity = CapabilityEvidenceProductionAdapter.dispatchIdentity(
                CapabilityEvidenceIdentity("test", provider.id, "1", "1", ProviderKind.Relay.rawValue),
                model,
                RelayTransport.OpenAIChatCompletions,
                "https://relay.example/v1/chat/completions",
            )
            return CapabilityEvidenceProductionAdapter.dispatchCapabilityProjection(
                model, provider.relayRequested, identity, setOf(key), explicitKeys,
            )
        }

        val template = buildJsonObject {
            put("transport", "openai_chat")
            wire?.let { put("wire", buildJsonObject { put(parameterId, it) }) }
        }
        val profile = buildJsonObject {
            put("template", "openai_chat_completions")
            put("parameters", kotlinx.serialization.json.buildJsonArray {
                add(buildJsonObject {
                    put("id", parameterId)
                    put("support", support)
                    put("source", "authoritative_metadata")
                })
            })
        }
        MetadataTestFixtures.applyRaw(buildJsonObject {
            put("version", 1)
            put("profiles", buildJsonObject {
                put("generation", buildJsonObject {
                    put("parameters", buildJsonObject {
                        put(parameterId, buildJsonObject { put("valueSchema", "number") })
                    })
                    put("templates", buildJsonObject { put("openai_chat_completions", template) })
                })
            })
            put("providers", buildJsonObject {
                put("openAI", buildJsonObject {
                    put("resolveMap", buildJsonObject { put(MODEL.id, MODEL.id) })
                    put("models", buildJsonObject {
                        put(MODEL.id, buildJsonObject {
                            put("canonicalModelId", MODEL.id)
                            put("transport", "openai_chat")
                            put("profiles", buildJsonObject { put("generation", profile) })
                        })
                    })
                })
            })
        }.toString())
        val provider = Provider(id = "official-$PROVIDER_ID", kind = ProviderKind.OpenAI)
        return CapabilityEvidenceProductionAdapter.capabilityProjection(
            provider = provider,
            model = MODEL,
            keys = setOf(key),
            explicitKeys = explicitKeys,
            finalTransport = TransportKind.OpenAIChat.wireValue,
        )
    }

    private fun contractText(): String {
        val path: Path = generateSequence(Path.of(System.getProperty("user.dir"))) { it.parent }
            .map { it.resolve("shared/model-contracts/generation_parameter_contract.v1.json") }
            .firstOrNull(Files::exists)
            ?: error("generation_parameter_contract.v1.json not found")
        return String(Files.readAllBytes(path), Charsets.UTF_8)
    }

    private val androidRoot: File by lazy {
        var dir = File(System.getProperty("user.dir") ?: ".")
        repeat(8) {
            if (File(dir, "app/src/main/res/values/strings.xml").exists()) return@lazy dir
            dir = dir.parentFile ?: return@repeat
        }
        error("Cannot find Android project root")
    }

    @Serializable
    private data class LifecycleFile(
        val lifecycleCases: List<LifecycleCase>,
        val lifecycleRules: LifecycleRules,
    )

    @Serializable
    private data class LifecycleRules(val lifecycle: List<String>, val presets: List<String>)

    @Serializable
    private data class LifecycleCase(
        val caseId: String,
        val intent: LifecycleIntent,
        val expect: LifecycleExpectation,
    )

    @Serializable
    private data class LifecycleIntent(
        val providerKind: String,
        val parameterId: String,
        val declared: Boolean,
        val storedState: String,
        val support: String? = null,
        val wire: String? = null,
    )

    @Serializable
    private data class LifecycleExpectation(val lifecycle: String)

    private companion object {
        const val PROVIDER_ID = "11111111-1111-1111-1111-111111111111"
        const val CONVERSATION_ID = "22222222-2222-2222-2222-222222222222"
        val MODEL = AIModel(id = "my-private-model", name = "my-private-model")

        val DORMANT_KEYS = listOf(
            "generation_parameter_dormant_summary",
            "generation_parameter_dormant_view",
            "generation_parameter_dormant_clear",
            "generation_parameter_dormant_restored",
        )
        val COUNTED_KEYS = setOf(
            "generation_parameter_dormant_summary",
            "generation_parameter_dormant_restored",
        )
        // Implementation words that must never surface in user-facing copy. The non-Latin ones are written as escapes so
        // this source file stays ASCII.
        val FORBIDDEN_WORDS = listOf("dormant", "\u4f11\u7720", "\u51bb\u7ed3", "\u51cd\u7d50")
    }
}
