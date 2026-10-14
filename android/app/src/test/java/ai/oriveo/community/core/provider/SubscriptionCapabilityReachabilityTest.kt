package ai.oriveo.community.core.provider

import ai.oriveo.community.core.data.remote.canonicalCapabilityTransport
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.ChatRequestOptions
import ai.oriveo.community.core.model.ModelCapability
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderAuthMode
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.ReasoningMode
import ai.oriveo.community.core.provider.openai.OpenAISubscriptionRequestContext
import ai.oriveo.community.core.provider.openai.codexReasoningEffort
import ai.oriveo.community.core.provider.transport.TransportKind
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Capability reachability on the subscription paths (Codex and Grok subscription sign-in).
 *
 * These came directly out of an investigation: subscription models are not in the model catalog, so
 * they never carry a `capabilityControls` block, and as a result the web search switch and the
 * reasoning level picker rendered nowhere and nothing was ever injected outbound. The carefully
 * written "copy what upstream declared" implementation had become dead code, because the fix lived
 * downstream of a gate that closed upstream of it.
 *
 * What this suite pins is the full chain once that gate is opened:
 *   upstream /models declaration -> capability verdict -> preference identity
 * If any link falls back to fail-closed behaviour, these turn red.
 */
class SubscriptionCapabilityReachabilityTest {

    /** A subscription connection: the test is `authMode`, not providerKind, because the same OpenAI provider has a different source of truth for capabilities in each mode. */
    private fun subscriptionProvider(kind: ProviderKind = ProviderKind.OpenAI) = Provider(
        id = if (kind == ProviderKind.Grok) "22222222-2222-4222-8222-222222222222"
            else "11111111-1111-4111-8111-111111111111",
        kind = kind,
        authMode = ProviderAuthMode.Subscription,
    )

    /** The shape a subscription catalog entry is modelled into: both the capability bits and the level table are copied from what upstream declares at `/models`. */
    private fun subscriptionModel(
        id: String = "gpt-5.6-sol",
        capabilities: List<ModelCapability> = listOf(
            ModelCapability.Text, ModelCapability.Web, ModelCapability.Reasoning,
        ),
        declaredLevels: List<String> = listOf("low", "medium", "high"),
        apiBackend: String? = null,
    ) = AIModel(
        id = id,
        name = id,
        capabilities = capabilities,
        reasoningModeAvailable = capabilities.contains(ModelCapability.Reasoning),
        upstreamReasoningLevels = declaredLevels,
        upstreamApiBackend = apiBackend,
    )

    // ── The capability verdict follows what upstream declares ──

    @Test
    fun `a declared web search capability leaves the control usable rather than degraded to not adjustable`() {
        val verdict = CapabilityControlResolution.resolve(
            provider = subscriptionProvider(), model = subscriptionModel(), capability = "web",
        )
        assertEquals("auto_available", verdict.state)
        assertTrue(verdict.intents.contains("automatic"))
        assertEquals("subscription_upstream_declared", verdict.reasonCode)
    }

    @Test
    fun `an undeclared web search capability is unavailable, a definite no, not unknown meaning not looked into yet`() {
        val verdict = CapabilityControlResolution.resolve(
            provider = subscriptionProvider(),
            model = subscriptionModel(capabilities = listOf(ModelCapability.Text)),
            capability = "web",
        )
        assertEquals("unavailable", verdict.state)
        assertEquals("model_capability_absent", verdict.reasonCode)
    }

    @Test
    fun `the offered levels come from the same function the outbound path uses, so only levels that map onto a declared value appear`() {
        val verdict = CapabilityControlResolution.resolve(
            provider = subscriptionProvider(), model = subscriptionModel(), capability = "reasoning",
        )
        assertEquals("auto_available", verdict.state)
        // Upstream declares only low/medium/high, so max walks the fallback chain down to high. The
        // fallback is guaranteed to land on a legal value rather than silently sending nothing, so
        // max is still a level that really can go out.
        assertEquals(listOf("low", "balanced", "deep", "max"), verdict.intents)
    }

