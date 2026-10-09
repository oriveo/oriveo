/**
 * Advanced settings grouping layout, subgroup summaries, and the footnote of the common card. The parameter
 * tables are the real ones from `local-engine-profiles.ts`, and the rows are produced by the production
 * row model `generationParameterRows`.
 */
import { describe, expect, it } from 'vitest';
import type { SourcedGenerationParameterOverrides } from '../generation-parameter-settings';
import { generationParameterRows, type GenerationParameterRow } from '../generation-parameter-rows';
import { localEngineGenerationProfile } from '../local-engine-profiles';
import {
  ADVANCED_COMMON_PARAMETER_IDS,
  advancedClusterSummary,
  advancedCommonFootnote,
  advancedMemberShortTitle,
  advancedSettingsSections,
  type AdvancedSettingsCluster,
  type AdvancedSettingsItem,
} from '../advanced-settings-layout';

const llama = localEngineGenerationProfile('llamacpp', undefined)!;
const ollama = localEngineGenerationProfile('ollama', undefined)!;

function clusterOf(item: AdvancedSettingsItem | undefined): AdvancedSettingsCluster {
  if (item?.kind !== 'cluster') throw new Error(`not a cluster: ${JSON.stringify(item)}`);
  return item.cluster;
}

function llamaRows(values: Record<string, unknown>, layer: 'conversation' | 'connection' = 'conversation'): Record<string, GenerationParameterRow> {
  const resolved: SourcedGenerationParameterOverrides = Object.fromEntries(Object.entries(values).map(([id, value]) => [
    id, { override: value === 'omit' ? { state: 'omit' } : { state: 'value', value: value as never }, layer },
  ]));
  const rows = generationParameterRows({
    parameterIds: llama.parameters.map((parameter) => parameter.id),
    profile: llama,
    resolved,
    editingLayers: ['transient', 'conversation'],
  });
  return Object.fromEntries(rows.map((row) => [row.id, row]));
}

