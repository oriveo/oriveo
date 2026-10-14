package ai.oriveo.community.feature.chat.modelcontrols

import ai.oriveo.community.R
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.EngineDeclaration
import ai.oriveo.community.core.model.ModelCapability
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderAuthMode
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.ReasoningMode
import ai.oriveo.community.core.model.RelayCapabilityOverrides
import ai.oriveo.community.core.model.RelayRequestedConfig
import ai.oriveo.community.core.model.RelayTransport
import ai.oriveo.community.core.provider.CapabilityControlPresentation
import ai.oriveo.community.core.provider.MetadataTestFixtures
import ai.oriveo.community.core.provider.relay.RelayNegativeCache
import ai.oriveo.community.feature.chat.modelcontrols.GenerationParameterRowModel.DisplayValue
import ai.oriveo.community.feature.chat.modelcontrols.GenerationParameterRowModel.Source
import ai.oriveo.community.feature.chat.modelcontrols.ModelOptionCapabilityShape.Capability
import ai.oriveo.community.feature.chat.modelcontrols.ModelOptionCapabilityShape.ConnectionCategory
import ai.oriveo.community.feature.chat.modelcontrols.ModelOptionCapabilityShape.CustomProtocol
import ai.oriveo.community.feature.chat.modelcontrols.ModelOptionsTiles.Corner
import ai.oriveo.community.feature.chat.modelcontrols.ModelOptionsTiles.FileDelivery
import ai.oriveo.community.feature.chat.modelcontrols.ModelOptionsTiles.Kind
import ai.oriveo.community.feature.chat.modelcontrols.ModelOptionsTiles.SummaryItem
import ai.oriveo.community.feature.chat.modelcontrols.ModelOptionsTiles.Vision
import java.io.File
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * Model-options capability area: the 2x2 four cards, the summary strip and the temperature row of the parameter card (BOARD-OPTIONS-01 to 10).
 * The capability-card inputs of 01 to 05 always go through the production [ModelOptionCapabilityShape.resolve], the file card through the production
 * [ModelOptionsPanelInput.fileDelivery] (internally AttachmentTransportResolver), and vision "unknown" through the production predicate.
 */
class ModelOptionsBoardStructureTest {
    private val cache = RelayNegativeCache(RelayNegativeCache.MemoryStore(), clock = { 1_000L })

    @Before
    fun setUp() {
        // Official Anthropic / Relay Anthropic use the Anthropic catalog (PDF allowlist, not native by default); Relay Gemini uses the Gemini catalog (PDF native by default).
        MetadataTestFixtures.applyRaw(
            """{"version":1,"providers":{
               "anthropic":{"resolveMap":{"$CLAUDE":"$CLAUDE"},"models":{"$CLAUDE":{"transport":"anthropic_messages","nativeFileMimes":["application/pdf"],"pdfNativeDefault":false}}},
               "gemini":{"resolveMap":{"$GEMINI":"$GEMINI"},"models":{"$GEMINI":{"nativeFileMimes":["application/pdf"],"pdfNativeDefault":true}}}}}""",
        )
    }

    @After
    fun tearDown() = MetadataTestFixtures.clear()

    private fun shape(
        capability: Capability,
        presentation: CapabilityControlPresentation,
        intents: List<String> = emptyList(),
        selected: String? = null,
        connection: ConnectionCategory = ConnectionCategory.Other,
        protocolUndecided: Boolean = false,
        customProtocol: CustomProtocol? = null,
        chatTemplateThinking: Boolean? = null,
    ) = ModelOptionCapabilityShape.resolve(
        ModelOptionCapabilityShape.Input(
            capability = capability,
            presentation = presentation,
            availableIntents = intents,
            selectedIntent = selected,
            connection = connection,
            protocolUndecided = protocolUndecided,
            customProtocol = customProtocol,
            chatTemplateThinking = chatTemplateThinking,
        ),
    )

    private fun relay(transport: RelayTransport) = Provider(
        id = "relay-1",
        kind = ProviderKind.Relay,
        baseUrlText = "https://relay.example.com/v1",
        relayRequested = RelayRequestedConfig(transport = transport),
    )

