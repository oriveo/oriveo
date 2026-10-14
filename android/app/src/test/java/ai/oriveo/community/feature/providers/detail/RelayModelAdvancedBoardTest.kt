package ai.oriveo.community.feature.providers.detail

import ai.oriveo.community.R
import ai.oriveo.community.core.attachments.AttachmentDelivery
import ai.oriveo.community.core.attachments.NativeFileFallback
import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.data.repository.relayForcesStream
import ai.oriveo.community.core.data.repository.resolveSendModelSelection
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.Attachment
import ai.oriveo.community.core.model.AttachmentKind
import ai.oriveo.community.core.model.CapabilityEvidenceIdentity
import ai.oriveo.community.core.model.ChatRequestOptions
import ai.oriveo.community.core.model.ModelCapability
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.ReasoningMode
import ai.oriveo.community.core.model.RelayAuthMode
import ai.oriveo.community.core.model.RelayCapabilityOverrides
import ai.oriveo.community.core.model.RelayCapabilityOverridesSerializer
import ai.oriveo.community.core.model.RelayConnectionSecurityMode
import ai.oriveo.community.core.model.RelayKind
import ai.oriveo.community.core.model.RelayRequestedConfig
import ai.oriveo.community.core.model.RelayTransport
import ai.oriveo.community.core.model.RelayTransportSource
import ai.oriveo.community.core.provider.AttachmentTransportResolver
import ai.oriveo.community.core.provider.CapabilityControlResolution
import ai.oriveo.community.core.provider.MetadataTestFixtures
import ai.oriveo.community.core.provider.ProviderTestFixtures
import ai.oriveo.community.core.provider.relay.RelayCapabilityTest
import ai.oriveo.community.core.provider.relay.RelayNegativeCache
import ai.oriveo.community.core.provider.relay.buildAnthropicBody
import ai.oriveo.community.feature.chat.modelcontrols.ModelOptionsPanelInput
import ai.oriveo.community.feature.chat.modelcontrols.ModelOptionsTiles
import ai.oriveo.community.feature.providers.relay.RelayBoardProtocol
import java.io.File
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonArray
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * "Model > Advanced" page (BOARD-ADVANCED-01 to 11).
 *
 * Page structure comes from production [RelayModelAdvancedBoard.build]; the four automatic status rows call the existing criteria via [RelayCatalogCapabilityFacts].
 * -08 / -09 / -10 assertion subjects come from the production attachment route resolver and request body builder, the send-entry image generation decision, and the thinking control resolution, respectively.
 */
class RelayModelAdvancedBoardTest {
    private val json = Json { ignoreUnknownKeys = true }
    private val metadata = MetadataClient()
    private val nowSeconds = 1_760_000_000L

    @Before
    fun setUp() {
    }

    @After
    fun tearDown() {
        MetadataTestFixtures.clear()
    }

    private fun relay(
        models: List<AIModel>,
        catalog: List<AIModel> = models,
        transport: RelayTransport = RelayTransport.OpenAIChatCompletions,
    ) = Provider(
        id = "relay-advanced",
        kind = ProviderKind.Relay,
        customName = "myrelay.dev",
        baseUrlText = "https://api.myrelay.dev",
        apiKey = "sk-live-0000000000007f2a",
        relayKind = RelayKind.OpenAICompatible,
        relayRequested = RelayRequestedConfig(
            transport = transport,
            resolvedAPIBaseURL = "https://api.myrelay.dev/v1",
        ),
        models = models,
        catalogModels = catalog,
    )

    private fun local(engineProfile: String, models: List<AIModel>, channel: RelayTransport = RelayTransport.OpenAIChatCompletions) = Provider(
        id = "local-engine",
        kind = ProviderKind.Relay,
        customName = "Mac mini",
        baseUrlText = "http://127.0.0.1:8080",
        relayKind = RelayKind.OpenAICompatible,
        relayRequested = RelayRequestedConfig(
            transport = channel,
            authMode = RelayAuthMode.None,
            securityMode = RelayConnectionSecurityMode.LocalHttp,
            engineProfile = engineProfile,
            resolvedAPIBaseURL = "http://127.0.0.1:8080/v1",
        ),
        models = models,
        catalogModels = models,
    )

    private fun identity(provider: Provider) = CapabilityEvidenceIdentity(
        partitionId = "partition",
        connectionInstanceId = provider.id,
        connectionGeneration = "generation",
        credentialEpoch = "epoch",
        providerKind = provider.kind.rawValue,
        authMode = provider.authMode.rawValue,
    )

    private fun cache() = RelayNegativeCache(RelayNegativeCache.MemoryStore(), clock = { nowSeconds })

    private fun overrides(raw: String): RelayCapabilityOverrides =
        json.decodeFromString(RelayCapabilityOverridesSerializer, raw)

    private fun board(
        provider: Provider,
        model: AIModel = provider.models.first(),
        probe: RelayAdvancedProbe? = null,
        negativeCache: RelayNegativeCache = cache(),
        toolMemory: Boolean? = null,
        automaticReasoning: List<ReasoningMode> = emptyList(),
    ) = RelayModelAdvancedBoard.build(
        provider = provider,
        model = model,
        nowSeconds = nowSeconds,
        probe = probe,
        facts = RelayCatalogCapabilityFacts(
            metadata = metadata,
            negativeCache = negativeCache,
            identityFor = { identity(provider) },
            toolMemoryFor = { toolMemory },
        ),
        negativeCache = negativeCache,
        toolMemory = toolMemory,
        automaticReasoning = automaticReasoning,
    )

    private fun RelayModelAdvancedBoard.row(capability: RelayAdvancedCapability) =
        capabilities.single { it.capability == capability }

    @Test
    fun `BOARD-ADVANCED-01 page structure for relay and local connections`() {
        val model = AIModel(id = "gpt-5", name = "GPT-5")
        val remote = board(relay(listOf(model)), automaticReasoning = listOf(ReasoningMode.Automatic, ReasoningMode.Deep))
        assertEquals("GPT-5", remote.modelName)
        assertEquals("api.myrelay.dev", remote.host)
        assertEquals(
            listOf(
                RelayAdvancedSection.Protocol,
                RelayAdvancedSection.Capabilities,
                RelayAdvancedSection.Thinking,
                RelayAdvancedSection.Legend,
                RelayAdvancedSection.Footer,
            ),
            remote.sections,
        )
        assertNotNull(remote.protocol)
        assertNull(remote.channel)
        assertEquals(
            listOf(
                RelayAdvancedCapability.Image,
                RelayAdvancedCapability.File,
                RelayAdvancedCapability.ImageGeneration,
                RelayAdvancedCapability.ToolCall,
                RelayAdvancedCapability.Web,
            ),
            remote.capabilities.map { it.capability },
        )
        assertEquals(
            listOf(RelayAdvancedSource.Catalog, RelayAdvancedSource.Detected, RelayAdvancedSource.Tested, RelayAdvancedSource.User),
            remote.legend,
        )
        // In the writable state the footer reads "changes apply immediately, stored on this device only" (BOARD-ADVANCED-16).
        assertEquals(R.string.relay_model_advanced_changes_apply, remote.footnoteRes)

        val ollama = board(local("ollama", listOf(model)), automaticReasoning = listOf(ReasoningMode.Deep))
        assertEquals(
            listOf(RelayAdvancedSection.Channel, RelayAdvancedSection.Capabilities, RelayAdvancedSection.Legend, RelayAdvancedSection.Footer),
            ollama.sections,
        )
        assertNull(ollama.protocol)
        assertNull("local does not show a thinking section", ollama.thinking)
        assertEquals(R.string.relay_transport_openai_chat_completions, ollama.channel?.valueRes)
        assertFalse("single-channel engine shows no footnote", ollama.channel!!.showsHint)
        assertEquals(listOf(RelayAdvancedSource.Engine, RelayAdvancedSource.User), ollama.legend)
        assertEquals(5, ollama.capabilities.size)
        // The web row of a local engine shows unknown with no source.
        assertEquals(R.string.relay_model_advanced_unknown, ollama.row(RelayAdvancedCapability.Web).statusRes)
        assertNull(ollama.row(RelayAdvancedCapability.Web).source)

        val llama = board(local("llamacpp", listOf(model), channel = RelayTransport.LlamaCppNative))
        assertEquals(R.string.relay_transport_llamacpp_native, llama.channel?.valueRes)
        assertTrue("llama.cpp shows a footnote for its two channels", llama.channel!!.showsHint)
        assertFalse("local does not offer capability test", llama.offersCapabilityTest)
    }

