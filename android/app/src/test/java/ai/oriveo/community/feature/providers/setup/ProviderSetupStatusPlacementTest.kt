package ai.oriveo.community.feature.providers.setup

import java.io.File
import org.junit.Assert.assertTrue
import org.junit.Test

class ProviderSetupStatusPlacementTest {

    @Test
    fun `provider setup exposes local compute and custom relay as two entries`() {
        val source = File(
            "src/main/java/ai/oriveo/community/feature/providers/setup/ProviderSetupScreen.kt",
        ).readText()

        assertTrue(!source.contains("ProviderCategory.All && customLLMMatches"))
        assertTrue(!source.contains("providerSearchQuery"))
        assertTrue(!source.contains("provider_setup_search"))
        assertTrue(source.contains("RelayCustomEntry("))
        assertTrue(source.contains("LocalComputeEntry("))
        assertTrue(source.contains("private fun CustomProviderEntry("))
        assertTrue(!source.contains("iconShadowColor"))
        assertTrue(source.contains(".heightIn(min = 70.dp)"))
        assertTrue(source.contains("onOpenLocalComputeSetup"))
    }

    @Test
    fun `local compute entry fixes the shared coordinator to the local scenario`() {
        val source = File("src/main/java/ai/oriveo/community/core/navigation/OriveoNavHost.kt").readText()

        assertTrue(source.contains("composable<AppRoute.LocalComputeSetup>"))
        assertTrue(source.contains("AppRoute.LocalComputeSetup::class"))
        assertTrue(source.contains("initialMethod = CustomLLMConnectionMethod.Local"))
        assertTrue(source.contains("RelaySetupScreen("))
        assertTrue(source.contains("onOpenLocalComputeSetup"))
        assertTrue(source.contains("navController.navigate(AppRoute.LocalComputeSetup(route.entryPoint))"))
    }

    @Test
    fun `setup route never asks the user to choose the scenario again`() {
        val source = File(
            "src/main/java/ai/oriveo/community/feature/providers/relay/RelaySetupScreen.kt",
        ).readText()
        val local = File(
            "src/main/java/ai/oriveo/community/feature/providers/local/LocalComputeSetupScreen.kt",
        ).readText()

        assertTrue(!source.contains("CustomLLMConnectionMethodPicker("))
        assertTrue(!source.contains("SingleChoiceSegmentedButtonRow("))
        assertTrue(!source.contains("RelaySecurityModeControl("))
        assertTrue(local.contains("RelaySecurityModeControl("))
        assertTrue(source.contains("val routeMethod = initialMethod"))
        assertTrue(source.contains("R.string.provider_setup_relay_title"))
        assertTrue(source.contains("R.string.local_compute_title"))
    }

    @Test
    fun `relay quick setup matches iOS fields and keeps display name manual only`() {
        val source = File(
            "src/main/java/ai/oriveo/community/feature/providers/relay/RelaySetupScreen.kt",
        ).readText()
        val quickSetup = source
            .substringAfter("private fun RelayQuickSetupContent")
            .substringBefore("private fun RelayQuickField")
        val manualSetup = source
            .substringAfter("private fun RelaySimpleSection")
            .substringBefore("private fun RelayStepHeader")

        assertTrue(!quickSetup.contains("R.string.relay_field_name"))
        assertTrue(manualSetup.contains("R.string.relay_field_name"))

        val endpoint = quickSetup.indexOf("R.string.relay_field_endpoint")
        val apiKey = quickSetup.indexOf("R.string.api_key")
        val defaultModel = quickSetup.indexOf("R.string.relay_default_model_label")
        assertTrue(endpoint >= 0)
        assertTrue(apiKey > endpoint)
        assertTrue(defaultModel > apiKey)
    }

    @Test
    fun `local setup uses one engine menu and a measured sticky action bar`() {
        val fields = File(
            "src/main/java/ai/oriveo/community/feature/providers/local/LocalComputeSetupScreen.kt",
        ).readText()
        val shell = File(
            "src/main/java/ai/oriveo/community/feature/providers/relay/RelaySetupScreen.kt",
        ).readText()

        assertTrue(fields.contains("RelayMenuRow("))
        assertTrue(fields.contains("options = LocalEngineKind.entries"))
        assertTrue(!fields.contains("LocalComputeScenario.entries"))
        assertTrue(shell.contains("onSizeChanged { actionBarHeightPx = it.height }"))
        assertTrue(shell.contains("actionBarHeightPx.toDp()"))
        assertTrue(shell.contains("isVerified = localViewModel.isConnectionVerified"))
        assertTrue(!shell.contains("bottom = 176.dp"))
    }

    @Test
    fun `syncing status banner is rendered before scrollable provider setup content`() {
        val source = File(
            "src/main/java/ai/oriveo/community/feature/providers/setup/ProviderSetupScreen.kt",
        ).readText()

        val bannerIndex = source.indexOf("ProviderSetupLoadingStatusBanner(")
        val scrollIndex = source.indexOf(".verticalScroll(scrollState)")

        assertTrue("loading status banner should exist", bannerIndex >= 0)
        assertTrue("scrollable provider setup content should exist", scrollIndex >= 0)
        assertTrue("loading status banner should be above scrollable content", bannerIndex < scrollIndex)
    }
}