    private fun file(provider: Provider, model: AIModel, web: Boolean = false) =
        ModelOptionsPanelInput.fileDelivery(provider, model, web, ReasoningMode.Automatic, cache)

    // ── 01 to 05: five shapes ──────────────────────────────────────────────────────

    @Test
    fun `BOARD-OPTIONS-01 official BYOK gives a switch, levels, available vision and native when supported`() {
        val provider = Provider(id = "anthropic-1", kind = ProviderKind.Anthropic)
        val model = AIModel(id = CLAUDE, name = CLAUDE)
        val web = shape(Capability.Web, CapabilityControlPresentation.AutomaticAvailable, listOf("off", "automatic"), "automatic")
        val reasoning = shape(Capability.Reasoning, CapabilityControlPresentation.AutomaticAvailable, listOf("off", "low", "balanced", "deep"), "deep")
        val tiles = ModelOptionsTiles.board(
            web = web,
            reasoning = reasoning,
            vision = ModelOptionsTiles.vision(entryVisible = true, relayWithoutPositiveEvidence = ModelOptionsPanelInput.visionUnknown(provider, model)),
            file = file(provider, model),
        )
        assertEquals(listOf(Kind.Web, Kind.Reasoning, Kind.Vision, Kind.File), tiles.map { it.kind })
        assertEquals(Corner.Switch, tiles[0].corner)
        assertEquals(R.string.model_options_web_note, tiles[0].statusRes)
        assertEquals(Corner.Levels, tiles[1].corner)
        assertEquals(4, tiles[1].levelCount)
        assertEquals(R.string.reasoning_deep, tiles[1].statusRes)
        assertEquals(Corner.Check, tiles[2].corner)
        assertEquals(R.string.model_options_vision_available, tiles[2].statusRes)
        assertEquals(Corner.Check, tiles[3].corner)
        assertEquals(R.string.model_options_file_native_when_supported, tiles[3].statusRes)
    }

    @Test
    fun `BOARD-OPTIONS-02 relay gives unknown vision, text files and the chat template switch`() {
        val provider = relay(RelayTransport.OpenAIChatCompletions)
        val model = AIModel(id = "m1", name = "m1")
        val web = shape(Capability.Web, CapabilityControlPresentation.Unknown, connection = ConnectionCategory.CustomLLM, customProtocol = CustomProtocol.ChatCompletions)
        val reasoning = shape(
            Capability.Reasoning, CapabilityControlPresentation.Unknown,
            connection = ConnectionCategory.CustomLLM, customProtocol = CustomProtocol.ChatCompletions, chatTemplateThinking = true,
        )
        val tiles = ModelOptionsTiles.board(
            web = web,
            reasoning = reasoning,
            vision = ModelOptionsTiles.vision(entryVisible = true, relayWithoutPositiveEvidence = ModelOptionsPanelInput.visionUnknown(provider, model)),
            file = file(provider, model),
        )
        // Thinking is a chat-template switch: the thinking card is ordered before the web-search card.
        assertEquals(listOf(Kind.Reasoning, Kind.Web, Kind.Vision, Kind.File), tiles.map { it.kind })
        assertEquals(Corner.Switch, tiles[0].corner)
        assertEquals(R.string.model_options_template_thinking_note, tiles[0].statusRes)
        // Web search: the connection cannot do it, the status row is not tappable.
        assertEquals(Corner.None, tiles[1].corner)
        assertEquals(R.string.model_options_connection_cannot, tiles[1].statusRes)
        assertFalse(tiles[1].tappable)
        assertEquals(Corner.Question, tiles[2].corner)
        assertEquals(R.string.model_options_vision_unknown, tiles[2].statusRes)
        assertEquals(R.string.model_options_file_text, tiles[3].statusRes)
        assertEquals(Corner.Check, tiles[3].corner)
    }