    @Test
    fun `BOARD-ADVANCED-02 protocol explanation line`() {
        val following = AIModel(id = "gpt-5", name = "gpt-5")
        val provider = relay(listOf(following))
        val auto = board(provider).protocol!!
        assertEquals(RelayAdvancedProtocol.entries.toList(), auto.segments)
        assertEquals(RelayAdvancedProtocol.Auto, auto.selected)
        assertEquals(RelayBoardProtocol.Chat, auto.autoEquals)
        // BOARD-ADVANCED-14: following a selected connection yields the status "Set by you"; only an auto connection yields "Unknown, remembered after sending".
        assertEquals(RelayAdvancedProtocolStatus.SetByYou, auto.status)
        assertEquals(RelayAdvancedProtocolStatus.UnknownUntilSent, board(relay(listOf(following), transport = RelayTransport.Auto)).protocol!!.status)
        assertEquals("/v1", auto.apiRootPath)

        val observed = following.copy(relayTransport = RelayTransport.OpenAIResponses, relayTransportSource = RelayTransportSource.Observed)
        val verified = board(relay(listOf(observed)), observed).protocol!!
        assertEquals("observed counts as an automatic result, Auto is selected", RelayAdvancedProtocol.Auto, verified.selected)
        assertEquals(RelayBoardProtocol.Responses, verified.autoEquals)
        assertEquals(RelayAdvancedProtocolStatus.Verified, verified.status)

        val reachable = following.copy(relayTransport = RelayTransport.AnthropicMessages, relayTransportSource = RelayTransportSource.Reachable)
        val reachableRow = board(relay(listOf(reachable)), reachable).protocol!!
        assertEquals(RelayAdvancedProtocol.Auto, reachableRow.selected)
        assertEquals(RelayBoardProtocol.Messages, reachableRow.autoEquals)
        assertEquals(RelayAdvancedProtocolStatus.Reachable, reachableRow.status)

        val user = following.copy(relayTransport = RelayTransport.GeminiGenerateContent, relayTransportSource = RelayTransportSource.User)
        val userRow = board(relay(listOf(user)), user).protocol!!
        assertEquals(RelayAdvancedProtocol.Gemini, userRow.selected)
        assertNull("\"Auto =\" is shown only when Auto is selected", userRow.autoEquals)
        assertEquals(RelayAdvancedProtocolStatus.SetByYou, userRow.status)
        val root = requireNotNull(ai.oriveo.community.core.provider.RelayEndpointResolver.effectiveAPIRoot(relay(listOf(user)), user))
        assertEquals(java.net.URI(root).path.ifEmpty { "/" }, userRow.apiRootPath)

        val bare = relay(listOf(following)).copy(baseUrlText = "https://api.myrelay.dev", relayRequested = RelayRequestedConfig(transport = RelayTransport.LlamaCppNative))
        assertEquals("an empty path shows /", "/", board(bare, following).protocol!!.apiRootPath)
    }

    @Test
    fun `BOARD-ADVANCED-03 protocol writes and single protocol probe result`() {
        val model = AIModel(id = "o3", name = "o3", relayTransport = RelayTransport.OpenAIChatCompletions, relayTransportSource = RelayTransportSource.Reachable)
        val provider = relay(listOf(model), catalog = listOf(model, AIModel(id = "other", name = "other")))
        val chosen = RelayModelAdvancedEdits.settingTransport(provider, "o3", RelayTransport.OpenAIResponses)
        for (list in listOf(chosen.models, chosen.catalogModels)) {
            val written = list.single { it.id == "o3" }
            assertEquals(RelayTransport.OpenAIResponses, written.relayTransport)
            assertEquals(RelayTransportSource.User, written.relayTransportSource)
        }
        assertNull(chosen.catalogModels.single { it.id == "other" }.relayTransport)

        val cleared = RelayModelAdvancedEdits.settingTransport(chosen, "o3", null)
        for (list in listOf(cleared.models, cleared.catalogModels)) {
            val written = list.single { it.id == "o3" }
            assertNull(written.relayTransport)
            assertNull(written.relayTransportSource)
        }

        val user = chosen.models.single()
        val running = board(chosen, user, probe = RelayAdvancedProbe(RelayTransport.OpenAIResponses, RelayAdvancedProbe.State.Running)).protocol!!
        assertEquals(RelayAdvancedProtocolStatus.Testing, running.status)
        val passed = board(chosen, user, probe = RelayAdvancedProbe(RelayTransport.OpenAIResponses, RelayAdvancedProbe.State.Passed)).protocol!!
        assertEquals(RelayAdvancedProtocol.Responses, passed.selected)
        assertEquals(RelayAdvancedProtocolStatus.Reachable, passed.status)
        val failed = board(chosen, user, probe = RelayAdvancedProbe(RelayTransport.OpenAIResponses, RelayAdvancedProbe.State.Failed)).protocol!!
        assertEquals(RelayAdvancedProtocolStatus.NotReachable, failed.status)
        assertEquals("a failure stays user", RelayTransportSource.User, user.relayTransportSource)
        assertEquals(RelayAdvancedProtocol.Responses, failed.selected)
        val stale = board(chosen, user, probe = RelayAdvancedProbe(RelayTransport.AnthropicMessages, RelayAdvancedProbe.State.Failed)).protocol!!
        assertEquals("switching protocol invalidates the old result", RelayAdvancedProtocolStatus.SetByYou, stale.status)
    }

