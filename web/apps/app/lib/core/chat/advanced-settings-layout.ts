/**
 * Advanced settings grouping layout, the trailing summary of subgroup rows, and the footnote of the common card.
 * Derived entirely from the parameter table (each parameter's group and declaration order); no page is hardcoded
 * for any engine, and the family table comes only from the row model's `GENERATION_PARAMETER_FAMILIES`.
 * Copy slots are always semantic enums.
 */
import {
  GENERATION_PARAMETER_FAMILIES,
  type GenerationParameterDisplayValue,
  type GenerationParameterRow,
  type GenerationParameterUnsetLabel,
} from './generation-parameter-rows';

export const ADVANCED_COMMON_PARAMETER_IDS = ['max_output_tokens', 'temperature', 'top_k', 'top_p', 'min_p'] as const;
export type AdvancedSectionTitle = 'common' | 'more' | 'reasoning' | 'antiRepetition' | 'moreSampling' | 'output' | 'engineRuntime' | `family:${string}`;
export type AdvancedClusterTitle = { kind: 'group'; group: string } | { kind: 'family'; familyId: string } | { kind: 'parameters'; ids: string[] };
export type AdvancedFamilyNote = { kind: 'familyNote'; familyId: string };
export type AdvancedClusterSubtitle = AdvancedFamilyNote | { kind: 'includes'; memberIds: string[] };
export interface AdvancedSettingsCluster { id: string; title: AdvancedClusterTitle; subtitle?: AdvancedClusterSubtitle; headId?: string; memberIds: string[] }
export type AdvancedModeLabel = { kind: 'off' } | { kind: 'literal'; text: string };
export type AdvancedSettingsItem =
  | { kind: 'parameter'; id: string }
  | { kind: 'mode'; parameterId: string; description?: AdvancedFamilyNote; options: Array<{ value: number; label: AdvancedModeLabel }> }
  | { kind: 'cluster'; cluster: AdvancedSettingsCluster };
export interface AdvancedSettingsSection { id: string; title?: AdvancedSectionTitle; items: AdvancedSettingsItem[] }
export type AdvancedClusterSummary = { emphasized: boolean } & (
  | { kind: 'value' | 'titledValue'; parameterId: string; displayValue: GenerationParameterDisplayValue }
  | { kind: 'rowTrailing'; parameterId: string; displayValue?: GenerationParameterDisplayValue; unsetLabel?: GenerationParameterUnsetLabel }
  | { kind: 'off' | 'plainText' | 'notAdjusted' }
  | { kind: 'adjustedCount'; count: number });
export type AdvancedCommonFootnote = { kind: 'engineDefaults'; engineName: string } | { kind: 'takenOver'; familyIds: string[] };

type LayoutParameter = { id: string; group?: string };

const MORE_GROUP_ORDER = ['budget', 'reasoning', 'sampling', 'repetition', 'reproducibility', 'output_contract', 'engine_runtime'];
/** The remaining parameters are split into multiple sections only above this count (llama.cpp and the like). */
const SINGLE_SECTION_LIMIT = 8;
const FAMILY_NOTES = new Set(['mirostat', 'dry', 'xtc', 'dynatemp']);
const MEMBER_SHORT_TITLES: Readonly<Record<string, { title: 'targetEntropy' | 'learningRate'; symbol: string }>> = {
  mirostat_tau: { title: 'targetEntropy', symbol: 'tau' },
  mirostat_eta: { title: 'learningRate', symbol: 'eta' },
};

const groupOf = (parameter: LayoutParameter) => parameter.group ?? 'sampling';
const row = (id: string): AdvancedSettingsItem => ({ kind: 'parameter', id });

