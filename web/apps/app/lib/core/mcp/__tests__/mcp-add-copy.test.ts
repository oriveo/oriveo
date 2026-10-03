import { describe, expect, it } from 'vitest';
import { checkMcpEndpoint } from '@oriveo/core/mcp/index';
import en from '../../../../messages/en.json';
import zhHans from '../../../../messages/zh-Hans.json';
import { mcpInvalidUrlMessageKey } from '../mcp-add-copy';

function lookup(messages: unknown, key: string): unknown {
  return key.split('.').reduce<unknown>((node, part) => (node as Record<string, unknown> | undefined)?.[part], (messages as { mcp: unknown }).mcp);
}

describe('invalid address copy in the add-server flow', () => {
  it('reports hasUserinfo for an address with a userinfo part and tells the user to use an access token instead', () => {
    const checked = checkMcpEndpoint('https://user:pass@mcp.example.com/mcp');
    expect(checked.ok).toBe(false);
    if (checked.ok) return;
    const key = mcpInvalidUrlMessageKey(checked.reason);
    expect(key).toBe('addServer.invalidUrlHasUserinfo');
    expect(lookup(en, key)).toMatch(/access token/i);
    // The localized message names the access token with the same term the catalog uses for that sign-in method.
    const term = lookup(zhHans, 'settings.signInToken');
    expect(typeof term).toBe('string');
    expect(term).not.toBe(lookup(en, 'settings.signInToken'));
    expect(lookup(zhHans, key)).toContain(term as string);
  });

  it('uses the generic message for other invalid addresses', () => {
    const checked = checkMcpEndpoint('http://mcp.example.com/mcp');
    expect(checked.ok).toBe(false);
    if (checked.ok) return;
    const key = mcpInvalidUrlMessageKey(checked.reason);
    expect(key).toBe('addServer.invalidUrl');
    expect(lookup(en, key)).toContain('https://');
    expect(lookup(zhHans, key)).toContain('https://');
  });
});
