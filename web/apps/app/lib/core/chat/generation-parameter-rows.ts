/**
 * What each row of advanced settings (generation parameters) shows: the source, the displayed value, why it was not sent, and who took it over.
 * The drop reason is not decided here; it is always delegated to the same outbound writer and the thinking linkage guard for pre-evaluation.
 */
import { guardAnthropicThinking } from '@oriveo/core/providers/request-builders/anthropic-thinking';
import {
  REQUIRED_WIRE_FIELDS,
  mergeDroppedGenerationParameters,
  writeGenerationParameters,
  type DroppedGenerationParameter,
  type GenerationDropReason,
  type GenerationParameterWriteResult,
} from '@oriveo/core/providers/request-builders/generation-parameters';
import type {
  GenerationParameterOverrides,
  GenerationParameterProfile,
  GenerationParameterValue,
} from '@oriveo/core/providers/request-builders/types';
import type { GenerationParameterLayer, SourcedGenerationParameterOverrides } from './generation-parameter-settings';
import { visibleStopSequence } from './stop-sequence-tags';

export type GenerationParameterRowSource = 'changedInConversation' | 'modelDefault' | 'decidedByModel';
export type GenerationParameterRowStanding = 'editedHere' | 'inherited' | 'unset';
export type GenerationParameterDisplayValue =
  | { kind: 'text'; text: string }
  | { kind: 'boolean'; value: boolean }
  | { kind: 'noLimit' };
export type GenerationParameterUnsetLabel = 'randomEachTime' | 'notSet' | 'plainText' | 'modelDefault' | 'omitted';
export type GenerationParameterValidationIssue =
  | { kind: 'notANumber' } | { kind: 'notAnInteger' } | { kind: 'invalidSchema' } | { kind: 'notAccepted' }
  | { kind: 'aboveMaximum' | 'belowMinimum' | 'notAbove' | 'notBelow'; limit: number };
export type GenerationParameterBound = { value: number; open: boolean };

export interface GenerationParameterRow {
  id: string;
  source: GenerationParameterRowSource;
  standing: GenerationParameterRowStanding;
  isOmitted: boolean;
  displayValue?: GenerationParameterDisplayValue;
  unsetLabel?: GenerationParameterUnsetLabel;
  allowedRange?: { lower?: GenerationParameterBound; upper?: GenerationParameterBound };
  dropReason?: GenerationDropReason;
  validationIssue?: GenerationParameterValidationIssue;
  conflictPartnerId?: string;
  requirementPartnerId?: string;
  supersededById?: string;
  fallbackValue?: GenerationParameterDisplayValue;
  modelDefaultValue?: GenerationParameterDisplayValue;
  engineDefault?: GenerationParameterDisplayValue;
  /** The list value as is (needed to render stop sequences as tags one by one; displayValue is the joined text). */
  listValue?: string[];
}

export interface GenerationParameterRowsInput {
  parameterIds: readonly string[];
  profile: GenerationParameterProfile;
  resolved: SourcedGenerationParameterOverrides | undefined;
  editingLayers: readonly GenerationParameterLayer[];
  lowerValues?: GenerationParameterOverrides;
  thinking?: { budgetTokens?: number } | null;
  toolsActive?: boolean;
}

/**
 * Takeover families. When the family head's value lands on a takeover level, is not dropped itself and will really be sent,
 * the parameters in `takes` are ignored upstream -- the panel only strikes them through and gives no drop reason.
 */
export const GENERATION_PARAMETER_FAMILIES: ReadonlyArray<{
  id: string;
  head: string;
  members: readonly string[];
  takeover?: { tiers: readonly number[]; takes: readonly string[] };
}> = [
  { id: 'mirostat', head: 'mirostat', members: ['mirostat_tau', 'mirostat_eta'], takeover: { tiers: [1, 2], takes: ['top_k', 'top_p'] } },
  { id: 'repeat', head: 'repeat_penalty', members: ['repeat_last_n', 'frequency_penalty', 'presence_penalty'] },
  { id: 'dry', head: 'dry_multiplier', members: ['dry_base', 'dry_allowed_length', 'dry_penalty_last_n', 'dry_sequence_breakers'] },
  { id: 'xtc', head: 'xtc_probability', members: ['xtc_threshold'] },
  { id: 'dynatemp', head: 'dynatemp_range', members: ['dynatemp_exponent'] },
];

const PLACEHOLDER_DEFAULTS = new Set(['provider_default', 'unknown']);
const UNSET_LABELS: Readonly<Record<string, GenerationParameterUnsetLabel>> = {
  seed: 'randomEachTime',
  stop: 'notSet', stop_sequences: 'notSet', dry_sequence_breakers: 'notSet', samplers: 'notSet',
  response_format: 'plainText', json_schema: 'plainText', grammar: 'plainText',
};

