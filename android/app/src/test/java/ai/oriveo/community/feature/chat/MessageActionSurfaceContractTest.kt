package ai.oriveo.community.feature.chat

import ai.oriveo.community.core.model.ChatMessageState
import ai.oriveo.community.feature.chat.components.shouldShowAssistantFooterActions
import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class MessageActionSurfaceContractTest {

    @Test
    fun `assistant footer waits for visual rendering to settle`() {
        assertFalse(
            shouldShowAssistantFooterActions(
                messageState = ChatMessageState.Generating,
                hasText = true,
                isBodyRenderSettled = true,
            ),
        )
        assertFalse(
            shouldShowAssistantFooterActions(
                messageState = ChatMessageState.Delivered,
                hasText = true,
                isBodyRenderSettled = false,
            ),
        )
        assertTrue(
            shouldShowAssistantFooterActions(
                messageState = ChatMessageState.Delivered,
                hasText = true,
                isBodyRenderSettled = true,
            ),
        )

        val bubbleSource = File("src/main/java/ai/oriveo/community/feature/chat/components/MessageBubble.kt")
            .readText()
        val markdownSource = File("src/main/java/ai/oriveo/community/ui/component/markdown/MarkdownMessageView.kt")
            .readText()
        assertTrue(
            "assistant footer readiness must consume the real markdown render phase",
            bubbleSource.contains("onRenderStreamingChanged = { renderStreaming ->"),
        )
        assertTrue(
            "markdown renderer must publish defer-finish phase changes",
            markdownSource.contains("onRenderStreamingChanged?.invoke(renderStreaming)"),
        )
    }

    @Test
    fun assistantFooterUsesCopySaveAndMoreInsteadOfInlineRegenerateIcon() {
        val source = File("src/main/java/ai/oriveo/community/feature/chat/components/MessageBubble.kt")
            .readText()

        assertTrue(
            "assistant footer must expose a dedicated action row",
            source.contains("AssistantFooterActionRow("),
        )
        assertTrue(
            "assistant footer must show the same Save as Note label used across note capture",
            source.contains("R.string.notes_chat_save_as_note"),
        )
        assertTrue(
            "assistant footer must use a More entry for secondary actions",
            source.contains("Icons.Filled.MoreHoriz"),
        )
        assertTrue(
            "secondary regenerate must live in the More menu with text",
            source.contains("R.string.regenerate"),
        )
        assertTrue(
            "secondary cross-check must live in the More menu with text",
            source.contains("R.string.notes_chat_crosscheck_action"),
        )
    }

    @Test
    fun assistantFooterCustomControlsExposeButtonSemantics() {
        val source = File("src/main/java/ai/oriveo/community/feature/chat/components/MessageBubble.kt")
            .readText()
        val footerActionButton = sourceBlock(source, "FooterActionButton")
        val footerIconButton = sourceBlock(source, "FooterIconButton")

        assertTrue(
            "custom footer controls must import Compose Role for accessibility services",
            source.contains("import androidx.compose.ui.semantics.Role"),
        )
        assertTrue(
            "text footer actions such as Save as Note must expose Role.Button semantics",
            footerActionButton.contains("role = Role.Button"),
        )
        assertTrue(
            "icon-only More action must expose Role.Button semantics",
            footerIconButton.contains("role = Role.Button"),
        )
    }

    @Test
    fun savedNoteStatusUsesTheSameFooterMetricsAsAssistantActions() {
        val bubbleSource = File("src/main/java/ai/oriveo/community/feature/chat/components/MessageBubble.kt")
            .readText()
        val actionRow = sourceBlock(bubbleSource, "AssistantFooterActionRow")
        val recoverySource = File("src/main/java/ai/oriveo/community/feature/chat/recovery/MessageItemWithActions.kt")
            .readText()
        val savedNoteBlock = recoverySource.substring(
            recoverySource.indexOf("if (savedNoteLinks.isNotEmpty())"),
            recoverySource.indexOf("// Failed recovery card", recoverySource.indexOf("if (savedNoteLinks.isNotEmpty())")),
        )

        assertTrue(
            "assistant footer action row must use the shared footer optical offset",
            actionRow.contains("AssistantMessageFooterMetrics.RowOpticalOffset"),
        )
        assertTrue(
            "saved-note status row must start from the same assistant footer column as action rows",
            savedNoteBlock.contains("AssistantMessageFooterMetrics.AbsoluteContentStart"),
        )
        assertTrue(
            "saved-note status row must use the same optical offset as the copy action row",
            savedNoteBlock.contains("AssistantMessageFooterMetrics.RowOpticalOffset"),
        )
        assertTrue(
            "saved-note status icon must use the same visual size as footer action icons",
            savedNoteBlock.contains("AssistantMessageFooterMetrics.IconSize"),
        )
        assertFalse(
            "saved-note status must not keep its old bespoke assistant start padding",
            savedNoteBlock.contains("start = if (message.role == ChatRole.Assistant) 30.dp else 24.dp"),
        )
        assertFalse(
            "saved-note status icon must not keep the old smaller 13dp size",
            savedNoteBlock.contains("Modifier.size(13.dp)"),
        )
    }

    @Test
    fun noteSaveEntrancesUseNoteAddNotBookmarkAdd() {
        val files = listOf(
            File("src/main/java/ai/oriveo/community/ui/component/markdown/CodeBlockCard.kt"),
            File("src/main/java/ai/oriveo/community/feature/chat/recovery/MessageItemWithActions.kt"),
            File("src/main/java/ai/oriveo/community/feature/chat/components/MessageBubble.kt"),
        )

        files.forEach { file ->
            val source = file.readText()
            assertFalse(
                "${file.name} must not use BookmarkAdd for note capture actions",
                source.contains("BookmarkAdd"),
            )
        }

        assertTrue(
            "code block save must use the note-plus icon",
            files[0].readText().contains("Icons.AutoMirrored.Outlined.NoteAdd"),
        )
        assertTrue(
            "message menus and saved-note chips must use note icons, not bookmark icons",
            files[1].readText().contains("Icons.AutoMirrored.Outlined.NoteAdd"),
        )
    }

    @Test
    fun textSelectionToolbarSuppressesTheOuterMessageMenu() {
        val itemSource = File("src/main/java/ai/oriveo/community/feature/chat/recovery/MessageItemWithActions.kt")
            .readText()
        val bubbleSource = File("src/main/java/ai/oriveo/community/feature/chat/components/MessageBubble.kt")
            .readText()
        val markdownSource = File("src/main/java/ai/oriveo/community/ui/component/markdown/MarkdownMessageView.kt")
            .readText()
        val toolbarSource = File("src/main/java/ai/oriveo/community/ui/component/markdown/NoteSelectionTextToolbar.kt")
            .readText()

        assertTrue(
            "Message item must receive text selection toolbar visibility from inner selectable text",
            itemSource.contains("onSelectionToolbarVisibleChange"),
        )
        assertTrue(
            "Opening the text selection toolbar must close the outer DropdownMenu to avoid two menus at once",
            itemSource.contains("if (visible) showMenu = false"),
        )
        assertTrue(
            "Outer long-press menu must not open immediately before the text toolbar can claim the gesture",
            itemSource.contains("delay(TEXT_SELECTION_OUTER_MENU_GUARD_MS)"),
        )
        assertTrue(
            "Opening text selection must cancel the pending outer message menu to prevent a toolbar-then-menu flash",
            itemSource.contains("pendingMessageMenuJob?.cancel()"),
        )
        assertTrue(
            "Pointer down inside selectable text must suppress the outer menu before ActionMode becomes visible",
            itemSource.contains("selectionGestureActive"),
        )
        assertTrue(
            "Selectable message text must report selection gesture activity before the system toolbar appears",
            bubbleSource.contains("onSelectionGestureActiveChange"),
        )
        assertTrue(
            "Assistant markdown text must also suppress the outer menu from pointer down, not only after ActionMode",
            markdownSource.contains("SelectionContainer(modifier = selectionModifier)"),
        )
        assertTrue(
            "User messages must inject the same note-aware selection toolbar as assistant text",
            bubbleSource.contains("rememberNoteSelectionTextToolbar("),
        )
        assertTrue(
            "The selection toolbar must notify when it is shown",
            toolbarSource.contains("onVisibilityChange(true)"),
        )
    }

    private fun sourceBlock(source: String, functionName: String): String {
        val start = source.indexOf("private fun $functionName(")
        assertTrue("$functionName must exist in MessageBubble.kt", start >= 0)
        val next = source.indexOf("\n@Composable", start + 1)
        return if (next >= 0) source.substring(start, next) else source.substring(start)
    }
}
