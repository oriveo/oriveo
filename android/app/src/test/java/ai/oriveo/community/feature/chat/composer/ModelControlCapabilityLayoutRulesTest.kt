package ai.oriveo.community.feature.chat.composer

import ai.oriveo.community.R
import ai.oriveo.community.core.model.CapabilityWebPreference
import ai.oriveo.community.core.provider.CapabilityControlPresentation
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The contract behind three pure layout functions: the web-search card, the
 * reasoning card, and the capability footer.
 *
 * The only rule that matters: there is no such category as a "grayed-out option"
 * in this UI. Whatever is selectable renders as selectable; whatever isn't
 * degrades to a single status line, and that line still responds to a tap --
 * tapping it gives a reason and a way out. In particular:
 * - a missing tier is not rendered at all, not grayed out in place with a
 *   persistent reason;
 * - there is no separate "deep thinking" toggle plus a flat tier list -- `off`
 *   is just the first pill in the row;
 * - the top tier is not a secondary entry -- it's an ordinary pill like the rest;
 * - web search is one switch plus, only when the recipe actually declares force,
 *   two timing pills -- not two persistent tiers with an optional third;
 * - unknown/pending states degrade to an honest status row rather than keeping
 *   a toggle with an escape-hatch caption that can never take effect.
 */
class ModelControlCapabilityLayoutRulesTest {

    private fun reasoning(
        status: CapabilityControlPresentation = CapabilityControlPresentation.AutomaticAvailable,
        intents: List<String> = listOf("off", "low", "balanced", "deep", "max"),
        selected: String? = null,
        editable: Boolean = true,
        hasCustomSchema: Boolean = true,
    ) = ModelControlReasoningLayout.layout(status, intents, selected, editable, hasCustomSchema)

    private fun web(
        status: CapabilityControlPresentation = CapabilityControlPresentation.AutomaticAvailable,
        intents: List<String> = emptyList(),
        selection: CapabilityWebPreference = CapabilityWebPreference.Off,
        editable: Boolean = true,
        hasCustomSchema: Boolean = true,
    ) = ModelControlWebLayout.layout(status, intents, selection, editable, hasCustomSchema)

    // ── Reasoning pill row ───────────────────────────────────────────────────

    /** "automatic" is a pseudo intent; the tier order is frozen. */
    @Test
    fun `the automatic pseudo intent and the tier order are frozen`() {
        assertEquals("automatic", ModelControlReasoningLayout.AUTOMATIC_INTENT)
        assertEquals(listOf("off", "low", "balanced", "deep", "max"), ModelControlReasoningLayout.tierOrder)
    }

    /**
     * Only tiers the recipe actually declares are rendered, with "automatic"
     * always present right after `off`. A missing tier is not rendered at all --
     * a row of unclickable gray pills can't answer "would another model help",
     * and that question is left to the status row's escape hatch instead.
     */
    @Test
    fun `the pill row only renders declared tiers with automatic always present`() {
        assertEquals(
            listOf("off", "automatic", "balanced"),
            reasoning(intents = listOf("off", "balanced")).options.map { it.id },
        )
        // When off isn't declared it's simply absent from the list, not grayed out.
        assertEquals(
            listOf("automatic", "deep", "max"),
            reasoning(intents = listOf("deep", "max")).options.map { it.id },
        )
        // No pill may carry "unavailable" semantics: the data model has no such field.
        assertEquals(
            listOf(R.string.model_control_off, R.string.model_control_supplier_default, R.string.reasoning_balanced),
            reasoning(intents = listOf("off", "balanced")).options.map { it.labelRes },
        )
    }

    /** "automatic" is the default selection; a stale tier no longer in the recipe falls back to it. */
    @Test
    fun `automatic is the default selection and a stale tier falls back to it`() {
        assertEquals("automatic", reasoning(intents = listOf("off", "balanced")).selection)
        assertEquals("deep", reasoning(intents = listOf("deep"), selected = "deep").selection)
        assertEquals(
            "a stale max no longer in the recipe falls back to automatic instead of leaving nothing highlighted",
            "automatic",
            reasoning(intents = listOf("low", "balanced"), selected = "max").selection,
        )
    }

    /** The caption follows the tier that's actually in effect; every tier has its own distinct sentence. */
    @Test
    fun `the caption follows the selected tier and every tier has its own sentence`() {
        assertEquals(
            R.string.model_control_reasoning_note_automatic,
            reasoning(intents = listOf("off", "low")).selectedAnnotationRes,
        )
        assertEquals(
            R.string.model_control_reasoning_note_fast,
            reasoning(intents = listOf("off", "low"), selected = "low").selectedAnnotationRes,
        )
        val notes = listOf("off", "automatic", "low", "balanced", "deep", "max")
            .map(ModelControlReasoningLayout::captionRes)
        assertEquals("the six tiers must map to six distinct string resources", 6, notes.toSet().size)
        assertTrue(notes.all { it != null })
        assertNull("an unknown intent must not get a made-up caption", ModelControlReasoningLayout.captionRes("nonsense"))
    }

