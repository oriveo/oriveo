/**
 * Semantic slots of model options / advanced settings / the additional request body -> `common` namespace message keys.
 * The data layer only emits semantic enums; this file is the single place where they land on next-intl.
 */
import type { GenerationDropReason } from '@oriveo/core/providers/request-builders/generation-parameters';
import type {
  AdvancedClusterSubtitle, AdvancedClusterSummary, AdvancedClusterTitle, AdvancedCommonFootnote,
  AdvancedFamilyNote, AdvancedModeLabel, AdvancedSectionTitle,
} from './advanced-settings-layout';
import type { ReasoningRowWithoutWritePath } from './advanced-settings-reasoning';
import type { ChatTemplateThinkingState } from './chat-template-thinking';
import type {
  GenerationParameterDisplayValue, GenerationParameterRow,
  GenerationParameterUnsetLabel, GenerationParameterValidationIssue,
} from './generation-parameter-rows';
import type {
  ModelOptionCapability, ModelOptionCaption, ModelOptionDisclosureStatus,
  ModelOptionLinkAction, ModelOptionNoticeBody, ModelOptionNoticeStatus, ModelOptionReadOnlyValue,
  ModelOptionTierFootnote, ModelOptionTierTrailing,
} from './model-option-capability-shape';

/** Parameter id -> title key; shared by the panel and advanced settings. */
export const GENERATION_PARAMETER_TITLE_KEYS: Readonly<Record<string, string>> = {
  max_output_tokens: 'generationParameterNameMaxOutputTokens',
  min_tokens: 'generationParameterNameMinTokens',
  temperature: 'generationParameterNameTemperature',
  top_p: 'generationParameterNameTopP',
  top_k: 'generationParameterNameTopK',
  min_p: 'generationParameterNameMinP',
  typical_p: 'generationParameterNameTypicalP',
  top_n_sigma: 'generationParameterNameTopNSigma',
  frequency_penalty: 'generationParameterNameFrequencyPenalty',
  presence_penalty: 'generationParameterNamePresencePenalty',
  repetition_penalty: 'generationParameterNameRepetitionPenalty',
  repeat_penalty: 'generationParameterNameRepeatPenalty',
  repeat_last_n: 'generationParameterNameRepeatLastN',
  mirostat: 'generationParameterNameMirostat',
  mirostat_tau: 'generationParameterNameMirostatTau',
  mirostat_eta: 'generationParameterNameMirostatEta',
  dry_multiplier: 'generationParameterNameDryMultiplier',
  dry_base: 'generationParameterNameDryBase',
  dry_allowed_length: 'generationParameterNameDryAllowedLength',
  dry_penalty_last_n: 'generationParameterNameDryPenaltyLastN',
  dry_sequence_breakers: 'generationParameterNameDrySequenceBreakers',
  xtc_probability: 'generationParameterNameXtcProbability',
  xtc_threshold: 'generationParameterNameXtcThreshold',
  dynatemp_range: 'generationParameterNameDynatempRange',
  dynatemp_exponent: 'generationParameterNameDynatempExponent',
  samplers: 'generationParameterNameSamplers',
  min_keep: 'generationParameterNameMinKeep',
  n_keep: 'generationParameterNameNKeep',
  n_indent: 'generationParameterNameNIndent',
  t_max_predict_ms: 'generationParameterNameTMaxPredictMs',
  ignore_eos: 'generationParameterNameIgnoreEos',
  seed: 'generationParameterNameSeed',
  stop: 'generationParameterNameStop',
  verbosity: 'generationParameterNameVerbosity',
  logprobs: 'generationParameterNameLogprobs',
  top_logprobs: 'generationParameterNameTopLogprobs',
  n_probs: 'generationParameterNameNProbs',
  post_sampling_probs: 'generationParameterNamePostSamplingProbs',
  reasoning_effort: 'generationParameterNameReasoningEffort',
  reasoning_budget: 'generationParameterNameReasoningBudget',
  reasoning_mode: 'generationParameterNameReasoningMode',
  response_format: 'generationParameterNameResponseFormat',
  json_schema: 'generationParameterNameJsonSchema',
  grammar: 'generationParameterNameGrammar',
  skip_special_tokens: 'generationParameterNameSkipSpecialTokens',
};

export function generationParameterTitleKey(id: string): string | undefined {
  return GENERATION_PARAMETER_TITLE_KEYS[id];
}