    @Test
    fun `BOARD-ADVANCED-04 automatic states and source order`() {
        val base = AIModel(
            id = "m",
            name = "m",
            capabilities = listOf(ModelCapability.Image, ModelCapability.ImageGen),
            nativeFileMimes = listOf("application/pdf"),
            toolCall = true,
        )
        val provider = relay(listOf(base))
        val catalog = board(provider, base)
        assertEquals(RelayAdvancedSource.Catalog, catalog.row(RelayAdvancedCapability.Image).source)
        assertEquals(RelayAdvancedSource.Catalog, catalog.row(RelayAdvancedCapability.File).source)
        assertEquals(RelayCatalogCapabilityState.Supported, catalog.row(RelayAdvancedCapability.File).state)
        assertEquals(RelayAdvancedSource.Catalog, catalog.row(RelayAdvancedCapability.ImageGeneration).source)
        assertEquals(RelayCatalogCapabilityState.Supported, catalog.row(RelayAdvancedCapability.ImageGeneration).state)
        assertEquals(RelayAdvancedSource.Catalog, catalog.row(RelayAdvancedCapability.ToolCall).source)
        assertEquals(RelayCatalogCapabilityState.Supported, catalog.row(RelayAdvancedCapability.ToolCall).state)
        assertTrue(catalog.capabilities.all { it.control == RelayAdvancedControl.Auto })

        val negative = cache()
        val key = requireNotNull(RelayNegativeCache.keyFor(provider, base))
        negative.record(key, RelayNegativeCache.Kind.File, nowSeconds)
        negative.record(key, RelayNegativeCache.Kind.ToolCall, nowSeconds)
        val detected = board(provider, base, negativeCache = negative)
        assertEquals("negative cache overrides the catalog", RelayAdvancedSource.Detected, detected.row(RelayAdvancedCapability.File).source)
        assertEquals(RelayCatalogCapabilityState.Unsupported, detected.row(RelayAdvancedCapability.File).state)
        assertEquals(RelayAdvancedSource.Detected, detected.row(RelayAdvancedCapability.ToolCall).source)

        val memory = base.copy(toolCall = null)
        assertEquals(
            "remembered tool true counts as Detected",
            RelayAdvancedSource.Detected,
            board(relay(listOf(memory)), memory, toolMemory = true).row(RelayAdvancedCapability.ToolCall).source,
        )

        val tested = base.copy(relayCapabilityOverrides = overrides("""{"image":{"value":false,"source":"tested"},"toolCall":{"value":true,"source":"user"}}"""))
        val overridden = board(relay(listOf(tested)), tested, negativeCache = negative)
        assertEquals(RelayAdvancedSource.Tested, overridden.row(RelayAdvancedCapability.Image).source)
        assertEquals(RelayCatalogCapabilityState.Unsupported, overridden.row(RelayAdvancedCapability.Image).state)
        assertEquals("tested also shows On / Off", RelayAdvancedControl.Off, overridden.row(RelayAdvancedCapability.Image).control)
        assertEquals(RelayAdvancedSource.User, overridden.row(RelayAdvancedCapability.ToolCall).source)
        assertEquals(RelayAdvancedControl.On, overridden.row(RelayAdvancedCapability.ToolCall).control)

        val engineModel = AIModel(id = "qwen", name = "qwen", engineDeclaration = ai.oriveo.community.core.model.EngineDeclaration(image = true, toolCall = false))
        val engine = board(local("ollama", listOf(engineModel)), engineModel)
        assertEquals(RelayAdvancedSource.Engine, engine.row(RelayAdvancedCapability.Image).source)
        assertEquals(RelayAdvancedSource.Engine, engine.row(RelayAdvancedCapability.ToolCall).source)
        // A local connection only draws Set by you / Tested / Engine declared: keys the engine does not declare have no source.
        val undeclared = AIModel(
            id = "llava",
            name = "llava",
            capabilities = listOf(ModelCapability.Image, ModelCapability.ImageGen),
            nativeFileMimes = listOf("application/pdf"),
            toolCall = true,
        )
        val localUndeclared = board(local("ollama", listOf(undeclared)), undeclared)
        assertNull(localUndeclared.row(RelayAdvancedCapability.File).source)
        assertNull(localUndeclared.row(RelayAdvancedCapability.ImageGeneration).source)
        assertNull(localUndeclared.row(RelayAdvancedCapability.Image).source)
        assertNull(localUndeclared.row(RelayAdvancedCapability.ToolCall).source)
        val notLocal = board(relay(listOf(engineModel)), engineModel)
        assertNull("engine declared only counts with an engineProfile", notLocal.row(RelayAdvancedCapability.Image).source)

        val bare = AIModel(id = "bare", name = "bare")
        val none = board(relay(listOf(bare)), bare)
        assertTrue(none.capabilities.all { it.source == null })
        val imageGen = none.row(RelayAdvancedCapability.ImageGeneration)
        assertEquals(RelayCatalogCapabilityState.Unknown, imageGen.state)
        assertEquals("unknown image generation uses Unknown", R.string.relay_model_advanced_unknown, imageGen.statusRes)
        assertEquals(R.string.model_options_vision_unknown, none.row(RelayAdvancedCapability.File).statusRes)
    }

    @Test
    fun `BOARD-ADVANCED-05 capability override writes`() {
        val model = AIModel(
            id = "m",
            name = "m",
            relayCapabilityOverrides = overrides("""{"image":{"value":true,"source":"tested"},"toolCall":{"value":true,"source":"tested"}}"""),
        )
        val provider = relay(listOf(model), catalog = listOf(model))
        val negative = cache()
        val key = requireNotNull(RelayNegativeCache.keyFor(provider, model))
        negative.record(key, RelayNegativeCache.Kind.Image, nowSeconds)
        negative.record(key, RelayNegativeCache.Kind.File, nowSeconds)
        negative.record(key, RelayNegativeCache.Kind.ToolCall, nowSeconds)

        val off = RelayModelAdvancedEdits.settingCapabilityOverride(provider, "m", RelayAdvancedCapability.Image, false, negative)
        for (list in listOf(off.models, off.catalogModels)) {
            val written = list.single().relayCapabilityOverrides!!
            assertEquals(false, written.image)
            assertEquals(RelayCapabilityOverrides.SOURCE_USER, written.sourceOf("image"))
            assertEquals("other keys untouched", RelayCapabilityOverrides.SOURCE_TESTED, written.sourceOf("toolCall"))
        }
        assertFalse("clears the negative cache of the same tier", negative.isRejected(key, RelayNegativeCache.Kind.Image, nowSeconds))
        assertTrue(negative.isRejected(key, RelayNegativeCache.Kind.File, nowSeconds))
        assertTrue(negative.isRejected(key, RelayNegativeCache.Kind.ToolCall, nowSeconds))

        val fileOn = RelayModelAdvancedEdits.settingCapabilityOverride(off, "m", RelayAdvancedCapability.File, true, negative)
        assertEquals(true, fileOn.models.single().relayCapabilityOverrides!!.file)
        assertFalse(negative.isRejected(key, RelayNegativeCache.Kind.File, nowSeconds))
        val generationOn = RelayModelAdvancedEdits.settingCapabilityOverride(fileOn, "m", RelayAdvancedCapability.ImageGeneration, true, negative)
        assertEquals(true, generationOn.models.single().relayCapabilityOverrides!!.imageGeneration)
        assertTrue("image generation has no tier", negative.isRejected(key, RelayNegativeCache.Kind.ToolCall, nowSeconds))

        val autoTested = RelayModelAdvancedEdits.settingCapabilityOverride(generationOn, "m", RelayAdvancedCapability.ToolCall, null, negative)
        assertNull("Auto removes tested", autoTested.models.single().relayCapabilityOverrides!!.toolCall)
        assertNull(autoTested.catalogModels.single().relayCapabilityOverrides!!.toolCall)
        assertTrue("Auto does not clear the negative cache", negative.isRejected(key, RelayNegativeCache.Kind.ToolCall, nowSeconds))
        val autoUser = RelayModelAdvancedEdits.settingCapabilityOverride(autoTested, "m", RelayAdvancedCapability.Image, null, negative)
        assertNull("Auto removes user", autoUser.models.single().relayCapabilityOverrides!!.image)
        val empty = listOf(RelayAdvancedCapability.File, RelayAdvancedCapability.ImageGeneration).fold(autoUser) { acc, capability ->
            RelayModelAdvancedEdits.settingCapabilityOverride(acc, "m", capability, null, negative)
        }
        assertNull("the whole key is omitted when nothing is left", empty.models.single().relayCapabilityOverrides)
    }

