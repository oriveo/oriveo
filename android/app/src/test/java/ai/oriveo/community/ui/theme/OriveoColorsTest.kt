package ai.oriveo.community.ui.theme

import androidx.compose.ui.graphics.Color
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

class OriveoColorsTest {

    @Test
    fun `LightOriveoColors is created successfully`() {
        assertNotNull(LightOriveoColors)
        assertNotNull(LightOriveoColors.primary)
        assertNotNull(LightOriveoColors.background)
        assertNotNull(LightOriveoColors.textPrimary)
    }

    @Test
    fun `DarkOriveoColors is created successfully`() {
        assertNotNull(DarkOriveoColors)
        assertNotNull(DarkOriveoColors.primary)
        assertNotNull(DarkOriveoColors.background)
        assertNotNull(DarkOriveoColors.textPrimary)
    }

    @Test
    fun `light and dark have different primary`() {
        // They should differ because light=0x8C5FF8 dark=0xC4B5FD
        assert(LightOriveoColors.primary != DarkOriveoColors.primary)
    }

    @Test
    fun `light and dark have different background`() {
        assert(LightOriveoColors.background != DarkOriveoColors.background)
    }

    @Test
    fun `error aliases danger in light`() {
        assertEquals(LightOriveoColors.danger, LightOriveoColors.error)
        assertEquals(LightOriveoColors.dangerSoft, LightOriveoColors.errorSoft)
    }

    @Test
    fun `error aliases danger in dark`() {
        assertEquals(DarkOriveoColors.danger, DarkOriveoColors.error)
        assertEquals(DarkOriveoColors.dangerSoft, DarkOriveoColors.errorSoft)
    }

    @Test
    fun `all 6 capability colors are distinct in light`() {
        val caps = setOf(
            LightOriveoColors.capReasoning,
            LightOriveoColors.capText,
            LightOriveoColors.capImage,
            LightOriveoColors.capFile,
            LightOriveoColors.capWeb,
            LightOriveoColors.capImageGen,
        )
        assertEquals(6, caps.size)
    }

    @Test
    fun `all new surface variants exist`() {
        assertNotNull(LightOriveoColors.backgroundBase)
        assertNotNull(LightOriveoColors.backgroundSecondary)
        assertNotNull(LightOriveoColors.surfaceElevated)
        assertNotNull(LightOriveoColors.surfaceInset)
        assertNotNull(LightOriveoColors.surfaceChrome)
    }

    @Test
    fun `shadow colors exist`() {
        assertNotNull(LightOriveoColors.shadow)
        assertNotNull(LightOriveoColors.shadowStrong)
        assertNotNull(LightOriveoColors.tabBar)
    }

    @Test
    fun `capability background colors exist`() {
        assertNotNull(LightOriveoColors.capReasoningBg)
        assertNotNull(LightOriveoColors.capTextBg)
        assertNotNull(LightOriveoColors.capImageBg)
        assertNotNull(LightOriveoColors.capFileBg)
        assertNotNull(LightOriveoColors.capWebBg)
        assertNotNull(LightOriveoColors.capImageGenBg)
    }

    @Test
    fun `capability border colors exist`() {
        assertNotNull(LightOriveoColors.capReasoningBorder)
        assertNotNull(LightOriveoColors.capTextBorder)
        assertNotNull(LightOriveoColors.capImageBorder)
        assertNotNull(LightOriveoColors.capFileBorder)
        assertNotNull(LightOriveoColors.capWebBorder)
        assertNotNull(LightOriveoColors.capImageGenBorder)
    }

