import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { describe, expect, it } from 'vitest';
import { createProxyChunkParser } from '../providers/proxy-chunk-parser';
import { applyToolCallWireAdapter } from '../providers/request-builders/tool-call-wire-adapter';
import type { ProxyToolCall } from '../providers/request-builders/runtime';
import { parseSSELines } from '../providers/sse-parser';
import type { StreamEvent, StreamHandle } from '../providers/types';
import { ToolCallLoop } from '../tools/tool-call-loop';
import { ToolCallRejection, type ToolLoopLegRequest } from '../tools/tool-loop-contracts';
import { ToolRegistry } from '../tools/tool-registry';
import { McpClient } from './mcp-client';
import {
  EMPTY_MCP_TOOL_PLAN,
  MCP_LOOP_PROMPTS,
  MCP_LOOP_STOPPED_ERROR_CODE,
  McpConversationGrants,
  McpToolExecutor,
  createMcpToolEntries,
  denyingMcpConfirmationGate,
  mcpLoopLimits,
  mcpSystemPrompt,
  planMcpTools,
  validatedMcpArguments,
  type McpBridgeServerInput,
  type McpConfirmationChoice,
  type McpConfirmationGate,
  type McpConfirmationRequest,
  type McpReauthorizationChoice,
  type McpReauthorizationRequest,
  type McpToolPlan,
  type McpToolStepUpdate,
} from './mcp-tool-bridge';
import { MCP_SAFETY_PROMPT } from './mcp-pure';
import { McpTransportError, type McpHttpRequest, type McpTransport } from './mcp-transport';
import { MCP_RUNTIME_CONFIG_FALLBACK, type McpRuntimeConfig, type McpServerRecord, type McpToolPermission, type McpToolSnapshot } from './mcp-types';

/**
  * MCP bridge × generic tool loop × protocol client, all production implementations. Only the two ends are
  * scripted: the model leg (shared corpus
  * `provider-toolcall/` parsed by the production `createProxyChunkParser`) and the MCP server (scripted transport).
  * Assertions target what the production path produces: the tools in the outbound request, the JSON-RPC sent
  * to the server, and the tool messages fed back into the history.
 */

const CORPUS = resolve(__dirname, '../../../../../shared/test-fixtures/provider-toolcall');
const SERVER_ID = '00000000-0000-4000-8000-0000000000a1';
const CONVERSATION = 'conv-1';
const WEATHER = 'mcp_weather_get_weather';
const TIME = 'mcp_weather_get_time';

function record(overrides: Partial<McpServerRecord> = {}): McpServerRecord {
  return {
    id: SERVER_ID, name: 'Weather', slug: 'weather', url: 'https://mcp.example.com/mcp', authKind: 'auto',
    iconURL: null, createdAt: 1, updatedAt: 1, schemaVersion: 1, ...overrides,
  };
}

function snapshot(toolName: string, overrides: Partial<McpToolSnapshot> = {}): McpToolSnapshot {
  return {
    serverId: SERVER_ID, toolName, title: `Title of ${toolName}`, description: `Description of ${toolName}`,
    inputSchema: { type: 'object', properties: { city: { type: 'string' }, unit: { type: 'string' } } },
    annotations: {}, contentHash: `hash-${toolName}`, readOnly: true, pendingReview: false, oversized: false, updatedAt: 1,
    ...overrides,
  };
}

function input(overrides: Partial<McpBridgeServerInput> = {}): McpBridgeServerInput {
  return { record: record(), connectionStatus: 'connected', snapshots: [snapshot('get_weather')], permissions: {}, ...overrides };
}

// ── Scripted MCP server ──────────────────────────────────────────────────

interface FakeServer extends McpTransport {
  /** Every JSON-RPC request the server received (built by the production client). */
  calls: Array<{ method: string; params: Record<string, unknown>; request: McpHttpRequest }>;
  toolCalls(): Array<{ name: string; arguments: unknown }>;
}

function fakeServer(reply: (name: string, index: number) => { text?: string; isError?: boolean; status?: number; network?: boolean; hang?: boolean } = () => ({ text: 'Sunny, 22°C' })): FakeServer {
  const calls: FakeServer['calls'] = [];
  let callIndex = 0;
  return {
    calls,
    toolCalls: () => calls.filter((call) => call.method === 'tools/call').map((call) => ({ name: call.params.name as string, arguments: call.params.arguments })),
    async send(request) {
      const body = JSON.parse(request.body ?? '{}') as { id: number; method: string; params: Record<string, unknown> };
      calls.push({ method: body.method, params: body.params ?? {}, request });
      const json = (result: unknown, status = 200) => ({
        status,
        headers: new Headers({ 'content-type': 'application/json' }),
        body: new Response(JSON.stringify({ jsonrpc: '2.0', id: body.id, result })).body,
      });
      if (body.method === 'tools/list') return json({ resultType: 'complete', tools: [] });
      const outcome = reply(body.params.name as string, callIndex++);
      if (outcome.network) throw new McpTransportError('network');
      if (outcome.hang) {
        return new Promise((_, reject) => {
          request.signal?.addEventListener('abort', () => reject(new DOMException('aborted', 'AbortError')));
        });
      }
      if (outcome.status && outcome.status !== 200) return { status: outcome.status, headers: new Headers(), body: new Response('').body };
      return json({ resultType: 'complete', content: [{ type: 'text', text: outcome.text ?? '' }], isError: outcome.isError === true });
    },
  };
}

// ── Scripted model leg ───────────────────────────────────────────────────

function handle(events: readonly StreamEvent[]): StreamHandle {
  return {
    stream: new ReadableStream<StreamEvent>({
      start(controller) {
        for (const event of events) controller.enqueue(event);
        controller.close();
      },
    }),
    abort: () => {},
  };
}