    @Test
    fun `BOARD-ADVANCED-06 thinking cells only narrow the automatic set`() {
        val automatic = listOf(ReasoningMode.Automatic, ReasoningMode.Balanced, ReasoningMode.Deep)
        val model = AIModel(id = "m", name = "m")
        val provider = relay(listOf(model))
        val full = board(provider, model, automaticReasoning = automatic).thinking as RelayAdvancedThinking.Levels
        assertEquals(ReasoningMode.entries.toList(), full.cells.map { it.mode })
        assertEquals(listOf(true, false, true, true, false), full.cells.map { it.available })
        assertEquals(listOf(true, false, true, true, false), full.cells.map { it.selected })

        val notOffered = RelayModelAdvancedEdits.toggledReasoningLevels(automatic, null, ReasoningMode.Max)
        assertNull("a cell outside the automatic set is not tappable", notOffered)
        val narrowed = RelayModelAdvancedEdits.toggledReasoningLevels(automatic, null, ReasoningMode.Automatic)
        assertEquals(listOf("balanced", "deep"), narrowed)
        val oneLeft = RelayModelAdvancedEdits.toggledReasoningLevels(automatic, listOf("deep"), ReasoningMode.Deep)
        assertEquals("the last cell cannot be deselected", listOf("deep"), oneLeft)
        val backToAll = RelayModelAdvancedEdits.toggledReasoningLevels(automatic, listOf("balanced", "deep"), ReasoningMode.Automatic)
        assertNull("selecting the full set removes the override", backToAll)

        val written = RelayModelAdvancedEdits.settingReasoningLevels(provider, "m", narrowed)
        val narrowedModel = written.models.single()
        assertEquals(listOf("balanced", "deep"), narrowedModel.relayCapabilityOverrides?.reasoningLevels)
        val cells = (board(written, narrowedModel, automaticReasoning = automatic).thinking as RelayAdvancedThinking.Levels).cells
        assertEquals(listOf(false, false, true, true, false), cells.map { it.selected })
        assertNull(RelayModelAdvancedEdits.settingReasoningLevels(written, "m", null).models.single().relayCapabilityOverrides)

        // BOARD-ADVANCED-15: no thinking card when the selectable tiers are empty.
        assertNull(board(provider, model, automaticReasoning = emptyList()).thinking)
        assertFalse(RelayAdvancedSection.Thinking in board(provider, model, automaticReasoning = emptyList()).sections)
        // On the production path the Relay automatic set comes from thinking control resolution; Relay has no recipe, so it is empty.
        val inherited = AIModel(id = "gpt-5", name = "gpt-5", capabilities = listOf(ModelCapability.Reasoning), reasoningModeAvailable = true)
        assertEquals(emptyList<ReasoningMode>(), RelayModelAdvancedBoard.automaticReasoning(relay(listOf(inherited)), inherited, metadata))
    }

    @Test
    fun `BOARD-ADVANCED-07 restore all and capability test entry live on this page`() {
        val following = AIModel(id = "m", name = "m")
        val provider = relay(listOf(following))
        assertFalse("not tappable when there is nothing to clear", board(provider).restoreAllEnabled)
        val reachable = following.copy(relayTransport = RelayTransport.OpenAIResponses, relayTransportSource = RelayTransportSource.Reachable)
        assertFalse("a reachable protocol does not count as manually set", board(relay(listOf(reachable)), reachable).restoreAllEnabled)

        val dirty = following.copy(
            relayTransport = RelayTransport.AnthropicMessages,
            relayTransportSource = RelayTransportSource.User,
            relayCapabilityOverrides = overrides(
                """{"image":{"value":true,"source":"tested"},"file":{"value":false,"source":"user"},"reasoningLevels":{"value":["deep"],"source":"user"}}""",
            ),
        )
        val dirtyProvider = relay(listOf(dirty), catalog = listOf(dirty))
        assertTrue(board(dirtyProvider, dirty).restoreAllEnabled)
        val negative = cache()
        val key = requireNotNull(RelayNegativeCache.keyFor(dirtyProvider, dirty))
        negative.record(key, RelayNegativeCache.Kind.Image, nowSeconds)
        val restored = RelayModelAdvancedEdits.restoringAllAutomatic(dirtyProvider, "m")
        for (list in listOf(restored.models, restored.catalogModels)) {
            val model = list.single()
            assertNull(model.relayCapabilityOverrides)
            assertNull(model.relayTransport)
            assertNull(model.relayTransportSource)
        }
        assertTrue("does not clear the negative cache", negative.isRejected(key, RelayNegativeCache.Kind.Image, nowSeconds))
        val keepsReachable = RelayModelAdvancedEdits.restoringAllAutomatic(relay(listOf(reachable)), "m").models.single()
        assertEquals(RelayTransport.OpenAIResponses, keepsReachable.relayTransport)

        assertEquals(RelayCapabilityTest.offersTest(provider, following), board(provider).offersCapabilityTest)
        assertTrue(board(provider).offersCapabilityTest)
        val actions = RelayModelAdvancedBoard.enabledRowActions(canSetDefault = true, canRemove = true)
        assertEquals(listOf(RelayEnabledRowMenuItem.SetDefault, RelayEnabledRowMenuItem.Remove), actions.menu)
        val rows = source("feature/providers/detail/ProviderDetailEnabledModels.kt")
        assertFalse("the row menu no longer has capability test", "R.string.relay_capability_test)" in rows)
        assertFalse("the row menu no longer has restore automatic", "R.string.relay_capability_test_restore" in rows)
        val page = source("feature/providers/detail/RelayModelAdvancedPage.kt")
        assertTrue("the capability test entry lives on this page", "R.string.relay_capability_test)" in page)
    }

