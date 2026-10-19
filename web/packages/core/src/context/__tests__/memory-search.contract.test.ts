import { describe, expect, it } from 'vitest';

import { functionToolsForProtocol, type WireProtocol } from '../../providers/request-builders/tool-call-wire-adapter';
import type { ProxyToolDefinition } from '../../providers/request-builders/runtime';
import { MemoryItems, type MemoryItemInput } from '../memory-items';
import { buildMemoryRecallIndex } from '../memory-recall';
import {
  MEMORY_SEARCH_CONSTANTS,
  MEMORY_SEARCH_EMPTY_RESULT,
  MEMORY_SEARCH_LIMIT_RESULT,
  MEMORY_SEARCH_NOTE,
  SEARCH_MEMORY_TOOL,
  searchMemory,
  searchMemoryMode,
  searchMemoryReturnedIds,
  searchMemoryToolResult,
  type SearchMemoryModeInput,
} from '../memory-search';
import { ContextContractFixture } from './fixture';

interface MemorySearchContract {
  constants: Record<string, unknown>;
  tool: unknown;
  projections: Record<WireProtocol, unknown[]>;
  note: string;
  emptyResult: string;
  limitResult: string;
  searchCases: Array<{
    id: string;
    input: {
      items: MemoryItemInput[];
      arguments: string;
      context: { conversationId: string; folderId: string | null; now: string; excludeIds: string[] };
      priorInTurn: number;
      maxTokens: number | null;
      rho: number;
    };
    expected: { outcome: unknown; toolResult: string; returnedIds: string[] };
  }>;
  modeCases: Array<{ id: string; input: SearchMemoryModeInput; expected: 'tool' | 'none' }>;
}

const contract = ContextContractFixture.load<MemorySearchContract>('memory-search.v1.json');

describe('ContextContractMemorySearch', () => {
  it('tool, texts and constants equal the fixture byte for byte', () => {
    expect(JSON.stringify(SEARCH_MEMORY_TOOL)).toBe(JSON.stringify(contract.tool));
    expect(MEMORY_SEARCH_NOTE).toBe(contract.note);
    expect(MEMORY_SEARCH_EMPTY_RESULT).toBe(contract.emptyResult);
    expect(MEMORY_SEARCH_LIMIT_RESULT).toBe(contract.limitResult);
    expect(JSON.parse(JSON.stringify(MEMORY_SEARCH_CONSTANTS))).toStrictEqual(contract.constants);
  });

  it.each(Object.keys(contract.projections) as WireProtocol[])('production projection %s', (protocol) => {
    const tools = [SEARCH_MEMORY_TOOL as unknown as ProxyToolDefinition];
    expect(functionToolsForProtocol(protocol, tools)).toStrictEqual(contract.projections[protocol]);
  });

  it.each(contract.searchCases.map((c) => [c.id, c] as const))('search %s', (_id, c) => {
    const index = buildMemoryRecallIndex(c.input.items.map((i) => MemoryItems.canonical(i)));
    const { conversationId, folderId, now, excludeIds } = c.input.context;
    const outcome = searchMemory(index, c.input.arguments, { conversationId, folderId, nowMs: Date.parse(now), excludeIds }, c.input.priorInTurn);
    expect(outcome).toStrictEqual(c.expected.outcome);
    expect(searchMemoryToolResult(outcome, c.input.maxTokens, c.input.rho)).toBe(c.expected.toolResult);
    expect(searchMemoryReturnedIds(outcome, c.input.maxTokens, c.input.rho)).toStrictEqual(c.expected.returnedIds);
  });

  it.each(contract.modeCases.map((c) => [c.id, c] as const))('mode %s', (_id, c) => {
    expect(searchMemoryMode(c.input)).toBe(c.expected);
  });
});
