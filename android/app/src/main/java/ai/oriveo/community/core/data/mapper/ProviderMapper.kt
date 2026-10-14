package ai.oriveo.community.core.data.mapper

import ai.oriveo.community.core.data.database.LOCAL_PARTITION_ID
import ai.oriveo.community.core.data.entity.ProviderEntity
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderAuthMode
import ai.oriveo.community.core.model.ProviderConnectionState
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.RelayKey
import ai.oriveo.community.core.model.RelayKeyStatus
import ai.oriveo.community.core.model.RelayKind
import ai.oriveo.community.core.provider.LocalEngineGenerationProfiles
import ai.oriveo.community.core.provider.ModelSelectionUtils
import ai.oriveo.community.core.util.normalizeProviderIds
import ai.oriveo.community.core.util.normalizeUuid
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.longOrNull

object ProviderMapper {

    private val json = Json { ignoreUnknownKeys = true; coerceInputValues = true }

    /**
     * [relayKeySecret] looks up the value of a non-primary key by key id (SecureKeyStore); it is only called when this row has a key list.
     * By default nothing is filled in (paths that send no request, such as sync merging, do not need key values, and writing back will not overwrite stored ones).
     */
    fun ProviderEntity.toDomain(
        apiKey: String = "",
        relayKeySecret: (String) -> String? = { null },
    ): Provider = normalizeProviderIds(
        Provider(
            id = id,
            kind = ProviderKind.valueOf(kind),
            status = json.decodeFromString<ProviderConnectionState>(status),
            // The enabled list of a relay is also deduplicated by literal key; an official enabled list is kept as is.
            models = json.decodeFromString<List<AIModel>>(modelsJson).let { decoded ->
                val providerKind = ProviderKind.valueOf(kind)
                if (providerKind == ProviderKind.Relay) ModelSelectionUtils.deduplicate(decoded, providerKind) else decoded
            },
            catalogModels = ModelSelectionUtils.deduplicate(
                json.decodeFromString<List<AIModel>>(catalogModelsJson),
                ProviderKind.valueOf(kind),
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
            endpointSource = endpointSource,
            setupValues = setupValuesJson.decodeOptional<Map<String, String>>(),
            relayKeys = decodeRelayKeys(relayKeysJson)?.mapIndexed { index, key ->
                if (index == 0) key else key.copy(apiKey = relayKeySecret(key.id).orEmpty())
            },
        ).recoveredFromPersistence().withCurrentLocalEngineProfiles()
    )

    // Local engine parameter tables are constants shipped with the app; a persisted copy may come from an
    // older build (for example one without `strict`), so reads always use the current table.
    private val LOCAL_ENGINES_REFRESHED_ON_READ = setOf("ollama", "lmstudio", "vllm")

    private fun Provider.withCurrentLocalEngineProfiles(): Provider {
        val requested = relayRequested ?: return this
        if (requested.engineProfile !in LOCAL_ENGINES_REFRESHED_ON_READ) return this
        val current = LocalEngineGenerationProfiles.profile(requested.engineProfile, requested.transport) ?: return this
        fun refresh(list: List<AIModel>) = list.map { if (it.generationProfile == current) it else it.copy(generationProfile = current) }
        return copy(models = refresh(models), catalogModels = refresh(catalogModels))
    }

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
        endpointSource = endpointSource,
        setupValuesJson = setupValues.encodeOptional(),
        // Key values never go into Room: after clearing, the apiKey entry is omitted as a default value.
        relayKeysJson = relayKeys?.map { it.copy(apiKey = "") }.encodeOptional(),
    )

    /**
     * Tolerant decoding: anything that is not an array counts as no list; entries whose id is not a non-empty string, or duplicates an earlier one, are dropped one by one;
     * a name that is not a string counts as absent; a status that is not an object, or whose state is not in the vocabulary, counts as unchecked. If no entry is left there is no list.
     */
    internal fun decodeRelayKeys(raw: String?): List<RelayKey>? {
        val text = raw?.takeIf { it.isNotBlank() } ?: return null
        val items = runCatching { json.parseToJsonElement(text) }.getOrNull() as? JsonArray ?: return null
        fun JsonElement?.string(): String? = (this as? JsonPrimitive)?.takeIf { it.isString }?.content
        val seen = mutableSetOf<String>()
        return items.mapNotNull { item ->
            val entry = item as? JsonObject ?: return@mapNotNull null
            val id = entry["id"].string()?.takeIf { it.isNotEmpty() && seen.add(it) } ?: return@mapNotNull null
            val status = (entry["status"] as? JsonObject)?.let { status ->
                val state = status["state"].string()?.takeIf { it in RelayKeyStatus.STATES } ?: return@let null
                RelayKeyStatus(
                    state = state,
                    httpStatus = (status["httpStatus"] as? JsonPrimitive)?.takeIf { !it.isString }?.intOrNull,
                    checkedAt = (status["checkedAt"] as? JsonPrimitive)?.takeIf { !it.isString }?.longOrNull,
                )
            }
            RelayKey(id = id, name = entry["name"].string(), status = status)
        }.ifEmpty { null }
    }

    private inline fun <reified T> String?.decodeOptional(): T? {
        val value = this?.takeIf { it.isNotBlank() } ?: return null
        return json.decodeFromString(value)
    }

    private inline fun <reified T> T?.encodeOptional(): String? {
        return this?.let { json.encodeToString(it) }
    }
}
