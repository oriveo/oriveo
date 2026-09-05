package ai.oriveo.community.feature.chat

import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class MessageSelectionHierarchyContractTest {

    @Test
    fun userMessageSelectionIsStructurallyLimitedToBodyText() {
        val source = File("src/main/java/ai/oriveo/community/feature/chat/components/MessageBubble.kt")
            .readText()
        val selectableText = sourceBlock(source, "SelectableUserMessageText")

        assertTrue(
            "User message body must retain native Compose text selection.",
            selectableText.contains("SelectionContainer(modifier = selectionModifier)"),
        )
        assertTrue(
            "The selection boundary must own the body Text instead of accepting arbitrary UI.",
            selectableText.contains("Text(") && selectableText.contains("text = text"),
        )
        assertFalse(
            "An arbitrary composable slot could reintroduce Popup or sheet roots into the message selection registrar.",
            selectableText.contains("content: @Composable"),
        )
        assertFalse(
            "Attachments must stay outside the user body selection hierarchy.",
            selectableText.contains("MessageAttachmentList("),
        )
        assertFalse(
            "Quote popup content must stay outside the user body selection hierarchy.",
            selectableText.contains("QuoteContextChip("),
        )
    }

    @Test
    fun crossWindowChatSurfacesClearInheritedSelectionRegistrars() {
        val imageViewer = File("src/main/java/ai/oriveo/community/ui/component/ImageViewerSheet.kt")
            .readText()
        val quoteChip = File("src/main/java/ai/oriveo/community/feature/chat/components/QuoteContextChip.kt")
            .readText()
        val codeBlock = File("src/main/java/ai/oriveo/community/ui/component/markdown/CodeBlockCard.kt")
            .readText()

        assertTrue(
            "ModalBottomSheet must clear a parent SelectionContainer before creating its separate layout root.",
            imageViewer.contains("DisableSelection {\n        ModalBottomSheet("),
        )
        assertTrue(
            "DropdownMenu must clear a parent SelectionContainer before creating its Popup layout root.",
            quoteChip.contains("DisableSelection {\n            DropdownMenu("),
        )
        assertTrue(
            "The full-screen code sheet must clear the message SelectionContainer before creating its layout root.",
            codeBlock.contains("DisableSelection {\n        ModalBottomSheet("),
        )
        assertTrue(
            "Full-screen code must retain selection through a sheet-local SelectionContainer.",
            codeBlock.contains("SelectionContainer(\n                    modifier = Modifier"),
        )
    }

    private fun sourceBlock(source: String, functionName: String): String {
        val start = source.indexOf("private fun $functionName(")
        assertTrue("$functionName must exist", start >= 0)
        val next = source.indexOf("\n@Composable", start + 1)
        return if (next >= 0) source.substring(start, next) else source.substring(start)
    }
}
