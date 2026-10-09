export type AdditionalBodyRetryInput = {
  /** Send-path fact: the merger actually merged non-empty content into the final request body (not merely "it is in storage"). */
  additionalBodyApplied: boolean;
  /** Any upstream event (text, thinking, tool call, ...) has been received. */
  receivedUpstreamEvent: boolean;
  sideEffects: boolean;
  /** Rejected locally (no request was sent). */
  localRejection: boolean;
  /** HTTP status; omitted for an in-stream error frame and for the empty-stream fallback. */
  httpStatus?: number;
  /** An in-stream error frame received before any content; `classifiedKind` is the already classified way out (quota / rate limit / auth / model unavailable). */
  streamErrorFrame?: { classifiedKind?: string };
};

/** Classified in-stream errors that each have their own way out: omitting the additional body would not fix them, so this way out is not offered. */
const CLASSIFIED_STREAM_ERROR_KINDS = new Set([
  'quotaExceeded', 'insufficientBalance', 'rateLimited', 'invalidKey', 'unauthorized', 'unavailable',
]);

/**
 * The "retry without the additional body" way out (same structure as `locateCapabilityRecovery` in
 * `capability-recovery-runtime`: rule out first, then recognize the rejection shape). It is not
 * offered for the empty-stream fallback: the contract recognizes "an error frame was received",
 * not "nothing was received".
 */
export function additionalBodyRetryEligible(input: AdditionalBodyRetryInput): boolean {
  if (!input.additionalBodyApplied || input.localRejection || input.receivedUpstreamEvent || input.sideEffects) return false;
  if (input.httpStatus === 400) return true;
  if (input.streamErrorFrame) {
    const kind = input.streamErrorFrame.classifiedKind;
    return !kind || !CLASSIFIED_STREAM_ERROR_KINDS.has(kind);
  }
  return false;
}
