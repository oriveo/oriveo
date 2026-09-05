package ai.oriveo.community.core.data.repository.conversation

import ai.oriveo.community.core.data.database.LOCAL_PARTITION_ID
import ai.oriveo.community.core.data.dao.MessageDao
import ai.oriveo.community.core.data.entity.ProviderUsageByModelRow
import ai.oriveo.community.core.model.CostFormatter
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.usage.CostSummarySource
import ai.oriveo.community.core.usage.MonthlyCostProviderEntry
import ai.oriveo.community.core.usage.MonthlyCostSummary
import ai.oriveo.community.core.usage.ProviderUsageModelEntry
import ai.oriveo.community.core.usage.ProviderUsageSummary
import ai.oriveo.community.core.usage.ProviderUsageWindow
import ai.oriveo.community.core.usage.UsageDataSource
import ai.oriveo.community.core.util.normalizeUuid
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.flow.map
import java.time.Duration
import java.time.Instant
import java.time.ZoneOffset
import java.time.temporal.ChronoUnit

/**
 * Local spend and token totals, aggregated straight out of the message table.
 *
 * Everything here is computed with SQL rather than by loading conversations and folding over them
 * in Kotlin: a few thousand messages is a millisecond in the database and a visible stall on the
 * main thread.
 */
internal class ConversationUsageAnalytics(
    private val messageDao: MessageDao,
) {
    private data class MonthlyCostWindow(
        val startMillis: Long,
        val endMillis: Long,
        val endExclusive: Instant,
    )

    /**
     * Monthly spend grouped by (provider kind, provider id) rather than by kind alone, so two
     * relay connections to different endpoints do not collapse into one row.
     *
     * The name here is the kind's generic display name: the user's custom name for a connection
     * lives on the provider row, not on messages, so the caller joins it in.
     */
    @OptIn(ExperimentalCoroutinesApi::class)
    fun observeMonthlyCostSummary(visibleProviderLimit: Int = 3): Flow<MonthlyCostSummary> {
        return observeCurrentMonthWindow().flatMapLatest { window ->
            val aid = LOCAL_PARTITION_ID
            messageDao.observeMonthlyCostByProviderKind(
                accountId = aid,
                minimumCostExclusive = CostFormatter.COST_EPSILON,
                windowStartMillis = window.startMillis,
                windowEndMillis = window.endMillis,
            ).map { rows ->
                val sortedProviders = rows
                    .mapNotNull { row ->
                        val kind = runCatching { ProviderKind.valueOf(row.providerKind) }.getOrNull()
                            ?: return@mapNotNull null
                        MonthlyCostProviderEntry(
                            providerKind = kind,
                            providerID = row.providerID,
                            displayName = kind.displayName,
                            cost = row.totalCost,
                        )
                    }
                    .sortedWith(
                        compareByDescending<MonthlyCostProviderEntry> { it.cost }
                            .thenBy { it.displayName },
                    )

                MonthlyCostSummary(
                    totalCost = sortedProviders.sumOf { it.cost },
                    providers = sortedProviders.take(visibleProviderLimit),
                    hiddenProviderCount = maxOf(0, sortedProviders.size - visibleProviderLimit),
                    source = CostSummarySource.LocalDevice,
                )
            }
        }
    }

    /** Total spend this month, for callers that need a number rather than a stream. */
    suspend fun currentMonthlyCostTotal(): Double {
        val aid = LOCAL_PARTITION_ID
        val window = monthWindowAt(Instant.now())
        val rows = messageDao.getMonthlyCostByProviderKind(
            accountId = aid,
            minimumCostExclusive = CostFormatter.COST_EPSILON,
            windowStartMillis = window.startMillis,
            windowEndMillis = window.endMillis,
        )
        return rows.sumOf { it.totalCost }
    }

    /** Monthly spend keyed by the provider id each conversation was started with. */
    @OptIn(ExperimentalCoroutinesApi::class)
    fun observeMonthlyCostByConversationProvider(): Flow<Map<String, Double>> {
        return observeCurrentMonthWindow().flatMapLatest { window ->
            val aid = LOCAL_PARTITION_ID
            messageDao.observeMonthlyCostByConversationProvider(
                accountId = aid,
                minimumCostExclusive = CostFormatter.COST_EPSILON,
                windowStartMillis = window.startMillis,
                windowEndMillis = window.endMillis,
            ).map { rows ->
                rows.associate { normalizeUuid(it.providerId) to it.totalCost }
            }
        }
    }

    /**
     * Per-model spend for one provider, as shown on its detail screen. Scoped by provider id so a
     * second connection to the same vendor keeps its own totals.
     */
    @OptIn(ExperimentalCoroutinesApi::class)
    fun observeProviderLocalUsageSummary(
        provider: ai.oriveo.community.core.model.Provider,
        visibleModelLimit: Int = 3,
    ): Flow<ProviderUsageSummary> {
        return observeCurrentMonthWindow().flatMapLatest { window ->
            val aid = LOCAL_PARTITION_ID
            messageDao.observeProviderUsageByModel(
                accountId = aid,
                providerId = provider.id,
                minimumCostExclusive = CostFormatter.COST_EPSILON,
                windowStartMillis = window.startMillis,
                windowEndMillis = window.endMillis,
            ).map { rows ->
                buildProviderUsageSummary(provider, rows, visibleModelLimit)
            }
        }
    }

    private fun buildProviderUsageSummary(
        provider: ai.oriveo.community.core.model.Provider,
        rows: List<ProviderUsageByModelRow>,
        visibleModelLimit: Int,
    ): ProviderUsageSummary {
        if (rows.isEmpty()) return emptyProviderUsageSummary(provider)
        val thisMonthAll = rows
            .filter { it.thisMonthCost > CostFormatter.COST_EPSILON }
            .map {
                ProviderUsageModelEntry(
                    modelKey = it.modelName.orEmpty(),
                    modelName = it.modelName.orEmpty().ifEmpty { "Unknown Model" },
                    cost = it.thisMonthCost,
                    messages = it.thisMonthMessages,
                )
            }
            .sortedWith(compareByDescending<ProviderUsageModelEntry> { it.cost }.thenBy { it.modelName })

        val allTimeAll = rows
            .filter { it.allTimeCost > CostFormatter.COST_EPSILON }
            .map {
                ProviderUsageModelEntry(
                    modelKey = it.modelName.orEmpty(),
                    modelName = it.modelName.orEmpty().ifEmpty { "Unknown Model" },
                    cost = it.allTimeCost,
                    messages = it.allTimeMessages,
                )
            }
            .sortedWith(compareByDescending<ProviderUsageModelEntry> { it.cost }.thenBy { it.modelName })

        return ProviderUsageSummary(
            providerId = provider.id,
            providerName = provider.displayName,
            source = UsageDataSource.LocalDevice,
            thisMonth = ProviderUsageWindow(
                totalCost = thisMonthAll.sumOf { it.cost },
                totalMessages = thisMonthAll.sumOf { it.messages },
                models = thisMonthAll.take(visibleModelLimit),
                hiddenModelCount = maxOf(0, thisMonthAll.size - visibleModelLimit),
            ),
            allTime = ProviderUsageWindow(
                totalCost = allTimeAll.sumOf { it.cost },
                totalMessages = allTimeAll.sumOf { it.messages },
                models = allTimeAll.take(visibleModelLimit),
                hiddenModelCount = maxOf(0, allTimeAll.size - visibleModelLimit),
            ),
        )
    }

    private fun emptyProviderUsageSummary(provider: ai.oriveo.community.core.model.Provider) = ProviderUsageSummary(
        providerId = provider.id,
        providerName = provider.displayName,
        source = UsageDataSource.LocalDevice,
        thisMonth = ProviderUsageWindow(),
        allTime = ProviderUsageWindow(),
    )

    private fun observeCurrentMonthWindow(): Flow<MonthlyCostWindow> = flow {
        while (true) {
            val now = Instant.now()
            val window = monthWindowAt(now)
            emit(window)

            val waitMillis = Duration.between(now, window.endExclusive)
                .toMillis()
                .coerceAtLeast(1_000L)
            delay(waitMillis)
        }
    }.distinctUntilChanged()

    private fun monthWindowAt(now: Instant): MonthlyCostWindow {
        val windowStart = now.atZone(ZoneOffset.UTC)
            .withDayOfMonth(1)
            .truncatedTo(ChronoUnit.DAYS)
            .toInstant()
        val windowEnd = windowStart.atZone(ZoneOffset.UTC)
            .plusMonths(1)
            .toInstant()

        return MonthlyCostWindow(
            startMillis = windowStart.toEpochMilli(),
            endMillis = windowEnd.toEpochMilli(),
            endExclusive = windowEnd,
        )
    }
}