    /** The only footnote left is the one about not being able to turn thinking off. */
    @Test
    fun `the only footnote left is the one about not being able to turn thinking off`() {
        assertNull(reasoning(intents = listOf("off", "balanced")).footnoteRes)
        assertEquals(
            R.string.model_control_reasoning_off_unavailable,
            reasoning(intents = listOf("low", "balanced")).footnoteRes,
        )
    }

    // ── Reasoning status row ─────────────────────────────────────────────────

    /** Unsupported gets a status row, a reason, and a real way out: pick another model. */
    @Test
    fun `an unsupported reasoning capability explains itself and offers another model`() {
        listOf(
            CapabilityControlPresentation.Unsupported,
            CapabilityControlPresentation.ExternalConnectorOnly,
        ).forEach { status ->
            val layout = reasoning(status = status)
            assertEquals(ModelControlReasoningLayout.Form.StatusRow, layout.form)
            assertEquals(R.string.model_control_not_supported_by_model, layout.statusTextRes)
            assertEquals(R.string.model_control_capability_unavailable_here, layout.explanationRes)
            assertEquals(ModelControlCapabilityEscape.SupportedModels, layout.escape)
        }
    }

    /** Custom-only branches on whether a schema really exists -- sending the user into advanced settings with no schema is a dead end. */
    @Test
    fun `custom only branches on whether a schema really exists`() {
        assertEquals(
            ModelControlCapabilityEscape.AdvancedSettings,
            reasoning(status = CapabilityControlPresentation.CustomOnly, hasCustomSchema = true).escape,
        )
        assertEquals(
            ModelControlCapabilityEscape.SupportedModels,
            reasoning(status = CapabilityControlPresentation.CustomOnly, hasCustomSchema = false).escape,
        )
        assertEquals(
            ModelControlCapabilityEscape.AdvancedSettings,
            web(status = CapabilityControlPresentation.CustomOnly, hasCustomSchema = true).escape,
        )
        assertEquals(
            ModelControlCapabilityEscape.SupportedModels,
            web(status = CapabilityControlPresentation.CustomOnly, hasCustomSchema = false).escape,
        )
    }

    /**
     * Unknown/pending reasoning has no escape-hatch toggle. Without a recipe there
     * is no outbound field to compile, so offering a switch would just let the
     * user tap a control that can never take effect.
     */
    @Test
    fun `pending and unknown reasoning degrade to an honest status row with no escape hatch`() {
        listOf(CapabilityControlPresentation.Pending, CapabilityControlPresentation.Unknown).forEach { status ->
            val layout = reasoning(status = status)
            assertEquals(ModelControlReasoningLayout.Form.StatusRow, layout.form)
            assertTrue("no tier may be rendered", layout.options.isEmpty())
            assertEquals(R.string.model_control_cannot_adjust_yet, layout.statusTextRes)
            assertEquals(R.string.model_control_reasoning_no_official_config, layout.explanationRes)
            assertEquals(ModelControlCapabilityEscape.SupportedModels, layout.escape)
        }
    }

    /** A read-only reasoning card shows the current tier, not a generic "unavailable" line -- what the user set must stay visible. */
    @Test
    fun `a read only reasoning card shows the current tier, not a generic unavailable line`() {
        val layout = reasoning(selected = "deep", editable = false)
        assertEquals(ModelControlReasoningLayout.Form.StatusRow, layout.form)
        assertEquals(R.string.reasoning_deep, layout.statusTextRes)
        assertNull(layout.explanationRes)
        assertEquals(ModelControlCapabilityEscape.None, layout.escape)
        assertEquals(
            "shows \"automatic\" when nothing has ever been selected",
            R.string.model_control_supplier_default,
            reasoning(editable = false).statusTextRes,
        )
    }

    /**
     * An automatic configuration can still list zero tiers in production (for
     * example `openAI/gpt-5-pro` only accepts high). That status line is already
     * a complete sentence on its own, so it deliberately has no alert -- tapping
     * through to repeat the same sentence would add nothing.
     */
    @Test
    fun `a fixed single tier model says so and is deliberately not tappable`() {
        val layout = reasoning(intents = emptyList())
        assertEquals(ModelControlReasoningLayout.Form.StatusRow, layout.form)
        assertEquals(R.string.model_control_reasoning_fixed_level, layout.statusTextRes)
        assertNull("a fixed single tier is a deliberate exception and gets no alert", layout.explanationRes)
        assertEquals(ModelControlCapabilityEscape.None, layout.escape)
    }

