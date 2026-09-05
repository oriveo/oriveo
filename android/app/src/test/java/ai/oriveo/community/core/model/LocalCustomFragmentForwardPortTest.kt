package ai.oriveo.community.core.model

import ai.oriveo.community.core.provider.MetadataTestFixtures
import ai.oriveo.community.core.provider.ModelControlRuntimeIdentity
import java.io.File
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.put
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * Forward-porting custom JSON must revalidate it against the new recipe.
 *
 * A typed preference comes from a closed vocabulary and can be carried over verbatim; what's being
 * carried over here is a field the user hand-wrote, which may no longer be valid under the new
 * recipe. This mirrors iOS's `customFragmentForwardPortRevalidatesAgainstTheNewRecipe` cell by
 * cell: passes revalidation -> stays enabled as-is; fails -> disabled but rawJSON is kept as-is
 * (paused, draft retained); wasn't enabled to begin with -> always disabled; forwardPort not
 * passed = a pure read that changes nothing.
 */
class LocalCustomFragmentForwardPortTest {
    private val json = Json { ignoreUnknownKeys = true; isLenient = true }
    private val providerID = "9a1195de-3af9-5888-abc8-b8177c458c07"
    private val canonicalModel = "canonical-model"
    private val namespace = LocalCapabilityCustomFragmentStore.REASONING_NAMESPACE
    private val legal = """{"reasoning":{"effort":"low"}}"""
    private val illegal = """{"bogus":1}"""

    private val context = LocalCapabilityCustomFragmentStore.ForwardPortContext(
        providerKind = ProviderKind.OpenAI,
        schemaModelID = SCHEMA_MODEL,
    )

    private fun identity(transport: String = "openai_responses", revision: String = "runtime-r7"): String =
        ModelControlRuntimeIdentity(providerID, canonicalModel, transport, revision).storageIdentity

    private var payload: String? = null

    private fun store(): LocalCapabilityCustomFragmentStore {
        payload = null
        return LocalCapabilityCustomFragmentStore(read = { payload }, write = { payload = it })
    }

    @Before
    fun setUp() = MetadataTestFixtures.applyRaw(fixture().toString())

    @After
    fun tearDown() = MetadataTestFixtures.clear()

    /** Sanity check first: the fixture must actually distinguish legal from illegal, or every assertion below is testing nothing. */
    @Test
    fun `the fixture really accepts the legal fragment and rejects the illegal one`() {
        assertTrue(preview(legal))
        assertFalse(preview(illegal))
    }

    /** 1. The new recipe still accepts this JSON -> carried over as-is and still goes out on the wire. */
    @Test
    fun `a fragment the new recipe still accepts stays enabled`() {
        val store = store()
        store.setConfiguration(
            LocalCapabilityCustomFragmentStore.Configuration(enabled = true, rawJSON = legal),
            providerID, canonicalModel, null, identity(revision = "runtime-r7"), namespace,
        )

        val migrated = store.effectiveConfiguration(
            providerID, canonicalModel, null, identity(revision = "runtime-r8"), namespace, context,
        )
        assertTrue("a field the new recipe still accepts was wrongly disabled", migrated.enabled)
        assertEquals(legal, migrated.rawJSON)
        assertEquals(
            "nothing went out on the wire after a legal forward-port",
            mapOf("reasoning" to legal),
            store.fragmentsByOwner(
                providerID, canonicalModel, null, identity(revision = "runtime-r8"), context,
            ),
        )
    }

    /** 2. The new recipe no longer accepts this -> paused, but the draft is kept. Leaving it enabled would trip the outbound fail-closed check and leave the user unable to send a message for no apparent reason. */
    @Test
    fun `a fragment the new recipe rejects is paused but keeps the draft`() {
        val store = store()
        store.setConfiguration(
            LocalCapabilityCustomFragmentStore.Configuration(enabled = true, rawJSON = illegal),
            providerID, canonicalModel, null, identity(revision = "runtime-r7"), namespace,
        )

        val paused = store.effectiveConfiguration(
            providerID, canonicalModel, null, identity(revision = "runtime-r8"), namespace, context,
        )
        assertFalse("a field the new recipe no longer accepts is still going out -- the message won't send", paused.enabled)
        assertEquals("the draft was dropped along the way; the user has nothing left to edit", illegal, paused.rawJSON)
        assertTrue(
            store.fragmentsByOwner(
                providerID, canonicalModel, null, identity(revision = "runtime-r8"), context,
            ).isEmpty(),
        )

        // 3. Idempotent: reading again doesn't change the outcome, and doesn't re-enable the field that was just disabled.
        assertFalse(
            store.effectiveConfiguration(
                providerID, canonicalModel, null, identity(revision = "runtime-r8"), namespace, context,
            ).enabled,
        )
    }

    /** A record that wasn't enabled to begin with: the draft comes along, but forward-porting never turns it on for the user. */
    @Test
    fun `a disabled draft is carried over but never re-enabled`() {
        val store = store()
        store.setConfiguration(
            LocalCapabilityCustomFragmentStore.Configuration(enabled = false, rawJSON = legal),
            providerID, canonicalModel, null, identity(revision = "runtime-r7"), namespace,
        )

        val migrated = store.effectiveConfiguration(
            providerID, canonicalModel, null, identity(revision = "runtime-r8"), namespace, context,
        )
        assertFalse("a disabled draft was forward-ported into an enabled state, effectively turning custom fields on for the user", migrated.enabled)
        assertEquals(legal, migrated.rawJSON)
    }

