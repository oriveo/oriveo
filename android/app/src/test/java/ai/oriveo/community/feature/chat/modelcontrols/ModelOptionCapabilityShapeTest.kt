package ai.oriveo.community.feature.chat.modelcontrols

import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.provider.CapabilityControlPresentation
import ai.oriveo.community.core.provider.CapabilityControlPresentationResolver
import ai.oriveo.community.core.provider.CapabilityControlResolution
import ai.oriveo.community.core.provider.GenerationParameterOutboundContractTest
import ai.oriveo.community.core.provider.MetadataTestFixtures
import ai.oriveo.community.feature.chat.modelcontrols.ModelOptionCapabilityShape.Capability
import ai.oriveo.community.feature.chat.modelcontrols.ModelOptionCapabilityShape.ConnectionCategory
import ai.oriveo.community.feature.chat.modelcontrols.ModelOptionCapabilityShape.CustomProtocol
import ai.oriveo.community.feature.chat.modelcontrols.ModelOptionCapabilityShape.DisclosureStatus
import ai.oriveo.community.feature.chat.modelcontrols.ModelOptionCapabilityShape.Escape
import ai.oriveo.community.feature.chat.modelcontrols.ModelOptionCapabilityShape.Input
import ai.oriveo.community.feature.chat.modelcontrols.ModelOptionCapabilityShape.NoticeBody
import ai.oriveo.community.feature.chat.modelcontrols.ModelOptionCapabilityShape.NoticeStatus
import ai.oriveo.community.feature.chat.modelcontrols.ModelOptionCapabilityShape.ToggleKind
import ai.oriveo.community.feature.chat.modelcontrols.ModelOptionCapabilityShape.TrailingNote
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Test

/** The 12 capability cards of the design states sheet, one test per card (test names carry the card number); three more inputs come from the production resolver. */
class ModelOptionCapabilityShapeTest {
    @After
    fun tearDown() = MetadataTestFixtures.clear()

    private fun input(
        capability: Capability,
        presentation: CapabilityControlPresentation,
        intents: List<String> = emptyList(),
        selected: String? = null,
        connection: ConnectionCategory = ConnectionCategory.Other,
        rejected: Set<String> = emptySet(),
        defaultIntent: String? = null,
    ) = Input(
        capability = capability,
        presentation = presentation,
        availableIntents = intents,
        selectedIntent = selected,
        connection = connection,
        rejectedIntents = rejected,
        defaultIntent = defaultIntent,
    )

    @Test
    fun `card 01 only on and off gives a toggle`() {
        val shape = ModelOptionCapabilityShape.resolve(
            input(Capability.Reasoning, CapabilityControlPresentation.AutomaticAvailable, listOf("off", "balanced"), "balanced"),
        )
        assertEquals(ModelOptionCapabilityShape.Toggle(isOn = true), shape)
    }

    @Test
    fun `card 02 multiple tiers that can be turned off draw off first`() {
        val shape = ModelOptionCapabilityShape.resolve(
            input(Capability.Reasoning, CapabilityControlPresentation.AutomaticAvailable, listOf("off", "low", "deep", "max"), "off"),
        ) as ModelOptionCapabilityShape.Tiers
        assertEquals(listOf("off", "low", "deep", "max"), shape.tiers)
        assertEquals(true, shape.includesOff)
        assertEquals(null, shape.trailingNote)
        assertEquals("off", shape.selected)
    }

    @Test
    fun `card 03 tiers without off draw no off and say so top right`() {
        val shape = ModelOptionCapabilityShape.resolve(
            input(Capability.Reasoning, CapabilityControlPresentation.AutomaticAvailable, listOf("low", "balanced", "deep", "max"), "balanced"),
        ) as ModelOptionCapabilityShape.Tiers
        assertEquals(listOf("low", "balanced", "deep", "max"), shape.tiers)
        assertEquals(false, shape.includesOff)
        assertEquals(TrailingNote.AlwaysThinks, shape.trailingNote)
        assertEquals(ModelOptionCapabilityShape.Footnote("balanced"), shape.footnote)
    }

    @Test
    fun `card 04 no official config gives a notice with a way out`() {
        val shape = ModelOptionCapabilityShape.resolve(input(Capability.Reasoning, CapabilityControlPresentation.Unknown))
        assertEquals(
            ModelOptionCapabilityShape.Notice(NoticeStatus.FollowsModelDefault, NoticeBody.ReasoningNotCatalogued, Escape.SupportedModels),
            shape,
        )
    }

    @Test
    fun `card 05 model does not think gives one tappable row`() {
        val shape = ModelOptionCapabilityShape.resolve(input(Capability.Reasoning, CapabilityControlPresentation.Unsupported))
        assertEquals(ModelOptionCapabilityShape.Disclosure(DisclosureStatus.ModelDoesNotThink), shape)
    }

    @Test
    fun `card 06 web on adds a timing row only when the recipe supports every message`() {
        val withForce = ModelOptionCapabilityShape.resolve(
            input(Capability.Web, CapabilityControlPresentation.AutomaticAvailable, listOf("force"), "automatic"),
        )
        assertEquals(ModelOptionCapabilityShape.ToggleWithTiming(listOf("automatic", "force"), "automatic"), withForce)
        val withoutForce = ModelOptionCapabilityShape.resolve(
            input(Capability.Web, CapabilityControlPresentation.AutomaticAvailable, emptyList(), "force"),
        )
        assertEquals(ModelOptionCapabilityShape.Toggle(isOn = true), withoutForce)
    }

