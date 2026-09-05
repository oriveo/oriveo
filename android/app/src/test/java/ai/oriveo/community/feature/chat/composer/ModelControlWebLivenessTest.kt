package ai.oriveo.community.feature.chat.composer

import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.LocalCapabilityCustomFragmentStore
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.provider.CapabilityControlPresentation
import ai.oriveo.community.core.provider.CapabilityWebPreferenceLiveness
import ai.oriveo.community.core.provider.MetadataTestFixtures
import ai.oriveo.community.core.provider.ModelControlRuntimeIdentityResolver
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
 * The single source of truth for "a lit-up globe icon never lies about actually reaching the wire".
 *
 * The preference is stored per connection x model x transport, but whether it actually goes
 * out over the wire depends on the metadata in effect right now. After a recipe changes, gets
 * retired, or the transport changes, the stored `Automatic` value doesn't change at all, so the
 * panel toggle and the composer's globe icon would otherwise stay lit while the request carries
 * no web field at all. Mirrors iOS's `staleWebPreferenceStopsLightingTheGlobe` /
 * `staleWebGateIsWiredEverywhere` test by test.
 */
class ModelControlWebLivenessTest {
    private val json = Json { ignoreUnknownKeys = true; isLenient = true }

    @After
    fun tearDown() = MetadataTestFixtures.clear()

    /** The judge has exactly one pure rule: either the official automatic recipe is in effect, or a custom control has taken over. */
    @Test
    fun `only an automatic recipe or an active custom fragment reaches the wire`() {
        assertTrue(
            CapabilityWebPreferenceLiveness.reachesTheWire(
                CapabilityControlPresentation.AutomaticAvailable, customIsActive = false,
            ),
        )
        assertTrue(
            "with a custom control taking over, it still reaches the wire even without an official recipe",
            CapabilityWebPreferenceLiveness.reachesTheWire(
                CapabilityControlPresentation.Unsupported, customIsActive = true,
            ),
        )
    }

    /** The set of statuses that must stay dark. `ForceUnsupported` is dark too -- it is not the same set as `isConfigurable`. */
    @Test
    fun `every other presentation stops lighting the globe`() {
        val dark = listOf(
            CapabilityControlPresentation.ForceUnsupported,
            CapabilityControlPresentation.Pending,
            CapabilityControlPresentation.Unknown,
            CapabilityControlPresentation.Unsupported,
            CapabilityControlPresentation.ExternalConnectorOnly,
            CapabilityControlPresentation.CustomOnly,
        )
        dark.forEach { status ->
            assertFalse(
                "$status must not light up a globe that never reaches the wire",
                CapabilityWebPreferenceLiveness.reachesTheWire(status, customIsActive = false),
            )
        }
        assertEquals(
            "the dark set must cover every status except AutomaticAvailable",
            CapabilityControlPresentation.entries.size - 1,
            dark.size,
        )
        // The difference from isConfigurable must exist, or someone conflated the two into a single rule.
        assertTrue(CapabilityControlPresentation.ForceUnsupported.isConfigurable)
        assertTrue(CapabilityControlPresentation.Unknown.isConfigurable)
    }

