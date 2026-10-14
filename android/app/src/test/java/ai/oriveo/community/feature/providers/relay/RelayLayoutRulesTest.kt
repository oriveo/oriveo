package ai.oriveo.community.feature.providers.relay

import ai.oriveo.community.R
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.RelayKey
import ai.oriveo.community.core.provider.relay.RelayKeyBinding
import ai.oriveo.community.feature.providers.detail.RelayCatalogRow
import ai.oriveo.community.feature.providers.detail.RelayCatalogRowChip
import ai.oriveo.community.feature.providers.detail.RelayCatalogRowChips
import ai.oriveo.community.feature.providers.detail.RelayKeyInputFieldId
import ai.oriveo.community.feature.providers.detail.RelayKeyInputKind
import ai.oriveo.community.feature.providers.detail.RelayKeysBoardModel
import ai.oriveo.community.feature.providers.detail.RelayStatusColumns
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Source gates for the three layout rules on relay-family pages (add / edit / detail / keys / catalog / advanced / web) and the cross-check "original answer":
 * the collapsed chevron points along the text direction (flipped in RTL) and the expanded one points down, never "down arrow + 180° rotation"; the trailing column of multi-line rows is vertically centered on the whole row.
 * TRAILING / ROW Same names as iOS `RelayLayoutRulesTests` and Web `relay-layout-rules.test.tsx`.
 */
class RelayLayoutRulesTest {

    @Test
    fun `RL2-LAYOUT-CHEVRON-01 family files never fold with a rotated down chevron`() {
        // A rotation angle held in animation state (animateFloatAsState(180f) + .rotate(state)) also lands on the .rotate( in the Icon arguments.
        val offenders = familyFiles().flatMap { file ->
            calls(file.readText(), "Icon(")
                .filter { (_, args) -> DOWN_ICON.containsMatchIn(args) && ROTATION.containsMatchIn(args) }
                .map { (line, _) -> "${file.name}:$line" }
        }
        assertTrue("Collapse indicator must not use a down arrow rotated 180°: $offenders", offenders.isEmpty())
    }

    @Test
    fun `RL2-LAYOUT-CHEVRON-02 collapsed right chevron flips in RTL`() {
        val offenders = familyFiles().flatMap { file ->
            calls(file.readText(), "Icon(")
                .filter { (_, args) -> "xpanded" in args && RIGHT_ICON.containsMatchIn(args) && "scaleX = -1f" !in args }
                .map { (line, _) -> "${file.name}:$line" }
        }
        assertTrue("Collapsed chevron resource does not auto-mirror; it must be flipped in RTL: $offenders", offenders.isEmpty())
    }

    @Test
    fun `RL2-LAYOUT-CHEVRON-03 directional arrows across main sources flip in RTL`() {
        // Forward / back / next-level arrows flip with the layout in RTL; non-AutoMirrored resources need scaleX = -1f in the Icon arguments.
        val files = root().walkTopDown().filter { it.isFile && it.extension == "kt" }.toList()
        var sites = 0
        val offenders = files.flatMap { file ->
            calls(file.readText(), "Icon(")
                .filter { (_, args) -> DIRECTIONAL_ICON.containsMatchIn(args) }
                .onEach { sites++ }
                .filter { (_, args) -> "scaleX = -1f" !in args }
                .map { (line, _) -> "${file.name}:$line" }
        }
        // The gate would silently go green if the scan rule broke: keep a lower bound of 9 sites (the community edition count as of 2026-10; the private build has 15 because it also carries the managed and sync screens).
        assertTrue("Too few directional arrow call sites: $sites", sites >= 9)
        assertTrue("Directional arrow resource does not auto-mirror; flip it in RTL (or switch to Icons.AutoMirrored): $offenders", offenders.isEmpty())
    }

    @Test
    fun `RL2-LAYOUT-TRAILING-01 anchored rows center the whole row`() {
        // Anchor = a line comment containing "whole-row vertical centering". The Row( within 6 code lines after the anchor is that row; when the anchor sits in the trailing column, take the innermost enclosing Row.
        val anchors = familyFiles().flatMap { file -> anchors(file) }
        assertTrue("No anchors at all; the gate would silently go green", anchors.isNotEmpty())
        val offenders = anchors.mapNotNull { anchor ->
            val row = anchor.row ?: return@mapNotNull "${anchor.where} no Row( found near the anchor"
            when {
                "verticalAlignment = Alignment.CenterVertically" !in row.args -> "${anchor.where} Row is not centered on the whole row"
                "padding(top" in row.block -> "${anchor.where} Row block still has padding(top pinning the title row"
                else -> null
            }
        }
        assertTrue("Rows carrying the whole-row centering anchor must be centered on the whole row: $offenders", offenders.isEmpty())

        // The edit-connection action row (connection security "Change") and the menu row share one row body, and the body carries the anchor (merged from the two earlier slice assertions).
        val sheet = source("feature/providers/relay/RelayAdvancedSettingsSheet.kt")
        val body = functionBody(sheet, "private fun EditRowBody(")
        assertTrue("Edit row body is missing the anchor", ANCHOR in body)
        assertTrue("Action row goes through the row body", "EditRowBody(" in functionBody(sheet, "private fun ValueRow("))
        assertTrue("Menu row goes through the row body", "EditRowBody(" in functionBody(sheet, "internal fun <T> MenuRow("))
    }

