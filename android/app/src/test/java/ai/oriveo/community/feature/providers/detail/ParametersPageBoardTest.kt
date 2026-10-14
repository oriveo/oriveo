package ai.oriveo.community.feature.providers.detail

import androidx.compose.ui.unit.dp
import ai.oriveo.community.R
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.feature.chat.composer.modelControlCapabilityTitleRes
import ai.oriveo.community.feature.chat.modelcontrols.ModelOptionParameterCardIcons
import java.io.File
import javax.xml.parsers.DocumentBuilderFactory
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.w3c.dom.Element

/**
 * Checks the parameters page board (the same five checks exist on all three platforms).
 *
 * The assertions on the maintenance fold layout function and the parameter card icon descriptors come
 * from what production code actually produces; the ordering that exists only in the Compose layout is
 * anchored on the source, and each anchor is asserted to exist first so that `substringAfter` cannot
 * silently hand back the whole source when it finds nothing.
 */
class ParametersPageBoardTest {
    private val sheet by lazy { repoFile("feature/providers/detail/GenerationParameterDefaultsSheet.kt").readText() }
    private val chatPage by lazy { repoFile("feature/chat/modelcontrols/AdvancedSettingsPage.kt").readText() }

    // ---- The page and every entry share the name Parameters ----

    @Test
    fun `the page and every entry resolve to Parameters`() {
        val english = strings("values")
        assertEquals(R.string.generation_parameters_section, modelControlCapabilityTitleRes("generation"))
        assertEquals("Parameters", english["generation_parameters_section"])
        assertEquals("Go to Parameters", english["model_control_go_to_parameters"])
        listOf(
            "feature/chat/modelcontrols/AdvancedSettingsPage.kt",
            "feature/chat/modelcontrols/ModelOptionsPanel.kt",
            "feature/chat/composer/ModelControlsSheet.kt",
            "feature/providers/detail/ProviderDetailSettingsCard.kt",
            "feature/providers/detail/GenerationParameterDefaultsSheet.kt",
        ).forEach { relative ->
            assertTrue("$relative must use the Parameters title", repoFile(relative).readText().contains("R.string.generation_parameters_section"))
        }
        val retired = listOf("generation_model_behavior", "model_control_go_to_advanced_settings", "relay_section_advanced_http")
        val offenders = sourceRoot().walkTopDown()
            .filter { it.isFile && it.extension == "kt" }
            .flatMap { file -> retired.filter { file.readText().contains("R.string.$it") }.map { "${file.name}: $it" } }
            .toList()
        assertEquals("production code must not reference the old keys any more", emptyList<String>(), offenders)
        valuesDirs().forEach { dir ->
            val defined = strings(dir.name).keys
            retired.forEach { key -> assertFalse("${dir.name} still defines $key", key in defined) }
        }
    }

    // ---- Connection-scope maintenance items fold into a More row at the end of the page ----

