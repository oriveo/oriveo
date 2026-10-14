import { existsSync, readFileSync } from 'node:fs';
import path from 'node:path';

import { describe, expect, it } from 'vitest';
import type { AIModel, Provider } from '@oriveo/shared/pure-types';
import { effectiveAPIRoot, effectiveTransport } from '../relay-effective';

interface ResolveCase {
  caseId: string;
  provider: { baseURL?: string; relayRequested?: Record<string, unknown> };
  model: Record<string, unknown>;
  expect: { effectiveTransport: string; effectiveAPIRoot: string };
}

function loadResolveCases(): ResolveCase[] {
  let dir = process.cwd();
  for (let depth = 0; depth < 8; depth += 1) {
    const candidate = path.join(dir, 'shared', 'test-fixtures', 'relay', 'portable-config.v1.json');
    if (existsSync(candidate)) {
      return (JSON.parse(readFileSync(candidate, 'utf8')) as { resolveCases: ResolveCase[] }).resolveCases;
    }
    dir = path.dirname(dir);
  }
  throw new Error('portable-config.v1.json not found');
}

/** The fixture's `baseURL` is this platform's Provider `baseURLText`; other keys are unchanged. */
function providerOf(item: ResolveCase): Pick<Provider, 'baseURLText' | 'relayRequested'> {
  return {
    baseURLText: item.provider.baseURL,
    relayRequested: item.provider.relayRequested as unknown as Provider['relayRequested'],
  };
}

const cases = loadResolveCases();

describe('RL2-RESOLVE-01 effectiveTransport', () => {
  it('the fixture carries all 13 resolution cases', () => {
    expect(cases).toHaveLength(13);
  });

  for (const item of cases) {
    it(`RL2-RESOLVE-01 ${item.caseId}`, () => {
      expect(effectiveTransport(providerOf(item), item.model as Partial<AIModel>))
        .toBe(item.expect.effectiveTransport);
    });
  }

  it('falls back to openai_chat_completions when there is no Relay config or no models', () => {
    expect(effectiveTransport({ baseURLText: 'https://relay.example.com' }, undefined))
      .toBe('openai_chat_completions');
  });
});

describe('RL2-RESOLVE-02 effectiveAPIRoot', () => {
  for (const item of cases) {
    it(`RL2-RESOLVE-02 ${item.caseId}`, () => {
      const provider = providerOf(item);
      const before = JSON.stringify(provider);
      expect(effectiveAPIRoot(provider, item.model as Partial<AIModel>))
        .toBe(item.expect.effectiveAPIRoot);
      // Pure function: does not write back to the provider.
      expect(JSON.stringify(provider)).toBe(before);
    });
  }
});
