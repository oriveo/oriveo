import { webcrypto } from 'node:crypto';
import { describe, expect, it } from 'vitest';
import {
  base64UrlEncode,
  buildTokenExchangeBody,
  genPkce,
  genState,
  parseTokenResponse,
  type PkceCryptoPort,
} from './oauth-pkce';

/** Real Node webcrypto injection, matching the runtime, verifying challenge=base64url(sha256(verifier)). */
const realCrypto: PkceCryptoPort = {
  randomBytes: (n) => webcrypto.getRandomValues(new Uint8Array(n)),
  sha256: async (data) => {
    const buf = await webcrypto.subtle.digest('SHA-256', data);
    return new Uint8Array(buf);
  },
};

/** Deterministic mock: randomBytes returns fixed bytes and sha256 is the real digest, so outputs can be asserted exactly. */
function deterministicCrypto(seed: number): PkceCryptoPort {
  return {
    randomBytes: (n) => {
      const out = new Uint8Array(n);
      for (let i = 0; i < n; i++) out[i] = (seed + i) & 0xff;
      return out;
    },
    sha256: realCrypto.sha256,
  };
}

describe('base64UrlEncode', () => {
  it('emits url-safe alphabet without padding', () => {
    // 0xfb 0xff is "+/8=" in standard base64, and "-_8" once url-safe and unpadded.
    const encoded = base64UrlEncode(new Uint8Array([0xfb, 0xff]));
    expect(encoded).not.toMatch(/[+/=]/);
    expect(encoded).toBe('-_8');
  });
});

describe('genPkce', () => {
  it('produces challenge = base64url(sha256(verifier))', async () => {
    const { verifier, challenge } = await genPkce(realCrypto);
    // The verifier is 32 bytes of base64url, so 43 characters, inside the RFC 7636 range of [43,128].
    expect(verifier).toHaveLength(43);
    expect(verifier).not.toMatch(/[+/=]/);

    // Recompute the challenge here rather than trusting genPkce to check its own arithmetic.
    const ascii = new Uint8Array(verifier.length);
    for (let i = 0; i < verifier.length; i++) ascii[i] = verifier.charCodeAt(i) & 0xff;
    const expected = base64UrlEncode(await realCrypto.sha256(ascii));
    expect(challenge).toBe(expected);
    expect(challenge).not.toMatch(/[+/=]/);
  });

  it('is deterministic given a deterministic crypto port (mock injection)', async () => {
    const a = await genPkce(deterministicCrypto(7));
    const b = await genPkce(deterministicCrypto(7));
    expect(a.verifier).toBe(b.verifier);
    expect(a.challenge).toBe(b.challenge);
    // A different seed gives a different verifier.
    const c = await genPkce(deterministicCrypto(9));
    expect(c.verifier).not.toBe(a.verifier);
  });
});

describe('genState', () => {
  it('returns unique url-safe nonces across calls', () => {
    const states = new Set(Array.from({ length: 50 }, () => genState(realCrypto)));
    expect(states.size).toBe(50);
    for (const s of states) expect(s).not.toMatch(/[+/=]/);
  });
});

describe('buildTokenExchangeBody', () => {
  it('builds a PKCE public-client form body without client_secret', () => {
    const body = buildTokenExchangeBody({
      clientId: 'cid',
      code: 'auth-code',
      verifier: 'verifier-xyz',
      redirectUri: 'http://127.0.0.1:9/callback',
    });
    const parsed = new URLSearchParams(body);
    expect(parsed.get('client_id')).toBe('cid');
    expect(parsed.get('code')).toBe('auth-code');
    expect(parsed.get('code_verifier')).toBe('verifier-xyz');
    expect(parsed.get('grant_type')).toBe('authorization_code');
    expect(parsed.has('client_secret')).toBe(false);
  });
});

describe('parseTokenResponse', () => {
  it('extracts access_token on success', () => {
    expect(parseTokenResponse({ access_token: 'tok' })).toEqual({ accessToken: 'tok' });
  });

  it('returns the error slug when the token endpoint reports one', () => {
    expect(parseTokenResponse({ error: 'invalid_grant' })).toEqual({ error: 'invalid_grant' });
  });

  it('flags a missing access_token', () => {
    expect(parseTokenResponse({ token_type: 'Bearer' })).toEqual({ error: 'missing_access_token' });
  });

  it('rejects non-object payloads', () => {
    expect(parseTokenResponse(null)).toEqual({ error: 'invalid_response' });
    expect(parseTokenResponse('nope')).toEqual({ error: 'invalid_response' });
    expect(parseTokenResponse(42)).toEqual({ error: 'invalid_response' });
  });
});
