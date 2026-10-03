import { describe, expect, it, vi } from 'vitest';
import type {
  ProxyMessage,
  ProxyToolCall,
  ProxyToolDefinition,
} from '../providers/request-builders/runtime';
import type { StreamEvent, StreamHandle } from '../providers/types';
import { ToolCallLoop } from './tool-call-loop';
import {
  ToolCallRejection,
  effectiveToolLoopMaxSteps,
  type ToolExecutionContext,
  type ToolFailureDisposition,
  type ToolLoopLegRequest,
  type ToolLoopPrompts,
  type ToolRegistryEntry,
  defaultToolLoopPrompts,
} from './tool-loop-contracts';
import { ToolRegistry } from './tool-registry';

function definition(name: string): ProxyToolDefinition {
  return {
    type: 'function',
    function: { name, description: name, parameters: { type: 'object' } },
  };
}

function makeEntry(
  name: string,
  execute: ToolRegistryEntry['execute'],
  failureDisposition: ToolRegistryEntry['failureDisposition'] = () => ({ kind: 'fatal' }),
): ToolRegistryEntry {
  return { name, scope: 'library', definition: definition(name), execute, failureDisposition };
}

function handle(events: readonly StreamEvent[], onAbort?: () => void): StreamHandle {
  return {
    stream: new ReadableStream<StreamEvent>({
      start(controller) {
        for (const event of events) controller.enqueue(event);
        controller.close();
      },
    }),
    abort: onAbort ?? ((): void => {}),
  };
}

function toolCall(id: string, name: string, args = '{}'): StreamEvent {
  return { type: 'tool_calls', toolCalls: [{ index: 0, id, type: 'function', name, arguments: args }] };
}

function text(content: string): StreamEvent {
  return { type: 'delta', content };
}

function makeRunner(handles: readonly StreamHandle[]) {
  const requests: ToolLoopLegRequest[] = [];
  const queue = [...handles];
  const runLeg = (request: ToolLoopLegRequest): StreamHandle => {
    requests.push(request);
    const next = queue.shift();
    if (!next) throw new Error('no queued leg for request');
    return next;
  };
  return { requests, runLeg };
}

const signal = new AbortController().signal;

function toolMessages(messages: readonly ProxyMessage[]): ProxyMessage[] {
  return messages.filter((message) => message.role === 'tool');
}

describe('ToolRegistry — hits and misses', () => {
  it('lists definitions in registration order and returns undefined for a miss', () => {
    const registry = new ToolRegistry([
      makeEntry('library_search', async () => ({ content: '{}' })),
      makeEntry('library_list', async () => ({ content: '{}' })),
    ]);

    expect(registry.names).toEqual(['library_search', 'library_list']);
    expect(registry.definitions.map((entry) => entry.function.name)).toEqual([
      'library_search',
      'library_list',
    ]);
    expect(registry.has('library_search')).toBe(true);
    expect(registry.entry('library_read')).toBeUndefined();
    expect(registry.has('library_read')).toBe(false);
  });

  it('keeps the first of duplicate names; an empty registry is empty', () => {
    const first = makeEntry('library_search', async () => ({ content: 'first' }));
    const second = makeEntry('library_search', async () => ({ content: 'second' }));
    const registry = new ToolRegistry([first, second]);

    expect(registry.names).toEqual(['library_search']);
    expect(registry.entry('library_search')).toBe(first);
    expect(ToolRegistry.empty.isEmpty).toBe(true);
  });

  it('keeps an entry without a definition out of tools but still executable', () => {
    const entry: ToolRegistryEntry = {
      name: 'server_builtin',
      scope: 'web',
      execute: async () => ({ content: '{}' }),
      failureDisposition: () => ({ kind: 'fatal' }),
    };
    const registry = new ToolRegistry([entry]);

    expect(registry.definitions).toEqual([]);
    expect(registry.entry('server_builtin')).toBe(entry);
  });
});

describe('effectiveToolLoopMaxSteps — formula', () => {
  it('effective value = min(server-delivered value, 8), 6 when missing or invalid', () => {
    expect(effectiveToolLoopMaxSteps(undefined)).toBe(6);
    expect(effectiveToolLoopMaxSteps(null)).toBe(6);
    expect(effectiveToolLoopMaxSteps(0)).toBe(6);
    expect(effectiveToolLoopMaxSteps(-3)).toBe(6);
    expect(effectiveToolLoopMaxSteps(3)).toBe(3);
    expect(effectiveToolLoopMaxSteps(8)).toBe(8);
    expect(effectiveToolLoopMaxSteps(12)).toBe(8);
  });
});