    @Test
    fun `card 07 web needs own configuration points to the additional body`() {
        val shape = ModelOptionCapabilityShape.resolve(input(Capability.Web, CapabilityControlPresentation.CustomOnly))
        assertEquals(
            ModelOptionCapabilityShape.Notice(NoticeStatus.NeedsOwnConfiguration, NoticeBody.WebNoGenericSwitch, Escape.AdditionalBody),
            shape,
        )
    }

    @Test
    fun `card 08 model cannot search gives one tappable row`() {
        val shape = ModelOptionCapabilityShape.resolve(input(Capability.Web, CapabilityControlPresentation.Unsupported))
        assertEquals(ModelOptionCapabilityShape.Disclosure(DisclosureStatus.ModelCannotSearch), shape)
    }

    @Test
    fun `card 10 custom connection with undecided protocol collapses into choose protocol`() {
        listOf(Capability.Web, Capability.Reasoning).forEach { capability ->
            val shape = ModelOptionCapabilityShape.resolve(
                input(capability, CapabilityControlPresentation.Unknown, connection = ConnectionCategory.CustomLLM)
                    .copy(protocolUndecided = true),
            )
            assertEquals(ModelOptionCapabilityShape.ProtocolUndecided, shape)
        }
    }

    @Test
    fun `card 11 custom chat completions connection gets a chat template thinking toggle`() {
        val base = input(Capability.Reasoning, CapabilityControlPresentation.Unknown, connection = ConnectionCategory.CustomLLM)
        assertEquals(
            ModelOptionCapabilityShape.Toggle(isOn = false, kind = ToggleKind.ChatTemplateThinking),
            ModelOptionCapabilityShape.resolve(base.copy(customProtocol = CustomProtocol.ChatCompletions, chatTemplateThinking = false)),
        )
        assertEquals(
            ModelOptionCapabilityShape.Notice(NoticeStatus.NeedsOwnConfiguration, NoticeBody.CustomThinkingUseAdditionalBody, Escape.AdditionalBody),
            ModelOptionCapabilityShape.resolve(base.copy(customProtocol = CustomProtocol.Other)),
        )
        assertEquals(
            ModelOptionCapabilityShape.Disclosure(DisclosureStatus.ConnectionCannotSearch),
            ModelOptionCapabilityShape.resolve(base.copy(capability = Capability.Web, customProtocol = CustomProtocol.ChatCompletions)),
        )
    }

    @Test
    fun `card 12 a rejected tier is removed from the segments and explained`() {
        val shape = ModelOptionCapabilityShape.resolve(
            input(
                Capability.Reasoning, CapabilityControlPresentation.AutomaticAvailable,
                listOf("low", "balanced", "deep", "max"), "max", rejected = setOf("max"), defaultIntent = "balanced",
            ),
        ) as ModelOptionCapabilityShape.Tiers
        assertEquals(listOf("low", "balanced", "deep"), shape.tiers)
        assertEquals("balanced", shape.selected)
        assertEquals(ModelOptionCapabilityShape.RejectedNotice("max", "balanced"), shape.rejected)
        assertEquals(null, shape.footnote)
    }

    @Test
    fun `recipe automatic tier is drawn first and opening never invents a selection`() {
        val shape = ModelOptionCapabilityShape.resolve(
            input(Capability.Reasoning, CapabilityControlPresentation.AutomaticAvailable, listOf("automatic", "off", "low", "deep")),
        ) as ModelOptionCapabilityShape.Tiers
        assertEquals(listOf("automatic", "off", "low", "deep"), shape.tiers)
        assertEquals(null, shape.selected)
        val toggle = ModelOptionCapabilityShape.resolve(
            input(Capability.Reasoning, CapabilityControlPresentation.AutomaticAvailable, listOf("off", "low")),
        )
        assertEquals(ModelOptionCapabilityShape.Toggle(isOn = null), toggle)
    }

    // -- inputs taken from the production resolver --

    private val anthropic = Provider(id = "anthropic-shape", kind = ProviderKind.Anthropic)
    private val officialModel = AIModel(
        id = GenerationParameterOutboundContractTest.OFFICIAL_MODEL,
        name = GenerationParameterOutboundContractTest.OFFICIAL_MODEL,
    )

    private fun production(provider: Provider, model: AIModel, capability: Capability, connection: ConnectionCategory): ModelOptionCapabilityShape {
        val key = if (capability == Capability.Web) "web" else "reasoning"
        val presentation = CapabilityControlPresentationResolver.presentation(provider, model, key)
        val intents = CapabilityControlResolution.resolve(provider, model, key).intents
        return ModelOptionCapabilityShape.resolve(Input(capability, presentation, intents, null, connection))
    }

    @Test
    fun `production official anthropic reasoning resolves to tiers with off`() {
        MetadataTestFixtures.applyRaw(GenerationParameterOutboundContractTest().officialMetadata().toString())
        val shape = production(anthropic, officialModel, Capability.Reasoning, ConnectionCategory.Other) as ModelOptionCapabilityShape.Tiers
        assertEquals(listOf("off", "low", "balanced", "deep"), shape.tiers)
        assertEquals(null, shape.selected)
    }

    @Test
    fun `production official anthropic web unavailable resolves to a disclosure`() {
        MetadataTestFixtures.applyRaw(GenerationParameterOutboundContractTest().officialMetadata().toString())
        assertEquals(
            ModelOptionCapabilityShape.Disclosure(DisclosureStatus.ModelCannotSearch),
            production(anthropic, officialModel, Capability.Web, ConnectionCategory.Other),
        )
    }
}
