package ai.oriveo.community.core.provider.relay

import ai.oriveo.community.core.model.RelayRequestedConfig
import ai.oriveo.community.core.model.RelayTransport

/**
 * Which protocol to try first when probing per model. It only decides the order of the 1-token probes:
 * it is not a source, stores no value and is not displayed. The rules match `shared/test-fixtures/relay/probe-orchestration.v1.json`
 * `candidateRules` word for word.
 */
object RelayProbeCandidates {
    const val MAX_CANDIDATES = 2

    private val endpointTypeToCandidate: Map<String, RelayTransport> = mapOf(
        "openai" to RelayTransport.OpenAIChatCompletions,
        "openai-response" to RelayTransport.OpenAIResponses,
        "anthropic" to RelayTransport.AnthropicMessages,
        "gemini" to RelayTransport.GeminiGenerateContent,
    )

    private val familyCandidates: Map<String, List<RelayTransport>> = mapOf(
        "anthropic" to listOf(RelayTransport.AnthropicMessages, RelayTransport.OpenAIChatCompletions),
        "google" to listOf(RelayTransport.GeminiGenerateContent, RelayTransport.OpenAIChatCompletions),
        "openai" to listOf(RelayTransport.OpenAIResponses, RelayTransport.OpenAIChatCompletions),
    )

    private val defaultCandidates: List<RelayTransport> = listOf(RelayTransport.OpenAIChatCompletions)

    /**
     * The connection protocol was chosen by the user (not Auto) (`candidateRules.explicitConnection`): models without a protocol of their own
     * always follow the connection - enabling and re-detection do not probe or write model fields, and protocol fallback at send time has no other candidates;
     * endpoint types, the family lookup and the generation route are all ignored for this connection.
     */
    fun connectionIsExplicit(requested: RelayRequestedConfig?): Boolean =
        requested?.transport?.let { it != RelayTransport.Auto } == true

    /** The gateway catalog's `supported_endpoint_types` are mapped in array order, dropping unknown and duplicate entries. */
    fun fromEndpointTypes(types: List<String>?): List<RelayTransport> =
        types.orEmpty().mapNotNull(endpointTypeToCandidate::get).distinct().take(MAX_CANDIDATES)

    /** Family given by the by-model view; no match / unknown family / view unavailable (null) all try Chat only. */
    fun forFamily(family: String?): List<RelayTransport> =
        (family?.let(familyCandidates::get) ?: defaultCandidates).take(MAX_CANDIDATES)

    /**
     * First look at the catalog's endpoint types, and look up the family only when no protocol can be mapped; the family lookup is called only when needed.
     * The family is never guessed from the model id text.
     */
    suspend fun candidates(
        supportedEndpointTypes: List<String>?,
        modelID: String,
        family: suspend (String) -> String?,
    ): List<RelayTransport> {
        fromEndpointTypes(supportedEndpointTypes).takeIf { it.isNotEmpty() }?.let { return it }
        return forFamily(family(modelID))
    }

    /**
     * When no catalog was fetched at add time and the protocol [route] was found only via the generation route (generationRouteCases): it comes first,
     * followed by the result of [candidates], deduplicated, at most [MAX_CANDIDATES]. When [route] is null this is just [candidates].
     */
    suspend fun withGenerationRoute(
        route: RelayTransport?,
        supportedEndpointTypes: List<String>?,
        modelID: String,
        family: suspend (String) -> String?,
    ): List<RelayTransport> =
        (listOfNotNull(route) + candidates(supportedEndpointTypes, modelID, family)).distinct().take(MAX_CANDIDATES)
}
