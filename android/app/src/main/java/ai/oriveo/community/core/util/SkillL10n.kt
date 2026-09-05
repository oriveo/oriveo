package ai.oriveo.community.core.util

import androidx.annotation.StringRes
import androidx.compose.runtime.Composable
import androidx.compose.ui.res.stringResource
import ai.oriveo.community.R
import ai.oriveo.community.core.model.Skill

object SkillL10n {
    @StringRes
    fun nameRes(key: String?): Int? = when (key) {
        "code_assistant" -> R.string.skill_code_assistant_name
        "code_review" -> R.string.skill_code_review_name
        "sql_expert" -> R.string.skill_sql_expert_name
        "git_assistant" -> R.string.skill_git_assistant_name
        "writing_coach" -> R.string.skill_writing_coach_name
        "email_assistant" -> R.string.skill_email_assistant_name
        "copywriting" -> R.string.skill_copywriting_name
        "blog_writer" -> R.string.skill_blog_writer_name
        "translation_expert" -> R.string.skill_translation_expert_name
        "proofreader" -> R.string.skill_proofreader_name
        "learning_tutor" -> R.string.skill_learning_tutor_name
        "research_assistant" -> R.string.skill_research_assistant_name
        "language_teacher" -> R.string.skill_language_teacher_name
        "data_analyst" -> R.string.skill_data_analyst_name
        "math_tutor" -> R.string.skill_math_tutor_name
        "document_summarizer" -> R.string.skill_document_summarizer_name
        "brainstorm" -> R.string.skill_brainstorm_name
        "story_creator" -> R.string.skill_story_creator_name
        "meeting_notes" -> R.string.skill_meeting_notes_name
        "interview_coach" -> R.string.skill_interview_coach_name
        "presentation_outliner" -> R.string.skill_presentation_outliner_name
        "recipe_assistant" -> R.string.skill_recipe_assistant_name
        "travel_planner" -> R.string.skill_travel_planner_name
        "fitness_coach" -> R.string.skill_fitness_coach_name
        "image_analyst" -> R.string.skill_image_analyst_name
        else -> null
    }

    @StringRes
    fun descRes(key: String?): Int? = when (key) {
        "code_assistant" -> R.string.skill_code_assistant_desc
        "code_review" -> R.string.skill_code_review_desc
        "sql_expert" -> R.string.skill_sql_expert_desc
        "git_assistant" -> R.string.skill_git_assistant_desc
        "writing_coach" -> R.string.skill_writing_coach_desc
        "email_assistant" -> R.string.skill_email_assistant_desc
        "copywriting" -> R.string.skill_copywriting_desc
        "blog_writer" -> R.string.skill_blog_writer_desc
        "translation_expert" -> R.string.skill_translation_expert_desc
        "proofreader" -> R.string.skill_proofreader_desc
        "learning_tutor" -> R.string.skill_learning_tutor_desc
        "research_assistant" -> R.string.skill_research_assistant_desc
        "language_teacher" -> R.string.skill_language_teacher_desc
        "data_analyst" -> R.string.skill_data_analyst_desc
        "math_tutor" -> R.string.skill_math_tutor_desc
        "document_summarizer" -> R.string.skill_document_summarizer_desc
        "brainstorm" -> R.string.skill_brainstorm_desc
        "story_creator" -> R.string.skill_story_creator_desc
        "meeting_notes" -> R.string.skill_meeting_notes_desc
        "interview_coach" -> R.string.skill_interview_coach_desc
        "presentation_outliner" -> R.string.skill_presentation_outliner_desc
        "recipe_assistant" -> R.string.skill_recipe_assistant_desc
        "travel_planner" -> R.string.skill_travel_planner_desc
        "fitness_coach" -> R.string.skill_fitness_coach_desc
        "image_analyst" -> R.string.skill_image_analyst_desc
        else -> null
    }

