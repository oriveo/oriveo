/**
 * Metadata runtime constants (single source of truth for the web client).
 *
 * Constants that must stay semantically aligned across clients live here, in their own module so
 * that mocking metadata-client in tests does not replace them as well.
 */

/**
 * contractVersion supported by this client.
 *
 * Compatibility window: `[N-1, N+1]` is consumed normally, `>= N+2` drops into safe degradation.
 * The initial release value is `1`; a breaking backend change must raise contractVersion, and
 * this constant follows it.
 */
export const SUPPORTED_CONTRACT_VERSION = 1;

/**
 * Whether a given contractVersion is above this client's safe-degradation threshold.
 *
 * `true` means the metadata contractVersion is too new (>= N+2), so the client must keep only
 * Manual-Retained plus already enabled models and must not extend the official catalog.
 *
 * @param contractVersion bundled catalog `contractVersion`
 */
export function isContractVersionDegraded(contractVersion: number | null | undefined): boolean {
  if (contractVersion == null) return false;
  return contractVersion >= SUPPORTED_CONTRACT_VERSION + 2;
}

/**
 * Manual-Retained pruning switch (the `metadata.authoritative.v1` flag).
 *
 * - `false` (pre-launch default): locally enabled models that metadata does not list are kept,
 *   tagged `source=manualRetained` and shown as their own group in the UI, which keeps the first
 *   migration round compatible
 * - `true` (flipped after launch): the Manual-Retained read/write path closes and the first
 *   resync prunes those models in one pass
 *
 * Where the web client reads this constant:
 *   - `buildOfficialEnabledModels`: whether to prune local ids that metadata misses
 *   - `hydrateMetadataAndReconcileProviders` (bootstrap): behaviour when recomputing at startup
 *
 * Every client has to flip this switch together so the semantics stay consistent.
 */
export const MANUAL_RETAINED_PRUNING_ENABLED = false;
