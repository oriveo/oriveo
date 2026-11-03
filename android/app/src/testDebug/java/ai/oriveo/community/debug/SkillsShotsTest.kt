package ai.oriveo.community.debug

import android.app.Application
import ai.oriveo.community.core.auth.AccountSessionManager
import ai.oriveo.community.core.data.dao.MessageDao
import ai.oriveo.community.core.data.repository.ConversationRepository
import ai.oriveo.community.core.data.repository.NoteRepository
import ai.oriveo.community.core.data.repository.SkillCatalogPrefsStore
import ai.oriveo.community.core.data.repository.SkillRepository
import ai.oriveo.community.core.data.repository.streaming.failedMessageDetail
import ai.oriveo.community.core.model.ChatMessageState
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.core.model.ProviderServiceError
import ai.oriveo.community.core.model.Skill
import ai.oriveo.community.core.model.SkillSource
import ai.oriveo.community.core.provider.CostSource
import ai.oriveo.community.core.skills.SkillDraft
import ai.oriveo.community.core.skills.SkillImprove
import ai.oriveo.community.core.skills.SkillRuntime
import ai.oriveo.community.core.skills.SkillTrial
import ai.oriveo.community.core.skills.SkillValidation
import ai.oriveo.community.core.usage.UsageTrendsGranularity
import ai.oriveo.community.core.skills.SkillsAutoInvokePreference
import ai.oriveo.community.feature.chat.components.SkillImprovePrompt
import ai.oriveo.community.feature.chat.composer.SkillComposerChipsModel
import ai.oriveo.community.feature.chat.composer.SkillComposerTrigger
import ai.oriveo.community.feature.chat.composer.SkillPickerCache
import ai.oriveo.community.feature.skills.SkillDraftFlowModel
import ai.oriveo.community.feature.skills.SkillsTemplatesModel
import ai.oriveo.community.ui.theme.DarkPaletteChoice
import java.io.File
import java.time.LocalDate
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment

/** Skills shot family entry: page table = shared manifest, fixture skills through the production decoder, every Android page opens. */
@RunWith(RobolectricTestRunner::class)
class SkillsShotsTest {

    private val text = manifestText()
    private val raw = Json.parseToJsonElement(text).jsonObject
    private val manifest = SkillsShotsManifest.parse(text).getOrThrow()

    @After
    fun tearDown() {
        RelayFamilyShotsRuntime.stop()
    }

    @Test
    fun `page table is exactly the shared manifest page names`() {
        val expected = raw.getValue("pages").jsonArray.map { it.jsonObject.getValue("name").jsonPrimitive.content }
        assertEquals(42, expected.size)
        assertEquals(expected, SkillsShotPage.entries.map { it.wire })
        assertEquals(expected, manifest.pages.map { it.name })
        expected.forEach { assertEquals(it, SkillsShotPage.parse(" $it ")?.wire) }
        assertNull(SkillsShotPage.parse("SkillsHome"))
        assertNull(SkillsShotPage.parse(null))
        // Page names never overlap with the other families routed through the same entry.
        SkillsShotPage.entries.forEach { page ->
            assertNull(RelayFamilyShotPage.parse(page.wire))
            assertNull(MemoryShotPage.parse(page.wire))
            assertNull(ContextShotPage.parse(page.wire))
            assertNull(WebSearchShotPage.parse(page.wire))
            assertNull(VoiceShotPage.parse(page.wire))
        }
    }

    @Test
    fun `fixture skills and templates decode through the production decoder field for field`() {
        val skills = raw.getValue("skills").jsonArray.map { it.jsonObject }
        assertEquals(skills.map { it.string("id") }, manifest.skills.map { it.id })
        skills.zip(manifest.skills).forEach { (json, skill) -> assertFields(json, skill) }
        assertTrue(manifest.skills.all { it.source == SkillSource.USER })

        val templates = raw.getValue("templates").jsonArray.map { it.jsonObject }
        assertEquals(templates.map { it.string("id") }, manifest.templates.map { it.id })
        templates.zip(manifest.templates).forEach { (json, skill) -> assertFields(json, skill) }
        assertTrue(manifest.templates.all { it.isBuiltIn })

        // Omitted fields take the decoder defaults.
        val neverUsed = manifest.skills.single { it.name == "Code review" }
        assertNull(neverUsed.lastUsedAt)
        assertTrue(manifest.templates.single { it.key == "math_tutor" }.previewUser.isEmpty())

        val usage = raw.getValue("usage").jsonObject
        assertEquals(usage.getValue("count").jsonPrimitive.intOrNull, manifest.usage.count)
        assertNull(manifest.usage.limit)
        assertEquals(usage.getValue("isPro").jsonPrimitive.booleanOrNull, manifest.usage.isPro)

        val conversation = SkillsShotsData.conversation(manifest)
        assertEquals(listOf(manifest.skills.first().id), conversation.skillIds)
        val reply = conversation.messages.last()
        assertEquals(listOf("manual", "auto"), reply.usedSkills.map { it.via })
        assertEquals(listOf(manifest.skills[1].id), SkillsShots.userAttachedIds(conversation, reply.id))
        assertEquals(reply.id, SkillsShotsData.expandedReplyId(conversation, checkNotNull(manifest.page(SkillsShotPage.SkillsUsed))))
        assertNull(SkillsShotsData.expandedReplyId(conversation, checkNotNull(manifest.page(SkillsShotPage.SkillsComposer))))
    }

