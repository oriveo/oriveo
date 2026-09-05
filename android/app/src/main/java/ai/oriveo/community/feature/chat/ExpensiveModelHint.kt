package ai.oriveo.community.feature.chat

import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.provider.ProviderSelectionSnapshot


data class ExpensiveModelHint(
    val newModelName: String,
    val oldModelName: String,
    val multiplier: Int,
)

private const val EXPENSIVE_MODEL_RATIO_THRESHOLD = 5.0


fun evaluateExpensiveModelMultiplier(
    oldPromptPrice: Double?,
    newPromptPrice: Double?,
    threshold: Double = EXPENSIVE_MODEL_RATIO_THRESHOLD,
): Int? {
    if (oldPromptPrice == null || newPromptPrice == null || oldPromptPrice <= 0) return null
    val ratio = newPromptPrice / oldPromptPrice
    return if (ratio > threshold) ratio.toInt() else null
}


fun evaluateExpensiveModelHint(
    providers: List<Provider>,
    oldProviderId: String?,
    oldModelId: String?,
    newProviderId: String,
    newModelId: String,
): ExpensiveModelHint? {
    val oldModel = oldProviderId?.let { pid ->
        oldModelId?.let { mid ->
            ProviderSelectionSnapshot.selectedModel(
                provider = providers.firstOrNull { it.id == pid },
                modelId = mid,
            )
        }
    }
    val newModel = ProviderSelectionSnapshot.selectedModel(
        provider = providers.firstOrNull { it.id == newProviderId },
        modelId = newModelId,
    )
    val multiplier = evaluateExpensiveModelMultiplier(oldModel?.promptPrice, newModel?.promptPrice)
    return if (multiplier != null && oldModel != null && newModel != null) {
        ExpensiveModelHint(
            newModelName = newModel.name,
            oldModelName = oldModel.name,
            multiplier = multiplier,
        )
    } else {
        null
    }
}
