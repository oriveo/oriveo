package ai.oriveo.community.core.provider

import ai.oriveo.community.core.data.remote.canonicalCapabilityTransport
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.ModelCapability
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderAuthMode
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.provider.transport.TransportKind
import org.junit.Assert.assertEquals
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
    fun `a Grok subscription on Responses that declares web search offers automatic only`() {
        val verdict = CapabilityControlResolution.resolve(
            provider = subscriptionProvider(kind = ProviderKind.Grok),
            model = subscriptionModel(id = "grok-4.6", apiBackend = "responses"),
            capability = "web",
        )
        assertEquals("auto_available", verdict.state)
        assertEquals(listOf("automatic"), verdict.intents)
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

    @Test
    fun `the same OpenAI provider in API key mode does not enter the subscription branch`() {
        val provider = Provider(id = "byok", kind = ProviderKind.OpenAI, authMode = ProviderAuthMode.ApiKey)
        assertTrue(!CapabilityControlResolution.isSubscriptionLink(provider))
        assertNull(CapabilityControlResolution.subscriptionFinalTransport(provider))
    }
}