    @Test
    fun `with only one declared level, the levels that map onto nothing do not appear`() {
        // Only xhigh is declared, and the fast candidates are low/minimal/medium, none of which
        // match, so that level must not be offered.
        val verdict = CapabilityControlResolution.resolve(
            provider = subscriptionProvider(),
            model = subscriptionModel(declaredLevels = listOf("xhigh")),
            capability = "reasoning",
        )
        assertEquals(listOf("max"), verdict.intents)
    }

    @Test
    fun `with no declared level table the reasoning control is unavailable rather than a button that does nothing`() {
        val verdict = CapabilityControlResolution.resolve(
            provider = subscriptionProvider(),
            model = subscriptionModel(declaredLevels = emptyList()),
            capability = "reasoning",
        )
        assertEquals("unavailable", verdict.state)
        assertEquals("upstream_parameter_not_declared", verdict.reasonCode)
    }

    @Test
    fun `a Grok subscription on Responses that declares web search offers automatic only and presents as always on`() {
        val provider = subscriptionProvider(kind = ProviderKind.Grok)
        val model = subscriptionModel(id = "grok-4.6", apiBackend = "responses")
        val verdict = CapabilityControlResolution.resolve(provider = provider, model = model, capability = "web")
        assertEquals("auto_available", verdict.state)
        assertEquals(listOf("automatic"), verdict.intents)
        // Upstream always carries web_search and the user cannot turn it off: the verdict is unchanged, the reasonCode becomes "always on".
        assertEquals("subscription_web_always_on", verdict.reasonCode)
        val presentation = CapabilityControlPresentationResolver.presentation(provider, model, "web")
        assertEquals(CapabilityControlPresentation.AlwaysOn, presentation)
        // It is not the user's choice: the globe stays dark.
        assertFalse(CapabilityWebPreferenceLiveness.reachesTheWire(presentation, customIsActive = false))
    }

    @Test
    fun `reasoning levels on a Grok subscription are usable as normal`() {
        val verdict = CapabilityControlResolution.resolve(
            provider = subscriptionProvider(kind = ProviderKind.Grok),
            model = subscriptionModel(id = "grok-4.6"),
            capability = "reasoning",
        )
        assertEquals("auto_available", verdict.state)
        assertTrue(verdict.intents.isNotEmpty())
    }

    @Test
    fun `every other capability on a subscription path is honestly unknown rather than pretending to be unsupported`() {
        val verdict = CapabilityControlResolution.resolve(
            provider = subscriptionProvider(), model = subscriptionModel(), capability = "generation",
        )
        assertEquals("unknown", verdict.state)
    }

    // ── Panel presentation, the second gate: auto_available must not be knocked back to unknown by the transport check ──

    @Test
    fun `auto_available on a subscription path survives the exact-transport check and reaches the panel`() {
        // Subscription models have no recipe, so `hasExactTransportRecipe` is necessarily false.
        // Without an exemption, `status(...)` would degrade every auto_available back to Unknown and
        // opening the verdict gate would have achieved nothing.
        val presentation = CapabilityControlPresentationResolver.presentation(
            provider = subscriptionProvider(), model = subscriptionModel(), capability = "web",
        )
        assertEquals(CapabilityControlPresentation.AutomaticAvailable, presentation)
        // The third gate has the same source: the globe lit up in the panel has to be the one that
        // really goes out on the wire.
        assertTrue(CapabilityWebPreferenceLiveness.reachesTheWire(presentation, customIsActive = false))
    }

    @Test
    fun `a capability upstream did not declare shows as unsupported in the panel rather than unknown`() {
        val presentation = CapabilityControlPresentationResolver.presentation(
            provider = subscriptionProvider(),
            model = subscriptionModel(capabilities = listOf(ModelCapability.Text)),
            capability = "web",
        )
        assertEquals(CapabilityControlPresentation.Unsupported, presentation)
    }

    // ── Preference identity, so a choice can actually be stored ──

    @Test
    fun `a subscription model resolves no catalog transport yet still has a valid identity`() {
        // With a null identity the whole capability panel goes read-only and not a single byte of the
        // user's level choice or web search switch can be stored.
        val identity = ModelControlRuntimeIdentityResolver.resolve(
            provider = subscriptionProvider(), model = subscriptionModel(),
        )
        assertNotNull(identity)
        assertEquals("gpt-5.6-sol", identity?.canonicalModelId)
        assertEquals(
            canonicalCapabilityTransport(TransportKind.OpenAIResponses.wireValue),
            identity?.finalTransport,
        )
        assertEquals(
            ModelControlRuntimeIdentityResolver.SUBSCRIPTION_RUNTIME_REVISION,
            identity?.runtimeRevision,
        )
    }