    @Test
    fun `BOARD-ADVANCED-08 file override drives the production attachment route`() {
        val modelID = "claude-sonnet-4-5"
        MetadataTestFixtures.applyRaw(
            """{"version":1,"providers":{"anthropic":{"resolveMap":{"$modelID":"$modelID"},
               "models":{"$modelID":{"nativeFileMimes":[],"pdfNativeDefault":false}}}}}""",
        )
        val pdf = Attachment(
            id = "pdf",
            kind = AttachmentKind.File,
            fileName = "report.pdf",
            mimeType = "application/pdf",
            base64Data = java.util.Base64.getEncoder().encodeToString("extracted text".toByteArray()),
            extractedSizeBytes = 5_000,
            originalBase64Data = java.util.Base64.getEncoder().encodeToString("%PDF-1.7".toByteArray()),
        )
        fun model(file: Boolean?) = AIModel(
            id = modelID,
            name = modelID,
            relayTransport = RelayTransport.AnthropicMessages,
            relayTransportSource = RelayTransportSource.User,
            relayCapabilityOverrides = file?.let { overrides("""{"file":{"value":$it,"source":"user"}}""") },
        )
        fun route(model: AIModel): AttachmentDelivery.Route {
            val provider = relay(listOf(model))
            val resolved = requireNotNull(
                AttachmentTransportResolver.routesFor(provider, model, false, ReasoningMode.Automatic, toolLoopPossible = false)?.single(),
            )
            return AttachmentDelivery.plan("", listOf(pdf), resolved.model, resolved.transport).items.single().route
        }
        assertEquals("Auto: empty catalog allowlist -> text", AttachmentDelivery.Route.Text, route(model(null)))
        assertEquals("On -> native", AttachmentDelivery.Route.Native, route(model(true)))
        assertEquals("Off -> text", AttachmentDelivery.Route.Text, route(model(false)))
        val messages = listOf(
            ProviderTestFixtures.userMessage("read", ProviderKind.Relay, modelID).copy(attachments = listOf(pdf)),
        )
        val body = buildAnthropicBody(
            modelID = modelID,
            messages = messages,
            stream = true,
            reasoningMode = ReasoningMode.Automatic,
            requestOptions = ChatRequestOptions(relayRequested = relay(listOf(model(true))).relayRequested, activeModel = model(true)),
        )
        assertTrue("request body carries a native document block", "\"type\":\"document\"" in body)

        // Catalog has no model with the same name: On builds on the local model and adds PDF -> native; Off / Auto still use text.
        val unlisted = "my-private-model"
        fun unlistedModel(file: Boolean?) = model(file).copy(id = unlisted, name = unlisted)
        assertEquals("catalog miss + On -> native", AttachmentDelivery.Route.Native, route(unlistedModel(true)))
        assertEquals(AttachmentDelivery.Route.Text, route(unlistedModel(false)))
        assertEquals(AttachmentDelivery.Route.Text, route(unlistedModel(null)))

        // With Off, a non-empty catalog allowlist still goes through text.
        MetadataTestFixtures.applyRaw(
            """{"version":1,"providers":{"anthropic":{"resolveMap":{"$modelID":"$modelID"},
               "models":{"$modelID":{"nativeFileMimes":["application/pdf"],"pdfNativeDefault":true}}}}}""",
        )
        assertEquals(AttachmentDelivery.Route.Native, route(model(null)))
        assertEquals(AttachmentDelivery.Route.Text, route(model(false)))

        // The protocol envelope does not accept native files: even On can only use text.
        MetadataTestFixtures.applyRaw(
            """{"version":1,"providers":{"anthropic":{"resolveMap":{"$modelID":"$modelID"},
               "models":{"$modelID":{"nativeFileMimes":["application/pdf"],"pdfNativeDefault":true}}}},
               "relayRuntimeConfig":{"transportEnvelopes":{"anthropic_messages":{"image":true,"nativeFile":false}}}}""",
        )
        assertEquals(AttachmentDelivery.Route.Text, route(model(true)))

        // On overrides the file negative cache: the fallback memory no longer goes straight to text, and the panel does not decide text from the negative cache either.
        MetadataTestFixtures.applyRaw(
            """{"version":1,"providers":{"anthropic":{"resolveMap":{"$modelID":"$modelID"},
               "models":{"$modelID":{"nativeFileMimes":["application/pdf"],"pdfNativeDefault":true}}}}}""",
        )
        val negative = RelayNegativeCache(RelayNegativeCache.MemoryStore())
        val on = model(true)
        val provider = relay(listOf(on))
        val key = requireNotNull(RelayNegativeCache.keyFor(provider, on))
        negative.record(key, RelayNegativeCache.Kind.File)
        val lane = NativeFileFallback.Lane(provider.id, ProviderKind.Relay, RelayTransport.AnthropicMessages.value)
        val attempts = mutableListOf<Boolean>()
        runBlocking {
            NativeFileFallback.run(
                lane = lane,
                recoverable = { true },
                relayMemory = NativeFileFallback.RelayMemory(negative, key, fileOverride = on.relayCapabilityOverrides?.file),
            ) { textOnly -> attempts += textOnly }
        }
        assertEquals("On: the first send carries the native file", listOf(false), attempts)
        attempts.clear()
        runBlocking {
            NativeFileFallback.run(
                lane = lane,
                recoverable = { true },
                relayMemory = NativeFileFallback.RelayMemory(negative, key, fileOverride = null),
            ) { textOnly -> attempts += textOnly }
        }
        assertEquals("Auto: a negative cache hit goes straight to text", listOf(true), attempts)
        assertEquals(
            ModelOptionsTiles.FileDelivery.PdfNative,
            ModelOptionsPanelInput.fileDelivery(provider, on, webSearchEnabled = false, reasoningMode = ReasoningMode.Automatic, negativeCache = negative),
        )
        val auto = model(null)
        assertEquals(
            ModelOptionsTiles.FileDelivery.Text,
            ModelOptionsPanelInput.fileDelivery(relay(listOf(auto)), auto, webSearchEnabled = false, reasoningMode = ReasoningMode.Automatic, negativeCache = negative),
        )
    }

    @Test
    fun `BOARD-ADVANCED-09 image generation override drives the production dispatch`() {
        val plain = AIModel(id = "gpt-image", name = "gpt-image")
        val generator = AIModel(id = "gen", name = "gen", capabilities = listOf(ModelCapability.ImageGen))
        val forcedOn = plain.copy(relayCapabilityOverrides = overrides("""{"imageGeneration":{"value":true,"source":"user"}}"""))
        val forcedOff = generator.copy(relayCapabilityOverrides = overrides("""{"imageGeneration":{"value":false,"source":"user"}}"""))
        val provider = relay(listOf(plain, generator, forcedOn.copy(id = "on"), forcedOff.copy(id = "off")))
        assertFalse(resolveSendModelSelection(provider, "gpt-image").supportsImageGen)
        assertTrue(resolveSendModelSelection(provider, "gen").supportsImageGen)
        assertTrue("true -> image generation path", resolveSendModelSelection(provider, "on").supportsImageGen)
        assertFalse("false -> not taken, even if capabilities include image generation", resolveSendModelSelection(provider, "off").supportsImageGen)
        // The attachment route resolver's image generation precheck uses the same rule: an image generation model returns null, a non-image model resolves as usual.
        assertNull(AttachmentTransportResolver.resolve(provider, provider.models.single { it.id == "on" }, false, ReasoningMode.Automatic))
        assertNotNull(AttachmentTransportResolver.resolve(provider, provider.models.single { it.id == "off" }, false, ReasoningMode.Automatic))
        // Forced streaming uses the same rule: Responses inline image generation follows the image generation decision, and an override of false does not force it.
        val responses = RelayTransport.OpenAIResponses
        assertTrue(relayForcesStream(provider, provider.models.single { it.id == "on" }, responses))
        assertFalse(relayForcesStream(provider, provider.models.single { it.id == "off" }, responses))
        assertTrue(relayForcesStream(provider, generator, responses))
        assertFalse(relayForcesStream(provider, plain, responses))
        assertFalse(relayForcesStream(provider, null, responses))
    }

    @Test
    fun `BOARD-ADVANCED-10 reasoning override narrows the production thinking control`() {
        val model = AIModel(
            id = "gpt-5",
            name = "gpt-5",
            relayCapabilityOverrides = overrides("""{"reasoningLevels":{"value":["fast","deep"],"source":"user"}}"""),
        )
        val provider = relay(listOf(model))
        val automatic = CapabilityControlResolution.resolveAutomatic(provider, model, "reasoning", metadata)
        val resolved = CapabilityControlResolution.resolve(provider, model, "reasoning", metadata)
        // Without model-facts tiers the Relay automatic set is empty, so the intersection stays empty.
        assertEquals(automatic.intents.filter { it == "off" || it == "automatic" || it == "low" || it == "deep" }, resolved.intents)

        val offered = CapabilityControlResolution.Verdict(
            state = "auto_available",
            intents = listOf("off", "automatic", "low", "balanced", "deep"),
            rejectedIntents = setOf("balanced", "deep"),
        )
        val narrowed = CapabilityControlResolution.narrowedByRelayOverride(provider, model, "reasoning", offered)
        assertEquals("available tiers = automatic ∩ override; off and automatic do not take part in narrowing", listOf("off", "automatic", "low", "deep"), narrowed.intents)
        assertEquals(setOf("deep"), narrowed.rejectedIntents)
        assertEquals(offered, CapabilityControlResolution.narrowedByRelayOverride(provider, model, "web", offered))
        assertEquals(offered, CapabilityControlResolution.narrowedByRelayOverride(provider, model.copy(relayCapabilityOverrides = null), "reasoning", offered))
        val official = provider.copy(kind = ProviderKind.OpenAI, relayRequested = null)
        assertEquals("non-Relay does not read overrides", offered, CapabilityControlResolution.narrowedByRelayOverride(official, model, "reasoning", offered))
    }

    @Test
    fun `BOARD-ADVANCED-11 enabled board row tap opens advanced (superseded by BOARD-CATALOG-14)`() {
        // The chevron is gone: tapping the whole row opens Advanced, and starting a chat moves to the trailing "New chat" action.
        assertEquals(emptyList<RelayEnabledRowMenuItem>(), RelayModelAdvancedBoard.enabledRowActions(canSetDefault = false, canRemove = false).menu)
        val rows = source("feature/providers/detail/ProviderDetailEnabledModels.kt")
        assertFalse("no chevron", "RelayCatalogChevron(" in rows)
        assertTrue("board row taps dispatch by tapTarget", "RelayCatalogBoardModel.rowTap(model.id, boardRow.tapTarget, enabledRow = true)" in rows)
        assertTrue("tapping an official row still opens chat", ".clickable(enabled = model.isAvailable, onClick = onStartChat)" in rows)
        val screen = source("feature/providers/detail/ProviderDetailScreen.kt")
        assertTrue("the Advanced page shares the restorable layer stack with the model library", "push(RelayDetailLayer.Advanced(" in screen)
    }

