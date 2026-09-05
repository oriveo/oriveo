package ai.oriveo.community.core.provider.transport

import ai.oriveo.community.core.model.AIModel
import kotlinx.serialization.json.Json

/**
 * Registry of transport strategies.
 *
 * Holds one singleton per [TransportKind] and dispatches either by
 * [AIModel.transportKind] or by the raw transport string the catalog published.
 *
 * Unknown kinds have two escape hatches:
 * - [strategyForWireValue] returns null, and the caller is expected to filter
 *   that model out of the picker
 * - [requireStrategy] throws [UnsupportedTransportException], which the model
 *   selection layer catches
 *
 * Instances come from Koin; tests can construct one directly with a mock Json.
 */
class TransportRegistry(json: Json) {
    private val strategies: Map<TransportKind, TransportStrategy> = mapOf(
        TransportKind.OpenAIChat to OpenAIChatStrategy(json),
        TransportKind.OpenAIResponses to OpenAIResponsesStrategy(json),
        TransportKind.AnthropicMessages to AnthropicMessagesStrategy(json),
        TransportKind.GeminiGenerate to GeminiGenerateStrategy(json),
        TransportKind.DashScopeNative to DashScopeNativeStrategy(json),
        TransportKind.OpenAIImages to OpenAIImagesStrategy(json),
        TransportKind.GeminiImage to GeminiImageStrategy(json),
        TransportKind.QwenImage to QwenImageStrategy(json),
        TransportKind.GrokImage to GrokImageStrategy(json),
        TransportKind.ZhipuImage to ZhipuImageStrategy(json),
        TransportKind.AnthropicFiles to AnthropicFilesStrategy(json),
        TransportKind.OpenAIFiles to OpenAIFilesStrategy(json),
    )

    /** Looks up the strategy for a [TransportKind]; a known kind always resolves. */
    fun strategy(kind: TransportKind): TransportStrategy =
        strategies[kind] ?: throw IllegalStateException("TransportKind $kind not registered")

    /**
     * Looks up the strategy by raw wire string; an unknown value returns null and
     * the caller is responsible for filtering the model out.
     */
    fun strategyForWireValue(rawKind: String?): TransportStrategy? {
        val kind = TransportKind.fromWireValue(rawKind) ?: return null
        return strategies[kind]
    }

    /**
     * Strict variant that throws [UnsupportedTransportException] on an unknown wire
     * value. Use it downstream of a code path that has already filtered unknown
     * models out.
     */
    fun requireStrategy(rawKind: String): TransportStrategy {
        return strategyForWireValue(rawKind)
            ?: throw UnsupportedTransportException(rawKind)
    }
}
