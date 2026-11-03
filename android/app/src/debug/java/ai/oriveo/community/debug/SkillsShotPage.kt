package ai.oriveo.community.debug

/**
 * Page names of the skills shot family (same on every end, case kept; the single source is the pages list
 * of the shared manifest skills.v1.json).
 * Usage: `adb shell am start -n ai.oriveo.community/ai.oriveo.community.debug.RelayFamilyShotsActivity --es AUTO_OPEN_PAGE <name>`
 * (shares the `:shots` entry with the relay family and is routed by page name).
 */
enum class SkillsShotPage(val wire: String) {
    SkillsHome("skillsHome"),
    SkillsHomeAmber("skillsHomeAmber"),
    SkillsHomeTeal("skillsHomeTeal"),
    SkillsHomeEmpty("skillsHomeEmpty"),
    SkillsHomeEmptyNoCatalog("skillsHomeEmptyNoCatalog"),
    SkillsHomeAutoOff("skillsHomeAutoOff"),
    SkillsMine("skillsMine"),
    SkillsMineAmber("skillsMineAmber"),
    SkillsMineTeal("skillsMineTeal"),
    SkillsMineEmpty("skillsMineEmpty"),
    SkillsDraftGenerating("skillsDraftGenerating"),
    SkillsTemplates("skillsTemplates"),
    SkillsTemplatesLoading("skillsTemplatesLoading"),
    SkillsTemplatesFailed("skillsTemplatesFailed"),
    SkillsDetail("skillsDetail"),
    SkillsDetailAmber("skillsDetailAmber"),
    SkillsDetailTeal("skillsDetailTeal"),
    SkillsEdit("skillsEdit"),
    SkillsEditAmber("skillsEditAmber"),
    SkillsEditTeal("skillsEditTeal"),
    SkillsEditDraftFailed("skillsEditDraftFailed"),
    SkillsEditNeedWhen("skillsEditNeedWhen"),
    SkillsComposer("skillsComposer"),
    SkillsComposerFull("skillsComposerFull"),
    SkillsUsed("skillsUsed"),
    SkillsHomePicker("skillsHomePicker"),
    SkillsImprovePrompt("skillsImprovePrompt"),
    SkillsImprovePromptAmber("skillsImprovePromptAmber"),
    SkillsImprovePromptTeal("skillsImprovePromptTeal"),
    SkillsImproveDiff("skillsImproveDiff"),
    SkillsImproveDiffAmber("skillsImproveDiffAmber"),
    SkillsImproveDiffTeal("skillsImproveDiffTeal"),
    SkillsTrial("skillsTrial"),
    SkillsTrialAmber("skillsTrialAmber"),
    SkillsTrialTeal("skillsTrialTeal"),
    SkillsTrialEmpty("skillsTrialEmpty"),
    SkillsTrialFailed("skillsTrialFailed"),
    SkillsUsageManifest("skillsUsageManifest"),
    SkillsUsageManifestAmber("skillsUsageManifestAmber"),
    SkillsUsageManifestTeal("skillsUsageManifestTeal"),
    SkillsTokenCost("skillsTokenCost"),
    SkillsEmptyReply("skillsEmptyReply"),
    ;

    companion object {
        /** Case-sensitive, surrounding whitespace ignored; unknown names return null (left to the other families). */
        fun parse(raw: String?): SkillsShotPage? {
            val value = raw?.trim().orEmpty()
            return entries.firstOrNull { it.wire == value }
        }
    }
}