/** Shared corpus SSE → production parser → stream events. Only the tool name in the corpus is swapped for the name sent in this request; the corpus files stay untouched. */
function corpusLeg(file: string): StreamEvent[] {
  const raw = readFileSync(resolve(CORPUS, file), 'utf8')
    .replaceAll('"get_weather"', `"${WEATHER}"`)
    .replaceAll('"get_time"', `"${TIME}"`);
  const parser = createProxyChunkParser('openAI');
  const events: StreamEvent[] = [];
  for (const entry of parseSSELines(raw)) {
    if (entry.data === '[DONE]') continue;
    const parsed = parser(entry.event, entry.data);
    if (parsed == null) continue;
    events.push(...(Array.isArray(parsed) ? parsed : [parsed]));
  }
  return events;
}

function proposal(id: string, name: string, args = '{"city":"Berlin"}'): StreamEvent {
  return { type: 'tool_calls', toolCalls: [{ index: 0, id, type: 'function', name, arguments: args }] };
}

function proposals(calls: Array<[string, string, string?]>): StreamEvent {
  return { type: 'tool_calls', toolCalls: calls.map(([id, name, args], index) => ({ index, id, type: 'function' as const, name, arguments: args ?? '{"city":"Berlin"}' })) };
}

const answer = (text: string): StreamEvent[] => [{ type: 'delta', content: text }];

function scriptedGate(choices: McpConfirmationChoice[]): McpConfirmationGate & { asked: McpConfirmationRequest[] } {
  const asked: McpConfirmationRequest[] = [];
  return {
    asked,
    async requestConfirmation(request) {
      asked.push(request);
      return choices[asked.length - 1] ?? 'deny';
    },
  };
}

function run(options: {
  plan: McpToolPlan;
  legs: StreamEvent[][];
  server?: FakeServer;
  gate?: McpConfirmationGate;
  grants?: McpConversationGrants;
  signal?: AbortSignal;
  runtimeConfig?: McpRuntimeConfig;
  token?: (serverId: string) => Promise<string | null>;
}) {
  const server = options.server ?? fakeServer();
  const runtimeConfig = options.runtimeConfig ?? MCP_RUNTIME_CONFIG_FALLBACK;
  const steps: McpToolStepUpdate[] = [];
  const requests: ToolLoopLegRequest[] = [];
  const unhandled: ProxyToolCall[] = [];
  const queue = [...options.legs];
  const executor = new McpToolExecutor({
    conversationId: CONVERSATION,
    runtimeConfig,
    gate: options.gate ?? denyingMcpConfirmationGate,
    grants: options.grants ?? new McpConversationGrants(),
    tokenProvider: options.token ?? (async () => 'server-token'),
    makeClient: (endpoint) => new McpClient({ endpoint, transport: server, runtimeConfig }),
    onStep: (update) => { steps.push(update); },
  });
  const loop = new ToolCallLoop({
    registry: new ToolRegistry(createMcpToolEntries(options.plan, executor)),
    runLeg: (request) => {
      requests.push({ ...request, messages: [...request.messages] });
      const next = queue.shift();
      if (!next) throw new Error('no scripted leg left');
      return handle(next);
    },
    signal: options.signal ?? new AbortController().signal,
    limits: mcpLoopLimits(runtimeConfig),
    prompts: MCP_LOOP_PROMPTS,
    stoppedErrorCode: MCP_LOOP_STOPPED_ERROR_CODE,
    onUnhandledToolCalls: (calls) => { unhandled.push(...calls); },
  });
  const result = loop.run([{ role: 'system', content: mcpSystemPrompt('You are helpful.') }, { role: 'user', content: 'Weather?' }]);
  return { result, server, steps, requests, unhandled };
}

/** Tool messages fed back into the history (by call id). */
function toolResult(request: ToolLoopLegRequest, callId: string): { ok: boolean; result?: string; error?: { code: string; message: string } } {
  const message = request.messages.find((item) => item.role === 'tool' && item.tool_call_id === callId);
  return JSON.parse(message!.content as string);
}

const weatherPlan = planMcpTools([input({ snapshots: [snapshot('get_weather'), snapshot('get_time')] })], MCP_RUNTIME_CONFIG_FALLBACK);

describe('four wire protocols replayed: model proposal → MCP call → result fed back', () => {
  const wires = [
    { name: 'openai_chat', file: 'openai_chat.tool_calls.sse', url: 'https://api.example.com/v1/chat/completions' },
    { name: 'openai_responses', file: 'openai_responses.function_call.sse', url: 'https://api.example.com/v1/responses' },
    { name: 'anthropic_messages', file: 'anthropic.tool_use.sse', url: 'https://api.example.com/v1/messages' },
    { name: 'gemini_generate', file: 'gemini.functionCall.sse', url: 'https://api.example.com/v1beta/models/x:streamGenerateContent?alt=sse' },
  ];

  for (const wire of wires) {
    it(`${wire.name}: the proposal in the corpus hits the lookup table, the server is called by the original name, and the result reaches the second leg in that wire protocol's shape`, async () => {
      const { result, server, steps, requests, unhandled } = run({ plan: weatherPlan, legs: [corpusLeg(wire.file), answer('It is sunny.')] });
      const final = await result;

      expect(final.text).toBe('It is sunny.');
      expect(unhandled).toEqual([]);
      // The server receives the original tool name and the model's arguments (JSON-RPC built by the production client)
      const calls = server.toolCalls();
      expect(calls[0]).toEqual({ name: 'get_weather', arguments: { city: 'Melbourne', unit: 'celsius' } });
      // The token goes into the credential only, never into protocol headers
      const callRequest = server.calls.find((call) => call.method === 'tools/call')!.request;
      expect(callRequest.credential).toBe('server-token');
      expect(JSON.stringify(callRequest.headers)).not.toContain('server-token');

      // The first leg carries the name from the lookup table plus the server's description and parameter schema, verbatim, with nothing of ours added
      expect(requests[0].tools.map((tool) => tool.function.name)).toEqual([WEATHER, TIME]);
      expect(requests[0].tools[0].function.description).toBe('Description of get_weather');
      expect(requests[0].messages[0].content).toContain(MCP_SAFETY_PROMPT);

      // Second leg: the request body encoded by the production wire adapter contains both the tool definition and the tool result
      const body = applyToolCallWireAdapter(
        { url: wire.url, headers: {}, body: {} },
        { messages: requests[1].messages, tools: requests[1].tools, toolChoice: requests[1].toolChoice },
      ).body;
      const wireText = JSON.stringify(body);
      expect(wireText).toContain(WEATHER);
      expect(wireText).toContain('Sunny, 22°C');
      // Steps: running first (with the raw arguments), then done (with the head of the result)
      const weatherSteps = steps.filter((step) => step.toolName === 'get_weather');
      expect(weatherSteps.map((step) => step.status)).toEqual(['running', 'done']);
      expect(weatherSteps[0]).toMatchObject({ serverId: SERVER_ID, serverName: 'Weather', title: 'Title of get_weather', argsSummary: 'Melbourne · celsius', step: 1, permission: 'auto', readOnly: true });
      expect(JSON.parse(weatherSteps[0].payload!.arguments!)).toEqual({ city: 'Melbourne', unit: 'celsius' });
      expect(weatherSteps[1].payload).toEqual({ arguments: null, resultPrefix: 'Sunny, 22°C' });
      expect(weatherSteps[1].durationMs).toBeGreaterThanOrEqual(0);
    });
  }

  it('openai_chat corpus with two proposals in one leg: both run and the results are fed back in proposal order', async () => {
    const { result, server, requests } = run({ plan: weatherPlan, legs: [corpusLeg('openai_chat.tool_calls.sse'), answer('Done.')] });
    await result;
    expect(server.toolCalls().map((call) => call.name)).toEqual(['get_weather', 'get_time']);
    const toolMessages = requests[1].messages.filter((message) => message.role === 'tool');
    expect(toolMessages.map((message) => message.tool_call_id)).toEqual(['call_r2_weather', 'call_r2_time']);
    expect(toolResult(requests[1], 'call_r2_weather')).toEqual({ ok: true, result: 'Sunny, 22°C' });
  });
});