    fun starterRes(key: String?): IntArray? = when (key) {
        "code_assistant" -> intArrayOf(
            R.string.skill_code_assistant_starter_0,
            R.string.skill_code_assistant_starter_1,
            R.string.skill_code_assistant_starter_2,
            R.string.skill_code_assistant_starter_3,
        )
        "code_review" -> intArrayOf(
            R.string.skill_code_review_starter_0,
            R.string.skill_code_review_starter_1,
            R.string.skill_code_review_starter_2,
            R.string.skill_code_review_starter_3,
        )
        "sql_expert" -> intArrayOf(
            R.string.skill_sql_expert_starter_0,
            R.string.skill_sql_expert_starter_1,
            R.string.skill_sql_expert_starter_2,
            R.string.skill_sql_expert_starter_3,
        )
        "git_assistant" -> intArrayOf(
            R.string.skill_git_assistant_starter_0,
            R.string.skill_git_assistant_starter_1,
            R.string.skill_git_assistant_starter_2,
            R.string.skill_git_assistant_starter_3,
        )
        "writing_coach" -> intArrayOf(
            R.string.skill_writing_coach_starter_0,
            R.string.skill_writing_coach_starter_1,
            R.string.skill_writing_coach_starter_2,
            R.string.skill_writing_coach_starter_3,
        )
        "email_assistant" -> intArrayOf(
            R.string.skill_email_assistant_starter_0,
            R.string.skill_email_assistant_starter_1,
            R.string.skill_email_assistant_starter_2,
            R.string.skill_email_assistant_starter_3,
        )
        "copywriting" -> intArrayOf(
            R.string.skill_copywriting_starter_0,
            R.string.skill_copywriting_starter_1,
            R.string.skill_copywriting_starter_2,
            R.string.skill_copywriting_starter_3,
        )
        "blog_writer" -> intArrayOf(
            R.string.skill_blog_writer_starter_0,
            R.string.skill_blog_writer_starter_1,
            R.string.skill_blog_writer_starter_2,
            R.string.skill_blog_writer_starter_3,
        )
        "translation_expert" -> intArrayOf(
            R.string.skill_translation_expert_starter_0,
            R.string.skill_translation_expert_starter_1,
            R.string.skill_translation_expert_starter_2,
            R.string.skill_translation_expert_starter_3,
        )
        "proofreader" -> intArrayOf(
            R.string.skill_proofreader_starter_0,
            R.string.skill_proofreader_starter_1,
            R.string.skill_proofreader_starter_2,
            R.string.skill_proofreader_starter_3,
        )
        "learning_tutor" -> intArrayOf(
            R.string.skill_learning_tutor_starter_0,
            R.string.skill_learning_tutor_starter_1,
            R.string.skill_learning_tutor_starter_2,
            R.string.skill_learning_tutor_starter_3,
        )
        "research_assistant" -> intArrayOf(
            R.string.skill_research_assistant_starter_0,
            R.string.skill_research_assistant_starter_1,
            R.string.skill_research_assistant_starter_2,
            R.string.skill_research_assistant_starter_3,
        )
        "language_teacher" -> intArrayOf(
            R.string.skill_language_teacher_starter_0,
            R.string.skill_language_teacher_starter_1,
            R.string.skill_language_teacher_starter_2,
            R.string.skill_language_teacher_starter_3,
        )
        "data_analyst" -> intArrayOf(
            R.string.skill_data_analyst_starter_0,
            R.string.skill_data_analyst_starter_1,
            R.string.skill_data_analyst_starter_2,
            R.string.skill_data_analyst_starter_3,
        )
        "math_tutor" -> intArrayOf(
            R.string.skill_math_tutor_starter_0,
            R.string.skill_math_tutor_starter_1,
            R.string.skill_math_tutor_starter_2,
            R.string.skill_math_tutor_starter_3,
        )
        "document_summarizer" -> intArrayOf(
            R.string.skill_document_summarizer_starter_0,
            R.string.skill_document_summarizer_starter_1,
            R.string.skill_document_summarizer_starter_2,
            R.string.skill_document_summarizer_starter_3,
        )
        "brainstorm" -> intArrayOf(
            R.string.skill_brainstorm_starter_0,
            R.string.skill_brainstorm_starter_1,
            R.string.skill_brainstorm_starter_2,
            R.string.skill_brainstorm_starter_3,
        )
        "story_creator" -> intArrayOf(
            R.string.skill_story_creator_starter_0,
            R.string.skill_story_creator_starter_1,
            R.string.skill_story_creator_starter_2,
            R.string.skill_story_creator_starter_3,
        )
        "meeting_notes" -> intArrayOf(
            R.string.skill_meeting_notes_starter_0,
            R.string.skill_meeting_notes_starter_1,
            R.string.skill_meeting_notes_starter_2,
            R.string.skill_meeting_notes_starter_3,
        )
        "interview_coach" -> intArrayOf(
            R.string.skill_interview_coach_starter_0,
            R.string.skill_interview_coach_starter_1,
            R.string.skill_interview_coach_starter_2,
            R.string.skill_interview_coach_starter_3,
        )
        "presentation_outliner" -> intArrayOf(
            R.string.skill_presentation_outliner_starter_0,
            R.string.skill_presentation_outliner_starter_1,
            R.string.skill_presentation_outliner_starter_2,
            R.string.skill_presentation_outliner_starter_3,
        )
        "recipe_assistant" -> intArrayOf(
            R.string.skill_recipe_assistant_starter_0,
            R.string.skill_recipe_assistant_starter_1,
            R.string.skill_recipe_assistant_starter_2,
            R.string.skill_recipe_assistant_starter_3,
        )
        "travel_planner" -> intArrayOf(
            R.string.skill_travel_planner_starter_0,
            R.string.skill_travel_planner_starter_1,
            R.string.skill_travel_planner_starter_2,
            R.string.skill_travel_planner_starter_3,
        )
        "fitness_coach" -> intArrayOf(
            R.string.skill_fitness_coach_starter_0,
            R.string.skill_fitness_coach_starter_1,
            R.string.skill_fitness_coach_starter_2,
            R.string.skill_fitness_coach_starter_3,
        )
        "image_analyst" -> intArrayOf(
            R.string.skill_image_analyst_starter_0,
            R.string.skill_image_analyst_starter_1,
            R.string.skill_image_analyst_starter_2,
            R.string.skill_image_analyst_starter_3,
        )
        else -> null
    }

    @StringRes
    fun categoryNameRes(categoryId: String?): Int? = when (categoryId) {
        "coding" -> R.string.skill_category_coding
        "writing" -> R.string.skill_category_writing
        "translation" -> R.string.skill_category_translation
        "learning" -> R.string.skill_category_learning
        "analysis" -> R.string.skill_category_analysis
        "creative" -> R.string.skill_category_creative
        "work" -> R.string.skill_category_work
        "life" -> R.string.skill_category_life
        "image" -> R.string.skill_category_image
        else -> null
    }
}

@Composable
fun Skill.localizedName(): String {
    if (!isBuiltIn || key == null) return name
    val resId = SkillL10n.nameRes(key) ?: return name
    return stringResource(resId)
}

@Composable
fun Skill.localizedDescription(): String {
    if (!isBuiltIn || key == null) return description
    val resId = SkillL10n.descRes(key) ?: return description
    return stringResource(resId)
}

@Composable
fun Skill.localizedStarterMessages(): List<String> {
    if (!isBuiltIn || key == null) return starterMessages
    val resIds = SkillL10n.starterRes(key) ?: return starterMessages
    return starterMessages.mapIndexed { i, fallback ->
        if (i < resIds.size) stringResource(resIds[i]) else fallback
    }
}