    @Test
    fun `every page listed for android has an entry`() {
        val android = manifest.pages.filter { SkillsShotsManifest.END in it.ends }
        assertEquals(manifest.pages, android)
        android.forEach { entry ->
            val page = checkNotNull(SkillsShotPage.parse(entry.name)) { "no entry for ${entry.name}" }
            assertNull(SkillsShots.refusal(page, Result.success(manifest)))
            val palette = SkillsShotsData.palette(entry)
            if (entry.themeSeed == null) {
                assertEquals(DarkPaletteChoice.Default, palette)
            } else {
                assertEquals(entry.themeSeed?.substring(1)?.toInt(16), (palette as DarkPaletteChoice.Custom).seed)
            }
        }
        assertNotNull(SkillsShots.refusal(SkillsShotPage.SkillsHome, Result.failure(IllegalStateException("broken"))))
        assertNotNull(SkillsShots.refusal(SkillsShotPage.SkillsHome, Result.success(manifest.copy(pages = emptyList()))))
        val webOnly = manifest.pages.map { if (it.name == "skillsMine") it.copy(ends = listOf("web")) else it }
        assertNotNull(SkillsShots.refusal(SkillsShotPage.SkillsMine, Result.success(manifest.copy(pages = webOnly))))
        val badSeed = manifest.pages.map { if (it.name == "skillsMineAmber") it.copy(themeSeed = "amber") else it }
        assertNotNull(SkillsShots.refusal(SkillsShotPage.SkillsMineAmber, Result.success(manifest.copy(pages = badSeed))))
    }

    @Test
    fun `composer preset opens the production picker on we`() {
        val composer = checkNotNull(manifest.page(SkillsShotPage.SkillsComposer))
        val typed = SkillsShots.composerText(composer)
        val trigger = checkNotNull(SkillComposerTrigger.detect(typed, typed.length))
        assertEquals(SkillsShotsData.COMPOSER_QUERY, trigger.query)
        val content = checkNotNull(SkillComposerChipsModel.pickerContent(SkillPickerCache(manifest.skills, manifest.templates), trigger.query))
        assertEquals(listOf("Weekly report", "Weekend workout plan"), content.mine.map { it.name })
        assertEquals("", SkillsShots.composerText(checkNotNull(manifest.page(SkillsShotPage.SkillsUsed))))
        val conversation = SkillsShotsData.conversation(manifest)
        assertEquals(conversation.skillIds, SkillsShots.composerSkillIds(manifest, conversation, composer))

        val full = checkNotNull(manifest.page(SkillsShotPage.SkillsComposerFull))
        assertEquals(SkillsShotsManifest.Subject.Composer, full.subject)
        assertEquals(SkillsShotsManifest.State.Full, full.state)
        assertEquals("/we", SkillsShots.composerText(full))
        val fullIds = SkillsShots.composerSkillIds(manifest, conversation, full)
        assertEquals(3, fullIds.size)
        val chips = SkillComposerChipsModel(
            scope = CoroutineScope(Dispatchers.Unconfined),
            userSkills = flowOf(manifest.skills),
            templates = flowOf(manifest.templates),
            writeSkillIds = { _, _ -> null },
            track = { _, _ -> },
        )
        // An open conversation shows the ids the composer is given (no pending local write).
        val shown = chips.chips(conversation.id, fullIds, SkillPickerCache(manifest.skills, manifest.templates))
        assertEquals(manifest.skills.take(3).map { it.name }, shown.map { it.skill?.name })
    }