describe('assembling the tools available for this request', () => {
  it('quarantined, disabled and oversized tools appear neither in tools nor in the lookup table', () => {
    const plan = planMcpTools([input({
      snapshots: [
        snapshot('get_weather'),
        snapshot('quarantined', { pendingReview: true }),
        snapshot('off_tool'),
        snapshot('huge', { oversized: true }),
        snapshot('writer', { readOnly: false }),
      ],
      permissions: { get_weather: 'auto', off_tool: 'off' },
    })], MCP_RUNTIME_CONFIG_FALLBACK);
    expect(plan.tools.map((tool) => tool.binding.toolName)).toEqual(['get_weather', 'writer']);
    expect([...plan.nameTable.keys()]).toEqual([WEATHER, 'mcp_weather_writer']);
    // Without stored permissions the defaults apply: declared read-only → auto, everything else → ask
    expect(plan.tools.map((tool) => tool.permission)).toEqual(['auto', 'ask']);
  });

  it('those tools do not appear in the request sent by the production loop either', async () => {
    const plan = planMcpTools([input({
      snapshots: [snapshot('get_weather'), snapshot('quarantined', { pendingReview: true }), snapshot('off_tool'), snapshot('huge', { oversized: true })],
      permissions: { off_tool: 'off' },
    })], MCP_RUNTIME_CONFIG_FALLBACK);
    const { result, requests } = run({ plan, legs: [answer('Hi.')] });
    await result;
    const sent = JSON.stringify(requests[0].tools);
    expect(requests[0].tools.map((tool) => tool.function.name)).toEqual([WEATHER]);
    for (const hidden of ['quarantined', 'off_tool', 'huge']) expect(sent).not.toContain(hidden);
  });

  it('a server that needs re-authentication is excluded entirely; empty when the master switch is off or there are no servers', () => {
    expect(planMcpTools([input({ connectionStatus: 'needsAuth' })], MCP_RUNTIME_CONFIG_FALLBACK).tools).toEqual([]);
    expect(planMcpTools([input()], { ...MCP_RUNTIME_CONFIG_FALLBACK, enabled: false })).toBe(EMPTY_MCP_TOOL_PLAN);
    expect(planMcpTools([], MCP_RUNTIME_CONFIG_FALLBACK)).toBe(EMPTY_MCP_TOOL_PLAN);
    // Non-https URLs are never sent out (last line of defence)
    expect(planMcpTools([input({ record: record({ url: 'http://mcp.example.com/mcp' }) })], MCP_RUNTIME_CONFIG_FALLBACK).tools).toEqual([]);
  });

  it('beyond maxToolsPerRequest the list is truncated in the order servers were enabled', () => {
    const second = '00000000-0000-4000-8000-0000000000b2';
    const plan = planMcpTools([
      input({ snapshots: [snapshot('a'), snapshot('b')] }),
      input({ record: record({ id: second, slug: 'second' }), snapshots: [snapshot('c', { serverId: second }), snapshot('d', { serverId: second })] }),
    ], { ...MCP_RUNTIME_CONFIG_FALLBACK, maxToolsPerRequest: 3 });
    expect(plan.truncated).toBe(true);
    expect(plan.tools.map((tool) => tool.binding.outboundName)).toEqual(['mcp_weather_a', 'mcp_weather_b', 'mcp_second_c']);
  });

  it('tools of one server that collide after sanitizing each get a hash suffix; the lookup table points back to each original name', () => {
    const plan = planMcpTools([input({ snapshots: [snapshot('get.weather'), snapshot('get weather')] })], MCP_RUNTIME_CONFIG_FALLBACK);
    const names = plan.tools.map((tool) => tool.binding.outboundName);
    expect(new Set(names).size).toBe(2);
    expect(names.every((name) => /^mcp_weather_get_weather_[0-9a-f]{6}$/.test(name))).toBe(true);
    expect(plan.tools.map((tool) => plan.nameTable.get(tool.binding.outboundName)?.toolName)).toEqual(['get.weather', 'get weather']);
  });

  it('a tool whose parameter schema is not an object is sent with an empty object schema, never a non-object', () => {
    const plan = planMcpTools([input({ snapshots: [snapshot('odd', { inputSchema: 'not-an-object' })] })], MCP_RUNTIME_CONFIG_FALLBACK);
    expect(plan.tools[0].definition.function.parameters).toEqual({ type: 'object' });
  });
});