describe('advancedSettingsSections', () => {
  it('rest <= 8: common group with a title plus one More section, one row per group, and multi-parameter groups folded into group subgroups', () => {
    const sections = advancedSettingsSections(ollama.parameters);
    expect(sections.map((section) => [section.id, section.title])).toEqual([['common', 'common'], ['more', 'more']]);
    expect(sections[0].items).toEqual(['max_output_tokens', 'temperature', 'top_p'].map((id) => ({ kind: 'parameter', id })));
    const more = sections[1].items;
    expect(more.map((item) => item.kind === 'cluster' ? item.cluster.id : item.kind === 'parameter' ? item.id : item.kind))
      .toEqual(['stop', 'reasoning_effort', 'group:repetition', 'seed', 'group:output_contract']);
    expect(clusterOf(more[2])).toEqual({
      id: 'group:repetition', title: { kind: 'group', group: 'repetition' }, memberIds: ['presence_penalty', 'frequency_penalty'],
    });
  });

  it('parameters without a group count as sampling; no title when only the common group exists', () => {
    expect(advancedSettingsSections([{ id: 'temperature' }, { id: 'max_output_tokens' }])).toEqual([
      { id: 'common', items: [{ kind: 'parameter', id: 'max_output_tokens' }, { kind: 'parameter', id: 'temperature' }] },
    ]);
    const sections = advancedSettingsSections([{ id: 'temperature' }, { id: 'typical_p' }, { id: 'seed', group: 'reproducibility' }, { id: 'tfs_z' }]);
    expect(sections[1].items.map((item) => item.kind === 'cluster' ? item.cluster.id : item.kind === 'parameter' ? item.id : '')).toEqual(['group:sampling', 'seed']);
    expect(clusterOf(sections[1].items[0]).memberIds).toEqual(['typical_p', 'tfs_z']);
  });

  it('llama.cpp chat real table (> 8): Mirostat gets its own section, DRY goes under repetition, and XTC and dynamic temperature go under more sampling', () => {
    const sections = advancedSettingsSections(llama.parameters);
    expect(sections.map((section) => section.id)).toEqual(['common', 'family:mirostat', 'repetition', 'moreSampling', 'output']);
    expect(sections[0].items.map((item) => item.kind === 'parameter' && item.id)).toEqual([...ADVANCED_COMMON_PARAMETER_IDS]);

    const mirostat = sections[1];
    expect(mirostat.title).toBe('family:mirostat');
    expect(mirostat.items).toEqual([
      {
        kind: 'mode', parameterId: 'mirostat', description: { kind: 'familyNote', familyId: 'mirostat' },
        options: [
          { value: 0, label: { kind: 'off' } },
          { value: 1, label: { kind: 'literal', text: 'v1' } },
          { value: 2, label: { kind: 'literal', text: 'v2' } },
        ],
      },
      { kind: 'parameter', id: 'mirostat_tau' },
      { kind: 'parameter', id: 'mirostat_eta' },
    ]);

    const repetition = sections[2];
    expect(repetition.title).toBe('antiRepetition');
    expect(repetition.items.map((item) => clusterOf(item))).toEqual([
      {
        id: 'family:repeat', title: { kind: 'family', familyId: 'repeat' }, headId: 'repeat_penalty',
        subtitle: { kind: 'includes', memberIds: ['repeat_last_n', 'frequency_penalty', 'presence_penalty'] },
        memberIds: ['repeat_penalty', 'repeat_last_n', 'frequency_penalty', 'presence_penalty'],
      },
      {
        id: 'family:dry', title: { kind: 'family', familyId: 'dry' }, headId: 'dry_multiplier',
        subtitle: { kind: 'familyNote', familyId: 'dry' },
        memberIds: ['dry_multiplier', 'dry_base', 'dry_allowed_length', 'dry_penalty_last_n', 'dry_sequence_breakers'],
      },
    ]);

    const sampling = sections[3];
    expect(sampling.title).toBe('moreSampling');
    const samplingClusters = sampling.items.map((item) => clusterOf(item));
    expect(samplingClusters.map((cluster) => cluster.id)).toEqual(['family:xtc', 'family:dynatemp', 'loose:sampling']);
    expect(samplingClusters[2]).toEqual({
      id: 'loose:sampling', title: { kind: 'parameters', ids: ['typical_p', 'top_n_sigma', 'samplers'] },
      memberIds: ['typical_p', 'top_n_sigma', 'samplers', 'min_keep', 'n_keep', 'n_indent'],
    });
    expect(samplingClusters[0].memberIds).toEqual(['xtc_probability', 'xtc_threshold']);
    expect(samplingClusters[1]).toMatchObject({ headId: 'dynatemp_range', subtitle: { kind: 'familyNote', familyId: 'dynatemp' } });

    const output = sections[4];
    expect(output.title).toBe('output');
    expect(output.items.slice(0, 4)).toEqual(['stop', 't_max_predict_ms', 'ignore_eos', 'seed'].map((id) => ({ kind: 'parameter', id })));
    expect(clusterOf(output.items[4]).id).toBe('group:output_contract');

    // Every parameter appears exactly once.
    const placed = sections.flatMap((section) => section.items.flatMap((item) => item.kind === 'parameter' ? [item.id]
      : item.kind === 'mode' ? [item.parameterId] : item.cluster.memberIds));
    expect([...placed].sort()).toEqual(llama.parameters.map((parameter) => parameter.id).sort());
  });

  it('scattered sampling parameters (at most 2) get one row each; a lone output_contract gets a row; the rest fall under engine runtime', () => {
    const parameters = [
      ...['a', 'b', 'c', 'd', 'e', 'f', 'g'].map((id) => ({ id, group: 'engine_runtime' })),
      { id: 'typical_p', group: 'sampling' }, { id: 'samplers', group: 'sampling' },
      { id: 'json_schema', group: 'output_contract' },
    ];
    const sections = advancedSettingsSections(parameters);
    expect(sections.map((section) => section.id)).toEqual(['moreSampling', 'output', 'engineRuntime']);
    expect(sections[0].items).toEqual([{ kind: 'parameter', id: 'typical_p' }, { kind: 'parameter', id: 'samplers' }]);
    expect(sections[1].items).toEqual([{ kind: 'parameter', id: 'json_schema' }]);
    expect(sections[2].items).toHaveLength(7);
  });

  it('short titles for family members', () => {
    expect(advancedMemberShortTitle('mirostat_tau')).toEqual({ title: 'targetEntropy', symbol: 'tau' });
    expect(advancedMemberShortTitle('mirostat_eta')).toEqual({ title: 'learningRate', symbol: 'eta' });
    expect(advancedMemberShortTitle('temperature')).toBeUndefined();
  });
});

