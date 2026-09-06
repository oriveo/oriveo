package ai.oriveo.community.core.usage

import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatMessageState
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.core.model.Conversation
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderConnectionState
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.RelayKind
import org.junit.Assert.assertEquals
import org.junit.Test
import java.time.Instant

class CostSummaryCalculatorTest {

    @Test
    fun `uses message timestamp instead of conversation createdAt`() {
        val summary = CostSummaryCalculator.calculateMonthlySummary(
            conversations = listOf(
                conversation(
                    createdAt = instant("2026-02-15T09:00:00Z").toEpochMilli(),
                    updatedAt = instant("2026-03-03T08:05:00Z").toEpochMilli(),
                    messages = listOf(
                        assistantMessage(
                            providerID = "provider-1",
                            providerKind = ProviderKind.OpenAI,
                            estimatedCost = 1.2,
                            createdAt = instant("2026-03-03T08:00:00Z").toEpochMilli(),
                        ),
                        assistantMessage(
                            providerID = "provider-1",
                            providerKind = ProviderKind.OpenAI,
                            estimatedCost = 0.8,
                            createdAt = instant("2026-02-27T08:00:00Z").toEpochMilli(),
                        ),
                    ),
                ),
            ),
            providers = listOf(makeProvider("provider-1", ProviderKind.OpenAI)),
            now = instant("2026-03-26T10:00:00Z"),
        )

        assertEquals(1.2, summary.totalCost, 0.00001)
        assertEquals(1, summary.providers.size)
        assertEquals(ProviderKind.OpenAI, summary.providers.first().providerKind)
        assertEquals("provider-1", summary.providers.first().providerID)
    }

    @Test
    fun `v0018+ multi-Relay each get own row by providerID`() {
        val providers = listOf(
            makeProvider("relay-a", ProviderKind.Relay, customName = "My Relay"),
            makeProvider("relay-b", ProviderKind.Relay, baseUrlText = "https://api.proxy.example.com/v1"),
            makeProvider("provider-c", ProviderKind.Anthropic),
        )
        val summary = CostSummaryCalculator.calculateMonthlySummary(
            conversations = listOf(
                conversation(
                    providerID = "relay-a",
                    messages = listOf(
                        assistantMessage(
                            providerID = "relay-a",
                            providerKind = ProviderKind.Relay,
                            estimatedCost = 1.0,
                            createdAt = instant("2026-03-04T08:00:00Z").toEpochMilli(),
                        ),
                    ),
                ),
                conversation(
                    providerID = "relay-b",
                    messages = listOf(
                        assistantMessage(
                            providerID = "relay-b",
                            providerKind = ProviderKind.Relay,
                            estimatedCost = 2.5,
                            createdAt = instant("2026-03-05T08:00:00Z").toEpochMilli(),
                        ),
                    ),
                ),
                conversation(
                    providerID = "provider-c",
                    messages = listOf(
                        assistantMessage(
                            providerID = "provider-c",
                            providerKind = ProviderKind.Anthropic,
                            estimatedCost = 0.9,
                            createdAt = instant("2026-03-06T08:00:00Z").toEpochMilli(),
                        ),
                    ),
                ),
            ),
            providers = providers,
            now = instant("2026-03-26T10:00:00Z"),
        )

        assertEquals(4.4, summary.totalCost, 0.00001)
        assertEquals(3, summary.providers.size)

        assertEquals("relay-b", summary.providers[0].providerID)

        assert(summary.providers[0].displayName.contains("api.proxy.example.com"))
        assertEquals("relay-a", summary.providers[1].providerID)
        assertEquals("My Relay", summary.providers[1].displayName)
        assertEquals("provider-c", summary.providers[2].providerID)
    }

