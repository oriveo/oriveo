/**
 * Deep merge of two message bags, used to lay one locale over the English fallback.
 *
 * The merge is per key, not per bag: a locale that has translated only part of a section keeps
 * the English text for the rest instead of dropping the whole section.
 */
export type MessageBag = Record<string, unknown>;

export function deepMerge(fallback: MessageBag, override: MessageBag): MessageBag {
  const merged: MessageBag = { ...fallback };
  for (const [key, value] of Object.entries(override)) {
    const base = merged[key];
    if (
      value !== null &&
      typeof value === 'object' &&
      !Array.isArray(value) &&
      base !== null &&
      typeof base === 'object' &&
      !Array.isArray(base)
    ) {
      merged[key] = deepMerge(base as MessageBag, value as MessageBag);
    } else {
      merged[key] = value;
    }
  }
  return merged;
}