describe('lookup table', () => {
  it('a name outside the lookup table (including original tool names and other prefixes) is not executed and goes to the existing unhandled path', async () => {
    const { result, server, unhandled, steps } = run({
      plan: weatherPlan,
      legs: [[proposals([['c1', 'get_weather'], ['c2', 'mcp_other_get_weather'], ['c3', 'library_search']])]],
    });
    const final = await result;
    expect(unhandled.map((call) => call.function.name)).toEqual(['get_weather', 'mcp_other_get_weather', 'library_search']);
    expect(server.calls).toEqual([]);
    expect(steps).toEqual([]);
    expect(final.executedToolSteps).toBe(0);
  });

  it('mixed leg: names in the lookup table run, the others get unknown_tool and are handed off', async () => {
    const { result, server, unhandled, requests } = run({
      plan: weatherPlan,
      legs: [[proposals([['c1', 'evil_tool'], ['c2', WEATHER]])], answer('ok')],
    });
    await result;
    expect(server.toolCalls().map((call) => call.name)).toEqual(['get_weather']);
    expect(unhandled.map((call) => call.function.name)).toEqual(['evil_tool']);
    expect(toolResult(requests[1], 'c1').error?.code).toBe('unknown_tool');
  });
});

describe('confirmation gate', () => {
  const askPlan = planMcpTools([input({ snapshots: [snapshot('get_weather', { readOnly: false })] })], MCP_RUNTIME_CONFIG_FALLBACK);

  it('the default gate (no UI to ask) always denies and the server receives no request at all', async () => {
    const { result, server, steps, requests } = run({ plan: askPlan, legs: [[proposal('c1', WEATHER)], answer('Skipped.')] });
    const final = await result;
    expect(server.calls).toEqual([]);
    expect(final.text).toBe('Skipped.');
    expect(toolResult(requests[1], 'c1').error?.code).toBe('user_denied');
    // While waiting for confirmation the step is already running (step block and activity row are present); it only becomes denied after the refusal.
    expect(steps.map((step) => [step.status, step.errorCode, step.permission])).toEqual([
      ['running', null, 'ask'],
      ['denied', 'user_denied', 'ask'],
    ]);
    // Raw arguments are handed over with the first callback only
    expect(steps.map((step) => step.payload?.arguments ?? null)).toEqual(['{"city":"Berlin"}', null]);
  });

  it('no tools/call after the user denies; the other tools of the same leg that need confirmation are still asked one by one', async () => {
    const plan = planMcpTools([input({ snapshots: [snapshot('get_weather', { readOnly: false }), snapshot('get_time', { readOnly: false })] })], MCP_RUNTIME_CONFIG_FALLBACK);
    const gate = scriptedGate(['deny', 'once']);
    const { result, server, requests } = run({ plan, gate, legs: [[proposals([['c1', WEATHER], ['c2', TIME]])], answer('ok')] });
    await result;
    expect(gate.asked.map((request) => request.toolName)).toEqual(['get_weather', 'get_time']);
    expect(server.toolCalls().map((call) => call.name)).toEqual(['get_time']);
    expect(toolResult(requests[1], 'c1').error?.code).toBe('user_denied');
    expect(toolResult(requests[1], 'c2').ok).toBe(true);
  });

  it('the dialog receives the server name, host name, tool title and the raw arguments from the model', async () => {
    const gate = scriptedGate(['once']);
    const { result } = run({ plan: askPlan, gate, legs: [[proposal('c1', WEATHER, '{"city":"Berlin","unit":"c"}')], answer('ok')] });
    await result;
    expect(gate.asked).toEqual([{
      conversationId: CONVERSATION, serverId: SERVER_ID, serverName: 'Weather', serverHost: 'mcp.example.com',
      toolName: 'get_weather', toolTitle: 'Title of get_weather', arguments: { city: 'Berlin', unit: 'c' },
      inputSchema: askPlan.tools[0].snapshot.inputSchema,
      changesData: true,
    }]);
  });

  it('allow-once asks every time; allow-for-this-conversation asks once, only for the same tool of the same server, and only in memory', async () => {
    const once = scriptedGate(['once', 'once']);
    const first = run({ plan: askPlan, gate: once, legs: [[proposal('c1', WEATHER)], [proposal('c2', WEATHER)], answer('ok')] });
    await first.result;
    expect(once.asked).toHaveLength(2);
    expect(first.server.toolCalls()).toHaveLength(2);

    const grants = new McpConversationGrants();
    const gate = scriptedGate(['conversation']);
    const second = run({ plan: askPlan, gate, grants, legs: [[proposal('c1', WEATHER)], [proposal('c2', WEATHER)], answer('ok')] });
    await second.result;
    expect(gate.asked).toHaveLength(1);
    expect(second.server.toolCalls()).toHaveLength(2);
    expect(grants.isGranted(CONVERSATION, SERVER_ID, 'get_weather')).toBe(true);
    expect(grants.isGranted('other-conversation', SERVER_ID, 'get_weather')).toBe(false);
    expect(grants.isGranted(CONVERSATION, SERVER_ID, 'get_time')).toBe(false);
    // A fresh grant table (as after a page reload) remembers nothing
    expect(new McpConversationGrants().isGranted(CONVERSATION, SERVER_ID, 'get_weather')).toBe(false);
    grants.revokeServer(SERVER_ID);
    expect(grants.isGranted(CONVERSATION, SERVER_ID, 'get_weather')).toBe(false);
  });

  it('an unknown value returned by the gate counts as a denial', async () => {
    const gate: McpConfirmationGate = { requestConfirmation: async () => 'always' as McpConfirmationChoice };
    const { result, server } = run({ plan: askPlan, gate, legs: [[proposal('c1', WEATHER)], answer('ok')] });
    await result;
    expect(server.calls).toEqual([]);
  });

  it('user presses stop while waiting for confirmation: the turn ends as cancelled and no tools/call is sent', async () => {
    const controller = new AbortController();
    const gate: McpConfirmationGate = {
      requestConfirmation: (_request, signal) => new Promise((resolveChoice) => {
        signal.addEventListener('abort', () => resolveChoice('once'));
        controller.abort();
      }),
    };
    const { result, server, steps } = run({ plan: askPlan, gate, signal: controller.signal, legs: [[proposal('c1', WEATHER)], answer('never')] });
    await expect(result).rejects.toMatchObject({ name: 'AbortError' });
    expect(server.calls).toEqual([]);
    // This step never ran: it is recorded as interrupted rather than left running forever
    expect(steps.map((step) => [step.status, step.errorCode])).toEqual([['running', null], ['interrupted', 'cancelled']]);
  });
});

