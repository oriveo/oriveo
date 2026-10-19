import { describe, expect, it } from 'vitest';

import { MemoryItems, type MemoryItemInput } from '../memory-items';
import {
  MEMORY_RECALL_CONSTANTS,
  buildMemoryRecallIndex,
  memoryRecallConflict,
  memoryRecallTokens,
  recallMemory,
  resolveMemoryRecallConflict,
  type MemoryRecallResolution,
} from '../memory-recall';
import { ContextContractFixture } from './fixture';

interface MemoryRecallContract {
  constants: Record<string, unknown>;
  tokenizeCases: Array<{ id: string; text: string; expected: string[] }>;
  recallCases: Array<{
    id: string;
    input: { items: MemoryItemInput[]; query: string; context: { conversationId: string; folderId: string | null; now: string } };
    expected: unknown;
  }>;
  conflictCases: Array<{ id: string; input: { saved: MemoryItemInput; items: MemoryItemInput[] }; expected: { conflictWith: string | null } }>;
  resolveCases: Array<{
    id: string;
    input: { newer: MemoryItemInput; older: MemoryItemInput; resolution: MemoryRecallResolution };
    expected: unknown;
  }>;
}

const contract = ContextContractFixture.load<MemoryRecallContract>('memory-recall.v1.json');

describe('ContextContractMemoryRecall', () => {
  it('constants equal the fixture', () => {
    const { cjkRanges: _ranges, ...constants } = contract.constants;
    expect(JSON.parse(JSON.stringify(MEMORY_RECALL_CONSTANTS))).toStrictEqual(constants);
  });

  it.each(contract.tokenizeCases.map((c) => [c.id, c] as const))('tokenize %s', (_id, c) => {
    expect(memoryRecallTokens(c.text)).toStrictEqual(c.expected);
  });

  it.each(contract.recallCases.map((c) => [c.id, c] as const))('recall %s', (_id, c) => {
    const index = buildMemoryRecallIndex(c.input.items.map((i) => MemoryItems.canonical(i)));
    const { conversationId, folderId, now } = c.input.context;
    expect(recallMemory(index, c.input.query, { conversationId, folderId, nowMs: Date.parse(now) })).toStrictEqual(c.expected);
  });

  it.each(contract.conflictCases.map((c) => [c.id, c] as const))('conflict %s', (_id, c) => {
    const saved = MemoryItems.canonical(c.input.saved);
    expect(memoryRecallConflict(saved, c.input.items.map((i) => MemoryItems.canonical(i)))).toBe(c.expected.conflictWith);
  });

  it.each(contract.resolveCases.map((c) => [c.id, c] as const))('resolve %s', (_id, c) => {
    const { newer, older, resolution } = c.input;
    expect(resolveMemoryRecallConflict(MemoryItems.canonical(newer), MemoryItems.canonical(older), resolution)).toStrictEqual(c.expected);
  });
});