describe('ToolCallLoop — one round of propose → execute → feed back → answer', () => {
  it('executes the tool that hit, feeds back in order and answers on the next leg', async () => {
    const execute = vi.fn(async (_call: ProxyToolCall, _context: ToolExecutionContext) => ({
      content: '{"ok":true,"result":{"hits":[]}}',
    }));
    const registry = new ToolRegistry([makeEntry('library_search', execute)]);
    const runner = makeRunner([
      handle([text('thinking'), toolCall('c1', 'library_search', '{"query":"x"}')]),
      handle([text('answer')]),
    ]);
    const progress: string[] = [];
    const loop = new ToolCallLoop({
      registry,
      runLeg: runner.runLeg,
      signal,
      limits: { maxSteps: 6 },
    });

    const result = await loop.run([{ role: 'user', content: 'hi' }], (event) => {
      progress.push(event.type);
    });

    expect(result.text).toBe('answer');
    expect(result.legTexts).toEqual(['thinking', 'answer']);
    expect(result.executedToolSteps).toBe(1);
    expect(result.receivedStructuredToolCalls).toBe(true);
    expect(result.endedWithoutToolCall).toBe(false);
    expect(result.stepLimitReached).toBe(false);

    expect(execute).toHaveBeenCalledTimes(1);
    // The context handed to the entry carries this run's cancellation signal (the same object, not a copy).
    expect(execute.mock.calls[0]?.[1]).toEqual({ callID: 'c1', stepNumber: 1, legIndex: 0, signal });
    expect(execute.mock.calls[0]?.[1].signal).toBe(signal);

    // Both legs carry tools; toolChoice=auto within the loop (not the synthesis leg yet).
    expect(runner.requests).toHaveLength(2);
    expect(runner.requests[0]?.toolChoice).toBe('auto');
    expect(runner.requests[0]?.tools).toHaveLength(1);
    expect(runner.requests[1]?.toolChoice).toBe('auto');

    // History of the second leg: the assistant proposal + the result of the tool that hit.
    const second = runner.requests[1]?.messages ?? [];
    const assistant = second.find((message) => message.role === 'assistant');
    expect(assistant?.tool_calls?.[0]?.id).toBe('c1');
    const results = toolMessages(second);
    expect(results).toHaveLength(1);
    expect(results[0]?.tool_call_id).toBe('c1');
    expect(JSON.parse(String(results[0]?.content))).toEqual({
      ok: true,
      result: { hits: [] },
    });

    expect(progress).toContain('toolCallsAccepted');
  });

  it('answers on the first leg with zero tool calls: endedWithoutToolCall=true and no second leg', async () => {
    const registry = new ToolRegistry([makeEntry('library_search', async () => ({ content: '{}' }))]);
    const runner = makeRunner([handle([text('direct answer')])]);
    const loop = new ToolCallLoop({
      registry,
      runLeg: runner.runLeg,
      signal,
      limits: { maxSteps: 6 },
    });

    const result = await loop.run([{ role: 'user', content: 'hi' }]);

    expect(result.text).toBe('direct answer');
    expect(result.endedWithoutToolCall).toBe(true);
    expect(result.receivedStructuredToolCalls).toBe(false);
    expect(runner.requests).toHaveLength(1);
  });
});

describe('ToolCallLoop — registry misses', () => {
  it('whole leg missed: no execution, no further leg, handed to onUnhandledToolCalls', async () => {
    const registry = new ToolRegistry([makeEntry('library_search', async () => ({ content: '{}' }))]);
    const runner = makeRunner([handle([text('hmm'), toolCall('c1', 'mcp_other_tool')])]);
    const onUnhandled = vi.fn();
    const loop = new ToolCallLoop({
      registry,
      runLeg: runner.runLeg,
      signal,
      limits: { maxSteps: 6 },
      onUnhandledToolCalls: onUnhandled,
    });

    const result = await loop.run([{ role: 'user', content: 'hi' }]);

    expect(onUnhandled).toHaveBeenCalledTimes(1);
    const reported = onUnhandled.mock.calls[0]?.[0] as ProxyToolCall[];
    expect(reported.map((call) => call.function.name)).toEqual(['mcp_other_tool']);
    expect(result.text).toBe('hmm');
    expect(result.receivedStructuredToolCalls).toBe(true);
    expect(result.executedToolSteps).toBe(0);
    expect(runner.requests).toHaveLength(1);
  });

  it('mixed leg: hits are executed, misses get unknown_tool, the next leg continues', async () => {
    const registry = new ToolRegistry([
      makeEntry('library_search', async () => ({ content: '{"ok":true}' })),
    ]);
    const runner = makeRunner([
      handle([
        text('mixed leg'),
        { type: 'tool_calls', toolCalls: [{ index: 0, id: 'c1', type: 'function', name: 'library_search', arguments: '{}' }] },
        { type: 'tool_calls', toolCalls: [{ index: 1, id: 'c2', type: 'function', name: 'mcp_other_tool', arguments: '{}' }] },
      ]),
      handle([text('answer')]),
    ]);
    const onUnhandled = vi.fn();
    const loop = new ToolCallLoop({
      registry,
      runLeg: runner.runLeg,
      signal,
      limits: { maxSteps: 6 },
      onUnhandledToolCalls: onUnhandled,
    });

    const result = await loop.run([{ role: 'user', content: 'hi' }]);

    expect(result.text).toBe('answer');
    expect(onUnhandled).toHaveBeenCalledTimes(1);
    const second = runner.requests[1]?.messages ?? [];
    const results = toolMessages(second);
    // Both proposals have a matching tool message, in proposal order.
    expect(results.map((message) => message.tool_call_id)).toEqual(['c1', 'c2']);
    expect(JSON.parse(String(results[1]?.content))).toEqual({
      ok: false,
      error: { code: 'unknown_tool', message: 'Unsupported tool: mcp_other_tool' },
    });
  });
});

