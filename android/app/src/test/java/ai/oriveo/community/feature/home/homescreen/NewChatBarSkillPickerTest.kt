package ai.oriveo.community.feature.home.homescreen

import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTextInput
import ai.oriveo.community.R
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.ModelCapability
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderConnectionState
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.Skill
import ai.oriveo.community.core.model.SkillSyncFields
import ai.oriveo.community.feature.chat.composer.SkillComposerChipsModel
import ai.oriveo.community.feature.home.HomeViewModel
import ai.oriveo.community.ui.theme.OriveoTheme
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.MutableStateFlow
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/** Home hero composer: `/` opens the same skill picker as the chat composer and a pick becomes a pending chip. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class NewChatBarSkillPickerTest {

    @get:Rule
    val composeRule = createEmptyComposeRule()

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)

    @After
    fun tearDown() {
        scope.cancel()
    }

    private fun activeModel(): HomeViewModel.ActiveModel {
        val model = AIModel(id = "gpt-4o-mini", name = "GPT-4o mini", isDefault = true, capabilities = listOf(ModelCapability.Text))
        return HomeViewModel.ActiveModel(
            provider = Provider(
                id = "provider-1",
                kind = ProviderKind.OpenAI,
                status = ProviderConnectionState.Connected,
                models = listOf(model),
            ),
            model = model,
        )
    }

    private fun chips(
        skills: List<Skill> = listOf(Skill(id = "s-gym", name = "Gym coach", systemPrompt = "Coach me.")),
    ) = SkillComposerChipsModel(
        scope = scope,
        userSkills = MutableStateFlow(skills),
        templates = MutableStateFlow(emptyList()),
        writeSkillIds = { _, ids -> ids },
        track = { _, _ -> },
    )

    private fun render(model: SkillComposerChipsModel): ComponentActivity {
        var text by mutableStateOf("")
        val activity = Robolectric.buildActivity(ComponentActivity::class.java).setup().get()
        activity.setContent {
            OriveoTheme(darkTheme = false) {
                NewChatBar(
                    activeModel = activeModel(),
                    hasProvider = true,
                    isDark = false,
                    heroText = text,
                    onHeroTextChange = { text = it },
                    isSendingFromHero = false,
                    isSearchActive = false,
                    onSend = {},
                    onModelSelect = {},
                    onAddProvider = {},
                    skillChips = model,
                )
            }
        }
        composeRule.waitForIdle()
        return activity
    }

    @Test
    fun slash_opens_picker() {
        val activity = render(chips())
        val title = activity.getString(R.string.skills_picker_title)
        composeRule.onNodeWithText(title).assertDoesNotExist()

        composeRule.onNodeWithTag("home_composer_input").performTextInput("/")
        composeRule.waitForIdle()
        composeRule.onNodeWithText(title).assertExists()
        composeRule.onNodeWithText("Gym coach").assertExists()
    }

    @Test
    fun pick_adds_chip() {
        val model = chips()
        val activity = render(model)
        composeRule.onNodeWithTag("home_composer_input").performTextInput("/")
        composeRule.waitForIdle()
        composeRule.onNodeWithText("Gym coach").performClick()
        composeRule.waitForIdle()

        // The picker closes and the pick is a pending chip of the conversation the first send creates.
        composeRule.onNodeWithText(activity.getString(R.string.skills_picker_title)).assertDoesNotExist()
        assertEquals(listOf("s-gym"), model.pendingSkillIds)
        composeRule.onNodeWithText("Gym coach").assertExists()
    }

    @Test
    fun full_picker_header_shows_only_max_reached() {
        val skills = (1..4).map { Skill(id = "s-$it", name = "Skill $it", systemPrompt = "Prompt $it.") }
        val model = chips(skills)
        val activity = render(model)
        skills.take(SkillSyncFields.SKILL_IDS_MAX).forEach { model.attach(it.id, "slash", null, emptyList()) }
        composeRule.onNodeWithTag("home_composer_input").performTextInput("/")
        composeRule.waitForIdle()

        // At the cap the max notice replaces the multi-select hint instead of sitting beside it.
        composeRule.onNodeWithText(activity.getString(R.string.skills_picker_maxReached, SkillSyncFields.SKILL_IDS_MAX)).assertExists()
        composeRule.onNodeWithText(activity.getString(R.string.skills_picker_multi)).assertDoesNotExist()
    }
}