    @Test
    fun templates_page_seeds_categories() = runBlocking {
        val app = RuntimeEnvironment.getApplication() as Application
        RelayFamilyShotsRuntime.start(app, interceptUrlConnections = false)
        val koin = RelayFamilyShotsRuntime.koin()

        SkillsShotsData.seed(koin, manifest, manifest.page(SkillsShotPage.SkillsTemplates))
        val skills = koin.get<SkillRepository>()
        val templates = skills.observeCatalogSkills().first()
        val chips = SkillsTemplatesModel.categoryChips(templates, skills.categories.value)
        assertEquals(listOf("work", "life", "learning"), chips.map { it.id })
        assertEquals(listOf("Work", "Life", "Learning"), chips.map { it.name })
        assertEquals(chips, koin.get<SkillCatalogPrefsStore>().load().categories)
    }

    @Test
    fun `seeded skills and conversation read back through production repositories in memory only`() = runBlocking {
        val app = RuntimeEnvironment.getApplication() as Application
        val realDatabase = app.getDatabasePath("oriveo.db")
        RelayFamilyShotsRuntime.start(app, interceptUrlConnections = false)
        val koin = RelayFamilyShotsRuntime.koin()

        SkillsShotsData.seed(koin, manifest)
        val shown = SkillsShotsData.seed(koin, manifest)
        val skills = koin.get<SkillRepository>()
        assertEquals(manifest.skills.map { it.id }.toSet(), skills.observeUserSkills().first().map { it.id }.toSet())
        assertEquals(manifest.templates.map { it.id }.toSet(), skills.observeCatalogSkills().first().map { it.id }.toSet())
        val stored = checkNotNull(skills.getById(manifest.skills.first().id))
        assertEquals(manifest.skills.first().starterMessages, stored.starterMessages)
        assertEquals(manifest.skills.first().whenToUse, stored.whenToUse)
        assertEquals(manifest.skills.first().autoInvoke, stored.autoInvoke)
        assertEquals(manifest.skills.first().lastUsedAt, stored.lastUsedAt)

        val conversations = koin.get<ConversationRepository>()
        val conversation = SkillsShotsData.conversation(manifest)
        val all = conversations.observeAll().first()
        // The production repository normalises UUIDs (upper case); seeding twice leaves one row per conversation.
        assertEquals(manifest.conversations.map { it.id.uppercase() }.sorted(), all.map { it.id.uppercase() }.sorted())
        val first = all.single { it.id.equals(conversation.id, ignoreCase = true) }
        assertEquals(conversation.skillIds.map { it.uppercase() }, first.skillIds.map { it.uppercase() })
        val loaded = shown
        assertEquals(first.id, loaded.id)
        assertEquals(loaded.messages.last().id, SkillsShotsData.expandedReplyId(loaded, checkNotNull(manifest.page(SkillsShotPage.SkillsUsed))))
        assertEquals(conversation.messages.map { it.text }, loaded.messages.map { it.text })
        assertEquals(
            conversation.messages.last().usedSkills.map { it.copy(id = it.id.uppercase()) },
            loaded.messages.last().usedSkills.map { it.copy(id = it.id.uppercase()) },
        )
        assertEquals(
            conversation.messages.first().attachedSkillIds.map { it.uppercase() },
            loaded.messages.first().attachedSkillIds.map { it.uppercase() },
        )
        assertFalse("real database must not be created", realDatabase.exists())
    }

    @Test
    fun `home presets and notes decode from the manifest`() {
        val notes = raw.getValue("notes").jsonArray.map { it.jsonObject }
        assertEquals(3, manifest.notes.size)
        assertEquals(notes.map { it.string("title") }, manifest.notes.map { it.title })
        assertEquals(notes.map { it.string("content") }, manifest.notes.map { it.body })
        assertEquals(notes.map { it.string("id")?.uppercase() }, manifest.notes.map { it.id })

        val empty = checkNotNull(manifest.page(SkillsShotPage.SkillsHomeEmpty))
        assertEquals(SkillsShotsManifest.Subject.Home, empty.subject)
        assertTrue(empty.emptyData)
        assertTrue(empty.autoInvoke)
        val autoOff = checkNotNull(manifest.page(SkillsShotPage.SkillsHomeAutoOff))
        assertEquals(SkillsShotsManifest.Subject.Home, autoOff.subject)
        assertFalse(autoOff.emptyData)
        assertFalse(autoOff.autoInvoke)
        val home = checkNotNull(manifest.page(SkillsShotPage.SkillsHome))
        assertFalse(home.emptyData)
        assertTrue(home.autoInvoke)

        assertTrue(SkillsShotsManifest.parse(text.replace("\"data\": \"empty\"", "\"data\": \"full\"")).isFailure)
        assertTrue(SkillsShotsManifest.parse(text.replace("\"autoInvoke\": false,", "\"autoInvoke\": \"no\",")).isFailure)
    }