describe('ToolCallLoop — step limit', () => {
  it('stops executing after maxSteps and runs the tool-less synthesis leg', async () => {
    const execute = vi.fn(async () => ({ content: '{"ok":true}' }));
    const registry = new ToolRegistry([makeEntry('library_search', execute)]);
    const runner = makeRunner([
      handle([toolCall('c1', 'library_search')]),
      handle([toolCall('c2', 'library_search')]),
      handle([text('synthesis')]),
    ]);
    const loop = new ToolCallLoop({
      registry,
      runLeg: runner.runLeg,
      signal,
      limits: { maxSteps: 2 },
    });

    const result = await loop.run([{ role: 'user', content: 'hi' }]);

    expect(execute).toHaveBeenCalledTimes(2);
    expect(result.executedToolSteps).toBe(2);
    expect(result.stepLimitReached).toBe(true);
    expect(result.text).toBe('synthesis');
    // The third leg is the synthesis leg: toolChoice=none.
    expect(runner.requests).toHaveLength(3);
    expect(runner.requests[2]?.toolChoice).toBe('none');
    const finalMessages = runner.requests[2]?.messages ?? [];
    expect(finalMessages.at(-1)).toEqual({
      role: 'system',
      content:
        'The tool call limit was reached. Answer now using the tool results you already have. Do not call another tool.',
    });
  });

  it('answers surplus proposals of the same leg with the neutral tool_loop_stopped when the limit is hit', async () => {
    const execute = vi.fn(async () => ({ content: '{"ok":true}' }));
    const registry = new ToolRegistry([makeEntry('library_search', execute)]);
    const runner = makeRunner([
      handle([
        { type: 'tool_calls', toolCalls: [{ index: 0, id: 'c1', type: 'function', name: 'library_search', arguments: '{}' }] },
        { type: 'tool_calls', toolCalls: [{ index: 1, id: 'c2', type: 'function', name: 'library_search', arguments: '{}' }] },
      ]),
      handle([text('synthesis')]),
    ]);
    const loop = new ToolCallLoop({
      registry,
      runLeg: runner.runLeg,
      signal,
      limits: { maxSteps: 1 },
    });

    const result = await loop.run([{ role: 'user', content: 'hi' }]);

    expect(execute).toHaveBeenCalledTimes(1);
    expect(result.stepLimitReached).toBe(true);
    const finalMessages = runner.requests[1]?.messages ?? [];
    const results = toolMessages(finalMessages);
    expect(results.map((message) => message.tool_call_id)).toEqual(['c1', 'c2']);
    expect(JSON.parse(String(results[1]?.content))).toEqual({
      ok: false,
      error: { code: 'tool_loop_stopped', message: 'The tool call step limit was reached.' },
    });
  });
});

describe('ToolCallLoop — failure disposition and self-correction', () => {
  it('feeds a rejected argument back as a structured error and counts a self-correction; throws the run beyond the limit', async () => {
    const registry = new ToolRegistry([
      makeEntry('library_search', async () => {
        throw new ToolCallRejection('invalid_arguments', 'bad args');
      }),
    ]);
    const runner = makeRunner([
      handle([toolCall('c1', 'library_search')]),
      handle([toolCall('c2', 'library_search')]),
    ]);
    const loop = new ToolCallLoop({
      registry,
      runLeg: runner.runLeg,
      signal,
      limits: { maxSteps: 6, maxSelfCorrections: 1 },
    });

    await expect(loop.run([{ role: 'user', content: 'hi' }])).rejects.toBeInstanceOf(
      ToolCallRejection,
    );
    expect(runner.requests).toHaveLength(2);
    const second = runner.requests[1]?.messages ?? [];
    expect(JSON.parse(String(toolMessages(second)[0]?.content))).toEqual({
      ok: false,
      error: { code: 'invalid_arguments', message: 'bad args' },
    });
  });

  it('a degrade failure only loses that one call, research continues', async () => {
    const registry = new ToolRegistry([
      makeEntry(
        'library_search',
        async () => {
          throw new Error('upstream down');
        },
        () => ({
          kind: 'degrade',
          code: 'library_source_error',
          message: 'The Library tool call failed.',
        }),
      ),
    ]);
    const runner = makeRunner([
      handle([toolCall('c1', 'library_search')]),
      handle([text('answer')]),
    ]);
    const loop = new ToolCallLoop({
      registry,
      runLeg: runner.runLeg,
      signal,
      limits: { maxSteps: 6 },
    });

    const result = await loop.run([{ role: 'user', content: 'hi' }]);

    expect(result.text).toBe('answer');
    expect(result.executedToolSteps).toBe(1);
    const second = runner.requests[1]?.messages ?? [];
    expect(JSON.parse(String(toolMessages(second)[0]?.content))).toEqual({
      ok: false,
      error: { code: 'library_source_error', message: 'The Library tool call failed.' },
    });
  });

  it('a fatal disposition throws the whole run', async () => {
    const registry = new ToolRegistry([
      makeEntry(
        'library_search',
        async () => {
          throw new Error('needs reauth');
        },
        () => ({ kind: 'fatal' }),
      ),
    ]);
    const runner = makeRunner([handle([toolCall('c1', 'library_search')])]);
    const loop = new ToolCallLoop({
      registry,
      runLeg: runner.runLeg,
      signal,
      limits: { maxSteps: 6 },
    });

    await expect(loop.run([{ role: 'user', content: 'hi' }])).rejects.toThrow('needs reauth');
  });

  it('stops the leg when an entry declares stopReason and answers the remaining proposals with tool_loop_stopped', async () => {
    const execute = vi.fn(async () => ({
      content: '{"ok":true}',
      stopReason: 'The empty-result limit was reached.',
    }));
    const registry = new ToolRegistry([makeEntry('library_search', execute)]);
    const runner = makeRunner([
      handle([
        { type: 'tool_calls', toolCalls: [{ index: 0, id: 'c1', type: 'function', name: 'library_search', arguments: '{}' }] },
        { type: 'tool_calls', toolCalls: [{ index: 1, id: 'c2', type: 'function', name: 'library_search', arguments: '{}' }] },
      ]),
      handle([text('synthesis')]),
    ]);
    const loop = new ToolCallLoop({
      registry,
      runLeg: runner.runLeg,
      signal,
      limits: { maxSteps: 6 },
    });

    const result = await loop.run([{ role: 'user', content: 'hi' }]);

    expect(execute).toHaveBeenCalledTimes(1);
    expect(result.stepLimitReached).toBe(false);
    expect(result.text).toBe('synthesis');
    const finalMessages = runner.requests[1]?.messages ?? [];
    const results = toolMessages(finalMessages);
    expect(JSON.parse(String(results[1]?.content))).toEqual({
      ok: false,
      error: { code: 'tool_loop_stopped', message: 'The empty-result limit was reached.' },
    });
    expect(finalMessages.some((message) => message.role === 'system' && message.content === 'The empty-result limit was reached.')).toBe(true);
  });
});

