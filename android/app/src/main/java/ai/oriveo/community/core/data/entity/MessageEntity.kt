package ai.oriveo.community.core.data.entity

import androidx.room.ColumnInfo
import androidx.room.Entity
import androidx.room.ForeignKey
import androidx.room.Index

/** One message row. */
@Entity(
    tableName = "messages",
    primaryKeys = ["id", "accountId"],
    foreignKeys = [
        ForeignKey(
            entity = ConversationEntity::class,
            parentColumns = ["id", "accountId"],
            childColumns = ["conversationId", "accountId"],
            onDelete = ForeignKey.CASCADE,
        ),
    ],
    indices = [
        // The chat screen only ever reads one conversation ordered by sortOrder, so the composite
        // index answers that query without a sort step.
        Index(value = ["conversationId", "accountId", "sortOrder"]),
    ],
)
data class MessageEntity(
    /**
     * Case-insensitive so one UUID cannot become two rows. Different writers disagree on letter
     * case; under a binary collation the duplicate would also give the list two identical keys,
     * which makes rendering unstable rather than merely wasteful.
     */
    @ColumnInfo(collate = ColumnInfo.NOCASE)
    val id: String,
    /** See [ai.oriveo.community.core.data.database.LOCAL_PARTITION_ID]. */
    val accountId: String = "local",
    /** Case-insensitive for the same reason as [id], so the foreign key still matches. */
    @ColumnInfo(collate = ColumnInfo.NOCASE)
    val conversationId: String,
    val role: String,           // ChatRole raw value
    val text: String,
    @ColumnInfo(collate = ColumnInfo.NOCASE)
    val providerID: String? = null,
    val providerKind: String,   // ProviderKind raw value
    val providerName: String,
    val modelID: String? = null,
    val modelName: String,
    val servedModelID: String? = null,
    val estimatedCost: Double,
    val state: String,          // ChatMessageState raw value
    val errorTitle: String?,
    val errorDetail: String?,
    val attachmentsJson: String?, // JSON array of Attachment
    /** v22: immutable selected-text snapshot; null for messages without an Ask selection. */
    val quoteContextJson: String? = null,
    val createdAt: Long?,
    val sortOrder: Int,
    /** Cited sources as JSON. Only ever set on an assistant message. */
    val citationsJson: String? = null,
    /** Which capabilities actually ran for this message, as JSON. Diagnostics only. */
    val capabilityExecutionResultsJson: String? = null,
    /** Tool calls the model proposed that no connected executor could run. */
    val unhandledToolCallsJson: String? = null,
    /** Stable key for the notice shown when a tool call could not be executed. */
    val toolFallbackNotice: String? = null,
    /**
     * Whether a "retry without the custom fields" action should be offered.
     *
     * Set only when the provider rejected the request before the first token and the request
     * actually carried a user-supplied JSON fragment. No part of the provider's response body is
     * persisted; only this flag and the code below.
     */
    val customRetryWithoutFieldsAvailable: Boolean = false,
    val customRetryWithoutFieldsCode: String? = null,
    /** Reasoning text, for the models that return it separately from the answer. */
    val reasoningText: String? = null,
    /**
     * How long the model spent reasoning. Null when the provider did not report it, in which case
     * the reasoning section shows no duration rather than a zero.
     */
    val reasoningDurationMs: Long? = null,
    /**
     * Token counts as the provider reported them. Null means not reported, which is not the same
     * as zero: a cost built on a missing count would read as free.
     */
    val inputTokens: Int? = null,
    val outputTokens: Int? = null,
    val cachedInputTokens: Int? = null,
    val cacheCreationInputTokens: Int? = null,
    val cacheCreation5mTokens: Int? = null,
    val cacheCreation1hTokens: Int? = null,
    /** `CostSource` name: how the displayed cost was arrived at. */
    val costSource: String? = null,
)