    // Memory page tokens have the same values on all three platforms; compare with iOS Palette.memoryHue.* / backgroundGrouped / warningLine / memoryAtlasDot
    @Test
    fun `memory page tokens match iOS values`() {
        val light = LightOriveoColors
        val dark = DarkOriveoColors
        assertEquals(Color(0xFFF4F4F6), light.backgroundGrouped)
        // The grouped page base follows the palette: it equals the current palette's backgroundBase
        assertEquals(dark.backgroundBase, dark.backgroundGrouped)
        assertEquals(Color(0x66F59E0B), light.warningLine)
        assertEquals(Color(0x52FCD34D), dark.warningLine)
        assertEquals(Color(0x1A18181B), light.memoryAtlasDot)
        assertEquals(Color(0x14FFFFFF), dark.memoryAtlasDot)
        assertEquals(
            listOf(Color(0xFF4F46E5), Color(0xFF0D9488), Color(0xFFEA580C), Color(0xFF0891B2), Color(0xFF7C3AED)),
            with(light) { listOf(memoryHueAbout, memoryHuePreferences, memoryHueInstructions, memoryHueWorkingOn, memoryHueEpisodic) },
        )
        assertEquals(
            listOf(Color(0xFF818CF8), Color(0xFF2DD4BF), Color(0xFFFB923C), Color(0xFF22D3EE), Color(0xFFA78BFA)),
            with(dark) { listOf(memoryHueAbout, memoryHuePreferences, memoryHueInstructions, memoryHueWorkingOn, memoryHueEpisodic) },
        )
    }

    // ── The 7 dark palettes: aligned value by value with shared/theme-contracts/dark-palettes.v1.json ──

    @Test
    fun `palette_instances_equal_json`() {
        val contract = DarkPaletteContract
        assertEquals("enum order matches the JSON order", contract.order, DarkPaletteId.entries.map { it.id })
        assertEquals(7, contract.order.size)
        for ((id, colors) in contract.instances()) {
            val json = contract.palette(id)
            for ((field, read) in contract.fieldReaders) {
                assertEquals("$id.$field", contract.color(json.getValue(field)), read(colors))
            }
            assertEquals("$id.glowK", contract.float(json.getValue("glowK")), colors.glowK)
            val status = contract.status
            assertEquals("$id.success", contract.color(status.getValue("success")), colors.success)
            assertEquals("$id.warning", contract.color(status.getValue("warning")), colors.warning)
            assertEquals("$id.error→danger", contract.color(status.getValue("error")), colors.danger)
            assertEquals("$id.error alias", colors.danger, colors.error)
            assertEquals("$id.info", contract.color(status.getValue("info")), colors.info)
        }
        assertEquals("default dark = JSON defaultId", DarkPaletteId.fromId(contract.defaultId).colors, DarkOriveoColors)
        assertEquals("the V2 alias still points at the default dark", DarkOriveoColors, DarkV2OriveoColors)
    }

    @Test
    fun `derived_tokens_follow_json`() {
        val derived = DarkPaletteContract.derived
        fun alpha(name: String) = DarkPaletteContract.float(derived.getValue(name).jsonObject.getValue("alpha"))
        fun from(name: String) = derived.getValue(name).jsonObject.getValue("from").jsonPrimitive.content
        assertEquals("primary", from("primarySubtle"))
        assertEquals("accent", from("accentSubtle"))
        assertEquals("primary", from("primaryGlow"))
        assertEquals("primary", from("focusRing"))
        assertEquals("primary", from("composerBorder"))
        assertEquals("bg", from("surfaceOverlay"))
        val gradient = derived.getValue("gradientBrand").jsonObject
        assertEquals(135f, DarkPaletteContract.float(gradient.getValue("angleDeg")))
        val aurora = derived.getValue("aurora").jsonObject
        fun auroraAlpha(layer: String) = DarkPaletteContract.float(aurora.getValue(layer).jsonObject.getValue("alpha"))
        for ((id, c) in DarkPaletteContract.instances()) {
            assertEquals("$id.primarySubtle", c.primary.copy(alpha = alpha("primarySubtle")), c.primarySubtle)
            assertEquals("$id.accentSubtle", c.accent.copy(alpha = alpha("accentSubtle")), c.accentSubtle)
            assertEquals("$id.primaryGlow", c.primary.copy(alpha = alpha("primaryGlow")), c.primaryGlow)
            assertEquals("$id.focusRing", c.primary.copy(alpha = alpha("focusRing")), c.focusRing)
            assertEquals("$id.composerBorder", c.primary.copy(alpha = alpha("composerBorder")), c.composerBorder)
            assertEquals("$id.surfaceOverlay", c.backgroundBase.copy(alpha = alpha("surfaceOverlay")), c.surfaceOverlay)
            assertEquals("$id.gradientBrand", listOf(c.primary, c.accent), c.gradientBrandStops)
            val k = c.glowK
            assertEquals("$id.aurora.bottom", c.primary.copy(alpha = auroraAlpha("bottom") * k), c.aurora.bottom)
            assertEquals("$id.aurora.bottomLeft", c.accent.copy(alpha = auroraAlpha("bottomLeft") * k), c.aurora.bottomLeft)
            assertEquals("$id.aurora.bottomRight", c.primary.copy(alpha = auroraAlpha("bottomRight") * k), c.aurora.bottomRight)
            assertEquals("$id.aurora.top", c.accent.copy(alpha = auroraAlpha("top") * k), c.aurora.top)
        }
    }