describe('ToolCallLoop — token budget and usage merging', () => {
  it('stops calling tools once the budget is reached and runs the synthesis leg', async () => {
    const execute = vi.fn(async () => ({ content: '{"ok":true}' }));
    const registry = new ToolRegistry([makeEntry('library_search', execute)]);
    const runner = makeRunner([
      handle([toolCall('c1', 'library_search'), { type: 'usage', usage: { total_tokens: 10 } }]),
      handle([text('synthesis')]),
    ]);
    const loop = new ToolCallLoop({
      registry,
      runLeg: runner.runLeg,
      signal,
      limits: { maxSteps: 6, tokenBudget: 5 },
    });

    const result = await loop.run([{ role: 'user', content: 'hi' }]);

    expect(execute).not.toHaveBeenCalled();
    expect(result.usage?.total_tokens).toBe(10);
    const finalMessages = runner.requests[1]?.messages ?? [];
    expect(JSON.parse(String(toolMessages(finalMessages)[0]?.content))).toEqual({
      ok: false,
      error: {
        code: 'tool_loop_stopped',
        message: 'The token budget for tool calls was reached.',
      },
    });
    expect(finalMessages.at(-1)).toEqual({
      role: 'system',
      content:
        'The token budget for tool calls was reached. Answer now using the tool results you already have and do not call another tool. If they are not enough to answer, say so clearly.',
    });
  });

  it('accumulates usage across legs and reports it per leg', async () => {
    const registry = new ToolRegistry([makeEntry('library_search', async () => ({ content: '{}' }))]);
    const runner = makeRunner([
      handle([toolCall('c1', 'library_search'), { type: 'usage', usage: { prompt_tokens: 1, completion_tokens: 2 } }]),
      handle([text('answer'), { type: 'usage', usage: { total_tokens: 10 } }]),
    ]);
    const usageEvents: number[] = [];
    const loop = new ToolCallLoop({
      registry,
      runLeg: runner.runLeg,
      signal,
      limits: { maxSteps: 6 },
    });

    const result = await loop.run([{ role: 'user', content: 'hi' }], (event) => {
      if (event.type === 'usage') usageEvents.push(event.usage.total_tokens ?? -1);
    });

    expect(result.usage?.prompt_tokens).toBe(1);
    expect(result.usage?.completion_tokens).toBe(2);
    expect(result.usage?.total_tokens).toBe(10);
    expect(usageEvents).toEqual([-1, 10]);
  });
});

describe('ToolCallLoop — leg failure', () => {
  it('turns an error event in the stream into a thrown ToolLoopError', async () => {
    const registry = new ToolRegistry([makeEntry('library_search', async () => ({ content: '{}' }))]);
    const runner = makeRunner([
      handle([{ type: 'error', error: 'upstream 500', errorKind: 'upstream' }]),
    ]);
    const loop = new ToolCallLoop({
      registry,
      runLeg: runner.runLeg,
      signal,
      limits: { maxSteps: 6 },
    });

    await expect(loop.run([{ role: 'user', content: 'hi' }])).rejects.toMatchObject({
      name: 'ToolLoopError',
      code: 'upstream',
      message: 'upstream 500',
    });
  });
});

function multiCall(...calls: Array<[id: string, name: string]>): StreamEvent[] {
  return calls.map(([id, name], index) => ({
    type: 'tool_calls' as const,
    toolCalls: [{ index, id, type: 'function' as const, name, arguments: '{}' }],
  }));
}

function isAbort(error: unknown): boolean {
  return error instanceof Error && error.name === 'AbortError';
}