    // ── Web search ───────────────────────────────────────────────────────────

    /** A writable, automatically-available state is one switch plus one persistent caption; both automatic and force count as on. */
    @Test
    fun `the web card is a switch whose caption is always present`() {
        val off = web(selection = CapabilityWebPreference.Off)
        assertEquals(ModelControlWebLayout.Form.Toggle, off.form)
        assertFalse(off.isOn)
        assertEquals(R.string.model_control_web_switch_note, off.captionRes)

        assertTrue(web(selection = CapabilityWebPreference.Automatic).isOn)
        assertTrue(web(intents = listOf("force"), selection = CapabilityWebPreference.Force).isOn)
    }

    /** The two timing pills only appear when the switch is on and the recipe actually declares force; the wording is frozen. */
    @Test
    fun `the timing pills appear only when force is declared and the switch is on`() {
        assertTrue("nothing renders when force isn't declared", web(selection = CapabilityWebPreference.Automatic).timingOptions.isEmpty())
        assertTrue(
            "timing doesn't apply while the switch is off",
            web(intents = listOf("force"), selection = CapabilityWebPreference.Off).timingOptions.isEmpty(),
        )
        val on = web(intents = listOf("force"), selection = CapabilityWebPreference.Automatic)
        assertEquals(
            listOf(CapabilityWebPreference.Automatic.name, CapabilityWebPreference.Force.name),
            on.timingOptions.map { it.id },
        )
        assertEquals(
            listOf(
                R.string.model_control_web_search_when_needed,
                R.string.model_control_web_search_every_message,
            ),
            on.timingOptions.map { it.labelRes },
        )
    }

    /** The timing selection is derived from the stored preference, and the status-row form resolves to the same value. */
    @Test
    fun `the timing selection is derived from the stored preference in both forms`() {
        assertEquals(
            CapabilityWebPreference.Force.name,
            web(intents = listOf("force"), selection = CapabilityWebPreference.Force).timingSelection,
        )
        assertEquals(
            CapabilityWebPreference.Automatic.name,
            web(selection = CapabilityWebPreference.Off).timingSelection,
        )
        assertEquals(
            CapabilityWebPreference.Automatic.name,
            web(status = CapabilityControlPresentation.Unsupported, selection = CapabilityWebPreference.Off)
                .timingSelection,
        )
    }

    /**
     * The clamp only narrows the selection when an official automatic
     * configuration actually exists. Rewriting a saved selection before the
     * snapshot has even arrived (pending/unknown) would turn "we don't know yet"
     * into "you never chose".
     */
    @Test
    fun `a stale force is clamped only where the recipe is authoritative`() {
        assertEquals(
            CapabilityWebPreference.Automatic,
            ModelControlWebLayout.clamp(
                CapabilityWebPreference.Force, CapabilityControlPresentation.AutomaticAvailable, emptyList(),
            ),
        )
        assertEquals(
            CapabilityWebPreference.Force,
            ModelControlWebLayout.clamp(
                CapabilityWebPreference.Force,
                CapabilityControlPresentation.AutomaticAvailable,
                listOf("force"),
            ),
        )
        listOf(
            CapabilityControlPresentation.CustomOnly,
            CapabilityControlPresentation.Pending,
            CapabilityControlPresentation.ExternalConnectorOnly,
            CapabilityControlPresentation.Unsupported,
            CapabilityControlPresentation.Unknown,
        ).forEach { status ->
            assertEquals(
                "the snapshot hasn't arrived under $status, so the user's selection must not be rewritten",
                CapabilityWebPreference.Force,
                ModelControlWebLayout.clamp(CapabilityWebPreference.Force, status, emptyList()),
            )
        }
        // Any selection other than force passes through unchanged.
        listOf(CapabilityWebPreference.Off, CapabilityWebPreference.Automatic, CapabilityWebPreference.Custom)
            .forEach { selection ->
                assertEquals(
                    selection,
                    ModelControlWebLayout.clamp(
                        selection, CapabilityControlPresentation.AutomaticAvailable, emptyList(),
                    ),
                )
            }
    }