    // ── Key binding section──

    private fun keyed(models: List<AIModel>, catalog: List<AIModel>) = relay(models, catalog).copy(
        relayKeys = listOf(
            ai.oriveo.community.core.model.RelayKey(id = "k1", name = "Main"),
            ai.oriveo.community.core.model.RelayKey(id = "k2", name = null, apiKey = "sk-backup-00000000beef"),
        ),
    )

    private fun keyedBoard(provider: Provider, model: AIModel, readOnly: Boolean = false) = RelayModelAdvancedBoard.build(
        provider = provider,
        model = model,
        nowSeconds = nowSeconds,
        probe = null,
        facts = RelayCatalogCapabilityFacts(metadata = metadata, negativeCache = cache(), identityFor = { identity(provider) }),
        negativeCache = cache(),
        toolMemory = null,
        automaticReasoning = emptyList(),
        readOnly = readOnly,
        family = { ai.oriveo.community.core.provider.RelayFamilyHeuristics.infer(it)?.name?.lowercase() },
    )

    @Test
    fun `BOARD-ADVANCED-12 key section with auto and every key, auto recomputes the binding rule`() {
        val target = AIModel(id = "gpt-5", name = "gpt-5", relayKeyID = "k2")
        val sibling = AIModel(id = "gpt-4o", name = "gpt-4o", relayKeyID = "k1")
        val catalog = listOf(
            AIModel(id = "gpt-5", name = "gpt-5", relayListedByKeyIDs = listOf("k1", "k2")),
            AIModel(id = "gpt-4o", name = "gpt-4o", relayListedByKeyIDs = listOf("k1", "k2")),
        )
        val provider = keyed(listOf(target, sibling), catalog)
        val board = keyedBoard(provider, target)
        assertEquals(
            listOf(RelayAdvancedSection.Protocol, RelayAdvancedSection.Key, RelayAdvancedSection.Capabilities),
            board.sections.take(3),
        )
        val section = requireNotNull(board.keySection)
        // Auto = recompute by the rule after removing this model from the enabled ones: the enabled gpt-4o of the same family uses k1.
        assertEquals("k1", section.autoKeyId)
        assertEquals(
            ai.oriveo.community.core.provider.relay.RelayKeyBinding.bind(
                listOf("k1", "k2"), catalog, listOf(sibling), "gpt-5",
                { ai.oriveo.community.core.provider.RelayFamilyHeuristics.infer(it)?.name?.lowercase() },
            ),
            section.autoKeyId,
        )
        assertEquals(RelayAdvancedKeyOption("k2", "sk-b…beef", "sk-b…beef"), section.current)
        assertFalse("current binding differs from the rule result, the menu shows that key", section.followsAuto)
        assertEquals(listOf("k1", "k2"), section.keys.map { it.keyId })
        assertEquals(listOf("Main", "sk-b…beef"), section.keys.map { it.title })
        assertTrue(section.interactive)
        assertEquals(R.string.relay_advanced_key_auto_hint, section.hintRes)
        // Selecting Auto -> the rule result key; selecting the current key writes nothing.
        assertEquals("k1", section.rebindTarget(null))
        assertNull(section.rebindTarget("k2"))
        assertEquals("k1", section.rebindTarget("k1"))

        // After rebinding to the rule result the menu shows Auto.
        val rebound = requireNotNull(ai.oriveo.community.core.provider.relay.RelayKeyBinding.rebind(provider, "gpt-5", "k1"))
        val after = requireNotNull(keyedBoard(rebound, rebound.models.first { it.id == "gpt-5" }).keySection)
        assertTrue(after.followsAuto)
        assertNull(after.rebindTarget(null))

        // A single key: no Key section.
        val single = keyedBoard(relay(listOf(target.copy(relayKeyID = null)), catalog), target.copy(relayKeyID = null))
        assertNull(single.keySection)
        assertFalse(RelayAdvancedSection.Key in single.sections)
    }

    @Test
    fun `BOARD-ADVANCED-13 read-only advanced from a catalog row`() {
        val enabled = AIModel(id = "gpt-4o", name = "gpt-4o", relayKeyID = "k2")
        val catalogModel = AIModel(id = "gpt-5", name = "gpt-5", relayListedByKeyIDs = listOf("k1", "k2"))
        val provider = keyed(listOf(enabled), listOf(catalogModel, enabled.copy(relayKeyID = null, relayListedByKeyIDs = listOf("k1", "k2"))))
        val board = keyedBoard(provider, catalogModel, readOnly = true)
        assertTrue(board.readOnly)
        assertEquals(R.string.relay_advanced_read_only_note, board.readOnlyNoteRes)
        assertFalse("read-only does not offer capability test", board.offersCapabilityTest)
        assertFalse("read-only cannot restore automatic", board.restoreAllEnabled)
        val section = requireNotNull(board.keySection)
        // Read-only: takes the rule result (the enabled gpt-4o of the same family uses k2), shows Auto, and is not operable.
        assertEquals("k2", section.autoKeyId)
        assertEquals("k2", section.current.keyId)
        assertTrue(section.followsAuto)
        assertFalse(section.interactive)
        assertNull(section.rebindTarget("k1"))

        // An editable page has no read-only note.
        val editable = keyedBoard(provider, enabled)
        assertFalse(editable.readOnly)
        assertNull(editable.readOnlyNoteRes)
        // Page: when read-only all controls are disabled and capability test is hidden (structure is driven by the board, the page turns off interaction by readOnly).
        val page = source("feature/providers/detail/RelayModelAdvancedPage.kt")
        assertTrue("the read-only note is driven by the board", "board.readOnlyNoteRes" in page)
        assertTrue("controls are disabled when read-only", "!board.readOnly" in page)
    }

    // ── Alignment (BOARD-ADVANCED-14 to 16)──