    /**
     * Call sites outside the panel don't have a ready-made status, so the convenience overload
     * computes it live from the production source of truth -- when the official recipe says
     * "unsupported" but the user's custom field is actively taking over, the globe must still
     * light up.
     */
    @Test
    fun `the convenience overload consults the real custom fragment store`() {
        MetadataTestFixtures.applyRaw(fixture().toString())
        val provider = Provider(id = PROVIDER, kind = ProviderKind.Qwen)
        val model = AIModel(id = MODEL, name = "custom only web")
        var payload: String? = null
        val store = LocalCapabilityCustomFragmentStore(read = { payload }, write = { payload = it })

        assertFalse(
            "must stay dark when the server explicitly says unsupported and the custom control hasn't taken over either",
            CapabilityWebPreferenceLiveness.reachesTheWire(
                provider = provider, model = model, conversationID = CONVERSATION,
                customFragmentStore = store, effectiveTransport = TRANSPORT,
            ),
        )

        val identity = requireNotNull(ModelControlRuntimeIdentityResolver.resolve(provider, model))
        store.setConfiguration(
            LocalCapabilityCustomFragmentStore.Configuration(enabled = true, rawJSON = "{\"enable_search\":true}"),
            provider.id, identity.canonicalModelId, CONVERSATION, identity.storageIdentity,
            LocalCapabilityCustomFragmentStore.WEB_NAMESPACE,
        )
        assertTrue(
            "the globe must light up again once the custom control takes over",
            CapabilityWebPreferenceLiveness.reachesTheWire(
                provider = provider, model = model, conversationID = CONVERSATION,
                customFragmentStore = store, effectiveTransport = TRANSPORT,
            ),
        )

        // The judge never rewrites storage -- switching back to a usable model restores it, and the user's own input is preserved throughout.
        val before = payload
        repeat(3) {
            CapabilityWebPreferenceLiveness.reachesTheWire(
                provider = provider, model = model, conversationID = CONVERSATION,
                customFragmentStore = store, effectiveTransport = TRANSPORT,
            )
        }
        assertEquals("the liveness judge rewrote storage", before, payload)

        // Once the server withdraws this control, that JSON no longer reaches the wire (the same
        // rule used by `fragmentsByOwner` filters it out). The globe must go dark accordingly, or
        // it's another case of "lit up but not actually connected" -- and the draft is still left
        // untouched.
        MetadataTestFixtures.applyRaw(fixture(mountsWebControl = false).toString())
        assertFalse(
            "once the schema is withdrawn the custom control no longer counts as taking over, and the globe must go dark",
            CapabilityWebPreferenceLiveness.reachesTheWire(
                provider = provider, model = model, conversationID = CONVERSATION,
                customFragmentStore = store, effectiveTransport = TRANSPORT,
            ),
        )
        assertEquals("going dark must not touch storage", before, payload)
    }

    /** Structural lock: the judge itself must never contain a write call. */
    @Test
    fun `the liveness judge never writes`() {
        val source = repoFile("core/provider/CapabilityControlPresentation.kt").readText()
        val judge = source.substringAfter("object CapabilityWebPreferenceLiveness")
        assertFalse(judge.contains("setConfiguration("))
        assertFalse(judge.contains("setFragment("))
    }

    /**
     * All three consumers must wire into the same judge. A pure behavior assertion alone can't
     * catch someone reintroducing a bare `web != Off` check at one of these sites -- which is
     * exactly how the original bug was written.
     */
    @Test
    fun `the stale web gate is wired at all three consumers`() {
        val sheet = repoFile("feature/chat/composer/ModelControlsSheet.kt").readText()
        val composer = repoFile("feature/chat/composer/EnhancedComposer.kt").readText()
        val decision = repoFile("feature/chat/ChatCapabilityOutboundDecision.kt").readText()

        // 1. The panel publishes the selected state
        assertTrue(sheet.contains("CapabilityWebPreferenceLiveness.reachesTheWire("))
        assertTrue(
            "\"is web on\" published upward by the panel must go through the judge, not a bare != Off check",
            sheet.contains("onSelectionChange(\n            clamped,"),
        )
        // 2. The composer's restore state (a discrete event)
        assertTrue(composer.contains("CapabilityWebPreferenceLiveness.reachesTheWire("))
        // The restore state never folds the dark/off value into `selectedControlWeb`. That value
        // doubles as both the panel's displayed value and the write-back source for `persist()` /
        // `promoteToModelDefault()` -- if the dark value were folded in, a user who just opened the
        // panel to change a reasoning setting would have their web preference silently written as
        // "off", even though they never turned it off (mirrors iOS's `restore()`, which keeps the
        // original value and only gates in `publishSelection()`). Liveness only feeds the chip
        // highlight, the library exclusivity check, and the outbound decision below.
        assertTrue("the restore state must persist the original stored value", composer.contains("selectedControlWeb = restored.web"))
        assertTrue(composer.contains("selectedControlWeb = values.web"))
        assertFalse(
            "the dark value must never be written into the panel's display / write-back source",
            composer.contains("selectedControlWeb = if (live)"),
        )
        // 3. The explicit outbound decision
        assertTrue(decision.contains("webReachesTheWire"))
        assertTrue(
            "the explicit key check must be ANDed together with the judge",
            decision.contains("\"web\" !in dormantOwners && webReachesTheWire &&"),
        )
        assertTrue(composer.contains("webReachesTheWire = CapabilityWebPreferenceLiveness.reachesTheWire("))
    }

