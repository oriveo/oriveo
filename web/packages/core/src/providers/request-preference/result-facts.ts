/**
 * request_preference_contract.v2 §resultFacts.
 *
 * Building the request and executing the response are two separate things: only a delta that
 * actually went out on the wire counts as requested, and a successful HTTP call with no evidence
 * declared by the recipe is unconfirmed rather than observed. Evidence present with
 * wireApplied=false, for example evidence left over from another request, must not be read back as
 * requested.
 */

import type { ObservationEvidenceKind, ResultState } from './types';

const OBSERVATION_EVIDENCE_KINDS = new Set<ObservationEvidenceKind>([
  'provider_tool_result', 'citation', 'grounding', 'thinking_block', 'reasoning_usage',
]);

export interface ResultIntent {
  wireApplied: boolean;
  providerAccepted: boolean;
  evidenceKinds: readonly string[];
  /** Whether the safe retry decided by retry.ts already happened; if so the terminal state is recovered rather than unconfirmed or observed. */
  recovered?: boolean;
}

export interface ResultFacts {
  state: Exclude<ResultState, 'requested'>;
  requested: boolean;
  observed: boolean;
}

export function classifyResult({
  wireApplied,
  providerAccepted,
  evidenceKinds,
  recovered = false,
}: ResultIntent): ResultFacts {
  if (!wireApplied) return { state: 'not_requested', requested: false, observed: false };
  if (!providerAccepted) return { state: 'rejected', requested: true, observed: false };
  if (recovered) return { state: 'recovered', requested: true, observed: false };
  if (evidenceKinds.some((kind) => OBSERVATION_EVIDENCE_KINDS.has(kind as ObservationEvidenceKind))) {
    return { state: 'observed', requested: true, observed: true };
  }
  return { state: 'unconfirmed', requested: true, observed: false };
}