    @Test
    fun `a Grok subscription with no declaration defaults to Responses, avoiding a fake search`() {
        val identity = ModelControlRuntimeIdentityResolver.resolve(
            provider = subscriptionProvider(kind = ProviderKind.Grok),
            model = subscriptionModel(id = "grok-4.6"),
        )
        assertEquals(
            canonicalCapabilityTransport(TransportKind.OpenAIResponses.wireValue),
            identity?.finalTransport,
        )
    }

    @Test
    fun `an explicit chat declaration on a Grok subscription must be honoured and web search is then unavailable`() {
        val provider = subscriptionProvider(kind = ProviderKind.Grok)
        val model = subscriptionModel(id = "grok-legacy", apiBackend = "chat")
        assertEquals(TransportKind.OpenAIChat.wireValue,
            CapabilityControlResolution.subscriptionFinalTransport(provider, model))
        assertEquals("unavailable",
            CapabilityControlResolution.resolve(provider, model, "web").state)
    }

    @Test
    fun `the two paths have different identities so a preference cannot bleed from one to the other`() {
        val codex = ModelControlRuntimeIdentityResolver.resolve(
            provider = subscriptionProvider(), model = subscriptionModel(),
        )
        val grok = ModelControlRuntimeIdentityResolver.resolve(
            provider = subscriptionProvider(kind = ProviderKind.Grok), model = subscriptionModel(),
        )
        // storageIdentity is deliberately transport+revision only; provider/connection id is the
        // store's separate partition column. Compare the complete runtime identities here.
        assertTrue(codex != grok)
    }

    // ── The API key mode is not caught in the crossfire ──

    // ── Truth adapter (the projection copies the subscription snapshot) ──

    private val reasoningModes = ReasoningMode.entries.filter { it != ReasoningMode.Automatic }
    private val truthKeys = setOf("vision_input", "web_search", "tool_call") +
        reasoningModes.map { "reasoning_level/${it.rawValue}" }

    private fun truthProjection(provider: Provider, model: AIModel) =
        CapabilityEvidenceProductionAdapter.capabilityProjection(
            provider = provider,
            model = model,
            keys = truthKeys,
            explicitKeys = truthKeys,
        )

    @Test
    fun `a model in the subscription snapshot projects as upstream_declaration and levels are filtered by the same function the outbound path uses`() {
        // Only minimal is declared: fast can land on it, while balanced / deep / max have no match in their candidate order, so they are filtered out.
        val levels = listOf("minimal")
        val model = subscriptionModel(
            capabilities = listOf(ModelCapability.Text, ModelCapability.Web, ModelCapability.Reasoning, ModelCapability.Image),
            declaredLevels = levels,
        )
        val provider = subscriptionProvider().copy(catalogModels = listOf(model))

        val projection = truthProjection(provider, model)
        assertEquals(
            CapabilityControlResolution.subscriptionFinalTransport(provider, model),
            projection.identity?.effectiveTransport,
        )
        listOf("vision_input", "web_search").forEach { key ->
            val decision = projection.decision(key)!!
            assertEquals(key, "supported", decision.resolution.support)
            assertEquals(key, "upstream_declaration", decision.resolution.source)
            assertEquals(key, "declared", decision.resolution.grade)
            assertTrue(key, decision.permitsOutbound)
        }
        // Every level shown in the UI must land on a value upstream actually accepts in the request: the same answer as codexReasoningEffort.
        val expectedSupported = reasoningModes.filter { codexReasoningEffort(it.rawValue, levels) != null }.toSet()
        assertTrue(expectedSupported.isNotEmpty() && expectedSupported.size < reasoningModes.size)
        reasoningModes.forEach { mode ->
            val decision = projection.decision("reasoning_level/${mode.rawValue}")!!
            val supported = mode in expectedSupported
            assertEquals(mode.rawValue, if (supported) "supported" else "unsupported", decision.resolution.support)
            assertEquals(mode.rawValue, "upstream_declaration", decision.resolution.source)
            assertEquals(mode.rawValue, supported, decision.permitsOutbound)
        }
    }