    @Test
    fun `RL2-LAYOUT-TRAILING-02 every row type in the family has an anchor`() {
        // Page to file: any page with zero anchors fails (same 8-entry table as iOS / Web).
        val pages = linkedMapOf(
            "Key row" to listOf("detail/RelayKeysPage.kt"),
            "Catalog enabled row" to listOf("detail/ProviderDetailEnabledModels.kt", "detail/RelayCatalogBoardView.kt"),
            "Catalog directory row" to listOf("detail/RelayCatalogBoardView.kt"),
            "Detail row" to listOf("detail/RelayDetailBoardView.kt"),
            "Edit / manual-setup menu row" to listOf("relay/RelayAdvancedSettingsSheet.kt"),
            "Step 1 detection row" to listOf("relay/RelaySetupScreen.kt"),
            "Advanced key row" to listOf("detail/RelayModelAdvancedPage.kt"),
            "Capability test header" to listOf("detail/RelayCapabilityTestPanel.kt"),
        )
        val missing = pages.filter { (_, files) ->
            files.none { anchors(File(root(), "feature/providers/$it")).isNotEmpty() }
        }.keys
        assertTrue("These pages have no whole-row centering anchor: $missing", missing.isEmpty())
    }

    @Test
    fun `RL2-LAYOUT-ROW-01 enabled and catalog rows put chips protocol then key under the name`() {
        // Chip order comes from a pure function read by both the component and this gate: protocol then key.
        val row = RelayCatalogRow(
            model = AIModel(id = "gpt-5", name = "gpt-5"),
            protocol = RelayBoardProtocol.Responses,
            caps = emptyList(),
            status = null,
            trailing = emptyList(),
            keyChip = "work",
        )
        assertEquals(
            listOf(RelayCatalogRowChip.Protocol(RelayBoardProtocol.Responses), RelayCatalogRowChip.Key("work")),
            RelayCatalogRowChips.of(row),
        )
        assertEquals(listOf(RelayCatalogRowChip.Key("work")), RelayCatalogRowChips.of(row.copy(protocol = null)))
        // The row body takes chips from the pure function; the name owns the first line: whatever wraps the name is not a Row / FlowRow (a different container from the chips).
        val view = source("feature/providers/detail/RelayCatalogBoardView.kt")
        val body = functionBody(view, "internal fun RelayCatalogRowBody(")
        assertTrue("Chips of directory / enabled rows must come from RelayCatalogRowChips", "RelayCatalogRowChips.of(row)" in body)
        val name = body.indexOf("text = row.model.name")
        assertTrue("Row body draws the name", name >= 0)
        assertTrue("The name is not in the same Row as the chips", innermostBlock(body, name, "Row(") == null && innermostBlock(body, name, "FlowRow(") == null)
        // Chips flow into wrapping one by one (a key chip that does not fit wraps whole to the next line instead of being squeezed into an ellipsis); capability icons always take their own line below the chips.
        val chip = body.indexOf("RelayCatalogChip(")
        assertTrue("The chip is a direct item of the FlowRow", innermostBlock(body, chip, "FlowRow(") != null)
        assertTrue("The chip is no longer wrapped in a Row first and then used as one item", innermostBlock(body, chip, "Row(") == null)
        val caps = body.indexOf("RelayCatalogCapabilityIcons(")
        assertTrue("Row body draws capability icons", caps >= 0)
        assertTrue("Capability icons are not in the same flow row as the chips", innermostBlock(body, caps, "FlowRow(") == null && innermostBlock(body, caps, "Row(") == null)
        val chipFn = functionBody(view, "private fun RelayCatalogChip(")
        assertFalse("Chips are not compressed by remaining width (middle-truncate only beyond the full column width)", ".weight(" in chipFn)
    }

    @Test
    fun `RL2-LAYOUT-ROW-02 enabled row status word sits in the trailing column and may wrap`() {
        val texts = listOf("detail/ProviderDetailEnabledModels.kt", "detail/RelayCatalogBoardView.kt").flatMap { path ->
            calls(source("feature/providers/$path"), "Text(").map { it.second }
        }.filter { "widthIn(max = 84.dp)" in it }
        assertTrue("Enabled-row status text is missing the width cap 84", texts.isNotEmpty())
        texts.forEach { args ->
            assertFalse("Status text may wrap and must not be single-line: $args", "maxLines = 1" in args)
            assertFalse("Status text may wrap and must not be ellipsized: $args", "Ellipsis" in args)
        }
        // Status text + button group always sit in the trailing column, on the same row as the left column and vertically centered on the whole row; the row does not wrap (no flow wrapping).
        listOf("detail/ProviderDetailEnabledModels.kt", "detail/RelayCatalogBoardView.kt").forEach { path ->
            val text = source("feature/providers/$path")
            val status = text.indexOf("RelayCatalogRowStatusText(row)")
                .takeIf { it >= 0 } ?: text.indexOf("RelayCatalogRowStatusText(boardRow)")
            val row = innermostBlock(text, status, "Row(")
            assertTrue("$path status text row not found", row != null)
            row!!
            assertTrue("$path status text is on the same row as the left column", "RelayCatalogRowBody(" in row.block)
            assertTrue("$path row is vertically centered on the whole row", "verticalAlignment = Alignment.CenterVertically" in row.args)
            assertTrue("$path row does not wrap", innermostBlock(text, status, "FlowRow(") == null)
        }
    }

