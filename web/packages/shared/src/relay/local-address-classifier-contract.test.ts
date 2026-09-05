import { existsSync, readFileSync } from 'node:fs';
import path from 'node:path';

import { describe, expect, it } from 'vitest';

import { classifyRelayEndpoint } from './endpoint-policy';

interface ClassifierCase {
  caseId: string;
  input: string;
  securityMode: 'remote_https' | 'local_http' | 'private_vpn';
  resolvedIPs?: string[];
  recheckResolvedIPs?: string[];
  redirects?: string[];
  credentials?: {
    authMode?: string;
    hasKey?: boolean;
    sensitiveHeaders?: string[];
  };
  expect: { allowed: boolean; reason: string; normalized?: string };
}

interface ClassifierContract {
  version: number;
  cases: ClassifierCase[];
}

describe('local-address-classifier.v1 red proof', () => {
  const contract = loadContract();

  it('loads the shared bidirectional classifier matrix', () => {
    expect(contract.version).toBe(1);
    expect(contract.cases).toHaveLength(20);
    expect(new Set(contract.cases.map((item) => item.securityMode))).toEqual(
      new Set(['remote_https', 'local_http', 'private_vpn']),
    );
  });

  for (const item of contract.cases) {
    it(`${item.caseId} matches the production endpoint policy`, () => {
      const result = classifyRelayEndpoint({ raw: item.input, ...item });
      expect(result.allowed, `${item.caseId} (${result.reason})`).toBe(item.expect.allowed);
      expect(result.reason).toBe(item.expect.reason);
      if (item.expect.normalized) expect(result.normalized).toBe(item.expect.normalized);
    });
  }
});

describe('local-engine scenarios fixture', () => {
  it('loads the zero-dependency simulator matrix', () => {
    const fixture = loadJSON<{ version: number; scenarios: Array<{ engine: string }> }>([
      'shared',
      'test-fixtures',
      'local-engine',
      'scenarios.v1.json',
    ]);
    expect(fixture.version).toBe(1);
    expect(fixture.scenarios).toHaveLength(15);
    // All five release engines need a scenario. vllm and openwebui were added with Open WebUI support.
    // Asserting the engine set as a whole, not just the scenario count, is what catches the next
    // engine that gets added on one client and missed on another.
    const engines = new Set(fixture.scenarios.map((item) => item.engine));
    for (const engine of ['llamacpp', 'ollama', 'lmstudio', 'vllm', 'openwebui'])
      expect(engines.has(engine)).toBe(true);
  });
});

function loadContract(): ClassifierContract {
  return loadJSON([
    'shared',
    'test-fixtures',
    'relay',
    'local-address-classifier.v1.json',
  ]);
}

function loadJSON<T>(components: string[]): T {
  let current = process.cwd();
  while (true) {
    const candidate = path.join(current, ...components);
    if (existsSync(candidate)) return JSON.parse(readFileSync(candidate, 'utf8')) as T;
    const parent = path.dirname(current);
    if (parent === current) throw new Error(`${components.join('/')} not found`);
    current = parent;
  }
}
