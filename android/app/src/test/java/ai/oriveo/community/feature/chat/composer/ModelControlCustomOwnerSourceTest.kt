package ai.oriveo.community.feature.chat.composer

import ai.oriveo.community.core.model.LocalCapabilityCustomFragmentStore
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.provider.MetadataTestFixtures
import ai.oriveo.community.core.provider.ModelControlRuntimeIdentity
import ai.oriveo.community.core.provider.capabilityCustomFragmentAvailable
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
import org.junit.Test

/**
 * There must be exactly one set answering "which owners are currently taken over by a custom
 * control".
 *
 * The shape of the bug this guards against: the outbound side (`ChatSendCoordinator`) wrapped
 * `fragmentsByOwner` in a second layer of filtering via `capabilityCustomFragmentAvailable`,
 * while the restore state (composer) read `.keys` directly. Once the server withdraws a web
 * control, the panel would still show the "custom" badge, the card would still say "the
 * preference selected above won't be sent", and the globe on the chip would still be lit --
 * while the JSON for that control had already been dropped from the request and no web request
 * ever happened.
 *
 * The fix pushes the filtering down into the storage layer: `fragmentsByOwner` decides once, and
 * the UI, liveness check, and outbound path all share that single answer.
 */
class ModelControlCustomOwnerSourceTest {
    private val json = Json { ignoreUnknownKeys = true; isLenient = true }

    private val providerID = "qwen-conn"
    private val modelID = "qwen-custom-model"
    private val conversationID = "conversation-1"

    private fun identity(transport: String) = ModelControlRuntimeIdentity(
        connectionId = providerID,
        canonicalModelId = modelID,
        finalTransport = transport,
        runtimeRevision = "sha256:r1",
    )

    private fun store(): LocalCapabilityCustomFragmentStore {
        var payload: String? = null
        return LocalCapabilityCustomFragmentStore(read = { payload }, write = { payload = it })
    }

    private fun forwardPort() = LocalCapabilityCustomFragmentStore.ForwardPortContext(
        providerKind = ProviderKind.Qwen,
        schemaModelID = modelID,
        activeProfile = null,
    )

    @After
    fun tearDown() = MetadataTestFixtures.clear()

    /** When the schema is present: this web custom control both reaches the wire and should show as taken over in the UI. */
    @Test
    fun `a mounted owner is reported by the one shared set`() {
        MetadataTestFixtures.applyRaw(payload(mountsWebControl = true).toString())
        val transport = identity("openai_chat")
        assertTrue(
            "precondition: the fixture must actually mount qwen's web control",
            capabilityCustomFragmentAvailable(ProviderKind.Qwen, modelID, "openai_chat", null, "web"),
        )
        val store = store()
        store.setFragment(
            rawJSON = """{"enable_search":true}""",
            providerID = providerID,
            modelID = modelID,
            conversationID = conversationID,
            transportIdentity = transport.storageIdentity,
            namespace = LocalCapabilityCustomFragmentStore.WEB_NAMESPACE,
        )
        assertEquals(
            setOf("web"),
            store.fragmentsByOwner(
                providerID, modelID, conversationID, transport.storageIdentity, forwardPort(),
            ).keys,
        )
    }

    /**
     * When the schema is withdrawn: the same function must drop it from the set.
     *
     * The UI and the outbound path read from the same call, so this single test pins both "the
     * chip never lights up falsely" and "the card never shows a takeover that isn't real". The
     * draft itself is not deleted -- the user still needs to see and clean it up from the edit
     * page (`effectiveConfiguration` can still read it).
     */
    @Test
    fun `withdrawing the schema removes the owner from the ui and the wire at the same time`() {
        MetadataTestFixtures.applyRaw(payload(mountsWebControl = true).toString())
        val transport = identity("openai_chat")
        val store = store()
        store.setFragment(
            rawJSON = """{"enable_search":true}""",
            providerID = providerID,
            modelID = modelID,
            conversationID = conversationID,
            transportIdentity = transport.storageIdentity,
            namespace = LocalCapabilityCustomFragmentStore.WEB_NAMESPACE,
        )

        // The next metadata update from the server withdraws this control.
        MetadataTestFixtures.applyRaw(payload(mountsWebControl = false).toString())
        assertFalse(
            capabilityCustomFragmentAvailable(ProviderKind.Qwen, modelID, "openai_chat", null, "web"),
        )
        assertEquals(
            "after the schema is withdrawn the owner set must be empty -- the UI and the outbound path must never diverge again",
            emptyMap<String, String>(),
            store.fragmentsByOwner(
                providerID, modelID, conversationID, transport.storageIdentity, forwardPort(),
            ),
        )
        assertTrue(
            "the draft itself must remain, or the user loses their only way to clean it up",
            store.effectiveConfiguration(
                providerID = providerID,
                modelID = modelID,
                conversationID = conversationID,
                transportIdentity = transport.storageIdentity,
                namespace = LocalCapabilityCustomFragmentStore.WEB_NAMESPACE,
            ).rawJSON.isNotBlank(),
        )
    }