describe('ToolCallLoop — neutral results (neither counted as consecutive failures nor resetting them)', () => {
  const notFound = new Error('not found');
  const flaky = new Error('source flaky');
  const disposition = (error: unknown): ToolFailureDisposition =>
    error === notFound
      ? { kind: 'neutral', code: 'doc_not_found', message: 'The document was not found.' }
      : { kind: 'degrade', code: 'source_error', message: 'The tool call failed.' };

  it('3 neutral results in a row do not trip the breaker: each feeds back ok:false, takes a step, and the next leg answers', async () => {
    const execute = vi.fn(async () => {
      throw notFound;
    });
    const registry = new ToolRegistry([makeEntry('doc_read', execute, disposition)]);
    const runner = makeRunner([
      handle(multiCall(['c1', 'doc_read'], ['c2', 'doc_read'], ['c3', 'doc_read'])),
      handle([text('all three are gone')]),
    ]);
    const loop = new ToolCallLoop({
      registry,
      runLeg: runner.runLeg,
      signal,
      limits: { maxSteps: 6, maxConsecutiveToolFailures: 3 },
    });

    const result = await loop.run([{ role: 'user', content: 'hi' }]);

    expect(result.text).toBe('all three are gone');
    expect(execute).toHaveBeenCalledTimes(3);
    expect(result.executedToolSteps).toBe(3);
    const results = toolMessages(runner.requests[1]?.messages ?? []);
    expect(results.map((message) => message.tool_call_id)).toEqual(['c1', 'c2', 'c3']);
    for (const message of results) {
      expect(JSON.parse(String(message.content))).toEqual({
        ok: false,
        error: { code: 'doc_not_found', message: 'The document was not found.' },
      });
    }
  });

  it('failure, failure, neutral, failure → breaker trips: neutral does not reset earlier failures', async () => {
    const outcomes = [flaky, flaky, notFound, flaky];
    const execute = vi.fn(async () => {
      throw outcomes[execute.mock.calls.length - 1];
    });
    const registry = new ToolRegistry([makeEntry('doc_read', execute, disposition)]);
    const runner = makeRunner([
      handle(
        multiCall(['c1', 'doc_read'], ['c2', 'doc_read'], ['c3', 'doc_read'], ['c4', 'doc_read']),
      ),
      handle([text('should not get here')]),
    ]);
    const loop = new ToolCallLoop({
      registry,
      runLeg: runner.runLeg,
      signal,
      limits: { maxSteps: 8, maxConsecutiveToolFailures: 3 },
    });

    await expect(loop.run([{ role: 'user', content: 'hi' }])).rejects.toBe(flaky);
    expect(execute).toHaveBeenCalledTimes(4);
    expect(runner.requests).toHaveLength(1);
  });

  it('failure, failure, success, failure → no breaker: control case proving the previous trip comes from neutral not resetting', async () => {
    let attempt = 0;
    const execute = vi.fn(async () => {
      attempt += 1;
      if (attempt === 3) return { content: '{"ok":true}' };
      throw flaky;
    });
    const registry = new ToolRegistry([makeEntry('doc_read', execute, disposition)]);
    const runner = makeRunner([
      handle(
        multiCall(['c1', 'doc_read'], ['c2', 'doc_read'], ['c3', 'doc_read'], ['c4', 'doc_read']),
      ),
      handle([text('answer')]),
    ]);
    const loop = new ToolCallLoop({
      registry,
      runLeg: runner.runLeg,
      signal,
      limits: { maxSteps: 8, maxConsecutiveToolFailures: 3 },
    });

    const result = await loop.run([{ role: 'user', content: 'hi' }]);
    expect(result.text).toBe('answer');
    expect(execute).toHaveBeenCalledTimes(4);
  });

  it('neutral results reaching the step limit still wind down into the synthesis leg', async () => {
    const execute = vi.fn(async () => {
      throw notFound;
    });
    const registry = new ToolRegistry([makeEntry('doc_read', execute, disposition)]);
    const runner = makeRunner([
      handle(multiCall(['c1', 'doc_read'], ['c2', 'doc_read'])),
      handle([text('synthesis')]),
    ]);
    const loop = new ToolCallLoop({
      registry,
      runLeg: runner.runLeg,
      signal,
      limits: { maxSteps: 1 },
    });

    const result = await loop.run([{ role: 'user', content: 'hi' }]);
    expect(execute).toHaveBeenCalledTimes(1);
    expect(result.stepLimitReached).toBe(true);
    expect(runner.requests[1]?.toolChoice).toBe('none');
  });
});