    @Test
    fun `uses UTC month boundary`() {
        val summary = CostSummaryCalculator.calculateMonthlySummary(
            conversations = listOf(
                conversation(
                    messages = listOf(
                        assistantMessage(
                            providerID = "provider-1",
                            providerKind = ProviderKind.OpenAI,
                            estimatedCost = 0.4,
                            createdAt = instant("2026-02-28T23:59:59Z").toEpochMilli(),
                        ),
                        assistantMessage(
                            providerID = "provider-1",
                            providerKind = ProviderKind.OpenAI,
                            estimatedCost = 0.6,
                            createdAt = instant("2026-03-01T00:00:00Z").toEpochMilli(),
                        ),
                    ),
                ),
            ),
            providers = listOf(makeProvider("provider-1", ProviderKind.OpenAI)),
            now = instant("2026-03-26T10:00:00Z"),
        )

        assertEquals(0.6, summary.totalCost, 0.00001)
        assertEquals(1, summary.providers.size)
        assertEquals(0.6, summary.providers.first().cost, 0.00001)
    }

    // ── augmentDisplayNames ──

    @Test
    fun `augmentDisplayNames replaces kind-only fallback with customName`() {
        val raw = MonthlyCostSummary(
            totalCost = 3.5,
            providers = listOf(
                MonthlyCostProviderEntry(
                    providerKind = ProviderKind.Relay,
                    providerID = "relay-a",
                    displayName = "Relay",
                    cost = 3.5,
                ),
            ),
            hiddenProviderCount = 0,
            source = CostSummarySource.LocalDevice,
        )
        val augmented = CostSummaryCalculator.augmentDisplayNames(
            raw,
            providers = listOf(makeProvider("relay-a", ProviderKind.Relay, customName = "My Relay")),
        )
        assertEquals("My Relay", augmented.providers.first().displayName)
    }

    @Test
    fun `augmentDisplayNames also resolves relay logo kind`() {
        val raw = MonthlyCostSummary(
            totalCost = 3.5,
            providers = listOf(
                MonthlyCostProviderEntry(
                    providerKind = ProviderKind.Relay,
                    providerID = "relay-a",
                    displayName = "Relay",
                    cost = 3.5,
                ),
            ),
            hiddenProviderCount = 0,
            source = CostSummarySource.LocalDevice,
        )
        val augmented = CostSummaryCalculator.augmentDisplayNames(
            raw,
            providers = listOf(
                makeProvider(
                    "relay-a",
                    ProviderKind.Relay,
                    customName = "My Relay",
                    relayKind = RelayKind.AnthropicCompatible,
                ),
            ),
        )

        assertEquals(ProviderKind.Anthropic, augmented.providers.first().logoProviderKind)
    }

    @Test
    fun `cost summary uses shared relay logo resolver for local device entries`() {
        val providers = listOf(
            makeProvider(
                "relay-anthropic",
                ProviderKind.Relay,
                customName = "Work Relay",
                relayKind = RelayKind.AnthropicCompatible,
            ),
        )
        val summary = CostSummaryCalculator.calculateMonthlySummary(
            conversations = listOf(
                conversation(
                    providerID = "relay-anthropic",
                    messages = listOf(
                        assistantMessage(
                            providerID = "relay-anthropic",
                            providerKind = ProviderKind.Relay,
                            estimatedCost = 1.0,
                            createdAt = instant("2026-03-04T08:00:00Z").toEpochMilli(),
                        ),
                    ),
                ),
            ),
            providers = providers,
            now = instant("2026-03-26T10:00:00Z"),
        )

        assertEquals(ProviderKind.Anthropic, summary.providers.first().logoProviderKind)
    }

    // ── monthlyCostByProvider ──

