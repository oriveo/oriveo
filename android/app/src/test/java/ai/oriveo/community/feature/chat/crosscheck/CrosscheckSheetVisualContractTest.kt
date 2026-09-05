package ai.oriveo.community.feature.chat.crosscheck

import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CrosscheckSheetVisualContractTest {
    private val source = File("src/main/java/ai/oriveo/community/feature/chat/crosscheck/CrosscheckSheet.kt").readText()
    private val coordinatorSource =
        File("src/main/java/ai/oriveo/community/feature/chat/crosscheck/CrosscheckCoordinator.kt").readText()
    private val chatNoteCoordinatorSource =
        File("src/main/java/ai/oriveo/community/feature/chat/ChatNoteCoordinator.kt").readText()
    private val noteDetailViewModelSource =
        File("src/main/java/ai/oriveo/community/feature/notes/NoteDetailViewModel.kt").readText()

    @Test
    fun `crosscheck page reuses shared model picker with add model support`() {
        val pageSetup = source.requiredSlice(
            from = "fun CrosscheckSheet(",
            to = "if (showModelPicker) {",
        )
        val pickerSheet = source.requiredSlice(
            from = "if (showModelPicker) {",
            to = "@Composable\nprivate fun CrosscheckHeader(",
        )

        assertFalse(pageSetup.contains("DropdownMenu"))
        assertTrue(pageSetup.contains("BackHandler {"))

        val mainPage = source.requiredSlice(
            from = "Box(\n        modifier = Modifier\n            .fillMaxSize()",
            to = "\n\n    if (showModelPicker) {",
        )

        assertTrue(mainPage.contains(".fillMaxSize()"))
        assertTrue(mainPage.contains("CommandDock("))
        assertTrue(mainPage.contains("SecondOpinionStage("))
        assertTrue(mainPage.contains("OriginalSourceStrip("))
        assertFalse(mainPage.contains("ModelPickerSheet("))
        assertFalse(mainPage.contains("ModalBottomSheet("))
        assertTrue(source.contains("private fun ModelComparisonRail("))

        assertTrue(pickerSheet.contains("ModalBottomSheet("))
        assertTrue(pickerSheet.contains("onDismissRequest = { showModelPicker = false }"))
        assertTrue(pickerSheet.contains("sheetState = pickerSheetState"))
        assertTrue(pickerSheet.contains("dragHandle = null"))
        assertTrue(pickerSheet.contains("contentWindowInsets = { WindowInsets(0) }"))
        assertTrue(pickerSheet.contains("ModelPickerSheet("))
        assertTrue(pickerSheet.contains("context = ModelPickerContext.Crosscheck"))
        assertTrue(pickerSheet.contains("providers = pickerProviders"))
        assertTrue(pickerSheet.contains("onEnableModel = onEnableModel"))
        assertTrue(pickerSheet.contains("onDismiss = { showModelPicker = false }"))
        assertFalse(source.contains("private fun CrosscheckModelPickerSheet("))
    }

    @Test
    fun `executed model is not reset when options refresh`() {
        val stateSetup = source.requiredSlice(
            from = "var selected by remember",
            to = "val displayState = if (executed == null)",
        )
        val refreshEffect = source.requiredSlice(
            from = "LaunchedEffect(options)",
            to = "BackHandler {",
        )

        assertTrue(stateSetup.contains("var executed by remember { mutableStateOf<CrosscheckOption?>(null) }"))
        assertFalse(stateSetup.contains("var executed by remember(options)"))
        assertFalse(refreshEffect.contains("executed = null"))
        assertTrue(refreshEffect.contains("selected = CrosscheckCoordinator.visibleOptionOrDefault(options, selected)"))
    }

    @Test
    fun `main sheet picker entry uses providers with visible options only`() {
        val mainSheet = source.requiredSlice(
            from = "fun CrosscheckSheet(",
            to = "BackHandler {",
        )
        val headerCall = source.requiredSlice(
            from = "CrosscheckHeader(",
            to = ")\n                    }",
        )

        assertTrue(mainSheet.contains("CrosscheckCoordinator.visibleOptions(options)"))
        assertTrue(mainSheet.contains("CrosscheckCoordinator.pickerProviders("))
        assertTrue(mainSheet.contains("providers = providers"))
        assertTrue(mainSheet.contains("visibleOptions = visibleOptions"))
        assertTrue(headerCall.contains("visibleOptions.isNotEmpty()"))
    }

    @Test
    fun `comparison rail avoids full rectangular border`() {
        val rail = source.requiredSlice(
            from = "private fun ModelComparisonRail(",
            to = "@Composable\nprivate fun ModelRailBlock(",
        )

        assertFalse(rail.contains(".border(width = 0.5.dp"))
        assertTrue(rail.contains("CrosscheckRailHairline()"))
    }

    @Test
    fun `model rail keeps full width while close button padding only affects copy`() {
        val header = source.requiredSlice(
            from = "private fun CrosscheckHeader(",
            to = "@Composable\nprivate fun ModelComparisonRail(",
        )

        assertFalse(header.contains(".padding(top = 12.dp, end = 42.dp)"))
        assertTrue(header.contains("modifier = Modifier.padding(end = 52.dp)"))
        assertTrue(header.contains("ModelComparisonRail("))
    }

    @Test
    fun `close button is restrained without double circular outline`() {
        val closeButton = source.requiredSlice(
            from = "private fun CloseButton(",
            to = "@Composable\nprivate fun CommandDock(",
        )

        assertFalse(closeButton.contains(".border("))
        assertFalse(closeButton.contains(".clip(CircleShape)"))
        assertFalse(closeButton.contains(".background("))
        assertTrue(closeButton.contains("Icons.Filled.Close"))
        assertTrue(closeButton.contains(".size(44.dp)"))
    }

    @Test
    fun `crosscheck run button has no duplicate light or dark dock shell`() {
        val commandDock = source.requiredSlice(
            from = "private fun CommandDock(",
            to = "@Composable\nprivate fun IconCircleButton(",
        )
        val heroButton = source.requiredSlice(
            from = "private fun CrosscheckDockHeroButton(",
            to = "@Composable\nprivate fun Provider.resolvedRelayKind(",
        )

        assertTrue(commandDock.contains("CrosscheckDockHeroButton("))
        assertFalse(commandDock.contains(".background("))
        assertFalse(commandDock.contains(".border("))
        assertFalse(commandDock.contains(".clip("))
        assertFalse(commandDock.contains(".shadow("))
        assertTrue(heroButton.contains(".background("))
        assertTrue(heroButton.contains(".border("))
    }

    @Test
    fun `crosscheck answer copy is not indented by a leading icon`() {
        val header = source.requiredSlice(
            from = "private fun CrosscheckHeader(",
            to = "@Composable\nprivate fun ModelComparisonRail(",
        )
        val stage = source.requiredSlice(
            from = "private fun SecondOpinionStage(",
            to = "@Composable\nprivate fun EmptyResultContent(",
        )

        assertTrue(header.contains("CrosscheckHeroIcon()"))
        assertTrue(stage.contains("SecondOpinionTitle("))
        assertTrue(stage.contains("-> ResultContent(text = state.text)"))
        assertFalse(stage.contains("ResultContentWithIcon("))
        assertTrue(source.contains("private fun CrosscheckHeroIcon("))
        assertTrue(source.contains("private fun SecondOpinionTitle("))
        assertTrue(source.contains("private fun ResultContent(\n    text: String,"))
        assertFalse(source.contains("private fun ResultContentWithIcon("))
        assertTrue(source.contains("Icons.Filled.AutoAwesome"))
        assertFalse(source.contains("FactCheck"))
    }

    @Test
    fun `crosscheck runtime message uses provider display name`() {
        val runtimeMessage = coordinatorSource.requiredSlice(
            from = "val crosscheckUserMessage = ChatMessage(",
            to = "state = ChatMessageState.Delivered,",
        )

        assertTrue(runtimeMessage.contains("providerName = provider.displayName"))
        assertFalse(runtimeMessage.contains("provider.kind.name"))
    }

    @Test
    fun `crosscheck picker reuses model picker transport filtering`() {
        val sectionBuilder = coordinatorSource.requiredSlice(
            from = "object CrosscheckModelPickerSectionBuilder",
            to = "\nclass CrosscheckCoordinator(",
        )

        assertTrue(sectionBuilder.contains("isModelTransportSupportedForModelPicker(option.provider, option.model)"))
    }

    @Test
    fun `crosscheck picker provider projection keeps catalog models for add flow`() {
        val projection = coordinatorSource.requiredSlice(
            from = "fun pickerProviders(",
            to = "\n\n        fun visibleOptionOrDefault(",
        )

        assertTrue(projection.contains("providers: List<Provider>"))
        assertTrue(projection.contains("visibleOptions: List<CrosscheckOption>"))
        assertTrue(projection.contains("provider.copy("))
        assertTrue(projection.contains("models = visibleModelsByProviderId[provider.id].orEmpty()"))
        assertTrue(projection.contains("catalogModels = provider.catalogModels"))
    }

    @Test
    fun `crosscheck saved note uses provider display name`() {
        val chatSave = chatNoteCoordinatorSource.requiredSlice(
            from = "fun saveCrosscheckNote(option: CrosscheckOption)",
            to = "crosscheckModelID = option.model.id,",
        )
        val noteSave = noteDetailViewModelSource.requiredSlice(
            from = "fun saveCrosscheckNote(option: CrosscheckOption)",
            to = "crosscheckModelID = option.model.id,",
        )

        assertTrue(chatSave.contains("crosscheckProviderName = option.provider.displayName"))
        assertTrue(noteSave.contains("crosscheckProviderName = option.provider.displayName"))
        assertFalse(chatSave.contains("option.provider.kind.name"))
        assertFalse(noteSave.contains("option.provider.kind.name"))
    }
}

private fun String.requiredSlice(from: String, to: String): String {
    val startIndex = indexOf(from)
    require(startIndex >= 0) { "Missing start boundary: $from" }
    val endIndex = indexOf(to, startIndex + from.length)
    require(endIndex >= 0) { "Missing end boundary: $to" }
    return substring(startIndex, endIndex)
}