    /**
     * Forward-porting the custom fragment only happens on discrete events and the send path;
     * the recomposition hot path only reads the already-computed result. Forward-porting is
     * idempotent, so wiring it into recomposition would mean re-reading SharedPreferences on
     * every frame for no reason.
     */
    @Test
    fun `every production read point forward ports except the recomposition hot path`() {
        listOf(
            "feature/providers/detail/CustomRequestFieldsPage.kt",
            "feature/providers/detail/GenerationParameterDefaultsSheet.kt",
            "feature/chat/ChatSendCoordinator.kt",
            "feature/chat/composer/EnhancedComposer.kt",
            "core/provider/CapabilityControlPresentation.kt",
        ).forEach { path ->
            assertTrue(
                "$path's custom field read isn't wired to the forward-port",
                repoFile(path).readText().contains("forwardPort = "),
            )
        }

        val composer = repoFile("feature/chat/composer/EnhancedComposer.kt").readText()
        // Forward-porting is wired only into this one read, `restoredCustomOwners()`, which itself
        // is only called from two LaunchedEffects.
        assertEquals(
            "the number of call sites for the forward-port grew; go back and confirm they're all discrete events (one each from two LaunchedEffects)",
            2,
            Regex(Regex.escape("developerCustomOwners = restoredCustomOwners()")).findAll(composer).count(),
        )
        assertEquals(
            "`restoredCustomOwners` must only be defined once; the forward-port logic must never be copied a second time",
            1,
            Regex(Regex.escape("fun restoredCustomOwners()")).findAll(composer).count(),
        )
        val hotPath = composer
            .substringAfter("val outboundCapabilityDecision = ChatCapabilityOutboundDecision.resolve(")
            .substringBefore("val hasReasoningHighlight")
        assertTrue("the hot path anchor is stale; this test isn't catching anything anymore", hotPath.contains("CapabilityWebPreferenceLiveness"))
        assertFalse("the recomposition hot path must never trigger the forward-port", hotPath.contains("forwardPort"))
        assertFalse(hotPath.contains("restoredCustomOwners"))
    }

    /**
     * A coordinate where the official web recipe is absent but this connection genuinely has a
     * custom control mounted on web.
     *
     * Has to be qwen@openai_chat: of the custom controls defined anywhere, the one for web is
     * only mounted here (the other two are openai's reasoning / generation). An earlier version
     * of this fixture used openai@openai_responses, but that coordinate has no schema for web at
     * all -- "has content but no schema" never counts as taking over, so that fixture was
     * describing a state that can't actually occur in production.
     *
     * @param mountsWebControl false means the server has withdrawn the web control (the draft is
     * still there, but it can no longer be sent).
     */
    private fun fixture(mountsWebControl: Boolean = true): JsonObject {
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
                "revision" to JsonPrimitive("sha256:web-liveness"),
                "generatedAt" to JsonPrimitive("2026-08-16T00:00:00Z"),
                "controlDefinitions" to definitions,
            ),
        )
        return buildJsonObject {
            put("version", 1)
            put("capabilityRuntime", runtime)
            put("providers", buildJsonObject {
                put(ProviderKind.Qwen.rawValue, buildJsonObject {
                    put("resolveMap", buildJsonObject { put(MODEL, MODEL) })
                    put("models", buildJsonObject {
                        put(MODEL, buildJsonObject {
                            put("transport", TRANSPORT)
                            put("capabilityControls", buildJsonObject {
                                put("web", buildJsonObject {
                                    put("state", "custom_only")
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

    private fun load(path: String): String = File(repoRoot(), path).readText(Charsets.UTF_8)

    private fun repoFile(relative: String): File =
        File(File(System.getProperty("user.dir")!!), "src/main/java/ai/oriveo/community/$relative")

    private fun repoRoot(): File {
        val moduleDir = File(System.getProperty("user.dir") ?: ".").absoluteFile
        return moduleDir.parentFile!!.parentFile!!
    }

    private companion object {
        const val PROVIDER = "9a1195de-3af9-5888-abc8-b8177c458c07"
        const val MODEL = "qwen-liveness-model"
        const val TRANSPORT = "openai_chat"
        const val CONVERSATION = "1b4e28ba-2fa1-11d2-883f-0016d3cca427"
    }
}