    /** 4. Not passing forwardPort is a pure read: nothing is forward-ported and nothing is rewritten (the plain-storage unit tests rely on this staying stable). */
    @Test
    fun `without the forward port context nothing is migrated and nothing is written`() {
        val store = store()
        store.setConfiguration(
            LocalCapabilityCustomFragmentStore.Configuration(enabled = true, rawJSON = legal),
            providerID, canonicalModel, null, identity(revision = "runtime-r7"), namespace,
        )
        val before = payload

        val untouched = store.effectiveConfiguration(
            providerID, canonicalModel, null, identity(revision = "runtime-r8"), namespace,
        )
        assertFalse(untouched.enabled)
        assertTrue(untouched.rawJSON.isEmpty())
        assertEquals("a pure read rewrote storage", before, payload)
    }

    /** 5. A different protocol is never migrated: that's genuinely a different request contract, and carrying the field across would be guessing on the user's behalf. */
    @Test
    fun `a different protocol is never migrated`() {
        val store = store()
        store.setConfiguration(
            LocalCapabilityCustomFragmentStore.Configuration(enabled = true, rawJSON = legal),
            providerID, canonicalModel, null, identity("openai_responses", "runtime-r7"), namespace,
        )

        val other = store.effectiveConfiguration(
            providerID, canonicalModel, null, identity("openai_chat", "runtime-r8"), namespace, context,
        )
        assertFalse(other.enabled)
        assertTrue(other.rawJSON.isEmpty())
    }

    /**
     * When a conversation exists, both scopes must run. When the conversation scope has no record,
     * this lookup already falls back to the model-default scope, so forward-porting only one of the
     * two scopes would make "which scope it falls back to" drift with every recipe version bump.
     */
    @Test
    fun `both the conversation scope and the model default scope forward port`() {
        val store = store()
        val old = identity(revision = "runtime-r7")
        val new = identity(revision = "runtime-r8")
        store.setConfiguration(
            LocalCapabilityCustomFragmentStore.Configuration(enabled = true, rawJSON = legal),
            providerID, canonicalModel, null, old, namespace,
        )
        store.setConfiguration(
            LocalCapabilityCustomFragmentStore.Configuration(enabled = true, rawJSON = legal),
            providerID, canonicalModel, CONVERSATION, old, namespace,
        )

        assertTrue(
            store.effectiveConfiguration(providerID, canonicalModel, CONVERSATION, new, namespace, context).enabled,
        )
        // once the conversation scope has forward-ported, the model-default scope must also already exist under the new identity (otherwise clearing the conversation scope falls back to empty).
        assertTrue(
            "the model-default scope didn't follow the version line, so its fallback target drifts across recipe versions",
            store.effectiveConfiguration(providerID, canonicalModel, null, new, namespace).enabled,
        )
    }

    private fun preview(raw: String): Boolean =
        ai.oriveo.community.core.provider.previewCapabilityRuntimeCustomFragment(
            raw = raw,
            providerKind = ProviderKind.OpenAI,
            modelID = SCHEMA_MODEL,
            finalTransport = "openai_responses",
            owner = "reasoning",
        ).accepted

    private fun fixture(): JsonObject {
        val execution = json.parseToJsonElement(
            load("shared/model-contracts/provider_recipe_execution.v1.json"),
        ).jsonObject
        val registryPath = (execution["registryPath"] as JsonPrimitive).content
        val registry = json.parseToJsonElement(load(registryPath)).jsonObject
        val definitions = json.parseToJsonElement(
            load("shared/capabilityrecipe/capability_custom_controls.v2.json"),
        ).jsonObject
        val runtime = JsonObject(
            registry + mapOf(
                "revision" to JsonPrimitive("sha256:custom-forward-port"),
                "generatedAt" to JsonPrimitive("2026-08-16T00:00:00Z"),
                "controlDefinitions" to definitions,
            ),
        )
        return buildJsonObject {
            put("version", 1)
            put("capabilityRuntime", runtime)
            put("providers", buildJsonObject {
                put(ProviderKind.OpenAI.rawValue, buildJsonObject {
                    put("resolveMap", buildJsonObject { put(SCHEMA_MODEL, SCHEMA_MODEL) })
                    put("models", buildJsonObject {
                        put(SCHEMA_MODEL, buildJsonObject {
                            put("transport", "openai_responses")
                            put("capabilityControls", buildJsonObject {
                                put("reasoning", buildJsonObject {
                                    put("state", "auto_available")
                                    put(
                                        "customControlRefs",
                                        JsonArray(listOf(JsonPrimitive("openai.reasoning.effort"))),
                                    )
                                })
                            })
                        })
                    })
                })
            })
        }
    }

    private fun load(path: String): String {
        val moduleDir = File(System.getProperty("user.dir") ?: ".").absoluteFile
        val root = moduleDir.parentFile!!.parentFile!!
        return File(root, path).readText(Charsets.UTF_8)
    }

    private companion object {
        const val SCHEMA_MODEL = "openai-forward-port"
        const val CONVERSATION = "1b4e28ba-2fa1-11d2-883f-0016d3cca427"
    }
}
