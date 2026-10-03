/**
 * Scrubs an MCP target address into a form that is safe to put in response headers and error bodies.
 *
 * The criteria match the definition of an address that carries a secret (fixture
 * `shared/test-fixtures/mcp/local-only.json`). Many services put the secret straight into the
 * address, and it can sit in any of three places:
 * 1. Query string: replaced as a whole. Sensitive parameter names are not picked one by one: in a
 *    key-only form such as `?x` the key itself is the secret.
 * 2. Userinfo component: removed as a whole.
 * 3. Path segments: a segment of at least 20 characters containing both letters and digits is replaced.
 *
 * The fragment is never sent upstream and is useless for troubleshooting, so it is dropped as well.
 */
const REDACTED = "***";

function looksLikeSecretSegment(segment: string): boolean {
  return segment.length >= 20 && /[A-Za-z]/.test(segment) && /[0-9]/.test(segment);
}

function decodeSegment(segment: string): string {
  try {
    return decodeURIComponent(segment);
  } catch {
    return segment;
  }
}

export function redactTargetURL(value: string): string {
  let url: URL;
  try {
    url = new URL(value);
  } catch {
    // If it cannot be parsed, do not risk echoing any part of it.
    return "<invalid-url>";
  }
  const path = url.pathname
    .split("/")
    // A match in either the percent-encoded or the decoded form counts: encoding only changes the spelling, the secret is the same.
    .map((segment) =>
      looksLikeSecretSegment(segment) || looksLikeSecretSegment(decodeSegment(segment)) ? REDACTED : segment,
    )
    .join("/");
  const query = url.search ? `?${REDACTED}` : "";
  return `${url.protocol}//${url.host}${path}${query}`;
}