describe('advancedClusterSummary', () => {
  const sections = advancedSettingsSections(llama.parameters);
  const clusters = Object.fromEntries(sections.flatMap((section) => section.items.flatMap((item) => item.kind === 'cluster' ? [[item.cluster.id, item.cluster]] : [])));

  it('adjusted family head -> the head display value; emphasized only when changed in this layer', () => {
    expect(advancedClusterSummary(clusters['family:dry'], llamaRows({ dry_multiplier: 0.8, dry_base: 2 }))).toEqual({
      kind: 'value', parameterId: 'dry_multiplier', displayValue: { kind: 'text', text: '0.8' }, emphasized: true,
    });
    expect(advancedClusterSummary(clusters['family:dry'], llamaRows({ dry_multiplier: 0.8 }, 'connection')).emphasized).toBe(false);
  });

  it('not adjusted: family head shows off, output_contract shows plain text, the rest show not adjusted; do-not-send does not count as adjusted', () => {
    const rows = llamaRows({ xtc_threshold: 'omit' });
    expect(advancedClusterSummary(clusters['family:xtc'], rows)).toEqual({ kind: 'off', emphasized: false });
    expect(advancedClusterSummary(clusters['group:output_contract'], rows)).toEqual({ kind: 'plainText', emphasized: false });
    expect(advancedClusterSummary(clusters['loose:sampling'], rows)).toEqual({ kind: 'notAdjusted', emphasized: false });
  });

  it('a single member that is not adjusted -> the trailing text of that row', () => {
    const rows = llamaRows({});
    expect(advancedClusterSummary({ id: 'group:reproducibility', title: { kind: 'group', group: 'reproducibility' }, memberIds: ['seed'] }, rows))
      .toEqual({ kind: 'rowTrailing', parameterId: 'seed', unsetLabel: 'randomEachTime', emphasized: false });
  });

  it('one item adjusted (not the family head) -> title and value', () => {
    expect(advancedClusterSummary(clusters['family:dry'], llamaRows({ dry_base: 2 }))).toEqual({
      kind: 'titledValue', parameterId: 'dry_base', displayValue: { kind: 'text', text: '2' }, emphasized: true,
    });
  });

  it('two or more items adjusted -> N items adjusted', () => {
    expect(advancedClusterSummary(clusters['loose:sampling'], llamaRows({ typical_p: 0.9, n_keep: 4 }, 'connection'))).toEqual({
      kind: 'adjustedCount', count: 2, emphasized: false,
    });
  });
});

describe('advancedCommonFootnote', () => {
  it('two sentences: the gray engine default numbers plus the struck-through taken-over items', () => {
    const rows = Object.values(llamaRows({ mirostat: 2, top_k: 20 }));
    expect(advancedCommonFootnote(rows, ADVANCED_COMMON_PARAMETER_IDS, 'llama.cpp')).toEqual([
      { kind: 'engineDefaults', engineName: 'llama.cpp' },
      { kind: 'takenOver', familyIds: ['mirostat'] },
    ]);
  });

  it('without an engine name the gray numbers are omitted; with neither -> empty', () => {
    const rows = Object.values(llamaRows({}));
    expect(advancedCommonFootnote(rows, ADVANCED_COMMON_PARAMETER_IDS)).toEqual([]);
    const allSet = Object.values(llamaRows(Object.fromEntries(ADVANCED_COMMON_PARAMETER_IDS.map((id) => [id, id === 'max_output_tokens' ? 256 : 0.5]))));
    expect(advancedCommonFootnote(allSet, ADVANCED_COMMON_PARAMETER_IDS, 'llama.cpp')).toEqual([]);
  });
});
