package ai.oriveo.community.core.util

import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test


class ExternalLaunchCallSiteContractTest {
    @Test
    fun `all user-facing external launch call sites keep safe launch and failure feedback`() {
        val contracts = listOf(
            Contract("ai/oriveo/community/ui/component/LegalLinks.kt", "openExternalUrl", "link_open_failed_message"),
            Contract("ai/oriveo/community/feature/chat/components/CitationsBlock.kt", "openExternalUrl", "link_open_failed_message"),
            Contract("ai/oriveo/community/feature/providers/detail/CustomRequestFieldsPage.kt", "openExternalUrl", "link_open_failed_message"),
            Contract("ai/oriveo/community/feature/providers/SubscriptionVerificationPage.kt", "launchExternalActivitySafely", "link_open_failed_message"),
            Contract("ai/oriveo/community/ui/component/markdown/MarkdownMessageView.kt", "openExternalUrl", "link_open_failed_message"),
            Contract("ai/oriveo/community/feature/storage/StorageSettingsLauncher.kt", "launchExternalActivitySafely", "external_app_unavailable"),
        )

        contracts.forEach { contract ->
            val source = File("src/main/java/${contract.path}").readText()
            assertTrue("${contract.path} must use ${contract.safeLaunch}", source.contains(contract.safeLaunch))
            assertTrue("${contract.path} must show ${contract.feedback}", source.contains(contract.feedback))
            assertFalse(
                "${contract.path} must not silently swallow startActivity failures",
                source.contains("runCatching { context.startActivity"),
            )
        }
    }

    private data class Contract(
        val path: String,
        val safeLaunch: String,
        val feedback: String,
    )
}