type ProfileParameter = GenerationParameterProfile['parameters'][number];

export function generationParameterRows(input: GenerationParameterRowsInput): GenerationParameterRow[] {
  const { profile, resolved = {}, lowerValues = {} } = input;
  const declared = new Map(profile.parameters.map((parameter) => [parameter.id, parameter]));
  const outbound = preEvaluate(input);
  const dropReasons = new Map(outbound.dropped.map((item) => [item.parameterId, item.reason]));
  const written = new Set(outbound.written);
  const superseded = supersededParameters(resolved, written);
  const editing = new Set(input.editingLayers);

  return input.parameterIds.map((id) => {
    const parameter = declared.get(id);
    const entry = resolved[id];
    const override = entry?.override;
    const engineDefault = engineDefaultValue(id, parameter);
    const lower = lowerValues[id];
    const lowerValue = lower?.state === 'value' ? displayOf(id, lower.value) : undefined;
    const supersededById = superseded.get(id);
    const dropReason = supersededById ? undefined : dropReasons.get(id);
    const row: GenerationParameterRow = {
      id,
      source: !entry ? 'decidedByModel'
        : entry.layer === 'transient' || entry.layer === 'conversation' ? 'changedInConversation' : 'modelDefault',
      standing: !entry ? 'unset' : editing.has(entry.layer) ? 'editedHere' : 'inherited',
      isOmitted: override?.state === 'omit',
    };
    const displayValue = override?.state === 'value' ? displayOf(id, override.value) : entry ? undefined : engineDefault;
    if (displayValue) row.displayValue = displayValue;
    if (override?.state === 'value' && Array.isArray(override.value)) row.listValue = [...override.value];
    else row.unsetLabel = row.isOmitted ? 'omitted' : UNSET_LABELS[id] ?? 'modelDefault';
    const range = allowedRange(parameter);
    if (range) row.allowedRange = range;
    if (dropReason) row.dropReason = dropReason;
    if (dropReason === 'invalid_value' && override?.state === 'value' && parameter) {
      row.validationIssue = validationIssue(override.value, parameter);
    }
    if (dropReason === 'conflict' && parameter) {
      const partner = conflictPartner(id, parameter, profile, written, input.toolsActive === true);
      if (partner) row.conflictPartnerId = partner;
    }
    if (dropReason === 'requirement_unmet') {
      const key = parameter?.requires?.find((requirement) => typeof requirement.key === 'string')?.key;
      if (typeof key === 'string') row.requirementPartnerId = key;
    }
    if (supersededById) row.supersededById = supersededById;
    const fallback = lowerValue ?? engineDefault;
    if (fallback) row.fallbackValue = fallback;
    if (lowerValue) row.modelDefaultValue = lowerValue;
    if (engineDefault) row.engineDefault = engineDefault;
    return row;
  });
}

export function generationParameterSummary(rows: readonly GenerationParameterRow[], maxChips = 2): {
  chips: Array<{ id: string; displayValue: GenerationParameterDisplayValue }>;
  moreCount: number;
} {
  const eligible = rows.flatMap((row) => row.source === 'changedInConversation' && row.displayValue
    && !row.validationIssue && !row.dropReason && !row.supersededById
    ? [{ id: row.id, displayValue: row.displayValue }]
    : []);
  return { chips: eligible.slice(0, maxChips), moreCount: Math.max(0, eligible.length - maxChips) };
}

/**
 * Same decision as outbound: the effective values are written onto an empty object by `writeGenerationParameters` (a "do not send" that hits a required
 * wire field follows the same table as the writer); when thinking is on, the thinking fields are added to that body and handed to `guardAnthropicThinking`.
 */
function preEvaluate(input: GenerationParameterRowsInput): GenerationParameterWriteResult {
  const { profile, resolved = {} } = input;
  const values: GenerationParameterOverrides = {};
  for (const [id, entry] of Object.entries(resolved)) {
    if (entry.override.state === 'value') values[id] = entry.override;
  }
  const body: Record<string, unknown> = {};
  const { dropped, written } = writeGenerationParameters(body, values, profile, { toolsActive: input.toolsActive });
  const requiredWires = REQUIRED_WIRE_FIELDS[profile.template] ?? [];
  const requiredDropped = Object.entries(resolved).flatMap(([id, entry]) => entry.override.state === 'omit'
    && profile.wire[id] && requiredWires.includes(profile.wire[id])
    ? [{ parameterId: id, reason: 'required_field' as const }]
    : []);
  let thinkingDropped: DroppedGenerationParameter[] = [];
  if (input.thinking && profile.template === 'anthropic_messages') {
    body.thinking = input.thinking.budgetTokens !== undefined
      ? { type: 'enabled', budget_tokens: input.thinking.budgetTokens }
      : { type: 'adaptive' };
    thinkingDropped = guardAnthropicThinking(body, { profile, written, builderDefaultMaxTokens: undefined });
  }
  const thinkingIds = new Set(thinkingDropped.map((item) => item.parameterId));
  return {
    dropped: mergeDroppedGenerationParameters(dropped, requiredDropped, thinkingDropped),
    written: written.filter((id) => !thinkingIds.has(id)),
  };
}