/** Copy reference: a message key (full path from the root, optionally with arguments) or an untranslated literal (engine name, family name, user-entered value). */
export type CopyRef = { key: string; args?: Record<string, CopyArg> } | { literal: string };
/** An argument can be a raw value or another piece of copy (lists are joined by the UI per language). */
export type CopyArg = string | number | CopyRef | CopyRef[];

const common = (key: string, args?: Record<string, CopyArg>): CopyRef => ({ key: `common.${key}`, ...(args ? { args } : {}) });
const literal = (text: string): CopyRef => ({ literal: text });
const OFF = 'pages.chat.reasoning.off';
const ON = 'common.advancedStateOn';

export function generationParameterTitleCopy(id: string): CopyRef {
  const key = generationParameterTitleKey(id);
  return key ? common(key) : literal(id);
}

// ---- Model options: capability card ----

type ReasoningIntent = 'off' | 'automatic' | 'low' | 'balanced' | 'deep' | 'max';
const REASONING_TIER_LABEL_KEYS: Readonly<Record<ReasoningIntent, string>> = {
  off: OFF,
  automatic: 'pages.chat.reasoning.supplierDefault',
  low: 'pages.chat.reasoning.fast',
  balanced: 'pages.chat.reasoning.balanced',
  deep: 'pages.chat.reasoning.deep',
  max: 'pages.chat.reasoning.max',
};
const REASONING_TIER_NOTE_KEYS: Readonly<Record<ReasoningIntent, string>> = {
  off: 'common.capabilityControlReasoningNoteOff',
  automatic: 'common.capabilityControlReasoningNoteAutomatic',
  low: 'common.capabilityControlReasoningNoteFast',
  balanced: 'common.capabilityControlReasoningNoteBalanced',
  deep: 'common.capabilityControlReasoningNoteDeep',
  max: 'common.capabilityControlReasoningNoteMax',
};
const isReasoningIntent = (intent: string): intent is ReasoningIntent => Object.hasOwn(REASONING_TIER_LABEL_KEYS, intent);

/** Tier name; an unknown intent from the catalog falls back to the raw text instead of being swallowed. */
export function reasoningTierLabelCopy(intent: string): CopyRef {
  return isReasoningIntent(intent) ? { key: REASONING_TIER_LABEL_KEYS[intent] } : literal(intent);
}

export function reasoningTierNoteCopy(intent: string): CopyRef | undefined {
  return isReasoningIntent(intent) ? { key: REASONING_TIER_NOTE_KEYS[intent] } : undefined;
}

export const MODEL_OPTION_CAPABILITY_TITLE_KEYS: Readonly<Record<ModelOptionCapability, string>> = {
  web: 'common.capabilityControlWebSearch',
  reasoning: 'common.capabilityControlThinking',
};
export const MODEL_OPTION_CAPTION_KEYS: Readonly<Record<ModelOptionCaption, string>> = {
  searchesTheWeb: 'common.modelOptionsWebNote',
  thinksFirst: 'common.modelOptionsThinksFirstNote',
  chatTemplateThinking: 'common.modelOptionsTemplateThinkingNote',
};
export const MODEL_OPTION_LINK_KEYS: Readonly<Record<ModelOptionLinkAction, string>> = {
  openSupportedModels: 'common.modelOptionsSeeAdjustableModels',
  openAdditionalRequestBody: 'common.openAdditionalBody',
  openConnectionProtocol: 'common.modelOptionsChooseProtocol',
  switchConnection: 'common.modelOptionsSwitchConnection',
};
export const MODEL_OPTION_WEB_TIMING_KEYS: Readonly<Record<'automatic' | 'force', string>> = {
  automatic: 'common.modelOptionsWebWhenNeeded',
  force: 'common.modelOptionsWebEveryMessage',
};
export const MODEL_OPTION_NOTICE_STATUS_KEYS: Readonly<Record<ModelOptionNoticeStatus, string>> = {
  alwaysThinks: 'common.modelOptionsAlwaysThinks',
  needsOwnConfiguration: 'common.modelOptionsNeedsManualSetup',
  modelDefault: 'common.modelOptionsUsesModelDefault',
  temporarilyUnavailable: 'common.modelOptionsNotAvailableYet',
};
export const MODEL_OPTION_PROTOCOL_UNDECIDED_KEYS = {
  title: 'common.modelOptionsChooseProtocolFirst',
  body: 'common.modelOptionsProtocolAutoNote',
} as const;
const CAPABILITY_BODY_KEYS: Readonly<Record<'customOnly' | 'notCatalogued' | 'modelLacksCapability', Record<ModelOptionCapability, string>>> = {
  customOnly: { web: 'common.modelOptionsWebNoGenericSwitch', reasoning: 'common.modelOptionsReasoningNoGenericSwitch' },
  notCatalogued: { web: 'common.modelOptionsWebNotCatalogued', reasoning: 'common.modelOptionsReasoningNotCatalogued' },
  modelLacksCapability: { web: 'common.modelOptionsCannotSearch', reasoning: 'common.modelOptionsNoThinkingMode' },
};

