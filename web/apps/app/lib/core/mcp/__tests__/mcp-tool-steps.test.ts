import { describe, expect, it } from 'vitest';
import type { ChatMessage } from '@oriveo/shared';
import type { McpToolStepUpdate } from '@oriveo/core/mcp/index';
import {
  interruptRunningMcpToolSteps,
  mcpToolStepDisplayTitle,
  mcpToolStepFromUpdate,
  mergeMcpToolStep,
} from '../mcp-tool-steps';

const SERVER_ID = '00000000-0000-4000-8000-0000000000A1';

function update(overrides: Partial<McpToolStepUpdate> = {}): McpToolStepUpdate {
  return {
    id: '1:call_1', serverId: SERVER_ID, serverName: 'Weather', toolName: 'get_weather', title: 'Get weather',
    argsSummary: 'Berlin · celsius', status: 'running', errorCode: null, step: 1, durationMs: null,
    permission: 'ask', readOnly: false,
    payload: { arguments: '{"city":"Berlin","apiKey":"RAW-ARGUMENT-SECRET"}', resultPrefix: 'RAW-RESULT-SECRET' },
    ...overrides,
  };
}

function assistantMessage(toolSteps: ChatMessage['toolSteps']): ChatMessage {
  return {
    id: '11111111-1111-4111-8111-111111111111', role: 'assistant', text: 'It is sunny.', providerID: 'p1', providerKind: 'openAI',
    providerName: 'OpenAI', modelID: 'gpt', modelName: 'GPT', estimatedCost: 0, state: 'delivered',
    createdAt: '2026-10-03T10:00:00.000Z', toolSteps,
  } as ChatMessage;
}

describe('MCP tool steps: executor callback to message summary', () => {
  it('keeps only the summary fields: no payload, permission or read-only hint, and a lower-cased serverId', () => {
    const step = mcpToolStepFromUpdate(update());
    expect(step).toEqual({
      id: '1:call_1', scope: 'mcp', serverId: SERVER_ID.toLowerCase(), serverName: 'Weather', toolName: 'get_weather',
      title: 'Get weather', argsSummary: 'Berlin · celsius', status: 'running', step: 1,
    });
  });

  it('replaces on a callback with the same id and appends on a different id', () => {
    let steps = mergeMcpToolStep(undefined, update());
    steps = mergeMcpToolStep(steps, update({ status: 'done', durationMs: 420, payload: null }));
    steps = mergeMcpToolStep(steps, update({ id: '2:call_2', step: 2, status: 'failed', errorCode: 'tool_error', durationMs: 9 }));
    expect(steps.map((step) => [step.id, step.status, step.errorCode, step.durationMs])).toEqual([
      ['1:call_1', 'done', undefined, 420],
      ['2:call_2', 'failed', 'tool_error', 9],
    ]);
  });

  it('shows the raw tool name when there is no title', () => {
    expect(mcpToolStepDisplayTitle({ title: '', toolName: 'get_weather' })).toBe('get_weather');
    expect(mcpToolStepDisplayTitle({ title: 'Get weather', toolName: 'get_weather' })).toBe('Get weather');
  });
});

describe('MCP tool steps: reload', () => {
  it('turns running into interrupted and returns the same array when nothing changes', () => {
    const steps = [mcpToolStepFromUpdate(update({ status: 'done' })), mcpToolStepFromUpdate(update({ id: '2:x', step: 2 }))];
    const settled = interruptRunningMcpToolSteps(steps);
    expect(settled.map((step) => [step.status, step.errorCode])).toEqual([['done', undefined], ['interrupted', 'interrupted']]);
    expect(interruptRunningMcpToolSteps(settled)).toBe(settled);
    expect(interruptRunningMcpToolSteps(undefined)).toBeUndefined();
  });
});