    /** A transport drift and a withdrawn schema are the same class of fact, and the filter must treat them identically. */
    @Test
    fun `a transport the owner was never mounted on is filtered out too`() {
        MetadataTestFixtures.applyRaw(payload(mountsWebControl = true).toString())
        val drifted = identity("openai_responses")
        val store = store()
        store.setFragment(
            rawJSON = """{"enable_search":true}""",
            providerID = providerID,
            modelID = modelID,
            conversationID = conversationID,
            transportIdentity = drifted.storageIdentity,
            namespace = LocalCapabilityCustomFragmentStore.WEB_NAMESPACE,
        )
        assertEquals(
            emptyMap<String, String>(),
            store.fragmentsByOwner(
                providerID, modelID, conversationID, drifted.storageIdentity, forwardPort(),
            ),
        )
    }

    /** The raw storage read (without passing forwardPort) is unchanged: storage-layer unit tests and migrations still see every record. */
    @Test
    fun `the raw storage read keeps every enabled owner`() {
        MetadataTestFixtures.applyRaw(payload(mountsWebControl = false).toString())
        val transport = identity("openai_chat")
        val store = store()
        store.setFragment(
            rawJSON = """{"enable_search":true}""",
            providerID = providerID,
            modelID = modelID,
            conversationID = conversationID,
            transportIdentity = transport.storageIdentity,
            namespace = LocalCapabilityCustomFragmentStore.WEB_NAMESPACE,
        )
        assertEquals(
            setOf("web"),
            store.fragmentsByOwner(providerID, modelID, conversationID, transport.storageIdentity).keys,
        )
    }

    /** Structural lock: the outbound side must never wrap a second layer of filtering around this, or it becomes two separate rules again. */
    @Test
    fun `no consumer re-implements the availability filter around the shared walk`() {
        val coordinator = repoFile("feature/chat/ChatSendCoordinator.kt").readText()
        assertTrue(coordinator.contains("fragmentsByOwner("))
        assertFalse(
            "the outbound side must not filter schema availability a second time on its own",
            coordinator.contains("capabilityCustomFragmentAvailable("),
        )
        val storeSource = repoFile("core/model/LocalCapabilityCustomFragmentStore.kt").readText()
        assertTrue(
            "the filtering must live in the shared traversal",
            storeSource.contains("capabilityCustomFragmentAvailable("),
        )
    }

    // -- fixtures --

    private fun payload(mountsWebControl: Boolean): JsonObject {
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
                "revision" to JsonPrimitive("sha256:custom-owner-source"),
                "generatedAt" to JsonPrimitive("2026-08-16T00:00:00Z"),
                "controlDefinitions" to definitions,
            ),
        )
        return buildJsonObject {
            put("version", 1)
            put("capabilityRuntime", runtime)
            put("providers", buildJsonObject {
                put("qwen", buildJsonObject {
                    put("resolveMap", buildJsonObject { put(modelID, modelID) })
                    put("models", buildJsonObject {
                        put(modelID, buildJsonObject {
                            put("transport", "openai_chat")
                            put("capabilityControls", buildJsonObject {
                                put("web", buildJsonObject {
                                    put("state", "auto_available")
                                    if (mountsWebControl) {
                                        put(
                                            "customControlRefs",
                                            JsonArray(listOf(JsonPrimitive("qwen.web.enable_search"))),
                                        )
                                    }
                                })
                            })
                        })
                    })
                })
            })
        }
    }

    private fun load(relative: String): String = repoRoot().resolve(relative).readText()

    private fun repoRoot(): File {
        var dir = File(System.getProperty("user.dir")!!).absoluteFile
        while (true) {
            if (File(dir, "shared/model-contracts").isDirectory) return dir
            dir = dir.parentFile ?: error("repo root not found")
        }
    }

    private fun repoFile(relative: String): File =
        repoRoot().resolve("android/app/src/main/java/ai/oriveo/community/$relative")
}