export function modelOptionNoticeBodyCopy(body: ModelOptionNoticeBody): CopyRef {
  switch (body.kind) {
    case 'fixedTier': return common('capabilityControlReasoningFixedLevel');
    case 'customOnly':
    case 'notCatalogued': return { key: CAPABILITY_BODY_KEYS[body.kind][body.capability] };
  }
}

export function modelOptionReadOnlyValueCopy(value: ModelOptionReadOnlyValue): CopyRef {
  switch (value.kind) {
    case 'webPreference': return value.preference === 'off' ? { key: OFF } : { key: MODEL_OPTION_WEB_TIMING_KEYS[value.preference] };
    case 'reasoningTier': return reasoningTierLabelCopy(value.intent);
    case 'modelDefault': return common('modelOptionsUsesModelDefault');
    case 'chatTemplateThinking': return { key: value.isOn ? ON : OFF };
  }
}

export function modelOptionDisclosureStatusCopy(status: ModelOptionDisclosureStatus, capability: ModelOptionCapability): CopyRef {
  switch (status.kind) {
    case 'cannotDoOnThisConnection': return common('modelOptionsConnectionCannot');
    case 'fixedByConnection': return common('capabilityControlFixedByConnection');
    case 'modelLacksCapability': return { key: CAPABILITY_BODY_KEYS.modelLacksCapability[capability] };
    case 'currentValue': return modelOptionReadOnlyValueCopy(status.value);
  }
}

export function modelOptionTierTrailingCopy(trailing: ModelOptionTierTrailing): CopyRef {
  switch (trailing.kind) {
    case 'rejected': return common('modelOptionsTierRejectedTitle', { tier: reasoningTierLabelCopy(trailing.intent) });
    case 'tierNote': return reasoningTierNoteCopy(trailing.intent) ?? reasoningTierLabelCopy(trailing.intent);
    case 'modelDefault': return common('modelOptionsUsesModelDefault');
    case 'alwaysThinks': return common('modelOptionsAlwaysThinks');
  }
}

export function modelOptionTierFootnoteCopy(footnote: ModelOptionTierFootnote): CopyRef {
  switch (footnote.kind) {
    case 'rejectedFallback':
      return common('modelOptionsTierRejectedBody', {
        rejected: reasoningTierLabelCopy(footnote.rejected),
        current: reasoningTierLabelCopy(footnote.fallback),
      });
    case 'tierNote': return reasoningTierNoteCopy(footnote.intent) ?? reasoningTierLabelCopy(footnote.intent);
    case 'costNote': return common('modelOptionsHigherLevelsNote');
  }
}

/** Chat-template thinking switch: when the additional request body blocks it, explains where to change it. */
export const CHAT_TEMPLATE_THINKING_STATE_KEYS: Readonly<Record<ChatTemplateThinkingState, string>> = {
  off: OFF,
  on: ON,
  blocked: 'common.additionalBodySwitchBlockedInvalid',
  notSending: 'common.additionalBodySwitchBlockedOff',
};

// ---- Advanced settings: parameter rows ----

export const GENERATION_PARAMETER_UNSET_LABEL_KEYS: Readonly<Record<GenerationParameterUnsetLabel, string>> = {
  randomEachTime: 'common.advancedRandomEachTime',
  notSet: 'common.advancedNotSet',
  plainText: 'common.advancedPlainText',
  modelDefault: 'common.advancedModelDefaultValue',
  omitted: 'common.generationParameterOmittedValue',
};
const DROP_REASON_KEYS: Readonly<Record<GenerationDropReason, string>> = {
  invalid_value: 'common.advancedDroppedValue',
  conflict: 'common.advancedDroppedConflict',
  requirement_unmet: 'common.advancedDroppedDepends',
  required_field: 'common.advancedDroppedRequiredDefault',
  thinking_incompatible: 'common.advancedDroppedThinking',
  thinking_budget: 'common.advancedDroppedReasoningBudget',
};

