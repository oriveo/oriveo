/**
 * How to handle a panel generation parameter rejected by upstream (shared contract `generation_parameter_contract.v1.cases.json` resolverCases:
 * `exact_structured_400_before_stream_requires_explicit_resend` / `unlocated_400_surfaces_without_learning` /
 * `status_422_does_not_self_heal` / `started_stream_never_retries`).
 *
 * Web never strips generation parameters automatically, never retries automatically and never learns a negative cache: the only way out is when a 400 before
 * the stream starts is pinpointed by a structured field of the error body to "an item that was really written into this request", and then, after the user confirms, the request is resent once without that item.
 */
export type GenerationParameterRejectionInput = {
  /** HTTP status; absent for in-stream error frames. */
  status?: number;
  /** Any upstream event has been received (text, thinking, tool calls, ...). */
  streamStarted: boolean;
  sideEffects: boolean;
  /** Raw structured fields of the error body, keyed by JSON pointer (e.g. `/error/param`); never mined from prose. */
  errorFields?: Readonly<Record<string, string>>;
  /** Parameter ids that `writeGenerationParameters` actually wrote in this request. */
  written: readonly string[];
  /** Parameter id -> wire path; defaults to comparing by the id itself. */
  wire?: Readonly<Record<string, string>>;
};

export type GenerationParameterRejectionDecision = {
  stripOnce: false;
  retry: false;
  learnNegative: false;
  action: 'surface_error' | 'user_confirmed_resend_without_located_setting';
  /** The located item; only given for `user_confirmed_resend_without_located_setting`. */
  parameterId?: string;
  /** What happens to the saved value of that item: kept, just not sent this once. */
  preference?: 'dormant';
};

const SURFACE: GenerationParameterRejectionDecision = { stripOnce: false, retry: false, learnNegative: false, action: 'surface_error' };

/** Field named by the error body -> parameter written this time: located only if the wire path matches exactly and uniquely. */
function locateWrittenParameter(input: GenerationParameterRejectionInput): string | undefined {
  const named = input.errorFields?.['/error/param'];
  if (!named) return undefined;
  const matches = input.written.filter((id) => (input.wire?.[id] ?? id) === named);
  return matches.length === 1 ? matches[0] : undefined;
}

export function decideGenerationParameterRejection(input: GenerationParameterRejectionInput): GenerationParameterRejectionDecision {
  if (input.status !== 400 || input.streamStarted || input.sideEffects) return SURFACE;
  const parameterId = locateWrittenParameter(input);
  if (!parameterId) return SURFACE;
  return { ...SURFACE, action: 'user_confirmed_resend_without_located_setting', parameterId, preference: 'dormant' };
}

/** "Resend without this setting": only this one request writes "do not send" in the highest-priority one-shot layer; the saved setting is untouched. */
export function omitOnceOverrides(parameterIds: readonly string[]): Record<string, { state: 'omit' }> {
  return Object.fromEntries(parameterIds.map((id) => [id, { state: 'omit' as const }]));
}