    /** The clamped result is exposed through `effectiveSelection` so the caller writes it back on the next persist. */
    @Test
    fun `the clamped preference is exposed for write back`() {
        assertEquals(
            CapabilityWebPreference.Automatic,
            web(selection = CapabilityWebPreference.Force).effectiveSelection,
        )
        assertEquals(
            CapabilityWebPreference.Force,
            web(intents = listOf("force"), selection = CapabilityWebPreference.Force).effectiveSelection,
        )
    }

    /**
     * The web-search escape-hatch toggle is gone too. Without a recipe the client
     * can't compile any web-search field at all, so flipping that switch on would
     * produce a byte-for-byte identical request to leaving it off -- the user
     * would see it stay "on" while every message still skipped web search.
     */
    @Test
    fun `pending and unknown web degrade to a status row instead of a lying switch`() {
        listOf(CapabilityControlPresentation.Pending, CapabilityControlPresentation.Unknown).forEach { status ->
            val layout = web(status = status)
            assertEquals(ModelControlWebLayout.Form.StatusRow, layout.form)
            assertEquals(R.string.model_control_cannot_adjust_yet, layout.statusTextRes)
            assertEquals(R.string.model_control_web_no_official_config, layout.explanationRes)
            assertEquals(ModelControlCapabilityEscape.SupportedModels, layout.escape)
            assertNull("the status-row form has no caption", layout.captionRes)
        }
    }

    /** Unsupported and read-only each take their own distinct shape. */
    @Test
    fun `unsupported and read only web cards each take their own shape`() {
        val unsupported = web(status = CapabilityControlPresentation.Unsupported)
        assertEquals(R.string.model_control_not_supported_by_model, unsupported.statusTextRes)
        assertEquals(R.string.model_control_web_no_official_config, unsupported.explanationRes)
        assertEquals(ModelControlCapabilityEscape.SupportedModels, unsupported.escape)

        // Read-only shows the current value using the same wording as the pill -- one value, one name.
        assertEquals(
            R.string.model_control_web_search_when_needed,
            web(selection = CapabilityWebPreference.Automatic, editable = false).statusTextRes,
        )
        assertEquals(
            R.string.model_control_web_search_every_message,
            web(intents = listOf("force"), selection = CapabilityWebPreference.Force, editable = false).statusTextRes,
        )
        assertEquals(
            R.string.model_control_off,
            web(selection = CapabilityWebPreference.Off, editable = false).statusTextRes,
        )
    }

    /** The tier id and the wire enum convert through exactly one place; the UI must not duplicate that `when`. */
    @Test
    fun `tier ids round trip to the wire enum through exactly one converter`() {
        CapabilityWebPreference.entries.forEach { preference ->
            assertEquals(preference, ModelControlWebLayout.preferenceFor(preference.name))
        }
        assertEquals(CapabilityWebPreference.Off, ModelControlWebLayout.preferenceFor("nonsense"))
    }

    // ── Capability footer ────────────────────────────────────────────────────

    private fun footer(
        context: ModelControlCapabilityFooter.Context = ModelControlCapabilityFooter.Context.PanelCard,
        overridden: Boolean = false,
        readOnlyReasonRes: Int? = null,
        isConfigurable: Boolean = true,
        statusTextRes: Int? = R.string.model_control_capability_unavailable_here,
        upstreamRejected: Boolean = false,
        riskTiers: List<String> = emptyList(),
        showsSupportedModelsAction: Boolean = false,
        hasCandidates: Boolean = true,
        showsAdvancedSettingsAction: Boolean = false,
        statusRowEscape: ModelControlCapabilityEscape = ModelControlCapabilityEscape.None,
    ) = ModelControlCapabilityFooter.entries(
        ModelControlCapabilityFooter.Input(
            context = context,
            overridden = overridden,
            readOnlyReasonRes = readOnlyReasonRes,
            isConfigurable = isConfigurable,
            statusTextRes = statusTextRes,
            upstreamRejected = upstreamRejected,
            riskTiers = riskTiers,
            showsSupportedModelsAction = showsSupportedModelsAction,
            hasSupportedModelCandidates = hasCandidates,
            showsAdvancedSettingsAction = showsAdvancedSettingsAction,
            statusRowEscape = statusRowEscape,
        ),
    )

    /** In the ordinary case (writable, configurable, no risk) the footer is empty in both contexts. */
    @Test
    fun `the footer is empty in the ordinary case`() {
        assertEquals(emptyList<ModelControlCapabilityFooter.Entry>(), footer())
        assertEquals(
            emptyList<ModelControlCapabilityFooter.Entry>(),
            footer(context = ModelControlCapabilityFooter.Context.BehaviorPageHeader),
        )
    }

