/**
 * OAuth PKCE, pure computation.
 *
 * Dependency free: crypto (randomBytes / sha256) is injected through a port, the main process
 * injects Node `webcrypto` and tests inject a mock, and core never reaches for a global crypto
 * directly.
 *
 * PKCE per RFC 7636: code_challenge = base64url(SHA256(code_verifier)), method=S256.
 * state is a base64url random nonce guarding against CSRF and against crossed in-flight requests.
 */

/**
 * Narrow crypto port used only by this file. Its shape differs from the CryptoPort in
 * ports/index.ts, which targets AES backups; this one only needs randomBytes and sha256 -> Uint8Array.
 * The main process injects Node webcrypto, tests inject a mock.
 */
export interface PkceCryptoPort {
  /** Return n cryptographically secure random bytes. */
  randomBytes(n: number): Uint8Array;
  /** SHA-256 digest, 32 bytes. */
  sha256(data: Uint8Array): Promise<Uint8Array>;
}

const VERIFIER_BYTES = 32; // 32B -> 43 char base64url, inside the RFC 7636 [43,128] range
const STATE_BYTES = 24;

/** RFC 4648 §5 base64url, no padding. */
export function base64UrlEncode(bytes: Uint8Array): string {
  let binary = '';
  for (let i = 0; i < bytes.length; i++) {
    binary += String.fromCharCode(bytes[i]!);
  }
  // btoa is available both in the Node main process and in the browser renderer (globalThis.btoa).
  return globalThis
    .btoa(binary)
    .replace(/\+/g, '-')
    .replace(/\//g, '_')
    .replace(/=+$/, '');
}

/** Generate a PKCE verifier and its S256 challenge. */
export async function genPkce(c: PkceCryptoPort): Promise<{ verifier: string; challenge: string }> {
  const verifier = base64UrlEncode(c.randomBytes(VERIFIER_BYTES));
  // challenge = base64url(sha256(ASCII(verifier)))
  const digest = await c.sha256(asciiBytes(verifier));
  const challenge = base64UrlEncode(digest);
  return { verifier, challenge };
}

/** Generate an OAuth state nonce (guards against CSRF and crossed in-flight requests). */
export function genState(c: PkceCryptoPort): string {
  return base64UrlEncode(c.randomBytes(STATE_BYTES));
}

/** Parse a token response: take access_token on success, normalize the error string on failure. */
export function parseTokenResponse(json: unknown): { accessToken: string } | { error: string } {
  if (!json || typeof json !== 'object') return { error: 'invalid_response' };
  const obj = json as Record<string, unknown>;
  if (typeof obj.error === 'string' && obj.error.length > 0) {
    return { error: obj.error };
  }
  if (typeof obj.access_token === 'string' && obj.access_token.length > 0) {
    return { accessToken: obj.access_token };
  }
  return { error: 'missing_access_token' };
}

/** Build the token exchange request body (PKCE public client, no client_secret). */
export function buildTokenExchangeBody(p: {
  clientId: string;
  code: string;
  verifier: string;
  redirectUri: string;
}): string {
  const body = new URLSearchParams();
  body.set('client_id', p.clientId);
  body.set('code', p.code);
  body.set('code_verifier', p.verifier);
  body.set('redirect_uri', p.redirectUri);
  body.set('grant_type', 'authorization_code');
  return body.toString();
}

function asciiBytes(s: string): Uint8Array {
  const out = new Uint8Array(s.length);
  for (let i = 0; i < s.length; i++) out[i] = s.charCodeAt(i) & 0xff;
  return out;
}