    @Test
    fun `maintenance blocks fold under More after Developer`() {
        val all = GenerationParameterMaintenanceFold.Input(
            isReadOnly = false,
            isConnectionScope = true,
            hasProfileFingerprint = true,
            canViewDiagnostics = true,
            hasCompatibilityConflicts = true,
            isRelay = true,
        )
        val order = listOf(
            GenerationParameterMaintenanceBlock.Presets,
            GenerationParameterMaintenanceBlock.Connection,
            GenerationParameterMaintenanceBlock.Diagnostics,
            GenerationParameterMaintenanceBlock.Compatibility,
            GenerationParameterMaintenanceBlock.ClearLearnedCapabilities,
        )
        assertTrue(GenerationParameterMaintenanceFold.showsMoreRow(all))
        assertEquals("none of the five blocks render while collapsed", emptyList<GenerationParameterMaintenanceBlock>(), GenerationParameterMaintenanceFold.renderedBlocks(all, expanded = false))
        assertEquals("the five blocks appear in order once expanded", order, GenerationParameterMaintenanceFold.renderedBlocks(all, expanded = true))

        // Each block keeps its own visibility condition: read-only leaves only compatibility (it states
        // a fact), and the conversation scope drops the four connection-level blocks.
        assertEquals(
            listOf(GenerationParameterMaintenanceBlock.Diagnostics, GenerationParameterMaintenanceBlock.Compatibility),
            GenerationParameterMaintenanceFold.visibleBlocks(all.copy(isReadOnly = true)),
        )
        // Conversation scope with conflicts: no More row, and compatibility stays where it was, before the parameter group.
        val conversation = all.copy(isConnectionScope = false, hasCompatibilityConflicts = true)
        assertFalse("no More row in conversation scope", GenerationParameterMaintenanceFold.showsMoreRow(conversation))
        assertEquals(emptyList<GenerationParameterMaintenanceBlock>(), GenerationParameterMaintenanceFold.renderedBlocks(conversation, expanded = true))
        val inPlace = sheet.indexOf("if (conversationId != null && compatibilityConflicts.isNotEmpty()) CompatibilityConflictsBlock()")
        assertTrue("the compatibility block stays in place in conversation scope", inPlace >= 0)
        assertTrue(
            "the original position is before the parameter group (empty state)",
            inPlace < sheet.indexOf("Text(stringResource(R.string.generation_parameters_section), style = OriveoTheme.typography.title3)"),
        )
        assertTrue("the More row carries its expanded / collapsed state", sheet.contains("stateDescription = expansionState"))
        val none = GenerationParameterMaintenanceFold.Input(
            isReadOnly = true,
            isConnectionScope = true,
            hasProfileFingerprint = true,
            canViewDiagnostics = false,
            hasCompatibilityConflicts = false,
            isRelay = true,
        )
        assertFalse("no More row when none of the five blocks is visible", GenerationParameterMaintenanceFold.showsMoreRow(none))

        // Layout: parameter group (empty state), saved summary, reset, Developer, More row, then the five blocks.
        val anchors = listOf(
            "Text(stringResource(R.string.generation_parameters_section), style = OriveoTheme.typography.title3)",
            "if (dormantIds.isNotEmpty() && partition != null) {",
            "if (!isReadOnly && values.values.isNotEmpty()) {",
            "stringResource(R.string.generation_parameter_developer),",
            "GenerationParameterMoreRow(\n                        expanded = maintenanceExpanded,",
            "GenerationParameterMaintenanceFold.renderedBlocks(maintenanceFold, maintenanceExpanded).forEach { block ->",
            "GenerationParameterMaintenanceBlock.Presets -> {",
            "GenerationParameterMaintenanceBlock.Connection -> {",
            "GenerationParameterMaintenanceBlock.Diagnostics -> {",
            "GenerationParameterMaintenanceBlock.Compatibility -> CompatibilityConflictsBlock()",
            "GenerationParameterMaintenanceBlock.ClearLearnedCapabilities -> {",
        )
        val positions = anchors.map { anchor ->
            val index = sheet.indexOf(anchor)
            assertTrue("anchor missing: $anchor", index >= 0)
            assertEquals("anchor must be unique: $anchor", index, sheet.lastIndexOf(anchor))
            index
        }
        assertEquals("page order", positions.sorted(), positions)
        assertTrue("the More row reuses advanced_more", sheet.contains("R.string.advanced_more"))
        assertTrue("the collapsed state is not persisted", sheet.contains("var maintenanceExpanded by remember { mutableStateOf(false) }"))
    }

    // ---- The chat-scope parameters page has no maintenance row ----

    @Test
    fun `chat scope keeps Basic, More, Write your own and no maintenance row`() {
        val anchors = listOf(
            "AdvancedSectionLabel(stringResource(R.string.generation_basic_settings))",
            "AdvancedSectionLabel(stringResource(R.string.advanced_more))",
            "AdvancedSectionLabel(stringResource(R.string.advanced_write_your_own))",
        )
        val positions = anchors.map { anchor ->
            val index = chatPage.indexOf(anchor)
            assertTrue("anchor missing: $anchor", index >= 0)
            index
        }
        assertEquals(positions.sorted(), positions)
        assertEquals("More appears only once, as a parameter group header", 1, Regex("""R\.string\.advanced_more\)""").findAll(chatPage).count())
        listOf("GenerationParameterMoreRow", "GenerationParameterMaintenanceFold", "R.string.generation_diagnostics_section", "R.string.generation_parameter_clear_learned_capabilities")
            .forEach { assertFalse("$it must not appear in chat scope", chatPage.contains(it)) }
    }

