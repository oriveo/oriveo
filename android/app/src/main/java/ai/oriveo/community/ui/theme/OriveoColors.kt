package ai.oriveo.community.ui.theme

import androidx.compose.runtime.Immutable
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color

@Immutable
data class OriveoColors(
    // ── Brand ──
    val primary: Color,
    val primaryPressed: Color,
    val primarySoft: Color,
    val primaryGlow: Color,
    /** Faint primary wash behind selected rows and chips: light primary @ 8%, dark primary @ 15%. */
    val primarySubtle: Color,
    /**
     * `primary` used **as text** on light surfaces (links, chip labels, text buttons, icon tints).
     * Light: the palette's `textSafe`; dark: points back to `primary`, which already passes there.
     * Do not use it as a fill under `onPrimary` text: with bright custom seeds the light text-safe
     * shade is tuned for contrast against white page backgrounds, not against `onPrimary`.
     * Fills that carry `onPrimary` text use [primaryFillText].
     *
     * **`primary` itself is unchanged**: fills without text, icons and strokes keep the vivid value.
     */
    val primaryTextSafe: Color,
    /**
     * Fill that carries `onPrimary` text or glyphs (primary buttons, count badges, selected pills).
     * Light: the palette's `fillText`, so `onPrimary` on it stays >= 4.5:1 even for bright seeds;
     * dark: `primary` (see [linkDarkPaletteFields]). Mirrors iOS `primaryTextSafe`.
     */
    val primaryFillText: Color,
    /** Pressed (active) state of the primary color; per-palette dark values are in `shared/theme-contracts/dark-palettes.v1.json` as primaryActive. */
    val primaryActive: Color,
    /** Brand secondary color: the second color of gradients / the user bubble. */
    val accent: Color,
    /** Ambient glow intensity factor (every aurora layer's alpha is multiplied by it); 1 for light and most dark palettes. */
    val glowK: Float,

    // ── Backgrounds ──
    val backgroundBase: Color,
    val background: Color,
    val backgroundSecondary: Color,
    val surface: Color,
    val surfaceElevated: Color,
    val surfaceInset: Color,
    val surfaceChrome: Color,
    /** Neutral translucent fill for secondary capsule buttons (iOS tertiarySystemFill); palette-independent. */
    val neutralFill: Color,

    // ── Text ──
    val textPrimary: Color,
    val textSecondary: Color,
    val textTertiary: Color,
    /**
     * **Neutral color for disabled text inside controls** (the segmented unavailable tier and greyed-out options). Same name and value on all three platforms.
     *
     * Why it cannot keep using `textTertiary`: on the segmented track it is only 2.34:1 in light and 5.40:1 in dark,
     * far below AA 4.5 in the light tier. In this design, "disabled" is **not** expressed by lowering contrast;
     * what expresses disabled is "no response to taps + not bold + a persistent reason next to the control" (visual spec §6 item 6).
     * Lowering contrast is just another form of the `alpha(0.5)` prohibition.
     *
     * Measured (track = `backgroundSecondary` over the sheet): light 4.70:1 / dark 6.50:1.
     * `textTertiary` itself is unchanged: uses that are **not information-bearing**, such as chevrons, keep using it (non-text 3:1).
     */
    val textDisabledOnControl: Color,
    /** The unfinalized segment of dictation live text (colored inside the input box). Same name and value on all three platforms. */
    val dictationVolatile: Color,
    val textInverse: Color,

    // ── Borders ──
    val border: Color,
    val borderStrong: Color,
    val cardHighlight: Color,
    // cardSheen — the card-surface gradient overlay (skipped on surfaceElevated fills), split from
    // the decorative cardHighlight, matching iOS.
    val cardSheen: Color,
    val hairline: Color,
    // borderSubtle - quiet card stroke that stays visible on light surfaces (light black 4% / dark white 6%).
    val borderSubtle: Color,
    // glassHighlight - white glass highlight decoration across themes (the gloss line at the top of cards and capsules).
    // Unlike cardSheen (the card-surface gradient overlay, skipped on surfaceElevated fills),
    // glassHighlight is a decorative white sheen line on cards / capsules.
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
    /** Success color for text on light surfaces (iOS `Palette.successText`); dark: equals `success`. */
    val successText: Color,
    val warning: Color,
    val warningSoft: Color,

    val warningText: Color,
    /** Outline for conflict cards and similar "take a look, but not an error" states; a line only, never text. Same name and value on every platform (iOS `Palette.warningLine`). */
    val warningLine: Color,
    val danger: Color,
    val dangerSoft: Color,
    /** Danger color for text on light surfaces (iOS `Palette.dangerText`); dark: equals `danger`. */
    val dangerText: Color,
    // Keep the error / errorSoft aliases for easier Material3 integration
    val error: Color,
    val errorSoft: Color,
    val info: Color,
    val infoSoft: Color,
    /** Info color for text on light surfaces (iOS `Palette.infoText`); dark: equals `info`. */
    val infoText: Color,

    // ── Code block ──
    val codeBlockBg: Color,
    val codeBlockHeaderBg: Color,

    // ── Chat bubbles ──
    val assistantBubble: Color,

    // ── Overlay / Shadow ──
    val overlay: Color,
    val shadow: Color,
    val shadowStrong: Color,
    val tabBar: Color,

    // ── Memory page (iOS `Palette.backgroundGrouped / memoryAtlasDot / memoryHue.*`) ──
    /** Grouped page background: one step darker than background so cards float. */
    val backgroundGrouped: Color,
    /** Background dot grid of the memory atlas. */
    val memoryAtlasDot: Color,
    // The five hues are for graphics only (star dots, spectrum, group glyphs); text always uses the body color
    val memoryHueAbout: Color,
    val memoryHuePreferences: Color,
    val memoryHueInstructions: Color,
    val memoryHueWorkingOn: Color,
    val memoryHueEpisodic: Color,

    // ── Capability badge colors, aligned with iOS ModelCapabilityBadge ──
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
    primarySubtle = Color(0xFF8C5FF8).copy(alpha = 0.08f), // light-roles contract: primary @ 8%
    primaryTextSafe = Color(0xFF6D28D9),      // accent fill that carries text; aligned with iOS / Web
    primaryFillText = Color(0xFF6D28D9),      // fill under onPrimary text; same as textSafe on default palette
    primaryActive = Color(0xFF7B3DEF),        // light has no separate active step; reuses primaryPressed
    accent = Color(0xFF8C5FF8),               // light has no separate secondary color; equals primary
    glowK = 1f,

    // Backgrounds
    backgroundBase = Color(0xFFFAFAFA),       // contract bg
    background = Color(0xFFF4F4F5),           // contract bgSubtle
    backgroundSecondary = Color(0xFFF0F0F2),  // neutral inset, = contract bg-inset light
    surface = Color(0xFFFFFFFF),              // opaque card surface (contract surface)
    surfaceElevated = Color(0xFFFFFFFF),      // opaque raised surface (contract surfaceRaised)
    surfaceInset = Color(0xFFF8FAFC),
    surfaceChrome = Color(0xF5FFFFFF),        // 96%
    neutralFill = Color(0x1F767680),          // rgba(118,118,128,0.12)

    // Text
    textPrimary = Color(0xFF18181B),
    textSecondary = Color(0xFF52525B),
    textTertiary = Color(0xFF71717A),         // same as iOS light; 4.83:1 on white (was #9CA3AF, 2.5:1)
    textDisabledOnControl = Color(0xFF6A6A73), // disabled text inside controls; aligned with iOS / Web
    dictationVolatile = Color(0xFF71717A),     // unfinalized segment of dictation
    textInverse = Color(0xFFFFFFFF),

    // Borders - aligned with iOS border (light black @8%) / borderStrong (light black @16%): translucent black rather than a fixed grey,
    // so the edge deepens adaptively on any card background (the old fixed grey #E5E7EB looked cold and faint on non-white backgrounds); the stroke-width difference is compensated by OriveoBorderWidth 0.5dp
    border = Color(0x14000000),               // black @8%
    borderStrong = Color(0x29000000),           // black @16%
    cardHighlight = Color(0x8CFFFFFF),        // white 55%, matches iOS light card highlight
    cardSheen = Color(0x8CFFFFFF),            // white 55%, matches iOS light card sheen
    hairline = Color(0xB3FFFFFF),             // 70%
    borderSubtle = Color(0x0A000000),         // black 4%
    glassHighlight = Color(0x57FFFFFF),       // 34% white - light mode; white decorative highlight on light surfaces

    // On-* foreground
    onPrimary = Color(0xFFFFFFFF),
    onSuccess = Color(0xFFFFFFFF),
    onWarning = Color(0xFF18181B),
    onDanger = Color(0xFFFFFFFF),
    onInfo = Color(0xFFFFFFFF),
    switchThumb = Color(0xFFFFFFFF),

    // Status
    success = Color(0xFF10B981),
    successSoft = Color(0x1A10B981),          // 10%
    successText = Color(0xFF065F46),
    warning = Color(0xFFF59E0B),
    warningSoft = Color(0x1AF59E0B),          // 10%
    warningText = Color(0xFF92400E),
    warningLine = Color(0x66F59E0B),          // 40%
    danger = Color(0xFFEF4444),
    dangerSoft = Color(0x1AEF4444),           // 10%
    dangerText = Color(0xFFB91C1C),
    error = Color(0xFFEF4444),
    errorSoft = Color(0x1AEF4444),            // 10%
    info = Color(0xFF3B82F6),
    infoSoft = Color(0x1A3B82F6),             // 10%
    infoText = Color(0xFF1D4ED8),

    // Code block: in light the code block is also dark (the current MarkdownTheme value)
    codeBlockBg = Color(0xFF0B1220),
    codeBlockHeaderBg = Color(0xFF111A2E),

    // Chat
    assistantBubble = Color(0xFFF3F4F6),

    // Overlay / Shadow
    overlay = Color(0x73000000),              // 45%
    shadow = Color(0x140F172A),               // 8%
    shadowStrong = Color(0x290F172A),          // 16%
    tabBar = Color(0xF0FFFFFF),               // 94%

    // Memory page
    backgroundGrouped = Color(0xFFF4F4F6),
    memoryAtlasDot = Color(0x1A18181B),       // 10%
    memoryHueAbout = Color(0xFF4F46E5),
    memoryHuePreferences = Color(0xFF0D9488),
    memoryHueInstructions = Color(0xFFEA580C),
    memoryHueWorkingOn = Color(0xFF0891B2),
    memoryHueEpisodic = Color(0xFF7C3AED),

    // Capability: light mode, aligned with iOS ModelCapabilityBadge
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

// ── Light brand colors ──

/**
 * The hand-tuned brand colors of the default palette (`dark`) in the light appearance, value for value as in `dark-palettes.v1.json#light.palettes.dark`.
 * The first seven come from [LightOriveoColors]; the gradient ends / second brand color / page background / capsule fill are the hand-tuned values of the original home page and bubble.
 */
internal val DefaultLightBrand = OriveoLightBrand(
    ink = LightOriveoColors.primary,
    textSafe = LightOriveoColors.primaryTextSafe,
    fill = LightOriveoColors.primary,
    fillText = LightOriveoColors.primaryTextSafe,
    fillPressed = LightOriveoColors.primaryPressed,
    gradStart = Color(0xFF8347F5),
    gradEnd = Color(0xFF6B3BC7),
    onPrimary = LightOriveoColors.onPrimary,
    soft = LightOriveoColors.primarySoft,
    accent = Color(0xFFD946EF),
    bgTop = Color(0xFFF7F5FB),
    bgBottom = Color(0xFFF2EEF7),
    pill = Color(0xFFF3F0FA),
    mode = OriveoLightBrand.Mode.White,
)

/**
 * Hand-tuned point colors of the default palette in light (not among the thirteen light-brand fields): the default palette keeps them value for value,
 * and every other palette swaps them for a brand key through [OriveoLightBrand.tuned].
 */
internal object DefaultLightBrandTuned {
    /** The home page's light purple (accent / send button / soft glow / shadow / conversation row accent / home tab). */
    val homeViolet = Color(0xFF8B5CF6)

    /** Lavender of the home focus aurora ring. */
    val ringLavender = Color(0xFFA78BFA)

    /** Pale purple at the end of the home aurora ring / the start of the section rule. */
    val lavender = Color(0xFFC4B5FD)
}

// ── Dark Mode ──
// Machine mirror of the 7 dark palettes: `shared/theme-contracts/dark-palettes.v1.json` (aligned value by value across the three platforms).
// Change the JSON first before editing any dark value here, and keep the other platforms aligned.
//
// Each palette writes only the 15 color fields of the JSON plus glowK; derived fields that change with the palette (textInverse, assistantBubble,
// surfaceChrome, ...) are recomputed from the current palette by [linkDarkPaletteFields] and are written as Unspecified placeholders at construction.

// Dark status colors shared by the fill and the text token, so `*Text` cannot drift from the status color.
private val DarkStatusSuccess = Color(0xFF6EE7A1)
private val DarkStatusDanger = Color(0xFFF8978F)
private val DarkStatusInfo = Color(0xFF8DB6FF)

/** Default dark palette (JSON `dark`). */
val DarkOriveoColors = OriveoColors(
    // Brand
    primary = Color(0xFFA78BFA),
    primaryPressed = Color(0xFFC4B5FD),
    primaryActive = Color(0xFF9370F7),
    accent = Color(0xFFC4B5FD),
    glowK = 0.4f,
    primarySoft = Color.Unspecified,          // = primary @12%, see linkDarkPaletteFields
    primaryGlow = Color.Unspecified,          // = primary @35% (derived.primaryGlow)
    primarySubtle = Color.Unspecified,        // = primary @ 15% (derived.primarySubtle), see linkDarkPaletteFields
    primaryTextSafe = Color.Unspecified,      // = primary: the dark tier already passes
    primaryFillText = Color.Unspecified,      // = primary, see linkDarkPaletteFields

    // Backgrounds: 4 layers
    backgroundBase = Color(0xFF111113),
    background = Color(0xFF151517),
    backgroundSecondary = Color.Unspecified,  // = surfaceInset
    surface = Color(0xFF1C1C1F),
    surfaceElevated = Color(0xFF27272B),
    surfaceInset = Color(0xFF19191C),
    surfaceChrome = Color.Unspecified,        // = background @92%
    neutralFill = Color(0x3D767680),          // rgba(118,118,128,0.24)

    // Text
    textPrimary = Color(0xFFEDEDEF),
    textSecondary = Color(0xFFB3B3BA),
    textTertiary = Color(0xFF8E8E96),
    textDisabledOnControl = Color(0xFF9AA0AC), // disabled text inside controls; aligned with iOS / Web
    dictationVolatile = Color(0xFF8E8E96),     // unfinalized segment of dictation
    textInverse = Color.Unspecified,          // = backgroundBase

    border = Color(0x1AFFFFFF),               // 10%
    borderStrong = Color(0x2EFFFFFF),         // 18%
    cardHighlight = Color(0x14FFFFFF),        // white 8% decorative, matches iOS dark card highlight
    cardSheen = Color(0x07FFFFFF),            // white 7/255, matches iOS dark card sheen
    hairline = Color(0x0FFFFFFF),             // 6%
    borderSubtle = Color(0x0FFFFFFF),         // white 6%
    glassHighlight = Color(0x14FFFFFF),       // white 8% (dark)

    // On-* foreground: the dark status colors are brightened, so white text lacks contrast and dark text is used
    onPrimary = Color(0xFF160B2E),
    onSuccess = Color(0xFF062A13),
    onWarning = Color(0xFF18181B),
    onDanger = Color(0xFF1F0A09),
    onInfo = Color(0xFF0A1A3D),
    switchThumb = Color(0xFFFFFFFF),

    // Status - shared by all dark palettes (JSON shared.status)
    success = DarkStatusSuccess,
    successSoft = Color(0x246EE7A1),          // 14%
    successText = DarkStatusSuccess,
    warning = Color(0xFFFCD34D),
    warningSoft = Color(0x24FCD34D),          // 14%
    warningText = Color(0xFFFCD34D),
    warningLine = Color(0x52FCD34D),          // 32%
    danger = DarkStatusDanger,
    dangerSoft = Color(0x24F8978F),           // 14%
    dangerText = DarkStatusDanger,
    error = DarkStatusDanger,
    errorSoft = Color(0x24F8978F),            // 14%
    info = DarkStatusInfo,
    infoSoft = Color(0x248DB6FF),             // 14%
    infoText = DarkStatusInfo,

    // Code block
    codeBlockBg = Color(0xFF0B0B0D),
    codeBlockHeaderBg = Color(0xFF17171A),

    // Chat
    assistantBubble = Color.Unspecified,      // = surface

    // Overlay / Shadow
    overlay = Color(0xB8000000),              // 72%
    shadow = Color(0x57000000),               // 34%
    shadowStrong = Color(0x8F000000),         // 56%
    tabBar = Color.Unspecified,               // = background @88%

    // Memory page
    backgroundGrouped = Color.Unspecified,    // = backgroundBase
    memoryAtlasDot = Color(0x14FFFFFF),       // 8%
    memoryHueAbout = Color(0xFF818CF8),
    memoryHuePreferences = Color(0xFF2DD4BF),
    memoryHueInstructions = Color(0xFFFB923C),
    memoryHueWorkingOn = Color(0xFF22D3EE),
    memoryHueEpisodic = Color(0xFFA78BFA),

    // Capability: dark mode, aligned with iOS ModelCapabilityBadge
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
).linkDarkPaletteFields()

/** JSON `dark-purple` (the primary family keeps the former default dark; the background family is a true purple tone). */
val DarkPurpleOriveoColors = DarkOriveoColors.copy(
    backgroundBase = Color(0xFF130F1D),
    background = Color(0xFF171224),
    surfaceInset = Color(0xFF1B152A),
    surface = Color(0xFF1E1830),
    surfaceElevated = Color(0xFF29213F),
    textPrimary = Color(0xFFEEEAF6),
    textSecondary = Color(0xFFBDB4D0),
    textTertiary = Color(0xFF9A92AE),
    primary = Color(0xFFA78BFA),
    primaryPressed = Color(0xFFC4B5FD),
    primaryActive = Color(0xFF9370F7),
    accent = Color(0xFFF0ABFC),
    onPrimary = Color(0xFF160B2E),
    codeBlockBg = Color(0xFF0E0B17),
    codeBlockHeaderBg = Color(0xFF1A1528),
    glowK = 1f,
).linkDarkPaletteFields()

/** JSON `dark-graphite`. */
val DarkGraphiteOriveoColors = DarkOriveoColors.copy(
    backgroundBase = Color(0xFF1B1D21),
    background = Color(0xFF1F2125),
    surfaceInset = Color(0xFF22252A),
    surface = Color(0xFF25282D),
    surfaceElevated = Color(0xFF30343B),
    textPrimary = Color(0xFFECEEF1),
    textSecondary = Color(0xFFBAC0C8),
    textTertiary = Color(0xFF9CA2AC),
    primary = Color(0xFF6AA6FF),
    primaryPressed = Color(0xFF94C0FF),
    primaryActive = Color(0xFF3B82F6),
    accent = Color(0xFF7DE3FF),
    onPrimary = Color(0xFF04132A),
    codeBlockBg = Color(0xFF131519),
    codeBlockHeaderBg = Color(0xFF212328),
    glowK = 1f,
).linkDarkPaletteFields()

/** JSON `dark-black`. */
val DarkBlackOriveoColors = DarkOriveoColors.copy(
    backgroundBase = Color(0xFF000000),
    background = Color(0xFF060607),
    surfaceInset = Color(0xFF09090B),
    surface = Color(0xFF0C0C0E),
    surfaceElevated = Color(0xFF18181B),
    textPrimary = Color(0xFFE8E8EB),
    textSecondary = Color(0xFFABABB3),
    textTertiary = Color(0xFF87878F),
    primary = Color(0xFFFF6B9D),
    primaryPressed = Color(0xFFFF94B8),
    primaryActive = Color(0xFFF43F7E),
    accent = Color(0xFF7DD3FC),
    onPrimary = Color(0xFF1F0410),
    codeBlockBg = Color(0xFF0A0A0B),
    codeBlockHeaderBg = Color(0xFF141416),
    glowK = 1f,
).linkDarkPaletteFields()

/** JSON `dark-ocean`. */
val DarkOceanOriveoColors = DarkOriveoColors.copy(
    backgroundBase = Color(0xFF061418),
    background = Color(0xFF09191E),
    surfaceInset = Color(0xFF0B1D22),
    surface = Color(0xFF0D2127),
    surfaceElevated = Color(0xFF142D35),
    textPrimary = Color(0xFFE6F3F4),
    textSecondary = Color(0xFFA6C2C6),
    textTertiary = Color(0xFF7F9DA2),
    primary = Color(0xFF2DD4BF),
    primaryPressed = Color(0xFF5EEAD4),
    primaryActive = Color(0xFF14B8A6),
    accent = Color(0xFF67B7FF),
    onPrimary = Color(0xFF021614),
    codeBlockBg = Color(0xFF041013),
    codeBlockHeaderBg = Color(0xFF0A1B20),
    glowK = 1f,
).linkDarkPaletteFields()

/** JSON `dark-forest`. */
val DarkForestOriveoColors = DarkOriveoColors.copy(
    backgroundBase = Color(0xFF0B140F),
    background = Color(0xFF0E1813),
    surfaceInset = Color(0xFF111C16),
    surface = Color(0xFF132019),
    surfaceElevated = Color(0xFF1B2B22),
    textPrimary = Color(0xFFE8F1EB),
    textSecondary = Color(0xFFAEC0B4),
    textTertiary = Color(0xFF86998D),
    primary = Color(0xFF34D399),
    primaryPressed = Color(0xFF6EE7B7),
    primaryActive = Color(0xFF10B981),
    accent = Color(0xFFD9F99D),
    onPrimary = Color(0xFF03160C),
    codeBlockBg = Color(0xFF08100C),
    codeBlockHeaderBg = Color(0xFF101B15),
    glowK = 1f,
).linkDarkPaletteFields()

/** JSON `dark-sunset`. */
val DarkSunsetOriveoColors = DarkOriveoColors.copy(
    backgroundBase = Color(0xFF16100D),
    background = Color(0xFF1A1310),
    surfaceInset = Color(0xFF1E1713),
    surface = Color(0xFF221915),
    surfaceElevated = Color(0xFF2E221C),
    textPrimary = Color(0xFFF4ECE6),
    textSecondary = Color(0xFFC9B8AB),
    textTertiary = Color(0xFFA08F82),
    primary = Color(0xFFFDBA4D),
    primaryPressed = Color(0xFFFDCF7F),
    primaryActive = Color(0xFFF59E0B),
    accent = Color(0xFFFF7E79),
    onPrimary = Color(0xFF241005),
    codeBlockBg = Color(0xFF100B09),
    codeBlockHeaderBg = Color(0xFF1C1511),
    glowK = 1f,
).linkDarkPaletteFields()

/**
 * Tokens that change with the palette in dark but are not among the 15 JSON fields: always derived from the fields of the current palette,
 * never hard-coding one palette's values (copying the bg of dark-purple into textInverse and the like would drift after a palette switch).
 */
internal fun OriveoColors.linkDarkPaletteFields(): OriveoColors = copy(
    primarySoft = primary.copy(alpha = 0.12f),
    primaryGlow = primary.copy(alpha = 0.35f),
    primarySubtle = primary.copy(alpha = 0.15f),
    primaryTextSafe = primary,
    primaryFillText = primary,
    backgroundSecondary = surfaceInset,
    surfaceChrome = background.copy(alpha = 0.92f),
    textInverse = backgroundBase,
    assistantBubble = surface,
    tabBar = background.copy(alpha = 0.88f),
    backgroundGrouped = backgroundBase,
)

// ── Derived tokens, aligned with JSON `derived` (alpha replaces the source alpha: the JSON source colors are all opaque) ──

val OriveoColors.accentSubtle: Color get() = accent.copy(alpha = 0.14f)
val OriveoColors.focusRing: Color get() = primary.copy(alpha = 0.5f)
val OriveoColors.composerBorder: Color get() = primary.copy(alpha = 0.22f)
val OriveoColors.surfaceOverlay: Color get() = backgroundBase.copy(alpha = 0.88f)

/** Brand gradient endpoints: primary -> accent. */
val OriveoColors.gradientBrandStops: List<Color> get() = listOf(primary, accent)

/** Brand gradient at 135 degrees (top-left -> bottom-right), aligned with Web `linear-gradient(135deg, primary, accent)`. */
val OriveoColors.gradientBrand: Brush
    get() = Brush.linearGradient(
        colors = gradientBrandStops,
        start = Offset.Zero,
        end = Offset(Float.POSITIVE_INFINITY, Float.POSITIVE_INFINITY),
    )

/** The four ambient glow layers at the bottom of the screen; alpha already multiplied by the palette glowK. */
@Immutable
data class OriveoAurora(
    val bottom: Color,
    val bottomLeft: Color,
    val bottomRight: Color,
    val top: Color,
)

val OriveoColors.aurora: OriveoAurora
    get() = OriveoAurora(
        bottom = primary.copy(alpha = 0.26f * glowK),
        bottomLeft = accent.copy(alpha = 0.18f * glowK),
        bottomRight = primary.copy(alpha = 0.16f * glowK),
        top = accent.copy(alpha = 0.09f * glowK),
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