describe('authorization expiring mid-run: pause, resume after signing in again, or skip', () => {
  const plan = planMcpTools([input()], MCP_RUNTIME_CONFIG_FALLBACK);

  function reauthRun(options: { choices: McpReauthorizationChoice[]; server: FakeServer; signal?: AbortSignal; onAsk?: () => void }) {
    const asked: McpReauthorizationRequest[] = [];
    const tokens: string[] = [];
    const steps: McpToolStepUpdate[] = [];
    const requests: ToolLoopLegRequest[] = [];
    const queue: StreamEvent[][] = [[proposal('c1', WEATHER)], answer('done')];
    let issued = 0;
    const executor = new McpToolExecutor({
      conversationId: CONVERSATION,
      runtimeConfig: MCP_RUNTIME_CONFIG_FALLBACK,
      gate: denyingMcpConfirmationGate,
      grants: new McpConversationGrants(),
      tokenProvider: async () => {
        const token = `token-${++issued}`;
        tokens.push(token);
        return token;
      },
      makeClient: (endpoint) => new McpClient({ endpoint, transport: options.server, runtimeConfig: MCP_RUNTIME_CONFIG_FALLBACK }),
      reauthorizationGate: {
        async requestReauthorization(request) {
          asked.push(request);
          options.onAsk?.();
          return options.choices[asked.length - 1] ?? 'skip';
        },
      },
      onStep: (update) => { steps.push(update); },
    });
    const loop = new ToolCallLoop({
      registry: new ToolRegistry(createMcpToolEntries(plan, executor)),
      runLeg: (request) => {
        requests.push({ ...request, messages: [...request.messages] });
        return handle(queue.shift() ?? []);
      },
      signal: options.signal ?? new AbortController().signal,
      limits: mcpLoopLimits(MCP_RUNTIME_CONFIG_FALLBACK),
      prompts: MCP_LOOP_PROMPTS,
      stoppedErrorCode: MCP_LOOP_STOPPED_ERROR_CODE,
    });
    return { result: loop.run([{ role: 'user', content: 'Weather?' }]), asked, tokens, steps, requests };
  }

  it('resumes from this step after signing in again: reconnects with the new token, sends tools/call once more, and the result is fed back as usual', async () => {
    const server = fakeServer((_name, index) => (index === 0 ? { status: 401 } : { text: 'Sunny' }));
    const { result, asked, tokens, steps, requests } = reauthRun({ choices: ['reauthorized'], server });
    await result;
    expect(asked).toEqual([{ conversationId: CONVERSATION, serverId: SERVER_ID, serverName: 'Weather', stepId: steps[0].id }]);
    expect(steps.map((step) => [step.status, step.errorCode, step.awaitingUser])).toEqual([
      ['running', null, false],
      ['needsAuth', 'needs_auth', true],
      ['running', null, false],
      ['done', null, false],
    ]);
    // The token was fetched again and the new connection carries the new token
    expect(tokens).toEqual(['token-1', 'token-2']);
    expect(server.toolCalls()).toHaveLength(2);
    expect(server.calls.at(-1)?.request.credential).toBe('token-2');
    expect(toolResult(requests[1], 'c1')).toEqual({ ok: true, result: 'Sunny' });
  });

  it('skipping the step: no further request, auth_skipped is fed back and the loop continues', async () => {
    const server = fakeServer(() => ({ status: 401 }));
    const { result, steps, requests } = reauthRun({ choices: ['skip'], server });
    expect((await result).text).toBe('done');
    expect(server.toolCalls()).toHaveLength(1);
    expect(steps.at(-1)).toMatchObject({ status: 'needsAuth', errorCode: 'auth_skipped', awaitingUser: false });
    expect(toolResult(requests[1], 'c1').error?.code).toBe('auth_skipped');
  });

  it('server still demands sign-in after signing in again: pauses once more and does not retry in a loop by itself', async () => {
    const server = fakeServer(() => ({ status: 401 }));
    const { result, asked } = reauthRun({ choices: ['reauthorized', 'skip'], server });
    await result;
    expect(asked).toHaveLength(2);
    expect(server.toolCalls()).toHaveLength(2);
  });

  it('user presses stop while waiting for the new sign-in: the turn ends as cancelled and the step is recorded as interrupted', async () => {
    const controller = new AbortController();
    const server = fakeServer(() => ({ status: 401 }));
    const { result, steps } = reauthRun({ choices: ['reauthorized'], server, signal: controller.signal, onAsk: () => controller.abort() });
    await expect(result).rejects.toMatchObject({ name: 'AbortError' });
    expect(steps.at(-1)).toMatchObject({ status: 'interrupted', errorCode: 'cancelled', awaitingUser: false });
    expect(server.toolCalls()).toHaveLength(1);
  });

  it('no expired-authorization gate supplied: no pause, degrades straight to needs_auth', async () => {
    const { result, steps, requests } = run({ plan, server: fakeServer(() => ({ status: 401 })), legs: [[proposal('c1', WEATHER)], answer('x')] });
    await result;
    expect(steps.at(-1)).toMatchObject({ status: 'needsAuth', errorCode: 'needs_auth', awaitingUser: false });
    expect(toolResult(requests[1], 'c1').error?.code).toBe('needs_auth');
  });
});