    // ---- Edit connection page: headers section ----

    @Test
    fun `the headers section is titled Headers and query params`() {
        assertEquals("Headers & query params", strings("values")["relay_section_headers_query"])
        // Edit connection renders from the row model: the section title comes from what the model produces.
        val provider = Provider(
            id = "relay-1",
            kind = ProviderKind.Relay,
            baseUrlText = "https://relay.example/v1",
            relayRequested = ai.oriveo.community.core.model.RelayRequestedConfig(),
        )
        val board = ai.oriveo.community.feature.providers.relay.RelayEditBoardModel.make(
            provider = provider,
            draft = ai.oriveo.community.feature.providers.relay.RelayEditDraft.from(provider, null),
            status = null,
            isSaving = false,
            issues = emptyList(),
        )
        assertEquals(
            R.string.relay_section_headers_query,
            board.groups.single { it.id == ai.oriveo.community.feature.providers.relay.RelayEditGroupId.Headers }.titleRes,
        )
    }

    // ---- The two parameter card rows lead with an icon ----

    @Test
    fun `the parameter card rows lead with thermometer and sliders`() {
        assertEquals(R.drawable.ph_thermometer_simple_duotone, ModelOptionParameterCardIcons.temperature)
        assertEquals(R.drawable.ph_sliders_horizontal_duotone, ModelOptionParameterCardIcons.entry)
        assertEquals(22.dp, ModelOptionParameterCardIcons.size)
        val card = repoFile("feature/chat/modelcontrols/ModelOptionsPanel.kt").readText()
            .substringAfter("internal fun ModelOptionParameterCard(")
            .substringBefore("internal object ModelOptionParameterCardIcons")
        assertEquals("one icon per row", 2, Regex("""ModelOptionParameterCardIcon\(""").findAll(card).count())
        assertTrue(card.contains("ModelOptionParameterCardIcon(ModelOptionParameterCardIcons.temperature)"))
        assertTrue(card.contains("ModelOptionParameterCardIcon(ModelOptionParameterCardIcons.entry)"))
    }

    private fun strings(dir: String): Map<String, String> {
        val file = File(resRoot(), "$dir/strings.xml")
        val nodes = DocumentBuilderFactory.newInstance().newDocumentBuilder().parse(file).getElementsByTagName("string")
        return buildMap {
            for (i in 0 until nodes.length) {
                val element = nodes.item(i) as Element
                put(element.getAttribute("name"), element.textContent.replace("\\'", "'"))
            }
        }
    }

    private fun valuesDirs(): List<File> = resRoot().listFiles().orEmpty()
        .filter { it.isDirectory && it.name.startsWith("values") && File(it, "strings.xml").exists() }

    private fun resRoot(): File = File(sourceRoot().parentFile!!.parentFile!!.parentFile!!.parentFile!!, "res")

    /** `.../java/ai/oriveo/community`. */
    private fun sourceRoot(): File =
        repoFile("feature/chat/composer/ModelControlsSheet.kt")
            .parentFile!!.parentFile!!.parentFile!!.parentFile!!

    private fun repoFile(relative: String): File {
        val direct = File("src/main/java/ai/oriveo/community/$relative")
        if (direct.exists()) return direct
        var dir = File(System.getProperty("user.dir")!!).absoluteFile
        val prefix = "android/app/src/main/java/ai/oriveo/community/"
        while (true) {
            val candidate = File(dir, prefix + relative)
            if (candidate.exists()) return candidate
            dir = dir.parentFile ?: break
        }
        error("cannot find $relative")
    }
}
