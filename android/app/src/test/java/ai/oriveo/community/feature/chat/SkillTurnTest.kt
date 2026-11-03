package ai.oriveo.community.feature.chat

import ai.oriveo.community.core.context.ContextBudget
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatMessageState
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.core.model.Conversation
import ai.oriveo.community.core.model.GenerationParameterSettingsStore
import ai.oriveo.community.core.model.ProviderChatResult
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderConnectionState
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.Skill
import ai.oriveo.community.core.model.SkillSource
import ai.oriveo.community.core.model.StreamEvent
import ai.oriveo.community.core.model.UsedSkill
import ai.oriveo.community.core.model.withSkillIds
import ai.oriveo.community.core.provider.CostSource
import ai.oriveo.community.core.skills.SkillChannel
import ai.oriveo.community.core.skills.SkillRuntime
import ai.oriveo.community.core.skills.SkillTurnDependencies
import ai.oriveo.community.core.streaming.ChatStreamingManager
import ai.oriveo.community.core.streaming.StreamRequest
import io.mockk.every
import io.mockk.mockk
import io.mockk.slot
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

class SkillTurnTest {

    private val firstId = "11111111-1111-1111-1111-111111111111"
    private val secondId = "22222222-2222-2222-2222-222222222222"
    private val autoId = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
    private val autoCanonical = SkillRuntime.canonicalId(autoId)

    private val first = Skill(id = firstId, name = "First", systemPrompt = "Be first.")
    private val second = Skill(id = secondId, name = "Second", systemPrompt = "Be second.")
    private val auto = Skill(
        id = autoId,
        name = "Auto  Writer",
        systemPrompt = "Write well.",
        whenToUse = "When the user asks for writing help",
        autoInvoke = true,
    )

    private val provider = Provider(
        id = "openai-1",
        kind = ProviderKind.OpenAI,
        status = ProviderConnectionState.Connected,
        apiKey = "local-key",
        models = listOf(AIModel(id = "gpt-4.1", name = "GPT-4.1")),
    )

    private val conversation = Conversation(
        id = "conversation-1",
        title = "Skills",
        providerID = "openai-1",
        providerKind = ProviderKind.OpenAI,
        modelID = "gpt-4.1",
    ).withSkillIds(listOf(secondId, firstId))

    private fun message(id: String, role: ChatRole) = ChatMessage(
        id = id,
        role = role,
        text = id,
        providerKind = ProviderKind.OpenAI,
        providerName = "OpenAI",
        modelName = "GPT-4.1",
        state = ChatMessageState.Delivered,
    )

    private fun done(text: String) = StreamEvent.Done(ProviderChatResult(text = text))

    private fun deltas(events: List<StreamEvent>) = events.filterIsInstance<StreamEvent.Delta>().map { it.text }

    private class Recorder {
        val resendLoaded = mutableListOf<List<String>>()
        val used = mutableListOf<Pair<String, String>>()
        val autoUsedEvents = mutableListOf<Pair<String, String>>()
    }

    private fun turn(recorder: Recorder, channel: SkillChannel = SkillChannel.MARKER) = SkillTurn(
        channel = channel,
        manifestIds = listOf(autoCanonical),
        attachedSkills = listOf(second, first),
        skills = listOf(second, first, auto),
        resendInputs = { loaded ->
            recorder.resendLoaded += loaded
            SkillTurnInputs(skillPrompt = "resent", knowledgeFiles = emptyList(), retrieval = null)
        },
        recordUsed = { id, via -> recorder.used += id to via },
        trackAutoUsed = { id, channel -> recorder.autoUsedEvents += id to channel },
    )

    private val resendFlow: Flow<StreamEvent> = flowOf(StreamEvent.Delta("answer"), done("answer"))

