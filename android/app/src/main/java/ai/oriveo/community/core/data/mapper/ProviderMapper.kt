package ai.oriveo.community.core.data.mapper

import ai.oriveo.community.core.data.database.LOCAL_PARTITION_ID
import ai.oriveo.community.core.data.entity.ProviderEntity
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderAuthMode
import ai.oriveo.community.core.model.ProviderConnectionState
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.RelayKind
import ai.oriveo.community.core.provider.ModelSelectionUtils
import ai.oriveo.community.core.util.normalizeProviderIds
import ai.oriveo.community.core.util.normalizeUuid
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

object ProviderMapper {

    private val json = Json { ignoreUnknownKeys = true; coerceInputValues = true }

    fun ProviderEntity.toDomain(apiKey: String = ""): Provider = normalizeProviderIds(
        Provider(
            id = id,
            kind = ProviderKind.valueOf(kind),
            status = json.decodeFromString<ProviderConnectionState>(status),
            models = json.decodeFromString<List<AIModel>>(modelsJson),
            catalogModels = ModelSelectionUtils.deduplicateByCanonical(
                json.decodeFromString<List<AIModel>>(catalogModelsJson)
            ),
            lastCheckedAt = lastCheckedAt,
            apiKey = apiKey,
            apiKeyPreview = apiKeyPreview,
            lastError = lastError,
            baseUrlText = baseUrlText,
            customName = customName,
            relayKind = RelayKind.fromValue(relayKind),
            relayRequested = relayRequestedJson.decodeOptional(),
            relayImage = relayImageJson.decodeOptional(),
            updatedAt = updatedAt,
            cachedAvailableModelCount = cachedAvailableModelCount,
            authMode = ProviderAuthMode.fromRawValue(authMode),
        ).recoveredFromPersistence()
    )

    fun Provider.toEntity(accountId: String = LOCAL_PARTITION_ID): ProviderEntity = ProviderEntity(
        id = normalizeUuid(id),
        kind = kind.name,
        status = json.encodeToString(status),
        lastCheckedAt = lastCheckedAt,
        apiKeyPreview = apiKeyPreview,
        lastError = lastError,
        baseUrlText = baseUrlText,
        customName = customName,
        relayKind = relayKind?.value,
        modelsJson = json.encodeToString(models),
        catalogModelsJson = json.encodeToString(catalogModels),
        relayRequestedJson = relayRequested.encodeOptional(),
        relayImageJson = relayImage.encodeOptional(),
        updatedAt = updatedAt,
        accountId = accountId,
        cachedAvailableModelCount = cachedAvailableModelCount,
        authMode = authMode.rawValue,
    )

    private inline fun <reified T> String?.decodeOptional(): T? {
        val value = this?.takeIf { it.isNotBlank() } ?: return null
        return json.decodeFromString(value)
    }

    private inline fun <reified T> T?.encodeOptional(): String? {
        return this?.let { json.encodeToString(it) }
    }
}