    @Test
    fun `home pages seed notes skills and the auto invoke switch per page`() = runBlocking {
        val app = RuntimeEnvironment.getApplication() as Application
        val realDatabase = app.getDatabasePath("oriveo.db")
        RelayFamilyShotsRuntime.start(app, interceptUrlConnections = false)
        val koin = RelayFamilyShotsRuntime.koin()
        val skills = koin.get<SkillRepository>()
        val notes = koin.get<NoteRepository>()
        val autoInvoke = koin.get<SkillsAutoInvokePreference>()

        SkillsShotsData.seed(koin, manifest, checkNotNull(manifest.page(SkillsShotPage.SkillsHomeAutoOff)))
        assertEquals(manifest.skills.size, skills.observeUserSkills().first().size)
        val active = notes.getActiveNotes().sortedByDescending { it.updatedAt }
        assertEquals(manifest.notes.size, active.size)
        assertEquals("Kyoto trip memo", active.first().title)
        assertFalse(autoInvoke.isEnabled())

        SkillsShotsData.seed(koin, manifest, checkNotNull(manifest.page(SkillsShotPage.SkillsHomeEmpty)))
        assertEquals(0, skills.observeUserSkills().first().size)
        assertEquals(0, notes.getActiveNotes().size)
        assertEquals(manifest.templates.map { it.id }.toSet(), skills.observeCatalogSkills().first().map { it.id }.toSet())
        assertTrue(autoInvoke.isEnabled())

        SkillsShotsData.seed(koin, manifest, checkNotNull(manifest.page(SkillsShotPage.SkillsHome)))
        assertEquals(manifest.skills.size, skills.observeUserSkills().first().size)
        assertEquals(manifest.notes.size, notes.getActiveNotes().size)
        assertTrue(autoInvoke.isEnabled())
        assertFalse("real database must not be created", realDatabase.exists())
    }

    @Test
    fun `empty_no_catalog_page_seeds_no_templates`() = runBlocking {
        val app = RuntimeEnvironment.getApplication() as Application
        RelayFamilyShotsRuntime.start(app, interceptUrlConnections = false)
        val koin = RelayFamilyShotsRuntime.koin()
        val skills = koin.get<SkillRepository>()

        val page = checkNotNull(manifest.page(SkillsShotPage.SkillsHomeEmptyNoCatalog))
        assertEquals(SkillsShotsManifest.Subject.Home, page.subject)
        assertEquals(listOf("ios", "android"), page.ends)
        assertTrue(page.emptyData)
        assertTrue(page.emptyCatalog)
        assertFalse(checkNotNull(manifest.page(SkillsShotPage.SkillsHomeEmpty)).emptyCatalog)

        SkillsShotsData.seed(koin, manifest)
        SkillsShotsData.seed(koin, manifest, page)
        assertTrue(skills.observeUserSkills().first().isEmpty())
        assertTrue(skills.observeCatalogSkills().first().isEmpty())

        // The plain empty page still writes every template back after the no-catalog page.
        SkillsShotsData.seed(koin, manifest, checkNotNull(manifest.page(SkillsShotPage.SkillsHomeEmpty)))
        assertEquals(manifest.templates.map { it.id }.toSet(), skills.observeCatalogSkills().first().map { it.id }.toSet())
    }

    @Test
    fun `improve pages hang the production diff under the first answer after the correction`() {
        val prompt = checkNotNull(manifest.page(SkillsShotPage.SkillsImprovePrompt))
        val diffPage = checkNotNull(manifest.page(SkillsShotPage.SkillsImproveDiffTeal))
        assertEquals(SkillsShotsManifest.Subject.ImproveDiff, diffPage.subject)
        val conversation = SkillsShotsData.conversation(manifest, prompt)
        assertEquals(manifest.improve.conversationId, conversation.id)
        assertEquals(conversation.id, SkillsShotsData.conversation(manifest, diffPage).id)

        val skill = manifest.skills.single { it.id == manifest.improve.skillId }
        val pending = SkillsShotsData.improvePending(manifest, conversation)
        val expected = checkNotNull(
            SkillImprove.buildImproveDiff(SkillImprove.DiffInput(skill.systemPrompt, manifest.improve.rule, manifest.improve.replaces)),
        )
        assertEquals(expected, pending.diff)
        assertEquals(SkillImprove.DiffOp.Replace, pending.diff.op)
        assertEquals(2, pending.diff.lineIndex)
        assertEquals("3. At most 5 bullets per section.", pending.diff.before)
        assertEquals("3. At most 3 bullets per section, risks first.", pending.diff.after)
        assertEquals(skill.systemPrompt, pending.diffBase)
        assertEquals(SkillRuntime.canonicalId(skill.id), pending.skillId)
        assertEquals("m13", pending.userMessageId)
        assertEquals("m14", SkillImprovePrompt.answerIdFor(conversation.messages, pending.userMessageId))
        val rows = SkillImprovePrompt.diffRows(pending, skill.systemPrompt)
        assertEquals(1, rows.count { it.kind == SkillImprovePrompt.RowKind.Removed })
        assertEquals(pending.diff.after, rows.single { it.kind == SkillImprovePrompt.RowKind.Added }.text)
    }