    @Test
    fun `RL2-LAYOUT-ROW-03 key row puts the mask before the catalog line and only status in the trailing column`() {
        // Production objects: a named key's mask differs from its title (goes into the directory-row prefix); an unnamed key's title is the mask (not shown twice).
        val board = RelayKeysBoardModel.build(
            Provider(
                id = "row-03",
                kind = ProviderKind.Relay,
                apiKey = "sk-row03-main-0001",
                relayKeys = listOf(
                    RelayKey(id = RelayKeyBinding.IMPLICIT_KEY_ID, name = "Main"),
                    RelayKey(id = "k-unnamed", apiKey = "sk-row03-team-0002"),
                ),
            ),
        )
        val named = board.rows.first { it.title == "Main" }
        val unnamed = board.rows.first { it.id == "k-unnamed" }
        assertEquals("A named key's mask goes into the directory-row prefix", named.maskedSecret, named.catalogMask)
        assertTrue("A named key has a mask", !named.catalogMask.isNullOrEmpty())
        assertEquals("An unnamed key's title is the mask", unnamed.maskedSecret, unnamed.title)
        assertEquals("An unnamed key no longer shows a mask", null, unnamed.catalogMask)

        val keys = source("feature/providers/detail/RelayKeysPage.kt")
        val summary = functionBody(keys, "internal fun RelayKeyRowSummary(")
        assertFalse("The mask is no longer switched between left and right columns by width", "SubcomposeLayout" in summary || "maskTrailing" in summary)
        // The marker is an inline prefix on the first line of the status text (same text flow, end-aligned); when wrapping it stays with the first line, right next to the first word; it is no longer two siblings "marker + wrapping Text".
        val status = calls(summary, "Text(").map { it.second }.single { "inlineContent = " in it }
        assertFalse("Trailing status holds only the status, no mask: $status", "mask" in status)
        assertFalse("Trailing status does not contain the title: $status", "key.title" in status)
        // Width split matches iOS columnWidths: total excludes the trailing chevron, status = min(single-line ideal width, total x 50%).
        assertTrue("Left column / status split widths by columnWidths", "RelayStatusColumnsLayout(" in summary)
        assertFalse("50% is no longer computed from the full row width including the chevron", "maxWidth * 0.5f" in summary || "statusMaxWidth" in summary)
        val columns = innermostBlock(summary, summary.indexOf("inlineContent = "), "RelayStatusColumnsLayout(")
        assertTrue("Status is inside the split-width layout", columns != null && "text = key.title" in columns.block)
        assertFalse("The trailing chevron is not counted in total", "ph_caret_right" in columns!!.args + columns.block)
        assertTrue("Status text has at most 2 lines: $status", "maxLines = 2" in status)
        assertTrue("Whole status block is end-aligned: $status", "textAlign = TextAlign.End" in status)
        val inline = summary.indexOf("appendInlineContent(")
        assertTrue("The marker enters the status text as inline content", inline >= 0)
        assertTrue("The marker comes before the status word", inline < summary.indexOf("append(it)", inline))
        assertFalse("The marker no longer takes its own column / top-aligned sibling", "Alignment.Top" in summary || "firstLineHeight" in summary)
        assertTrue("Directory-row prefix uses catalogMask", "key.catalogMask" in summary)
        val catalogLine = calls(summary, "Text(").map { it.second }.single { "catalog" in it && "mask" in it }
        assertTrue("Directory row = <mask> · catalog, may wrap: $catalogLine", "\" · \"" in catalogLine && "maxLines = 1" !in catalogLine)
        val left = innermostBlock(summary, summary.indexOf("text = key.title"), "Column(")
        assertTrue("The mask is in the left column's directory row", left != null && catalogLine in left.block)
        val detail = source("feature/providers/detail/RelayDetailBoardView.kt")
        assertTrue("The detail page's inline key uses the same key-row component", "RelayKeyRowSummary(" in detail)
    }