function supersededParameters(resolved: SourcedGenerationParameterOverrides, written: ReadonlySet<string>): Map<string, string> {
  const result = new Map<string, string>();
  for (const family of GENERATION_PARAMETER_FAMILIES) {
    const head = resolved[family.head]?.override;
    if (!family.takeover || head?.state !== 'value' || !written.has(family.head)) continue;
    if (typeof head.value !== 'number' || !family.takeover.tiers.includes(head.value)) continue;
    for (const id of family.takeover.takes) result.set(id, family.id);
  }
  return result;
}

function engineDefaultValue(id: string, parameter: ProfileParameter | undefined): GenerationParameterDisplayValue | undefined {
  const raw = parameter?.defaultDescription;
  if (raw === undefined || (typeof raw === 'string' && PLACEHOLDER_DEFAULTS.has(raw))) return undefined;
  return displayOf(id, raw);
}

const STOP_SEQUENCE_IDS = new Set(['stop', 'stop_sequences']);

function displayOf(id: string, value: GenerationParameterValue): GenerationParameterDisplayValue {
  if (id === 'max_output_tokens' && typeof value === 'number' && value < 0) return { kind: 'noLimit' };
  if (typeof value === 'boolean') return { kind: 'boolean', value };
  if (typeof value === 'number' || typeof value === 'string') return { kind: 'text', text: String(value) };
  // Stop sequences in the summary are separated one by one in a visible form: joined as is, newlines and spaces cannot be seen in a one-line pill,
  // and when a sequence itself contains commas the separators are ambiguous.
  if (Array.isArray(value) && STOP_SEQUENCE_IDS.has(id)) {
    return { kind: 'text', text: value.map((item) => visibleStopSequence(String(item))).join(' · ') };
  }
  if (Array.isArray(value)) return { kind: 'text', text: value.join(', ') };
  return { kind: 'text', text: JSON.stringify(value) };
}

function allowedRange(parameter: ProfileParameter | undefined): GenerationParameterRow['allowedRange'] {
  const range = parameter?.range;
  if (!range) return undefined;
  const lower = range.minExclusive != null ? { value: range.minExclusive, open: true }
    : range.min != null ? { value: range.min, open: false } : undefined;
  const upper = range.maxExclusive != null ? { value: range.maxExclusive, open: true }
    : range.max != null ? { value: range.max, open: false } : undefined;
  if (!lower && !upper) return undefined;
  return { ...(lower ? { lower } : {}), ...(upper ? { upper } : {}) };
}

/** Only classifies the reason; the decision itself was already made by the writer. This finds the first check that fails, in the same check order. */
function validationIssue(value: GenerationParameterValue, parameter: ProfileParameter): GenerationParameterValidationIssue {
  if (parameter.id === 'json_schema' || parameter.valueSchema === 'json-schema') return { kind: 'invalidSchema' };
  const numericSchema = parameter.valueSchema === 'number' || parameter.valueSchema === 'integer';
  if (numericSchema && (typeof value !== 'number' || !Number.isFinite(value))) return { kind: 'notANumber' };
  if (typeof value === 'number') {
    if (parameter.valueSchema === 'integer' && !Number.isInteger(value)) return { kind: 'notAnInteger' };
    const range = parameter.range;
    if (range?.min != null && value < range.min) return { kind: 'belowMinimum', limit: range.min };
    if (range?.max != null && value > range.max) return { kind: 'aboveMaximum', limit: range.max };
    if (range?.minExclusive != null && value <= range.minExclusive) return { kind: 'notAbove', limit: range.minExclusive };
    if (range?.maxExclusive != null && value >= range.maxExclusive) return { kind: 'notBelow', limit: range.maxExclusive };
  }
  return { kind: 'notAccepted' };
}

function conflictPartner(
  id: string,
  parameter: ProfileParameter,
  profile: GenerationParameterProfile,
  written: ReadonlySet<string>,
  toolsActive: boolean,
): string | undefined {
  const present = (key: string) => written.has(key) || (key === 'tools' && toolsActive);
  const own = (parameter.conflictsWith ?? []).find(present);
  if (own) return own;
  return [...written].sort().find((peer) => profile.parameters.find((item) => item.id === peer)?.conflictsWith?.includes(id));
}
