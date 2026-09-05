package ai.oriveo.community.core.provider

import ai.oriveo.community.core.model.ProviderKind
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/**
 * Builds the body of a Relay liveness probe (ping).
 *
 * Note: BYOK key validation for the built-in providers lives in [ProviderKeyValidator], which skips
 * model probing and looks only at the HTTP status code, so it does not use the chat ping built here.
 * This object serves exactly one caller,
 * [ai.oriveo.community.core.provider.relay.RelayTransportCoordinator], when it pings an Anthropic or
 * Gemini transport: those two need a minimal request body, and it must carry max_tokens.
 */
internal object ProviderValidationStrategy {
    /** Smallest output token budget for a Relay ping body, so the probe never triggers real generation. */
    private const val PING_MAX_TOKENS = 1

    fun anthropicBody(providerKind: ProviderKind, modelId: String): String {
        return applyBodyParams(
            providerKind = providerKind,
            body = buildJsonObject {
                put("model", modelId)
                put("max_tokens", PING_MAX_TOKENS)
                put(
                    "messages",
                    kotlinx.serialization.json.JsonArray(
                        listOf(
                            buildJsonObject {
                                put("role", "user")
                                put("content", "ping")
                            }
                        )
                    )
                )
            },
        ).toString()
    }

    fun geminiBody(providerKind: ProviderKind): String {
        return applyBodyParams(
            providerKind = providerKind,
            body = buildJsonObject {
                put(
                    "contents",
                    kotlinx.serialization.json.JsonArray(
                        listOf(
                            buildJsonObject {
                                put("role", "user")
                                put(
                                    "parts",
                                    kotlinx.serialization.json.JsonArray(
                                        listOf(buildJsonObject { put("text", "ping") })
                                    )
                                )
                            }
                        )
                    )
                )
                put(
                    "generationConfig",
                    buildJsonObject {
                        put("maxOutputTokens", PING_MAX_TOKENS)
                    }
                )
            },
        ).toString()
    }

    private fun applyBodyParams(providerKind: ProviderKind, body: JsonObject): JsonObject {
        val bodyParams = defaultBodyParams(providerKind) ?: return body
        return merge(body, bodyParams)
    }

    private fun defaultBodyParams(providerKind: ProviderKind): JsonObject? {
        return when (providerKind) {
            ProviderKind.Moonshot -> buildJsonObject {
                put("thinking", buildJsonObject { put("type", "disabled") })
            }
            else -> null
        }
    }

    private fun merge(base: JsonObject, overrides: JsonObject): JsonObject {
        return buildJsonObject {
            for ((key, value) in base) {
                put(key, value)
            }
            for ((key, value) in overrides) {
                val current = base[key]
                if (current is JsonObject && value is JsonObject) {
                    put(key, merge(current, value))
                } else {
                    put(key, value)
                }
            }
        }
    }
}