export function generationDisplayValueCopy(value: GenerationParameterDisplayValue): CopyRef {
  switch (value.kind) {
    case 'text': return literal(value.text);
    case 'boolean': return { key: value.value ? ON : OFF };
    case 'noLimit': return common('advancedNoLimit');
  }
}

/** The "why was this not sent" line under a row: a family takeover comes first, then the drop reason (naming the other party when it is known). */
export function generationRowStatusCopy(
  row: Pick<GenerationParameterRow, 'dropReason' | 'conflictPartnerId' | 'requirementPartnerId' | 'supersededById'>,
): CopyRef | undefined {
  if (row.supersededById) return common('advancedTakenOver', { family: advancedFamilyTitleCopy(row.supersededById) });
  if (!row.dropReason) return undefined;
  if (row.dropReason === 'conflict' && row.conflictPartnerId) {
    return common('advancedDroppedConflictWith', { parameter: generationParameterTitleCopy(row.conflictPartnerId) });
  }
  if (row.dropReason === 'requirement_unmet' && row.requirementPartnerId) {
    return common('advancedDroppedRequires', { parameter: generationParameterTitleCopy(row.requirementPartnerId) });
  }
  return { key: DROP_REASON_KEYS[row.dropReason] };
}

export function generationValidationIssueCopy(parameterId: string, issue: GenerationParameterValidationIssue): CopyRef {
  switch (issue.kind) {
    case 'notANumber': return common('advancedErrorNumber');
    case 'notAnInteger': return common('advancedErrorInteger');
    case 'invalidSchema': return common('advancedErrorJsonSchema');
    case 'notAccepted': return common('advancedErrorValueRejected');
    case 'aboveMaximum':
      return parameterId === 'max_output_tokens'
        ? common('advancedErrorMaxTokens', { limit: issue.limit })
        : common('advancedErrorHighest', { value: issue.limit });
    case 'belowMinimum': return common('advancedErrorLowest', { value: issue.limit });
    // Open interval: an exclusive lower bound means it must be greater; an exclusive upper bound means it must be less.
    case 'notAbove': return common('advancedErrorGreaterThan', { value: issue.limit });
    case 'notBelow': return common('advancedErrorLessThan', { value: issue.limit });
  }
}

export const ADVANCED_REASONING_STATUS_NOTE_KEYS: Readonly<Record<ReasoningRowWithoutWritePath['statusNote'], string>> = {
  reasoningSetByThinking: 'common.advancedReasoningSetByThinking',
};

// ---- Advanced settings: sections, families, and subgroups ----

/** Kept in step with `GENERATION_PARAMETER_FAMILIES`; adding a family to the table makes the test fail. */
type FamilyId = 'mirostat' | 'repeat' | 'dry' | 'xtc' | 'dynatemp';
/** Family names: Mirostat / DRY / XTC are proper names of sampling methods and are not translated in any language. */
const FAMILY_TITLES: Readonly<Record<FamilyId, CopyRef>> = {
  mirostat: literal('Mirostat'),
  repeat: common('generationParameterNameRepeatPenalty'),
  dry: literal('DRY'),
  xtc: literal('XTC'),
  dynatemp: common('advancedDynamicTemperature'),
};
const FAMILY_NOTE_KEYS: Readonly<Record<Exclude<FamilyId, 'repeat'>, string>> = {
  mirostat: 'common.advancedMirostatNote',
  dry: 'common.advancedDryNote',
  xtc: 'common.advancedXtcNote',
  dynatemp: 'common.advancedDynamicTemperatureNote',
};
const SECTION_TITLE_KEYS: Readonly<Record<Exclude<AdvancedSectionTitle, `family:${string}`>, string>> = {
  common: 'common.generationBasicSettings',
  more: 'common.advancedMore',
  reasoning: 'common.generationGroupReasoning',
  antiRepetition: 'common.advancedRepetition',
  moreSampling: 'common.advancedMoreSampling',
  output: 'common.advancedOutput',
  engineRuntime: 'common.generationGroupEngineRuntime',
};
const GROUP_TITLE_KEYS: Readonly<Record<string, string>> = {
  budget: 'common.generationGroupBudget',
  reasoning: 'common.generationGroupReasoning',
  sampling: 'common.generationGroupSampling',
  repetition: 'common.generationGroupRepetition',
  reproducibility: 'common.generationGroupReproducibility',
  output_contract: 'common.generationGroupOutputContract',
  engine_runtime: 'common.generationGroupEngineRuntime',
};
const MEMBER_SHORT_TITLE_KEYS: Readonly<Record<'targetEntropy' | 'learningRate', string>> = {
  targetEntropy: 'common.advancedTargetEntropy',
  learningRate: 'common.advancedLearningRate',
};

