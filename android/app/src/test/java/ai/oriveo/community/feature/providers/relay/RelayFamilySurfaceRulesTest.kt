package ai.oriveo.community.feature.providers.relay

import ai.oriveo.community.R
import ai.oriveo.community.core.data.repository.ProviderRepository
import ai.oriveo.community.feature.providers.detail.RelayDetailBoardModel
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Source gates for the card surfaces and bottom bars of the relay family pages: the needs-attention card,
 * the edit-connection validation failure card, the edit bottom bar, the manual setup connection name and
 * the top safe area of step 2. The recovery and edit-failure checks share their names with iOS / Web.
 */
class RelayFamilySurfaceRulesTest {

    @Test
    fun `recovery card is neutral and dismissible for this visit only`() {
        val board = source(MAIN, "feature/providers/detail/RelayDetailBoardView.kt")
        val card = functionBody(board, "internal fun RelayRecoveryCardView(")
        assertFalse("the needs-attention card no longer has a yellow background", "warningSoft" in card)
        assertFalse("the needs-attention card no longer has a yellow border", ".border(" in card)
        assertTrue("the needs-attention card uses the same surface as a regular card", "surfaceElevated" in card)
        assertTrue("top-right x dismisses", "onDismiss" in card)
        assertTrue("the reason row still follows lastError (card.reason)", "card.reason" in card)
        // The marker string stored by an unverified save maps to the reason row "Connection has not been verified." (same as iOS); everything else goes through the usual error mapping.
        assertEquals(
            R.string.relay_connection_not_verified,
            RelayDetailBoardModel.recoveryReasonRes(ProviderRepository.RELAY_UNVERIFIED_MESSAGE),
        )
        assertNull(RelayDetailBoardModel.recoveryReasonRes("Incorrect API key provided."))
        assertTrue("the reason row goes through the production mapping", "RelayDetailBoardModel.recoveryReasonRes(reason)" in card)

        val screen = source(MAIN, "feature/providers/detail/ProviderDetailScreen.kt")
        val state = Regex("""var (\w+) by (remember\w*) \{ mutableStateOf\(false\) \}""").findAll(screen)
            .firstOrNull { it.groupValues[1] == "dismissedRelayRecovery" }
        assertTrue("the x hides only for this visit to the page", state != null)
        assertTrue("not persisted (no rememberSaveable)", state!!.groupValues[2] == "remember")
        val call = screen.substring(screen.indexOf("RelayRecoveryCardView(card"))
        assertTrue("the call site wires up dismissal", call.substringBefore('\n').contains("onDismiss = { dismissedRelayRecovery = true }"))
    }

    @Test
    fun `edit connection failure card is warning toned with save anyway`() {
        val sheet = source(MAIN, "feature/providers/relay/RelayAdvancedSettingsSheet.kt")
        val status = functionBody(sheet, "internal fun StatusBlock(")
        assertTrue("the call site can set the failure card tone", "severity ?:" in status)
        val editCall = sheet.substring(sheet.indexOf("StatusBlock(\n                    status = board.status,"))
            .substringBefore("\n                )")
        assertTrue("the edit connection validation failure card tone is warning", "severity = OriveoErrorSeverity.Warning" in editCall)
    }

    @Test
    fun `failure card puts technical details below the primary button`() {
        val card = functionBody(source(MAIN, "ui/component/OriveoErrorCard.kt"), "fun OriveoErrorCard(")
        val below = card.indexOf("if (detailsBelowAction) details()")
        assertTrue("technical details can optionally go below the primary button", below >= 0)
        assertTrue("the lower copy comes after the primary button", below > card.indexOf("OriveoPrimaryButton("))
        assertTrue("the default position is unchanged (other pages stay as they were)", card.indexOf("if (!detailsBelowAction) details()") in 0 until card.indexOf("OriveoPrimaryButton("))
        val status = functionBody(source(MAIN, "feature/providers/relay/RelayAdvancedSettingsSheet.kt"), "internal fun StatusBlock(")
        val call = status.substring(status.indexOf("OriveoErrorCard("))
        assertTrue("edit / manual setup failure card technical details sit below the primary button", "detailsBelowAction = true" in call)
        assertTrue("the manual setup note goes on its own line after the reason", "listOfNotNull(reason, failureNote).joinToString(\"\\n\")" in status)
    }

    @Test
    fun `manual setup failure production reveals the card`() {
        val setup = source(MAIN, "feature/providers/relay/RelaySetupScreen.kt")
        assertFalse("production keeps no focus requester parameter that only the sample uses", "manualModelFocusRequester" in setup)
        val content = functionBody(setup, "private fun RelayManualSetupContent(")
        val reveal = content.substring(content.indexOf("if (reveal) {")).substringBefore("}")
        assertTrue("after a failure production clears focus, hides the keyboard and scrolls to the failure card: $reveal", "clearFocus()" in reveal && "keyboard?.hide()" in reveal && "failureRequester.bringIntoView()" in reveal)
    }