export function advancedSettingsSections(parameters: ReadonlyArray<LayoutParameter>): AdvancedSettingsSection[] {
  const present = new Set(parameters.map((parameter) => parameter.id));
  const commonIds = ADVANCED_COMMON_PARAMETER_IDS.filter((id) => present.has(id));
  const common = new Set<string>(commonIds);
  const rest = parameters.filter((parameter) => !common.has(parameter.id));
  const sections: AdvancedSettingsSection[] = [];
  if (commonIds.length > 0) {
    sections.push({ id: 'common', ...(rest.length > 0 ? { title: 'common' as const } : {}), items: commonIds.map(row) });
  }
  if (rest.length === 0) return sections;
  if (rest.length <= SINGLE_SECTION_LIMIT) {
    sections.push({ id: 'more', title: 'more', items: groupRows(rest) });
    return sections;
  }

  let remaining = [...rest];
  const take = (predicate: (parameter: LayoutParameter) => boolean) => {
    const taken = remaining.filter(predicate);
    remaining = remaining.filter((parameter) => !predicate(parameter));
    return taken;
  };
  const push = (section: AdvancedSettingsSection) => { if (section.items.length > 0) sections.push(section); };

  for (const family of GENERATION_PARAMETER_FAMILIES) {
    if (!family.takeover || !remaining.some((parameter) => parameter.id === family.head)) continue;
    const memberIds = new Set(family.members);
    const members = take((parameter) => parameter.id === family.head || memberIds.has(parameter.id))
      .filter((parameter) => parameter.id !== family.head);
    push({
      id: `family:${family.id}`,
      title: `family:${family.id}`,
      items: [
        {
          kind: 'mode', parameterId: family.head,
          ...(FAMILY_NOTES.has(family.id) ? { description: { kind: 'familyNote' as const, familyId: family.id } } : {}),
          options: [
            { value: 0, label: { kind: 'off' } },
            ...family.takeover.tiers.map((tier) => ({ value: tier, label: { kind: 'literal' as const, text: `v${tier}` } })),
          ],
        },
        ...members.map((parameter) => row(parameter.id)),
      ],
    });
  }
  push({ id: 'reasoning', title: 'reasoning', items: take((parameter) => groupOf(parameter) === 'reasoning').map((parameter) => row(parameter.id)) });
  push({ id: 'repetition', title: 'antiRepetition', items: familyRows(take((parameter) => groupOf(parameter) === 'repetition')) });
  push({ id: 'moreSampling', title: 'moreSampling', items: familyRows(take((parameter) => groupOf(parameter) === 'sampling'), true) });
  const budget = take((parameter) => groupOf(parameter) === 'budget');
  const reproducibility = take((parameter) => groupOf(parameter) === 'reproducibility');
  const contract = take((parameter) => groupOf(parameter) === 'output_contract');
  push({
    id: 'output',
    title: 'output',
    items: [
      ...[...budget, ...reproducibility].map((parameter) => row(parameter.id)),
      ...(contract.length > 1 ? [groupCluster('output_contract', contract)] : contract.map((parameter) => row(parameter.id))),
    ],
  });
  push({ id: 'engineRuntime', title: 'engineRuntime', items: remaining.map((parameter) => row(parameter.id)) });
  return sections;
}

export function advancedMemberShortTitle(id: string): { title: 'targetEntropy' | 'learningRate'; symbol: string } | undefined {
  return MEMBER_SHORT_TITLES[id];
}

/** The "More" section: one row per group in group order (a group with a single parameter is just that row); groups outside the group order go last in order of appearance. */
function groupRows(parameters: readonly LayoutParameter[]): AdvancedSettingsItem[] {
  const groups = new Map<string, LayoutParameter[]>();
  for (const parameter of parameters) groups.set(groupOf(parameter), [...groups.get(groupOf(parameter)) ?? [], parameter]);
  const order = [...MORE_GROUP_ORDER, ...[...groups.keys()].filter((group) => !MORE_GROUP_ORDER.includes(group))];
  return order.flatMap((group) => {
    const members = groups.get(group);
    if (!members) return [];
    return members.length === 1 ? [row(members[0].id)] : [groupCluster(group, members)];
  });
}

function groupCluster(group: string, members: readonly LayoutParameter[]): AdvancedSettingsItem {
  return { kind: 'cluster', cluster: { id: `group:${group}`, title: { kind: 'group', group }, memberIds: members.map((parameter) => parameter.id) } };
}

/**
 * Families within a group (the family head and at least one member are both in the group) fold into one row,
 * ordered by where each family first appears in the group; loose parameters that form no family always follow
 * all families, and with `collectLoose` more than 2 of them fold into one row.
 */