describe('pre-execution recheck: the current on-device state is verified once more before sending the request', () => {
  const planned = input({ snapshots: [snapshot('get_weather'), snapshot('get_time')] });
  const plan = planMcpTools([planned], MCP_RUNTIME_CONFIG_FALLBACK);

  /** Production executor + production loop; the "current on-device state" comes from `live.current`, which tests change while a turn is running. */
  function liveRun(options: {
    legs: StreamEvent[][];
    server?: FakeServer;
    gate?: McpConfirmationGate;
    reauth?: (request: McpReauthorizationRequest) => McpReauthorizationChoice;
    plan?: McpToolPlan;
    current?: McpBridgeServerInput | null;
  }) {
    const server = options.server ?? fakeServer();
    const live: { current: McpBridgeServerInput | null; asked: Array<[string, string]>; fail: boolean } = {
      current: options.current === undefined ? planned : options.current,
      asked: [],
      fail: false,
    };
    const steps: McpToolStepUpdate[] = [];
    const requests: ToolLoopLegRequest[] = [];
    const tokens: string[] = [];
    const queue = [...options.legs];
    const reauth = options.reauth;
    const executor = new McpToolExecutor({
      conversationId: CONVERSATION,
      runtimeConfig: MCP_RUNTIME_CONFIG_FALLBACK,
      gate: options.gate ?? denyingMcpConfirmationGate,
      grants: new McpConversationGrants(),
      tokenProvider: async () => {
        tokens.push(`token-${tokens.length + 1}`);
        return tokens.at(-1)!;
      },
      makeClient: (endpoint) => new McpClient({ endpoint, transport: server, runtimeConfig: MCP_RUNTIME_CONFIG_FALLBACK }),
      ...(reauth ? { reauthorizationGate: { requestReauthorization: async (request: McpReauthorizationRequest) => reauth(request) } } : {}),
      revalidate: async (serverId, toolName) => {
        live.asked.push([serverId, toolName]);
        if (live.fail) throw new Error('local store unreadable');
        return live.current;
      },
      onStep: (update) => { steps.push(update); },
    });
    const loop = new ToolCallLoop({
      registry: new ToolRegistry(createMcpToolEntries(options.plan ?? plan, executor)),
      runLeg: (request) => {
        requests.push({ ...request, messages: [...request.messages] });
        return handle(queue.shift() ?? []);
      },
      signal: new AbortController().signal,
      limits: mcpLoopLimits(MCP_RUNTIME_CONFIG_FALLBACK),
      prompts: MCP_LOOP_PROMPTS,
      stoppedErrorCode: MCP_LOOP_STOPPED_ERROR_CODE,
    });
    return { result: loop.run([{ role: 'user', content: 'Weather?' }]), server, live, steps, requests, tokens };
  }

  const withTool = (overrides: Partial<McpToolSnapshot>, permissions: Record<string, McpToolPermission> = {}): McpBridgeServerInput =>
    input({ snapshots: [snapshot('get_weather', overrides), snapshot('get_time')], permissions });

  const gone: Array<[string, McpBridgeServerInput | null]> = [
    ['the server was removed, or this conversation turned it off', null],
    ['the tool was removed by the server', input({ snapshots: [snapshot('get_time')] })],
    ['the tool is quarantined (definition changed, awaiting user confirmation)', withTool({ pendingReview: true })],
    ['the tool is oversized', withTool({ oversized: true })],
    ['the content hash differs from the one at assembly time', withTool({ contentHash: 'hash-other' })],
    ['the display title differs from the one at assembly time', withTool({ title: 'Delete everything' })],
    ['the permission was changed to off', withTool({}, { get_weather: 'off' })],
    ['the server URL changed', input({ record: record({ url: 'https://elsewhere.example.com/mcp' }), snapshots: [snapshot('get_weather'), snapshot('get_time')] })],
  ];
  for (const [label, current] of gone) {
    it(`${label}: no request is sent, tool_unavailable is fed back, and the answer finishes normally`, async () => {
      const { result, server, steps, requests, live } = liveRun({ legs: [[proposal('c1', WEATHER)], answer('Done without it.')], current });
      expect((await result).text).toBe('Done without it.');
      expect(server.calls).toEqual([]);
      expect(live.asked).toEqual([[SERVER_ID, 'get_weather']]);
      expect(toolResult(requests[1], 'c1')).toMatchObject({ ok: false, error: { code: 'tool_unavailable' } });
      expect(steps.map((step) => [step.status, step.errorCode])).toEqual([['running', null], ['failed', 'tool_unavailable']]);
    });
  }

  it('on-device state cannot be read: treated as unavailable, no request is sent (fail closed)', async () => {
    const context = liveRun({ legs: [[proposal('c1', WEATHER)], answer('x')] });
    context.live.fail = true;
    await context.result;
    expect(context.server.calls).toEqual([]);
    expect(toolResult(context.requests[1], 'c1').error?.code).toBe('tool_unavailable');
  });

  it('server removed mid-turn: the earlier step runs normally, later calls are not sent and the cached connection is no longer used', async () => {
    const context = liveRun({ legs: [[proposal('c1', WEATHER)], [proposal('c2', TIME)], answer('ok')] });
    const original = context.server.send.bind(context.server);
    context.server.send = async (request) => {
      const response = await original(request);
      // Right after the first tools/call response arrives, the server is removed from this device
      if ((JSON.parse(request.body ?? '{}') as { method?: string }).method === 'tools/call') context.live.current = null;
      return response;
    };
    await context.result;
    expect(context.server.toolCalls()).toEqual([{ name: 'get_weather', arguments: { city: 'Berlin' } }]);
    expect(toolResult(context.requests[1], 'c1')).toEqual({ ok: true, result: 'Sunny, 22°C' });
    expect(toolResult(context.requests[2], 'c2').error?.code).toBe('tool_unavailable');
  });

  it('auto-run at assembly time but changed to ask-every-time before the call → goes through the confirmation gate; a denial sends no tools/call', async () => {
    const gate = scriptedGate(['deny']);
    const context = liveRun({
      legs: [[proposal('c1', WEATHER)], answer('ok')],
      gate,
      current: withTool({}, { get_weather: 'ask' }),
    });
    await context.result;
    expect(plan.tools[0].permission).toBe('auto');
    expect(gate.asked.map((request) => request.toolName)).toEqual(['get_weather']);
    expect(context.server.calls).toEqual([]);
    expect(context.steps.at(-1)).toMatchObject({ status: 'denied', errorCode: 'user_denied', permission: 'ask' });
  });

  it('tool switched to off while waiting for the user: nothing is sent even if the user allows it', async () => {
    const context = liveRun({
      plan: planMcpTools([input({ snapshots: [snapshot('get_weather', { readOnly: false })] })], MCP_RUNTIME_CONFIG_FALLBACK),
      legs: [[proposal('c1', WEATHER)], answer('ok')],
      current: input({ snapshots: [snapshot('get_weather', { readOnly: false })] }),
      gate: {
        async requestConfirmation() {
          context.live.current = input({ snapshots: [snapshot('get_weather', { readOnly: false })], permissions: { get_weather: 'off' } });
          return 'once';
        },
      },
    });
    await context.result;
    expect(context.server.calls).toEqual([]);
    expect(toolResult(context.requests[1], 'c1').error?.code).toBe('tool_unavailable');
  });

  it('no second prompt after the user chose allow-once (the recheck does not turn one confirmation into two)', async () => {
    const gate = scriptedGate(['once']);
    const ask = input({ snapshots: [snapshot('get_weather', { readOnly: false })] });
    const context = liveRun({ plan: planMcpTools([ask], MCP_RUNTIME_CONFIG_FALLBACK), legs: [[proposal('c1', WEATHER)], answer('ok')], current: ask, gate });
    await context.result;
    expect(gate.asked).toHaveLength(1);
    expect(context.server.toolCalls()).toHaveLength(1);
  });

  it('paused on expired authorization → tool definition changes and is quarantined during re-sign-in → resuming sends no tools/call', async () => {
    const server = fakeServer((_name, index) => (index === 0 ? { status: 401 } : { text: 'Sunny' }));
    const context = liveRun({
      server,
      legs: [[proposal('c1', WEATHER)], answer('ok')],
      reauth: () => {
        // The catalog was refreshed after signing in again: this tool's description changed, so it is back in quarantine
        context.live.current = withTool({ pendingReview: true, contentHash: 'hash-after-relogin' });
        return 'reauthorized';
      },
    });
    await context.result;
    expect(server.toolCalls()).toHaveLength(1);
    expect(context.tokens).toEqual(['token-1']);
    expect(context.steps.map((step) => [step.status, step.errorCode, step.awaitingUser])).toEqual([
      ['running', null, false],
      ['needsAuth', 'needs_auth', true],
      ['failed', 'tool_unavailable', false],
    ]);
    expect(toolResult(context.requests[1], 'c1').error?.code).toBe('tool_unavailable');
  });

  it('permission changed to ask-every-time during re-sign-in: the confirmation gate runs before resuming', async () => {
    const gate = scriptedGate(['deny']);
    const server = fakeServer((_name, index) => (index === 0 ? { status: 401 } : { text: 'Sunny' }));
    const context = liveRun({
      server,
      gate,
      legs: [[proposal('c1', WEATHER)], answer('ok')],
      reauth: () => {
        context.live.current = withTool({}, { get_weather: 'ask' });
        return 'reauthorized';
      },
    });
    await context.result;
    expect(gate.asked).toHaveLength(1);
    expect(server.toolCalls()).toHaveLength(1);
    expect(toolResult(context.requests[1], 'c1').error?.code).toBe('user_denied');
  });

  it('server now needs re-authentication: the connection and token cached for this answer are dropped, and the next call fetches a token and connects again', async () => {
    const context = liveRun({ legs: [[proposal('c1', WEATHER)], [proposal('c2', TIME)], answer('ok')] });
    const original = context.server.send.bind(context.server);
    context.server.send = async (request) => {
      const response = await original(request);
      if ((JSON.parse(request.body ?? '{}') as { method?: string }).method === 'tools/call') {
        context.live.current = { ...planned, connectionStatus: 'needsAuth' };
      }
      return response;
    };
    await context.result;
    expect(context.tokens).toEqual(['token-1', 'token-2']);
    expect(context.server.calls.at(-1)?.request.credential).toBe('token-2');
  });

  it('unchanged state: runs normally, with one recheck per call', async () => {
    const context = liveRun({ legs: [[proposal('c1', WEATHER)], [proposal('c2', TIME)], answer('ok')] });
    await context.result;
    expect(context.server.toolCalls()).toHaveLength(2);
    expect(context.live.asked).toEqual([[SERVER_ID, 'get_weather'], [SERVER_ID, 'get_time']]);
    expect(context.tokens).toEqual(['token-1']);
  });
});

