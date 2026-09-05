package ai.oriveo.community.core.provider

import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatMessageState
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.core.model.ProviderKind
import kotlinx.serialization.KSerializer
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.put
import java.io.File
import java.util.UUID

object MetadataTestFixtures {
    private val clientClass = MetadataClient::class.java
    private val json = Json { ignoreUnknownKeys = true }

    fun applyProviders(vararg specs: ProviderSpec) {
        val providerEntries = specs.joinToString(",") { it.toJsonBlock() }
        setTable("""{"version":1,"providers":{${providerEntries}}}""")
    }

    fun applyRaw(payload: String) {
        setTable(payload)
    }

    fun clear() = setTable(null)

    private fun setTable(payload: String?) {
        val tableField = clientClass.getDeclaredField("table").apply { isAccessible = true }
        // The snapshot a test injects is that test's view of the catalog, so treat it as confirmed for this session.
        // Otherwise the negative verdicts of library research routing (see snapshotConfirmed in LibraryResearchRouting.route)
        // could never be reached from a unit test.
        val confirmedField = clientClass.getDeclaredField("_snapshotConfirmedThisSession")
            .apply { isAccessible = true }
        confirmedField.setBoolean(MetadataClient.instance, payload != null)
        if (payload == null) {
            MetadataClient.instance.loadNetworkPayloadForTesting("{\"providers\":{}}", responseETag = null)
            tableField.set(MetadataClient.instance, null)
            confirmedField.setBoolean(MetadataClient.instance, false)
            return
        }

        // Use the same decode/publication boundary as a 200 network response: H8 projections
        // consume evidencePublication rather than the legacy table field.
        MetadataClient.instance.loadNetworkPayloadForTesting(payload, responseETag = "fixture-etag")

        val responseClass = clientClass.declaredClasses.first { it.simpleName == "MetadataResponse" }
        val companion = responseClass.getDeclaredField("Companion").apply { isAccessible = true }.get(null)
        @Suppress("UNCHECKED_CAST")
        val serializer = companion.javaClass.getDeclaredMethod("serializer").apply { isAccessible = true }
            .invoke(companion) as KSerializer<Any>
        val decoded = json.decodeFromString(serializer, payload)
        tableField.set(MetadataClient.instance, decoded)
    }

    // ──────────────────────────────────────────────────────────────────
    // capabilityRuntime envelope: with no runtime there is zero automatic configuration.
    
    // `ProviderRequestProfiles.applyCapabilityRuntimeRecipes` sets `authoritativeRuntime = true` outright whenever
    // `MetadataClient.capabilityRuntimeRequest` returns null, and the client does not fall back to a legacy profile.
    // So any fixture that wants to assert automatic configuration really reached the wire has to carry a genuine
    // capabilityRuntime envelope; supplying `profiles` alone injects nothing at all.
    // ──────────────────────────────────────────────────────────────────

    /**
     * The production registry itself plus the revision/generatedAt that only get filled in when it is served: a minimal
     * usable envelope.
     *
     * It reads `capability_runtime.v1.json` directly, which already holds recipes, controlDefinitions and sourceIndex,
     * rather than hand-writing a recipes constant. A false green of exactly that kind has been fixed before: a mock
     * supplied `recipes: {}`, so every auto_available carrying a recipeRef fell back to a legacy profile with
     * `dangling_recipe_ref`, which meant the assertion 'no legacy profile is consulted' was passing precisely because a
     * legacy profile was consulted.
     *
     * `RequestPreferenceResolver.validateEnvelope` requires schemaVersion(=2), revision, generatedAt, recipes,
     * controlDefinitions and sourceIndex to all be present; if one is missing the whole envelope is ignored.
     */
    fun capabilityRuntimeJson(revision: String = "sha256:android-fixture-runtime"): String {
        val registry = Json.parseToJsonElement(
            workspaceFile(
                "shared/capabilityrecipe/capability_runtime.v1.json",
            ).readText(),
        ).jsonObject
        return JsonObject(
            registry + mapOf(
                "revision" to JsonPrimitive(revision),
                "generatedAt" to JsonPrimitive("2026-08-15T00:00:00Z"),
            ),
        ).toString()
    }

    /**
     * The `capabilityControls` block of one model, as published for an exact provider/model/transport triple.
     *
     * The intent the user selects must also appear in [ControlSpec.availableIntents], otherwise
     * `ProviderRecipeRequestCompiler.compile` reports `intent_not_available` and the whole recipe stays off the wire.
     * The availableIntents for reasoning must be **kept in the ladder order** off < low < balanced < deep < max; out of
     * order they are rejected by `RequestPreferenceResolver.validateIntents` as `unordered_available_intents`. On the web
     * side the contract permits the single value `["force"]` and rejects anything else as `invalid_available_intent`.
     */
    data class ControlSpec(
        val capability: String,
        val recipeRef: String,
        val state: String = "auto_available",
        val availableIntents: List<String>? = null,
    )

    fun capabilityControlsJson(vararg controls: ControlSpec): String = buildJsonObject {
        controls.forEach { control ->
            put(
                control.capability,
                buildJsonObject {
                    put("state", control.state)
                    put("recipeRef", control.recipeRef)
                    control.availableIntents?.let { intents ->
                        put("availableIntents", JsonArray(intents.map(::JsonPrimitive)))
                    }
                },
            )
        }
    }.toString()

