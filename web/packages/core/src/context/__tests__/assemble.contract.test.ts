import { describe, expect, it } from 'vitest';

import { ContextAssembler, type AssembleInput } from '../assemble';
import type { ContextPlan } from '../plan';
import { ContextContractFixture, toContextMessage, type FixtureMessage } from './fixture';

interface FixtureInput extends Omit<AssembleInput, 'window' | 'history'> {
  window: { W: number | null; windowKind: 'total' | 'inputOnly'; maxOutput: number | null };
  history: FixtureMessage[];
}

interface AssembleContract {
  constants: { notes: Record<string, string>; continuePrompt: string; reminderPointer: string; instructionsHeader: string };
  cases: Array<{ id: string; input: FixtureInput; expected: Record<string, unknown> }>;
}

const contract = ContextContractFixture.load<AssembleContract>('assemble.v1.json');

function toInput(input: FixtureInput): AssembleInput {
  return {
    ...input,
    window: { W: input.window.W, windowKind: input.window.windowKind, maxOutput: { model: input.window.maxOutput } },
    history: input.history.map(toContextMessage),
  };
}

/** Projects the plan onto the fixture's comparison shape for one key. */
function project(plan: ContextPlan, key: string): unknown {
  switch (key) {
    case 'messages':
      return plan.messages === null ? null : plan.messages.map((m) => ({ role: m.role, blocks: m.blocks }));
    case 'segments':
      return plan.segments.map((s) => s.kind);
    default:
      return (plan as unknown as Record<string, unknown>)[key];
  }
}

function normalizeExpected(key: string, value: unknown): unknown {
  if (key === 'segments' && Array.isArray(value)) {
    return value.map((s: string | { kind: string }) => (typeof s === 'string' ? s : s.kind));
  }
  return value;
}

describe('ContextContractAssemble', () => {
  it('constants match the module', () => {
    expect(ContextAssembler.constants.notes).toStrictEqual(contract.constants.notes);
    expect(ContextAssembler.constants.continuePrompt).toBe(contract.constants.continuePrompt);
    expect(ContextAssembler.constants.reminderPointer).toBe(contract.constants.reminderPointer);
    expect(ContextAssembler.constants.instructionsHeader).toBe(contract.constants.instructionsHeader);
  });

  it.each(contract.cases.map((c) => [c.id, c] as const))('%s', (id, c) => {
    const plan = ContextAssembler.assemble(toInput(c.input));
    for (const [key, expected] of Object.entries(c.expected)) {
      expect(project(plan, key), `${id}.${key}`).toStrictEqual(normalizeExpected(key, expected));
    }
  });
});