    /** The custom-override note swallows both the read-only and status notes -- being overridden is the stronger fact. */
    @Test
    fun `the overridden note swallows the read only and status sentences`() {
        val entries = footer(
            overridden = true,
            readOnlyReasonRes = R.string.model_control_context_unavailable,
            isConfigurable = false,
            context = ModelControlCapabilityFooter.Context.BehaviorPageHeader,
        )
        assertEquals(
            listOf(
                ModelControlCapabilityFooter.Entry.Note(
                    R.string.model_control_custom_fields_active_note,
                    ModelControlCapabilityFooter.NoteIcon.CustomFields,
                    ModelControlCapabilityFooter.Tone.Warning,
                ),
            ),
            entries,
        )
    }

    /** The read-only reason and status sentence appear only in the advanced-settings page header -- the panel card's status row already said it once. */
    @Test
    fun `the panel card never repeats what the status row already said`() {
        assertEquals(
            emptyList<ModelControlCapabilityFooter.Entry>(),
            footer(readOnlyReasonRes = R.string.model_control_context_unavailable, isConfigurable = false),
        )
        assertEquals(
            listOf(
                ModelControlCapabilityFooter.Entry.Note(
                    R.string.model_control_context_unavailable,
                    ModelControlCapabilityFooter.NoteIcon.Lock,
                    ModelControlCapabilityFooter.Tone.Tertiary,
                ),
            ),
            footer(
                readOnlyReasonRes = R.string.model_control_context_unavailable,
                isConfigurable = false,
                context = ModelControlCapabilityFooter.Context.BehaviorPageHeader,
            ),
        )
        // A purely informational note has no icon: one sentence, one bullet; three sentences, three bullets.
        val statusOnly = footer(
            isConfigurable = false,
            context = ModelControlCapabilityFooter.Context.BehaviorPageHeader,
        ).single() as ModelControlCapabilityFooter.Entry.Note
        assertEquals(R.string.model_control_capability_unavailable_here, statusOnly.textRes)
        assertNull(statusOnly.icon)
    }

    /** If the upstream really rejected the request, say so plainly -- that beats any metadata we're guessing at. */
    @Test
    fun `an upstream rejection is always reported`() {
        assertTrue(
            footer(upstreamRejected = true).contains(
                ModelControlCapabilityFooter.Entry.Note(
                    R.string.model_control_upstream_rejected,
                    ModelControlCapabilityFooter.NoteIcon.UpstreamRejected,
                    ModelControlCapabilityFooter.Tone.Warning,
                ),
            ),
        )
    }

    /**
     * Risk semantics belong to the custom JSON fields, not to the capability
     * itself. Attaching them to the panel card while custom fields are disabled
     * leaves the user reading a warning with no subject -- the reasoning card
     * once permanently showed "this field may increase the provider's charge"
     * on a card that had no field at all.
     */
    @Test
    fun `risk notes stay with the custom fields context`() {
        assertEquals(
            emptyList<ModelControlCapabilityFooter.Entry>(),
            footer(riskTiers = listOf("privacy_impacting", "cost_impacting")),
        )
        val onPage = footer(
            riskTiers = listOf("privacy_impacting", "cost_impacting"),
            context = ModelControlCapabilityFooter.Context.BehaviorPageHeader,
        )
        assertEquals(
            listOf(R.string.model_control_risk_privacy, R.string.model_control_risk_cost),
            onPage.filterIsInstance<ModelControlCapabilityFooter.Entry.Note>().map { it.textRes },
        )
        // While a custom field is actually active, the panel card must say so too -- it really is rewriting the request then.
        assertTrue(
            footer(overridden = true, riskTiers = listOf("privacy_impacting"))
                .filterIsInstance<ModelControlCapabilityFooter.Entry.Note>()
                .any { it.textRes == R.string.model_control_risk_privacy },
        )
    }

    /** Link out when candidates exist; say so plainly when they don't -- otherwise tapping through lands on an empty list, exactly the dead end to avoid. */
    @Test
    fun `the supported models entry tells the truth about whether candidates exist`() {
        assertEquals(
            listOf(ModelControlCapabilityFooter.Entry.SupportedModelsLink),
            footer(isConfigurable = false, showsSupportedModelsAction = true),
        )
        assertEquals(
            listOf(
                ModelControlCapabilityFooter.Entry.Note(
                    R.string.model_control_no_supported_models, null,
                    ModelControlCapabilityFooter.Tone.Tertiary,
                ),
            ),
            footer(isConfigurable = false, showsSupportedModelsAction = true, hasCandidates = false),
        )
    }