    @Test
    fun `BOARD-OPTIONS-05 subscription shows notices with a way out and text files without a whitelist`() {
        val provider = Provider(id = "sub", kind = ProviderKind.OpenAI, authMode = ProviderAuthMode.Subscription)
        val model = AIModel(id = "gpt-x", name = "gpt-x")
        val tiles = ModelOptionsTiles.board(
            web = shape(Capability.Web, CapabilityControlPresentation.Unknown),
            reasoning = shape(Capability.Reasoning, CapabilityControlPresentation.Pending),
            vision = ModelOptionsTiles.vision(entryVisible = true, relayWithoutPositiveEvidence = ModelOptionsPanelInput.visionUnknown(provider, model)),
            file = file(provider, model),
        )
        assertEquals(Corner.Chevron, tiles[0].corner)
        assertEquals(R.string.model_options_not_available_yet, tiles[0].statusRes)
        assertEquals(R.string.model_options_web_not_catalogued, tiles[0].bodyRes)
        assertTrue(tiles[0].tappable)
        assertEquals(R.string.model_options_uses_model_default, tiles[1].statusRes)
        assertEquals(R.string.model_options_reasoning_not_catalogued, tiles[1].bodyRes)
        assertEquals(R.string.model_options_vision_available, tiles[2].statusRes)
        assertEquals(R.string.model_options_file_text, tiles[3].statusRes)
    }

    // ── 06 transport undecided ─────────────────────────────────────────────────────────

    @Test
    fun `BOARD-OPTIONS-06 protocol undecided keeps only the callout`() {
        val web = shape(Capability.Web, CapabilityControlPresentation.Unknown, connection = ConnectionCategory.CustomLLM, protocolUndecided = true)
        val reasoning = shape(Capability.Reasoning, CapabilityControlPresentation.Unknown, connection = ConnectionCategory.CustomLLM, protocolUndecided = true)
        assertTrue(ModelOptionsTiles.showsCalloutOnly(web, reasoning))
        // With only one transport-undecided row, the card is drawn as a callout card (callout title / body, whole card tappable); vision / files are still shown.
        val official = shape(Capability.Reasoning, CapabilityControlPresentation.AutomaticAvailable, listOf("off", "low", "deep"), "low")
        assertFalse(ModelOptionsTiles.showsCalloutOnly(web, official))
        val tile = ModelOptionsTiles.capabilityTile(Capability.Web, web)
        assertEquals(R.string.model_options_choose_protocol_first, tile.statusRes)
        assertEquals(R.string.model_options_protocol_auto_note, tile.bodyRes)
        assertTrue(tile.tappable)
        assertEquals(4, ModelOptionsTiles.board(web, official, Vision.Unknown, FileDelivery.Text).size)
    }

    // ── 07 summary strip ───────────────────────────────────────────────────────────

    @Test
    fun `BOARD-OPTIONS-07 summary lists web then thinking and is empty when nothing rewrites the request`() {
        val webOn = shape(Capability.Web, CapabilityControlPresentation.AutomaticAvailable, listOf("off", "automatic"), "automatic")
        val webOff = shape(Capability.Web, CapabilityControlPresentation.AutomaticAvailable, listOf("off", "automatic"), "off")
        val webTiming = shape(Capability.Web, CapabilityControlPresentation.AutomaticAvailable, listOf("off", "automatic", "force"), "force")
        val tiers = listOf("automatic", "off", "low", "deep")
        val deep = shape(Capability.Reasoning, CapabilityControlPresentation.AutomaticAvailable, tiers, "deep")
        val auto = shape(Capability.Reasoning, CapabilityControlPresentation.AutomaticAvailable, tiers, "automatic")
        val off = shape(Capability.Reasoning, CapabilityControlPresentation.AutomaticAvailable, tiers, "off")
        val toggleOn = shape(Capability.Reasoning, CapabilityControlPresentation.AutomaticAvailable, listOf("off", "balanced"), "balanced")
        val templateOn = shape(
            Capability.Reasoning, CapabilityControlPresentation.Unknown,
            connection = ConnectionCategory.CustomLLM, customProtocol = CustomProtocol.ChatCompletions, chatTemplateThinking = true,
        )

        assertEquals(listOf(SummaryItem.WebOn, SummaryItem.ThinkingLevel("deep")), ModelOptionsTiles.summary(webOn, deep))
        assertEquals(listOf(SummaryItem.WebOn), ModelOptionsTiles.summary(webTiming, auto))
        assertEquals(listOf(SummaryItem.ThinkingLevel("off")), ModelOptionsTiles.summary(webOff, off))
        assertEquals(listOf(SummaryItem.ThinkingOn), ModelOptionsTiles.summary(webOff, toggleOn))
        assertEquals(listOf(SummaryItem.ThinkingOn), ModelOptionsTiles.summary(webOff, templateOn))
        assertEquals(emptyList<SummaryItem>(), ModelOptionsTiles.summary(webOff, auto))
        // Copy slots: thinking "off" uses the existing tier word, the auto tier uses the Automatic key.
        assertEquals(R.string.model_control_off, SummaryItem.ThinkingLevel("off").tierRes)
        assertEquals(R.string.model_control_supplier_default, ModelOptionsRender.tierLabelRes("automatic"))
    }