    @Test
    fun `RL2-LAYOUT-ROW-08 library key strip keeps one line per key with tail truncation`() {
        // Left column has two lines = "name (mask if unnamed)" middle-truncated / "Catalog: N models" tail-truncated; trailing = status (<= 50%, <= 2 lines) + Retry (intrinsic width, never wrapped or squeezed).
        val strip = functionBody(source("feature/providers/detail/RelayCatalogBoardView.kt"), "internal fun RelayCatalogKeyStrip(")
        val texts = calls(strip, "Text(").map { it.second }
        val title = texts.single { "item.title" in it }
        val catalog = texts.single { "relay_key_catalog_count" in it }
        val status = texts.single { "httpStatus" in it }
        assertTrue("Name is 1 line, middle-truncated: $title", "maxLines = 1" in title && "TextOverflow.MiddleEllipsis" in title)
        assertTrue("Catalog is 1 line, tail-truncated: $catalog", "maxLines = 1" in catalog && "TextOverflow.Ellipsis" in catalog && "MiddleEllipsis" !in catalog)
        assertTrue("Status is <= 2 lines, tail-truncated: $status", "maxLines = 2" in status && "TextOverflow.Ellipsis" in status && "MiddleEllipsis" !in status)
        // Width split matches iOS columnWidths: total = after the key icon and before Retry; status = min(single-line ideal width, total x 50%).
        assertFalse("50% is no longer computed from the full row width", "maxWidth * 0.5f" in strip || "statusMaxWidth" in strip)
        val left = innermostBlock(strip, strip.indexOf("text = item.title"), "Column(")
        assertTrue("Name and catalog are the two stacked lines of the left column", left != null && "relay_key_catalog_count" in left.block)
        left!!
        val columns = innermostBlock(strip, strip.indexOf("text = item.title"), "RelayStatusColumnsLayout(")
        assertTrue("Left column and status are inside the split-width layout", columns != null && "httpStatus" in columns.args && "ph_check_circle_duotone" in columns.args && "text = item.title" in columns.block)
        columns!!
        assertTrue("The split-width layout fills the space between icon and Retry (the name never gets zero width)", "modifier = Modifier.weight(1f)" in columns.args && "fill = false" !in columns.args)
        assertFalse("The key icon is not inside total", "R.drawable.ph_key)" in columns.args + columns.block)
        assertFalse("Retry is not inside total", "R.string.retry" in columns.args + columns.block)
        assertFalse("No more Spacer eating the remaining width in the row", "Spacer(" in strip)
        val row = innermostBlock(strip, strip.indexOf("R.string.retry"), "Row(")
        assertTrue("Left column / status / Retry are on the same row", row != null && columns.block in row.block && "R.drawable.ph_key)" in row.block)
        val retry = texts.single { "R.string.retry" in it && "contentDescription" !in it }
        assertTrue("Retry never wraps: $retry", "maxLines = 1" in retry && "softWrap = false" in retry)
        assertFalse("Retry takes no weight", ".weight(" in calls(strip, "TextButton(").map { it.second }.single())
    }

    @Test
    fun `RL2-LAYOUT-ROW-08 status column is min of single line width and half the space between icon and retry`() {
        // Production function: same semantics as iOS RelayMenuRowColumns.columnWidths (status column = min(ideal, total x 50%), left column = total - status - spacing).
        assertEquals("Short status: ideal width", 192 to 100, RelayStatusColumns.columnWidths(total = 300, statusIdeal = 100, spacing = 8))
        assertEquals("Long status: capped at half of total", 142 to 150, RelayStatusColumns.columnWidths(total = 300, statusIdeal = 400, spacing = 8))
        assertEquals("No status: left column fills, no spacing", 300 to 0, RelayStatusColumns.columnWidths(total = 300, statusIdeal = 0, spacing = 8))
        assertEquals("Not enough width: left column is never negative", 0 to 5, RelayStatusColumns.columnWidths(total = 10, statusIdeal = 100, spacing = 8))
        // Third key in the 402-wide sample ("429 Out of credit or rate-limited"): the old rule gave status 50% of the full width, leaving the left column about 75,
        // so "Catalog: 2 models" was truncated; the new rule deducts the key icon and Retry from total first, so the left column >= the single-line catalog width.
        val strip = 343
        val oldLeft = strip - 14 - 8 - strip / 2 - 8 - 59 - 8
        val total = strip - 14 - 8 - 59 - 8
        val (left, status) = RelayStatusColumns.columnWidths(total = total, statusIdeal = 220, spacing = 8)
        assertEquals(total / 2, status)
        assertTrue("New left column ($left) is wider than the old one ($oldLeft)", left > oldLeft + 30)
    }