    @Test
    fun `token cost and empty reply pages carry the optional message fields`() {
        val tokenPage = checkNotNull(manifest.page(SkillsShotPage.SkillsTokenCost))
        val first = SkillsShotsData.conversation(manifest, tokenPage)
        assertEquals(manifest.conversations.first().id, first.id)
        val reply = first.messages.single { it.id == "m2" }
        assertEquals(3120, reply.inputTokens)
        assertEquals(486, reply.outputTokens)
        assertEquals(0.0124, reply.estimatedCost, 0.0)
        assertEquals(CostSource.LOCAL_ESTIMATE.name, reply.costSource)
        assertEquals("m2", SkillsShotsData.tokenUsageReplyId(first, tokenPage))
        assertNull(SkillsShotsData.tokenUsageReplyId(first, checkNotNull(manifest.page(SkillsShotPage.SkillsUsed))))
        assertEquals(mapOf("m2" to 1840, "m12" to 2210, "m14" to 2350), manifest.skillManifestTokens)

        val emptyPage = checkNotNull(manifest.page(SkillsShotPage.SkillsEmptyReply))
        val empty = SkillsShotsData.conversation(manifest, emptyPage)
        assertEquals("c0000000-0000-4000-8000-000000000003", empty.id)
        val failed = empty.messages.single { it.id == "m22" }
        assertEquals(ChatRole.Assistant, failed.role)
        assertEquals(ChatMessageState.Failed, failed.state)
        assertEquals(ProviderServiceError.EmptyResponse.title, failed.errorTitle)
        assertEquals(failedMessageDetail(ProviderServiceError.EmptyResponse), failed.errorDetail)
        assertTrue(manifest.conversations.flatMap { it.messages }.filter { it.id != "m22" }.all { it.state == ChatMessageState.Delivered })

        assertTrue(SkillsShotsManifest.parse(text.replace("\"error\": \"empty_response\"", "\"error\": \"timeout\"")).isFailure)
        assertTrue(SkillsShotsManifest.parse(text.replace("\"skillManifestTokens\": 1840", "\"skillManifestTokens\": \"1840\"")).isFailure)
    }

    @Test
    fun `chat pages seed token columns and read back the page conversation`() = runBlocking {
        val app = RuntimeEnvironment.getApplication() as Application
        val realDatabase = app.getDatabasePath("oriveo.db")
        RelayFamilyShotsRuntime.start(app, interceptUrlConnections = false)
        val koin = RelayFamilyShotsRuntime.koin()
        val accountId = koin.get<AccountSessionManager>().currentAccountId.value

        val tokenPage = SkillsShotsData.seed(koin, manifest, checkNotNull(manifest.page(SkillsShotPage.SkillsTokenCost)))
        val reply = tokenPage.messages.single { it.id.equals("m2", ignoreCase = true) }
        assertEquals(3120, reply.inputTokens)
        assertEquals(486, reply.outputTokens)
        assertEquals(CostSource.LOCAL_ESTIMATE.name, reply.costSource)
        val rows = koin.get<MessageDao>().remoteConfirmationStatesByConversation(accountId, tokenPage.id)
        assertEquals(1840, rows.single { it.id.equals("m2", ignoreCase = true) }.skillManifestTokens)
        assertNull(rows.single { it.id.equals("m1", ignoreCase = true) }.skillManifestTokens)

        val emptyPage = SkillsShotsData.seed(koin, manifest, checkNotNull(manifest.page(SkillsShotPage.SkillsEmptyReply)))
        assertTrue(emptyPage.id.equals("c0000000-0000-4000-8000-000000000003", ignoreCase = true))
        val failed = emptyPage.messages.last()
        assertEquals(ChatMessageState.Failed, failed.state)
        assertEquals(ProviderServiceError.EmptyResponse.title, failed.errorTitle)

        val improvePage = SkillsShotsData.seed(koin, manifest, checkNotNull(manifest.page(SkillsShotPage.SkillsImproveDiff)))
        val pending = SkillsShotsData.improvePending(manifest, improvePage)
        val answer = checkNotNull(SkillImprovePrompt.answerIdFor(improvePage.messages, pending.userMessageId))
        assertTrue(answer.equals("m14", ignoreCase = true))
        val improveRows = koin.get<MessageDao>().remoteConfirmationStatesByConversation(accountId, improvePage.id)
        assertEquals(2350, improveRows.single { it.id.equals(answer, ignoreCase = true) }.skillManifestTokens)
        assertFalse("real database must not be created", realDatabase.exists())
    }

