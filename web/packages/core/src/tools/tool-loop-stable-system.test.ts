import { describe, expect, it, vi } from 'vitest';
import type { ProxyMessage } from '../providers/request-builders/runtime';
import { applyToolCallWireAdapter } from '../providers/request-builders/tool-call-wire-adapter';
import { buildRelayAnthropicMessagesBody } from '../providers/relay-orchestrator';
import { anthropicMessagesStrategy } from '../providers/transport/strategies/anthropic-messages';
import type { StreamEvent, StreamHandle } from '../providers/types';
import { ToolCallLoop } from './tool-call-loop';
import { defaultToolLoopPrompts, type ToolLoopLegRequest } from './tool-loop-contracts';
import { ToolRegistry } from './tool-registry';

// Host loop notices (step limit / token budget / stopReason) must not go into system: every leg's top-level
// system has to match the first leg byte for byte, or the prefix cache is invalidated mid tool loop.

const SYSTEM = 'You are a careful researcher.\nCite sources.';

function handle(events: readonly StreamEvent[]): StreamHandle {
  return {
    stream: new ReadableStream<StreamEvent>({
      start(controller) {
        for (const event of events) controller.enqueue(event);
        controller.close();
      },
    }),
    abort: (): void => {},
  };
}

function toolCall(id: string): StreamEvent {
  return { type: 'tool_calls', toolCalls: [{ index: 0, id, type: 'function', name: 'library_search', arguments: '{}' }] };
}

const PROTOCOLS = [
  { name: 'anthropic', url: 'https://api.anthropic.com/v1/messages', systemOf: (b: Record<string, unknown>) => b.system },
  {
    name: 'gemini',
    url: 'https://generativelanguage.googleapis.com/v1beta/models/g:streamGenerateContent',
    systemOf: (b: Record<string, unknown>) => b.systemInstruction,
  },
  { name: 'responses', url: 'https://api.openai.com/v1/responses', systemOf: (b: Record<string, unknown>) => b.instructions },
  {
    name: 'chat',
    url: 'https://api.openai.com/v1/chat/completions',
    systemOf: (b: Record<string, unknown>) => (b.messages as Array<{ role: string }>).filter((m) => m.role === 'system'),
  },
] as const;

async function runStepLimitedLoop(url: string): Promise<Array<Record<string, unknown>>> {
  const bodies: Array<Record<string, unknown>> = [];
  const queue = [handle([toolCall('c1')]), handle([toolCall('c2')]), handle([{ type: 'delta', content: 'final' }])];
  const execute = vi.fn(async () => ({ content: '{"ok":true}' }));
  const registry = new ToolRegistry([{
    name: 'library_search',
    scope: 'library',
    definition: { type: 'function', function: { name: 'library_search', description: 's', parameters: { type: 'object' } } },
    execute,
    failureDisposition: () => ({ kind: 'fatal' }),
  }]);
  const loop = new ToolCallLoop({
    registry,
    signal: new AbortController().signal,
    limits: { maxSteps: 2 },
    runLeg: (request: ToolLoopLegRequest) => {
      // Encode the wire body at send time: history is the same array the loop keeps appending to, so encoding later would see later messages.
      bodies.push(applyToolCallWireAdapter(
        { url, headers: {}, body: {} },
        { messages: request.messages, tools: request.tools, toolChoice: request.toolChoice },
      ).body);
      const next = queue.shift();
      if (!next) throw new Error('no queued leg');
      return next;
    },
  });
  const initial: ProxyMessage[] = [
    { role: 'system', content: SYSTEM },
    { role: 'user', content: 'Find the plan.' },
  ];
  const result = await loop.run(initial);
  expect(result.stepLimitReached).toBe(true);
  return bodies;
}

describe('tool loop host notices keep the system prefix stable', () => {
  it.each(PROTOCOLS)('$name: every leg carries the first-leg system byte for byte', async ({ url, systemOf }) => {
    const bodies = await runStepLimitedLoop(url);
    expect(bodies).toHaveLength(3);
    const first = JSON.stringify(systemOf(bodies[0]));
    expect(first).toContain('careful researcher');
    for (const body of bodies) expect(JSON.stringify(systemOf(body))).toBe(first);
  });

  const notice = defaultToolLoopPrompts.stepLimitReached;

  it('anthropic: notice shares the user turn with the tool_result, no adjacent user turns', async () => {
    const final = (await runStepLimitedLoop(PROTOCOLS[0].url))[2];
    const messages = final.messages as Array<{ role: string; content: Array<Record<string, unknown>> }>;
    for (let i = 1; i < messages.length; i += 1) expect(messages[i].role).not.toBe(messages[i - 1].role);
    const last = messages.at(-1)!;
    expect(last.role).toBe('user');
    expect(last.content.map((block) => block.type)).toEqual(['tool_result', 'text']);
    expect(last.content[0].tool_use_id).toBe('c2');
    expect(last.content[1].text).toBe(notice);
  });

  it('gemini: notice shares the user content with the functionResponse', async () => {
    const final = (await runStepLimitedLoop(PROTOCOLS[1].url))[2];
    const contents = final.contents as Array<{ role: string; parts: Array<Record<string, unknown>> }>;
    for (let i = 1; i < contents.length; i += 1) expect(contents[i].role).not.toBe(contents[i - 1].role);
    const last = contents.at(-1)!;
    expect(last.role).toBe('user');
    expect(last.parts[0].functionResponse).toBeDefined();
    expect(last.parts[1]).toEqual({ text: notice });
  });

  it('responses: notice is a user input after the function_call_output', async () => {
    const final = (await runStepLimitedLoop(PROTOCOLS[2].url))[2];
    const input = final.input as Array<Record<string, unknown>>;
    expect(input.at(-2)).toMatchObject({ type: 'function_call_output', call_id: 'c2' });
    expect(input.at(-1)).toEqual({ role: 'user', content: [{ type: 'input_text', text: notice }] });
    expect(final.instructions).toBe(SYSTEM);
  });

  it('chat: notice is a user message after the tool message', async () => {
    const final = (await runStepLimitedLoop(PROTOCOLS[3].url))[2];
    const messages = final.messages as Array<Record<string, unknown>>;
    expect(messages.at(-2)).toMatchObject({ role: 'tool', tool_call_id: 'c2' });
    expect(messages.at(-1)).toMatchObject({ role: 'user', content: notice });
    expect(messages.filter((m) => m.role === 'system')).toHaveLength(1);
  });
});

describe('Relay Anthropic keeps every system message', () => {
  const messages = [
    { role: 'system' as const, content: 'First system.' },
    { role: 'system' as const, content: 'Second system.' },
    { role: 'user' as const, content: 'Hi' },
  ];

  it('buildRelayAnthropicMessagesBody joins all system texts with a blank line', () => {
    expect(buildRelayAnthropicMessagesBody('claude', messages, undefined).system).toBe('First system.\n\nSecond system.');
  });

  it('anthropic messages strategy joins all system texts with a blank line', () => {
    expect(anthropicMessagesStrategy.buildRequestBody({ modelID: 'claude', messages }).system)
      .toBe('First system.\n\nSecond system.');
  });
});