    @Test
    fun `RL2-KEYINPUT-01 add replace rename are a bottom sheet with close, titled fields, eye toggle and one save`() {
        // Production objects: every field has a title (visible box); add = name + key, replace key = key, rename = name.
        val add = RelayKeysBoardModel.inputSheet(RelayKeyInputKind.Add, null)
        assertEquals(listOf(RelayKeyInputFieldId.Name, RelayKeyInputFieldId.Secret), add.fields.map { it.id })
        assertEquals(listOf(RelayKeyInputFieldId.Secret), RelayKeysBoardModel.inputSheet(RelayKeyInputKind.Replace, null).fields.map { it.id })
        assertEquals(listOf(RelayKeyInputFieldId.Name), RelayKeysBoardModel.inputSheet(RelayKeyInputKind.Rename, null).fields.map { it.id })
        assertTrue("Every field has a title", add.fields.all { it.labelRes != 0 })
        assertFalse("Add: Save is disabled when the key is empty", add.canSave("  "))
        assertTrue("Add: can save with a key", add.canSave("sk-new"))
        assertFalse("Replace key: disabled when empty", RelayKeysBoardModel.inputSheet(RelayKeyInputKind.Replace, null).canSave(""))
        assertTrue("Rename: the name may be cleared", RelayKeysBoardModel.inputSheet(RelayKeyInputKind.Rename, null).canSave(""))

        val keys = source("feature/providers/detail/RelayKeysPage.kt")
        assertFalse("No more AlertDialog input popup", "TextEntryDialog(" in keys)
        val sheet = functionBody(keys, "private fun KeyEntrySheet(")
        assertTrue("Android uses a bottom sheet", "OriveoModalBottomSheet(" in sheet && "AlertDialog(" !in sheet)
        assertTrue("Top-left x: 36dp drawn / 48dp touch target", "R.drawable.ph_x" in sheet && "size(36.dp)" in sheet && "size(48.dp)" in sheet)
        assertTrue("Centered title", "TextAlign.Center" in sheet && "sheet.titleRes" in sheet)
        assertTrue("Input field with a title", "OutlinedTextField(" in sheet && "KeyEntryField(" in sheet)
        assertTrue(
            "Key field show / hide eye",
            "R.drawable.ph_eye" in sheet && "secure_field_show" in sheet && "VisualTransformation.None" in sheet,
        )
        val save = calls(sheet, "OriveoPrimaryButton(").map { it.second }.single()
        assertTrue("Full-width Save at the bottom: $save", "R.string.save" in save && "fillMaxWidth()" in save && "sheet.canSave(" in save)
        assertFalse("No Cancel button", "R.string.cancel" in sheet || "relay_key_entry_cancel_button" in sheet)
        assertTrue("Key field is masked by default", "var revealed by remember { mutableStateOf(false) }" in sheet && "PasswordVisualTransformation()" in sheet)
    }

    @Test
    fun `RL2-KEYINPUT-02 add replace rename put the field title above the box and only the placeholder inside`() {
        // Production objects: add-name has no placeholder; key placeholder = the existing "sk-..." on this platform; rename placeholder = that key's mask.
        val add = RelayKeysBoardModel.inputSheet(RelayKeyInputKind.Add, null)
        val addName = add.fields.single { it.id == RelayKeyInputFieldId.Name }
        assertTrue("Add: no placeholder inside the name field", addName.placeholderRes == null && addName.placeholderText == null)
        assertEquals(R.string.relay_api_key_placeholder, add.fields.single { it.id == RelayKeyInputFieldId.Secret }.placeholderRes)
        val board = RelayKeysBoardModel.build(
            Provider(
                id = "keyinput-02",
                kind = ProviderKind.Relay,
                apiKey = "sk-keyinput-02-main",
                relayKeys = listOf(
                    RelayKey(id = RelayKeyBinding.IMPLICIT_KEY_ID, name = "Main"),
                    RelayKey(id = "k-1", apiKey = "sk-keyinput-02-0001"),
                ),
            ),
        )
        val row = board.rows.first { it.id == "k-1" }
        val rename = RelayKeysBoardModel.inputSheet(RelayKeyInputKind.Rename, row)
        assertTrue("Rename placeholder = mask", row.maskedSecret.isNotEmpty() && row.maskedSecret == rename.fields.single().placeholderText)

        val keys = source("feature/providers/detail/RelayKeysPage.kt")
        val sheet = functionBody(keys, "private fun KeyEntrySheet(")
        assertFalse("No floating label inside the field", "label = {" in sheet)
        val fields = calls(sheet, "OutlinedTextField(").map { it.first }
        assertEquals("Two input fields: name + key", 2, fields.size)
        var index = sheet.indexOf("OutlinedTextField(")
        // The title outside the box and the field's screen-reader label are the same string (val title = stringResource(field.labelRes)).
        assertTrue("The outside title takes the field label", "val title = stringResource(field.labelRes)" in sheet)
        while (index >= 0) {
            val wrapper = innermostBlock(sheet, index, "KeyEntryField(")
            assertTrue("Every input field is wrapped in the outside-title component", wrapper != null && "title = title" in wrapper.args)
            index = sheet.indexOf("OutlinedTextField(", index + 1)
        }
        assertTrue("Only the placeholder is inside the box", "placeholder = placeholder?.let" in sheet)
        val wrapper = functionBody(keys, "private fun KeyEntryField(")
        val title = wrapper.indexOf("text = title")
        assertTrue("Title is above the input field", title >= 0 && title < wrapper.indexOf("content()"))
        assertTrue("Title and input field are stacked vertically", innermostBlock(wrapper, title, "Column(") != null)
    }

    @Test
    fun `RL2-LAYOUT-ROW-04 detection row keeps elapsed time in its own trailing column`() {
        val body = functionBody(source("feature/providers/relay/RelaySetupScreen.kt"), "private fun RelayDetectionRowView(")
        val left = innermostBlock(body, body.indexOf("RelayFailureSentence("), "Column(")
        assertTrue("The failure text must be in the left column", left != null)
        left!!
        assertTrue("The key directory row is in the left column", "RelayKeyCatalogLineView(" in left.block)
        assertTrue("Detail is in the left column", "detail" in left.block)
        assertFalse("Elapsed time is not in the left column", "elapsedMs" in left.block)
        val row = innermostBlock(body, body.indexOf("elapsedMs"), "Row(")
        assertTrue("Elapsed time is on the same row as the left column", row != null && left.block in row.block)
    }

