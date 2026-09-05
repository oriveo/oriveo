package ai.oriveo.community.core.model

import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color


enum class FolderColor(
    val tag: String,
    private val mainHex: Long,
    private val darkHex: Long,
) {
    BLUE("blue", 0xFF3B82F6, 0xFF2563EB),
    PURPLE("purple", 0xFF8B5CF6, 0xFF7C3AED),
    PINK("pink", 0xFFEC4899, 0xFFDB2777),
    RED("red", 0xFFEF4444, 0xFFDC2626),
    ORANGE("orange", 0xFFF97316, 0xFFEA580C),
    YELLOW("yellow", 0xFFEAB308, 0xFFCA8A04),
    GREEN("green", 0xFF22C55E, 0xFF16A34A),
    TEAL("teal", 0xFF14B8A6, 0xFF0D9488),
    INDIGO("indigo", 0xFF6366F1, 0xFF4F46E5),
    GRAY("gray", 0xFF6B7280, 0xFF4B5563);

    private val mainColor: Color by lazy { Color(mainHex) }
    private val darkColor: Color by lazy { Color(darkHex) }
    
    
    private val cachedGradient: Brush by lazy {
        Brush.linearGradient(colors = listOf(mainColor, darkColor))
    }

    fun toColor(): Color = mainColor

    fun gradientBrush(): Brush = cachedGradient

    companion object {
        private val ordered: List<FolderColor> = entries

        
        fun fromTag(tag: String?): FolderColor =
            entries.find { it.tag == tag } ?: BLUE

        
        fun nextColor(folders: List<Folder>): FolderColor {
            val lastFolder = folders.sortedBy { it.sortOrder }.lastOrNull()
                ?: return BLUE
            val lastColor = fromTag(lastFolder.colorTag)
            val lastIndex = ordered.indexOf(lastColor)
            return ordered[(lastIndex + 1) % ordered.size]
        }
    }
}