    @Test
    fun `manual model dialog focuses its field on open`() {
        val entry = functionBody(source(MAIN, "feature/providers/relay/RelaySetupScreen.kt"), "private fun RelayManualModelEntry(")
        val dialog = entry.substring(entry.indexOf("AlertDialog("))
        assertTrue("the dialog input has a focus requester attached", "remember { FocusRequester() }" in entry && ".focusRequester(" in dialog)
        assertTrue("focuses as soon as it opens", "LaunchedEffect(" in dialog && ".requestFocus()" in dialog)
    }

    @Test
    fun `address slots use the body font, not monospace`() {
        val address = functionBody(source(MAIN, "feature/providers/relay/RelayAdvancedSettingsSheet.kt"), "private fun AddressRow(")
        assertFalse("the edit page address slot is not monospace", "Monospace" in address)
        assertTrue("the address slot uses the body font", "OriveoTheme.typography.body" in address)
        assertFalse("the add page address slot is not monospace", "FontFamily.Monospace" in source(MAIN, "feature/providers/relay/RelaySetupScreen.kt"))
    }

    @Test
    fun `menu row values show Auto for the automatic choices`() {
        val provider = ai.oriveo.community.core.model.Provider(
            id = "menuval",
            kind = ai.oriveo.community.core.model.ProviderKind.Relay,
            baseUrlText = "https://api.relay-demo.example",
            relayRequested = ai.oriveo.community.core.model.RelayRequestedConfig(
                transport = ai.oriveo.community.core.model.RelayTransport.Auto,
                authMode = ai.oriveo.community.core.model.RelayAuthMode.Auto,
            ),
        )
        val rows = RelayEditBoardModel.make(
            provider = provider,
            draft = RelayEditDraft.from(provider, null),
            status = null,
            isSaving = false,
            issues = emptyList(),
        ).groups.flatMap { it.rows }.associateBy { it.id }
        assertEquals("automatic default protocol shows Auto", R.string.relay_profile_auto, rows.getValue(RelayEditRowId.DefaultProtocol).valueRes)
        assertEquals("automatic authentication shows Auto", R.string.relay_profile_auto, rows.getValue(RelayEditRowId.Authentication).valueRes)
        assertEquals(
            "the same row in manual setup",
            R.string.relay_profile_auto,
            RelayEditBoardModel.defaultProtocolRow(ai.oriveo.community.core.model.RelayTransport.Auto).valueRes,
        )
        // Menu candidates keep their full names (only the row value changes).
        assertEquals(R.string.relay_transport_auto, relayTransportLabelRes(ai.oriveo.community.core.model.RelayTransport.Auto))
        assertEquals(R.string.relay_auth_auto, relayAuthModeLabelRes(ai.oriveo.community.core.model.RelayAuthMode.Auto))
        // Authentication Bearer shows "Bearer" (same as iOS; the menu candidate follows with the same name).
        assertEquals(R.string.relay_auth_bearer, relayAuthModeMenuValueRes(ai.oriveo.community.core.model.RelayAuthMode.Bearer))
        val strings = listOf(File("src/main/res/values/strings.xml"), File("app/src/main/res/values/strings.xml")).first { it.isFile }.readText()
        assertTrue("English Bearer carries no token", "<string name=\"relay_auth_bearer\">Bearer</string>" in strings)
    }

    @Test
    fun `manual setup collapsed summary and other value displays use the short Auto`() {
        val board = RelayManualSetupBoardModel.make(
            RelayManualSetupInput(
                endpoint = "https://api.relay-demo.example", keys = emptyList(), model = "gpt-5.6-sol", connectionName = "",
                transport = ai.oriveo.community.core.model.RelayTransport.Auto, authMode = ai.oriveo.community.core.model.RelayAuthMode.Auto,
                userAgent = "", headers = emptyList(), queryParams = emptyList(), issues = emptyList(),
                advancedExpanded = false, isValidating = false, failure = null, completed = false, modelPlaceholder = "",
            ),
        )
        assertEquals("the automatic option in the authentication, headers and query params summary shows Auto", R.string.relay_profile_auto, board.advancedSummary.authRes)
        // Value slots (not menu candidates) always go through MenuValueRes and no longer show "Auto detect" directly.
        assertFalse("the manual setup summary does not use the full candidate name directly", "RelayManualSummary(relayAuthModeLabelRes(" in source(MAIN, "feature/providers/relay/RelayManualSetupBoard.kt"))
        assertFalse("the local transport value does not use the full candidate name directly", "valueRes = relayTransportLabelRes(" in source(MAIN, "feature/providers/relay/RelayEditBoardModel.kt"))
        assertFalse("the advanced page transport value does not use the full candidate name directly", "valueRes = relayTransportLabelRes(" in source(MAIN, "feature/providers/detail/RelayModelAdvancedBoard.kt"))
    }

