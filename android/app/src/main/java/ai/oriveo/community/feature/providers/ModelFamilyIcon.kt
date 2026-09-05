package ai.oriveo.community.feature.providers

import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.HelpOutline
import androidx.compose.material.icons.filled.Bolt
import androidx.compose.material.icons.outlined.Air
import androidx.compose.material.icons.outlined.AutoAwesome
import androidx.compose.material.icons.outlined.DarkMode
import androidx.compose.material.icons.outlined.DeveloperBoard
import androidx.compose.material.icons.outlined.Diamond
import androidx.compose.material.icons.outlined.Eco
import androidx.compose.material.icons.outlined.Functions
import androidx.compose.material.icons.outlined.GridOn
import androidx.compose.material.icons.outlined.LooksOne
import androidx.compose.material.icons.outlined.Memory
import androidx.compose.material.icons.outlined.Psychology
import androidx.compose.material.icons.outlined.Search
import androidx.compose.ui.graphics.vector.ImageVector


internal object ModelFamilyIcon {
    fun familyIcon(modelName: String): ImageVector {
        val lower = modelName.lowercase()

        if (lower.startsWith("o1") || lower.startsWith("o3") || lower.startsWith("o4")) {
            return Icons.Outlined.Psychology
        }
        if (lower.startsWith("gpt")) return Icons.Outlined.Memory
        if (lower.startsWith("claude")) return Icons.Outlined.AutoAwesome
        if (lower.startsWith("gemini")) return Icons.Outlined.Diamond
        if (lower.startsWith("grok")) return Icons.Filled.Bolt
        if (lower.startsWith("deepseek")) return Icons.Outlined.Search
        if (lower.startsWith("llama")) return Icons.Outlined.Eco
        if (lower.startsWith("mistral") || lower.startsWith("mixtral")) return Icons.Outlined.Air
        if (lower.startsWith("qwen")) return Icons.AutoMirrored.Outlined.HelpOutline
        if (lower.startsWith("kimi") || lower.startsWith("moonshot")) return Icons.Outlined.DarkMode
        if (lower.startsWith("glm") || lower.startsWith("chatglm")) return Icons.Outlined.GridOn
        if (lower.startsWith("yi-") || lower == "yi") return Icons.Outlined.LooksOne
        if (lower.startsWith("phi")) return Icons.Outlined.Functions
        return Icons.Outlined.DeveloperBoard
    }
}


internal fun shortenedModelName(raw: String): String {
    var s = raw

    val lastSlash = s.lastIndexOf('/')
    if (lastSlash >= 0) s = s.substring(lastSlash + 1)

    val datePatterns = listOf(
        Regex("""[-_]\d{4}-\d{2}-\d{2}(-?(preview|exp|latest))?$"""),
        Regex("""[-_]\d{8}(-?(preview|exp|latest))?$"""),
        Regex("""[-_]\d{6}(-?(preview|exp|latest))?$"""),
    )
    for (pattern in datePatterns) {
        val m = pattern.find(s)
        if (m != null) {
            s = s.removeRange(m.range)
            break
        }
    }

    return s
}
