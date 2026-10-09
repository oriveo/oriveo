/**
 * Tag-style editing of stop sequences: one tag per sequence, invisible characters made visible, and the rules for adding and removing.
 * A sequence may itself contain commas, spaces, and newlines, so nothing is ever split.
 */

/** Newline shows as ↵, tab as ⇥, and space as ␣; \r\n counts as a single newline. */
export function visibleStopSequence(sequence: string): string {
  return sequence.replace(/\r\n|\r|\n/g, '↵').replace(/\t/g, '⇥').replace(/ /g, '␣');
}

/** Empty, a duplicate of an existing entry, or already at the limit: not added, returns null. An omitted `limit` means the parameter table declares none, so there is no cap. */
export function addStopSequence(list: readonly string[], draft: string, limit?: number): string[] | null {
  if (!draft || list.includes(draft) || !canAddStopSequence(list, limit)) return null;
  return [...list, draft];
}

export function removeStopSequence(list: readonly string[], index: number): string[] {
  return list.filter((_, position) => position !== index);
}

/** Hide "Add" once the limit is reached. */
export function canAddStopSequence(list: readonly string[], limit?: number): boolean {
  return limit === undefined || list.length < limit;
}