    @Test
    fun `attached skills follow skillIds order and the marker manifest rides the send`() = runTest {
        val streamingManager = mockk<ChatStreamingManager>(relaxed = true)
        val captured = slot<StreamRequest>()
        every { streamingManager.startStream(capture(captured)) } returns Unit
        val recorded = mutableListOf<Pair<String, String>>()
        val byId = listOf(first, second, auto).associateBy { SkillRuntime.canonicalId(it.id) }
        val coordinator = ChatSendCoordinator(
            chatStreamingManager = streamingManager,
            applicationScope = this,
            skillDependencies = object : SkillTurnDependencies {
                override suspend fun skill(id: String): Skill? = byId[SkillRuntime.canonicalId(id)]
                override suspend fun userSkills(): List<Skill> = listOf(first, second, auto)
                override suspend fun recordUse(skillId: String, via: String) {
                    recorded += skillId to via
                }
            },
            pinnedNotesResolver = { emptyList() },
            pendingPinnedNoteIds = { emptyList() },
            generationParameterSettingsStore = GenerationParameterSettingsStore(readPayload = { null }, writePayload = {}),
        )
        // The first skill was attached to an earlier user message: only the second one is recorded (manual, once).
        val earlier = ChatMessage(
            id = "m-1",
            role = ChatRole.User,
            text = "Earlier",
            providerKind = ProviderKind.OpenAI,
            providerName = "OpenAI",
            modelName = "GPT-4.1",
            state = ChatMessageState.Delivered,
            attachedSkillIds = listOf(firstId),
        )

        coordinator.launchSend(
            conversation = conversation,
            provider = provider,
            modelId = "gpt-4.1",
            text = "Please help me write",
            memoryItems = emptyList(),
            existingMessages = listOf(earlier),
        )
        advanceUntilIdle()

        val request = captured.captured
        val prompt = checkNotNull(request.requestOptions.chatContext?.conversation?.skillPrompt)
        assertTrue(prompt, prompt.startsWith(SkillRuntime.ATTACHED_HEADER))
        val secondAt = prompt.indexOf("## Skill: Second\nBe second.")
        val firstAt = prompt.indexOf("## Skill: First\nBe first.")
        assertTrue(prompt, secondAt in 0 until firstAt)
        assertTrue(prompt, prompt.contains(SkillRuntime.MARKER_NOTE))
        assertTrue(prompt, prompt.contains("<skill id=\"$autoCanonical\" name=\"Auto Writer\">"))
        val skillTurn = checkNotNull(request.skillTurn)
        assertEquals(SkillChannel.MARKER, skillTurn.channel)
        assertEquals(listOf(autoCanonical), skillTurn.manifestIds)
        assertEquals(
            listOf(UsedSkill(secondId, "Second", "manual"), UsedSkill(firstId, "First", "manual")),
            skillTurn.usedSkills(),
        )
        // Nothing is recorded before the repository stores the user message.
        assertTrue(recorded.isEmpty())
        skillTurn.recordManualUses(listOf(earlier))
        advanceUntilIdle()
        assertEquals(listOf(secondId to "manual"), recorded)
    }

    @Test
    fun `manual use is recorded once per conversation`() {
        val history = listOf(
            message("u1", ChatRole.User).copy(attachedSkillIds = listOf(firstId)),
            message("a1", ChatRole.Assistant),
        )
        assertEquals(listOf(firstId), SkillTurn.manualUses(listOf(firstId, firstId.lowercase()), emptyList()))
        assertEquals(emptyList<String>(), SkillTurn.manualUses(listOf(firstId.lowercase()), history))
        assertEquals(listOf(secondId), SkillTurn.manualUses(listOf(firstId, secondId), history))
    }

    @Test
    fun `marker hit stops the first request and resends once with the loaded skill`() = runTest {
        val recorder = Recorder()
        val skillTurn = turn(recorder)
        val upstream = flowOf(
            StreamEvent.Delta("⟦skill:"),
            StreamEvent.Delta("$autoId | fits writing⟧"),
            StreamEvent.Delta("never shown"),
            done("never shown"),
        )

        val events = skillTurn.gate(upstream) { inputs ->
            assertEquals("resent", inputs.skillPrompt)
            resendFlow
        }.toList()

        assertEquals(listOf("answer"), deltas(events))
        assertEquals("answer", events.filterIsInstance<StreamEvent.Done>().single().result.text)
        assertEquals(listOf(listOf(autoCanonical)), recorder.resendLoaded)
        assertFalse(skillTurn.markerActive)
        assertEquals(
            listOf(
                UsedSkill(secondId, "Second", "manual"),
                UsedSkill(firstId, "First", "manual"),
                UsedSkill(autoId, "Auto Writer", "auto", "fits writing"),
            ),
            skillTurn.usedSkills(),
        )
        skillTurn.recordAutoUses()
        assertEquals(listOf(autoId to "auto"), recorder.used)
        assertEquals(listOf(autoId to "marker"), recorder.autoUsedEvents)
    }

