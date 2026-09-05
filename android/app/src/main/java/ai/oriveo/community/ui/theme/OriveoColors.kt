package ai.oriveo.community.ui.theme

import androidx.compose.runtime.Immutable
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Color


@Immutable
data class OriveoColors(
    // ── Brand ──
    val primary: Color,
    val primaryPressed: Color,
    val primarySoft: Color,
    val primaryGlow: Color,
    
    val primaryTextSafe: Color,

    // ── Backgrounds ──
    val backgroundBase: Color,
    val background: Color,
    val backgroundSecondary: Color,
    val surface: Color,
    val surfaceElevated: Color,
    val surfaceInset: Color,
    val surfaceChrome: Color,

    // ── Text ──
    val textPrimary: Color,
    val textSecondary: Color,
    val textTertiary: Color,
    
    val textDisabledOnControl: Color,
    val textInverse: Color,

    // ── Borders ──
    val border: Color,
    val borderStrong: Color,
    val cardHighlight: Color,
    val hairline: Color,
    
    
    
    val glassHighlight: Color,

    
    
    val onPrimary: Color,
    val onSuccess: Color,
    val onWarning: Color,
    val onDanger: Color,
    val onInfo: Color,
    val switchThumb: Color,

    // ── Status ──
    val success: Color,
    val successSoft: Color,
    val warning: Color,
    val warningSoft: Color,
    
    val warningText: Color,
    val danger: Color,
    val dangerSoft: Color,
    
    val error: Color,
    val errorSoft: Color,
    val info: Color,
    val infoSoft: Color,

    // ── Chat bubbles ──
    val userBubble: Color,
    val assistantBubble: Color,

    // ── Overlay / Shadow ──
    val overlay: Color,
    val shadow: Color,
    val shadowStrong: Color,
    val tabBar: Color,

    
    val capReasoning: Color,
    val capReasoningBg: Color,
    val capReasoningBorder: Color,
    val capText: Color,
    val capTextBg: Color,
    val capTextBorder: Color,
    val capImage: Color,
    val capImageBg: Color,
    val capImageBorder: Color,
    val capFile: Color,
    val capFileBg: Color,
    val capFileBorder: Color,
    val capWeb: Color,
    val capWebBg: Color,
    val capWebBorder: Color,
    val capImageGen: Color,
    val capImageGenBg: Color,
    val capImageGenBorder: Color,
)


val LightOriveoColors = OriveoColors(
    // Brand — iOS: 0x8C5FF8
    primary = Color(0xFF8C5FF8),
    primaryPressed = Color(0xFF7B3DEF),
    primarySoft = Color(0xFFEDE9FE),
    primaryGlow = Color(0x1A8C5FF8),          // 10%
    primaryTextSafe = Color(0xFF6D28D9),

    // Backgrounds
    backgroundBase = Color(0xFFFFFFFF),
    background = Color(0xFFF8FAFC),
    backgroundSecondary = Color(0xB8EEF2FF),  // 72%
    surface = Color(0xF0FFFFFF),              // 94%
    surfaceElevated = Color(0xFAFFFFFF),      // 98%
    surfaceInset = Color(0xFFF8FAFC),
    surfaceChrome = Color(0xF5FFFFFF),        // 96%

    // Text
    textPrimary = Color(0xFF111827),
    textSecondary = Color(0xFF6B7280),
    textTertiary = Color(0xFF9CA3AF),
    textDisabledOnControl = Color(0xFF6A6A73),
    textInverse = Color(0xFFFFFFFF),

    
    
    border = Color(0x14000000),
    borderStrong = Color(0x29000000),
    cardHighlight = Color(0x00FFFFFF),
    hairline = Color(0xB3FFFFFF),             // 70%
    glassHighlight = Color(0x57FFFFFF),

    // On-* foreground
    onPrimary = Color(0xFFFFFFFF),
    onSuccess = Color(0xFFFFFFFF),
    onWarning = Color(0xFF18181B),
    onDanger = Color(0xFFFFFFFF),
    onInfo = Color(0xFFFFFFFF),
    switchThumb = Color(0xFFFFFFFF),

    // Status
    success = Color(0xFF10B981),
    successSoft = Color(0xFFECFDF5),
    warning = Color(0xFFF59E0B),
    warningSoft = Color(0xFFFFFBEB),
    warningText = Color(0xFF92400E),
    danger = Color(0xFFEF4444),
    dangerSoft = Color(0xFFFEF2F2),
    error = Color(0xFFEF4444),
    errorSoft = Color(0xFFFEF2F2),
    info = Color(0xFF3B82F6),
    infoSoft = Color(0x1A3B82F6),             // 10%

    // Chat
    userBubble = Color(0xFF8C5FF8),
    assistantBubble = Color(0xFFF3F4F6),

    // Overlay / Shadow
    overlay = Color(0x73000000),              // 45%
    shadow = Color(0x140F172A),               // 8%
    shadowStrong = Color(0x290F172A),          // 16%
    tabBar = Color(0xF0FFFFFF),               // 94%

    
    capReasoning = Color(0xFFB45309),
    capReasoningBg = Color(0xFFFEF3C7),
    capReasoningBorder = Color(0xFFFCD34D),
    capText = Color(0xFF6B7280),              // textSecondary
    capTextBg = Color(0xFFF3F4F6),
    capTextBorder = Color(0xFFD1D5DB),
    capImage = Color(0xFFBE185D),
    capImageBg = Color(0xFFFCE7F3),
    capImageBorder = Color(0xFFF9A8D4),
    capFile = Color(0xFF4338CA),
    capFileBg = Color(0xFFEDE9FE),
    capFileBorder = Color(0xFFC4B5FD),
    capWeb = Color(0xFF0F766E),
    capWebBg = Color(0xFFECFEFF),
    capWebBorder = Color(0xFFA5F3FC),
    capImageGen = Color(0xFF7C3AED),
    capImageGenBg = Color(0xFFEDE9FE),
    capImageGenBorder = Color(0xFFC4B5FD),
)


