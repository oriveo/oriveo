package ai.oriveo.community.feature.chat

import java.io.File
import org.junit.Assert.assertTrue
import org.junit.Test

private const val LOGICAL_LINE_BUDGET = 940

class ChatViewModelStructureTest {

    @Test
    fun `chat view model stays below its architecture line budget`() {
        val viewModelSource = File("src/main/java/ai/oriveo/community/feature/chat/ChatViewModel.kt").readText()

        // Orchestration logic lives in dedicated coordinators (send / retry / export / model
        // selection / drafts / conversation actions / notes / continuation / analytics); the
        // view model itself only wires things together and exposes state. The expensive-model
        // hint has its own file too.
        //
        // The unit counted is logical lines (imports, blank lines, and comment-only lines
        // excluded), not the file's raw line count, because those three categories carry zero
        // complexity and would otherwise eat into the budget for free -- and taxing comments
        // specifically punishes leaving in load-bearing notes about tricky invariants and race
        // conditions, which is a perverse incentive. Lines that just wire dependencies together
        // still count, since that is real complexity and shouldn't be lumped in with imports.
        //
        // This budget is a tripwire that triggers a review, not an architectural law. When it
        // fires, ask whether a new responsibility has quietly grown inside the view model: if
        // so, extract it into its own coordinator; if not, re-baseline and write down why. Avoid
        // re-baselining to land exactly on the line, which just repeats the same review cycle
        // without fixing anything.
        //
        // When re-baselining, leave a deliberate margin (roughly 6%) above the measured value
        // instead of sitting right on it -- landing exactly on the boundary defeats the
        // budget's purpose, since the next unrelated one-line addition trips it again for no
        // reason. A margin like this should still be sensitive enough to catch a genuinely new
        // responsibility, which typically adds on the order of 80-130 lines.
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
                "first ask whether a new responsibility has grown into the view model (extract a coordinator for it) instead of just raising the budget.",
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
        ).forEach { expected ->
            assertTrue("Expected ChatViewModel to reference $expected", viewModelSource.contains(expected))
        }
    }
}