    @Test
    fun `subscription tool_call only trusts the snapshot model's own first-party declaration, and with no declaration and no facts there is no candidate`() {
        val declared = subscriptionModel().copy(toolCall = true)
        val provider = subscriptionProvider().copy(catalogModels = listOf(declared))
        val firstParty = truthProjection(provider, declared).decision("tool_call")!!
        assertEquals("supported", firstParty.resolution.support)
        assertEquals("upstream_declaration", firstParty.resolution.source)
        assertTrue(firstParty.permitsOutbound)

        val silent = subscriptionModel()
        val undeclared = truthProjection(provider.copy(catalogModels = listOf(silent)), silent).decision("tool_call")!!
        assertFalse(undeclared.visible)
        assertEquals("unknown", undeclared.resolution.support)
    }

    @Test
    fun `a subscription snapshot not yet fetched is missing_evidence, and fetched but without this model is catalog_absent`() {
        val model = subscriptionModel()
        val unfetched = truthProjection(subscriptionProvider(), model)
        val absent = truthProjection(
            subscriptionProvider().copy(catalogModels = listOf(model)),
            model.copy(id = "gpt-not-in-snapshot", canonicalModelId = "gpt-not-in-snapshot"),
        )
        (truthKeys - "tool_call").forEach { key ->
            val unfetchedDecision = unfetched.decision(key)!!
            assertEquals(key, "unknown", unfetchedDecision.resolution.support)
            assertEquals(key, "missing_evidence", unfetchedDecision.resolution.reasonCode)
            assertFalse(key, unfetchedDecision.permitsOutbound)

            val absentDecision = absent.decision(key)!!
            assertEquals(key, "unknown", absentDecision.resolution.support)
            assertEquals(key, "catalog_absent", absentDecision.resolution.source)
            assertEquals(key, "catalog_absent", absentDecision.resolution.reasonCode)
            assertFalse(key, absentDecision.permitsOutbound)
        }
    }

    @Test
    fun `the subscription outbound projection and the UI projection share one shape and one source of truth`() {
        val model = subscriptionModel(
            capabilities = listOf(ModelCapability.Text, ModelCapability.Web, ModelCapability.Image),
        )
        val options = ChatRequestOptions(
            openAISubscription = OpenAISubscriptionRequestContext(
                responsesUrl = "https://chatgpt.test/backend-api/codex/responses",
                accountId = "acct",
                requiredHeaders = emptyMap(),
            ),
            activeModel = model,
        )
        val outbound = officialRequestCapabilityProjection(
            providerKind = ProviderKind.OpenAI,
            modelID = model.id,
            options = options,
            messages = emptyList(),
            finalTransport = TransportKind.OpenAIResponses.wireValue,
        )
        val ui = truthProjection(subscriptionProvider().copy(catalogModels = listOf(model)), model)
        listOf("vision_input", "web_search").forEach { key ->
            assertEquals(key, ui.decision(key)!!.resolution.support, outbound.decision(key)!!.resolution.support)
            assertEquals(key, "upstream_declaration", outbound.decision(key)!!.resolution.source)
        }
        // Vision is the only outbound gate on this path that the projection lets through; web search is still decided by CapabilityControlResolution.
        assertTrue(outbound.permitsOutbound("vision_input"))
        assertFalse(outbound.permitsOutbound("web_search"))

        // With no catalog object it is state 1: no guessing, and no letting an explicit intent through.
        val unfetched = officialRequestCapabilityProjection(
            providerKind = ProviderKind.OpenAI,
            modelID = model.id,
            options = options.copy(activeModel = null),
            finalTransport = TransportKind.OpenAIResponses.wireValue,
        )
        assertEquals("unknown", unfetched.decision("vision_input")!!.resolution.support)
        assertEquals("missing_evidence", unfetched.decision("vision_input")!!.resolution.reasonCode)
    }

    @Test
    fun `the same OpenAI provider in API key mode does not enter the subscription branch`() {
        val provider = Provider(id = "byok", kind = ProviderKind.OpenAI, authMode = ProviderAuthMode.ApiKey)
        assertTrue(!CapabilityControlResolution.isSubscriptionLink(provider))
        assertNull(CapabilityControlResolution.subscriptionFinalTransport(provider))
    }
}
