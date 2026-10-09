import { RELAY_REDACTED_PLACEHOLDER } from '@oriveo/shared/relay/endpoint-policy';

/** Cap (in UTF-8 bytes) on upstream error text before it enters the body / technical details. */
export const UPSTREAM_ERROR_TEXT_MAX_BYTES = 2048;

/**
 * The single exit for upstream error text: first scrubs the credentials of this request, then truncates by bytes (never leaving half a multibyte character at the cut).
 * Credentials are replaced longest first, so a short credential cannot match part of a long one and leave a fragment of the long one behind.
 */
export function sanitizeUpstreamErrorText(
  text: string,
  credentials: readonly (string | undefined | null)[] = [],
  maxBytes: number = UPSTREAM_ERROR_TEXT_MAX_BYTES,
): string {
  let out = text;
  const secrets = [...new Set(credentials.filter((value): value is string => typeof value === 'string' && value.length >= 4))]
    .sort((a, b) => b.length - a.length);
  // Same marker as `redactRelayCredentials` on the Relay side: technical details have only one spelling.
  for (const secret of secrets) out = out.split(secret).join(RELAY_REDACTED_PLACEHOLDER);
  const bytes = new TextEncoder().encode(out);
  if (bytes.length <= maxBytes) return out;
  // A decoder with fatal=false turns a half character at the cut into U+FFFD; instead step back to a whole character boundary.
  let end = maxBytes;
  while (end > 0 && (bytes[end] & 0xc0) === 0x80) end -= 1;
  return new TextDecoder().decode(bytes.subarray(0, end));
}

/**
 * An OpenAI-style top-level `error` inside the stream (the shape Relay Chat / native llama.cpp etc. put straight into a data frame).
 * It only recognises the frame and does no classification; null means this frame is not an error frame.
 */
export function readTopLevelErrorFrame(chunk: unknown): { message: string; typeOrCode?: string } | null {
  if (!chunk || typeof chunk !== 'object') return null;
  const error = (chunk as { error?: unknown }).error;
  if (typeof error === 'string' && error) return { message: error };
  if (!error || typeof error !== 'object') return null;
  const { message, type, code } = error as { message?: unknown; type?: unknown; code?: unknown };
  const typeOrCode = typeof type === 'string' ? type : typeof code === 'string' ? code : undefined;
  return { message: typeof message === 'string' && message ? message : 'Provider error', ...(typeOrCode ? { typeOrCode } : {}) };
}