    @Test
    fun `trial page starts on the manifest trial copy and its two finished turns`() {
        val page = checkNotNull(manifest.page(SkillsShotPage.SkillsTrial))
        assertEquals(SkillsShotsManifest.Subject.Trial, page.subject)
        val args = SkillsShotsData.trialArgs(manifest)
        val skill = manifest.skills.single { it.id == manifest.trial.skillId }
        assertEquals(SkillTrial.Origin.SAVED, args.origin)
        assertEquals(skill.id, args.skillId)
        assertEquals(skill, args.original)
        assertEquals(skill.systemPrompt, args.instructions)
        assertEquals(manifest.trial.trialSystemPrompt, args.initialInstructions)
        assertNotEquals(skill.systemPrompt, args.initialInstructions)
        assertEquals(2, args.initialMessages.size)
        assertEquals(listOf(ChatRole.User, ChatRole.Assistant), args.initialMessages.map { it.role })
        assertEquals(manifest.trial.messages.map { it.text }, args.initialMessages.map { it.text })
        assertTrue(args.initialMessages.all { it.state == ChatMessageState.Delivered })
        // The saved copy differs from the trial copy, so the write-back button is a PUT.
        val saved = SkillValidation.Input(
            name = skill.name,
            whenToUse = skill.whenToUse,
            instructions = skill.systemPrompt,
            starters = skill.starterMessages,
            autoInvoke = skill.autoInvoke,
            savedName = skill.name,
        )
        val action = SkillTrial.trialWriteBack(
            SkillTrial.WriteBackInput(args.origin, saved, saved.copy(instructions = manifest.trial.trialSystemPrompt)),
        ).action
        assertEquals(SkillTrial.Action.PUT, action)
    }

    @Test
    fun `usage page row sums the period assistant manifest tokens through the production summary`() {
        val page = checkNotNull(manifest.page(SkillsShotPage.SkillsUsageManifest))
        assertEquals(SkillsShotsManifest.Subject.Usage, page.subject)
        val row = SkillsShotsData.usageManifestRow(manifest)
        val summary = checkNotNull(row.summary)
        assertEquals(6400L, summary.tokens)
        assertEquals(3, summary.turns)
        val state = SkillsShotsData.usageState(manifest)
        assertFalse(state.isDemoMode)
        assertEquals(row, state.manifestRow)
        assertEquals(UsageTrendsGranularity.month, state.selectedGranularity)
        assertEquals("2026-10-01", state.providerTrends?.currentPeriod?.start)
        assertEquals("2026-10-31", state.providerTrends?.currentPeriod?.end)
        // A period without recorded turns has no summary (the row shows not available, never 0).
        val empty = manifest.copy(usagePage = manifest.usagePage.copy(start = LocalDate.parse("2026-09-01"), end = LocalDate.parse("2026-09-30")))
        assertNull(SkillsShotsData.usageManifestRow(empty).summary)
    }

    @Test
    fun usage_page_scrolls_to_manifest_row() {
        val page = checkNotNull(manifest.page(SkillsShotPage.SkillsUsageManifest))
        assertEquals(SkillsShotsManifest.Subject.Usage, page.subject)
        // Starts past the end; ScrollState clamps to the real maximum on layout, so the last panel (the manifest row) is in view.
        val scroll = SkillsShots.usageScrollState()
        assertEquals(Int.MAX_VALUE, scroll.value)
        assertNotNull(SkillsShotsData.usageState(manifest).manifestRow?.summary)
    }

    @Test
    fun usage_shot_scroll_target_per_page() {
        // The plain page scrolls to the end (manifest row in view); the palette pages pin the composition card to the top.
        assertEquals(SkillsShots.UsageScrollTarget.Bottom, SkillsShots.usageScrollTarget(SkillsShotPage.SkillsUsageManifest))
        assertEquals(SkillsShots.UsageScrollTarget.CompositionCardTop, SkillsShots.usageScrollTarget(SkillsShotPage.SkillsUsageManifestAmber))
        assertEquals(SkillsShots.UsageScrollTarget.CompositionCardTop, SkillsShots.usageScrollTarget(SkillsShotPage.SkillsUsageManifestTeal))
    }

