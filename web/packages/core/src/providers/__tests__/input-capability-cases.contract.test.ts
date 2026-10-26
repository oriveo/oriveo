import { existsSync, readFileSync } from 'node:fs';
import path from 'node:path';

import { describe, expect, it } from 'vitest';

import {
  projectInputCapability,
  type InputCapabilityProjectionInput,
} from '../capability-evidence-facade';
import { endImplementsWireFamily, WEB_PROTOCOL_IMPLEMENTATIONS } from '../protocol-implementations';

interface InputCapabilityCase extends InputCapabilityProjectionInput {
  id: string;
  expect: Record<string, unknown>;
}

interface EvidenceContract {
  inputCapabilityCases: { cases: InputCapabilityCase[] };
}

interface WireFamilies {
  families: Array<{ id: string; implementedBy: string[] }>;
}

describe('capability_evidence_contract.v1 inputCapabilityCases', () => {
  const contract = loadJSON<EvidenceContract>('shared/model-contracts/capability_evidence_contract.v1.json');
  const cases = contract.inputCapabilityCases.cases;

  it('has cases', () => {
    expect(cases.length).toBeGreaterThan(0);
  });

  for (const testCase of cases) {
    it(testCase.id, () => {
      const { id: _id, expect: expected, ...input } = testCase;
      expect({ ...projectInputCapability(input) }).toEqual(expected);
    });
  }
});

describe('wire_families.v1 implementedBy web', () => {
  const wire = loadJSON<WireFamilies>('shared/model-contracts/wire_families.v1.json');
  const familyIds = new Set(wire.families.map((family) => family.id));

  it('table equals families whose implementedBy lists web', () => {
    const listed = wire.families.filter((family) => family.implementedBy.includes('web')).map((family) => family.id);
    expect([...WEB_PROTOCOL_IMPLEMENTATIONS].sort()).toEqual([...listed].sort());
    expect(WEB_PROTOCOL_IMPLEMENTATIONS.size).toBe(listed.length);
  });

  it('every table key is a declared family', () => {
    for (const id of WEB_PROTOCOL_IMPLEMENTATIONS) expect(familyIds.has(id), id).toBe(true);
  });

  it('unknown or missing family is not implemented', () => {
    expect(endImplementsWireFamily(undefined)).toBe(false);
    expect(endImplementsWireFamily('gemini.file_data')).toBe(false);
    expect(endImplementsWireFamily('openai_chat.image_url')).toBe(true);
  });
});

function loadJSON<T>(relativePath: string): T {
  let current = process.cwd();
  while (true) {
    const candidate = path.join(current, relativePath);
    if (existsSync(candidate)) return JSON.parse(readFileSync(candidate, 'utf8')) as T;
    const parent = path.dirname(current);
    if (parent === current) throw new Error(`${relativePath} not found`);
    current = parent;
  }
}
