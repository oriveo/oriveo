package ai.oriveo.community.feature.chat

import java.io.File
import org.junit.Assert.assertTrue
import org.junit.Test

private const val LOGICAL_LINE_BUDGET = 1060

class ChatViewModelStructureTest {

    @Test
    fun `chat view model stays below its architecture line budget`() {
        val viewModelSource = File("src/main/java/ai/oriveo/community/feature/chat/ChatViewModel.kt").readText()

        // Extraction: orchestration logic is spread across the coordinators (send / retry / export / model selection / drafts / conversation actions /
        // notes / managed / analytics), and the VM only does assembly + state exposure. The expensive-model hint is also extracted to ExpensiveModelHint.kt.
        //
        // Metric = logical lines (excluding imports / blank lines / comment-only lines), not the file's total line count. Reasons:
        // (1) Under the old metric, 29% of the total was imports (58) + blank lines (120) + comments (112): zero complexity, yet it consumed the budget;
        // (2) The old metric **taxed comments**: it pushed people to delete load-bearing pitfall notes to free up quota (e.g. the hasMoreBelow
        //   Eagerly cold-flow invariant and the stopGeneration read-ordering race warning), which is a perverse incentive;
        // (3) The old `lineSequence().count()` counted one extra line for files ending in \n (a nominal 1000 was really 999).
        // Wiring lines still count: they are real complexity, they just should not be lumped together with imports.
        //
        // Purpose: this is a tripwire that triggers one review, not an architecture rule. When it fires, ask "has a new domain quietly grown into
        // the VM?": if yes, extract it (e.g. ChatManagedCoordinator was extracted on 2026-07-15); if no, re-baseline and state the reason.
        // Do not extract just to land exactly on the line (historically it turned red 9 times in 6 weeks, each time green landing 0~3 lines under the ceiling = Goodhart's law).
        //
        // 2026-07-25 baseline 780 -> 880, and ChatLibraryCoordinator was extracted at the same time. Both were done this time, for these reasons:
        // (1) The review concluded "a new domain has grown in" = confirmed. The library is a new domain: 724f828a7 (research pipeline) pushed the VM from 735 to
        //    805 (red), and e0864c48c (direct context) pushed it further to 914. After extracting ChatLibraryCoordinator it fell back to 828,
        //    and the -86 lines were almost entirely the library domain, which confirms the diagnosis.
        // (2) Of the remaining 828-709 (the measured value at the previous baseline) = 119, after subtracting the 86 library lines there are still ~33 lines, coming from
        //    the **scattered accumulation** of 5 commits: managed continued generation / read-only backfill on Pro expiry / signed-out second-entry guidance, etc. --
        //    there is no second cohesive domain to extract, and forcing an extraction would only create a coordinator in name only. This is exactly the case
        //    described above as "otherwise re-baseline".
        // (3) The new baseline deliberately leaves ~6% headroom (828 -> 880) instead of sitting at 830: sitting right on the line is the Goodhart trap warned about above.
        //    880 is still sensitive enough: a new domain is typically 80~130 lines, so it is bound to hit the line when it lands.
        //
        // 2026-08-07 baseline 880 -> 940 (triggered as a side effect of the fix for pure heartbeat during long thinking). Walked through the process above:
        // (1) The review concluded "a new domain has grown in" = **not confirmed**. The only addition is one per-session `streamingReasoningActive`
        //    stream exposure, and the adjacent streamingText / streamingReasoning belong to the same domain
        //    (streaming state exposure), not something that can stand alone as a coordinator.
        // (2) What should be extracted already was: the `combine(activeConversationId, sessionsVersion) → flatMapLatest`
        //    re-subscription orchestration sank into ChatStreamingManager.reasoningActiveFlow (conversation semantics belong to it),
        //    leaving the VM with 3 lines of `.stateIn` wrap-up -- 879 -> 882, a real increase of only 3 lines.
        // (3) Why the baseline had to move: the number 880 pinned the file at 879/880, leaving 1 line of headroom, so any new public state
        //    would hit the line -- exactly the Goodhart state warned about at the top (the previous baseline was set too close to the edge).
        //    882 -> 940 restores ~6% headroom, using the same method as the previous 828 -> 880; 940 still catches a new domain of 80~130 lines.
        //
        // 2026-10-01 baseline 940 -> 1000 (triggered by the streaming activity status line). Same process:
        // (1) The review concluded "a new domain has grown in" = **not confirmed**. The only addition is one per-session `streamingActivity`
        //    stream exposure, in the same domain as the adjacent streamingText / streamingReasoning / streamingReasoningActive.
        // (2) What should sink has sunk: the re-subscription orchestration is in ChatStreamingManager.streamingActivityFlow, and the VM has only 3 lines
        //    of `.stateIn` wrap-up -- 940 -> 943.
        // (3) Why the baseline had to move: before the change the file was exactly 940/940 with zero headroom, so any new public state would hit the line (back to the
        //    edge-hugging state warned about above). 943 -> 1000 restores ~6% headroom, the same method as the previous two.
        //
        // 2026-10-30 baseline 1000 -> 1060 (Skills revamp composer chips).
        // (1) A new domain did grow in (composer skill chips, picker cache, used-skill actions), so it was
        //     extracted: SkillComposerChipsModel.forChat owns the wiring and disableAutoInCurrent, the VM keeps
        //     one property and one hook into the send coordinator - 1000 -> 1002.
        // (2) The file was already at 1000/1000 before this change, zero headroom again; 1002 -> 1060 restores
        //     ~6% the same way as the previous two raises.
        val logicalLines = viewModelSource.lineSequence().count { line ->
            val trimmed = line.trim()
            trimmed.isNotEmpty() &&
                !trimmed.startsWith("import ") &&
                !trimmed.startsWith("//") &&
                !trimmed.startsWith("*") &&
                !trimmed.startsWith("/*")
        }

        assertTrue(
            "ChatViewModel.kt has $logicalLines logical lines, over the $LOGICAL_LINE_BUDGET budget -- " +
                "first ask whether a new domain has grown into the view model (extract a coordinator if so), instead of simply raising the budget.",
            logicalLines <= LOGICAL_LINE_BUDGET,
        )
    }

    @Test
    fun `chat view model delegates extracted orchestration responsibilities`() {
        val viewModelSource = File("src/main/java/ai/oriveo/community/feature/chat/ChatViewModel.kt").readText()

        listOf(
            "ChatSendCoordinator(",
            "ChatSendCommandCoordinator(",
            "ChatAttachmentCoordinator(",
            "ChatRetryCoordinator(",
            "ChatExportCoordinator(",
            "ChatModelSelectionCoordinator(",
            "ChatDraftCoordinator(",
            "ChatConversationActions(",
            "ChatNoteCoordinator(",
            "ChatManagedCoordinator(",
            "ChatLibraryCoordinator(",
            "ChatTelemetryReporter(",
            "ChatMessageWindowCoordinator(",
        ).forEach { expected ->
            assertTrue("Expected ChatViewModel to reference $expected", viewModelSource.contains(expected))
        }
    }
}