    @Test
    fun empty_reply_page_uses_default_placeholder() {
        val emptyPage = checkNotNull(manifest.page(SkillsShotPage.SkillsEmptyReply))
        val empty = SkillsShotsData.conversation(manifest, emptyPage)
        assertEquals(ChatMessageState.Failed, empty.messages.last().state)
        // A conversation whose last reply failed still has messages, so the skills placeholder stays hidden.
        assertTrue(SkillsShots.composerHasMessages(empty))
        assertFalse(SkillsShots.composerHasMessages(empty.copy(messages = emptyList(), messageCount = 0)))
    }

    @Test
    fun `state field refines only its own subject and unknown states refuse the manifest`() {
        val states = manifest.pages.filter { it.state != null }.associate { it.name to it.state }
        assertEquals(
            mapOf(
                "skillsDraftGenerating" to SkillsShotsManifest.State.DraftGenerating,
                "skillsTemplatesLoading" to SkillsShotsManifest.State.TemplatesLoading,
                "skillsTemplatesFailed" to SkillsShotsManifest.State.TemplatesFailed,
                "skillsEditDraftFailed" to SkillsShotsManifest.State.DraftFailed,
                "skillsEditNeedWhen" to SkillsShotsManifest.State.NeedWhen,
                "skillsComposerFull" to SkillsShotsManifest.State.Full,
                "skillsTrialEmpty" to SkillsShotsManifest.State.Empty,
                "skillsTrialFailed" to SkillsShotsManifest.State.Failed,
            ),
            states,
        )
        manifest.pages.filter { it.state != null }.forEach { assertEquals(it.name, it.state?.subject, it.subject) }
        assertTrue(SkillsShotsManifest.parse(withPageState("skillsComposerFull", "draftFailed")).isFailure)
        assertTrue(SkillsShotsManifest.parse(withPageState("skillsTrialEmpty", "loading")).isFailure)
        assertTrue(SkillsShotsManifest.parse(withPageState("skillsTrial", "failed")).isSuccess)
    }

    @Test
    fun `mine empty page seeds the first run data set`() {
        val page = checkNotNull(manifest.page(SkillsShotPage.SkillsMineEmpty))
        assertEquals(SkillsShotsManifest.Subject.Mine, page.subject)
        assertTrue(page.emptyData)
        assertFalse(page.emptyCatalog)
        assertNull(page.state)
    }

    @Test
    fun `draft generating page holds the production flow on its generating step`() = runBlocking {
        val page = checkNotNull(manifest.page(SkillsShotPage.SkillsDraftGenerating))
        assertEquals(SkillsShotsManifest.Subject.Mine, page.subject)
        val state = SkillsShotsData.draftGeneratingState(manifest)
        val described = SkillDraftFlowModel.start(manifest.states.draftDescription)
        assertEquals(SkillDraftFlowModel.skip(SkillDraftFlowModel.skip(described)), state)
        assertEquals(SkillDraftFlowModel.Step.Generating, state.step)
        assertNull(withTimeoutOrNull(200) { SkillDraftFlowModel.generate(SkillsShotsData.pendingDraftService(), state) })
    }

    @Test
    fun `draft failed page prefills the editor the way the production failure path does`() = runBlocking {
        val page = checkNotNull(manifest.page(SkillsShotPage.SkillsEditDraftFailed))
        assertEquals(SkillsShotsManifest.Subject.Edit, page.subject)
        assertEquals(SkillsShotsManifest.State.DraftFailed, page.state)
        // A thrown draft request hands an empty draft to the editor; the description is not carried over on Android.
        assertEquals(SkillDraft.Draft(), SkillsShotsData.draftFailedPrefill(manifest))
    }

    @Test
    fun `need when page prefills a new skill without when to use`() {
        val page = checkNotNull(manifest.page(SkillsShotPage.SkillsEditNeedWhen))
        assertEquals(SkillsShotsManifest.State.NeedWhen, page.state)
        val prefill = SkillsShotsData.needWhenPrefill(manifest)
        val needWhen = raw.getValue("states").jsonObject.getValue("needWhen").jsonObject
        assertEquals(needWhen.string("name"), prefill.name)
        assertEquals(needWhen.string("instructions"), prefill.instructions)
        assertNull(prefill.whenToUse)
    }

    @Test
    fun `trial empty page starts on the saved instructions with no turns`() {
        val page = checkNotNull(manifest.page(SkillsShotPage.SkillsTrialEmpty))
        val args = SkillsShotsData.trialArgs(manifest, page)
        val skill = manifest.skills.single { it.id == manifest.trial.skillId }
        assertEquals(SkillTrial.Origin.SAVED, args.origin)
        assertEquals(skill.systemPrompt, args.instructions)
        assertNull(args.initialInstructions)
        assertTrue(args.initialMessages.isEmpty())
    }