    // ── 08 file tri-state ─────────────────────────────────────────────────────────

    @Test
    fun `BOARD-OPTIONS-08 file delivery follows the production route, whitelist and file negative cache`() {
        val gemini = relay(RelayTransport.GeminiGenerateContent)
        val geminiModel = AIModel(id = GEMINI, name = GEMINI)
        assertEquals(FileDelivery.PdfNative, file(gemini, geminiModel))
        val anthropic = relay(RelayTransport.AnthropicMessages)
        assertEquals(FileDelivery.NativeWhenSupported, file(anthropic, AIModel(id = CLAUDE, name = CLAUDE)))
        // Route off (Chat Completions) -> text.
        assertEquals(FileDelivery.Text, file(relay(RelayTransport.OpenAIChatCompletions), geminiModel))
        // The model is not in the catalog -> no allowlist -> text.
        assertEquals(FileDelivery.Text, file(gemini, AIModel(id = "unknown-model", name = "unknown-model")))
        // The image-output model's route cannot be determined (resolver returns empty) -> treated as text.
        assertEquals(FileDelivery.Text, file(gemini, geminiModel.copy(capabilities = listOf(ModelCapability.ImageGen))))
        // Relay file negative cache not yet expired -> text; the key is the same keyFor as the send side.
        cache.record(RelayNegativeCache.keyFor(gemini, geminiModel)!!, RelayNegativeCache.Kind.File)
        assertEquals(FileDelivery.Text, file(gemini, geminiModel))
        // All three states have a check at the top right.
        FileDelivery.entries.forEach { assertEquals(Corner.Check, ModelOptionsTiles.fileTile(it).corner) }
    }

    // ── 09 vision tri-state ─────────────────────────────────────────────────────────

    @Test
    fun `BOARD-OPTIONS-09 vision is unknown only for a visible relay model without positive evidence`() {
        val provider = relay(RelayTransport.OpenAIChatCompletions)
        val bare = AIModel(id = "m1", name = "m1")
        assertTrue(ModelOptionsPanelInput.visionUnknown(provider, bare))
        assertFalse(ModelOptionsPanelInput.visionUnknown(provider, bare.copy(relayCapabilityOverrides = RelayCapabilityOverrides(image = true))))
        assertFalse(ModelOptionsPanelInput.visionUnknown(provider, bare.copy(capabilities = listOf(ModelCapability.Text, ModelCapability.Image))))
        val engine = provider.copy(relayRequested = provider.relayRequested!!.copy(engineProfile = "llama.cpp"))
        assertFalse(ModelOptionsPanelInput.visionUnknown(engine, bare.copy(engineDeclaration = EngineDeclaration(image = true))))
        assertFalse(ModelOptionsPanelInput.visionUnknown(Provider(id = "o", kind = ProviderKind.OpenAI), bare))

        assertEquals(Vision.Hidden, ModelOptionsTiles.vision(entryVisible = false, relayWithoutPositiveEvidence = true))
        assertEquals(Vision.Unknown, ModelOptionsTiles.vision(entryVisible = true, relayWithoutPositiveEvidence = true))
        assertEquals(Vision.Available, ModelOptionsTiles.vision(entryVisible = true, relayWithoutPositiveEvidence = false))
        assertEquals(Corner.Cross, Vision.Hidden.corner)
        assertEquals(Corner.Question, Vision.Unknown.corner)
        assertEquals(Corner.Check, Vision.Available.corner)
    }