    @Test
    fun `marker miss releases the text untouched and never resends`() = runTest {
        val recorder = Recorder()
        val skillTurn = turn(recorder)
        val finished = done("[x and more")
        val events = skillTurn.gate(
            flowOf(StreamEvent.Delta("["), StreamEvent.Delta("x"), StreamEvent.Delta(" and more"), finished),
        ) { resendFlow }.toList()

        assertEquals(listOf("[x", " and more"), deltas(events))
        assertSame(finished, events.last())
        assertTrue(recorder.resendLoaded.isEmpty())
        assertFalse(skillTurn.markerActive)
        assertEquals(2, skillTurn.usedSkills().size)
        skillTurn.recordAutoUses()
        assertTrue(recorder.used.isEmpty())
        assertTrue(recorder.autoUsedEvents.isEmpty())
    }

    @Test
    fun `stream_end_without_done_releases_held_text`() = runTest {
        val recorder = Recorder()
        val events = turn(recorder).gate(
            flowOf(StreamEvent.Delta("["), StreamEvent.Delta("x")),
        ) { resendFlow }.toList()

        assertEquals("[x", deltas(events).joinToString(""))
        assertTrue(events.none { it is StreamEvent.Done })
        assertTrue(recorder.resendLoaded.isEmpty())
    }

    @Test
    fun `stream_end_without_done_marker_hit_resends`() = runTest {
        val recorder = Recorder()
        val events = turn(recorder).gate(
            flowOf(StreamEvent.Delta("\u27e6skill:"), StreamEvent.Delta("$autoId | fits\u27e7")),
        ) { resendFlow }.toList()

        assertEquals(listOf(StreamEvent.Delta("answer"), done("answer")), events)
        assertEquals(1, recorder.resendLoaded.size)
    }

    @Test
    fun `invalid marker drops its line and releases the rest`() = runTest {
        val recorder = Recorder()
        val skillTurn = turn(recorder)
        val events = skillTurn.gate(
            flowOf(
                StreamEvent.Delta("⟦skill:unknown|x⟧\nReal"),
                StreamEvent.Delta(" answer"),
                done("⟦skill:unknown|x⟧\nReal answer"),
            ),
        ) { resendFlow }.toList()

        assertEquals(listOf("Real", " answer"), deltas(events))
        assertEquals("Real answer", events.filterIsInstance<StreamEvent.Done>().single().result.text)
        assertTrue(recorder.resendLoaded.isEmpty())
    }

    @Test
    fun `managed stream hit keeps managed frames and resends`() = runTest {
        val recorder = Recorder()
        val skillTurn = turn(recorder)
        val created = StreamEvent.ManagedRequestCreated("request-1")
        val sequence = StreamEvent.ManagedSequence("request-1", 1)
        val events = skillTurn.gate(
            flowOf(
                created,
                sequence,
                StreamEvent.Delta("【skill：$autoCanonical｜why】"),
                StreamEvent.ManagedSequence("request-1", 2),
                StreamEvent.Delta("tail"),
            ),
        ) { resendFlow }.toList()

        assertEquals(listOf(created, sequence, StreamEvent.Delta("answer"), done("answer")), events)
        assertEquals(listOf(listOf(autoCanonical)), recorder.resendLoaded)
        assertEquals("why", skillTurn.usedSkills().last().reason)
    }

