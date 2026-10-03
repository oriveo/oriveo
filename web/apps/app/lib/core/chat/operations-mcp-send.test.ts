// @vitest-environment jsdom
//
// Integration tests for remote MCP wired into the chat send path.
//
// Runs the real sendMessage / sendLibraryMessage -> MCP bridge -> generic loop -> leg runner
// (sendLibraryAgentLeg) -> protocol client, with local state in the real MCP store and IndexedDB
// (fake-indexeddb). Only the two ends are scripted: `/api/chat/stream` (a `fetch` stand-in replaying
// SSE from the shared corpus) and the MCP server (a scripted transport). Every outbound request body
// is passed through the production `validateChatStreamRequest`, proving that end-to-end requests pass
// server-side validation.

import 'fake-indexeddb/auto';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { AIModel, ChatMessage, Conversation, Provider } from '@oriveo/shared';
import {
  MCP_SAFETY_PROMPT,
  McpTransportError,
  type McpHttpRequest,
  type McpServerAddition,
  type McpToolPermission,
  type McpToolSnapshot,
  type McpTransport,
} from '@oriveo/core/mcp/index';

const mocks = vi.hoisted(() => ({
  runStreamPipeline: vi.fn(),
  trackEvent: vi.fn(),
  reportSendCompletion: vi.fn(),
  executeLibraryTool: vi.fn(),
  activeUid: { value: 'uid-mcp-send' },
}));

// Pipeline of the ordinary send path: all that matters here is whether the ordinary path was taken, not
// that it really runs.
vi.mock('./stream-runner', async (importOriginal) => ({
  ...(await importOriginal<typeof import('./stream-runner')>()),
  runStreamPipeline: (...args: unknown[]) => mocks.runStreamPipeline(...args),
}));
vi.mock('../../utils/chat-stream-utils', async (importOriginal) => ({
  ...(await importOriginal<typeof import('../../utils/chat-stream-utils')>()),
  buildChatHistory: vi.fn(async (messages: ChatMessage[]) =>
    messages.filter((message) => message.text).map((message) => ({ role: message.role, content: message.text }))),
  sanitizeOutboundMessages: (messages: unknown[]) => messages,
}));
vi.mock('./prompt-injection', () => ({
  buildPromptInjectionContext: vi.fn(async () => ({ systemContent: 'You are helpful.', memoryInjected: false, retrievalCost: 0 })),
}));
vi.mock('./stream-options', async (importOriginal) => ({
  ...(await importOriginal<typeof import('./stream-options')>()),
  buildStreamOptionsFromIntent: vi.fn(() => ({})),
  buildProviderStreamOptions: vi.fn(() => ({})),
  resolveGenerationProfileForModel: vi.fn(() => undefined),
}));
vi.mock('../metadata/metadata-client', async (importOriginal) => ({
  ...(await importOriginal<typeof import('../metadata/metadata-client')>()),
  resolveGenerationProfileRef: vi.fn(() => undefined),
  getRelayRuntimeConfig: vi.fn(() => undefined),
  getModelTransport: vi.fn(() => 'openai_chat'),
  getMetadataRevision: () => undefined,
  hasCatalogModel: vi.fn(() => true),
  resolveCatalogModel: vi.fn(() => ({ contextLength: 128_000 })),
  isMetadataSnapshotConfirmed: vi.fn(() => true),
  getProviderCatalogStatus: vi.fn(() => 'loaded'),
  getLibraryRuntimeConfig: vi.fn(() => ({
    version: 2,
    toolDescriptions: { library_search: 'Search the library.', library_list: 'List the library.', library_read: 'Read a document.' },
    maxSteps: 6, toolTimeoutMs: 1000, maxEmptyHits: 2, maxSelfCorrections: 2, tokenBudget: 0,
    estimatedTokensPerStep: 2_000, highCostConfirmationUSD: 0.25, weakModelDenylist: [], sensitiveGateEnabled: true,
  })),
}));
vi.mock('./cost-fields', async (importOriginal) => ({
  ...(await importOriginal<typeof import('./cost-fields')>()),
  deriveCostFields: vi.fn(() => ({ cost: 0, costSource: 'localEstimate' })),
}));
vi.mock('./send-completion', () => ({
  reportSendCompletion: (...args: unknown[]) => mocks.reportSendCompletion(...args),
}));
vi.mock('../telemetry', async () => ({
  trackEvent: (...args: unknown[]) => mocks.trackEvent(...args),
  telemetryProviderKind: (kind: string) => kind,
  telemetryModelID: (await vi.importActual<typeof import('../telemetry')>('../telemetry')).telemetryModelID,
}));
vi.mock('../library/api', async (importOriginal) => ({
  ...(await importOriginal<typeof import('../library/api')>()),
  executeLibraryTool: (...args: unknown[]) => mocks.executeLibraryTool(...args),
}));
vi.mock('../../infra/storage/partition', async (importOriginal) => ({
  ...(await importOriginal<typeof import('../../infra/storage/partition')>()),
  getActiveUIDSync: () => mocks.activeUid.value,
}));

import { validateChatStreamRequest } from '../../../app/api/chat/stream/validate';
import { createAppStore } from '../store/app-store';
import {
  enableMcpConfirmationUi,
  mcpConversationGrants,
  resolveMcpConfirmation,
  resolveMcpReauthorization,
  useMcpConfirmationStore,
  useMcpReauthorizationStore,
} from '../mcp/mcp-confirmation';
import { connectionSupportsMcpTools, prepareMcpSend } from '../mcp/mcp-chat';
import {
  createIdbMcpCredentialStorage,
  createIdbMcpServerRepository,
  fetchMcpStepPayload,
  loadMcpLocalState,
  removeMcpServer as removeMcpServerRows,
  setMcpServerEnabled as setMcpServerEnabledRow,
  setMcpToolPermission as setMcpToolPermissionRow,
} from '../mcp/mcp-idb';
import { __setMcpTransportForTests, mcpDraftScope, useMcpStore } from '../mcp/mcp-store';
import { McpCredentialStore } from '@oriveo/core/mcp/index';
import { deleteConversation } from '../conversation-ops';
import { sendMessage } from './operations-send';
import { deleteMessage } from './operations-delete';
import { sendLibraryMessage } from './operations-library-send';

const CORPUS = resolve(__dirname, '../../../../../../shared/test-fixtures/provider-toolcall');
const SERVER_ID = '00000000-0000-4000-8000-0000000000a1';
const WEATHER = 'mcp_weather_get_weather';
const TIME = 'mcp_weather_get_time';

function model(overrides: Partial<AIModel> = {}): AIModel {
  return {
    id: 'gpt-4o', name: 'GPT-4o', capabilities: ['text'], toolCall: true, reasoningModeAvailable: false,
    isAvailable: true, isDefault: true, priceTier: '$', promptPrice: 0, completionPrice: 0, ...overrides,
  };
}

function provider(overrides: Partial<Provider> = {}): Provider {
  return {
    id: 'provider-1', kind: 'openAI', status: { kind: 'connected' }, models: [model()], catalogModels: [model()],
    apiKey: 'sk-test', apiKeyPreview: 'sk-...test', ...overrides,
  };
}