    // ── 10 parameter card ───────────────────────────────────────────────────────────

    @Test
    fun `BOARD-OPTIONS-10 temperature gets its own row and leaves the entry chips`() {
        fun row(id: String, source: Source = Source.Session, display: DisplayValue = DisplayValue.Value("0.7")) = GenerationParameterRowModel(
            id = id, titleKey = id, display = display, source = source, range = null, validationError = null,
            dropReason = null, takenOverBy = null, isEditable = true, reasoningSetInModelOptions = false, inlineVerification = null,
        )
        val rows = listOf(row("temperature"), row("top_p"), row("max_output_tokens"), row("seed"))
        val parameters = ModelOptionsTiles.parameterRows(rows)
        assertEquals("temperature", parameters.temperature?.id)
        assertEquals(listOf("top_p", "max_output_tokens"), parameters.entry.chips.map { it.id })
        assertEquals(1, parameters.entry.moreCount)
        // No temperature row means none is shown; the capsule is as before.
        val withoutTemperature = ModelOptionsTiles.parameterRows(rows.drop(1))
        assertNull(withoutTemperature.temperature)
        assertEquals(GenerationParameterRowModel.summary(rows.drop(1)), withoutTemperature.entry)
        // With no value the temperature row is still shown (using that row's existing default copy).
        val modelDecides = ModelOptionsTiles.parameterRows(listOf(row("temperature", Source.ModelDecides, DisplayValue.Fallback(GenerationParameterRowModel.FallbackKind.ModelDecides))))
        assertEquals("temperature", modelDecides.temperature?.id)
        assertTrue(modelDecides.entry.chips.isEmpty())
    }

    @Test
    fun `thinking segments draw a ray for automatic, a dash for off and bars for levels`() {
        assertEquals(ModelOptionsTiles.TierGlyph.Automatic, ModelOptionsTiles.tierGlyph("automatic"))
        assertEquals(ModelOptionsTiles.TierGlyph.Off, ModelOptionsTiles.tierGlyph("off"))
        assertEquals(ModelOptionsTiles.TierGlyph.Bars(1), ModelOptionsTiles.tierGlyph("low"))
        assertEquals(ModelOptionsTiles.TierGlyph.Bars(4), ModelOptionsTiles.tierGlyph("max"))
        val panel = source("feature/chat/modelcontrols/ModelOptionsPanel.kt")
        assertTrue("auto draws the starburst (same path as Web)", panel.contains("M7.5 1v2.2M7.5 9.8V12M2 6.5h2.2M10.8 6.5H13M3.6 2.6l1.5 1.5M9.9 8.9l1.5 1.5M11.4 2.6L9.9 4.1M5.1 8.9l-1.5 1.5"))
        assertTrue("off draws a horizontal dash", panel.contains("OffDash("))
        assertTrue("segments take their icon from the pure function", panel.contains("ModelOptionsTiles.tierGlyph("))
    }

    @Test
    fun `chat template thinking puts the thinking tile before web, otherwise web first`() {
        val web = shape(Capability.Web, CapabilityControlPresentation.Unknown, connection = ConnectionCategory.CustomLLM, customProtocol = CustomProtocol.ChatCompletions)
        val template = shape(
            Capability.Reasoning, CapabilityControlPresentation.Unknown,
            connection = ConnectionCategory.CustomLLM, customProtocol = CustomProtocol.ChatCompletions, chatTemplateThinking = false,
        )
        assertEquals(
            listOf(Kind.Reasoning, Kind.Web, Kind.Vision, Kind.File),
            ModelOptionsTiles.board(web, template, Vision.Unknown, FileDelivery.Text).map { it.kind },
        )
        // When blocked (extra request body unavailable) it is still the chat-template card, order unchanged.
        assertEquals(
            listOf(Kind.Reasoning, Kind.Web, Kind.Vision, Kind.File),
            ModelOptionsTiles.board(web, template, Vision.Unknown, FileDelivery.Text, R.string.additional_body_switch_blocked_invalid).map { it.kind },
        )
        val notice = shape(Capability.Reasoning, CapabilityControlPresentation.Unknown, connection = ConnectionCategory.CustomLLM, customProtocol = CustomProtocol.Other)
        assertEquals(
            listOf(Kind.Web, Kind.Reasoning, Kind.Vision, Kind.File),
            ModelOptionsTiles.board(web, notice, Vision.Unknown, FileDelivery.Text).map { it.kind },
        )
    }