val DarkOriveoColors = OriveoColors(
    
    primary = Color(0xFFA78BFA),
    primaryPressed = Color(0xFFC4B5FD),
    primarySoft = Color(0x1FA78BFA),          // 12%
    primaryGlow = Color(0x388C5FF8),          // 22%
    primaryTextSafe = Color(0xFFA78BFA),

    
    backgroundBase = Color(0xFF0F1218),
    background = Color(0xFF14181F),
    backgroundSecondary = Color(0xFF181C24),
    surface = Color(0xFF1B1F2A),
    surfaceElevated = Color(0xFF252937),
    surfaceInset = Color(0xFF181C24),
    surfaceChrome = Color(0xEB14181F),        // 92%

    // Text
    textPrimary = Color(0xFFECEEF2),
    textSecondary = Color(0xFFB4BAC6),
    textTertiary = Color(0xFF8B919E),
    textDisabledOnControl = Color(0xFF9AA0AC),
    textInverse = Color(0xFF0F1218),

    
    border = Color(0x1AFFFFFF),               // 10%
    borderStrong = Color(0x2EFFFFFF),         // 18%
    cardHighlight = Color(0x14FFFFFF),         // 8%
    hairline = Color(0x0FFFFFFF),             // 6%
    glassHighlight = Color(0x14FFFFFF),

    
    onPrimary = Color(0xFF0F1218),
    onSuccess = Color(0xFF062A13),
    onWarning = Color(0xFF18181B),
    onDanger = Color(0xFF1F0A09),
    onInfo = Color(0xFF0A1A3D),
    switchThumb = Color(0xFFFFFFFF),

    
    success = Color(0xFF6EE7A1),
    successSoft = Color(0x246EE7A1),          // 14%
    warning = Color(0xFFFCD34D),
    warningSoft = Color(0x24FCD34D),          // 14%
    warningText = Color(0xFFFCD34D),
    danger = Color(0xFFF8978F),
    dangerSoft = Color(0x24F8978F),           // 14%
    error = Color(0xFFF8978F),
    errorSoft = Color(0x24F8978F),            // 14%
    info = Color(0xFF8DB6FF),
    infoSoft = Color(0x248DB6FF),             // 14%

    
    userBubble = Color(0xFF7C5BEE),
    assistantBubble = Color(0xFF1B1F2A),      // = surface

    // Overlay / Shadow
    overlay = Color(0xB8000000),              // 72%
    shadow = Color(0x57000000),               // 34%
    shadowStrong = Color(0x8F000000),         // 56%
    tabBar = Color(0xE014181F),               // 88%

    
    capReasoning = Color(0xFFFBBF24),
    capReasoningBg = Color(0x26B45309),       // 15%
    capReasoningBorder = Color(0x47B45309),   // 28%
    capText = Color(0xFFB4C1D9),              // textSecondary
    capTextBg = Color(0x29334155),            // 16%
    capTextBorder = Color(0x3D94A3B8),        // 24%
    capImage = Color(0xFFF472B6),
    capImageBg = Color(0x26BE185D),           // 15%
    capImageBorder = Color(0x47BE185D),       // 28%
    capFile = Color(0xFFA5B4FC),
    capFileBg = Color(0x294338CA),            // 16%
    capFileBorder = Color(0x474338CA),        // 28%
    capWeb = Color(0xFF5EEAD4),
    capWebBg = Color(0x290F766E),             // 16%
    capWebBorder = Color(0x470F766E),         // 28%
    capImageGen = Color(0xFFC4B5FD),
    capImageGenBg = Color(0x267C3AED),        // 15%
    capImageGenBorder = Color(0x477C3AED),    // 28%
)

val LocalOriveoColors = staticCompositionLocalOf { LightOriveoColors }
val LocalIsDarkTheme = staticCompositionLocalOf { false }


fun Color.opacity(factor: Float): Color = copy(alpha = alpha * factor)


val DarkV2OriveoColors = DarkOriveoColors


val LightV2OriveoColors = LightOriveoColors.copy(
    // iOS V2: borderDefault light = black @ 6%
    border = Color(0x0F000000),
    // iOS V2: borderEmphasis light = black @ 12%
    borderStrong = Color(0x1F000000),
)