describe('execution and failures', () => {
  it('arguments that are not a JSON object or miss a required field: counted as model self-correction, the server is not called', async () => {
    const plan = planMcpTools([input({ snapshots: [snapshot('get_weather', { inputSchema: { type: 'object', properties: { city: { type: 'string' } }, required: ['city'] } })] })], MCP_RUNTIME_CONFIG_FALLBACK);
    const { result, server, requests, steps } = run({
      plan,
      legs: [[proposal('c1', WEATHER, '[1,2]')], [proposal('c2', WEATHER, '{"unit":"c"}')], [proposal('c3', WEATHER, '{"city":"Berlin"}')], answer('ok')],
    });
    await result;
    expect(toolResult(requests[1], 'c1').error?.code).toBe('invalid_arguments');
    expect(toolResult(requests[2], 'c2').error).toEqual({ code: 'missing_required_arguments', message: 'Missing required arguments: city.' });
    expect(server.toolCalls()).toEqual([{ name: 'get_weather', arguments: { city: 'Berlin' } }]);
    expect(steps.map((step) => step.status)).toEqual(['running', 'done']);
    expect(() => validatedMcpArguments('not json', {})).toThrow(ToolCallRejection);
    expect(validatedMcpArguments('', {})).toEqual({});
  });

  it('no circuit breaker on consecutive failures: a server fails 4 times in a row, the answer still finishes, and only closed-set codes are fed back', async () => {
    const server = fakeServer(() => ({ status: 500 }));
    const { result, requests, steps } = run({
      plan: weatherPlan,
      server,
      legs: [[proposal('c1', WEATHER)], [proposal('c2', WEATHER)], [proposal('c3', WEATHER)], [proposal('c4', WEATHER)], answer('Unavailable.')],
    });
    const final = await result;
    expect(final.text).toBe('Unavailable.');
    expect(server.toolCalls()).toHaveLength(4);
    const fed = toolResult(requests[4], 'c4');
    expect(fed).toEqual({ ok: false, error: { code: 'server_error', message: 'The tool call did not succeed. Do not invent its result; continue with what you have.' } });
    expect(steps.filter((step) => step.status === 'failed')).toHaveLength(4);
  });

  it('tool execution error (isError): the step fails, the server text goes into the on-device payload only (cut to 200 characters) and is not fed back to the model', async () => {
    const secret = `Database password is hunter2. ${'x'.repeat(400)}`;
    const server = fakeServer(() => ({ text: secret, isError: true }));
    const { result, requests, steps } = run({ plan: weatherPlan, server, legs: [[proposal('c1', WEATHER)], answer('Failed.')] });
    await result;
    const terminal = steps.at(-1)!;
    expect(terminal).toMatchObject({ status: 'failed', errorCode: 'tool_error' });
    expect(Array.from(terminal.payload!.resultPrefix!)).toHaveLength(200);
    expect(JSON.stringify(requests[1].messages)).not.toContain('hunter2');
    expect(toolResult(requests[1], 'c1').error?.code).toBe('tool_error');
  });

  it('server demands sign-in → needs_auth; cannot connect → unreachable; a failed token fetch is split into transient / sign-in required', async () => {
    const needsAuth = run({ plan: weatherPlan, server: fakeServer(() => ({ status: 401 })), legs: [[proposal('c1', WEATHER)], answer('x')] });
    await needsAuth.result;
    expect(needsAuth.steps.at(-1)).toMatchObject({ status: 'needsAuth', errorCode: 'needs_auth' });

    const offline = run({ plan: weatherPlan, server: fakeServer(() => ({ network: true })), legs: [[proposal('c1', WEATHER)], answer('x')] });
    await offline.result;
    expect(offline.steps.at(-1)).toMatchObject({ status: 'failed', errorCode: 'unreachable' });
    // No automatic retry once tools/call has been sent
    expect(offline.server.toolCalls()).toHaveLength(1);

    const noToken = run({ plan: weatherPlan, token: async () => { throw new Error('storage'); }, legs: [[proposal('c1', WEATHER)], answer('x')] });
    await noToken.result;
    expect(noToken.steps.at(-1)).toMatchObject({ status: 'failed', errorCode: 'unreachable' });
    expect(noToken.server.calls).toEqual([]);
  });

  it('each server is connected only once per answer', async () => {
    const { result, server } = run({ plan: weatherPlan, legs: [[proposal('c1', WEATHER)], [proposal('c2', TIME)], answer('ok')] });
    await result;
    expect(server.calls.map((call) => call.method)).toEqual(['tools/list', 'tools/call', 'tools/call']);
  });

  it('user presses stop during a call: the request is aborted, the turn ends as cancelled and the step is recorded as interrupted', async () => {
    const controller = new AbortController();
    const server = fakeServer(() => ({ hang: true }));
    const { result, steps } = run({ plan: weatherPlan, server, signal: controller.signal, legs: [[proposal('c1', WEATHER)], answer('never')] });
    await new Promise((done) => setTimeout(done, 20));
    controller.abort();
    await expect(result).rejects.toMatchObject({ name: 'AbortError' });
    expect(steps.at(-1)).toMatchObject({ status: 'interrupted', errorCode: 'cancelled' });
  });

  it('at the step limit a tool-less synthesis leg runs and skipped proposals get tool_loop_stopped', async () => {
    const config = { ...MCP_RUNTIME_CONFIG_FALLBACK, maxSteps: 1 };
    const { result, requests, server } = run({ plan: weatherPlan, runtimeConfig: config, legs: [[proposals([['c1', WEATHER], ['c2', TIME]])], answer('Done.')] });
    const final = await result;
    expect(final.stepLimitReached).toBe(true);
    expect(server.toolCalls()).toHaveLength(1);
    expect(toolResult(requests[1], 'c2').error?.code).toBe('tool_loop_stopped');
    expect(requests[1].toolChoice).toBe('none');
    expect(mcpLoopLimits({ ...MCP_RUNTIME_CONFIG_FALLBACK, maxSteps: 8 }).maxSteps).toBe(8);
    expect(mcpLoopLimits(MCP_RUNTIME_CONFIG_FALLBACK).maxConsecutiveToolFailures).toBe(Number.POSITIVE_INFINITY);
  });

  it('the safety prompt is appended after the user system prompt; it stands alone when there is none', () => {
    expect(mcpSystemPrompt('  Be brief.  ')).toBe(`Be brief.\n\n${MCP_SAFETY_PROMPT}`);
    expect(mcpSystemPrompt('')).toBe(MCP_SAFETY_PROMPT);
    expect(mcpSystemPrompt(null)).toBe(MCP_SAFETY_PROMPT);
  });
});

describe('permissions', () => {
  it('an explicitly stored ask overrides the default auto of a read-only declaration', () => {
    const permissions: Record<string, McpToolPermission> = { get_weather: 'ask' };
    const plan = planMcpTools([input({ permissions })], MCP_RUNTIME_CONFIG_FALLBACK);
    expect(plan.tools[0].permission).toBe('ask');
  });
});