    @Test
    fun `monthlyCostByProvider groups by providerID`() {
        val costs = CostSummaryCalculator.monthlyCostByProvider(
            conversations = listOf(
                conversation(
                    providerID = "provider-a",
                    messages = listOf(
                        assistantMessage(providerID = "provider-a", providerKind = ProviderKind.OpenAI, estimatedCost = 1.0, createdAt = instant("2026-03-04T08:00:00Z").toEpochMilli()),
                        assistantMessage(providerID = "provider-a", providerKind = ProviderKind.OpenAI, estimatedCost = 2.0, createdAt = instant("2026-03-05T08:00:00Z").toEpochMilli()),
                    ),
                ),
                conversation(
                    providerID = "provider-b",
                    messages = listOf(
                        assistantMessage(providerID = "provider-b", providerKind = ProviderKind.Anthropic, estimatedCost = 0.5, createdAt = instant("2026-03-06T08:00:00Z").toEpochMilli()),
                    ),
                ),
            ),
            now = instant("2026-03-26T10:00:00Z"),
        )

        assertEquals(2, costs.size)
        assertEquals(3.0, costs["provider-a"]!!, 0.00001)
        assertEquals(0.5, costs["provider-b"]!!, 0.00001)
    }

    @Test
    fun `monthlyCostByProvider respects UTC month window`() {
        val costs = CostSummaryCalculator.monthlyCostByProvider(
            conversations = listOf(
                conversation(
                    providerID = "provider-a",
                    messages = listOf(
                        assistantMessage(providerID = "provider-a", providerKind = ProviderKind.OpenAI, estimatedCost = 0.4, createdAt = instant("2026-02-28T23:59:59Z").toEpochMilli()),
                        assistantMessage(providerID = "provider-a", providerKind = ProviderKind.OpenAI, estimatedCost = 0.6, createdAt = instant("2026-03-01T00:00:00Z").toEpochMilli()),
                    ),
                ),
            ),
            now = instant("2026-03-26T10:00:00Z"),
        )

        assertEquals(1, costs.size)
        assertEquals(0.6, costs["provider-a"]!!, 0.00001)
    }

    @Test
    fun `monthlyCostByProvider returns empty when no cost data`() {
        val costs = CostSummaryCalculator.monthlyCostByProvider(
            conversations = listOf(
                conversation(
                    messages = listOf(
                        ChatMessage(
                            id = "msg-user",
                            role = ChatRole.User,
                            text = "hello",
                            providerKind = ProviderKind.OpenAI,
                            providerName = "OpenAI",
                            modelName = "gpt-4o",
                            estimatedCost = 0.0,
                            state = ChatMessageState.Delivered,
                            createdAt = instant("2026-03-04T08:00:00Z").toEpochMilli(),
                        ),
                    ),
                ),
            ),
            now = instant("2026-03-26T10:00:00Z"),
        )

        assertEquals(0, costs.size)
    }

    private fun conversation(
        providerID: String = "provider-1",
        createdAt: Long = instant("2026-03-01T00:00:00Z").toEpochMilli(),
        updatedAt: Long = createdAt,
        messages: List<ChatMessage>,
    ): Conversation = Conversation(
        id = "conversation-${providerID}-${messages.size}",
        title = "Test",
        providerID = providerID,
        providerKind = ProviderKind.OpenAI,
        modelID = "gpt-4o",
        messages = messages,
        createdAt = createdAt,
        updatedAt = updatedAt,
    )

    private fun assistantMessage(
        providerID: String? = null,
        providerKind: ProviderKind,
        estimatedCost: Double,
        createdAt: Long,
    ): ChatMessage = ChatMessage(
        id = "message-${providerKind.name}-$createdAt",
        role = ChatRole.Assistant,
        text = "reply",
        providerID = providerID,
        providerKind = providerKind,
        providerName = providerKind.displayName,
        modelName = "gpt-4o",
        estimatedCost = estimatedCost,
        state = ChatMessageState.Delivered,
        createdAt = createdAt,
    )

    private fun makeProvider(
        id: String,
        kind: ProviderKind,
        customName: String? = null,
        baseUrlText: String? = null,
        relayKind: RelayKind? = null,
        models: List<AIModel> = emptyList(),
    ): Provider = Provider(
        id = id,
        kind = kind,
        status = ProviderConnectionState.Connected,
        models = models,
        customName = customName,
        baseUrlText = baseUrlText,
        relayKind = relayKind,
    )

    private fun instant(value: String): Instant = Instant.parse(value)
}
