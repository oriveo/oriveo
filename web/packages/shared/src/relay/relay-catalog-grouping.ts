/**
 * Relay model library grouping (a contract shared by all clients; fixture `catalog-groups.v1.json`).
 *
 * The family is supplied by the caller (cached Server by-model family -> RelayFamilyHeuristics, the same family as key binding);
 * group order follows first appearance in the catalog, "Other" always sinks to the bottom; order within a group follows the catalog. The model library and add-step 2 share this one function.
 */

export const RELAY_CATALOG_GROUP_OTHER = 'other';

/** Group names are vendor proper nouns and are not localized; a family id not in the table is used directly as the group name, and "Other" is localized by the caller. */
export const RELAY_CATALOG_GROUP_LABELS: Readonly<Record<string, string>> = {
  openai: 'OpenAI',
  anthropic: 'Anthropic',
  google: 'Google',
  deepseek: 'DeepSeek',
  xai: 'xAI',
  qwen: 'Qwen',
  mistral: 'Mistral',
  minimax: 'MiniMax',
  zhipu: 'Zhipu',
  moonshot: 'Moonshot',
  meta: 'Meta',
};

export interface RelayCatalogGroup<T> {
  id: string;
  /** null = "Other", the caller supplies the localized title. */
  label: string | null;
  models: T[];
}

/** Relays often prefix the model id with a vendor (`anthropic/claude-x`); when the whole string does not identify a family, use the segment after the last `/`; used only for grouping, the family used for key binding is unchanged. */
export function relayFamilyAllowingVendorPrefix(
  modelID: string,
  family: (modelID: string) => string | null | undefined,
): string | null | undefined {
  const hit = family(modelID)?.trim();
  if (hit) return hit;
  const slash = modelID.lastIndexOf('/');
  if (slash < 0) return undefined;
  const tail = modelID.slice(slash + 1);
  return tail ? family(tail) : undefined;
}

export function relayCatalogGroups<T extends { id: string }>(
  models: readonly T[],
  family: (modelID: string) => string | null | undefined,
): RelayCatalogGroup<T>[] {
  const groups = new Map<string, T[]>();
  for (const model of models) {
    const id = relayFamilyAllowingVendorPrefix(model.id, family) || RELAY_CATALOG_GROUP_OTHER;
    const members = groups.get(id);
    if (members) members.push(model);
    else groups.set(id, [model]);
  }
  const ordered = [...groups.keys()].filter((id) => id !== RELAY_CATALOG_GROUP_OTHER);
  if (groups.has(RELAY_CATALOG_GROUP_OTHER)) ordered.push(RELAY_CATALOG_GROUP_OTHER);
  return ordered.map((id) => ({
    id,
    label: id === RELAY_CATALOG_GROUP_OTHER ? null : RELAY_CATALOG_GROUP_LABELS[id] ?? id,
    models: groups.get(id)!,
  }));
}