function familyRows(parameters: readonly LayoutParameter[], collectLoose = false): AdvancedSettingsItem[] {
  const ids = new Set(parameters.map((parameter) => parameter.id));
  const familyOf = new Map<string, AdvancedSettingsCluster>();
  for (const family of GENERATION_PARAMETER_FAMILIES) {
    const members = family.members.filter((id) => ids.has(id));
    if (!ids.has(family.head) || members.length === 0) continue;
    const subtitle: AdvancedClusterSubtitle | undefined = FAMILY_NOTES.has(family.id)
      ? { kind: 'familyNote', familyId: family.id }
      : family.id === 'repeat' ? { kind: 'includes', memberIds: members } : undefined;
    const cluster: AdvancedSettingsCluster = {
      id: `family:${family.id}`, title: { kind: 'family', familyId: family.id }, ...(subtitle ? { subtitle } : {}),
      headId: family.head, memberIds: [family.head, ...members],
    };
    for (const id of cluster.memberIds) familyOf.set(id, cluster);
  }
  const loose = parameters.filter((parameter) => !familyOf.has(parameter.id)).map((parameter) => parameter.id);
  const collapseLoose = collectLoose && loose.length > 2;
  const items: AdvancedSettingsItem[] = [];
  const placed = new Set<string>();
  for (const parameter of parameters) {
    const cluster = familyOf.get(parameter.id);
    if (cluster && !placed.has(cluster.id)) items.push({ kind: 'cluster', cluster });
    if (cluster) placed.add(cluster.id);
  }
  if (collapseLoose) {
    items.push({ kind: 'cluster', cluster: { id: 'loose:sampling', title: { kind: 'parameters', ids: loose.slice(0, 3) }, memberIds: loose } });
  } else {
    items.push(...loose.map(row));
  }
  return items;
}

export function advancedClusterSummary(
  cluster: AdvancedSettingsCluster,
  rowsById: Readonly<Record<string, GenerationParameterRow>>,
): AdvancedClusterSummary {
  const members = cluster.memberIds.flatMap((id) => rowsById[id] ? [rowsById[id]] : []);
  const adjusted = members.filter((item) => item.standing !== 'unset' && !item.isOmitted && item.displayValue);
  const emphasized = adjusted.some((item) => item.standing === 'editedHere');
  const head = cluster.headId ? adjusted.find((item) => item.id === cluster.headId) : undefined;
  if (head?.displayValue) return { kind: 'value', parameterId: head.id, displayValue: head.displayValue, emphasized };
  if (adjusted.length === 0) {
    if (cluster.headId) return { kind: 'off', emphasized };
    if (cluster.memberIds.length === 1) {
      const only = rowsById[cluster.memberIds[0]];
      return {
        kind: 'rowTrailing', parameterId: cluster.memberIds[0],
        ...(only?.displayValue ? { displayValue: only.displayValue } : {}),
        ...(only?.unsetLabel ? { unsetLabel: only.unsetLabel } : {}),
        emphasized,
      };
    }
    return { kind: cluster.id === 'group:output_contract' ? 'plainText' : 'notAdjusted', emphasized };
  }
  if (adjusted.length === 1) return { kind: 'titledValue', parameterId: adjusted[0].id, displayValue: adjusted[0].displayValue!, emphasized };
  return { kind: 'adjustedCount', count: adjusted.length, emphasized };
}

export function advancedCommonFootnote(
  rows: readonly GenerationParameterRow[],
  commonIds: readonly string[],
  engineName?: string,
): AdvancedCommonFootnote[] {
  const common = new Set(commonIds);
  const commonRows = rows.filter((item) => common.has(item.id));
  const notes: AdvancedCommonFootnote[] = [];
  if (engineName && commonRows.some((item) => item.standing === 'unset' && item.engineDefault)) {
    notes.push({ kind: 'engineDefaults', engineName });
  }
  const familyIds = [...new Set(commonRows.flatMap((item) => item.supersededById ? [item.supersededById] : []))];
  if (familyIds.length > 0) notes.push({ kind: 'takenOver', familyIds });
  return notes;
}
