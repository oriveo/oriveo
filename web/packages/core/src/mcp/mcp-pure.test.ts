import { readFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { resolve } from 'node:path';
import { describe, expect, it } from 'vitest';
import {
  MCP_SAFETY_PROMPT,
  argsSummary,
  canonicalJsonString,
  isLocalOnlyUrl,
  localOnlyVerdict,
  makeSlug,
  maskSecretPathSegments,
  outboundToolName,
  sanitizeToolName,
  sha256Hex,
  toolContentHash,
  uniqueSlug,
} from './mcp-pure';
import { parseMcpRuntimeConfig, MCP_RUNTIME_CONFIG_FALLBACK } from './mcp-types';

/**
 * Replay of the fixtures shared by all clients. The fixtures are frozen and every expected value comes from the fixture files themselves.
 */
const FIXTURES = resolve(__dirname, '../../../../../shared/test-fixtures/mcp');
// eslint-disable-next-line @typescript-eslint/no-explicit-any
const load = (name: string): any => JSON.parse(readFileSync(resolve(FIXTURES, name), 'utf8'));

describe('sha256Hex (pure implementation)', () => {
  it('agrees with Node crypto for various lengths and non-ASCII input', () => {
    const inputs = ['', 'abc', 'a'.repeat(55), 'a'.repeat(56), 'a'.repeat(64), 'a'.repeat(1000), 'クエ·テン😀', '\u0000\u001f'];
    for (const input of inputs) {
      expect(sha256Hex(input)).toBe(createHash('sha256').update(input, 'utf8').digest('hex'));
    }
  });
});

describe('naming.json', () => {
  for (const testCase of load('naming.json').cases) {
    it(testCase.caseId, () => {
      const result = outboundToolName({
        slug: testCase.slug,
        serverId: testCase.serverId,
        toolName: testCase.toolName,
        collidesWith: testCase.collidesWith,
      });
      expect(result.name).toBe(testCase.expect.outboundName);
      expect(result.name.length).toBe(testCase.expect.length);
      expect(result.hashSuffixed).toBe(testCase.expect.hashSuffixed);
    });
  }
});

describe('identifiers.json', () => {
  const fixture = load('identifiers.json');
  for (const testCase of fixture.slugMake.cases) {
    it(`slugMake ${testCase.caseId}`, () => {
      expect(makeSlug(testCase.name)).toBe(testCase.expect);
      expect(makeSlug(testCase.name)).toMatch(/^[a-z0-9]{1,16}$/);
    });
  }
  for (const testCase of fixture.slugUnique.cases) {
    it(`slugUnique ${testCase.caseId}`, () => {
      expect(uniqueSlug(testCase.name, testCase.existing)).toBe(testCase.expect);
    });
  }
  for (const testCase of fixture.sanitize.cases) {
    it(`sanitize ${testCase.caseId}`, () => {
      expect(sanitizeToolName(testCase.toolName)).toBe(testCase.expect);
    });
  }
});

describe('tool-hash.json', () => {
  for (const testCase of load('tool-hash.json').cases) {
    it(testCase.caseId, () => {
      const before = toolContentHash(testCase.before);
      const after = toolContentHash(testCase.after);
      expect(before === after).toBe(testCase.expectEqual);
      if (testCase.expect.hash) {
        expect(before).toBe(testCase.expect.hash);
        expect(after).toBe(testCase.expect.hash);
      }
      if (testCase.expect.beforeHash) expect(before).toBe(testCase.expect.beforeHash);
      if (testCase.expect.afterHash) expect(after).toBe(testCase.expect.afterHash);
    });
  }

  it('canonical JSON sorts keys recursively, keeps array order and escapes minimally', () => {
    expect(canonicalJsonString({ b: [3, { y: 1, x: 2 }], a: 'é"\\\n' })).toBe('{"a":"é\\"\\\\\\u000a","b":[3,{"x":2,"y":1}]}');
  });
});

describe('args-summary.json', () => {
  for (const testCase of load('args-summary.json').cases) {
    it(testCase.caseId, () => {
      const summary = argsSummary(testCase.inputSchema, testCase.arguments);
      expect(summary).toBe(testCase.expect.summary);
      if (testCase.expect.length !== undefined) expect(Array.from(summary).length).toBe(testCase.expect.length);
    });
  }
});

describe('local-only.json', () => {
  for (const testCase of load('local-only.json').cases) {
    it(testCase.caseId, () => {
      expect(localOnlyVerdict(testCase.url)).toEqual(testCase.expect);
      expect(isLocalOnlyUrl(testCase.url)).toBe(testCase.expect.localOnly);
    });
  }

  it('masks exactly the path segments the third criterion flags, in either spelling', () => {
    expect(maskSecretPathSegments('/api/abcdefghij0123456789/mcp')).toBe('/api/…/mcp');
    expect(maskSecretPathSegments('/abcdefghij%30123456789')).toBe('/…');
    expect(maskSecretPathSegments('/abcdefghij012345678/mcp')).toBe('/abcdefghij012345678/mcp');
    expect(maskSecretPathSegments('/')).toBe('/');
  });
});

describe('safety-prompt.txt', () => {
  it('matches the fixture character for character (minus the trailing newline)', () => {
    expect(MCP_SAFETY_PROMPT).toBe(readFileSync(resolve(FIXTURES, 'safety-prompt.txt'), 'utf8').replace(/\n$/, ''));
  });
});

describe('parseMcpRuntimeConfig', () => {
  it('uses the fallback values when the input is missing or mistyped', () => {
    expect(parseMcpRuntimeConfig(undefined)).toEqual(MCP_RUNTIME_CONFIG_FALLBACK);
    expect(parseMcpRuntimeConfig({ maxServers: 'many' })).toEqual(MCP_RUNTIME_CONFIG_FALLBACK);
  });

  it('clamps out-of-range values to the bounds instead of falling back wholesale', () => {
    const config = parseMcpRuntimeConfig({
      version: 3,
      enabled: false,
      maxServers: 0,
      maxToolsPerRequest: 1e30,
      maxToolDefinitionBytes: 5,
      maxResultChars: 9_999_999,
      callTimeoutSeconds: 1,
      maxSteps: 99,
    });
    expect(config).toEqual({
      version: 3,
      enabled: false,
      maxServers: 1,
      maxToolsPerRequest: 128,
      maxToolDefinitionBytes: 1024,
      maxResultChars: 200_000,
      callTimeoutSeconds: 5,
      maxSteps: 8,
    });
  });
});
