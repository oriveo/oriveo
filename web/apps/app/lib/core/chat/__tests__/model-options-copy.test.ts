/**
 * Semantic slot -> message key: every mapped key must exist in messages/en.json (the real JSON is read).
 * Sections, subgroups, summaries, and row states are what the production `advancedSettingsSections` /
 * `generationParameterRows` produce from the real llama.cpp table.
 */
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';
import type { SourcedGenerationParameterOverrides } from '../generation-parameter-settings';
import { GENERATION_PARAMETER_FAMILIES, generationParameterRows } from '../generation-parameter-rows';
import { localEngineGenerationProfile } from '../local-engine-profiles';
import {
  ADVANCED_COMMON_PARAMETER_IDS, advancedClusterSummary, advancedCommonFootnote, advancedMemberShortTitle, advancedSettingsSections,
} from '../advanced-settings-layout';
import * as copy from '../model-options-copy';
import type { CopyArg, CopyRef } from '../model-options-copy';

const en = JSON.parse(readFileSync(join(process.cwd(), 'messages', 'en.json'), 'utf8')) as Record<string, unknown>;
const lookup = (path: string) => path.split('.').reduce<unknown>((node, part) => (node as Record<string, unknown> | undefined)?.[part], en);

function keysOf(value: CopyArg | undefined | null, into: string[] = []): string[] {
  if (value == null || typeof value === 'string' || typeof value === 'number') return into;
  if (Array.isArray(value)) { value.forEach((item) => keysOf(item, into)); return into; }
  if ('key' in value) {
    into.push(value.key);
    Object.values(value.args ?? {}).forEach((arg) => keysOf(arg, into));
  }
  return into;
}
const missing = (keys: string[]) => [...new Set(keys)].filter((key) => typeof lookup(key) !== 'string');
const refs = (...values: Array<CopyRef | CopyRef[] | undefined>) => values.flatMap((value) => keysOf(value ?? null));

const INTENTS = ['off', 'automatic', 'low', 'balanced', 'deep', 'max'];