    /** Walks up from the working directory to find a path relative to the repository root. */
    private fun workspaceFile(relative: String): File {
        var dir: File? = File("").absoluteFile
        while (dir != null) {
            val candidate = File(dir, relative)
            if (candidate.exists()) return candidate
            dir = dir.parentFile
        }
        throw IllegalStateException("cannot find $relative")
    }

    data class ProviderSpec(
        val providerKind: ProviderKind,
        val defaultModelId: String? = null,
        val models: List<ModelSpec> = emptyList(),
        val resolveMap: Map<String, String> = emptyMap(),
        val transportBaseUrl: String? = null,
        val transportChatPath: String? = null,
        val transportResponsesPath: String? = null,
    ) {
        fun toJsonBlock(): String {
            val modelsJson = models.joinToString(",") { it.toJsonEntry() }
            val defaultJson = defaultModelId.safeQuoted()
            val resolveJson = if (resolveMap.isNotEmpty()) {
                val entries = resolveMap.entries.joinToString(",") { "\"${it.key}\":\"${it.value}\"" }
                "\"resolveMap\":{$entries},"
            } else ""
            val transportJson = if (transportBaseUrl != null || transportChatPath != null || transportResponsesPath != null) {
                val endpointParts = mutableListOf<String>()
                transportChatPath?.let { endpointParts.add("\"chat\":${it.safeQuoted()}") }
                transportResponsesPath?.let { endpointParts.add("\"responses\":${it.safeQuoted()}") }
                "\"transport\":{\"baseUrl\":${transportBaseUrl.safeQuoted()},\"endpoints\":{${endpointParts.joinToString(",")}}},"
            } else ""
            return "\"${providerKey(providerKind)}\":{\"defaultModelId\":$defaultJson,$resolveJson$transportJson\"models\":{$modelsJson}}"
        }
    }

    data class ModelSpec(
        val id: String,
        val canonicalModelId: String? = null,
        val displayName: String? = null,
        val contextLength: Int? = null,
        val promptPerToken: Double? = null,
        val completionPerToken: Double? = null,
        val created: Double? = null,
        val transport: String? = null,
    ) {
        fun toJsonEntry(): String {
            val parts = mutableListOf<String>()
            canonicalModelId?.let { parts.add("\"canonicalModelId\":${it.safeQuoted()}") }
            displayName?.let { parts.add("\"displayName\":${it.safeQuoted()}") }
            contextLength?.let { parts.add("\"contextLength\":$it") }
            if (promptPerToken != null || completionPerToken != null) {
                parts.add(
                    "\"pricing\":{\"promptPerMToken\":${promptPerToken.toPerMillion()},\"completionPerMToken\":${completionPerToken.toPerMillion()}}"
                )
            }
            created?.let { parts.add("\"created\":$it") }
            transport?.let { parts.add("\"transport\":${it.safeQuoted()}") }
            return "\"$id\":{${parts.joinToString(",")}}"
        }
    }

    private fun Double?.toPerMillion(): Double = (this ?: 0.0) * 1_000_000
    private fun String?.safeQuoted(): String = if (this == null) "null" else "\"$this\""

    private fun providerKey(providerKind: ProviderKind): String = when (providerKind) {
        ProviderKind.Together -> "togetherAI"
        ProviderKind.Fireworks -> "fireworksAI"
        else -> providerKind.rawValue
    }
}

object ProviderTestFixtures {
    fun userMessage(
        text: String,
        providerKind: ProviderKind,
        modelName: String,
    ) = ChatMessage(
        id = UUID.randomUUID().toString(),
        role = ChatRole.User,
        text = text,
        providerKind = providerKind,
        providerName = providerKind.displayName,
        modelID = modelName,
        modelName = modelName,
        state = ChatMessageState.Delivered,
    )

    fun anthropicEvent(event: String, data: String) = "event: $event\ndata: $data"

    fun anthropicStream(vararg events: String) = events.joinToString("\n\n", postfix = "\n\n")

    fun openAiChunk(
        delta: String? = null,
        promptTokens: Int = 0,
        completionTokens: Int = 0,
        model: String? = null,
    ): String {
        val modelJson = model?.let { "\"model\":\"$it\"," } ?: ""
        val deltaJson = delta?.let { "\"delta\":{\"content\":\"$it\"}" } ?: "\"delta\":{}"
        return "data: {$modelJson\"choices\":[{$deltaJson}],\"usage\":{\"prompt_tokens\":$promptTokens,\"completion_tokens\":$completionTokens}}"
    }

    fun openAiStream(vararg chunks: String) = buildString {
        chunks.forEach { appendLine(it) }
        appendLine("data: [DONE]")
    }

    fun geminiChunk(
        text: String,
        inlineData: String? = null,
        mimeType: String = "image/png",
        promptTokens: Int = 0,
        completionTokens: Int = 0,
    ): String {
        val parts = mutableListOf<String>()
        if (text.isNotEmpty()) parts.add("{\"text\":\"$text\"}")
        inlineData?.let {
            parts.add("""{"inlineData":{"mimeType":"$mimeType","data":"$it"}}""")
        }
        val partsJson = parts.joinToString(",")
        return "data: {\"candidates\":[{\"content\":{\"parts\":[$partsJson]}}],\"usageMetadata\":{\"promptTokenCount\":$promptTokens,\"candidatesTokenCount\":$completionTokens}}"
    }
}
