/**
 * Parses the `WWW-Authenticate` header of 401 / 403 responses and decides whether a response means
 * "sign-in required". Behaviour matches the iOS `McpWWWAuthenticate` / `McpAuthResponseMapping`.
 */

export interface McpAuthChallenge {
  /** `resource_metadata` (RFC 9728 §5.1), the raw string; the discovery step checks it is https before use. */
  resourceMetadata: string | null;
  scope: string | null;
  error: string | null;
  errorDescription: string | null;
}

/** Parses `WWW-Authenticate` (RFC 7235 auth-param). Returns `null` for an empty value. */
export function parseWwwAuthenticate(header: string | null | undefined): McpAuthChallenge | null {
  if (!header || header.trim().length === 0) return null;
  const challenge: McpAuthChallenge = { resourceMetadata: null, scope: null, error: null, errorDescription: null };
  const space = header.indexOf(' ');
  if (space < 0) return challenge;
  for (const token of splitAuthParams(header.slice(space + 1))) {
    const equals = token.indexOf('=');
    if (equals < 0) continue;
    const name = token.slice(0, equals).trim().toLowerCase();
    let value = token.slice(equals + 1).trim();
    if (value.length >= 2 && value.startsWith('"') && value.endsWith('"')) value = value.slice(1, -1);
    if (name === 'resource_metadata') challenge.resourceMetadata = value;
    else if (name === 'scope') challenge.scope = value;
    else if (name === 'error') challenge.error = value;
    else if (name === 'error_description') challenge.errorDescription = value;
  }
  return challenge;
}

/** Splits on commas, except commas inside quotes (scope values contain spaces, error_description may contain commas). */
function splitAuthParams(text: string): string[] {
  const result: string[] = [];
  let start = 0;
  let inQuotes = false;
  for (let i = 0; i < text.length; i++) {
    const char = text[i];
    if (char === '"') inQuotes = !inQuotes;
    else if (char === ',' && !inQuotes) {
      result.push(text.slice(start, i));
      start = i + 1;
    }
  }
  result.push(text.slice(start));
  return result;
}

/** Step-up authorization is not implemented: a 401, or a 403 with `insufficient_scope`, both count as "sign-in required". */
export function requiresAuthResponse(status: number, wwwAuthenticate: string | null | undefined): boolean {
  if (status === 401) return true;
  return status === 403 && parseWwwAuthenticate(wwwAuthenticate)?.error === 'insufficient_scope';
}
