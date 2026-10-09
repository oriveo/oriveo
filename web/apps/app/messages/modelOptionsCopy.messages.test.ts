import { readdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { IntlMessageFormat } from 'intl-messageformat';
import { describe, expect, it } from 'vitest';
import { LOCAL_ENGINE_PROFILES } from '../lib/core/chat/local-engine-profiles';
import { generationParameterTitleKey } from '../lib/core/chat/model-options-copy';

// Copy for model options / advanced settings / the additional request body is carried in all 16 languages verbatim;
// this locks that every imported key exists in all 16 languages, is non-empty, has consistent placeholder parameters, and that every parameter in the local-engine table has a title.
const IMPORTED_KEYS = [
  'modelOptionsLocal', 'modelOptionsWebNote', 'modelOptionsAlwaysThinks', 'modelOptionsThinksFirstNote',
  'modelOptionsHigherLevelsNote', 'modelOptionsTemplateThinkingNote', 'modelOptionsConnectionCannot',
  'modelOptionsUsesModelDefault', 'modelOptionsReasoningNotCatalogued', 'modelOptionsWebNotCatalogued',
  'modelOptionsSeeAdjustableModels', 'modelOptionsNoThinkingMode', 'modelOptionsCannotSearch',
  'modelOptionsWebWhenNeeded', 'modelOptionsWebEveryMessage', 'modelOptionsNeedsManualSetup',
  'modelOptionsReasoningNoGenericSwitch', 'modelOptionsWebNoGenericSwitch',
  'modelOptionsSwitchConnection',
  'modelOptionsChooseProtocolFirst', 'modelOptionsProtocolAutoNote', 'modelOptionsChooseProtocol',
  'modelOptionsTierRejectedTitle', 'modelOptionsTierRejectedBody', 'modelOptionsMoreCount',
  'modelOptionsCantSwitchHere', 'modelOptionsNotAvailableConnection', 'modelOptionsNotAvailableYet',
  'advancedThisConversationOnly', 'advancedReset',
  'advancedResetConversationTitle', 'advancedResetConversationBody', 'advancedResetConversationAction',
  'advancedResetModelTitle', 'advancedResetModelBody', 'advancedResetModelAction', 'advancedNotAdjusted',
  'advancedFieldsCount', 'advancedRandomEachTime', 'advancedPlainText',
  'advancedWriteYourOwn', 'advancedAdditionalBodySubtitle', 'advancedChangedInConversation',
  'advancedUsingYourDefault', 'advancedYourDefault', 'advancedStateSet', 'advancedStateOn',
  'advancedUseModelDefault', 'advancedDontSend', 'advancedAllowedRange', 'advancedAlsoCovers', 'advancedNoLimit',
  'advancedNewStopSequence', 'advancedStopSequenceAdd', 'advancedStopSequenceRemove', 'advancedMore', 'advancedStopSequencesNote', 'advancedErrorMaxTokens', 'advancedErrorNumber',
  'advancedErrorInteger', 'advancedErrorHighest', 'advancedErrorLowest', 'advancedErrorGreaterThan',
  'advancedErrorLessThan', 'advancedErrorJsonSchema', 'advancedErrorValueRejected', 'advancedDroppedThinking',
  'advancedDroppedConflict', 'advancedDroppedConflictWith', 'advancedDroppedDepends', 'advancedDroppedRequires',
  'advancedDroppedValue', 'advancedDroppedRequiredDefault', 'advancedDroppedReasoningBudget', 'advancedTakenOver',
  'advancedCrossedOutLegend', 'advancedGreyDefaultsLegend', 'advancedMirostatNote', 'advancedTargetEntropy',
  'advancedLearningRate', 'advancedRepetition', 'advancedDryNote', 'advancedMoreSampling', 'advancedXtcNote',
  'advancedDynamicTemperature', 'advancedDynamicTemperatureNote', 'advancedReasoningSetByThinking',
  
  'additionalBodyTitle', 'additionalBodySendToggle', 'additionalBodySendToggleNote',
  'additionalBodyDeviceOnly', 'additionalBodyPaste', 'additionalBodyTidy', 'additionalBodyWhenSending',
  'additionalBodyIncluded', 'additionalBodyCannotChange', 'additionalBodyFooter', 'additionalBodyDocsLink',
  'additionalBodyRemoveLine', 'additionalBodyConversationFilled', 'additionalBodyAttachmentsFilled',
  'additionalBodySystemPromptFilled', 'additionalBodyToolsManaged', 'additionalBodyModelChosen',
  'additionalBodyStreamingByOriveo', 'additionalBodyFieldFilled', 'additionalBodyFieldNameInvalid',
  'additionalBodyPasteReplaceTitle', 'additionalBodyPasteReplaceBody', 'additionalBodyTidyInvalid',
  'additionalBodySwitchBlockedInvalid', 'additionalBodySwitchBlockedOff',
  'generationParameterNameGrammar', 'generationParameterNameMinTokens', 'generationParameterNameSkipSpecialTokens',
  'generationParameterOmittedValue', 'advancedNotSet', 'advancedModelDefaultValue', 'advancedAdjustedCount', 'advancedOutput',
];

type Tree = Record<string, unknown>;
const dir = join(process.cwd(), 'messages');
const locales = readdirSync(dir).filter((file) => file.endsWith('.json')).map((file) => file.slice(0, -'.json'.length));
const common = (locale: string) =>
  (JSON.parse(readFileSync(join(dir, `${locale}.json`), 'utf8')) as { common: Tree }).common;

function argumentNames(message: string, locale: string): string[] {
  const names = new Set<string>();
  for (const element of new IntlMessageFormat(message, locale).getAst()) {
    if ((element.type as number) === 1) names.add((element as { value: string }).value);
  }
  return [...names].sort();
}

describe('model options copy', () => {
  it('every imported key exists in all 16 locales with the same arguments', () => {
    expect(locales.length).toBeGreaterThanOrEqual(16);
    const en = common('en');
    const problems: string[] = [];
    for (const locale of locales) {
      const messages = common(locale);
      for (const key of IMPORTED_KEYS) {
        const value = messages[key];
        if (typeof value !== 'string' || value.trim() === '') {
          problems.push(`${locale} ${key}: missing`);
          continue;
        }
        const expected = argumentNames(en[key] as string, 'en');
        const actual = argumentNames(value, locale);
        if (expected.join() !== actual.join()) problems.push(`${locale} ${key}: ${actual} ≠ ${expected}`);
      }
    }
    expect(problems).toEqual([]);
  });

  it('every parameter in the local engine tables resolves to a title in all locales', () => {
    const ids = new Set(Object.values(LOCAL_ENGINE_PROFILES).flatMap((transports) =>
      Object.values(transports).flatMap((profile) => profile?.parameters.map((row) => row.id) ?? [])));
    expect(ids.size).toBeGreaterThan(30);
    const problems: string[] = [];
    for (const locale of locales) {
      const messages = common(locale);
      for (const id of ids) {
        const key = generationParameterTitleKey(id);
        if (!key || typeof messages[key] !== 'string' || (messages[key] as string).trim() === '') problems.push(`${locale} ${id}`);
      }
    }
    expect(problems).toEqual([]);
  });
});