    /** When the status row's alert already offers the same way out, the footer yields -- the same action never appears twice on one card. */
    @Test
    fun `the footer yields to the status row escape`() {
        assertEquals(
            emptyList<ModelControlCapabilityFooter.Entry>(),
            footer(
                isConfigurable = false,
                showsSupportedModelsAction = true,
                statusRowEscape = ModelControlCapabilityEscape.SupportedModels,
            ),
        )
        // It doesn't yield when the escape is "go to advanced settings" -- that's a different path.
        assertEquals(
            listOf(ModelControlCapabilityFooter.Entry.SupportedModelsLink),
            footer(
                isConfigurable = false,
                showsSupportedModelsAction = true,
                statusRowEscape = ModelControlCapabilityEscape.AdvancedSettings,
            ),
        )
    }

    /** When a preference is overridden, the card must offer exactly one way back, placed last. */
    @Test
    fun `an overridden control always keeps a way back to advanced settings`() {
        val entries = footer(overridden = true, showsAdvancedSettingsAction = true)
        assertEquals(ModelControlCapabilityFooter.Entry.AdvancedSettingsLink, entries.last())
        // Once overridden, "view supported models" isn't repeated -- that action's precondition requires the preference not be overridden.
        assertFalse(
            footer(overridden = true, showsAdvancedSettingsAction = true, showsSupportedModelsAction = true)
                .contains(ModelControlCapabilityFooter.Entry.SupportedModelsLink),
        )
    }

    /** Only genuinely blocked states earn the "view supported models" escape. `CustomOnly` counts too -- both paths are offered, neither yields. */
    @Test
    fun `only genuinely blocked states offer the supported models action`() {
        listOf(
            CapabilityControlPresentation.Unsupported,
            CapabilityControlPresentation.Unknown,
            CapabilityControlPresentation.Pending,
            CapabilityControlPresentation.ExternalConnectorOnly,
            CapabilityControlPresentation.CustomOnly,
        ).forEach { assertTrue("$it", modelControlShowsSupportedModelsAction(it)) }
        listOf(
            CapabilityControlPresentation.AutomaticAvailable,
            CapabilityControlPresentation.ForceUnsupported,
        ).forEach { assertFalse("$it", modelControlShowsSupportedModelsAction(it)) }
    }

    // ── Badges ───────────────────────────────────────────────────────────────

    /**
     * When the web / reasoning card is unsupported or externalConnectorOnly, it
     * already renders a full "not supported by this model" status row, so
     * hanging an "unavailable" badge on the title row too would say the same
     * thing twice. Only this one state is suppressed -- the others carry
     * information the status row doesn't (timing, ownership, who took over).
     */
    @Test
    fun `capability cards never stack an unavailable badge on top of their status row`() {
        listOf(
            CapabilityControlPresentation.Unsupported,
            CapabilityControlPresentation.ExternalConnectorOnly,
        ).forEach { status ->
            assertEquals(
                ModelControlBadgeClassification.Unavailable,
                ModelControlBadgeClassification.resolve(status),
            )
            assertEquals(
                "$status must not stack an 'unavailable' badge on top of its capability card",
                ModelControlBadgeClassification.None,
                ModelControlBadgeClassification.capabilityCard(status),
            )
        }
        // "not ready" carries timing and "manual" carries who took over -- both of these stay.
        mapOf(
            CapabilityControlPresentation.Pending to ModelControlBadgeClassification.NotReady,
            CapabilityControlPresentation.Unknown to ModelControlBadgeClassification.NotReady,
            CapabilityControlPresentation.CustomOnly to ModelControlBadgeClassification.Manual,
            CapabilityControlPresentation.AutomaticAvailable to ModelControlBadgeClassification.None,
            CapabilityControlPresentation.ForceUnsupported to ModelControlBadgeClassification.None,
        ).forEach { (status, expected) ->
            assertEquals("$status", expected, ModelControlBadgeClassification.capabilityCard(status))
        }
    }

