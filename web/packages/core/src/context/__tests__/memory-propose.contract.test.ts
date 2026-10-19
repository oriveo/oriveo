import { readFileSync } from 'node:fs';
import path from 'node:path';

import { describe, expect, it } from 'vitest';

import { functionToolsForProtocol, type WireProtocol } from '../../providers/request-builders/tool-call-wire-adapter';
import type { ProxyToolDefinition } from '../../providers/request-builders/runtime';
import type { MemoryCandidateRecord } from '../memory-intent';
import {
  PROPOSE_MEMORY_MAX_PER_TURN,
  PROPOSE_MEMORY_TOOL,
  PROPOSE_MEMORY_TOOL_RESULT,
  proposeMemoryCandidate,
  proposeMemoryMode,
  shouldDegradeProposeMemory,
  type ProposeMemoryContext,
  type ProposeMemoryModeInput,
} from '../memory-propose';
import { ContextContractFixture } from './fixture';

interface MemoryProposeContract {
  tool: unknown;
  toolResult: string;
  projections: Record<WireProtocol, unknown[]>;
  constants: { maxProposalsPerTurn: number };
  proposeCases: Array<{
    id: string;
    context: Omit<ProposeMemoryContext, 'records'> & { records: MemoryCandidateRecord[] };
    priorInTurn: number;
    arguments: string;
    expected: unknown;
  }>;
  modeCases: Array<{ id: string; input: ProposeMemoryModeInput; expected: string }>;
  degradeCases: Array<{
    id: string;
    rejection: string;
    legIndex: number;
    streamStarted: boolean;
    receivedStructuredToolCalls: boolean;
    expected: { degrade: boolean };
  }>;
}

const contract = ContextContractFixture.load<MemoryProposeContract>('memory-propose.v2.json');
const toolUnsupported = JSON.parse(
  readFileSync(
    path.join(path.dirname(ContextContractFixture.path('memory-propose.v2.json')), '..', 'test-fixtures', 'provider-toolcall', 'tool-unsupported-4xx.json'),
    'utf8',
  ),
) as { cases: Array<{ id: string; expect: boolean }> };

describe('ContextContractMemoryPropose', () => {
  it('tool, tool_result and turn limit equal the fixture byte for byte', () => {
    expect(JSON.stringify(PROPOSE_MEMORY_TOOL)).toBe(JSON.stringify(contract.tool));
    expect(PROPOSE_MEMORY_TOOL_RESULT).toBe(contract.toolResult);
    expect(PROPOSE_MEMORY_MAX_PER_TURN).toBe(contract.constants.maxProposalsPerTurn);
  });

  it.each(Object.keys(contract.projections) as WireProtocol[])('production projection %s', (protocol) => {
    const tools = [PROPOSE_MEMORY_TOOL as unknown as ProxyToolDefinition];
    expect(functionToolsForProtocol(protocol, tools)).toStrictEqual(contract.projections[protocol]);
  });

  it.each(contract.proposeCases.map((c) => [c.id, c] as const))('propose %s', (_id, c) => {
    expect(proposeMemoryCandidate(c.arguments, c.context, c.priorInTurn)).toStrictEqual(c.expected);
  });

  it.each(contract.modeCases.map((c) => [c.id, c] as const))('mode %s', (_id, c) => {
    expect(proposeMemoryMode(c.input)).toBe(c.expected);
  });

  it.each(contract.degradeCases.map((c) => [c.id, c] as const))('degrade %s', (_id, c) => {
    const source = toolUnsupported.cases.find((k) => k.id === c.rejection);
    expect(source).toBeDefined();
    expect(
      shouldDegradeProposeMemory({
        toolUnsupported: source!.expect,
        legIndex: c.legIndex,
        streamStarted: c.streamStarted,
        receivedStructuredToolCalls: c.receivedStructuredToolCalls,
      }),
    ).toBe(c.expected.degrade);
  });
});
