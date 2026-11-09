/**
 * Shared fixture studio_data_model.v1.json operationTable: every case runs through the Web
 * resolveStudioOperation and the whole expected decision is compared.
 */
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { describe, expect, it } from 'vitest';
import {
  resolveStudioOperation,
  type StudioModelOperation,
  type StudioOperationContext,
  type StudioOperationDecision,
} from '../studio-work-operation';
import { repoRoot } from '../../../../../../test-support/repo-root';

const ROOT = repoRoot();
const SHARED_DIR = 'shared';

interface OperationCase {
  caseId: string;
  context: StudioOperationContext;
  modelOps: StudioModelOperation[];
  expect: StudioOperationDecision;
}

const fixture = JSON.parse(readFileSync(
  resolve(ROOT, SHARED_DIR, 'studio-contracts/studio_data_model.v1.json'), 'utf8',
)) as { operationTable: OperationCase[] };

describe('studio_data_model.v1 operationTable', () => {
  it('operationTable_matchFixture', () => {
    expect(fixture.operationTable.length).toBeGreaterThan(0);
    for (const c of fixture.operationTable) {
      expect(resolveStudioOperation(c.context, c.modelOps), c.caseId).toStrictEqual(c.expect);
    }
  });
});