    @Test
    fun `BOARD-ADVANCED-14 protocol card explains auto and status in two lines`() {
        val unverified = AIModel(id = "gpt-5", name = "gpt-5")
        // Connection auto, model has no protocol: row 1 "Auto = <first protocol>", row 2 status "Unknown, remembered after sending".
        val auto = board(relay(listOf(unverified), transport = RelayTransport.Auto)).protocol!!
        assertEquals(RelayAdvancedProtocol.Auto, auto.selected)
        assertEquals(RelayBoardProtocol.Chat, auto.autoEquals)
        assertFalse(auto.autoFollowsConnection)
        assertEquals(RelayAdvancedProtocolStatus.UnknownUntilSent, auto.status)
        assertEquals(R.string.model_options_vision_unknown, auto.status.textRes)
        assertEquals("/v1", auto.apiRootPath)

        // Connection selected, model has no own protocol: row 1 is the follow-connection line, status Set by you.
        for (transport in listOf(RelayTransport.OpenAIChatCompletions, RelayTransport.OpenAIResponses, RelayTransport.AnthropicMessages, RelayTransport.GeminiGenerateContent)) {
            val explicit = board(relay(listOf(unverified), transport = transport)).protocol!!
            assertEquals(transport.name, RelayAdvancedProtocol.Auto, explicit.selected)
            assertEquals(transport.name, RelayBoardProtocol.of(transport), explicit.autoEquals)
            assertTrue(transport.name, explicit.autoFollowsConnection)
            assertEquals(transport.name, RelayAdvancedProtocolStatus.SetByYou, explicit.status)
        }

        // Connection selected but the model already has a detected / remembered protocol: row 1 is "Auto = model protocol", status follows the source.
        val observed = unverified.copy(relayTransport = RelayTransport.OpenAIResponses, relayTransportSource = RelayTransportSource.Observed)
        val observedRow = board(relay(listOf(observed), transport = RelayTransport.AnthropicMessages), observed).protocol!!
        assertEquals(RelayBoardProtocol.Responses, observedRow.autoEquals)
        assertFalse(observedRow.autoFollowsConnection)
        assertEquals(RelayAdvancedProtocolStatus.Verified, observedRow.status)

        // Model-set protocol: no row 1, row 2 = Set by you; the single-protocol test only changes the status word.
        val user = unverified.copy(relayTransport = RelayTransport.GeminiGenerateContent, relayTransportSource = RelayTransportSource.User)
        val userProvider = relay(listOf(user), transport = RelayTransport.Auto)
        val userRow = board(userProvider, user).protocol!!
        assertNull(userRow.autoEquals)
        assertFalse(userRow.autoFollowsConnection)
        assertEquals(RelayAdvancedProtocolStatus.SetByYou, userRow.status)
        assertEquals(
            listOf(RelayAdvancedProtocolStatus.Testing, RelayAdvancedProtocolStatus.Reachable, RelayAdvancedProtocolStatus.NotReachable),
            RelayAdvancedProbe.State.entries.map { board(userProvider, user, probe = RelayAdvancedProbe(RelayTransport.GeminiGenerateContent, it)).protocol!!.status },
        )
        assertEquals(R.string.relay_edit_status_testing, RelayAdvancedProtocolStatus.Testing.textRes)

        // The local channel card has no description.
        assertNull(board(local("ollama", listOf(unverified))).protocol)

        assertEquals("Auto = %1\$s", englishString("relay_model_advanced_auto_equals"))
        assertEquals("Auto = this connection's default protocol (%1\$s)", englishString("relay_model_advanced_auto_equals_connection"))
        assertEquals("API root %1\$s", englishString("relay_model_advanced_api_root"))
        // Two rows: row 1 only appears when Auto is selected, row 2 = status and root address.
        val page = source("feature/providers/detail/RelayModelAdvancedPage.kt")
        assertTrue("R.string.relay_model_advanced_auto_equals_connection" in page)
        assertFalse("\"Auto =\" and the status are no longer joined into one line", "row.autoEquals?.let { stringResource(R.string.relay_model_advanced_auto_equals, it.legend) },\n            stringResource(row.status.textRes)" in page)
    }

    @Test
    fun `BOARD-ADVANCED-14b auto line reads the first send protocol`() {
        val root = "https://api.myrelay.dev/v1"
        val model = AIModel(id = "claude-sonnet-4-5", name = "claude-sonnet-4-5")
        val provider = relay(listOf(model), transport = RelayTransport.Auto)
        try {
            ai.oriveo.community.core.provider.relay.RelayCatalogEndpointTypes.record(root, mapOf(model.id to listOf("anthropic", "openai")))
            val row = board(provider, model).protocol!!
            assertEquals(RelayBoardProtocol.Messages, row.autoEquals)
            assertEquals(
                RelayBoardProtocol.of(ai.oriveo.community.core.provider.relay.RelayFirstSendTransport.resolve(provider, model)),
                row.autoEquals,
            )
            assertEquals(RelayAdvancedProtocolStatus.UnknownUntilSent, row.status)
        } finally {
            ai.oriveo.community.core.provider.relay.RelayCatalogEndpointTypes.record(root, emptyMap())
        }
    }

    @Test
    fun `BOARD-ADVANCED-15 card order and the thinking card only with pickable levels`() {
        val target = AIModel(id = "gpt-5", name = "gpt-5", relayKeyID = "k1")
        val catalog = listOf(AIModel(id = "gpt-5", name = "gpt-5", relayListedByKeyIDs = listOf("k1", "k2")))
        val provider = keyed(listOf(target), catalog)
        fun sections(levels: List<ReasoningMode>, p: Provider = provider) = RelayModelAdvancedBoard.build(
            provider = p,
            model = target,
            nowSeconds = nowSeconds,
            probe = null,
            facts = RelayCatalogCapabilityFacts(metadata = metadata, negativeCache = cache(), identityFor = { identity(p) }),
            negativeCache = cache(),
            toolMemory = null,
            automaticReasoning = levels,
        ).sections
        assertEquals(
            listOf(
                RelayAdvancedSection.Protocol,
                RelayAdvancedSection.Key,
                RelayAdvancedSection.Capabilities,
                RelayAdvancedSection.Thinking,
                RelayAdvancedSection.Legend,
                RelayAdvancedSection.Footer,
            ),
            sections(listOf(ReasoningMode.Deep)),
        )
        assertEquals(
            listOf(RelayAdvancedSection.Protocol, RelayAdvancedSection.Key, RelayAdvancedSection.Capabilities, RelayAdvancedSection.Legend, RelayAdvancedSection.Footer),
            sections(emptyList()),
        )
        val oneKey = relay(listOf(target.copy(relayKeyID = null)))
        assertEquals(
            listOf(RelayAdvancedSection.Protocol, RelayAdvancedSection.Capabilities, RelayAdvancedSection.Thinking, RelayAdvancedSection.Legend, RelayAdvancedSection.Footer),
            sections(listOf(ReasoningMode.Deep), oneKey),
        )
        val ollama = board(local("ollama", listOf(target)), automaticReasoning = listOf(ReasoningMode.Deep))
        assertEquals(
            listOf(RelayAdvancedSection.Channel, RelayAdvancedSection.Capabilities, RelayAdvancedSection.Legend, RelayAdvancedSection.Footer),
            ollama.sections,
        )
        assertNull(ollama.thinking)
        assertEquals("Thinking levels you can pick in chat", englishString("relay_model_advanced_thinking_levels"))
        assertFalse("the no-tiers line leaves together with the empty thinking card", "relay_model_advanced_thinking_none" in source("feature/providers/detail/RelayModelAdvancedPage.kt"))
    }

    @Test
    fun `BOARD-ADVANCED-16 footer only in the writable page, read-only follows the connection line too`() {
        val enabled = AIModel(id = "gpt-4o", name = "gpt-4o")
        val catalogModel = AIModel(id = "gpt-5", name = "gpt-5")
        val provider = relay(listOf(enabled), catalog = listOf(enabled, catalogModel))
        val writable = board(provider, enabled)
        assertTrue(RelayAdvancedSection.Footer in writable.sections)
        assertEquals(R.string.relay_model_advanced_changes_apply, writable.footnoteRes)
        assertEquals("Changes apply right away and are saved only on this device.", englishString("relay_model_advanced_changes_apply"))
        val readOnly = RelayModelAdvancedBoard.build(
            provider = provider,
            model = catalogModel,
            nowSeconds = nowSeconds,
            probe = null,
            facts = RelayCatalogCapabilityFacts(metadata = metadata, negativeCache = cache(), identityFor = { identity(provider) }),
            negativeCache = cache(),
            toolMemory = null,
            automaticReasoning = emptyList(),
            readOnly = true,
        )
        assertFalse("read-only state shows no footer", RelayAdvancedSection.Footer in readOnly.sections)
        // Read-only + connection selected: row 1 is likewise the follow-connection line.
        assertTrue(readOnly.protocol!!.autoFollowsConnection)
        assertEquals(RelayBoardProtocol.Chat, readOnly.protocol!!.autoEquals)
        // The local writable state also shows the footer.
        assertTrue(RelayAdvancedSection.Footer in board(local("ollama", listOf(enabled))).sections)
    }