    @Test
    fun `RL2-LAYOUT-ROW-05 menu row keeps value and chevron in one trailing column and footnote inline`() {
        val body = functionBody(source("feature/providers/relay/RelayAdvancedSettingsSheet.kt"), "private fun EditRowBody(")
        val trailing = innermostBlock(body, body.indexOf("trailing()"), "Row(")
        assertTrue("Value and chevron are in the same trailing column of the row", trailing != null && "text = value" in trailing.block && "RowTitle(" !in trailing.block)
        // Left column = icon + title (RowTitle) on the first line + footnote.
        val left = innermostBlock(body, body.indexOf("RowTitle("), "Column(")
        assertTrue("Footnote is in the left column (inline)", left != null && "footnote" in left.block)
    }

    @Test
    fun `RL2-LAYOUT-ROW-06 menu row value column takes at most 45 percent and two lines`() {
        val body = functionBody(source("feature/providers/relay/RelayAdvancedSettingsSheet.kt"), "private fun EditRowBody(")
        val trailing = innermostBlock(body, body.indexOf("trailing()"), "Row(")
        assertTrue("Value column not found", trailing != null)
        trailing!!
        assertTrue("Value column max width = 45% of the row width", "widthIn(max = valueMaxWidth)" in trailing.args && "* 0.45f" in body)
        assertTrue("Value has at most 2 lines", "maxLines = 2" in trailing.block)
        assertTrue("Value is tail-truncated", "TextOverflow.Ellipsis" in trailing.block && "MiddleEllipsis" !in trailing.block)
        assertTrue("Value column is vertically centered on the whole row", "verticalAlignment = Alignment.CenterVertically" in trailing.args)
        // The 45% is based on the row content width excluding the trailing chevron; the chevron is outside the value column, "Change" is inside it; the footnote is not truncated.
        assertTrue("Base width deducts the trailing chevron", "maxWidth - ROW_CHEVRON - ROW_CHEVRON_GAP" in body && "contentWidth * 0.45f" in body)
        assertFalse("Chevron is not inside the value column", "chevron" in trailing.block)
        val chevron = body.indexOf("chevron?.invoke()")
        assertTrue("Chevron comes after the value column", chevron > body.indexOf(trailing.block))
        val footnote = calls(body, "Text(").map { it.second }.single { "typography.footnote" in it }
        assertFalse("Footnote has no line cap: $footnote", "maxLines" in footnote || "Ellipsis" in footnote)
        val sheet = source("feature/providers/relay/RelayAdvancedSettingsSheet.kt")
        val valueRow = functionBody(sheet, "private fun ValueRow(")
        val slotStart = valueRow.indexOf("chevron = {")
        assertTrue("Action row has a chevron slot", slotStart >= 0)
        val slot = valueRow.substring(slotStart, matching(valueRow, valueRow.indexOf('{', slotStart), '{', '}') + 1)
        assertTrue("Action row chevron goes through the chevron slot", "R.drawable.ph_caret_right" in slot)
        assertTrue("Change is not in the chevron slot (it is inside the value column)", "text = trailing" !in slot && "text = trailing" in valueRow)
        val menuRow = functionBody(sheet, "internal fun <T> MenuRow(")
        val menuSlot = menuRow.indexOf("chevron = ")
        assertTrue("Menu row chevron goes through the chevron slot", menuSlot >= 0 && menuSlot < menuRow.indexOf("R.drawable.ph_caret_down"))
    }

    @Test
    fun `RL2-LAYOUT-ROW-09 setup group header pins select all in group to the row end`() {
        // Name + count + selected are packed into a cluster that fills the remaining width; "Select all in group" is the last item at the row end and does not drift with name length.
        val body = functionBody(source("feature/providers/relay/RelaySetupScreen.kt"), "private fun RelaySetupModelGroupView(")
        val header = innermostBlock(body, body.indexOf("R.string.relay_setup_select_group"), "Row(")
        assertTrue("Group header not found", header != null && "clickable(onClick = onToggleGroup)" in header.args)
        header!!
        assertFalse("Group header no longer splits remaining width with the name via a Spacer", "Spacer(" in header.block)
        val cluster = innermostBlock(body, body.indexOf("group.titleRes"), "Row(")
        assertTrue("The name is in its own cluster", cluster != null && cluster.args != header.args && cluster.block in header.block)
        cluster!!
        assertTrue("Cluster fills the remaining width: ${cluster.args}", "Modifier.weight(1f)" in cluster.args && "fill = false" !in cluster.args)
        assertTrue("The count follows the name directly", "group.modelCount" in cluster.block)
        assertFalse("The button is not in the cluster", "relay_setup_select_group" in cluster.block)
        assertTrue("The button comes after the cluster (row end)", header.block.indexOf("R.string.relay_setup_select_group") > header.block.indexOf(cluster.block))
    }