    @Test
    fun `managed sequence of held text is not released while the marker is pending`() = runTest {
        val skillTurn = turn(Recorder())
        val before = StreamEvent.ManagedSequence("request-1", 1)
        val held = StreamEvent.ManagedSequence("request-1", 2)
        val events = mutableListOf<StreamEvent>()
        val dropped = runCatching {
            skillTurn.gate(
                kotlinx.coroutines.flow.flow {
                    emit(before)
                    emit(StreamEvent.Reasoning("think"))
                    emit(held)
                    emit(StreamEvent.Delta("\u27e6skill:"))
                    throw java.io.IOException("dropped")
                },
            ) { resendFlow }.collect { events += it }
        }.exceptionOrNull()

        assertTrue(dropped is java.io.IOException)
        assertEquals(listOf(before, StreamEvent.Reasoning("think")), events)
    }

    @Test
    fun `reasoning after held text is held until the marker is decided`() = runTest {
        val held = StreamEvent.ManagedSequence("request-1", 2)
        val late = StreamEvent.Reasoning("late")
        val pendingEvents = mutableListOf<StreamEvent>()
        runCatching {
            turn(Recorder()).gate(
                kotlinx.coroutines.flow.flow {
                    emit(held)
                    emit(StreamEvent.Delta("\u27e6skill:"))
                    emit(late)
                    throw java.io.IOException("dropped")
                },
            ) { resendFlow }.collect { pendingEvents += it }
        }
        assertTrue(pendingEvents.isEmpty())

        val finished = done("[x")
        val missEvents = turn(Recorder()).gate(
            flowOf(held, StreamEvent.Delta("["), late, StreamEvent.Delta("x"), finished),
        ) { resendFlow }.toList()
        assertEquals(listOf(held, late, StreamEvent.Delta("[x"), finished), missEvents)

        val hitEvents = turn(Recorder()).gate(
            flowOf(StreamEvent.Delta("\u27e6skill:"), late, StreamEvent.Delta("$autoId | fits\u27e7")),
        ) { resendFlow }.toList()
        assertEquals(listOf(StreamEvent.Delta("answer"), done("answer")), hitEvents)
    }

    @Test
    fun `managed sequence is released just before the text it marks on a miss`() = runTest {
        val skillTurn = turn(Recorder())
        val held = StreamEvent.ManagedSequence("request-1", 2)
        val finished = done("[x")
        val events = skillTurn.gate(
            flowOf(held, StreamEvent.Delta("["), StreamEvent.Delta("x"), finished),
        ) { resendFlow }.toList()

        assertEquals(listOf(held, StreamEvent.Delta("[x"), finished), events)
    }

    @Test
    fun `channel none passes the stream through`() = runTest {
        val skillTurn = turn(Recorder(), channel = SkillChannel.NONE)
        val upstream = flowOf(StreamEvent.Delta("⟦skill:$autoCanonical|x⟧"), done("x"))
        assertSame(upstream, skillTurn.gate(upstream) { resendFlow })
    }

    @Test
    fun `templates attach but never enter the manifest`() {
        val template = auto.copy(id = "template-1", source = SkillSource.BUILTIN)
        val result = SkillRuntime.buildManifest(
            skills = listOf(SkillTurn.runtimeSkill(template), SkillTurn.runtimeSkill(auto)),
            attached = emptyList(),
            disabledAuto = emptyList(),
            autoEnabled = true,
            channel = SkillChannel.MARKER,
            loaded = emptyList(),
        )
        assertEquals(listOf(autoCanonical), result.manifestIds)
    }

    @Test
    fun `hit with reported usage charges the stopped request with that usage`() = runTest {
        val skillTurn = turn(Recorder())
        val reported = ProviderChatResult(
            text = "\u27e6skill:$autoId | fits writing\u27e7",
            promptTokens = 120,
            completionTokens = 9,
            estimatedCost = 0.002,
            costSource = CostSource.UPSTREAM.name,
        )
        skillTurn.gate(flowOf(StreamEvent.Done(reported))) { resendFlow }.toList()

        val leg = checkNotNull(skillTurn.chargeInterrupted(estimatedInput = 999, rhoHi = 0.5))
        assertEquals(120, leg.promptTokens)
        assertEquals(9, leg.completionTokens)
        assertEquals(0.002, leg.estimatedCost, 0.0)
        assertEquals(CostSource.UPSTREAM.name, leg.costSource)
        assertEquals("", leg.text)
        assertSame(leg, skillTurn.interruptedLeg)
    }