    @Test
    fun `tiers without a selection show the shape's own trailing sentence`() {
        val alwaysThinks = shape(Capability.Reasoning, CapabilityControlPresentation.AutomaticAvailable, listOf("low", "deep"), null)
            as ModelOptionCapabilityShape.Tiers
        assertEquals(ModelOptionCapabilityShape.TrailingNote.AlwaysThinks, alwaysThinks.trailingNote)
        assertEquals(
            ModelOptionsRender.trailingNoteRes(ModelOptionCapabilityShape.TrailingNote.AlwaysThinks),
            ModelOptionsTiles.capabilityTile(Capability.Reasoning, alwaysThinks).statusRes,
        )
        assertEquals(R.string.model_options_always_thinks, ModelOptionsRender.trailingNoteRes(ModelOptionCapabilityShape.TrailingNote.AlwaysThinks))
        // When the shape has no top-right sentence (can be turned off) the model default applies.
        val withOff = shape(Capability.Reasoning, CapabilityControlPresentation.AutomaticAvailable, listOf("off", "low", "deep"), null)
            as ModelOptionCapabilityShape.Tiers
        assertNull(withOff.trailingNote)
        assertEquals(R.string.model_options_uses_model_default, ModelOptionsTiles.capabilityTile(Capability.Reasoning, withOff).statusRes)
    }

    // ── View structure ────────────────────────────────────────────────────────────

    @Test
    fun `the panel renders the board from the pure model and goes single column at large font scale`() {
        assertTrue(ModelOptionsTiles.singleColumn(fontScale = 1.5f))
        assertFalse(ModelOptionsTiles.singleColumn(fontScale = 1.3f))
        val sheet = source("feature/chat/composer/ModelControlsSheet.kt")
        val panel = source("feature/chat/modelcontrols/ModelOptionsPanel.kt")
        assertTrue(sheet.contains("ModelOptionsTiles.board("))
        assertTrue(sheet.contains("ModelOptionsTiles.summary(webShape, reasoningShape)"))
        assertTrue(sheet.contains("ModelOptionsTiles.parameterRows("))
        assertTrue("gallery visibility uses the same value as the input box", sheet.contains("imageEntryVisible"))
        assertTrue("file card takes the panel's web-search switch, tool loop is false", sheet.contains("ModelOptionsPanelInput.fileDelivery("))
        assertTrue(panel.contains("R.drawable.ph_globe_duotone") && panel.contains("R.drawable.ph_brain_duotone"))
        assertTrue(panel.contains("R.drawable.ph_eye_duotone") && panel.contains("R.drawable.ph_paperclip_duotone"))
        assertTrue(panel.contains("CapabilityPalette."))
        assertTrue(panel.contains("R.plurals.model_options_reasoning_level_count"))
        assertTrue(panel.contains("R.string.model_options_turn_summary"))
    }

    private fun source(relative: String): String {
        val prefix = "android/app/src/main/java/ai/oriveo/community/"
        val direct = File("src/main/java/ai/oriveo/community/$relative")
        if (direct.exists()) return direct.readText()
        var dir: File? = File(System.getProperty("user.dir")!!).absoluteFile
        while (dir != null) {
            val candidate = File(dir, prefix + relative)
            if (candidate.exists()) return candidate.readText()
            dir = dir.parentFile
        }
        error("cannot find $relative")
    }

    private companion object {
        const val CLAUDE = "claude-board"
        const val GEMINI = "gemini-board"
    }
}
