package ai.oriveo.community.feature.providers.relay

import android.content.Context
import ai.oriveo.community.core.data.entity.ProviderEntity
import ai.oriveo.community.core.data.mapper.ProviderMapper
import ai.oriveo.community.core.data.remote.MetadataRefreshEventBus
import ai.oriveo.community.core.data.repository.ProviderRepository
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderConnectionState
import ai.oriveo.community.core.model.RelayKey
import ai.oriveo.community.core.navigation.ProviderSetupEntryPoint
import ai.oriveo.community.core.provider.RelayDiscoveryService
import ai.oriveo.community.core.provider.RelayService
import ai.oriveo.community.core.provider.relay.RelayKeyBinding
import ai.oriveo.community.core.provider.transport.TransportRegistry
import ai.oriveo.community.core.security.SecureKeyStore
import ai.oriveo.community.feature.providers.detail.ProviderDetailNotice
import ai.oriveo.community.feature.providers.detail.buildProviderCatalogGroups
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.http.ContentType
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpMethod
import io.ktor.http.HttpStatusCode
import io.ktor.http.content.TextContent
import io.ktor.http.headersOf
import io.mockk.coEvery
import io.mockk.every
import io.mockk.mockk
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.setMain
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.util.Collections

/**
 * Add page step 2 board (SetupModels): production [RelaySetupViewModel] + production [RelayDiscoveryService] +
 * production [ProviderRepository] / [RelayService] hit a MockEngine fake relay and count generation requests; persisted objects round-trip through the production ProviderMapper.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class RelaySetupModelsBoardTest {
    private val json = Json { ignoreUnknownKeys = true }

    @Before
    fun setUp() {
        Dispatchers.setMain(Dispatchers.Unconfined)
    }

    @After
    fun tearDown() {
        Dispatchers.resetMain()
    }

    @Test
    fun `BOARD-SETUPMODELS-01 groups follow the model library projection, start collapsed and select a whole group`() = runBlocking {
        val harness = Harness(catalogs = mapOf(KEY_A to CATALOG_A))
        val vm = harness.viewModel()
        vm.next()
        settle(vm)

        assertEquals(RelaySetupStep.Models, vm.step)
        val board = vm.modelsBoard
        // Group order of the catalog (same per-family projection as the catalog): order of first appearance in the directory, with Other at the bottom and its group name localized.
        assertEquals(listOf("anthropic", "openai", "google", "deepseek", "other"), board.groups.map { it.id })
        assertEquals(listOf("Anthropic", "OpenAI", "Google", "DeepSeek"), board.groups.dropLast(1).map { it.title })
        assertEquals(ai.oriveo.community.R.string.relay_catalog_group_other, board.groups.last().titleRes)
        assertEquals(CATALOG_A.size, board.totalModels)
        // Groups are collapsed by default: the group header shows a count, rows are not expanded.
        assertTrue(board.groups.none { it.expanded })
        assertTrue(board.groups.all { it.rows.isEmpty() })
        assertEquals(3, board.groups.single { it.title == "Anthropic" }.modelCount)
        assertFalse(board.isSaveEnabled)

        // Groups containing checked rows are expanded and show all rows; rows carry candidate protocol chips.
        vm.toggleModel("gpt-6-sol")
        val openAI = vm.modelsBoard.groups.single { it.title == "OpenAI" }
        assertTrue(openAI.expanded)
        assertEquals(listOf("gpt-5.6-sol", "gpt-6-sol").toSet(), openAI.rows.map { it.id }.toSet())
        assertEquals(1, openAI.selectedCount)
        assertTrue(openAI.rows.all { it.protocol == RelayBoardProtocol.Chat })
        assertTrue(vm.modelsBoard.groups.filter { it.title != "OpenAI" }.none { it.expanded })

        // Search: groups with hits expand and list only the matching rows; Select all in group selects the whole group (not just the matching rows).
        vm.updateSearch("sonnet")
        val searching = vm.modelsBoard
        assertEquals(listOf("Anthropic"), searching.groups.map { it.title })
        val anthropic = searching.groups.single()
        assertTrue(anthropic.expanded)
        assertEquals(listOf("claude-sonnet-4.5"), anthropic.rows.map { it.id })
        assertTrue(anthropic.canSelectAll)
        vm.selectGroup(anthropic.id)
        assertFalse(vm.modelsBoard.groups.single().canSelectAll)
        vm.updateSearch("")
        val selectedAnthropic = vm.modelsBoard.groups.single { it.title == "Anthropic" }
        assertEquals(3, selectedAnthropic.selectedCount)
        assertEquals(4, vm.modelsBoard.selectedCount)

        // A group the user collapsed manually stays collapsed (even if it has selected rows).
        vm.toggleGroup(selectedAnthropic.id)
        assertFalse(vm.modelsBoard.groups.single { it.title == "Anthropic" }.expanded)
        vm.toggleGroup(selectedAnthropic.id)
        assertTrue(vm.modelsBoard.groups.single { it.title == "Anthropic" }.expanded)

        // Step 1 sends zero 1-token requests.
        assertEquals(0, harness.posts.size)
    }

    @Test
    fun `RL2-HOST-01 step 2 subtitle host is the relay domain`() = runBlocking {
        val harness = Harness(catalogs = mapOf(KEY_A to CATALOG_A))
        val vm = harness.viewModel()
        vm.next()
        settle(vm)

        assertEquals(RelaySetupStep.Models, vm.step)
        // Endpoint https://relay.example.com: with more than two labels take the last two (same as the relay domain name).
        assertEquals("example.com", vm.modelsBoard.host)
        assertEquals(ProviderRepository.relayDomainNameFromEndpoint("https://relay.example.com"), vm.modelsBoard.host)
        assertEquals("localhost", ProviderRepository.relayDomainNameFromEndpoint("http://localhost:8080/v1"))
        assertEquals("10.0.0.12", ProviderRepository.relayDomainNameFromEndpoint("http://10.0.0.12:3000"))
    }

    @Test
    fun `BOARD-SETUPMODELS-02 key chips only with two or more keys and they are the bound key`() = runBlocking {
        // Only one key: no key chip.
        val single = Harness(catalogs = mapOf(KEY_A to CATALOG_A))
        val one = single.viewModel()
        one.next()
        settle(one)
        one.toggleModel("claude-sonnet-4.5")
        assertTrue(one.modelsBoard.groups.flatMap { it.rows }.all { it.keyChip == null })
        assertEquals(1, one.modelsBoard.keyCount)

        // Two keys: the primary key lists Claude etc., the second lists GPT.
        val harness = Harness(catalogs = mapOf(KEY_A to CATALOG_A.filterNot { it.startsWith("gpt") }, KEY_B to listOf("gpt-6-sol", "gpt-5.6-sol")))
        val vm = harness.viewModel()
        vm.addKey()
        val second = vm.board.keys[1].id
        vm.updateKeySecret(second, KEY_B)
        vm.updateKeyName(second, "OpenAI group")
        vm.next()
        settle(vm)

        // Step 1 fetch-catalog shows one row per key: name (mask when unnamed) + model count.
        val lines = requireNotNull(vm.board.detection).keyLines
        assertEquals(listOf(SecureKeyStore.maskApiKey(KEY_A), "OpenAI group"), lines.map { it.label })
        assertEquals(listOf(CATALOG_A.size - 2, 2), lines.map { it.modelCount })

        assertEquals(RelaySetupStep.Models, vm.step)
        assertEquals(2, vm.modelsBoard.keyCount)
        vm.toggleModel("gpt-6-sol")
        vm.toggleModel("claude-opus-4.1")
        val rows = vm.modelsBoard.groups.flatMap { it.rows }
        // Chips appear only on checked rows; value = the result of the key bind.
        assertEquals("OpenAI group", rows.single { it.id == "gpt-6-sol" }.keyChip)
        assertEquals(SecureKeyStore.maskApiKey(KEY_A), rows.single { it.id == "claude-opus-4.1" }.keyChip)
        assertTrue(rows.filterNot { it.selected }.all { it.keyChip == null })

        vm.save()
        settle(vm)
        val stored = harness.current()
        assertEquals(listOf(RelayKeyBinding.IMPLICIT_KEY_ID, second), RelayKeyBinding.keyIDs(stored))
        assertEquals("OpenAI group", stored.relayKeys?.get(1)?.name)
        assertEquals(KEY_B, harness.secrets[second])
        assertEquals(second, RelayKeyBinding.effectiveKeyID(stored, "gpt-6-sol"))
        assertEquals(RelayKeyBinding.IMPLICIT_KEY_ID, RelayKeyBinding.effectiveKeyID(stored, "claude-opus-4.1"))
        // Verification uses the key bound to the first checked model (display order: the Anthropic group comes before the OpenAI group).
        assertEquals(listOf("Bearer $KEY_A"), harness.posts.map { it.second })
    }

    @Test
    fun `BOARD-SETUPMODELS-03 save verifies only the first selected with one request, enables all and lands on detail`() = runBlocking {
        val harness = Harness(catalogs = mapOf(KEY_A to CATALOG_A))
        val vm = harness.viewModel()
        vm.next()
        settle(vm)
        val stepTwoGroups = vm.modelsBoard.groups.map { it.id to it.title }

        // Click order differs from display order: the first checked model is the first in display order.
        vm.toggleModel("gpt-6-sol")
        vm.toggleModel("deepseek-chat")
        vm.toggleModel("claude-sonnet-4.5")
        assertEquals("claude-sonnet-4.5", vm.modelsBoard.firstSelected)
        assertEquals(3, vm.modelsBoard.selectedCount)
        assertTrue(vm.modelsBoard.isSaveEnabled)

        vm.save()
        settle(vm)

        // Only 1 generation request, model = the first checked in display order.
        assertEquals(listOf("claude-sonnet-4.5"), harness.posts.map { it.first })
        val stored = harness.current()
        assertEquals(ProviderConnectionState.Connected, stored.status)
        assertEquals(setOf("gpt-6-sol", "deepseek-chat", "claude-sonnet-4.5"), stored.models.map { it.id }.toSet())
        // The first model gets the probe result, the others are not probed.
        assertNotNull(stored.models.single { it.id == "claude-sonnet-4.5" }.relayTransport)
        assertTrue(stored.models.filter { it.id != "claude-sonnet-4.5" }.all { it.relayTransport == null })
        // Directory rows carry their group at registration, matching the catalog's group projection verbatim.
        assertEquals("Anthropic", stored.catalogModels.single { it.id == "claude-haiku-4.5" }.groupName)
        val library = buildProviderCatalogGroups(stored.copy(models = emptyList()), searchQuery = "")
        assertEquals(stepTwoGroups, library.map { it.id to it.title })

        val target = vm.completionTarget as RelaySetupCompletionTarget.ProviderDetail
        assertEquals(stored.id, target.providerId)
        assertEquals(3, target.addedModelCount)
        // One-shot notice: appears only at the providers entry and is cleared once taken.
        target.postAddedNotice(ProviderSetupEntryPoint.Onboarding)
        assertNull(ProviderDetailNotice.take(stored.id))
        target.postAddedNotice(ProviderSetupEntryPoint.Providers)
        assertNull("The added notice has no reason line", ProviderDetailNotice.takeUnverified(stored.id))
        assertEquals(3, ProviderDetailNotice.take(stored.id))
        assertNull(ProviderDetailNotice.take(stored.id))
    }

    @Test
    fun `BOARD-SETUPMODELS-04 catalog failure leads to manual add and zero selected cannot save`() = runBlocking {
        val harness = Harness(catalogs = emptyMap(), catalogStatus = HttpStatusCode.Forbidden)
        val vm = harness.viewModel()
        vm.next()
        settle(vm)

        assertEquals(RelaySetupStep.Address, vm.step)
        val detection = requireNotNull(vm.board.detection)
        assertEquals(RelayCheckState.Failed, detection.rows[0].state)
        assertEquals(RelaySetupFailureKind.Permission, detection.rows[0].failure)
        // Under the one-line failure, keep the requests that were tried.
        assertTrue(detection.attempts.isNotEmpty())

        vm.next()
        assertEquals(RelaySetupStep.Models, vm.step)
        assertTrue(vm.modelsBoard.isCatalogEmpty)
        assertFalse(vm.modelsBoard.isSaveEnabled)
        vm.save()
        assertEquals(0, harness.posts.size)

        vm.addManualModel("  my-model  ")
        assertEquals(1, vm.modelsBoard.selectedCount)
        assertEquals("my-model", vm.modelsBoard.firstSelected)
        assertTrue(vm.modelsBoard.isSaveEnabled)
        vm.save()
        settle(vm)
        assertEquals(listOf("my-model"), harness.posts.map { it.first })
        assertEquals(listOf("my-model"), harness.current().models.map { it.id })
    }

    @Test
    fun `BOARD-SETUPMODELS-05 failed verification does not persist and the error stays visible on step 2`() = runBlocking {
        val harness = Harness(catalogs = mapOf(KEY_A to CATALOG_A), postStatus = HttpStatusCode.Unauthorized)
        val vm = harness.viewModel()
        vm.next()
        settle(vm)
        vm.toggleModel("claude-sonnet-4.5")
        vm.toggleModel("gpt-6-sol")
        vm.save()
        settle(vm)

        assertTrue(harness.posts.isNotEmpty())
        assertTrue(harness.posts.all { it.first == "claude-sonnet-4.5" })
        assertNull("Failed verification is not persisted", harness.stored)
        assertNull(vm.completionTarget)
        assertEquals(RelaySetupStep.Models, vm.step)
        assertNotNull(vm.modelsBoard.saveFailure)
        // Selection is kept so the user can retry.
        assertEquals(2, vm.modelsBoard.selectedCount)
        assertTrue(vm.modelsBoard.isSaveEnabled)
    }

    // ── Step 2 manually add model IDs──

    private suspend fun stepTwo(catalog: List<String>): Pair<Harness, RelaySetupViewModel> {
        val harness = Harness(catalogs = mapOf(KEY_A to catalog))
        val vm = harness.viewModel()
        vm.next()
        settle(vm)
        assertEquals(RelaySetupStep.Models, vm.step)
        return harness to vm
    }

    private fun RelaySetupViewModel.selectedIDs(): Set<String> =
        catalogRowsForTest().filter { it.second }.map { it.first }.toSet()

    /** (row id, checked) after expanding all groups. */
    private fun RelaySetupViewModel.catalogRowsForTest(): List<Pair<String, Boolean>> {
        modelsBoard.groups.filterNot { it.expanded }.forEach { toggleGroup(it.id) }
        return modelsBoard.groups.flatMap { g -> g.rows.map { it.id to it.selected } }
    }

    @Test
    fun `BOARD-SETUPMODELS-06 empty or blank input is ignored and add is unavailable`() = runBlocking {
        val (_, vm) = stepTwo(CATALOG_A)
        assertFalse(relayManualModelAddable(""))
        assertFalse(relayManualModelAddable("   "))
        assertTrue(relayManualModelAddable(" x "))
        assertEquals(RelayManualModelAddResult.Ignored, vm.addManualModel("   "))
        assertEquals(0, vm.modelsBoard.selectedCount)
        assertEquals(CATALOG_A.size, vm.modelsBoard.totalModels)
        assertFalse(vm.modelsBoard.manualAddNotice)
    }

    @Test
    fun `BOARD-SETUPMODELS-07 a catalog duplicate is selected with a notice that clears on the next action`() = runBlocking {
        val (_, vm) = stepTwo(CATALOG_A)
        assertEquals(RelayManualModelAddResult.AlreadyListed, vm.addManualModel("  gpt-6-sol "))
        assertEquals(CATALOG_A.size, vm.modelsBoard.totalModels)
        assertEquals(setOf("gpt-6-sol"), vm.selectedIDs())
        assertTrue(vm.modelsBoard.manualAddNotice)

        vm.toggleModel("claude-opus-4.1")
        assertFalse("Disappears after toggling a checkbox", vm.modelsBoard.manualAddNotice)
        vm.addManualModel("gpt-6-sol")
        vm.selectGroup("anthropic")
        assertFalse("Disappears after selecting the whole group", vm.modelsBoard.manualAddNotice)
        vm.addManualModel("gpt-6-sol")
        vm.beginManualModelEntry()
        assertFalse("Disappears after reopening add", vm.modelsBoard.manualAddNotice)
        vm.addManualModel("gpt-6-sol")
        assertEquals(RelayManualModelAddResult.Added, vm.addManualModel("brand-new"))
        assertFalse("Disappears after a successful add", vm.modelsBoard.manualAddNotice)
    }

    @Test
    fun `BOARD-SETUPMODELS-08 a manual duplicate is reselected without growing the list`() = runBlocking {
        val (_, vm) = stepTwo(CATALOG_A)
        assertEquals(RelayManualModelAddResult.Added, vm.addManualModel("my-model"))
        vm.toggleModel("my-model")
        val total = vm.modelsBoard.totalModels
        assertEquals(RelayManualModelAddResult.AlreadyListed, vm.addManualModel(" my-model"))
        assertEquals(total, vm.modelsBoard.totalModels)
        assertTrue("my-model" in vm.selectedIDs())
        assertTrue(vm.modelsBoard.manualAddNotice)
    }

    @Test
    fun `BOARD-SETUPMODELS-09 a case-only difference is the same model and saves the listed spelling`() = runBlocking {
        val (harness, vm) = stepTwo(CATALOG_A)
        assertEquals(RelayManualModelAddResult.AlreadyListed, vm.addManualModel("GPT-6-SOL"))
        assertEquals(setOf("gpt-6-sol"), vm.selectedIDs())
        assertEquals(CATALOG_A.size, vm.modelsBoard.totalModels)
        vm.save()
        settle(vm)
        val stored = harness.current()
        assertEquals(listOf("gpt-6-sol"), stored.models.map { it.id })
        assertEquals(stored.models.size, (vm.completionTarget as RelaySetupCompletionTarget.ProviderDetail).addedModelCount)
    }

    @Test
    fun `BOARD-SETUPMODELS-10 a date snapshot suffix is another model and both are saved`() = runBlocking {
        val (harness, vm) = stepTwo(listOf("gpt-4o", "claude-sonnet-4.5"))
        assertEquals(RelayManualModelAddResult.Added, vm.addManualModel("gpt-4o-2024-08-06"))
        assertTrue("gpt-4o-2024-08-06" in vm.catalogRowsForTest().map { it.first })
        assertEquals(RelayManualModelAddResult.AlreadyListed, vm.addManualModel("GPT-4o-2024-08-06"))
        assertEquals(setOf("gpt-4o-2024-08-06"), vm.selectedIDs())
        vm.toggleModel("gpt-4o")
        assertEquals(2, vm.modelsBoard.selectedCount)
        vm.save()
        settle(vm)
        val stored = harness.current()
        assertEquals(setOf("gpt-4o", "gpt-4o-2024-08-06"), stored.models.map { it.id }.toSet())
        assertEquals(2, (vm.completionTarget as RelaySetupCompletionTarget.ProviderDetail).addedModelCount)
        assertEquals("Only the 1 generation request for the verification sample is sent", 1, harness.posts.size)

        // Reverse: when the directory has only dated IDs, adding an undated one is also a new addition.
        val (reverseHarness, reverse) = stepTwo(listOf("gpt-4o-2024-08-06"))
        assertEquals(RelayManualModelAddResult.Added, reverse.addManualModel("gpt-4o"))
        reverse.toggleModel("gpt-4o-2024-08-06")
        reverse.save()
        settle(reverse)
        assertEquals(setOf("gpt-4o", "gpt-4o-2024-08-06"), reverseHarness.current().models.map { it.id }.toSet())
    }

    @Test
    fun `BOARD-SETUPMODELS-11 the saved notice reports the actually enabled count`() = runBlocking {
        // Both platforms build the same case from two directory IDs that differ only in case, both checked; IDs differing only in case count as the same one.
        val (harness, vm) = stepTwo(listOf("GPT-X", "gpt-x"))
        vm.catalogRowsForTest().forEach { (id, selected) -> if (!selected) vm.toggleModel(id) }
        vm.save()
        settle(vm)
        val stored = harness.current()
        assertEquals(1, stored.models.size)
        assertEquals(1, (vm.completionTarget as RelaySetupCompletionTarget.ProviderDetail).addedModelCount)
    }

    @Test
    fun `BOARD-SETUPMODELS-12 two different date snapshots are two models`() = runBlocking {
        val (harness, vm) = stepTwo(listOf("claude-3-5-sonnet-20240620"))
        assertEquals(RelayManualModelAddResult.Added, vm.addManualModel("claude-3-5-sonnet-20241022"))
        vm.toggleModel("claude-3-5-sonnet-20240620")
        assertEquals(2, vm.modelsBoard.selectedCount)
        vm.save()
        settle(vm)
        assertEquals(
            setOf("claude-3-5-sonnet-20240620", "claude-3-5-sonnet-20241022"),
            harness.current().models.map { it.id }.toSet(),
        )
    }

    // ── BOARD-SETUPMODELS-13──

    @Test
    fun `BOARD-SETUPMODELS-13 manual model entry opens an alert dialog and an empty draft cannot be added`() = runBlocking {
        val entry = java.io.File("src/main/java/ai/oriveo/community/feature/providers/relay/RelaySetupScreen.kt").readText()
            .substringAfter("private fun RelayManualModelEntry(").substringBefore("\n}\n")
        // Dialog host: same title string, single-line input with the flagship-model placeholder, no auto-capitalization or autocorrect, Cancel / Add (disabled when trimmed text is empty).
        assertTrue(entry, entry.contains("AlertDialog("))
        assertTrue(entry, entry.contains("OutlinedTextField("))
        assertTrue(entry, entry.contains("singleLine = true"))
        assertTrue(entry, entry.contains("RelayFlagshipModel.current()"))
        assertTrue(entry, entry.contains("KeyboardCapitalization.None"))
        assertTrue(entry, entry.contains("autoCorrectEnabled = false"))
        assertTrue(entry, entry.contains("R.string.cancel"))
        assertTrue(entry, entry.contains("R.string.add"))
        assertTrue(entry, entry.contains("enabled = relayManualModelAddable("))
        assertTrue(entry, entry.contains("onBegin()"))
        assertTrue(entry, entry.contains("R.string.relay_setup_models_already_listed"))
        // The inline input is removed.
        assertFalse(entry, entry.contains("RelayQuickField("))
        // Disabling on empty input uses the production predicate; Add goes through production addManualModel.
        assertFalse(relayManualModelAddable(""))
        assertFalse(relayManualModelAddable("   "))
        assertTrue(relayManualModelAddable(" m-new "))
        val (_, vm) = stepTwo(listOf("m1"))
        val before = vm.modelsBoard.totalModels
        assertEquals(RelayManualModelAddResult.Ignored, vm.addManualModel("  "))
        assertEquals(before, vm.modelsBoard.totalModels)
        assertEquals(RelayManualModelAddResult.Added, vm.addManualModel(" m-new "))
        assertEquals(before + 1, vm.modelsBoard.totalModels)
    }

    // ── harness ──

    private suspend fun settle(vm: RelaySetupViewModel) = withTimeout(10_000) {
        delay(5)
        while (vm.isDiscovering || vm.isSubmitting) delay(5)
    }

    private inner class Harness(
        private val catalogs: Map<String, List<String>>,
        private val catalogStatus: HttpStatusCode = HttpStatusCode.OK,
        private val postStatus: HttpStatusCode = HttpStatusCode.OK,
    ) {
        var apiKey = ""
        val secrets: MutableMap<String, String> = mutableMapOf()
        var stored: ProviderEntity? = null
        /** Each generation request: (model, Authorization). */
        val posts: MutableList<Pair<String, String?>> = Collections.synchronizedList(mutableListOf())

        private val engine = MockEngine { request ->
            val auth = request.headers[HttpHeaders.Authorization]
            if (request.method == HttpMethod.Get) {
                if (request.url.encodedPath != "/v1/models") return@MockEngine respond("", HttpStatusCode.NotFound)
                if (catalogStatus != HttpStatusCode.OK) return@MockEngine respond("{}", catalogStatus)
                val ids = catalogs[auth?.removePrefix("Bearer ")]
                    ?: return@MockEngine respond("{\"error\":\"Invalid API key\"}", HttpStatusCode.Unauthorized)
                return@MockEngine respond(
                    "{\"object\":\"list\",\"data\":[" + ids.joinToString(",") { "{\"id\":\"$it\",\"object\":\"model\"}" } + "]}",
                    HttpStatusCode.OK,
                    headersOf(HttpHeaders.ContentType, ContentType.Application.Json.toString()),
                )
            }
            val model = runCatching {
                json.parseToJsonElement((request.body as TextContent).text).jsonObject["model"]?.jsonPrimitive?.content
            }.getOrNull().orEmpty()
            posts += model to auth
            respond(
                if (postStatus == HttpStatusCode.OK) "{\"id\":\"x\",\"choices\":[{\"message\":{\"content\":\"p\"}}]}" else "{\"error\":\"Invalid API key\"}",
                postStatus,
                headersOf(HttpHeaders.ContentType, ContentType.Application.Json.toString()),
            )
        }

        val repository: ProviderRepository = run {
            val dao = mockk<ai.oriveo.community.core.data.dao.ProviderDao>()
            coEvery { dao.getById(any(), any()) } coAnswers {
                stored?.takeIf { it.accountId == firstArg<String>() && it.id == secondArg<String>() }
            }
            coEvery { dao.upsert(any()) } coAnswers { stored = firstArg() }
            coEvery { dao.getAll(any()) } coAnswers { listOfNotNull(stored) }
            val keys = mockk<SecureKeyStore>(relaxed = true)
            every { keys.getApiKey(any(), any()) } answers { apiKey }
            every { keys.saveApiKey(any(), any(), any()) } answers { apiKey = thirdArg() }
            every { keys.getRelayKeySecret(any(), any(), any()) } answers { secrets[thirdArg()] }
            every { keys.saveRelayKeySecrets(any(), any(), any()) } answers {
                thirdArg<List<RelayKey>?>().orEmpty().drop(1).filter { it.apiKey.isNotEmpty() }.forEach { secrets[it.id] = it.apiKey }
            }
            ProviderRepository(
                dao = dao,
                conversationDao = mockk(relaxed = true),
                secureKeyStore = keys,
                openRouterService = mockk(relaxed = true),
                openAIService = mockk(relaxed = true),
                deepSeekService = mockk(relaxed = true),
                grokService = mockk(relaxed = true),
                anthropicService = mockk(relaxed = true),
                geminiService = mockk(relaxed = true),
                groqService = mockk(relaxed = true),
                togetherService = mockk(relaxed = true),
                fireworksService = mockk(relaxed = true),
                miniMaxService = mockk(relaxed = true),
                zhipuService = mockk(relaxed = true),
                qwenService = mockk(relaxed = true),
                moonshotService = mockk(relaxed = true),
                mistralService = mockk(relaxed = true),
                siliconFlowService = mockk(relaxed = true),
                relayService = RelayService(client = HttpClient(engine), json = json, transportRegistry = TransportRegistry(json)),
                metadataRefreshEventBus = MetadataRefreshEventBus(debounceMillis = 0),
                httpClient = HttpClient(MockEngine { respond("", HttpStatusCode.NotFound) }),
                relayModelFamily = { null },
            )
        }

        fun viewModel(): RelaySetupViewModel {
            val context = mockk<Context>()
            every { context.getString(any()) } answers { "string-${firstArg<Int>()}" }
            every { context.getString(any(), *anyVararg()) } answers { "string-${firstArg<Int>()}" }
            return RelaySetupViewModel(
                context = context,
                providerRepository = repository,
                discoveryService = RelayDiscoveryService(HttpClient(engine), json, retryBackoffMs = emptyList()),
                modelFamily = { null },
                cachedModelFamily = { null },
            ).apply {
                updateEndpoint("https://relay.example.com")
                updateApiKey(KEY_A)
            }
        }

        fun current(): Provider = with(ProviderMapper) { requireNotNull(stored).toDomain(apiKey) { secrets[it] } }
    }

    private companion object {
        const val ACCOUNT = "acct-setup-models"
        const val KEY_A = "sk-aaaa-0000000000001111"
        const val KEY_B = "sk-bbbb-0000000000002222"
        val CATALOG_A = listOf(
            "claude-sonnet-4.5",
            "claude-opus-4.1",
            "claude-haiku-4.5",
            "gpt-6-sol",
            "gpt-5.6-sol",
            "gemini-2.5-pro",
            "deepseek-chat",
            "custom-x",
        )
    }
}
