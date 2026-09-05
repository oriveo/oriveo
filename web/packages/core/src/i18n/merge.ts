/**
 * i18n  A02 §3.3  Web +  
 *
 *   fallback  key  
 *   key   15  
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
