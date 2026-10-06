import { describe, expect, it } from 'vitest';
import { bundledMcpIconURL, mcpBrandKey, mcpBrandKeys } from './mcp-icons';

describe('packaged MCP vendor icons', () => {
  it('recognizes vendor endpoints even with a custom display name', () => {
    expect(mcpBrandKey('My docs', 'https://mcp.deepwiki.com/mcp')).toBe('deepwiki');
    expect(mcpBrandKey('My docs', 'https://mcp.context7.com/mcp')).toBe('context7');
    expect(mcpBrandKey('custom', 'https://LINEAR.APP./sse')).toBe('linear');
    expect(mcpBrandKey('GitHub', 'https://mcp.linear.app/sse')).toBe('linear');
  });

  it('requires a DNS label boundary and an HTTPS endpoint', () => {
    for (const url of ['https://evilcontext7.com/mcp', 'https://context7.com.evil.example/mcp', 'https://context7.com@evil.example/mcp', 'http://context7.com/mcp', 'javascript:alert(1)']) {
      expect(mcpBrandKey('custom', url)).toBeNull();
    }
  });

  it('normalizes exact aliases without guessing from substrings', () => {
    expect(mcpBrandKey('  MCP_server_GitHub  ')).toBe('github');
    expect(mcpBrandKey('Deep-Wiki MCP server')).toBe('deepwiki');
    expect(mcpBrandKey('Google   Drive')).toBe('googledrive');
    expect(mcpBrandKey('Postgres')).toBe('postgresql');
    expect(mcpBrandKey('my github proxy')).toBeNull();
    expect(mcpBrandKey('unknown service')).toBeNull();
  });

  it('uses theme specific local paths for every catalog entry', () => {
    expect(new Set(mcpBrandKeys).size).toBe(mcpBrandKeys.length);
    for (const key of mcpBrandKeys) {
      expect(bundledMcpIconURL(key)).toBe(`/mcp-icons/light/${key}.png`);
      expect(bundledMcpIconURL(key, null, true)).toBe(`/mcp-icons/dark/${key}.png`);
    }
    expect(bundledMcpIconURL('unknown')).toBeNull();
  });
});
