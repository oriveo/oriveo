/**
 * Shared fixture studio_prompt_compose.v1.json: every case runs through the Web
 * composeStudioPrompt with the fixture spec; the whole result (composed, error,
 * adjustments) is compared with expect.
 */
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { describe, expect, it } from 'vitest';
import {
  composeStudioPrompt,
  STUDIO_PROMPT_COMPOSE_SPEC,
  type StudioPromptComposeInput,
  type StudioPromptComposeResult,
  type StudioPromptComposeSpec,
} from '../prompt-compose';

const ROOT = resolve(__dirname, '../../../../../../../..');
const CONTRACTS = resolve(ROOT, '\u5171\u4eab/studio-contracts');

interface ComposeCase {
  caseId: string;
  input: StudioPromptComposeInput;
  expect: StudioPromptComposeResult;
}

function readJson<T>(name: string): T {
  return JSON.parse(readFileSync(resolve(CONTRACTS, name), 'utf8')) as T;
}

const fixture = readJson<{
  contractId: string;
  spec: StudioPromptComposeSpec;
  cases: ComposeCase[];
}>('studio_prompt_compose.v1.json');

describe('studio_prompt_compose.v1', () => {
  it('composeCases', () => {
    expect(fixture.contractId).toBe('studio_prompt_compose.v1');
    expect(STUDIO_PROMPT_COMPOSE_SPEC, 'built-in spec equals the fixture spec').toStrictEqual(fixture.spec);
    expect(fixture.cases.length).toBeGreaterThan(0);
    for (const entry of fixture.cases) {
      expect(composeStudioPrompt(fixture.spec, entry.input), entry.caseId).toStrictEqual(entry.expect);
    }
  });
});
