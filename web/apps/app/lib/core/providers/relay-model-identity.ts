import type { AIModel } from '@oriveo/shared';

/**
 * Model identity of a relay (kind relay, including local engines): identical by literal ID, trim + lowercase;
 * date snapshots, canonicalModelId and display names never take part. Web has no old prefix to strip.
 * canonical is read only once, in `resolveRelayStoredModel`, when resolving historical stored values.
 */
export function relayModelKey(id: string | null | undefined): string {
  return id?.trim().toLowerCase() ?? '';
}

export function sameRelayModel(a: Pick<AIModel, 'id'>, b: Pick<AIModel, 'id'>): boolean {
  const key = relayModelKey(a.id);
  return key !== '' && key === relayModelKey(b.id);
}

/** Pure literal lookup: the first one with an equal key; no canonical / date-stripping fallback. */
export function findRelayModel<T extends Pick<AIModel, 'id'>>(
  models: readonly T[],
  query: string | null | undefined,
): T | undefined {
  const key = relayModelKey(query);
  if (!key) return undefined;
  return models.find((model) => relayModelKey(model.id) === key);
}

/** Value written into session / message / last-used: the literal model.id. */
export function relayStoredModelId(model: Pick<AIModel, 'id'>): string {
  return model.id;
}

/** De-duplicate by key, keep order, the first one wins. */
export function deduplicateRelayModels<T extends Pick<AIModel, 'id'>>(models: readonly T[]): T[] {
  const seen = new Set<string>();
  return models.filter((model) => {
    const key = relayModelKey(model.id);
    if (seen.has(key)) return false;
    seen.add(key);
    return true;
  });
}

/**
 * Resolve a stored value (current selection, session model, last-used, "removed" check, session row display name): a literal hit is used;
 * otherwise, if exactly one enabled model has a canonical key equal to the stored value's key, use it (a canonical value stored before literal identity); otherwise undefined.
 */
export function resolveRelayStoredModel<T extends Pick<AIModel, 'id' | 'canonicalModelId'>>(
  enabledModels: readonly T[],
  storedModelId: string | null | undefined,
): T | undefined {
  const literal = findRelayModel(enabledModels, storedModelId);
  if (literal) return literal;
  const key = relayModelKey(storedModelId);
  if (!key) return undefined;
  const byCanonical = enabledModels.filter((model) => relayModelKey(model.canonicalModelId) === key);
  return byCanonical.length === 1 ? byCanonical[0] : undefined;
}

/**
 * Parameter key read fallback: when the literal key misses, read the canonical key. If canonical is empty or equal to the literal key there is no fallback key.
 */
export function relayParameterFallbackModelId(model: Pick<AIModel, 'id' | 'canonicalModelId'>): string | undefined {
  const canonical = model.canonicalModelId?.trim();
  if (!canonical || relayModelKey(canonical) === relayModelKey(model.id)) return undefined;
  return canonical;
}

/**
 * Parameter keys to delete on disabling a model: the literal key; the canonical key only if the connection has no other enabled model whose canonical equals it
 * (otherwise it would delete the old record another date snapshot reads back), and it must not be exactly another enabled model's literal key.
 */
export function relayParameterKeysToRemoveOnDisable(
  remainingEnabledModels: readonly Pick<AIModel, 'id' | 'canonicalModelId'>[],
  model: Pick<AIModel, 'id' | 'canonicalModelId'>,
): string[] {
  const canonical = relayParameterFallbackModelId(model);
  if (!canonical) return [model.id];
  const key = relayModelKey(canonical);
  const stillReferenced = remainingEnabledModels.some((other) => relayModelKey(other.canonicalModelId) === key
    || relayModelKey(other.id) === key);
  return stillReferenced ? [model.id] : [model.id, canonical];
}