    @Test
    fun `RL2-LAYOUT-ROW-07 library header subtitle wraps to two lines with tail truncation`() {
        val view = source("feature/providers/detail/RelayCatalogBoardView.kt")
        val subtitle = calls(view, "Text(").map { it.second }.single { "R.plurals.relay_keys_count" in it }
        assertTrue("Subtitle has at most 2 lines: $subtitle", "maxLines = 2" in subtitle)
        assertTrue("Subtitle is tail-truncated, not middle-truncated: $subtitle", "TextOverflow.Ellipsis" in subtitle && "MiddleEllipsis" !in subtitle)
    }

    @Test
    fun `RL2-LAYOUT-URL-01 scheme chip slot shows only the part after the scheme`() {
        // The slot shows only what follows the scheme; input containing "://" replaces the whole string, otherwise the written scheme is kept; the chip shows the written scheme, https when none.
        assertEquals("api.relay-demo.example/v1", relaySchemeSlotText("https://api.relay-demo.example/v1"))
        assertEquals("localhost:11434", relaySchemeSlotText("http://localhost:11434"))
        assertEquals("api.example.com", relaySchemeSlotText("api.example.com"))
        assertEquals("http://new.example", relaySchemeSlotInput("http://old.example", "new.example"))
        assertEquals("https://pasted.example/v1", relaySchemeSlotInput("http://old.example", "https://pasted.example/v1"))
        assertEquals("typed.example", relaySchemeSlotInput("", "typed.example"))
        // Slot cleared means the whole string is cleared, leaving no half scheme.
        assertEquals("", relaySchemeSlotInput("https://old.example", ""))
        assertEquals("", relaySchemeSlotInput("http://old.example", ""))
        assertEquals("https", setupSchemeChip("api.example.com", cleartext = false))
        assertEquals("http", setupSchemeChip("http://api.example.com", cleartext = false))
        // Placeholder drops the scheme: setup / manual setup api.example.com, edit api.example.com/v1 (URL examples are not translated).
        assertEquals("api.example.com", RELAY_ENDPOINT_PLACEHOLDER)
        assertEquals("api.example.com/v1", RELAY_EDIT_ENDPOINT_PLACEHOLDER)
        // Both address slots with chips read and write through this pair of pure functions.
        val quick = functionBody(source("feature/providers/relay/RelaySetupScreen.kt"), "internal fun RelayQuickField(")
        val address = functionBody(source("feature/providers/relay/RelayAdvancedSettingsSheet.kt"), "private fun AddressRow(")
        listOf("Quick field" to quick, "Edit address row" to address).forEach { (name, body) ->
            assertTrue("$name slot shows what follows the scheme", "relaySchemeSlotText(" in body)
            assertTrue("$name input write-back keeps the scheme", "relaySchemeSlotInput(" in body)
        }
        assertTrue("Edit address row placeholder drops the scheme", "RELAY_EDIT_ENDPOINT_PLACEHOLDER" in address)
    }

    @Test
    fun `RL2-LAYOUT-HEADER-01 family section titles are small secondary labels`() {
        val label = functionBody(source("feature/providers/detail/ProviderDetailSectionHeader.kt"), "fun ProviderDetailSectionLabel(")
        assertTrue("Small secondary-color label: footnote semibold + letter spacing + textSecondary", listOf("footnote", "SemiBold", "letterSpacing", "textSecondary").all { it in label })
        assertFalse("Label has no accent bar", "colors.primary" in label || "width(4.dp)" in label)
        val familyPages = listOf(
            "detail/RelayDetailBoardView.kt",
            "detail/RelayWebSearchPage.kt",
            "relay/RelayAdvancedSettingsSheet.kt",
            "relay/RelaySetupScreen.kt",
        )
        val offenders = familyPages.filter { "ProviderDetailSectionHeader(" in source("feature/providers/$it") }
        assertTrue("Section titles of detail / edit / manual setup / web must not use the accent-bar header: $offenders", offenders.isEmpty())
        assertTrue("Detail page sections use the small label", "ProviderDetailSectionLabel(" in source("feature/providers/detail/RelayDetailBoardView.kt"))
        assertTrue("Edit / manual-setup groups use the small label", "ProviderDetailSectionLabel(" in source("feature/providers/relay/RelayAdvancedSettingsSheet.kt"))
        assertTrue("Web section uses the small label", "ProviderDetailSectionLabel(" in source("feature/providers/detail/RelayWebSearchPage.kt"))
        // Only the catalog "Enabled · N" still uses the accent-bar header.
        assertTrue("Catalog enabled section keeps the accent-bar header", "ProviderDetailSectionHeader(" in source("feature/providers/detail/ProviderDetailEnabledModels.kt"))
    }

    private data class Call(val args: String, val block: String, val end: Int)

    private data class Anchor(val where: String, val row: Call?)

    private fun source(path: String): String = File(root(), path).readText()