describe('ToolCallLoop — cancellation', () => {
  it('after a cancellation within a leg none of the remaining tools run and no further leg is sent', async () => {
    const controller = new AbortController();
    const executed: string[] = [];
    const execute = vi.fn(async (call: ProxyToolCall) => {
      executed.push(call.id);
      // The user pressed stop while the first tool was running; the tool itself returns normally (simulating an entry that ignores cancellation).
      if (call.id === 'c1') controller.abort();
      return { content: '{"ok":true}' };
    });
    const registry = new ToolRegistry([makeEntry('writer', execute)]);
    const runner = makeRunner([
      handle(multiCall(['c1', 'writer'], ['c2', 'writer'], ['c3', 'writer'])),
      handle([text('should not get here')]),
    ]);
    const loop = new ToolCallLoop({
      registry,
      runLeg: runner.runLeg,
      signal: controller.signal,
      limits: { maxSteps: 6 },
    });

    const error = await loop.run([{ role: 'user', content: 'hi' }]).catch((reason) => reason);

    expect(isAbort(error)).toBe(true);
    expect(executed).toEqual(['c1']);
    expect(runner.requests).toHaveLength(1);
  });

  it('the signal an entry receives is this run\'s cancellation signal', async () => {
    const controller = new AbortController();
    let seen: AbortSignal | undefined;
    const registry = new ToolRegistry([
      makeEntry('writer', async (_call, context) => {
        seen = context.signal;
        return { content: '{"ok":true}' };
      }),
    ]);
    const runner = makeRunner([handle([toolCall('c1', 'writer')]), handle([text('answer')])]);
    await new ToolCallLoop({
      registry,
      runLeg: runner.runLeg,
      signal: controller.signal,
      limits: { maxSteps: 6 },
    }).run([{ role: 'user', content: 'hi' }]);

    expect(seen).toBe(controller.signal);
  });

  it('cancelled while the last tool is running: no synthesis leg is sent', async () => {
    const controller = new AbortController();
    const registry = new ToolRegistry([
      makeEntry('writer', async () => {
        controller.abort();
        return { content: '{"ok":true}' };
      }),
    ]);
    // maxSteps=1: the limit is hit right after this step, so the loop would normally move on to the synthesis leg.
    const runner = makeRunner([
      handle([toolCall('c1', 'writer')]),
      handle([text('should not get here')]),
    ]);
    const loop = new ToolCallLoop({
      registry,
      runLeg: runner.runLeg,
      signal: controller.signal,
      limits: { maxSteps: 1 },
    });

    const error = await loop.run([{ role: 'user', content: 'hi' }]).catch((reason) => reason);

    expect(isAbort(error)).toBe(true);
    expect(runner.requests).toHaveLength(1);
  });

  it('an ordinary error thrown by a tool during cancellation winds down as cancelled: no feedback, and not the original error via the breaker threshold', async () => {
    const controller = new AbortController();
    const wrapped = new Error('request failed');
    const registry = new ToolRegistry([
      makeEntry(
        'writer',
        async () => {
          controller.abort();
          throw wrapped;
        },
        () => ({ kind: 'degrade', code: 'source_error', message: 'failed' }),
      ),
    ]);
    const runner = makeRunner([handle([toolCall('c1', 'writer')]), handle([text('x')])]);
    const loop = new ToolCallLoop({
      registry,
      runLeg: runner.runLeg,
      signal: controller.signal,
      limits: { maxSteps: 6, maxConsecutiveToolFailures: 1 },
    });

    const error = await loop.run([{ role: 'user', content: 'hi' }]).catch((reason) => reason);

    expect(isAbort(error)).toBe(true);
    expect(error).not.toBe(wrapped);
    expect(runner.requests).toHaveLength(1);
  });

  it('rethrows an AbortError from a tool as is without asking failureDisposition', async () => {
    const failureDisposition = vi.fn((): ToolFailureDisposition => ({
      kind: 'degrade',
      code: 'source_error',
      message: 'failed',
    }));
    const registry = new ToolRegistry([
      makeEntry(
        'writer',
        async () => {
          throw new DOMException('Aborted', 'AbortError');
        },
        failureDisposition,
      ),
    ]);
    const runner = makeRunner([handle([toolCall('c1', 'writer')])]);
    const loop = new ToolCallLoop({
      registry,
      runLeg: runner.runLeg,
      signal,
      limits: { maxSteps: 6 },
    });

    const error = await loop.run([{ role: 'user', content: 'hi' }]).catch((reason) => reason);
    expect(isAbort(error)).toBe(true);
    expect(failureDisposition).not.toHaveBeenCalled();
  });

  it('cancelled before the run starts: not a single leg is sent', async () => {
    const controller = new AbortController();
    controller.abort();
    const registry = new ToolRegistry([makeEntry('writer', async () => ({ content: '{}' }))]);
    const runner = makeRunner([handle([text('x')])]);
    const loop = new ToolCallLoop({
      registry,
      runLeg: runner.runLeg,
      signal: controller.signal,
      limits: { maxSteps: 6 },
    });

    const error = await loop.run([{ role: 'user', content: 'hi' }]).catch((reason) => reason);
    expect(isAbort(error)).toBe(true);
    expect(runner.requests).toHaveLength(0);
  });

  it('cancelled while a model leg is in flight: aborts that leg\'s stream and throws AbortError', async () => {
    const controller = new AbortController();
    const abortLeg = vi.fn();
    let streamController!: ReadableStreamDefaultController<StreamEvent>;
    const hanging: StreamHandle = {
      stream: new ReadableStream<StreamEvent>({
        start(c) {
          streamController = c;
        },
      }),
      abort: () => {
        abortLeg();
        streamController.close();
      },
    };
    const registry = new ToolRegistry([makeEntry('writer', async () => ({ content: '{}' }))]);
    const runner = makeRunner([hanging]);
    const pending = new ToolCallLoop({
      registry,
      runLeg: runner.runLeg,
      signal: controller.signal,
      limits: { maxSteps: 6 },
    })
      .run([{ role: 'user', content: 'hi' }])
      .catch((reason) => reason);

    await Promise.resolve();
    controller.abort();
    const error = await pending;

    expect(isAbort(error)).toBe(true);
    expect(abortLeg).toHaveBeenCalledTimes(1);
  });
});

describe("ToolCallLoop — toolsMode: 'disabled'", () => {
  it('every leg has tools=[] and tool_choice=none even when the registry has definitions', async () => {
    const registry = new ToolRegistry([makeEntry('library_search', async () => ({ content: '{}' }))]);
    const runner = makeRunner([handle([text('direct-send answer')])]);
    const loop = new ToolCallLoop({
      registry,
      runLeg: runner.runLeg,
      signal,
      limits: { maxSteps: 6 },
      toolsMode: 'disabled',
    });

    const result = await loop.run([{ role: 'user', content: 'hi' }]);

    expect(result.text).toBe('direct-send answer');
    expect(runner.requests).toHaveLength(1);
    expect(runner.requests[0]?.tools).toEqual([]);
    expect(runner.requests[0]?.toolChoice).toBe('none');
  });

  it('the model still proposes with an empty registry: no execution, handed to onUnhandledToolCalls, no further leg', async () => {
    const onUnhandled = vi.fn();
    const runner = makeRunner([handle([text('I want to call a tool'), toolCall('c1', 'library_search')])]);
    const loop = new ToolCallLoop({
      registry: ToolRegistry.empty,
      runLeg: runner.runLeg,
      signal,
      limits: { maxSteps: 6 },
      toolsMode: 'disabled',
      onUnhandledToolCalls: onUnhandled,
    });

    const result = await loop.run([{ role: 'user', content: 'hi' }]);

    expect(onUnhandled).toHaveBeenCalledTimes(1);
    expect(result.executedToolSteps).toBe(0);
    expect(runner.requests).toHaveLength(1);
  });
});

