/**
 * Case-insensitive matching of AIModel ids.
 *
 * Relays often rewrite model ids with mixed case (`Gpt-Image-1`, `gpt-IMAGE-1`), so a strict
 * `===` comparison loses skill knowledge lookups and model lookups.
 *
 * Only the `id` and `canonicalModelId` fields participate in the match.
 */
export interface ModelIdentityLike {
  id: string;
  canonicalModelId?: string;
}

/**
 * @param model the model entry to test
 * @param target the target model id, usually `retrievalModel` or the modelID the user picked
 */
export function matchModelById(
  model: ModelIdentityLike,
  target: string | null | undefined,
): boolean {
  if (!target) return false;
  const normalized = target.trim().toLowerCase();
  if (!normalized) return false;
  if (model.id.toLowerCase() === normalized) return true;
  const canonical = model.canonicalModelId?.toLowerCase();
  return !!canonical && canonical === normalized;
}
