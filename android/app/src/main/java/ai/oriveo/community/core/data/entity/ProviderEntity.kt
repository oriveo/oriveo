package ai.oriveo.community.core.data.entity

import androidx.room.ColumnInfo
import androidx.room.Entity
import androidx.room.Index

/**
 * One configured provider connection.
 *
 * The model catalog is stored alongside the connection as JSON rather than in its own table: it is
 * always read whole, is rewritten whole on every refresh, and is only ever queried by provider.
 */
@Entity(
    tableName = "providers",
    primaryKeys = ["id", "accountId"],
    indices = [
        Index("accountId"),
        Index(value = ["accountId", "kind"]),
    ],
)
data class ProviderEntity(
    @ColumnInfo(collate = ColumnInfo.NOCASE)
    val id: String,
    /** `ProviderKind` raw value. */
    val kind: String,
    /** Serialized `ProviderConnectionState`. */
    val status: String,
    val lastCheckedAt: Long?,
    val apiKeyPreview: String,
    val lastError: String?,
    val baseUrlText: String?,
    val customName: String?,
    val relayKind: String? = null,
    /** JSON array of the models the user has enabled. */
    val modelsJson: String,
    /** JSON array of everything the provider offers, before the user's selection. */
    val catalogModelsJson: String,
    val relayRequestedJson: String? = null,
    val relayImageJson: String? = null,
    val updatedAt: Long,
    /** See [ai.oriveo.community.core.data.database.LOCAL_PARTITION_ID]. */
    val accountId: String = "local",
    /** Cached count so the provider list can show a number without parsing the catalog JSON. */
    val cachedAvailableModelCount: Int? = null,
    /**
     * How this connection authenticates: `apiKey`, or `subscription` for a sign-in the user
     * imported from their own machine. An unrecognized value falls back to `apiKey`, which fails
     * loudly on the next request rather than silently sending nothing.
     */
    val authMode: String = "apiKey",
)