describe('ToolCallLoop — unhandledToolCalls: selfCorrect', () => {
  it('missed names get unknown_tool in order and count as self-corrections, bypass onUnhandledToolCalls, and the next leg continues', async () => {
    const execute = vi.fn(async () => ({ content: '{"ok":true}' }));
    const onUnhandled = vi.fn();
    const registry = new ToolRegistry([makeEntry('library_search', execute)]);
    const runner = makeRunner([
      handle(multiCall(['c1', 'libary_serach'], ['c2', 'library_search'])),
      handle([text('answer')]),
    ]);
    const loop = new ToolCallLoop({
      registry,
      runLeg: runner.runLeg,
      signal,
      limits: { maxSteps: 6 },
      unhandledToolCalls: 'selfCorrect',
      onUnhandledToolCalls: onUnhandled,
    });

    const result = await loop.run([{ role: 'user', content: 'hi' }]);

    expect(result.text).toBe('answer');
    expect(onUnhandled).not.toHaveBeenCalled();
    expect(execute).toHaveBeenCalledTimes(1);
    // The call with the misspelled name does not take a tool step.
    expect(result.executedToolSteps).toBe(1);
    const results = toolMessages(runner.requests[1]?.messages ?? []);
    expect(results.map((message) => message.tool_call_id)).toEqual(['c1', 'c2']);
    expect(JSON.parse(String(results[0]?.content))).toEqual({
      ok: false,
      error: { code: 'unknown_tool', message: 'Unsupported tool: libary_serach' },
    });
  });

  it('continues even when a whole leg has misspelled names (handoff mode would end here)', async () => {
    const registry = new ToolRegistry([makeEntry('library_search', async () => ({ content: '{}' }))]);
    const runner = makeRunner([
      handle([toolCall('c1', 'nope')]),
      handle([text('answer')]),
    ]);
    const loop = new ToolCallLoop({
      registry,
      runLeg: runner.runLeg,
      signal,
      limits: { maxSteps: 6 },
      unhandledToolCalls: 'selfCorrect',
    });

    const result = await loop.run([{ role: 'user', content: 'hi' }]);
    expect(result.text).toBe('answer');
    expect(runner.requests).toHaveLength(2);
  });

  it('throws ToolCallRejection(unknown_tool) beyond the self-correction limit, with the text from unknownToolMessage', async () => {
    const registry = new ToolRegistry([makeEntry('library_search', async () => ({ content: '{}' }))]);
    const runner = makeRunner([
      handle([toolCall('c1', 'nope')]),
      handle([toolCall('c2', 'nope')]),
    ]);
    const loop = new ToolCallLoop({
      registry,
      runLeg: runner.runLeg,
      signal,
      limits: { maxSteps: 6, maxSelfCorrections: 1 },
      unhandledToolCalls: 'selfCorrect',
      unknownToolMessage: (name) => `No such tool here: ${name}`,
    });

    await expect(loop.run([{ role: 'user', content: 'hi' }])).rejects.toMatchObject({
      name: 'ToolCallRejection',
      code: 'unknown_tool',
      message: 'No such tool here: nope',
    });
    expect(runner.requests).toHaveLength(2);
    expect(
      JSON.parse(String(toolMessages(runner.requests[1]?.messages ?? [])[0]?.content)),
    ).toEqual({
      ok: false,
      error: { code: 'unknown_tool', message: 'No such tool here: nope' },
    });
  });
});

describe('ToolCallLoop — onFirstLegWithoutToolCalls', () => {
  it('returns messages: drops the first-leg text and runs the tool-less synthesis leg with the injected history', async () => {
    const registry = new ToolRegistry([makeEntry('library_search', async () => ({ content: '{}' }))]);
    const runner = makeRunner([handle([text('answer made up without retrieval')]), handle([text('evidence-based answer')])]);
    const injected: ProxyMessage[] = [
      { role: 'system', content: 'evidence' },
      { role: 'user', content: 'hi' },
    ];
    const hook = vi.fn(async () => injected);
    const loop = new ToolCallLoop({
      registry,
      runLeg: runner.runLeg,
      signal,
      limits: { maxSteps: 6 },
      onFirstLegWithoutToolCalls: hook,
    });

    const result = await loop.run([{ role: 'user', content: 'hi' }]);

    expect(hook).toHaveBeenCalledWith('answer made up without retrieval');
    expect(result.text).toBe('evidence-based answer');
    expect(result.legTexts).toEqual(['answer made up without retrieval', 'evidence-based answer']);
    expect(result.endedWithoutToolCall).toBe(false);
    // This is not "hitting the step limit": no limit hint is appended and stepLimitReached stays false.
    expect(result.stepLimitReached).toBe(false);
    expect(runner.requests[1]?.messages).toEqual(injected);
    expect(runner.requests[1]?.toolChoice).toBe('none');
  });

  it('returns null: the first-leg text is the answer and no second leg is sent', async () => {
    const registry = new ToolRegistry([makeEntry('library_search', async () => ({ content: '{}' }))]);
    const runner = makeRunner([handle([text('first-leg answer')])]);
    const loop = new ToolCallLoop({
      registry,
      runLeg: runner.runLeg,
      signal,
      limits: { maxSteps: 6 },
      onFirstLegWithoutToolCalls: async () => null,
    });

    const result = await loop.run([{ role: 'user', content: 'hi' }]);
    expect(result.text).toBe('first-leg answer');
    expect(result.endedWithoutToolCall).toBe(true);
    expect(runner.requests).toHaveLength(1);
  });

  it('fires on the first leg only: zero tool calls on a later leg is a normal wrap-up', async () => {
    const hook = vi.fn(async () => null);
    const registry = new ToolRegistry([makeEntry('library_search', async () => ({ content: '{}' }))]);
    const runner = makeRunner([
      handle([toolCall('c1', 'library_search')]),
      handle([text('answer')]),
    ]);
    const loop = new ToolCallLoop({
      registry,
      runLeg: runner.runLeg,
      signal,
      limits: { maxSteps: 6 },
      onFirstLegWithoutToolCalls: hook,
    });

    const result = await loop.run([{ role: 'user', content: 'hi' }]);
    expect(result.text).toBe('answer');
    expect(hook).not.toHaveBeenCalled();
  });
});

