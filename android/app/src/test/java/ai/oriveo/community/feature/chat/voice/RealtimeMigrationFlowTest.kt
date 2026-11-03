package ai.oriveo.community.feature.chat.voice

import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderAuthMode
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.voice.VoiceCatalog
import ai.oriveo.community.core.voice.VoiceDirection
import ai.oriveo.community.core.voice.VoiceEngineSelection
import ai.oriveo.community.core.voice.VoiceEngineSettings
import ai.oriveo.community.core.voice.VoiceOption
import ai.oriveo.community.core.voice.VoiceProviderCatalog
import ai.oriveo.community.core.voice.VoiceRealtimeEntry
import ai.oriveo.community.core.voice.VoiceTransport
import ai.oriveo.community.core.voice.realtime.RealtimeModel
import ai.oriveo.community.testing.TestSharedPreferences
import java.io.File
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Old-user migration: the 10 migrationCases in shared/voice-contracts/realtime-model.v1.json each drive the host's
 * [RealtimeVoiceMigration] (the ≋ pre-check in rememberVoiceConversationHost, the prompt answer, and the disclosure answer all go through it).
 * Old keys are written into the real [VoiceEngineSettings]; connection and catalog are production Provider / VoiceCatalog; assertions check the host's next step, whether the old key is deleted, and whether disclosure consent is kept.
 */
class RealtimeMigrationFlowTest {

    private val fixture: JsonObject =
        Json.parseToJsonElement(workspaceFile("shared/voice-contracts/realtime-model.v1.json").readText()).jsonObject

    private fun JsonObject.present(key: String): JsonElement? = this[key].takeUnless { it == null || it is JsonNull }
    private fun JsonObject.str(key: String): String? = present(key)?.jsonPrimitive?.content
    private fun JsonObject.bool(key: String): Boolean? = present(key)?.jsonPrimitive?.booleanOrNull

    /** Fixture connection → production Provider: auth apiKey = official apiKey connection, others (relay) = subscription auth; RealtimeModel.connectionAuth classifies them as non-apiKey. */
    private fun providersOf(input: JsonObject): List<Provider> =
        input.present("connections")?.jsonArray?.map { it.jsonObject }.orEmpty().map { c ->
            Provider(
                id = c.str("id")!!,
                kind = ProviderKind.fromRawValue(c.str("providerKind")!!)!!,
                authMode = if (c.str("auth") == RealtimeModel.AUTH_API_KEY) ProviderAuthMode.ApiKey else ProviderAuthMode.Subscription,
                apiKey = "sk-test",
            )
        }

    private fun catalogOf(input: JsonObject): VoiceCatalog = VoiceCatalog(
        providers = input.present("realtimeCatalog")?.jsonObject.orEmpty().map { (kind, list) ->
            ProviderKind.fromRawValue(kind)!! to VoiceProviderCatalog(
                realtime = list.jsonArray.map { it.jsonObject }.map { e ->
                    VoiceRealtimeEntry(
                        model = e.str("model")!!,
                        transport = VoiceTransport.OpenAIRealtime,
                        path = "/v1/realtime",
                        contextWindow = 32_000,
                        voices = listOf(VoiceOption("marin", isDefault = true)),
                        isDefault = e.bool("isDefault") == true,
                    )
                },
            )
        }.toMap(),
    )