    @Test
    fun `trial failed page shows the rate limited reply through the production failure mapping`() {
        val page = checkNotNull(manifest.page(SkillsShotPage.SkillsTrialFailed))
        val args = SkillsShotsData.trialArgs(manifest, page)
        val skill = manifest.skills.single { it.id == manifest.trial.skillId }
        assertEquals(skill.systemPrompt, args.instructions)
        assertNull(args.initialInstructions)
        val failed = raw.getValue("states").jsonObject.getValue("trialFailedMessages").jsonArray.map { it.jsonObject }
        assertEquals(failed.map { it.string("text") }, args.initialMessages.map { it.text })
        assertEquals(listOf(ChatRole.User, ChatRole.Assistant), args.initialMessages.map { it.role })
        assertEquals(listOf(ChatMessageState.Delivered, ChatMessageState.Failed), args.initialMessages.map { it.state })
        val error = SkillsShotsData.trialRateLimitError()
        assertTrue(error is ProviderServiceError.RateLimited)
        assertEquals(429, error.httpStatus)
        val reply = args.initialMessages.last()
        assertEquals(error.title, reply.errorTitle)
        assertEquals(failedMessageDetail(error), reply.errorDetail)
    }

    @Test
    fun `home picker page types we and carries the composer chip`() {
        val page = checkNotNull(manifest.page(SkillsShotPage.SkillsHomePicker))
        assertEquals(SkillsShotsManifest.Subject.HomePicker, page.subject)
        val chips = SkillComposerChipsModel(
            scope = CoroutineScope(Dispatchers.Unconfined),
            userSkills = flowOf(manifest.skills),
            templates = flowOf(manifest.templates),
            writeSkillIds = { _, _ -> null },
            track = { _, _ -> },
        )
        val text = SkillsShotsData.homePicker(manifest, chips)
        assertEquals("/we", text)
        assertEquals(SkillsShotsData.COMPOSER_QUERY, checkNotNull(SkillComposerTrigger.detect(text, text.length)).query)
        val chip = chips.chips(null, emptyList(), SkillPickerCache(manifest.skills, manifest.templates)).single()
        val composerChip = SkillsShotsData.conversation(manifest).skillIds.single()
        assertTrue(chip.id.equals(composerChip, ignoreCase = true))
        assertNotNull(chip.skill)
    }

    private fun assertFields(json: JsonObject, skill: Skill) {
        for ((key, value) in json) {
            if (key.startsWith("$")) continue
            val actual: Any? = when (key) {
                "id" -> skill.id
                "key" -> skill.key
                "name" -> skill.name
                "source" -> skill.source.value
                "category" -> skill.category
                "iconKey" -> skill.iconKey
                "whenToUse" -> skill.whenToUse
                "autoInvoke" -> skill.autoInvoke
                "systemPrompt" -> skill.systemPrompt
                "starterMessages" -> skill.starterMessages
                "usageCount" -> skill.usageCount
                "sortOrder" -> skill.sortOrder
                "lastUsedAt" -> skill.lastUsedAt
                "createdAt" -> skill.createdAt
                "updatedAt" -> skill.updatedAt
                "whenToUseTranslations" -> skill.whenToUseTranslations
                "previewUser" -> skill.previewUser
                "previewAssistant" -> skill.previewAssistant
                else -> error("fixture key $key is not checked")
            }
            assertEquals("${skill.id}.$key", plain(value), actual)
        }
    }

    private fun plain(value: JsonElement): Any? = when (value) {
        is JsonNull -> null
        is JsonPrimitive -> value.booleanOrNull.takeIf { !value.isString } ?: value.intOrNull.takeIf { !value.isString } ?: value.content
        is JsonArray -> value.map(::plain)
        is JsonObject -> value.mapValues { plain(it.value) }
    }

    private fun JsonObject.string(key: String): String? = (this[key] as? JsonPrimitive)?.content

    /** Manifest text with page [name] given `state` [value]. */
    private fun withPageState(name: String, value: String): String {
        val pages = raw.getValue("pages").jsonArray.map { element ->
            val page = element.jsonObject
            if (page.string("name") == name) JsonObject(page + ("state" to JsonPrimitive(value))) else page
        }
        return JsonObject(raw + ("pages" to JsonArray(pages))).toString()
    }

    private companion object {
        const val FIXTURE = "\u5171\u4eab/test-fixtures/shots/skills.v1.json"

        fun manifestText(): String {
            var dir: File? = File(System.getProperty("user.dir") ?: ".").absoluteFile
            while (dir != null) {
                val file = File(dir, FIXTURE)
                if (file.isFile) return file.readText()
                dir = dir.parentFile
            }
            error("$FIXTURE not found above ${System.getProperty("user.dir")}")
        }
    }
}