describe('ToolCallLoop — callIdFallbackPrefix', () => {
  const blankIdCall: StreamEvent = {
    type: 'tool_calls',
    toolCalls: [{ index: 0, id: '', type: 'function', name: 'library_search', arguments: '{}' }],
  };

  it('fills in tool_call_<leg>_<index> by default when the upstream gives no call id, without collisions across legs', async () => {
    const execute = vi.fn(async (_call: ProxyToolCall, _context: ToolExecutionContext) => ({
      content: '{"ok":true}',
    }));
    const registry = new ToolRegistry([makeEntry('library_search', execute)]);
    const runner = makeRunner([handle([blankIdCall]), handle([blankIdCall]), handle([text('answer')])]);
    await new ToolCallLoop({
      registry,
      runLeg: runner.runLeg,
      signal,
      limits: { maxSteps: 6 },
    }).run([{ role: 'user', content: 'hi' }]);

    const ids = execute.mock.calls.map((args) => args[1].callID);
    expect(ids).toHaveLength(2);
    expect(ids[0]).toMatch(/^tool_call_1_/);
    expect(ids[1]).toMatch(/^tool_call_2_/);
    // The assistant proposal and the tool result use the same filled-in id.
    const third = runner.requests[2]?.messages ?? [];
    expect(toolMessages(third).map((message) => message.tool_call_id)).toEqual(ids);
    expect(
      third
        .filter((message) => message.role === 'assistant')
        .map((message) => message.tool_calls?.[0]?.id),
    ).toEqual(ids);
  });

  it('applies a custom prefix', async () => {
    const execute = vi.fn(async (_call: ProxyToolCall, _context: ToolExecutionContext) => ({
      content: '{"ok":true}',
    }));
    const registry = new ToolRegistry([makeEntry('library_search', execute)]);
    const runner = makeRunner([handle([blankIdCall]), handle([text('answer')])]);
    await new ToolCallLoop({
      registry,
      runLeg: runner.runLeg,
      signal,
      limits: { maxSteps: 6 },
      callIdFallbackPrefix: 'mcp_call',
    }).run([{ role: 'user', content: 'hi' }]);

    expect(execute.mock.calls[0]?.[1].callID).toMatch(/^mcp_call_1_/);
  });
});

describe('ToolCallLoop — neutral default prompts and overridable stop error code', () => {
  it('default prompts carry no feature flavour', () => {
    const all = Object.values(defaultToolLoopPrompts).join('\n');
    expect(all).not.toMatch(/research|library|cite|\[n\]|evidence|source/i);
  });

  it('uses the caller\'s prompts and stoppedErrorCode verbatim when passed explicitly', async () => {
    const prompts: ToolLoopPrompts = {
      stepLimitReached: 'STEP LIMIT SYSTEM',
      tokenBudgetReached: 'BUDGET SYSTEM',
      stoppedByStepLimit: 'STEP LIMIT TOOL',
      stoppedByTokenBudget: 'BUDGET TOOL',
    };
    const registry = new ToolRegistry([
      makeEntry('library_search', async () => ({ content: '{"ok":true}' })),
    ]);

    const stepRunner = makeRunner([
      handle(multiCall(['c1', 'library_search'], ['c2', 'library_search'])),
      handle([text('synthesis')]),
    ]);
    await new ToolCallLoop({
      registry,
      runLeg: stepRunner.runLeg,
      signal,
      limits: { maxSteps: 1 },
      prompts,
      stoppedErrorCode: 'research_stopped',
    }).run([{ role: 'user', content: 'hi' }]);
    const stepMessages = stepRunner.requests[1]?.messages ?? [];
    expect(JSON.parse(String(toolMessages(stepMessages)[1]?.content))).toEqual({
      ok: false,
      error: { code: 'research_stopped', message: 'STEP LIMIT TOOL' },
    });
    expect(stepMessages.at(-1)).toEqual({ role: 'system', content: 'STEP LIMIT SYSTEM' });

    const budgetRunner = makeRunner([
      handle([toolCall('c1', 'library_search'), { type: 'usage', usage: { total_tokens: 10 } }]),
      handle([text('synthesis')]),
    ]);
    await new ToolCallLoop({
      registry,
      runLeg: budgetRunner.runLeg,
      signal,
      limits: { maxSteps: 6, tokenBudget: 5 },
      prompts,
      stoppedErrorCode: 'research_stopped',
    }).run([{ role: 'user', content: 'hi' }]);
    const budgetMessages = budgetRunner.requests[1]?.messages ?? [];
    expect(JSON.parse(String(toolMessages(budgetMessages)[0]?.content))).toEqual({
      ok: false,
      error: { code: 'research_stopped', message: 'BUDGET TOOL' },
    });
    expect(budgetMessages.at(-1)).toEqual({ role: 'system', content: 'BUDGET SYSTEM' });
  });
});