    @Test
    fun migrationCasesDriveHost() = runTest {
        val cases = fixture["migrationCases"]!!.jsonArray.map { it.jsonObject }
        assertEquals("migrationCases count", 10, cases.size)
        for (case in cases) {
            val id = case.str("id")!!
            val input = case["input"]!!.jsonObject
            val expected = case["expected"]!!.jsonObject
            val settings = VoiceEngineSettings { TestSharedPreferences() }
            val providers = providersOf(input)
            val catalog = catalogOf(input)
            val migration = RealtimeVoiceMigration(settings, { catalog }, { providers })

            val oldKeyPresent = input.bool("oldKeyPresent") == true
            val old = input.present("oldChoice")?.jsonObject?.let {
                VoiceEngineSelection.Cloud(
                    providerKind = ProviderKind.fromRawValue(it.str("providerKind")!!)!!,
                    connectionId = it.str("connectionId")!!,
                    model = it.str("model")!!,
                )
            }
            if (oldKeyPresent) {
                // oldChoice null = old setting is "follow model".
                settings.setSelection(VoiceDirection.Realtime, old ?: VoiceEngineSelection.System)
                assertNotNull("$id old key written", settings.legacyRealtimeChoice())
            }
            val consented = input.bool("consented") == true
            if (consented) settings.disclosure.markAccepted(old!!.providerKind, VoiceDirection.Realtime)

            val first = migration.check()
            if (expected.bool("showPrompt") != true) {
                assertEquals(id, RealtimeVoiceMigration.Step.Cascade, first)
            } else {
                assertEquals(id, RealtimeVoiceMigration.Step.Prompt(old!!), first)
                // Prompt only: do not delete the old key.
                assertNotNull("$id old key still present while the prompt is shown", settings.legacyRealtimeChoice())
                var step = migration.answer(input.str("answer")!!)
                if (expected.bool("showDisclosure") == true) {
                    val disclosure = step as RealtimeVoiceMigration.Step.Disclosure
                    assertEquals(id, old, disclosure.selection)
                    val declined = input.bool("disclosureDeclined") == true
                    step = migration.disclosureAnswered(disclosure, accepted = !declined)
                    assertEquals("$id disclosure consent record", !declined, settings.disclosure.isAccepted(old.providerKind, VoiceDirection.Realtime))
                } else {
                    assertTrue("$id disclosure not shown", step !is RealtimeVoiceMigration.Step.Disclosure)
                }
                val want = when (expected.str("result")) {
                    RealtimeModel.MIGRATION_SELECT_REALTIME -> RealtimeVoiceMigration.Step.SelectRealtime(old)
                    RealtimeModel.MIGRATION_ENTER_CASCADE -> RealtimeVoiceMigration.Step.Cascade
                    else -> RealtimeVoiceMigration.Step.None
                }
                assertEquals(id, want, step)
            }

            if (oldKeyPresent && expected.bool("deleteOldKeys") != true) {
                assertNotNull("$id old key kept", settings.legacyRealtimeChoice())
                // System interruption without an answer: the next tap on ≋ asks again.
                assertTrue("$id asks again", migration.check() is RealtimeVoiceMigration.Step.Prompt)
            } else {
                assertNull("$id old key deleted", settings.legacyRealtimeChoice())
                assertEquals("$id cascades after deletion", RealtimeVoiceMigration.Step.Cascade, migration.check())
            }
            if (consented) {
                assertTrue("$id disclosure consent record kept", settings.disclosure.isAccepted(old!!.providerKind, VoiceDirection.Realtime))
            }
        }
    }

    /** When the voice catalog is unavailable at decision time (null = not loaded / fetch failed): do not classify as unresolvable; go to ≋, keep the old key; prompt normally once the catalog returns. */
    @Test
    fun migration_catalog_unknown_keeps_keys() = runTest {
        val settings = VoiceEngineSettings { TestSharedPreferences() }
        val old = VoiceEngineSelection.Cloud(providerKind = ProviderKind.OpenAI, connectionId = "conn-openai", model = "gpt-realtime")
        settings.setSelection(VoiceDirection.Realtime, old)
        val providers = listOf(
            Provider(id = "conn-openai", kind = ProviderKind.OpenAI, authMode = ProviderAuthMode.ApiKey, apiKey = "sk-test"),
        )
        var catalog: VoiceCatalog? = null
        val migration = RealtimeVoiceMigration(settings, { catalog }, { providers })

        assertEquals(RealtimeVoiceMigration.Step.Cascade, migration.check())
        assertNotNull("old key kept when the catalog is unknown", settings.legacyRealtimeChoice())
        assertEquals(RealtimeVoiceMigration.Step.Cascade, migration.answer(RealtimeModel.ANSWER_SWITCH))
        assertNotNull("answering without a catalog also does not delete the old key", settings.legacyRealtimeChoice())

        catalog = VoiceCatalog(
            providers = mapOf(
                ProviderKind.OpenAI to VoiceProviderCatalog(
                    realtime = listOf(
                        VoiceRealtimeEntry(
                            model = "gpt-realtime",
                            transport = VoiceTransport.OpenAIRealtime,
                            path = "/v1/realtime",
                            contextWindow = 32_000,
                            voices = listOf(VoiceOption("marin", isDefault = true)),
                            isDefault = true,
                        ),
                    ),
                ),
            ),
        )
        assertEquals(RealtimeVoiceMigration.Step.Prompt(old), migration.check())
        assertNotNull(settings.legacyRealtimeChoice())
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
}
