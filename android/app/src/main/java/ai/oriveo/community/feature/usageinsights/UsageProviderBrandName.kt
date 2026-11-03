package ai.oriveo.community.feature.usageinsights

import ai.oriveo.community.core.model.ProviderKind
import java.util.Locale

/**
 * Provider name shown on the usage page when the user has no custom name for it.
 * Known kinds use the brand spelling (`openai` -> "OpenAI", `deepseek` -> "DeepSeek");
 * the usage API may send kinds in any case, so the lookup is case-insensitive.
 * Unknown kinds fall back to the raw string with its first letter capitalized.
 * Full chain at call sites mirrors iOS: custom name -> brand name -> capitalized raw kind -> label.
 */
fun usageProviderBrandName(kind: String): String {
    val known = ProviderKind.fromRawValue(kind)
        ?: ProviderKind.entries.firstOrNull { it.rawValue.equals(kind, ignoreCase = true) }
    return known?.displayName ?: kind.replaceFirstChar { it.titlecase(Locale.ROOT) }
}