    /**
     * The "not ready" badge on the advanced settings card is a semantic error,
     * not a layout nit.
     *
     * The request-parameter editor behind this card never reads the recipe at
     * all -- its editable set comes from the generation profile
     * (`CapabilityEvidenceProductionAdapter.generationParameterUiProjection`:
     * relay reads the local engine/transport profile, and an official model
     * reads the catalog model's `generationProfile`), while
     * `presentation("generation")` reads `capabilityControls.generation`
     * instead. Relay's `capabilityControls` is always empty, and an official
     * model may not send this field either, so the card routinely lands on
     * `Unknown` and shows "not ready" even though the parameters are genuinely
     * editable and really do go out on the wire.
     *
     * The harder consequence is in `ModelControlNavigationRow`: the badge takes
     * priority over the trailing text, so this false badge swallows the whole
     * "N settings adjusted" line -- the user is told a wrong status and also
     * loses visibility into how many settings they already changed.
     */
    @Test
    fun `the advanced settings card drops the not-ready badge but keeps what server denies`() {
        // Parameter editing doesn't depend on the recipe, so pending / unknown never get a badge.
        listOf(CapabilityControlPresentation.Pending, CapabilityControlPresentation.Unknown)
            .forEach { status ->
                assertEquals(
                    "$status still resolves to the raw NotReady classification",
                    ModelControlBadgeClassification.NotReady,
                    ModelControlBadgeClassification.resolve(status),
                )
                assertEquals(
                    "$status must not show 'not ready' on the advanced settings row",
                    ModelControlBadgeClassification.None,
                    ModelControlBadgeClassification.advancedSettingsCard(status),
                )
            }
        // The two states where the server explicitly says it can't be done keep their badge: this row has no status row speaking for it.
        listOf(
            CapabilityControlPresentation.Unsupported,
            CapabilityControlPresentation.ExternalConnectorOnly,
        ).forEach { status ->
            assertEquals(
                ModelControlBadgeClassification.Unavailable,
                ModelControlBadgeClassification.advancedSettingsCard(status),
            )
        }
        // Every other state matches its unsuppressed classification exactly -- over-suppressing would delete real information too.
        listOf(
            CapabilityControlPresentation.AutomaticAvailable,
            CapabilityControlPresentation.ForceUnsupported,
            CapabilityControlPresentation.CustomOnly,
            CapabilityControlPresentation.Unsupported,
            CapabilityControlPresentation.ExternalConnectorOnly,
        ).forEach { status ->
            assertEquals(
                "$status's badge got suppressed along the way -- only NotReady should be suppressed here",
                ModelControlBadgeClassification.resolve(status),
                ModelControlBadgeClassification.advancedSettingsCard(status),
            )
        }
        // The capability card's own suppression is unaffected: the two cards suppress different states and must not be merged into one function.
        assertEquals(
            ModelControlBadgeClassification.NotReady,
            ModelControlBadgeClassification.capabilityCard(CapabilityControlPresentation.Unknown),
        )
        assertEquals(
            ModelControlBadgeClassification.NotReady,
            ModelControlBadgeClassification.capabilityCard(CapabilityControlPresentation.Pending),
        )
    }

    /**
     * The test above pins the projection itself; this one pins who consumes it:
     * the web / reasoning cards use the projection that suppresses unavailable,
     * while the advanced settings row uses the one that suppresses notReady.
     * Wire them to the wrong one and both projections still pass while the UI
     * still grows an extra badge.
     */
    @Test
    fun `each card consumes its own badge projection`() {
        val sheet = repoFile("feature/chat/composer/ModelControlsSheet.kt").readText()
        listOf("ModelControlWebCard", "ModelControlReasoningCard").forEach { card ->
            val body = sheet.substringAfter("private fun $card(").substringBefore("\n@Composable")
            assertTrue(
                "$card must consume the capability-card projection",
                body.contains("ModelControlBadgeClassification.capabilityCard(status)"),
            )
        }
        val behaviorRow = sheet
            .substringAfter("ModelControlNavigationRow(\n                                    icon = Icons.Outlined.Tune,")
            .substringBefore("\n                            }")
        assertTrue("scope didn't land on the advanced settings row, this assertion has nothing to test", behaviorRow.contains("badge = modelControlBadge("))
        assertTrue(
            "the advanced settings row must not fall back to the unsuppressed projection -- relay and recipe-less models would grow a false 'not ready' badge again",
            behaviorRow.contains("ModelControlBadgeClassification.advancedSettingsCard("),
        )
        assertFalse(
            "the advanced settings row got wired to the capability card's suppression -- that one suppresses Unavailable, not NotReady",
            behaviorRow.contains("ModelControlBadgeClassification.capabilityCard("),
        )
        assertFalse(
            "the advanced settings row must not consume the unsuppressed resolve directly",
            behaviorRow.contains("ModelControlBadgeClassification.resolve("),
        )
        // A badge swallows the "N settings adjusted" line the moment it's shown, which is the actual harm here; catch it if this relationship changes.
        val components = repoFile("feature/chat/composer/ModelControlsComponents.kt").readText()
        val row = components
            .substringAfter("internal fun ModelControlNavigationRow(")
            .substringBefore("// MARK: - List rows")
        assertTrue(
            "the mutual exclusion between trailing text and the badge changed -- the advanced settings row's badge projection needs to be re-evaluated",
            row.contains("if (badge != null) {") && row.contains("} else if (!trailingText.isNullOrEmpty()) {"),
        )
    }