    @Test
    fun `hit without usage estimates the stopped request as localEstimate`() = runTest {
        val skillTurn = turn(Recorder())
        val held = "\u27e6skill:$autoId | fits writing\u27e7"
        val shown = "Thinking first. "
        val heldThought = "Then the marker."
        skillTurn.gate(
            flowOf(
                StreamEvent.Reasoning(shown),
                StreamEvent.Delta("\u27e6skill:"),
                StreamEvent.Reasoning(heldThought),
                StreamEvent.Delta(held.removePrefix("\u27e6skill:")),
                StreamEvent.Delta("never shown"),
            ),
        ) { resendFlow }.toList()

        assertEquals(held, checkNotNull(skillTurn.interruptedRequest).heldText)
        assertEquals(shown + heldThought, checkNotNull(skillTurn.interruptedRequest).reasoningText)
        val leg = checkNotNull(skillTurn.chargeInterrupted(estimatedInput = 340, rhoHi = 0.5))
        assertEquals(340, leg.promptTokens)
        assertEquals(
            ContextBudget.estimateText(held, 0.5) + ContextBudget.estimateText(shown + heldThought, 0.5),
            leg.completionTokens,
        )
        assertTrue(leg.completionTokens > 0)
        assertEquals(CostSource.LOCAL_ESTIMATE.name, leg.costSource)
        assertTrue(leg.usageReported)
    }

    @Test
    fun `hit without usage or input estimate leaves the stopped leg unknown`() {
        val leg = SkillTurn.interruptedLeg(SkillInterruptedRequest(usage = null, heldText = "x"), estimatedInput = null, rhoHi = 0.5)
        assertFalse(leg.usageReported)
        // Message input tokens are unknown (null, never 0) while the output estimate is still added.
        assertTrue(SkillTurn.interruptedInputUnknown(leg))
        assertEquals(ContextBudget.estimateText("x", 0.5), leg.completionTokens)
        val reply = SkillTurn.withInterruptedLeg(leg, ProviderChatResult(text = "answer", promptTokens = 10, completionTokens = 2))
        assertEquals(null, SkillTurn.replyUsage(reply, leg).inputTokens)
        assertEquals(2 + leg.completionTokens, reply.completionTokens)
        assertFalse(reply.usageReported)
    }

    @Test
    fun `stopped request and resend add up to the reply cost`() = runTest {
        val skillTurn = turn(Recorder())
        val stopped = ProviderChatResult(text = "marker", promptTokens = 100, completionTokens = 8, estimatedCost = 0.002,
            costSource = CostSource.UPSTREAM.name)
        val resend = ProviderChatResult(text = "answer", promptTokens = 150, completionTokens = 40, estimatedCost = 0.003,
            costSource = CostSource.UPSTREAM.name)
        skillTurn.gate(flowOf(StreamEvent.Done(stopped.copy(text = "\u27e6skill:$autoId | fits writing\u27e7")))) {
            flowOf(StreamEvent.Delta("answer"), StreamEvent.Done(resend))
        }.toList()
        val leg = skillTurn.chargeInterrupted(estimatedInput = null, rhoHi = 0.5)

        val reply = SkillTurn.withInterruptedLeg(leg, resend)
        assertEquals("answer", reply.text)
        assertEquals(250, reply.promptTokens)
        assertEquals(48, reply.completionTokens)
        assertEquals(0.005, reply.estimatedCost, 1e-12)
        assertEquals(2, reply.legs?.size)
        assertTrue(reply.usageReported)
    }

    @Test
    fun `turn without a marker hit keeps the reply unchanged`() = runTest {
        val skillTurn = turn(Recorder())
        skillTurn.gate(flowOf(StreamEvent.Delta("plain answer"), done("plain answer"))) { resendFlow }.toList()
        val reply = ProviderChatResult(text = "plain answer", promptTokens = 10, completionTokens = 2)

        assertEquals(null, skillTurn.interruptedRequest)
        assertEquals(null, skillTurn.chargeInterrupted(estimatedInput = 10, rhoHi = 0.5))
        assertSame(reply, SkillTurn.withInterruptedLeg(skillTurn.interruptedLeg, reply))
    }
}