const isFamilyId = (id: string): id is FamilyId => Object.hasOwn(FAMILY_TITLES, id);

export function advancedFamilyTitleCopy(familyId: string): CopyRef {
  return isFamilyId(familyId) ? FAMILY_TITLES[familyId] : literal(familyId);
}

export function advancedSectionTitleCopy(title: AdvancedSectionTitle): CopyRef {
  if (title.startsWith('family:')) return advancedFamilyTitleCopy(title.slice('family:'.length));
  return { key: SECTION_TITLE_KEYS[title as keyof typeof SECTION_TITLE_KEYS] };
}

/** Subgroup title; a subgroup of scattered parameters gives the titles of its first few parameters, joined by the UI per language. */
export function advancedClusterTitleCopy(title: AdvancedClusterTitle): CopyRef[] {
  switch (title.kind) {
    case 'group': return [GROUP_TITLE_KEYS[title.group] ? { key: GROUP_TITLE_KEYS[title.group] } : literal(title.group)];
    case 'family': return [advancedFamilyTitleCopy(title.familyId)];
    case 'parameters': return title.ids.map(generationParameterTitleCopy);
  }
}

export function advancedFamilyNoteCopy(note: AdvancedFamilyNote): CopyRef | undefined {
  return note.familyId in FAMILY_NOTE_KEYS ? { key: FAMILY_NOTE_KEYS[note.familyId as keyof typeof FAMILY_NOTE_KEYS] } : undefined;
}

export function advancedClusterSubtitleCopy(subtitle: AdvancedClusterSubtitle): CopyRef | undefined {
  if (subtitle.kind === 'familyNote') return advancedFamilyNoteCopy(subtitle);
  return common('advancedAlsoCovers', { names: subtitle.memberIds.map(generationParameterTitleCopy) });
}

export function advancedModeLabelCopy(label: AdvancedModeLabel): CopyRef {
  return label.kind === 'off' ? { key: OFF } : literal(label.text);
}

export function advancedMemberShortTitleCopy(title: 'targetEntropy' | 'learningRate'): CopyRef {
  return { key: MEMBER_SHORT_TITLE_KEYS[title] };
}

/** Trailing summary of a subgroup row; `titledValue` is the two parts "parameter name" and "value", joined by the UI. */
export function advancedClusterSummaryCopy(summary: AdvancedClusterSummary): CopyRef[] {
  switch (summary.kind) {
    case 'value': return [generationDisplayValueCopy(summary.displayValue)];
    case 'titledValue': return [generationParameterTitleCopy(summary.parameterId), generationDisplayValueCopy(summary.displayValue)];
    case 'rowTrailing':
      if (summary.displayValue) return [generationDisplayValueCopy(summary.displayValue)];
      return summary.unsetLabel ? [{ key: GENERATION_PARAMETER_UNSET_LABEL_KEYS[summary.unsetLabel] }] : [];
    case 'off': return [{ key: OFF }];
    case 'plainText': return [common('advancedPlainText')];
    case 'notAdjusted': return [common('advancedNotAdjusted')];
    case 'adjustedCount': return [common('advancedAdjustedCount', { count: summary.count })];
  }
}

export function advancedCommonFootnoteCopy(note: AdvancedCommonFootnote): CopyRef {
  return note.kind === 'engineDefaults'
    ? common('advancedGreyDefaultsLegend', { engine: literal(note.engineName) })
    : common('advancedCrossedOutLegend', { families: note.familyIds.map(advancedFamilyTitleCopy) });
}