    /** Every "whole-row vertical centering" line-comment anchor in the file and its corresponding Row. */
    private fun anchors(file: File): List<Anchor> {
        if (!file.isFile) return emptyList()
        val text = file.readText()
        val lines = text.lines()
        val offsets = lines.runningFold(0) { acc, line -> acc + line.length + 1 }
        return lines.indices.filter { i -> lines[i].contains("//") && ANCHOR in lines[i].substringAfter("//") }.map { i ->
            val following = (i + 1 until lines.size)
                .filter { lines[it].isNotBlank() && !lines[it].trimStart().startsWith("//") }
                .take(6)
                .firstOrNull { ROW_CALL.containsMatchIn(lines[it]) }
            val row = if (following != null) {
                callAt(text, offsets[following] + ROW_CALL.find(lines[following])!!.range.first + 1)
            } else {
                innermostBlock(text, offsets[i], "Row(")
            }
            Anchor("${file.name}:${i + 1}", row)
        }
    }

    /** The `Row(` call at [index]: arguments (parentheses balanced) + trailing lambda block. */
    private fun callAt(text: String, index: Int): Call {
        val open = text.indexOf('(', index)
        val close = matching(text, open, '(', ')')
        var cursor = close + 1
        while (cursor < text.length && text[cursor].isWhitespace()) cursor++
        if (cursor >= text.length || text[cursor] != '{') return Call(text.substring(open, close + 1), "", close)
        val blockEnd = matching(text, cursor, '{', '}')
        return Call(text.substring(open, close + 1), text.substring(cursor, blockEnd + 1), blockEnd)
    }

    /** The innermost [token] call enclosing [position] (its arguments or trailing block cover it). */
    private fun innermostBlock(text: String, position: Int, token: String): Call? {
        if (position < 0) return null
        var best: Call? = null
        var index = text.indexOf(token)
        while (index in 0 until position) {
            val prev = if (index > 0) text[index - 1] else ' '
            if (!prev.isLetterOrDigit()) {
                val call = callAt(text, index)
                if (call.end > position) best = call
            }
            index = text.indexOf(token, index + 1)
        }
        return best
    }

    private fun functionBody(text: String, signature: String): String {
        val start = text.indexOf(signature)
        assertTrue("Cannot find $signature", start >= 0)
        val paramsEnd = matching(text, text.indexOf('(', start + signature.length - 1), '(', ')')
        val open = text.indexOf('{', paramsEnd)
        return text.substring(open, matching(text, open, '{', '}') + 1)
    }

    private fun matching(text: String, open: Int, left: Char, right: Char): Int {
        var depth = 0
        var i = open
        while (i < text.length) {
            when (text[i]) {
                left -> depth++
                right -> if (--depth == 0) return i
            }
            i++
        }
        return text.length - 1
    }

    private fun familyFiles(): List<File> {
        val root = root()
        val relay = File(root, "feature/providers/relay").listFiles { f -> f.extension == "kt" }.orEmpty().toList()
        val detail = File(root, "feature/providers/detail").listFiles { f ->
            f.extension == "kt" && (f.name.startsWith("Relay") || f.name in setOf("ProviderCatalogComponents.kt", "ProviderDetailEnabledModels.kt"))
        }.orEmpty().toList()
        val files = relay + detail + File(root, "feature/chat/crosscheck/CrosscheckSheet.kt")
        assertTrue("Family files not found", files.size > 10)
        return files
    }

    /** Arguments of each call (parentheses balanced across lines). */
    private fun calls(text: String, token: String): List<Pair<Int, String>> {
        val result = mutableListOf<Pair<Int, String>>()
        var index = text.indexOf(token)
        while (index >= 0) {
            val prev = if (index > 0) text[index - 1] else ' '
            val start = index + token.length - 1
            var depth = 0
            var end = start
            while (end < text.length) {
                when (text[end]) {
                    '(' -> depth++
                    ')' -> if (--depth == 0) break
                }
                end++
            }
            if (!prev.isLetterOrDigit()) result += text.substring(0, index).count { it == '\n' } + 1 to text.substring(start, end + 1)
            index = text.indexOf(token, end)
        }
        return result
    }

    private fun root(): File {
        val direct = File("src/main/java/ai/oriveo/community")
        if (direct.isDirectory) return direct
        return File("app/src/main/java/ai/oriveo/community")
    }

    private companion object {
        const val ANCHOR = "whole-row vertical centering"
        val ROW_CALL = Regex("""(?<![A-Za-z0-9])Row\(""")
        val DOWN_ICON = Regex("""ExpandMore|ph_caret_down|KeyboardArrowDown|ArrowDropDown""")
        val RIGHT_ICON = Regex("""ph_caret_right|ChevronRight""")
        val ROTATION = Regex("""\.rotate\(|rotationZ""")
        val DIRECTIONAL_ICON = Regex(
            """Icons\.(Filled|Outlined|Rounded|Default|Sharp|TwoTone)\.(ChevronRight|ChevronLeft|KeyboardArrowRight|KeyboardArrowLeft|ArrowForwardIos|ArrowBackIos|ArrowForward|ArrowBack|NavigateNext|NavigateBefore)\b""",
        )
    }
}