    // ── Read-only and identity gaps ──────────────────────────────────────────

    /** A missing identity outranks "read only"; only writable can persist. */
    @Test
    fun `editability resolves in the same order the runtime identity fails`() {
        assertEquals(
            ModelControlsEditability.RuntimeIdentityUnavailable,
            ModelControlsEditability.resolve(null, runtimeIsReadOnly = true),
        )
        assertEquals(
            ModelControlsEditability.RuntimeReadOnly,
            ModelControlsEditability.resolve("r1.a.b", runtimeIsReadOnly = true),
        )
        assertEquals(
            ModelControlsEditability.Writable,
            ModelControlsEditability.resolve("r1.a.b", runtimeIsReadOnly = false),
        )
        assertTrue(ModelControlsEditability.Writable.canPersist)
        ModelControlsEditability.entries.filter { it != ModelControlsEditability.Writable }
            .forEach { assertFalse("$it", it.canPersist) }
    }

    /**
     * The three reasons identity can be missing map to three completely
     * different actions. Collapsing them into one sentence is a dead end: a
     * tappable button promises "tap me and this gets fixed", and when it can't
     * point at the real cause it's worse than no button at all.
     */
    @Test
    fun `each identity gap gets the one action that can actually change it`() {
        assertEquals(
            ModelControlsIdentityGap.RuntimeSnapshotMissing,
            ModelControlsIdentityGap.resolve(
                ai.oriveo.community.core.model.ProviderKind.Relay,
                relayTransportIsDecided = false,
                runtimeIsReady = false,
            ),
        )
        assertEquals(
            ModelControlsIdentityGap.RelayTransportUndecided,
            ModelControlsIdentityGap.resolve(
                ai.oriveo.community.core.model.ProviderKind.Relay,
                relayTransportIsDecided = false,
                runtimeIsReady = true,
            ),
        )
        assertEquals(
            ModelControlsIdentityGap.ModelNotInCatalog,
            ModelControlsIdentityGap.resolve(
                ai.oriveo.community.core.model.ProviderKind.OpenAI,
                relayTransportIsDecided = false,
                runtimeIsReady = true,
            ),
        )
        assertEquals(
            listOf(
                ModelControlsIdentityGap.RecoveryAction.RefetchRuntime,
                ModelControlsIdentityGap.RecoveryAction.OpenConnectionSettings,
                ModelControlsIdentityGap.RecoveryAction.ChooseAnotherModel,
            ),
            ModelControlsIdentityGap.entries.map { it.recoveryAction },
        )
        assertEquals(
            "the three reasons must map to three distinct sentences",
            3,
            ModelControlsIdentityGap.entries.map { it.reasonTextRes }.toSet().size,
        )
        ModelControlsIdentityGap.entries.forEach { assertNotNull(it.reasonTextRes) }
    }

    /** Each of the three owners has its own title, status text, and transport label -- no two may share a word. */
    @Test
    fun `capability titles and status sentences never collide`() {
        assertEquals(R.string.model_control_web_search, modelControlCapabilityTitleRes("web"))
        assertEquals(R.string.model_control_thinking, modelControlCapabilityTitleRes("reasoning"))
        assertEquals(R.string.generation_model_behavior, modelControlCapabilityTitleRes("generation"))
        assertEquals(
            3,
            modelControlOwnerOrder.map(::modelControlCapabilityTitleRes).toSet().size,
        )
        // Every presentation state has its own sentence.
        val byStatus = CapabilityControlPresentation.entries.associateWith(::modelControlStatusTextRes)
        assertEquals(
            "every presentation state must map to its own sentence",
            CapabilityControlPresentation.entries.size,
            byStatus.values.toSet().size,
        )
        assertEquals("Chat Completions", CapabilityTransportLabel.display("openai_chat"))
        assertEquals("Responses", CapabilityTransportLabel.display("openai_responses"))
        assertNull("an unknown transport must not get a made-up name", CapabilityTransportLabel.display("nonsense_wire"))
    }

    /** Production source under `.../java/ai/oriveo/community` -- assertions like "who consumes which projection" can only be pinned to the source itself. */
    private fun repoFile(relative: String): File {
        val direct = File("src/main/java/ai/oriveo/community/$relative")
        if (direct.exists()) return direct
        var dir = File(System.getProperty("user.dir")!!).absoluteFile
        val prefix = "android/app/src/main/java/ai/oriveo/community/"
        while (true) {
            val candidate = File(dir, prefix + relative)
            if (candidate.exists()) return candidate
            dir = dir.parentFile ?: break
        }
        error("could not find $relative")
    }
}