    @Test
    fun `manual setup and edit failure cards share the warning style`() {
        val status = functionBody(source(MAIN, "feature/providers/relay/RelayAdvancedSettingsSheet.kt"), "internal fun StatusBlock(")
        assertTrue("the failure card defaults to the warning style (yellow triangle) and does not turn red with the error mapping", "severity = severity ?: OriveoErrorSeverity.Warning," in status)
        assertFalse("no longer falls back to the severity the error carries", "status.error?.severity" in status)
    }

    @Test
    fun `vendor monogram uses the localized group name`() {
        assertEquals("OT", ai.oriveo.community.ui.component.vendorMonogram("Other"))
        assertEquals("SO", ai.oriveo.community.ui.component.vendorMonogram("Sonstige"))
        assertEquals("split words by Unicode letters and take the first 2 characters", "\u305d\u306e", ai.oriveo.community.ui.component.vendorMonogram("\u305d\u306e\u4ed6"))
        assertEquals("\u5176\u4ed6", ai.oriveo.community.ui.component.vendorMonogram("\u5176\u4ed6"))
        assertEquals("falls back to AI when no word can be split", "AI", ai.oriveo.community.ui.component.vendorMonogram(" - / "))
        // Combining marks (\p{M}) are not split off their base character: Thai อ plus two upper marks is one character cluster.
        assertEquals("อื่น", ai.oriveo.community.ui.component.vendorMonogram("อื่นๆ"))
        val hindi = "अन्य"
        val hi = ai.oriveo.community.ui.component.vendorMonogram(hindi)
        assertTrue("hi takes a prefix of the original word: $hi", hindi.startsWith(hi) && hi.length >= 2)
        assertFalse(
            "hi does not split combining marks apart: $hi",
            hi.length < hindi.length && Character.getType(hindi[hi.length]).toByte() in setOf(Character.NON_SPACING_MARK, Character.COMBINING_SPACING_MARK, Character.ENCLOSING_MARK),
        )
        assertEquals("two or more words take the initials of the first two", "MA", ai.oriveo.community.ui.component.vendorMonogram("Mistral AI"))
        assertEquals("AI", ai.oriveo.community.ui.component.vendorMonogram(""))
        val header = source(MAIN, "feature/providers/detail/ProviderCatalogComponents.kt")
            .substringAfter("ModelVendorIcon(").substringBefore(")\n")
        assertTrue("the Other group passes the localized group name", "groupName = group.titleRes?.let { stringResource(it) } ?: group.title" in header)
    }

    @Test
    fun `edit connection action bar puts test connection beside save`() {
        val bar = functionBody(source(MAIN, "feature/providers/relay/SetupBoardComponents.kt"), "internal fun SetupActionBar(")
        assertTrue("side-by-side variant: the secondary outlined button first, the primary button after", "OriveoSecondaryButton(" in bar && "secondaryInline" in bar)
        val sheet = source(MAIN, "feature/providers/relay/RelayAdvancedSettingsSheet.kt")
        assertTrue("edit connection uses the side-by-side variant", "secondaryInline = true" in sheet)
        val setup = source(MAIN, "feature/providers/relay/RelaySetupScreen.kt")
        assertFalse("the setup page bottom bar is unchanged", "secondaryInline" in setup)
    }

    @Test
    fun `manual connection name shows only the derived domain on the right`() {
        val setup = source(MAIN, "feature/providers/relay/RelaySetupScreen.kt")
        val block = setup.substring(setup.indexOf("RelayManualBlock.ConnectionName ->")).substringBefore("RelayManualBlock.ProtocolCard ->")
        assertFalse("does not fall back to the in-slot label when no domain can be derived", "connectionNamePlaceholder ?: stringResource" in block)
    }

    @Test
    fun `models step keeps its title below the status bar`() {
        val setup = source(MAIN, "feature/providers/relay/RelaySetupScreen.kt")
        val top = setup.substring(setup.indexOf("if (!showsModelsStep) RelaySetupTopBar(")).substringBefore("Column(")
        assertTrue("step 2 leaves room for the status bar itself when no topBar is stacked", "statusBarsPadding()" in top)
    }

    private fun source(base: String, path: String): String {
        val direct = File("src/$base/java/ai/oriveo/community", path)
        return (if (direct.isFile) direct else File("app/src/$base/java/ai/oriveo/community", path)).readText()
    }

    private fun functionBody(text: String, signature: String): String {
        val start = text.indexOf(signature)
        assertTrue("cannot find $signature", start >= 0)
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

    private companion object {
        const val MAIN = "main"
        const val DEBUG = "debug"
    }
}