describe('model options copy keys', () => {
  it('every key in the exhaustive tables exists in en.json', () => {
    const tables = Object.values(copy).filter((value) => value && typeof value === 'object') as Array<Record<string, unknown>>;
    const keys = tables.flatMap((table) => Object.values(table)).filter((value): value is string => typeof value === 'string' && value.includes('.'));
    expect(keys.length).toBeGreaterThan(25);
    expect(missing(keys)).toEqual([]);
  });

  it('capability card copy resolves for every semantic slot', () => {
    const keys = [
      ...INTENTS.flatMap((intent) => refs(copy.reasoningTierLabelCopy(intent), copy.reasoningTierNoteCopy(intent),
        copy.modelOptionTierTrailingCopy({ kind: 'rejected', intent }), copy.modelOptionTierTrailingCopy({ kind: 'tierNote', intent }),
        copy.modelOptionTierFootnoteCopy({ kind: 'rejectedFallback', rejected: intent, fallback: 'balanced' }),
        copy.modelOptionReadOnlyValueCopy({ kind: 'reasoningTier', intent }))),
      ...refs(copy.modelOptionTierTrailingCopy({ kind: 'modelDefault' }), copy.modelOptionTierTrailingCopy({ kind: 'alwaysThinks' }),
        copy.modelOptionTierFootnoteCopy({ kind: 'costNote' }), copy.modelOptionNoticeBodyCopy({ kind: 'fixedTier' })),
      ...(['web', 'reasoning'] as const).flatMap((capability) => refs(
        copy.modelOptionNoticeBodyCopy({ kind: 'customOnly', capability }), copy.modelOptionNoticeBodyCopy({ kind: 'notCatalogued', capability }),
        copy.modelOptionDisclosureStatusCopy({ kind: 'cannotDoOnThisConnection' }, capability),
        copy.modelOptionDisclosureStatusCopy({ kind: 'modelLacksCapability' }, capability))),
      ...(['off', 'automatic', 'force'] as const).flatMap((preference) => refs(copy.modelOptionReadOnlyValueCopy({ kind: 'webPreference', preference }))),
      ...refs(copy.modelOptionReadOnlyValueCopy({ kind: 'modelDefault' }), copy.modelOptionReadOnlyValueCopy({ kind: 'chatTemplateThinking', isOn: true }),
        copy.modelOptionReadOnlyValueCopy({ kind: 'chatTemplateThinking', isOn: false })),
    ];
    expect(keys.length).toBeGreaterThan(40);
    expect(missing(keys)).toEqual([]);
    expect(copy.reasoningTierLabelCopy('balanced')).toEqual({ key: 'pages.chat.reasoning.balanced' });
    expect(copy.modelOptionTierFootnoteCopy({ kind: 'rejectedFallback', rejected: 'max', fallback: 'deep' })).toEqual({
      key: 'common.modelOptionsTierRejectedBody',
      args: { rejected: { key: 'pages.chat.reasoning.max' }, current: { key: 'pages.chat.reasoning.deep' } },
    });
  });

  it('every family in the production table has a title', () => {
    for (const family of GENERATION_PARAMETER_FAMILIES) {
      const title = copy.advancedFamilyTitleCopy(family.id);
      expect(title, family.id).not.toEqual({ literal: family.id });
    }
  });

  it('llama.cpp production sections, summaries and rows all resolve to existing keys', () => {
    const llama = localEngineGenerationProfile('llamacpp', undefined)!;
    const values: Record<string, unknown> = { typical_p: 0.9, mirostat: 2, xtc_threshold: 'omit', min_p: 7, temperature: 'x', seed: 'omit' };
    const resolved: SourcedGenerationParameterOverrides = Object.fromEntries(Object.entries(values).map(([id, value]) => [
      id, { override: value === 'omit' ? { state: 'omit' } : { state: 'value', value: value as never }, layer: id === 'typical_p' ? 'connectionModel' : 'conversation' },
    ]));
    const rows = generationParameterRows({
      parameterIds: llama.parameters.map((parameter) => parameter.id), profile: llama, resolved, editingLayers: ['transient', 'conversation'],
    });
    const rowsById = Object.fromEntries(rows.map((row) => [row.id, row]));
    const keys: string[] = [];
    for (const row of rows) {
      if (row.unsetLabel) keys.push(copy.GENERATION_PARAMETER_UNSET_LABEL_KEYS[row.unsetLabel]);
      keys.push(...refs(copy.generationParameterTitleCopy(row.id), copy.generationRowStatusCopy(row),
        row.validationIssue && copy.generationValidationIssueCopy(row.id, row.validationIssue),
        row.displayValue && copy.generationDisplayValueCopy(row.displayValue)));
    }
    for (const section of advancedSettingsSections(llama.parameters)) {
      if (section.title) keys.push(...refs(copy.advancedSectionTitleCopy(section.title)));
      for (const item of section.items) {
        if (item.kind === 'parameter') {
          const short = advancedMemberShortTitle(item.id);
          if (short) keys.push(...refs(copy.advancedMemberShortTitleCopy(short.title)));
        } else if (item.kind === 'mode') {
          keys.push(...refs(...item.options.map((option) => copy.advancedModeLabelCopy(option.label)), item.description && copy.advancedFamilyNoteCopy(item.description)));
        } else {
          keys.push(...refs(copy.advancedClusterTitleCopy(item.cluster.title), item.cluster.subtitle && copy.advancedClusterSubtitleCopy(item.cluster.subtitle),
            copy.advancedClusterSummaryCopy(advancedClusterSummary(item.cluster, rowsById))));
        }
      }
    }
    for (const note of advancedCommonFootnote(rows, ADVANCED_COMMON_PARAMETER_IDS, 'llama.cpp')) keys.push(...refs(copy.advancedCommonFootnoteCopy(note)));

    expect([
      'common.generationParameterOmittedValue',
      'common.advancedTakenOver', 'common.advancedErrorHighest', 'common.advancedErrorNumber', 'common.advancedOutput',
      'common.advancedCrossedOutLegend', 'common.advancedMirostatNote',
    ].filter((key) => !keys.includes(key))).toEqual([]);
    expect(missing(keys)).toEqual([]);
    // top_p taken over by Mirostat names the family
    expect(copy.generationRowStatusCopy(rowsById.top_k)).toEqual({ key: 'common.advancedTakenOver', args: { family: { literal: 'Mirostat' } } });
  });
});
