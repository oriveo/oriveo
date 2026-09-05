package ai.oriveo.community.feature.settings

import ai.oriveo.community.core.app.AppPreferencesRepository
import ai.oriveo.community.core.model.LanguageOption
import ai.oriveo.community.core.model.ThemeOption
import io.mockk.coEvery
import io.mockk.coVerify
import io.mockk.every
import io.mockk.just
import io.mockk.mockk
import io.mockk.runs
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Before
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class SettingsViewModelTest {

    private val dispatcher = StandardTestDispatcher()
    private val appPreferencesRepository = mockk<AppPreferencesRepository>()

    private val themeFlow = MutableStateFlow(ThemeOption.System)
    private val languageFlow = MutableStateFlow(LanguageOption.System)
    private val memoryTextFlow = MutableStateFlow("")
    private val memoryHasSeenFlow = MutableStateFlow(false)

    @Before
    fun setUp() {
        Dispatchers.setMain(dispatcher)

        every { appPreferencesRepository.theme } returns themeFlow
        every { appPreferencesRepository.language } returns languageFlow
        every { appPreferencesRepository.memoryText } returns memoryTextFlow
        every { appPreferencesRepository.memoryHasSeen } returns memoryHasSeenFlow
        coEvery { appPreferencesRepository.setTheme(any()) } just runs
        coEvery { appPreferencesRepository.setLanguage(any()) } just runs
    }

    @After
    fun tearDown() {
        Dispatchers.resetMain()
    }

    @Test
    fun `setTheme persists selection`() = runTest {
        val viewModel = SettingsViewModel(appPreferencesRepository)

        viewModel.setTheme(ThemeOption.Dark)
        advanceUntilIdle()

        coVerify { appPreferencesRepository.setTheme(ThemeOption.Dark) }
    }

    @Test
    fun `setLanguage persists selection`() = runTest {
        val viewModel = SettingsViewModel(appPreferencesRepository)

        viewModel.setLanguage(LanguageOption.Japanese)
        advanceUntilIdle()

        coVerify { appPreferencesRepository.setLanguage(LanguageOption.Japanese) }
    }
}