function conversation(id = 'conv-1'): Conversation {
  return {
    id, title: 'Chat', hasCustomTitle: false, providerID: 'provider-1', providerKind: 'openAI', modelID: 'gpt-4o',
    previewText: '', estimatedCost: 0, isDraft: false, messages: [], draftText: '',
    createdAt: '2026-10-03T00:00:00.000Z', updatedAt: '2026-10-03T00:00:00.000Z',
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

// ── Scripted MCP server ──────────────────────────────────────────────────

interface FakeServer extends McpTransport {
  requests: McpHttpRequest[];
  toolCalls(): Array<{ name: string; arguments: unknown }>;
}

function fakeServer(reply: (name: string) => { text?: string; isError?: boolean; status?: number; network?: boolean; hang?: boolean } = () => ({ text: 'Sunny, 22°C' })): FakeServer {
  const requests: McpHttpRequest[] = [];
  const bodies: Array<{ method: string; params: Record<string, unknown> }> = [];
  return {
    requests,
    toolCalls: () => bodies.filter((body) => body.method === 'tools/call').map((body) => ({ name: body.params.name as string, arguments: body.params.arguments })),
    async send(request) {
      requests.push(request);
      const body = JSON.parse(request.body ?? '{}') as { id: number; method: string; params: Record<string, unknown> };
      bodies.push(body);
      const json = (result: unknown) => ({
        status: 200,
        headers: new Headers({ 'content-type': 'application/json' }),
        body: new Response(JSON.stringify({ jsonrpc: '2.0', id: body.id, result })).body,
      });
      if (body.method === 'tools/list') return json({ resultType: 'complete', tools: [] });
      const outcome = reply(body.params.name as string);
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

// ── Scripted /api/chat/stream ────────────────────────────────────────────

/** The shared corpus (openai_chat wire shape), with only the tool name swapped for the one this request sent out. */
function corpusSse(): string {
  return readFileSync(resolve(CORPUS, 'openai_chat.tool_calls.sse'), 'utf8')
    .replaceAll('"get_weather"', `"${WEATHER}"`)
    .replaceAll('"get_time"', `"${TIME}"`);
}

function proposalSse(calls: Array<{ id: string; name: string; args?: string }>): string {
  const toolCalls = calls.map((call, index) => ({ index, id: call.id, type: 'function', function: { name: call.name, arguments: call.args ?? '{"city":"Berlin"}' } }));
  return `data: ${JSON.stringify({ choices: [{ index: 0, delta: { role: 'assistant', tool_calls: toolCalls } }] })}\n\n`
    + `data: ${JSON.stringify({ choices: [{ index: 0, delta: {}, finish_reason: 'tool_calls' }] })}\n\ndata: [DONE]\n\n`;
}

function textSse(text: string): string {
  return `data: ${JSON.stringify({ choices: [{ index: 0, delta: { role: 'assistant', content: text } }] })}\n\n`
    + `data: ${JSON.stringify({ choices: [{ index: 0, delta: {}, finish_reason: 'stop' }], usage: { prompt_tokens: 10, completion_tokens: 5, total_tokens: 15 } })}\n\ndata: [DONE]\n\n`;
}

interface ChatStreamBody {
  providerKind: string;
  messages: Array<{ role: string; content: unknown; tool_call_id?: string; tool_calls?: unknown[] }>;
  tools?: Array<{ function: { name: string; description: string; parameters: unknown } }>;
  toolChoice?: string;
}

/** Takes over `fetch`: records every `/api/chat/stream` request body and replays the scripted legs in order. */
function scriptChatStream(legs: Array<string | { status: number; body: unknown }>): { bodies: ChatStreamBody[] } {
  const bodies: ChatStreamBody[] = [];
  const queue = [...legs];
  vi.stubGlobal('fetch', vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = typeof input === 'string' ? input : input.toString();
    if (!url.endsWith('/api/chat/stream')) throw new Error(`unexpected fetch: ${url}`);
    const body = JSON.parse(String(init?.body)) as ChatStreamBody;
    bodies.push(body);
    const next = queue.shift();
    if (next === undefined) throw new Error('no scripted leg left');
    if (typeof next !== 'string') {
      return new Response(JSON.stringify(next.body), { status: next.status, headers: { 'Content-Type': 'application/json', 'X-Oriveo-Error-Source': 'provider' } });
    }
    return new Response(next, { status: 200, headers: { 'Content-Type': 'text/event-stream' } });
  }));
  return { bodies };
}

// ── Local MCP state ──────────────────────────────────────────────────────

async function seedServer(input: {
  uid?: string;
  serverId?: string;
  name?: string;
  snapshots?: McpToolSnapshot[];
  permissions?: Record<string, McpToolPermission>;
  enabledIn?: string[];
} = {}): Promise<void> {
  const uid = input.uid ?? mocks.activeUid.value;
  const id = input.serverId ?? SERVER_ID;
  const addition: McpServerAddition = {
    id, name: input.name ?? 'Weather', url: `https://${(input.name ?? 'weather').toLowerCase()}.example.com/mcp`, authKind: 'token',
    iconURL: null, createdAt: 1, snapshots: input.snapshots ?? [snapshot('get_weather'), snapshot('get_time')],
    permissions: input.permissions ?? {},
    connectionState: { serverId: id, status: 'connected', lastSuccessAt: 1, negotiatedVersion: '2026-07-28', generation: 'stateless', sessionId: null },
  };
  await createIdbMcpServerRepository(uid).addServer(addition, 20);
  await new McpCredentialStore(createIdbMcpCredentialStorage(uid)).save({ pastedToken: 'SERVER-TOKEN' }, id, uid);
  await useMcpStore.getState().hydrate(uid);
  for (const scope of input.enabledIn ?? []) await useMcpStore.getState().setServerEnabled(scope, id, true);
}

function start(options: {
  conv?: Conversation | undefined;
  newConversation?: boolean;
  provider?: Provider;
  model?: AIModel;
  draftSessionId?: string;
  text?: string;
} = {}) {
  const conv = options.newConversation ? undefined : options.conv ?? conversation();
  const store = createAppStore({ conversations: conv ? [conv] : [] });
  const handle = sendMessage(
    { store, appendChunk: vi.fn(), te: (key) => key },
    {
      text: options.text ?? 'What is the weather?',
      prevMessages: [],
      conversation: conv,
      provider: options.provider ?? provider(),
      model: options.model ?? model(),
      reasoningMode: 'automatic',
      ...(options.draftSessionId ? { generationParameterDraftSessionId: options.draftSessionId } : {}),
    },
  );
  const assistant = (): ChatMessage | undefined => store.getState().conversations
    .find((item) => item.id === handle.convId)?.messages.find((message) => message.id === handle.msgId);
  return { store, handle, assistant };
}

function expectValid(bodies: ChatStreamBody[]): void {
  expect(bodies.length).toBeGreaterThan(0);
  for (const body of bodies) {
    const verdict = validateChatStreamRequest(body);
    expect(verdict.ok, JSON.stringify(verdict)).toBe(true);
  }
}

function toolResult(body: ChatStreamBody, callId: string): { ok: boolean; result?: string; error?: { code: string } } {
  const message = body.messages.find((item) => item.role === 'tool' && item.tool_call_id === callId);
  return JSON.parse(message!.content as string);
}

let uidCounter = 0;
let server: FakeServer;

beforeEach(async () => {
  uidCounter += 1;
  mocks.activeUid.value = `uid-mcp-send-${uidCounter}`;
  mocks.runStreamPipeline.mockReset();
  mocks.runStreamPipeline.mockRejectedValue(new Error('plain path reached'));
  mocks.trackEvent.mockReset();
  mocks.reportSendCompletion.mockReset();
  mocks.executeLibraryTool.mockReset();
  localStorage.clear();
  useMcpStore.getState().reset();
  mcpConversationGrants.revokeAll();
  server = fakeServer();
  __setMcpTransportForTests(server);
});

afterEach(() => {
  vi.unstubAllGlobals();
  __setMcpTransportForTests(null);
});

describe('MCP only: model proposal, tool call, result fed back, reply', () => {
  it('replays the shared corpus: calls the server by the original name, feeds the result into the second leg, attaches step summaries to the message, and every outbound body passes server validation', async () => {
    await seedServer({ enabledIn: ['conv-1'] });
    const chat = scriptChatStream([corpusSse(), textSse('It is sunny in Melbourne.')]);
    const { handle, assistant, store } = start();
    await handle.done;

    expectValid(chat.bodies);
    expect(mocks.runStreamPipeline).not.toHaveBeenCalled();
    // First leg: names from the lookup table, with the server's description and input schema sent as is; the safety prompt is appended to the system prompt
    expect(chat.bodies[0].tools?.map((tool) => tool.function.name)).toEqual([TIME, WEATHER]);
    expect(chat.bodies[0].tools?.[1].function.description).toBe('Description of get_weather');
    expect(chat.bodies[0].toolChoice).toBe('auto');
    expect(chat.bodies[0].messages[0]).toEqual({ role: 'system', content: `You are helpful.\n\n${MCP_SAFETY_PROMPT}` });
    // The server receives the original tool name and the arguments the model gave; the token travels as credential
    expect(server.toolCalls()).toEqual([
      { name: 'get_weather', arguments: { city: 'Melbourne', unit: 'celsius' } },
      { name: 'get_time', arguments: { timezone: 'Australia/Melbourne' } },
    ]);
    expect(server.requests.every((request) => request.credential === 'SERVER-TOKEN')).toBe(true);
    // The second leg carries both tool results
    expect(toolResult(chat.bodies[1], 'call_r2_weather')).toEqual({ ok: true, result: 'Sunny, 22°C' });
    expect(toolResult(chat.bodies[1], 'call_r2_time').ok).toBe(true);

    const message = assistant()!;
    expect(message).toMatchObject({ state: 'delivered', text: 'It is sunny in Melbourne.' });
    expect(message.toolSteps?.map((step) => [step.toolName, step.status, step.serverName, step.argsSummary, step.step])).toEqual([
      ['get_weather', 'done', 'Weather', 'Melbourne · celsius', 1],
      ['get_time', 'done', 'Weather', '', 2],
    ]);
    expect(message.libraryResearchEnabled).toBeUndefined();
    expect(store.getState().streamingConversationIds).not.toContain(handle.convId);
    expect(mocks.reportSendCompletion).toHaveBeenCalledTimes(1);
  });

  it('stores raw arguments and results only in the step payload, never in the message', async () => {
    await seedServer({ enabledIn: ['conv-1'] });
    server = fakeServer(() => ({ text: 'RESULT-BODY-ONLY-ON-THIS-DEVICE' }));
    __setMcpTransportForTests(server);
    scriptChatStream([proposalSse([{ id: 'c1', name: WEATHER, args: '{"city":"ARGUMENT-ONLY-ON-THIS-DEVICE"}' }]), textSse('Done.')]);
    const { handle, assistant } = start();
    await handle.done;

    const message = assistant()!;
    const stepId = message.toolSteps![0].id;
    await vi.waitFor(async () => {
      const payload = await fetchMcpStepPayload(mocks.activeUid.value, message.id, stepId);
      expect(payload?.resultPrefix).toBe('RESULT-BODY-ONLY-ON-THIS-DEVICE');
      expect(JSON.parse(payload!.arguments!)).toEqual({ city: 'ARGUMENT-ONLY-ON-THIS-DEVICE' });
    });
    // The message itself holds only the summary
    const stored = JSON.stringify(message);
    expect(stored).toContain('"toolSteps"');
    expect(stored).not.toContain('RESULT-BODY-ONLY-ON-THIS-DEVICE');
    // The argument summary is built from the values of scalar arguments; it is the only argument information kept on the message
    expect(message.toolSteps![0].argsSummary).toBe('ARGUMENT-ONLY-ON-THIS-DEVICE');
    expect(Object.keys(message.toolSteps![0]).sort()).toEqual(
      ['argsSummary', 'durationMs', 'id', 'scope', 'serverId', 'serverName', 'status', 'step', 'title', 'toolName'],
    );
  });
});

describe('cascading deletion of step payloads (local-only data must not accumulate forever)', () => {
  /** Really runs one reply with tools and waits for the production path to persist the step payload in the local database. */
  async function answered(conv: Conversation = conversation()) {
    scriptChatStream([proposalSse([{ id: 'c1', name: WEATHER, args: '{"city":"Berlin"}' }]), textSse('Done.')]);
    const run = start({ conv });
    await run.handle.done;
    const message = run.assistant()!;
    const stepId = message.toolSteps![0].id;
    await vi.waitFor(async () => expect((await fetchMcpStepPayload(mocks.activeUid.value, message.id, stepId))?.resultPrefix).toBe('Sunny, 22°C'));
    return { ...run, message, stepId, payload: () => fetchMcpStepPayload(mocks.activeUid.value, message.id, stepId) };
  }

  it('deletes the payloads of a deleted message and leaves those of other messages alone', async () => {
    await seedServer({ enabledIn: ['conv-1', 'conv-2'] });
    const first = await answered();
    const other = await answered(conversation('conv-2'));
    deleteMessage(first.store, first.handle.convId, first.message.id);
    await vi.waitFor(async () => expect(await first.payload()).toBeNull());
    expect(await other.payload()).not.toBeNull();
  });

  it('deletes the payloads of a deleted conversation and leaves those of other conversations alone', async () => {
    await seedServer({ enabledIn: ['conv-1', 'conv-2'] });
    const first = await answered();
    const other = await answered(conversation('conv-2'));
    deleteConversation(first.store, first.handle.convId);
    await vi.waitFor(async () => expect(await first.payload()).toBeNull());
    expect(await other.payload()).not.toBeNull();
  });

  it('deletes the payloads of steps a removed server ran while keeping the step summaries on the messages', async () => {
    await seedServer({ enabledIn: ['conv-1'] });
    const first = await answered();
    await useMcpStore.getState().removeServer(SERVER_ID);
    expect(await first.payload()).toBeNull();
    expect(first.assistant()!.toolSteps).toHaveLength(1);
  });
});

describe('when MCP tools are not sent', () => {
  it('takes the ordinary send path with no tool-carrying request when the conversation has no server switched on', async () => {
    await seedServer({ enabledIn: ['another-conversation'] });
    const chat = scriptChatStream([]);
    const { handle } = start();
    await handle.done;
    expect(mocks.runStreamPipeline).toHaveBeenCalledTimes(1);
    expect(chat.bodies).toEqual([]);
    expect(server.requests).toEqual([]);
    expect(prepareMcpSend({ conversationId: 'conv-1', provider: provider(), model: model() }).tools).toEqual([]);
  });

  it('remembers switches per conversation: with conversation A switched on, requests of conversation B carry no mcp_ tool', async () => {
    await seedServer({ enabledIn: ['conv-A'] });
    const chat = scriptChatStream([textSse('Hello from A.')]);
    const a = start({ conv: conversation('conv-A') });
    await a.handle.done;
    expect(chat.bodies[0].tools?.length).toBe(2);

    const b = start({ conv: conversation('conv-B') });
    await b.handle.done;
    expect(mocks.runStreamPipeline).toHaveBeenCalledTimes(1);
    expect(chat.bodies).toHaveLength(1);
  });

  it('sends no tools for models that explicitly lack tool support or for image generation models', async () => {
    await seedServer({ enabledIn: ['conv-1'] });
    expect(connectionSupportsMcpTools(provider(), model({ toolCall: false }))).toBe(false);
    expect(connectionSupportsMcpTools(provider(), model({ capabilities: ['text', 'imageGeneration'], imageGenProfile: 'openai_images' } as Partial<AIModel>))).toBe(false);
    expect(connectionSupportsMcpTools(provider(), model())).toBe(true);
  });

  it('keeps quarantined, turned-off and oversized tools out of the outbound request body', async () => {
    await seedServer({
      enabledIn: ['conv-1'],
      snapshots: [
        snapshot('get_weather'),
        snapshot('quarantined_tool', { pendingReview: true }),
        snapshot('disabled_tool'),
        snapshot('oversized_tool', { oversized: true }),
      ],
      permissions: { disabled_tool: 'off' },
    });
    const chat = scriptChatStream([textSse('Hi.')]);
    const { handle } = start();
    await handle.done;
    expectValid(chat.bodies);
    expect(chat.bodies[0].tools?.map((tool) => tool.function.name)).toEqual([WEATHER]);
    const sent = JSON.stringify(chat.bodies[0]);
    for (const hidden of ['quarantined_tool', 'disabled_tool', 'oversized_tool']) expect(sent).not.toContain(hidden);
  });

  it('sends no tools while the master switch is off or the store is not hydrated yet', async () => {
    await seedServer({ enabledIn: ['conv-1'] });
    expect(prepareMcpSend({ conversationId: 'conv-1', provider: provider(), model: model(), runtimeConfig: { version: 1, enabled: false, maxServers: 20, maxToolsPerRequest: 40, maxToolDefinitionBytes: 16384, maxResultChars: 24000, callTimeoutSeconds: 60, maxSteps: 6 } }).tools).toEqual([]);
    useMcpStore.getState().reset();
    expect(prepareMcpSend({ conversationId: 'conv-1', provider: provider(), model: model() }).tools).toEqual([]);
  });
});

describe('lookup table and confirmation', () => {
  it('does not execute names outside the lookup table and routes them to the existing no-executor notice card and event', async () => {
    await seedServer({ enabledIn: ['conv-1'] });
    const chat = scriptChatStream([proposalSse([{ id: 'c1', name: 'get_weather' }, { id: 'c2', name: 'mcp_other_delete_everything' }])]);
    const { handle, assistant } = start();
    await handle.done;
    expectValid(chat.bodies);
    expect(server.requests).toEqual([]);
    expect(assistant()).toMatchObject({ state: 'delivered' });
    expect(assistant()!.unhandledToolCalls?.map((call) => call.name)).toEqual(['get_weather', 'mcp_other_delete_everything']);
    expect(assistant()!.toolSteps).toBeUndefined();
    const unhandled = mocks.trackEvent.mock.calls.filter(([name]) => name === 'tool_call_unhandled').map(([, props]) => props);
    expect(unhandled).toHaveLength(2);
    // Names starting with `mcp_` embed the server slug and the third-party tool name, so events always use
    // a fixed placeholder for them; built-in tool names are reported as before.
    expect(unhandled.map((props) => props.toolName)).toEqual(['get_weather', 'mcp_tool']);
    expect(JSON.stringify(unhandled)).not.toContain('delete_everything');
    expect(JSON.stringify(unhandled)).not.toContain('mcp_other');
  });

  it('also keeps an mcp_ name invented by the model out of events when the conversation has no MCP on (ordinary send path)', async () => {
    mocks.runStreamPipeline.mockReset();
    mocks.runStreamPipeline.mockResolvedValue({
      text: 'Answer.',
      usage: undefined,
      unhandledToolCalls: [{ id: 'c1', name: 'mcp_acmecorp_export_customers', arguments: '{}' }, { id: 'c2', name: 'web_search', arguments: '{}' }],
    });
    const { handle } = start();
    await handle.done;
    const unhandled = mocks.trackEvent.mock.calls.filter(([name]) => name === 'tool_call_unhandled').map(([, props]) => props);
    expect(unhandled.map((props) => props.toolName)).toEqual(['mcp_tool', 'web_search']);
    expect(JSON.stringify(mocks.trackEvent.mock.calls)).not.toContain('acmecorp');
  });

  it('never executes an ask-every-time tool when there is no confirmation UI, so the server receives no request at all', async () => {
    await seedServer({ enabledIn: ['conv-1'], snapshots: [snapshot('get_weather', { readOnly: false })] });
    const chat = scriptChatStream([proposalSse([{ id: 'c1', name: WEATHER }]), textSse('I could not run it.')]);
    const { handle, assistant } = start();
    await handle.done;
    expectValid(chat.bodies);
    expect(server.requests).toEqual([]);
    expect(toolResult(chat.bodies[1], 'c1').error?.code).toBe('user_denied');
    expect(assistant()!.toolSteps?.map((step) => [step.status, step.errorCode])).toEqual([['denied', 'user_denied']]);
    expect(assistant()!.text).toBe('I could not run it.');
  });

  it('queues the request in the store for the user once the confirmation UI is attached and sends tools/call only after Allow once', async () => {
    await seedServer({ enabledIn: ['conv-1'], snapshots: [snapshot('get_weather', { readOnly: false })] });
    const disable = enableMcpConfirmationUi();
    try {
      scriptChatStream([proposalSse([{ id: 'c1', name: WEATHER, args: '{"city":"Berlin"}' }]), textSse('Done.')]);
      const { handle, assistant } = start();
      await vi.waitFor(() => expect(useMcpConfirmationStore.getState().pending).toHaveLength(1));
      // No request reaches the server while waiting for confirmation
      expect(server.requests).toEqual([]);
      const pending = useMcpConfirmationStore.getState().pending[0];
      expect(pending.request).toMatchObject({
        conversationId: 'conv-1', serverId: SERVER_ID, serverName: 'Weather', serverHost: 'weather.example.com',
        toolName: 'get_weather', toolTitle: 'Title of get_weather', arguments: { city: 'Berlin' },
      });
      resolveMcpConfirmation(pending.id, 'once');
      await handle.done;
      expect(server.toolCalls()).toEqual([{ name: 'get_weather', arguments: { city: 'Berlin' } }]);
      expect(assistant()!.toolSteps?.[0].status).toBe('done');
      expect(useMcpConfirmationStore.getState().pending).toEqual([]);
      // Allow once leaves no grant behind
      expect(mcpConversationGrants.isGranted('conv-1', SERVER_ID, 'get_weather')).toBe(false);
    } finally {
      disable();
    }
  });

  it('keeps allow-for-this-conversation in memory only: the same tool is not asked again in the same conversation, other conversations still ask, and nothing is persisted', async () => {
    await seedServer({ enabledIn: ['conv-1', 'conv-2'], snapshots: [snapshot('get_weather', { readOnly: false })] });
    const disable = enableMcpConfirmationUi();
    try {
      scriptChatStream([
        proposalSse([{ id: 'c1', name: WEATHER }]), textSse('First.'),
        proposalSse([{ id: 'c2', name: WEATHER }]), textSse('Second.'),
        proposalSse([{ id: 'c3', name: WEATHER }]), textSse('Third.'),
      ]);
      const first = start();
      await vi.waitFor(() => expect(useMcpConfirmationStore.getState().pending).toHaveLength(1));
      resolveMcpConfirmation(useMcpConfirmationStore.getState().pending[0].id, 'conversation');
      await first.handle.done;

      // Same conversation again: no prompt, executed directly
      const second = start();
      await second.handle.done;
      expect(useMcpConfirmationStore.getState().pending).toEqual([]);
      expect(server.toolCalls()).toHaveLength(2);

      // Another conversation: still asks
      const other = start({ conv: conversation('conv-2') });
      await vi.waitFor(() => expect(useMcpConfirmationStore.getState().pending).toHaveLength(1));
      resolveMcpConfirmation(useMcpConfirmationStore.getState().pending[0].id, 'deny');
      await other.handle.done;
      expect(server.toolCalls()).toHaveLength(2);

      // The grant is in no persistence layer: the permission in the local database is still the default and localStorage does not have it
      const local = await loadMcpLocalState(mocks.activeUid.value);
      expect(local.permissions[SERVER_ID] ?? {}).toEqual({});
      expect(JSON.stringify({ ...localStorage })).not.toContain('get_weather');
    } finally {
      disable();
    }
  });

  it('revokes allow-for-this-conversation: after the tool permission is changed, its definition changes or the server is removed, the same conversation asks again', async () => {
    await seedServer({ enabledIn: ['conv-1'], snapshots: [snapshot('get_weather', { readOnly: false }), snapshot('get_time', { readOnly: false })] });
    const disable = enableMcpConfirmationUi();
    const TIME = WEATHER.replace('get_weather', 'get_time');
    /** Sends a message that proposes only `name`; returns whether a confirmation was raised (if so, it is answered with allow-for-this-conversation). */
    const sendAndReport = async (name: string): Promise<boolean> => {
      scriptChatStream([proposalSse([{ id: 'c1', name }]), textSse('Ok.')]);
      const { handle } = start();
      let asked = false;
      const answer = vi.waitFor(() => expect(useMcpConfirmationStore.getState().pending).toHaveLength(1), { timeout: 300 }).then(
        () => {
          asked = true;
          resolveMcpConfirmation(useMcpConfirmationStore.getState().pending[0].id, 'conversation');
        },
        () => {},
      );
      await handle.done;
      await answer;
      return asked;
    };
    try {
      expect(await sendAndReport(WEATHER)).toBe(true);
      expect(await sendAndReport(TIME)).toBe(true);
      expect(await sendAndReport(WEATHER)).toBe(false);

      // 1. The user sets this tool to ask every time (it already was ask; selecting it again counts too): only this tool is revoked
      await useMcpStore.getState().setToolPermission(SERVER_ID, 'get_weather', 'ask');
      expect(mcpConversationGrants.isGranted('conv-1', SERVER_ID, 'get_time')).toBe(true);
      expect(await sendAndReport(WEATHER)).toBe(true);
      expect(await sendAndReport(WEATHER)).toBe(false);

      // 2. A tool definition changed and the user confirmed the change (the catalog is replaced as a whole): the changed tool asks again, unchanged ones are unaffected
      const state = useMcpStore.getState();
      await state.saveToolCatalog(
        SERVER_ID,
        state.snapshots[SERVER_ID].map((item) => (item.toolName === 'get_weather' ? { ...item, description: 'Now also deletes things', contentHash: 'hash-changed' } : item)),
        state.permissions[SERVER_ID] ?? {},
      );
      expect(mcpConversationGrants.isGranted('conv-1', SERVER_ID, 'get_time')).toBe(true);
      expect(await sendAndReport(WEATHER)).toBe(true);

      // 3. Server removed: every grant under it is revoked
      await useMcpStore.getState().removeServer(SERVER_ID);
      expect(mcpConversationGrants.isGranted('conv-1', SERVER_ID, 'get_weather')).toBe(false);
      expect(mcpConversationGrants.isGranted('conv-1', SERVER_ID, 'get_time')).toBe(false);
    } finally {
      disable();
    }
  });

  it('ends pending requests as denied when the confirmation UI unmounts', async () => {
    await seedServer({ enabledIn: ['conv-1'], snapshots: [snapshot('get_weather', { readOnly: false })] });
    const disable = enableMcpConfirmationUi();
    scriptChatStream([proposalSse([{ id: 'c1', name: WEATHER }]), textSse('Skipped.')]);
    const { handle, assistant } = start();
    await vi.waitFor(() => expect(useMcpConfirmationStore.getState().pending).toHaveLength(1));
    disable();
    await handle.done;
    expect(server.requests).toEqual([]);
    expect(assistant()!.toolSteps?.[0].status).toBe('denied');
  });
});

describe('per-conversation switches are stored locally only', () => {
  it('moves servers switched on in the draft scope under the real conversation id after the first message of a new conversation, so the next message still carries tools', async () => {
    await seedServer({ enabledIn: [mcpDraftScope('draft-1')] });
    const chat = scriptChatStream([textSse('First answer.'), textSse('Second answer.')]);
    const first = start({ newConversation: true, draftSessionId: 'draft-1' });
    await first.handle.done;
    expect(chat.bodies[0].tools?.map((tool) => tool.function.name)).toEqual([TIME, WEATHER]);

    const convId = first.handle.convId;
    await vi.waitFor(async () => {
      expect((await loadMcpLocalState(mocks.activeUid.value)).switches).toEqual({ [convId]: [SERVER_ID] });
    });
    expect(useMcpStore.getState().conversationServers).toEqual({ [convId]: [SERVER_ID] });
    // The switch is not on the conversation object: nothing synced with the conversation contains it
    const created = first.store.getState().conversations.find((item) => item.id === convId)!;
    expect(JSON.stringify(created)).not.toContain(SERVER_ID);

    expect(prepareMcpSend({ conversationId: convId, provider: provider(), model: model() }).tools).toHaveLength(2);
  });

  it('clears the switches of a deleted conversation (memory and local database) without affecting other conversations', async () => {
    await seedServer({ enabledIn: ['conv-1', 'conv-keep'] });
    const store = createAppStore({ conversations: [conversation('conv-1'), conversation('conv-keep')] });
    deleteConversation(store, 'conv-1');
    expect(useMcpStore.getState().conversationServers).toEqual({ 'conv-keep': [SERVER_ID] });
    await vi.waitFor(async () => {
      expect((await loadMcpLocalState(mocks.activeUid.value)).switches).toEqual({ 'conv-keep': [SERVER_ID] });
    });
  });

  it('defaults everything to off in a new conversation: one with no switch turned on takes the ordinary path', async () => {
    await seedServer({ enabledIn: ['some-other-conversation'] });
    const chat = scriptChatStream([]);
    const { handle } = start({ newConversation: true, draftSessionId: 'fresh-draft' });
    await handle.done;
    expect(chat.bodies).toEqual([]);
    expect(mocks.runStreamPipeline).toHaveBeenCalledTimes(1);
  });
});

describe('failure, cancellation and recovery', () => {
  it('finishes the reply normally after the server fails 4 times in a row instead of turning it into a whole-message error card', async () => {
    await seedServer({ enabledIn: ['conv-1'] });
    server = fakeServer(() => ({ status: 500 }));
    __setMcpTransportForTests(server);
    const chat = scriptChatStream([
      proposalSse([{ id: 'c1', name: WEATHER }]), proposalSse([{ id: 'c2', name: WEATHER }]),
      proposalSse([{ id: 'c3', name: WEATHER }]), proposalSse([{ id: 'c4', name: WEATHER }]),
      textSse('The weather service is unavailable.'),
    ]);
    const { handle, assistant } = start();
    await handle.done;
    expectValid(chat.bodies);
    expect(assistant()).toMatchObject({ state: 'delivered', text: 'The weather service is unavailable.' });
    expect(assistant()!.toolSteps?.map((step) => [step.status, step.errorCode])).toEqual(Array(4).fill(['failed', 'server_error']));
    expect(toolResult(chat.bodies[4], 'c4').error?.code).toBe('server_error');
  });

  it('records the step as needsAuth and sets the connection state to needsAuth when the server requires sign-in again, and the next send no longer carries its tools', async () => {
    await seedServer({ enabledIn: ['conv-1'] });
    server = fakeServer(() => ({ status: 401 }));
    __setMcpTransportForTests(server);
    scriptChatStream([proposalSse([{ id: 'c1', name: WEATHER }]), textSse('Please sign in again.')]);
    const { handle, assistant } = start();
    await handle.done;
    expect(assistant()!.toolSteps?.[0]).toMatchObject({ status: 'needsAuth', errorCode: 'needs_auth' });
    await vi.waitFor(() => expect(useMcpStore.getState().connections[SERVER_ID]?.status).toBe('needsAuth'));
    expect(prepareMcpSend({ conversationId: 'conv-1', provider: provider(), model: model() }).tools).toEqual([]);
  });

  it('aborts the request when stop is pressed during a call, persists the message as interrupted and records unfinished steps as interrupted', async () => {
    await seedServer({ enabledIn: ['conv-1'] });
    server = fakeServer(() => ({ hang: true }));
    __setMcpTransportForTests(server);
    const chat = scriptChatStream([proposalSse([{ id: 'c1', name: WEATHER }]), textSse('never')]);
    const { handle, assistant } = start();
    await vi.waitFor(() => expect(server.toolCalls()).toHaveLength(1));
    handle.abort();
    await handle.done;
    expect(chat.bodies).toHaveLength(1);
    expect(assistant()).toMatchObject({ state: 'interrupted' });
    expect(assistant()!.toolSteps?.[0]).toMatchObject({ status: 'interrupted', errorCode: 'cancelled' });
  });

  it('persists the message as failed when a model leg fails and keeps the steps that already finished', async () => {
    await seedServer({ enabledIn: ['conv-1'] });
    scriptChatStream([proposalSse([{ id: 'c1', name: WEATHER }]), { status: 500, body: { error: 'upstream exploded' } }]);
    const { handle, assistant } = start();
    await handle.done;
    expect(assistant()).toMatchObject({ state: 'failed', errorSource: 'provider' });
    expect(assistant()!.toolSteps?.[0].status).toBe('done');
    expect(mocks.trackEvent.mock.calls.some(([name]) => name === 'chat_message_failed')).toBe(true);
  });

  it('resends once without tools and remembers it when the upstream deterministically rejects tools on the first leg, so the next send goes without them', async () => {
    await seedServer({ enabledIn: ['conv-1'] });
    const rejection = { status: 400, body: { error: { message: 'Unrecognized request argument supplied: tools', type: 'invalid_request_error' } } };
    const chat = scriptChatStream([rejection, textSse('Plain answer.'), textSse('Still plain.')]);
    const first = start();
    await first.handle.done;
    expect(first.assistant()).toMatchObject({ state: 'delivered', text: 'Plain answer.' });
    expect(chat.bodies[0].tools?.length).toBe(2);
    expect(chat.bodies[1].tools).toBeUndefined();
    expect(server.requests).toEqual([]);

    // Remembered: the next send on this connection carries no tools from the first leg on
    const second = start();
    await second.handle.done;
    expect(chat.bodies).toHaveLength(3);
    expect(chat.bodies[2].tools).toBeUndefined();
    expectValid(chat.bodies);
  });

  it('does not resend or remember on a 4xx that is not a tools-unsupported rejection (such as 401)', async () => {
    await seedServer({ enabledIn: ['conv-1'] });
    const chat = scriptChatStream([{ status: 401, body: { error: { message: 'Incorrect API key provided' } } }, textSse('Next.')]);
    const first = start();
    await first.handle.done;
    expect(first.assistant()).toMatchObject({ state: 'failed' });
    expect(chat.bodies).toHaveLength(1);
    const second = start();
    await second.handle.done;
    expect(chat.bodies[1].tools?.length).toBe(2);
  });

  it('treats a retry as a brand-new reply and does not carry over the steps of the previous round', async () => {
    await seedServer({ enabledIn: ['conv-1'] });
    scriptChatStream([textSse('Fresh answer.')]);
    const conv = conversation();
    const store = createAppStore({ conversations: [conv] });
    const stale: ChatMessage = {
      id: '22222222-2222-4222-8222-222222222222', role: 'assistant', text: '', providerID: 'provider-1', providerKind: 'openAI',
      providerName: 'OpenAI', modelID: 'gpt-4o', modelName: 'GPT-4o', estimatedCost: 0, state: 'generating',
      toolSteps: [{ id: '1:old', scope: 'mcp', serverId: SERVER_ID, serverName: 'Weather', toolName: 'get_weather', title: 'x', argsSummary: '', status: 'failed', errorCode: 'server_error', step: 1 }],
    } as ChatMessage;
    const handle = sendMessage({ store, appendChunk: vi.fn(), te: (key) => key }, {
      text: 'Again', prevMessages: [], conversation: conv, provider: provider(), model: model(), reasoningMode: 'automatic',
      assistantMessageOverride: stale,
    });
    await handle.done;
    const message = store.getState().conversations[0].messages.find((item) => item.id === handle.msgId)!;
    expect(message).toMatchObject({ state: 'delivered', text: 'Fresh answer.' });
    expect(message.toolSteps).toBeUndefined();
  });
});

describe('activity line mcp_tool', () => {
  it('is set while a step runs and cleared as soon as body text arrives, with the server name and tool title for display held in the message toolSteps', async () => {
    await seedServer({ enabledIn: ['conv-1'] });
    server = fakeServer(() => ({ hang: true }));
    __setMcpTransportForTests(server);
    scriptChatStream([proposalSse([{ id: 'c1', name: WEATHER }]), textSse('never')]);
    const { store, handle, assistant } = start();
    await vi.waitFor(() => expect(server.toolCalls()).toHaveLength(1));
    expect(store.getState().streamingActivities['conv-1']).toBe('mcp_tool');
    expect(assistant()!.toolSteps?.at(-1)).toMatchObject({ status: 'running', serverName: 'Weather', title: 'Title of get_weather' });
    handle.abort();
    await handle.done;
    expect(store.getState().streamingActivities['conv-1'] ?? null).toBeNull();
  });

  it('stays set while waiting for user confirmation (that is waiting for a person, not silence), with the step already running', async () => {
    await seedServer({ snapshots: [snapshot('get_weather', { readOnly: false })], enabledIn: ['conv-1'] });
    scriptChatStream([proposalSse([{ id: 'c1', name: WEATHER }]), textSse('Sunny.')]);
    const disable = enableMcpConfirmationUi();
    try {
      const { store, handle, assistant } = start();
      await vi.waitFor(() => expect(useMcpConfirmationStore.getState().pending).toHaveLength(1));
      expect(store.getState().streamingActivities['conv-1']).toBe('mcp_tool');
      expect(assistant()!.toolSteps?.[0]).toMatchObject({ status: 'running' });
      expect(server.toolCalls()).toEqual([]);
      resolveMcpConfirmation(useMcpConfirmationStore.getState().pending[0].id, 'once');
      await handle.done;
      expect(assistant()).toMatchObject({ state: 'delivered', text: 'Sunny.' });
      expect(assistant()!.toolSteps?.[0].status).toBe('done');
    } finally {
      disable();
    }
  });
});

describe('authorization expiring mid-run: pause, resume, skip', () => {
  /** The first tools/call returns 401; later ones succeed. */
  function expiringServer(): FakeServer {
    let calls = 0;
    return fakeServer(() => (++calls === 1 ? { status: 401 } : { text: 'Sunny, 22°C' }));
  }

  it('pauses the loop on the step for the user while the chat UI is present, and after reauthorization continues from that step without redoing earlier results', async () => {
    await seedServer({ enabledIn: ['conv-1'] });
    server = expiringServer();
    __setMcpTransportForTests(server);
    const chat = scriptChatStream([proposalSse([{ id: 'c1', name: WEATHER }]), textSse('It is sunny.')]);
    const disable = enableMcpConfirmationUi();
    try {
      const { handle, assistant } = start();
      await vi.waitFor(() => expect(useMcpReauthorizationStore.getState().pending).toHaveLength(1));
      const pending = useMcpReauthorizationStore.getState().pending[0];
      expect(pending.request).toMatchObject({ conversationId: 'conv-1', serverId: SERVER_ID, serverName: 'Weather' });
      expect(assistant()!.toolSteps?.[0]).toMatchObject({ id: pending.request.stepId, status: 'needsAuth', errorCode: 'needs_auth' });
      await vi.waitFor(() => expect(useMcpStore.getState().connections[SERVER_ID]?.status).toBe('needsAuth'));
      // While paused the model leg did not advance and no terminal event was recorded
      expect(chat.bodies).toHaveLength(1);
      expect(mocks.trackEvent.mock.calls.filter(([name]) => name === 'mcp_tool_call')).toEqual([]);

      resolveMcpReauthorization(pending.id, 'reauthorized');
      await handle.done;
      expect(server.toolCalls()).toHaveLength(2);
      expect(assistant()).toMatchObject({ state: 'delivered', text: 'It is sunny.' });
      expect(assistant()!.toolSteps?.map((step) => [step.status, step.errorCode])).toEqual([['done', undefined]]);
      expect(toolResult(chat.bodies[1], 'c1')).toEqual({ ok: true, result: 'Sunny, 22°C' });
      await vi.waitFor(() => expect(useMcpStore.getState().connections[SERVER_ID]?.status).toBe('connected'));
      // The raw arguments were not lost during the pause: after resuming, the payload has both arguments and result
      await vi.waitFor(async () => {
        expect(await fetchMcpStepPayload(mocks.activeUid.value, handle.msgId, pending.request.stepId)).toMatchObject({
          arguments: '{"city":"Berlin"}', resultPrefix: 'Sunny, 22°C',
        });
      });
    } finally {
      disable();
    }
  });

  it('sends no further request on Skip this step, feeds back auth_skipped and lets the model go on answering', async () => {
    await seedServer({ enabledIn: ['conv-1'] });
    server = expiringServer();
    __setMcpTransportForTests(server);
    const chat = scriptChatStream([proposalSse([{ id: 'c1', name: WEATHER }]), textSse('I could not check the weather.')]);
    const disable = enableMcpConfirmationUi();
    try {
      const { handle, assistant } = start();
      await vi.waitFor(() => expect(useMcpReauthorizationStore.getState().pending).toHaveLength(1));
      resolveMcpReauthorization(useMcpReauthorizationStore.getState().pending[0].id, 'skip');
      await handle.done;
      expect(server.toolCalls()).toHaveLength(1);
      expect(toolResult(chat.bodies[1], 'c1').error?.code).toBe('auth_skipped');
      expect(assistant()).toMatchObject({ state: 'delivered', text: 'I could not check the weather.' });
      expect(assistant()!.toolSteps?.[0]).toMatchObject({ status: 'needsAuth', errorCode: 'auth_skipped' });
    } finally {
      disable();
    }
  });

  it('ends the wait when stop is pressed while waiting for reauthorization, persists the message as interrupted and records the step as interrupted', async () => {
    await seedServer({ enabledIn: ['conv-1'] });
    server = expiringServer();
    __setMcpTransportForTests(server);
    scriptChatStream([proposalSse([{ id: 'c1', name: WEATHER }]), textSse('never')]);
    const disable = enableMcpConfirmationUi();
    try {
      const { handle, assistant } = start();
      await vi.waitFor(() => expect(useMcpReauthorizationStore.getState().pending).toHaveLength(1));
      handle.abort();
      await handle.done;
      expect(useMcpReauthorizationStore.getState().pending).toEqual([]);
      expect(assistant()).toMatchObject({ state: 'interrupted' });
      expect(assistant()!.toolSteps?.[0]).toMatchObject({ status: 'interrupted', errorCode: 'cancelled' });
    } finally {
      disable();
    }
  });
});

describe('rechecking local state before execution', () => {
  /** The first tools/call returns 401; later ones succeed. */
  function expiringServer(): FakeServer {
    let calls = 0;
    return fakeServer(() => (++calls === 1 ? { status: 401 } : { text: 'Sunny, 22°C' }));
  }

  /** Sends a message, waits for the confirmation dialog, runs `whilePending` first and then answers Allow once. */
  async function sendThenApprove(legs: string[], whilePending: () => Promise<void>) {
    const chat = scriptChatStream(legs);
    const run = start();
    await vi.waitFor(() => expect(useMcpConfirmationStore.getState().pending).toHaveLength(1));
    await whilePending();
    resolveMcpConfirmation(useMcpConfirmationStore.getState().pending[0].id, 'once');
    await run.handle.done;
    return { chat, ...run };
  }

  it('does not send tools/call on resume and feeds back tool_unavailable when the tool definition changed and was quarantined during the sign-in that followed an authorization-expired pause', async () => {
    await seedServer({ enabledIn: ['conv-1'] });
    server = expiringServer();
    __setMcpTransportForTests(server);
    const chat = scriptChatStream([proposalSse([{ id: 'c1', name: WEATHER }]), textSse('I could not check.')]);
    const disable = enableMcpConfirmationUi();
    try {
      const { handle, assistant } = start();
      await vi.waitFor(() => expect(useMcpReauthorizationStore.getState().pending).toHaveLength(1));
      expect(server.toolCalls()).toHaveLength(1);
      // The catalog is refreshed after signing in again: this tool's description changed, so it goes back to quarantine until the user confirms the change
      const state = useMcpStore.getState();
      await state.saveToolCatalog(
        SERVER_ID,
        state.snapshots[SERVER_ID].map((item) => (item.toolName === 'get_weather'
          ? { ...item, description: 'Now also deletes things', contentHash: 'hash-changed', pendingReview: true }
          : item)),
        state.permissions[SERVER_ID] ?? {},
      );
      resolveMcpReauthorization(useMcpReauthorizationStore.getState().pending[0].id, 'reauthorized');
      await handle.done;

      expect(server.toolCalls()).toHaveLength(1);
      expect(toolResult(chat.bodies[1], 'c1')).toMatchObject({ ok: false, error: { code: 'tool_unavailable' } });
      expect(assistant()).toMatchObject({ state: 'delivered', text: 'I could not check.' });
      expect(assistant()!.toolSteps?.map((step) => [step.status, step.errorCode])).toEqual([['failed', 'tool_unavailable']]);
    } finally {
      disable();
    }
  });

  it('does not send later calls of a tool in the same round once it is turned off mid-round', async () => {
    await seedServer({ enabledIn: ['conv-1'], snapshots: [snapshot('get_weather', { readOnly: false }), snapshot('get_time')] });
    const disable = enableMcpConfirmationUi();
    try {
      const { chat, assistant } = await sendThenApprove(
        [proposalSse([{ id: 'c1', name: WEATHER }, { id: 'c2', name: TIME }]), textSse('Half done.')],
        () => useMcpStore.getState().setToolPermission(SERVER_ID, 'get_time', 'off'),
      );
      expect(server.toolCalls().map((call) => call.name)).toEqual(['get_weather']);
      expect(toolResult(chat.bodies[1], 'c1')).toEqual({ ok: true, result: 'Sunny, 22°C' });
      expect(toolResult(chat.bodies[1], 'c2').error?.code).toBe('tool_unavailable');
      expect(assistant()!.toolSteps?.map((step) => [step.toolName, step.status, step.errorCode])).toEqual([
        ['get_weather', 'done', undefined],
        ['get_time', 'failed', 'tool_unavailable'],
      ]);
    } finally {
      disable();
    }
  });

  it('sends nothing when the server is removed mid-round, even if the user then clicks allow, so the server receives no request at all', async () => {
    await seedServer({ enabledIn: ['conv-1'], snapshots: [snapshot('get_weather', { readOnly: false }), snapshot('get_time')] });
    const disable = enableMcpConfirmationUi();
    try {
      const { chat } = await sendThenApprove(
        [proposalSse([{ id: 'c1', name: WEATHER }, { id: 'c2', name: TIME }]), textSse('Nothing ran.')],
        () => useMcpStore.getState().removeServer(SERVER_ID),
      );
      expect(server.requests).toEqual([]);
      expect(toolResult(chat.bodies[1], 'c1').error?.code).toBe('tool_unavailable');
      expect(toolResult(chat.bodies[1], 'c2').error?.code).toBe('tool_unavailable');
    } finally {
      disable();
    }
  });

  it('does not send later calls once the switch of this conversation is turned off mid-round', async () => {
    await seedServer({ enabledIn: ['conv-1'], snapshots: [snapshot('get_weather', { readOnly: false })] });
    const disable = enableMcpConfirmationUi();
    try {
      const { chat } = await sendThenApprove(
        [proposalSse([{ id: 'c1', name: WEATHER }]), textSse('Nothing ran.')],
        () => useMcpStore.getState().setServerEnabled('conv-1', SERVER_ID, false),
      );
      expect(server.requests).toEqual([]);
      expect(toolResult(chat.bodies[1], 'c1').error?.code).toBe('tool_unavailable');
    } finally {
      disable();
    }
  });

  it('routes a tool through the confirmation dialog instead of executing it directly once it is changed from run automatically to ask every time mid-round', async () => {
    await seedServer({ enabledIn: ['conv-1'], snapshots: [snapshot('get_weather', { readOnly: false }), snapshot('get_time')] });
    const disable = enableMcpConfirmationUi();
    try {
      const chat = scriptChatStream([proposalSse([{ id: 'c1', name: WEATHER }, { id: 'c2', name: TIME }]), textSse('Ok.')]);
      const { handle } = start();
      await vi.waitFor(() => expect(useMcpConfirmationStore.getState().pending).toHaveLength(1));
      await useMcpStore.getState().setToolPermission(SERVER_ID, 'get_time', 'ask');
      resolveMcpConfirmation(useMcpConfirmationStore.getState().pending[0].id, 'once');
      // get_time was run-automatically (read-only) at assembly time; now it has to ask
      await vi.waitFor(() => expect(useMcpConfirmationStore.getState().pending.map((item) => item.request.toolName)).toEqual(['get_time']));
      expect(server.toolCalls().map((call) => call.name)).toEqual(['get_weather']);
      resolveMcpConfirmation(useMcpConfirmationStore.getState().pending[0].id, 'deny');
      await handle.done;
      expect(server.toolCalls().map((call) => call.name)).toEqual(['get_weather']);
      expect(toolResult(chat.bodies[1], 'c2').error?.code).toBe('user_denied');
    } finally {
      disable();
    }
  });

  describe('changed by another tab (only persisted; the in-memory projection of this page is stale)', () => {
    const cases: Array<[string, () => Promise<void>]> = [
      ['server removed', () => removeMcpServerRows(mocks.activeUid.value, SERVER_ID)],
      ['tool turned off', () => setMcpToolPermissionRow(mocks.activeUid.value, SERVER_ID, 'get_weather', 'off')],
      ['conversation switch turned off', () => setMcpServerEnabledRow(mocks.activeUid.value, 'conv-1', SERVER_ID, false)],
    ];
    for (const [label, change] of cases) {
      it(`${label}: the call on this page is still not sent`, async () => {
        await seedServer({ enabledIn: ['conv-1'], snapshots: [snapshot('get_weather', { readOnly: false })] });
        const disable = enableMcpConfirmationUi();
        try {
          const { chat } = await sendThenApprove([proposalSse([{ id: 'c1', name: WEATHER }]), textSse('Nothing ran.')], async () => {
            await change();
            // In this page's memory it is still there, still on and its permission unchanged, so a recheck that only read memory would let it through
            const memory = useMcpStore.getState();
            expect(memory.servers.map((item) => item.id)).toEqual([SERVER_ID]);
            expect(memory.conversationServers['conv-1']).toEqual([SERVER_ID]);
            expect(memory.permissions[SERVER_ID]?.get_weather).not.toBe('off');
          });
          expect(server.requests).toEqual([]);
          expect(toolResult(chat.bodies[1], 'c1').error?.code).toBe('tool_unavailable');
        } finally {
          disable();
        }
      });
    }
  });

  it('does not mistake servers of a new conversation for switched off right after they moved from the draft scope to the real id (not yet persisted)', async () => {
    await seedServer({ enabledIn: [mcpDraftScope('draft-1')] });
    const chat = scriptChatStream([proposalSse([{ id: 'c1', name: WEATHER }]), textSse('It is sunny.')]);
    const { handle } = start({ newConversation: true, draftSessionId: 'draft-1' });
    await handle.done;
    expect(server.toolCalls()).toHaveLength(1);
    expect(toolResult(chat.bodies[1], 'c1')).toEqual({ ok: true, result: 'Sunny, 22°C' });
  });
});

describe('reaching the step limit', () => {
  it('records toolStepLimitReached on the message at the limit (the trailing row of the step block is based on it)', async () => {
    await seedServer({ enabledIn: ['conv-1'] });
    const proposals = Array.from({ length: 6 }, (_, index) => proposalSse([{ id: `c${index + 1}`, name: WEATHER }]));
    scriptChatStream([...proposals, textSse('Here is what I have so far.')]);
    const { handle, assistant } = start();
    await handle.done;
    expect(assistant()).toMatchObject({ state: 'delivered', text: 'Here is what I have so far.', toolStepLimitReached: true });
    expect(assistant()!.toolSteps).toHaveLength(6);
  });

  it('does not set the flag on a reply below the limit', async () => {
    await seedServer({ enabledIn: ['conv-1'] });
    scriptChatStream([proposalSse([{ id: 'c1', name: WEATHER }]), textSse('Sunny.')]);
    const { handle, assistant } = start();
    await handle.done;
    expect(assistant()!.toolStepLimitReached).toBeUndefined();
  });
});

describe('mcp_tool_call event', () => {
  const toolCallEvents = () => mocks.trackEvent.mock.calls.filter(([name]) => name === 'mcp_tool_call').map(([, props]) => props);

  it('records once per finished step with closed-set fields only: no server name, tool name, arguments or result', async () => {
    await seedServer({ enabledIn: ['conv-1'] });
    scriptChatStream([proposalSse([{ id: 'c1', name: WEATHER, args: '{"city":"SECRET-CITY"}' }]), textSse('Sunny.')]);
    const { handle } = start();
    await handle.done;
    const events = toolCallEvents();
    expect(events).toHaveLength(1);
    expect(Object.keys(events[0]).sort()).toEqual(['durationBucket', 'errorCode', 'permission', 'readOnly', 'status']);
    expect(events[0]).toMatchObject({ status: 'done', errorCode: 'none', permission: 'auto', readOnly: true });
    expect(['lt_1s', '1_5s']).toContain(events[0].durationBucket);
    const serialized = JSON.stringify(mocks.trackEvent.mock.calls.filter(([name]) => String(name).startsWith('mcp_')));
    for (const secret of ['SECRET-CITY', 'Sunny', 'Weather', 'get_weather', 'example.com', SERVER_ID]) expect(serialized).not.toContain(secret);
  });

  it('records failed and denied with their own status and error code, never the server error text', async () => {
    await seedServer({ snapshots: [snapshot('get_weather'), snapshot('get_time', { readOnly: false })], enabledIn: ['conv-1'] });
    server = fakeServer(() => ({ text: 'SERVER-SAID-NO: internal detail', isError: true }));
    __setMcpTransportForTests(server);
    scriptChatStream([proposalSse([{ id: 'c1', name: WEATHER }, { id: 'c2', name: TIME }]), textSse('Could not.')]);
    const { handle } = start();
    await handle.done;
    expect(toolCallEvents()).toEqual([
      expect.objectContaining({ status: 'failed', errorCode: 'tool_error', permission: 'auto', readOnly: true }),
      // No confirmation UI: the ask-every-time tool is denied
      { status: 'denied', errorCode: 'user_denied', permission: 'ask', readOnly: false, durationBucket: 'none' },
    ]);
    expect(JSON.stringify(mocks.trackEvent.mock.calls)).not.toContain('SERVER-SAID-NO');
  });
});

describe('library and MCP both on', () => {
  const ACTIVE_NOTION_CONNECTION = { id: 'notion-1', provider: 'notion' as const, displayName: 'Notion', scopes: [], status: 'active' as const };

  function startLibrary() {
    const conv = conversation();
    const store = createAppStore({ conversations: [conv], libraryConnections: [ACTIVE_NOTION_CONNECTION] });
    const handle = sendLibraryMessage(
      { store, appendChunk: vi.fn(), te: (key) => key },
      {
        text: 'Find the roadmap and check the weather', prevMessages: [], conversation: conv, provider: provider(), model: model(),
        reasoningMode: 'automatic', cancelledText: 'Cancelled', errorTitle: 'Failed', errorDetail: 'Try again',
      },
    );
    const assistant = (): ChatMessage | undefined => store.getState().conversations[0].messages.find((message) => message.id === handle.msgId);
    return { store, handle, assistant };
  }

  it('uses one registry and one loop: library tools and MCP tools both execute within a leg and the request body passes validation', async () => {
    await seedServer({ enabledIn: ['conv-1'] });
    mocks.executeLibraryTool.mockResolvedValue({ result: { hits: [{ docId: 'd1', source: 'notion', title: 'Roadmap', snippet: 'Q4' }] } });
    const chat = scriptChatStream([
      proposalSse([{ id: 'c1', name: 'library_search', args: '{"query":"roadmap"}' }, { id: 'c2', name: WEATHER }]),
      textSse('Roadmap found and it is sunny.'),
    ]);
    const { handle, assistant } = startLibrary();
    await handle.done;

    expectValid(chat.bodies);
    expect(chat.bodies[0].tools?.map((tool) => tool.function.name)).toEqual(['library_search', 'library_list', 'library_read', TIME, WEATHER]);
    const system = String(chat.bodies[0].messages[0].content);
    expect(system).toContain('Use the connected Library tools');
    expect(system).toContain(MCP_SAFETY_PROMPT);
    expect(mocks.executeLibraryTool).toHaveBeenCalledTimes(1);
    expect(server.toolCalls()).toEqual([{ name: 'get_weather', arguments: { city: 'Berlin' } }]);
    expect(toolResult(chat.bodies[1], 'c2')).toEqual({ ok: true, result: 'Sunny, 22°C' });

    const message = assistant()!;
    expect(message).toMatchObject({ state: 'delivered', text: 'Roadmap found and it is sunny.', libraryResearchEnabled: true });
    expect(message.researchSteps?.map((step) => step.tool)).toEqual(['library_search']);
    expect(message.toolSteps?.map((step) => [step.toolName, step.status])).toEqual([['get_weather', 'done']]);
  });

  it('does not trip the breaker on consecutive MCP failures when both are on, leaving the library-only breaker unaffected', async () => {
    await seedServer({ enabledIn: ['conv-1'] });
    server = fakeServer(() => ({ status: 500 }));
    __setMcpTransportForTests(server);
    scriptChatStream([
      proposalSse([{ id: 'c1', name: WEATHER }]), proposalSse([{ id: 'c2', name: WEATHER }]),
      proposalSse([{ id: 'c3', name: WEATHER }]), proposalSse([{ id: 'c4', name: WEATHER }]),
      textSse('Weather is unavailable.'),
    ]);
    const { handle, assistant } = startLibrary();
    await handle.done;
    expect(assistant()).toMatchObject({ state: 'delivered', text: 'Weather is unavailable.' });
    expect(assistant()!.toolSteps).toHaveLength(4);
  });

  it('sends only the three library tools when the library is on but the conversation has no MCP switched on', async () => {
    await seedServer({ enabledIn: ['another-conversation'] });
    const chat = scriptChatStream([textSse('No tools needed.')]);
    const { handle } = startLibrary();
    await handle.done;
    expectValid(chat.bodies);
    expect(chat.bodies[0].tools?.map((tool) => tool.function.name)).toEqual(['library_search', 'library_list', 'library_read']);
    expect(JSON.stringify(chat.bodies[0])).not.toContain('mcp_');
  });
});
