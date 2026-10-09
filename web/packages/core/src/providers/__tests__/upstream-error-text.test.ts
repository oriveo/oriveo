import { describe, expect, it } from 'vitest';
import { RELAY_REDACTED_PLACEHOLDER } from '@oriveo/shared/relay/endpoint-policy';
import { sanitizeUpstreamErrorText, UPSTREAM_ERROR_TEXT_MAX_BYTES } from '../upstream-error-text';

const bytes = (text: string) => new TextEncoder().encode(text).length;

describe('sanitizeUpstreamErrorText', () => {
  it('scrubs credentials (a longer credential before its prefix) using the same placeholder constant as the Relay side', () => {
    expect(sanitizeUpstreamErrorText('bad key sk-abcdef123 and sk-abc', ['sk-abc', 'sk-abcdef123']))
      .toBe(`bad key ${RELAY_REDACTED_PLACEHOLDER} and ${RELAY_REDACTED_PLACEHOLDER}`);
  });

  it('truncates to 2 KB by bytes without leaving half a multi-byte character at the cut', () => {
    const out = sanitizeUpstreamErrorText('a' + '错'.repeat(1000));
    expect(bytes(out)).toBeLessThanOrEqual(UPSTREAM_ERROR_TEXT_MAX_BYTES);
    expect(out).not.toContain('�');
    expect(out.length).toBe(1 + Math.floor((UPSTREAM_ERROR_TEXT_MAX_BYTES - 1) / 3));
  });

  it('scrubs before truncating: a credential straddling the truncation boundary leaves no fragment', () => {
    const secret = 'sk-' + 'z'.repeat(40);
    const out = sanitizeUpstreamErrorText('x'.repeat(2040) + secret, [secret]);
    expect(out).not.toContain('zzzz');
  });
});
