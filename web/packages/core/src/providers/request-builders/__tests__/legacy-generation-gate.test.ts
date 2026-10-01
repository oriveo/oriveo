import { existsSync, readFileSync } from 'node:fs';
import path from 'node:path';

import { describe, expect, it } from 'vitest';

import { legacyGenerationGateAllowsInjection, type RuntimeRecipe } from '../capability-execution';

interface GateCase {
  caseId: string;
  template: string;
  profileTemplate: string;
  expectInject: boolean;
}

describe('legacy generation template gate', () => {
  const fixturePath = findFromRoot(path.join('shared', 'model-contracts', 'provider_recipe_request_compiler.v1.json'));
  const cases = (JSON.parse(readFileSync(fixturePath, 'utf8')) as { legacyGenerationGateCases: GateCase[] }).legacyGenerationGateCases;

  it('injects for each of the four templates only when the profile template is equal', () => {
    expect(cases).toHaveLength(8);
    for (const entry of cases) {
      const recipe: RuntimeRecipe = {
        id: `legacy.${entry.caseId}`,
        providerKind: 'relay',
        capability: 'generation',
        executionKind: 'request_overlay',
        requestOps: [{ op: 'legacy_generation_template', template: entry.template }],
      };
      expect(
        legacyGenerationGateAllowsInjection(recipe, entry.profileTemplate),
        `${entry.caseId} expectInject`,
      ).toBe(entry.expectInject);
    }
  });

  it('never injects without a recipe or with an empty profile template', () => {
    const recipe: RuntimeRecipe = {
      id: 'legacy.empty',
      providerKind: 'relay',
      capability: 'generation',
      executionKind: 'request_overlay',
      requestOps: [{ op: 'legacy_generation_template', template: 'openai_responses' }],
    };
    expect(legacyGenerationGateAllowsInjection(undefined, 'openai_responses')).toBe(false);
    expect(legacyGenerationGateAllowsInjection(recipe, '')).toBe(false);
    expect(legacyGenerationGateAllowsInjection(recipe, undefined)).toBe(false);
  });
});

function findFromRoot(relativePath: string): string {
  let current = process.cwd();
  while (true) {
    const candidate = path.join(current, relativePath);
    if (existsSync(candidate)) return candidate;
    const parent = path.dirname(current);
    if (parent === current) throw new Error(`${relativePath} not found`);
    current = parent;
  }
}
