// @vitest-environment node
/**
 * Shared fixture byok_image_tasks.v1.json: every group (spec, timeout, retry,
 * transportPhase web table, aggregate, queue, reconcile) runs through the Web
 * byok-tasks pure functions and matches the fixture case by case.
 */
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { describe, expect, it } from 'vitest';
import {
  BYOK_EMPTY_QUEUE,
  BYOK_IMAGE_TASK_SPEC,
  byokAggregate,
  byokEffectiveTimeoutSeconds,
  byokQueueReduce,
  byokReconcile,
  byokRetryDecision,
  byokTransportPhase,
  type ByokAggregate,
  type ByokBatchResult,
  type ByokPhase,
  type ByokQueueEffect,
  type ByokQueueEvent,
  type ByokQueueState,
  type ByokReconcileAction,
  type ByokRetryDecision,
} from '../byok-tasks';

const ROOT = resolve(__dirname, '../../../../../../../..');
const CONTRACTS = resolve(ROOT, '\u5171\u4eab/studio-contracts');
const FIXTURE_PATH = resolve(CONTRACTS, 'byok_image_tasks.v1.json');

function readJson<T>(path: string): T {
  return JSON.parse(readFileSync(path, 'utf8')) as T;
}

interface Fixture {
  spec: {
    defaultTimeoutSeconds: number;
    maxTimeoutSeconds: number;
    maxConcurrentRounds: number;
    maxAutoRetries: number;
    phases: string[];
    reconcileActions: string[];
    roundStatuses: string[];
    rules: string[];
  };
  timeout: { caseId: string; timeoutSeconds: number | null; expect: number }[];
  retry: { caseId: string; phase: ByokPhase; attempt: number; expect: ByokRetryDecision }[];
  transportPhase: {
    web: { caseId: string; name: string; causeCode: string | null; nestedCauseCode?: string; expect: ByokPhase }[];
  };
  aggregate: {
    caseId: string;
    input: { n: number; batches: number[]; results: ByokBatchResult[]; cancelled: boolean };
    expect: ByokAggregate;
  }[];
  queue: {
    caseId: string;
    steps: {
      event: ByokQueueEvent;
      expect: { running: string[]; queued: string[]; effects: ByokQueueEffect[] };
    }[];
  }[];
  reconcile: {
    caseId: string;
    input: {
      status: string;
      startedAtMs: number | null;
      nowMs: number;
      timeoutSeconds: number | null;
      responseReceived: boolean;
      transferActive: boolean;
    };
    expect: ByokReconcileAction;
  }[];
}

const fixture = readJson<Fixture>(FIXTURE_PATH);

describe('byok_image_tasks.v1.json', () => {
  it('spec', () => {
    const { rules, ...values } = fixture.spec;
    expect(rules.length).toBeGreaterThan(0);
    expect(BYOK_IMAGE_TASK_SPEC).toEqual(values);
  });

  it('timeout', () => {
    expect(fixture.timeout.length).toBeGreaterThan(0);
    for (const c of fixture.timeout) {
      expect(byokEffectiveTimeoutSeconds(c.timeoutSeconds), c.caseId).toBe(c.expect);
    }
    // Typed ends cannot express these; Web falls back like missing.
    expect(byokEffectiveTimeoutSeconds(60.5)).toBe(180);
    expect(byokEffectiveTimeoutSeconds(Number.NaN)).toBe(180);
  });

  it('retry', () => {
    expect(fixture.retry.length).toBeGreaterThan(0);
    for (const c of fixture.retry) {
      expect(byokRetryDecision(c.phase, c.attempt), c.caseId).toEqual(c.expect);
    }
  });

  it('transportPhase', () => {
    const table = fixture.transportPhase.web;
    expect(new Set(table.map((c) => c.expect))).toEqual(new Set(fixture.spec.phases));
    for (const c of table) {
      const error = Object.assign(new Error('x'), {
        name: c.name,
        cause: c.causeCode
          ? { code: c.causeCode }
          : c.nestedCauseCode
            ? { cause: { code: c.nestedCauseCode } }
            : undefined,
      });
      expect(byokTransportPhase(error), c.caseId).toBe(c.expect);
    }
  });

  it('aggregate', () => {
    expect(fixture.aggregate.length).toBeGreaterThan(0);
    for (const c of fixture.aggregate) {
      const { n, batches, results, cancelled } = c.input;
      expect(byokAggregate(n, batches, results, cancelled), c.caseId).toEqual(c.expect);
    }
  });

  it('queue', () => {
    expect(fixture.queue.length).toBeGreaterThan(0);
    for (const c of fixture.queue) {
      let state: ByokQueueState = BYOK_EMPTY_QUEUE;
      c.steps.forEach((step, index) => {
        const label = `${c.caseId}#${index}`;
        const before = JSON.stringify(state);
        const result = byokQueueReduce(state, step.event);
        expect(JSON.stringify(state), `${label} input untouched`).toBe(before);
        expect(result.state.running, `${label} running`).toEqual(step.expect.running);
        expect(result.state.queued, `${label} queued`).toEqual(step.expect.queued);
        expect(result.effects, `${label} effects`).toEqual(step.expect.effects);
        state = result.state;
      });
    }
  });

  it('reconcile', () => {
    expect(fixture.reconcile.length).toBeGreaterThan(0);
    for (const c of fixture.reconcile) {
      const i = c.input;
      expect(
        byokReconcile(
          i.status,
          i.startedAtMs,
          i.nowMs,
          i.timeoutSeconds,
          i.responseReceived,
          i.transferActive,
        ),
        c.caseId,
      ).toBe(c.expect);
    }
  });
});
