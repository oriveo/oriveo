import type { UnsupportedParamScope } from "@oriveo/core/providers/unsupported-param";

/**
 * Self-healing scope for the server route: it **never learns**, which is deliberate rather than unfinished.
 *
 * A Next.js API route is a **process shared across users**: a negative cache written here would apply one
 * 400 observed on user A's relay to user B's request, possibly against a completely different upstream.
 * So only providerKind / modelID / transport are provided, `scopePrefix` is always null, and the
 * semantics are locked to:
 *   - `markUnsupportedParamDropped` always returns 'ineligible' (telemetry only, nothing cached)
 *   - `droppedUnsupportedParams` is always empty (nothing pre-stripped)
 * A single request does not scan error bodies, strip parameters or silently retry either; a precise
 * rejection is persisted only by the browser renderer against the full runtime identity and waits for the
 * user to resend explicitly (see capabilityLearningIdentity in `lib/core/chat/capability-evidence.ts`).
 */
export function serverSelfHealScope(
  providerKind: string,
  modelID: string,
  transport: string | undefined,
): UnsupportedParamScope {
  return { providerKind, modelID, ...(transport ? { transport } : {}) };
}

export {
  executeWithUnsupportedParamSelfHeal,
  droppedUnsupportedParams,
  extractUnsupportedParam,
  markUnsupportedParamDropped,
  runtimeUnsupportedParamEvidenceCandidates,
  resetUnsupportedParamCacheForTesting,
  setUnsupportedParamPatterns,
  stripKnownUnsupportedParams,
  stripUnsupportedParam,
} from "@oriveo/core/providers/unsupported-param";