    @Test
    fun `palette linked tokens follow the current palette instead of a frozen hex`() {
        for ((id, c) in DarkPaletteContract.instances()) {
            assertEquals("$id.textInverse", c.backgroundBase, c.textInverse)
            assertEquals("$id.backgroundGrouped", c.backgroundBase, c.backgroundGrouped)
            assertEquals("$id.assistantBubble", c.surface, c.assistantBubble)
            assertEquals("$id.backgroundSecondary", c.surfaceInset, c.backgroundSecondary)
            assertEquals("$id.primaryTextSafe", c.primary, c.primaryTextSafe)
            assertEquals("$id.primarySoft", c.primary.copy(alpha = 0.12f), c.primarySoft)
            assertEquals("$id.surfaceChrome", c.background.copy(alpha = 0.92f), c.surfaceChrome)
            assertEquals("$id.tabBar", c.background.copy(alpha = 0.88f), c.tabBar)
            val scheme = darkColorSchemeOf(c)
            assertEquals("$id M3 primary", c.primary, scheme.primary)
            assertEquals("$id M3 onPrimary", c.onPrimary, scheme.onPrimary)
            assertEquals("$id M3 background", c.backgroundBase, scheme.background)
            assertEquals("$id M3 surface", c.surface, scheme.surface)
            assertEquals("$id M3 onSurface", c.textPrimary, scheme.onSurface)
            assertEquals("$id M3 error", c.danger, scheme.error)
        }
        val ids = DarkPaletteContract.order.toSet()
        assertTrue("the 7 instances are pairwise different", DarkPaletteContract.instances().map { it.second }.toSet().size == ids.size)
    }

    @Test
    fun `unknown_or_missing_palette_resolves_default`() {
        assertEquals(DarkPaletteId.Dark, DarkPaletteId.Default)
        assertEquals(DarkPaletteId.Dark, DarkPaletteId.fromId(null))
        assertEquals(DarkPaletteId.Dark, DarkPaletteId.fromId(""))
        for (case in DarkPaletteContract.resolveCases) {
            val stored = case.getValue("stored").jsonPrimitive
            val input = if (stored.isString) stored.content else null
            assertEquals(
                case.getValue("name").jsonPrimitive.content,
                case.getValue("renders").jsonPrimitive.content,
                DarkPaletteId.fromId(input).id,
            )
        }
    }

    @Test
    fun `light palette keeps its pre palette values`() {
        assertEquals(Color(0xFF8C5FF8), LightOriveoColors.primary)
        assertEquals(Color(0xFFFFFFFF), LightOriveoColors.backgroundBase)
        assertEquals(Color(0xFFFFFFFF), LightOriveoColors.textInverse)
        assertEquals(Color(0x1A8C5FF8), LightOriveoColors.primaryGlow)
        assertEquals(1f, LightOriveoColors.glowK)
    }
}
