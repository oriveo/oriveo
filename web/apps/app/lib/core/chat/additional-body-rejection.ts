/**
 * Error card for a local additional-body rejection: safe code -> copy key.
 *
 * The safe code `additional_body_rejected:<reason>[:<field>][@line]` is produced by core's `additionalBodyRejectionCode`.
 * The field slot can only hold one of Oriveo's own root field names or a blocked segment name, never user-written keys or values, so it may appear in the error card.
 * Error card body = reason sentence (a syntax error is prefixed with "Line N:") + "This message was not sent."; the technical details hold only the safe code.
 */
export const ADDITIONAL_BODY_ERROR_KIND = 'additionalBodyRejected';

/** "Go edit": sent by the error card and received by whoever mounts the model options overlay (opens the additional body editor). */
export const OPEN_ADDITIONAL_BODY_EDITOR_EVENT = 'oriveo:open-additional-body-editor';

const CODE_PATTERN = /additional_body_rejected:[a-z_]+(?::[^\s@]+)?(?:@\d+)?/;

const REASON_KEYS: Record<string, string> = {
  invalid_json: 'reasonInvalidJson',
  not_object: 'reasonNotObject',
  too_deep: 'reasonTooDeep',
  too_large: 'reasonTooLarge',
  protected_field: 'reasonProtectedField',
  blocked_segment: 'reasonBlockedSegment',
};

/** Extracts the safe code from a thrown error (`code` / `detail` / `message`) or a string; returns null when it is not an additional body rejection. */
export function additionalBodyRejectionCode(source: unknown): string | null {
  const candidates: unknown[] = typeof source === 'string'
    ? [source]
    : source && typeof source === 'object'
      ? [(source as { code?: unknown }).code, (source as { detail?: unknown }).detail, (source as { message?: unknown }).message]
      : [];
  for (const candidate of candidates) {
    if (typeof candidate !== 'string') continue;
    const match = CODE_PATTERN.exec(candidate);
    if (match) return match[0];
  }
  return null;
}

/** Copy keys live under `errors.additionalBodyRejected.*`. An unknown reason invents no reason and only says "not sent". */
export function additionalBodyRejectionCopy(code: string): { reasonKey: string; values?: Record<string, string>; line?: number } {
  const match = /^additional_body_rejected:([a-z_]+)(?::([^@]+))?(?:@(\d+))?$/.exec(code);
  const reasonKey = match ? REASON_KEYS[match[1]] : undefined;
  if (!match || !reasonKey) return { reasonKey: 'message' };
  return {
    reasonKey,
    ...(match[2] ? { values: { field: match[2] } } : {}),
    ...(match[3] ? { line: Number(match[3]) } : {}),
  };
}

/** Error card body. `te` = the translation function of the `errors` namespace. */
export function additionalBodyRejectionDetail(
  code: string,
  te: (key: string, values?: Record<string, string | number>) => string,
): string {
  const copy = additionalBodyRejectionCopy(code);
  const notSent = te('additionalBodyRejected.message');
  if (copy.reasonKey === 'message') return notSent;
  const reason = te(`additionalBodyRejected.${copy.reasonKey}`, copy.values);
  const sentence = copy.line ? te('additionalBodyRejected.line', { line: copy.line, reason }) : reason;
  return `${sentence} ${notSent}`;
}

/** Failure message patch: the body becomes the reason sentence and the technical details hold only the safe code. Returns undefined when it is not an additional body rejection. */
export function additionalBodyFailurePatch(
  error: unknown,
  te: (key: string, values?: Record<string, string | number>) => string,
): { errorDetail: string; errorTechnicalDetail: string } | undefined {
  if (!error || typeof error !== 'object' || (error as { kind?: unknown }).kind !== ADDITIONAL_BODY_ERROR_KIND) return undefined;
  const code = additionalBodyRejectionCode(error);
  if (!code) return undefined;
  return { errorDetail: additionalBodyRejectionDetail(code, te), errorTechnicalDetail: code };
}
