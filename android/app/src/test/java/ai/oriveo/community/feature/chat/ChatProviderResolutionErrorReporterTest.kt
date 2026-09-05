package ai.oriveo.community.feature.chat

import android.content.Context
import ai.oriveo.community.R
import ai.oriveo.community.core.app.GlobalSnackbarManager
import ai.oriveo.community.core.app.GlobalSnackbarMessage
import ai.oriveo.community.core.app.GlobalToastStyle
import ai.oriveo.community.core.app.UiText
import ai.oriveo.community.core.model.ProviderServiceError
import ai.oriveo.community.core.provider.RelayErrorMapper
import io.mockk.every
import io.mockk.mockk
import io.mockk.verify
import org.junit.Assert.assertTrue
import org.junit.Test

class ChatProviderResolutionErrorReporterTest {

    @Test
    fun `relay error produced by classifier reaches snackbar through stable guidance code`() {
        val context: Context = mockk()
        val snackbarManager: GlobalSnackbarManager = mockk(relaxed = true)
        every { context.getString(R.string.relay_guidance_rate_limited) } returns "Localized rate limit guidance"
        val error = RelayErrorMapper.classify(
            status = 429,
            body = """{"error":{"message":"rate limit"}}""",
        )
        assertTrue(error is ProviderServiceError.RelayUpstream)

        ChatProviderResolutionErrorReporter(context, snackbarManager).show(error!!)

        verify(exactly = 1) {
            snackbarManager.show(
                GlobalSnackbarMessage(
                    message = UiText.Dynamic("Localized rate limit guidance"),
                    style = GlobalToastStyle.Error,
                ),
            )
        }
    }
}