    private fun englishString(name: String): String? {
        val direct = File("src/main/res/values/strings.xml")
        val file = if (direct.exists()) direct else File("app/src/main/res/values/strings.xml")
        val doc = javax.xml.parsers.DocumentBuilderFactory.newInstance().newDocumentBuilder().parse(file)
        val nodes = doc.getElementsByTagName("string")
        for (i in 0 until nodes.length) {
            val element = nodes.item(i) as org.w3c.dom.Element
            if (element.getAttribute("name") == name) return element.textContent.replace("\\'", "'")
        }
        return null
    }

    private fun source(relative: String): String {
        val direct = File("src/main/java/ai/oriveo/community/$relative")
        if (direct.exists()) return direct.readText()
        return File("app/src/main/java/ai/oriveo/community/$relative").readText()
    }

    /**
     * RL2-WEBPROBE-15: the "Web search" row after tool calling on the advanced page capability card; status and source come from the fixture
     * `web-probe.v1.json` presentationCases `advanced`; Auto / On / Off write the web override (user source, Auto = clear), and "Restore all to Auto" clears it too.
     */
    @Test
    fun `RL2-WEBPROBE-15 advanced web row status and source per presentationCases, writes and restore`() {
        val fixture = readFixture("shared/test-fixtures/relay/web-probe.v1.json")
        val cases = fixture.getValue("presentationCases").jsonObject.getValue("cases").jsonArray.map { it.jsonObject }
        val transport = RelayTransport.OpenAIChatCompletions
        val template = ai.oriveo.community.core.provider.relay.RelayWebFragments.template(transport)!!
        val saved = kotlinx.serialization.json.buildJsonObject {
            put("web_search_options", kotlinx.serialization.json.buildJsonObject { put("search_context_size", kotlinx.serialization.json.JsonPrimitive("low")) })
        }
        assertEquals(12, cases.size)
        cases.forEach { case ->
            val caseId = case.getValue("caseId").jsonPrimitive.content
            val hasSaved = case.getValue("savedFragment").jsonPrimitive.content == "true"
            val userOverride = (case.getValue("userOverride") as? kotlinx.serialization.json.JsonPrimitive)
                ?.takeUnless { it is kotlinx.serialization.json.JsonNull }?.content?.toBooleanStrict()
            val model = AIModel(id = "m", name = "m", relayCapabilityOverrides = userOverride?.let { RelayCapabilityOverrides(web = it) })
            val provider = relay(listOf(model), transport = transport)
            val fragments = ai.oriveo.community.core.provider.relay.RelayWebFragmentStore(ai.oriveo.community.core.provider.relay.RelayWebFragmentStore.MemoryStore())
            if (hasSaved) fragments.save(provider.id, transport, saved.toString())
            val records = ai.oriveo.community.core.provider.relay.RelayWebProbeRecordStore(ai.oriveo.community.core.provider.relay.RelayWebProbeRecordStore.MemoryStore()) { 1L }
            (case["record"] as? kotlinx.serialization.json.JsonObject)?.let { record ->
                records.record(
                    ai.oriveo.community.core.provider.relay.RelayWebProbeRecordStore.Key(provider.id, model.id, transport.value),
                    ai.oriveo.community.core.provider.relay.RelayWebProbeRecord(
                        ai.oriveo.community.core.provider.relay.RelayWebProbeResult.entries.single { it.wire == record.getValue("result").jsonPrimitive.content },
                        ai.oriveo.community.core.provider.relay.RelayWebProbeSource.Tested,
                        1L,
                        if (record.getValue("fragmentHash").jsonPrimitive.content == "current") {
                            ai.oriveo.community.core.provider.relay.RelayWebProbe.fragmentHash(if (hasSaved) saved else template)
                        } else {
                            "0".repeat(64)
                        },
                    ),
                )
            }
            val negativeCache = cache()
            val row = RelayModelAdvancedBoard.build(
                provider = provider,
                model = model,
                nowSeconds = nowSeconds,
                probe = null,
                facts = RelayCatalogCapabilityFacts(metadata = metadata, negativeCache = negativeCache, identityFor = { identity(provider) }, toolMemoryFor = { null }),
                negativeCache = negativeCache,
                toolMemory = null,
                automaticReasoning = emptyList(),
                webFragments = fragments,
                webRecords = records,
            ).row(RelayAdvancedCapability.Web)
            val expect = case.getValue("expect").jsonObject.getValue("advanced").jsonObject
            val message = "RL2-WEBPROBE-15-$caseId: $row"
            assertEquals(message, expect.getValue("statusId").jsonPrimitive.content, row.webStatus?.wire)
            val source = (expect.getValue("source") as? kotlinx.serialization.json.JsonPrimitive)?.takeUnless { it is kotlinx.serialization.json.JsonNull }?.content
            assertEquals(message, source, row.source?.let { if (it == RelayAdvancedSource.User) "user" else if (it == RelayAdvancedSource.Tested) "tested" else it.name })
            assertEquals(
                message,
                when (userOverride) { true -> RelayAdvancedControl.On; false -> RelayAdvancedControl.Off; null -> RelayAdvancedControl.Auto },
                row.control,
            )
            assertEquals(message, ModelOptionsRenderStatus.of(row.webStatus!!), row.statusRes)
        }

        // The control follows the other capability rows: tested true -> On, tested false -> Off (the source is still Tested by record / override).
        listOf(true to RelayAdvancedControl.On, false to RelayAdvancedControl.Off).forEach { (value, control) ->
            val mirrored = AIModel(id = "m", name = "m", relayCapabilityOverrides = RelayCapabilityOverrides(web = value, testedKeys = setOf("web")))
            assertEquals("RL2-WEBPROBE-15 tested $value", control, board(relay(listOf(mirrored))).row(RelayAdvancedCapability.Web).control)
        }

        // Writes: On / Off write a user-source override (clearing the tested mark), Auto deletes the key; restoring all to Auto clears it too.
        val tested = AIModel(id = "m", name = "m", relayCapabilityOverrides = RelayCapabilityOverrides(web = true, testedKeys = setOf("web")))
        val provider = relay(listOf(tested))
        val off = RelayModelAdvancedEdits.settingCapabilityOverride(provider, "m", RelayAdvancedCapability.Web, false, cache())
        val offOverrides = off.models.single().relayCapabilityOverrides
        assertEquals(false, offOverrides?.web)
        assertEquals(RelayCapabilityOverrides.SOURCE_USER, offOverrides?.sourceOf("web"))
        assertEquals("a catalog model with the same id is written the same", offOverrides, off.catalogModels.single().relayCapabilityOverrides)
        val auto = RelayModelAdvancedEdits.settingCapabilityOverride(off, "m", RelayAdvancedCapability.Web, null, cache())
        assertNull(auto.models.single().relayCapabilityOverrides?.web)
        val on = RelayModelAdvancedEdits.settingCapabilityOverride(auto, "m", RelayAdvancedCapability.Web, true, cache())
        assertEquals(true, on.models.single().relayCapabilityOverrides?.web)
        assertNull(RelayModelAdvancedEdits.restoringAllAutomatic(on, "m").models.single().relayCapabilityOverrides?.web)
    }

    /** The status sentence of the advanced page web row uses the same mapping as the chat model options status line. */
    private object ModelOptionsRenderStatus {
        fun of(status: ai.oriveo.community.core.provider.relay.RelayWebChat.Status): Int =
            ai.oriveo.community.feature.chat.modelcontrols.ModelOptionsRender.relayWebStatusRes(status)
    }

    private fun readFixture(relative: String): kotlinx.serialization.json.JsonObject {
        var dir: File? = File(System.getProperty("user.dir")).absoluteFile
        while (dir != null) {
            val file = File(dir, relative)
            if (file.isFile) return json.parseToJsonElement(file.readText()).jsonObject
            dir = dir.parentFile
        }
        error("fixture not found: $relative")
    }
}
