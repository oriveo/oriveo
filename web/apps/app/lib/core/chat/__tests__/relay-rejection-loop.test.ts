/**
  * Send side of the Relay upstream rejection loop (fixtures negative-cache.v1.json / capability-test.v1.json).
 *
  * The send goes through the production chain: attachment filter `withoutUnreceivableImages` -> `buildOutboundChatHistory` -> `sendWithRelayRejectionLoop`
  * -> `sendWithNativeFileFallback` -> production `sendStream` (Relay orchestration layer); only `fetch` is replaced with a fake relay.
 */
import 'fake-indexeddb/auto';
import { existsSync, readFileSync } from 'node:fs';
import path from 'node:path';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { AIModel, Attachment, ChatMessage, Provider, RelayModelTransport } from '@oriveo/shared';
import { effectiveTransport } from '@oriveo/core/providers/relay-effective';
import { relayFirstSendTransport } from '../../providers/relay-first-send-transport';
import type { StreamEvent } from '../../providers/types';
import { createAppStore } from '../../store/app-store';
import { sendStream } from '../../providers/service';
import { sendWithNativeFileFallback } from '../../attachments/native-file-fallback';
import { buildOutboundChatHistory } from '../outbound-history';
import { buildProviderStreamOptions, buildStreamOptionsFromIntent } from '../stream-options';
import { resolveAttachmentCapabilities, withoutUnreceivableImages } from '../attachment-policy';
import { resolveModelCapabilityEvidence } from '../capability-evidence';
import {
  RELAY_NEGATIVE_CACHE_STORAGE_KEY,
  isRelayNegativeCached,
  recordRelayNegativeCache,
  type RelayNegativeCacheKind,
} from '../relay-negative-cache';
import {
  decideRelayProtocolFallback,
  isRelayRejectionEvent,
  isRelayRejectionResponse,
  recordToolCallFallback,
  shouldRecordRelayImageRejection,
  relayImageSupportUnknown,
  relayFirstSendMessagesBlockedByFiles,
  sendWithRelayRejectionLoop,
  toolCallRememberedUnsupported,
} from '../relay-rejection-loop';
import {
  recordToolCallSupportFalse,
  toolCallSupportIsRememberedFalse,
  type ToolCallRecoveryIdentity,
} from '../capability-recovery-runtime';
import { createRelayManualModel } from '../../provider-model-ops';
import { isRelayRouteRejection, rememberRelayCatalogEndpointTypes } from '../../providers/relay-probe-candidates';
import { relayCapabilityTestTransport, runRelayCapabilityTest } from '../../relay-capability-test-ops';
import { redetectRelayModels } from '../../relay-model-probe-ops';
import {
  beginCapabilityEvidenceIdentityIfAbsent,
  resetCapabilityEvidenceIdentitiesForTesting,
} from '../../providers/capability-evidence-identity';
import { getActiveUIDSync } from '../../../infra/storage/partition';
import { relayModelAdvancedBoard } from '../../../../app/providers/[providerId]/relay-model-advanced-board';

/** The cached by-model family table (the first-send protocol reads only it); models not registered go through the production lookup as usual. */
const families = vi.hoisted(() => new Map<string, string>());

vi.mock('../../metadata/metadata-client', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../../metadata/metadata-client')>();
  return {
    ...actual,
    cachedModelFamilyByModel: (modelID: string) => families.get(modelID) ?? actual.cachedModelFamilyByModel(modelID),
    lookupModelFamilyByModel: async (modelID: string) => (
      families.has(modelID) ? families.get(modelID) : actual.lookupModelFamilyByModel(modelID)
    ),
  };
});

/* ── Fixtures ─────────────────────────────────────────────── */

type ShortTransport = 'chat' | 'responses' | 'messages' | 'gemini';

function loadFixture<T>(name: string): T {
  let dir = process.cwd();
  for (let depth = 0; depth < 8; depth += 1) {
    const candidate = path.join(dir, 'shared', 'test-fixtures', 'relay', name);
    if (existsSync(candidate)) return JSON.parse(readFileSync(candidate, 'utf8')) as T;
    dir = path.dirname(dir);
  }
  throw new Error(`${name} not found`);
}

const negative = loadFixture<{
  transports: Record<ShortTransport, RelayModelTransport>;
  imageRecordCases: Array<{
    caseId: string;
    override: { value: boolean; source: 'user' | 'tested' } | null;
    engineDeclarationImage: boolean | null;
    modelDeclaresImage: boolean;
    rejected: boolean;
    outputStarted: boolean;
    protocolSwitched: boolean;
    expectRecord: boolean;
  }>;
  protocolFallbackRules: { statuses: number[]; phraseStatuses: number[]; phrases: string[]; htmlSuccessIsRouteRejection: boolean };
  protocolFallbackCases: Array<{
    caseId: string;
    current: ShortTransport;
    source: 'reachable' | 'observed' | 'user' | null;
    candidates: ShortTransport[];
    status: number;
    /** An old case without body counts as an empty body; one without contentType counts as application/json. */
    body?: string;
    contentType?: string;
    outputStarted: boolean;
    alreadySwitched: boolean;
    expectNext: ShortTransport | null;
  }>;
}>('negative-cache.v1.json');

const capability = loadFixture<{
  classifyCases: Array<{ caseId: string; status: number; contentType?: string | null; body: string; expect: string }>;
}>('capability-test.v1.json');

const full = (transport: ShortTransport) => negative.transports[transport];

/* ── Fake relay ───────────────────────────────────────────── */

interface Sent { url: string; body: string }
const sent: Sent[] = [];
let responders: Array<() => Response> = [];

function upstreamOf(input: RequestInfo | URL, init?: RequestInit): string {
  return new Headers(init?.headers).get('X-Relay-Upstream-URL') ?? String(input instanceof Request ? input.url : input);
}

function reject(status: number): () => Response {
  return () => new Response(JSON.stringify({ error: { message: 'upstream said no' } }), {
    status, headers: { 'Content-Type': 'application/json' },
  });
}

function sse(frames: unknown[], done = true): () => Response {
  const body = frames.map((frame) => `data: ${JSON.stringify(frame)}\n\n`).join('') + (done ? 'data: [DONE]\n\n' : '');
  return () => new Response(body, { status: 200, headers: { 'Content-Type': 'text/event-stream' } });
}

const chatOk = (text = 'ANSWER') => sse([{ choices: [{ index: 0, delta: { content: text } }] }]);

beforeEach(() => {
  sent.length = 0;
  responders = [];
  localStorage.clear();
  resetCapabilityEvidenceIdentitiesForTesting();
  vi.stubGlobal('fetch', vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
    sent.push({ url: upstreamOf(input, init), body: typeof init?.body === 'string' ? init.body : '' });
    const next = responders.shift();
    if (!next) return new Response('not found', { status: 404 });
    return next();
  }));
});

afterEach(() => {
  vi.unstubAllGlobals();
  families.clear();
  localStorage.clear();
  resetCapabilityEvidenceIdentitiesForTesting();
});

/* ── Connection / model / send ───────────────────────────────── */

function relayProvider(models: AIModel[], id = 'relay-loop'): Provider {
  return {
    id,
    kind: 'relay',
    status: { kind: 'connected' },
    models,
    catalogModels: models,
    apiKey: 'sk-test',
    apiKeyPreview: 'sk-...test',
    baseURLText: 'https://relay.example.com/v1',
    relayKind: 'openai_compatible',
    relayRequested: { transport: 'openai_chat_completions', authMode: 'bearer' },
  } as Provider;
}

function model(id: string, extra: Partial<AIModel> = {}): AIModel {
  return { ...createRelayManualModel(id, true), ...extra };
}

const IMAGE_B64 = 'iVBORw0KGgoORIVEOIMAGE';

function userMessage(attachments?: Attachment[]): ChatMessage {
  return {
    id: 'u1', role: 'user', text: 'Look at this', providerKind: 'relay', providerName: 'Relay', modelName: 'm',
    estimatedCost: 0, state: 'delivered', createdAt: '2026-10-11T00:00:00Z',
    ...(attachments ? { attachments } : {}),
  } as ChatMessage;
}

const imageAttachment = { id: 'img-1', kind: 'image', mimeType: 'image/png', base64Data: IMAGE_B64 } as Attachment;

function streamOptionsFor(provider: Provider, relayModel: AIModel) {
  return buildProviderStreamOptions(provider, buildStreamOptionsFromIntent(relayModel, 'automatic', false), relayModel);
}

async function drain(stream: ReadableStream<StreamEvent>): Promise<StreamEvent[]> {
  const events: StreamEvent[] = [];
  const reader = stream.getReader();
  while (true) {
    const { done, value } = await reader.read();
    if (done) return events;
    events.push(value);
  }
}

async function sendRelay(
  store: ReturnType<typeof createAppStore>,
  provider: Provider,
  relayModel: AIModel,
  message: ChatMessage,
) {
  const streamOptions = streamOptionsFor(provider, relayModel);
  const messages = withoutUnreceivableImages([message], provider, relayModel, streamOptions);
  const history = await buildOutboundChatHistory({}, { messages, provider, model: relayModel, streamOptions });
  // Same decision as the send / continue send paths: computed from the original attachments before entering the loop (attachment criteria).
  const messagesBlockedByFiles = await relayFirstSendMessagesBlockedByFiles({ provider, model: relayModel, messages, streamOptions });
  const handle = sendWithRelayRejectionLoop({
    store,
    provider,
    model: relayModel,
    history,
    streamOptions,
    messagesBlockedByFiles,
    send: (outbound, options) => sendWithNativeFileFallback(outbound, (h) => sendStream(
      provider.kind, provider.apiKey, relayModel.id, h, provider.baseURLText, options,
    )),
  });
  const events = await drain(handle.stream);
  return { handle, events };
}

const errorsOf = (events: StreamEvent[]) =>
  events.filter((event): event is Extract<StreamEvent, { type: 'error' }> => event.type === 'error');
const textOf = (events: StreamEvent[]) => events.map((event) => (event.type === 'delta' ? event.content : '')).join('');

function storedEntryCount(): number {
  const raw = localStorage.getItem(RELAY_NEGATIVE_CACHE_STORAGE_KEY);
  return raw ? (JSON.parse(raw) as { entries: unknown[] }).entries.length : 0;
}

function negCached(provider: Provider, relayModel: AIModel, kind: RelayNegativeCacheKind): boolean {
  return isRelayNegativeCached({
    connectionId: provider.id, modelId: relayModel.id, transport: effectiveTransport(provider, relayModel), kind,
  });
}

function setup(models: AIModel[], relayRequested?: Provider['relayRequested']) {
  const store = createAppStore();
  const provider = relayRequested ? { ...relayProvider(models), relayRequested } : relayProvider(models);
  store.getState().addProvider(provider);
  beginCapabilityEvidenceIdentityIfAbsent(getActiveUIDSync(), provider.id);
  return { store, provider };
}

/* ── RL2-NEGCACHE-01 signal and tool share a key ───────────────────── */

describe('RL2-NEGCACHE-01 the rejection signal counts only a rejected verdict of the capability test decision function (capability-test classifyCases)', () => {
  it.each(capability.classifyCases)('RL2-NEGCACHE-01 $caseId', (item) => {
    expect(isRelayRejectionResponse(item)).toBe(item.expect === 'rejected');
  });

  it('RL2-NEGCACHE-01 error events: only an upstream 4xx rejection counts; local / network sources and in-stream error frames do not', () => {
    expect(isRelayRejectionEvent({ type: 'error', error: 'x', status: 400, source: 'provider' })).toBe(true);
    expect(isRelayRejectionEvent({ type: 'error', error: 'x', status: 415, source: 'provider' })).toBe(true);
    expect(isRelayRejectionEvent({ type: 'error', error: 'x', status: 500, source: 'provider' })).toBe(false);
    expect(isRelayRejectionEvent({ type: 'error', error: 'x', status: 429, source: 'provider' })).toBe(false);
    expect(isRelayRejectionEvent({ type: 'error', error: 'x', status: 400, source: 'oriveo' })).toBe(false);
    expect(isRelayRejectionEvent({ type: 'error', error: 'x', source: 'network' })).toBe(false);
    expect(isRelayRejectionEvent({ type: 'error', error: 'x', status: 400, streamErrorFrame: true })).toBe(false);
  });
});

describe('RL2-NEGCACHE-01 tools share the key: the production tool rejection path writes to the same store', () => {
  const identity = (provider: Provider, relayModel: AIModel): ToolCallRecoveryIdentity => ({
    accountId: getActiveUIDSync(),
    connectionId: provider.id,
    authMode: 'bearer',
    canonicalModelId: relayModel.id,
    finalTransport: 'openai_chat_completions',
  });
  const toolRejection = (status: number) => ({
    status, structuredError: { error: { message: 'tools is not supported by this model' } },
  });
  const toolSupport = (provider: Provider, relayModel: AIModel) => resolveModelCapabilityEvidence({
    key: 'tool_call', provider, model: relayModel, streamOptions: streamOptionsFor(provider, relayModel),
  }).support;

  it('RL2-NEGCACHE-01 Relay resend without tools succeeds + 400 -> toolCall entry (same key as the truth adapter), the old tool memory is not written', () => {
    const relayModel = model('tool-model');
    const { provider } = setup([relayModel]);
    recordToolCallFallback(provider, relayModel, identity(provider, relayModel), toolRejection(400), effectiveTransport(provider, relayModel));
    expect(negCached(provider, relayModel, 'toolCall')).toBe(true);
    expect(toolSupport(provider, relayModel)).toBe('unsupported');
    expect(toolCallRememberedUnsupported(provider, relayModel, identity(provider, relayModel))).toBe(true);
    expect(toolCallSupportIsRememberedFalse(identity(provider, relayModel))).toBe(false);
  });

  it.each([500, 503, 429, 401])('RL2-NEGCACHE-01 Relay %i is not written', (status) => {
    const relayModel = model('tool-model');
    const { provider } = setup([relayModel]);
    recordToolCallFallback(provider, relayModel, identity(provider, relayModel), toolRejection(status), effectiveTransport(provider, relayModel));
    expect(storedEntryCount()).toBe(0);
    expect(toolCallSupportIsRememberedFalse(identity(provider, relayModel))).toBe(false);
  });

  it('RL2-NEGCACHE-01 Relay does not read false from the old tool memory', () => {
    const relayModel = model('tool-model');
    const { provider } = setup([relayModel]);
    recordToolCallSupportFalse(identity(provider, relayModel));
    expect(toolCallRememberedUnsupported(provider, relayModel, identity(provider, relayModel))).toBe(false);
  });

  it('RL2-NEGCACHE-01 non-Relay form (manually entered model, eligible) still writes and reads the old tool memory and does not enter the new store', () => {
    const official = { id: 'official-1', kind: 'openAI', status: { kind: 'connected' }, models: [], catalogModels: [], apiKey: '', apiKeyPreview: '' } as unknown as Provider;
    const officialModel = { ...model('gpt-x'), isManual: true };
    const officialIdentity: ToolCallRecoveryIdentity = {
      accountId: getActiveUIDSync(), connectionId: official.id, authMode: 'apiKey', canonicalModelId: 'gpt-x', finalTransport: 'openai_chat',
    };
    recordToolCallFallback(official, officialModel, officialIdentity, toolRejection(400), undefined);
    expect(storedEntryCount()).toBe(0);
    expect(toolCallRememberedUnsupported(official, officialModel, officialIdentity)).toBe(true);
  });
});

/* ── RL2-NEGCACHE-03 image send rejected ─────────────────────────── */

describe('RL2-NEGCACHE-03 Relay vision unknown: the image is sent anyway, 400 -> image entry, entry hidden, hint card', () => {
  it('RL2-NEGCACHE-03 when vision is unknown the production request body carries the image', async () => {
    const relayModel = model('vision-unknown');
    const { store, provider } = setup([relayModel]);
    expect(resolveModelCapabilityEvidence({
      key: 'vision_input', provider, model: relayModel, streamOptions: streamOptionsFor(provider, relayModel),
    }).support).toBe('unknown');
    responders = [chatOk()];
    const { events, handle } = await sendRelay(store, provider, relayModel, userMessage([imageAttachment]));
    expect(sent).toHaveLength(1);
    expect(sent[0]!.body).toContain(IMAGE_B64);
    expect(textOf(events)).toBe('ANSWER');
    expect(handle.getRelayImageRejected?.()).toBe(false);
    expect(storedEntryCount()).toBe(0);
  });

  it('RL2-NEGCACHE-03 send image -> 400 -> image entry, vision entry hidden, next send strips the image, failure marks the hint card', async () => {
    const relayModel = model('vision-unknown');
    const { store, provider } = setup([relayModel]);
    responders = [reject(400)];
    const { events, handle } = await sendRelay(store, provider, relayModel, userMessage([imageAttachment]));
    expect(sent).toHaveLength(1);
    expect(errorsOf(events)).toEqual([expect.objectContaining({ status: 400 })]);
    expect(negCached(provider, relayModel, 'image')).toBe(true);
    expect(handle.getRelayImageRejected?.()).toBe(true);
    expect(resolveAttachmentCapabilities(provider, relayModel, { image: true, nativeFile: false, textFileInline: true })
      .supportsImage).toBe(false);
    // No automatic resend and no text fallback
    sent.length = 0;
    responders = [chatOk()];
    await sendRelay(store, provider, relayModel, userMessage([imageAttachment]));
    expect(sent[0]!.body).not.toContain(IMAGE_B64);
  });

  it.each([500, 429, 401])('RL2-NEGCACHE-03 send image -> %i is not written', async (status) => {
    const relayModel = model('vision-unknown');
    const { store, provider } = setup([relayModel]);
    responders = [reject(status)];
    const { handle } = await sendRelay(store, provider, relayModel, userMessage([imageAttachment]));
    expect(storedEntryCount()).toBe(0);
    expect(handle.getRelayImageRejected?.()).toBe(false);
  });

  it('RL2-NEGCACHE-03 when vision is already overridden to supported, a rejection does not record image', async () => {
    const relayModel = model('vision-tested', { relayCapabilityOverrides: { image: { value: true, source: 'tested' } } });
    const { store, provider } = setup([relayModel]);
    responders = [reject(400)];
    const { handle } = await sendRelay(store, provider, relayModel, userMessage([imageAttachment]));
    expect(sent[0]!.body).toContain(IMAGE_B64);
    expect(storedEntryCount()).toBe(0);
    expect(handle.getRelayImageRejected?.()).toBe(false);
  });

  it('RL2-NEGCACHE-03 a request without an image that gets 400 does not record image', async () => {
    const relayModel = model('vision-unknown');
    const { store, provider } = setup([relayModel]);
    responders = [reject(400)];
    await sendRelay(store, provider, relayModel, userMessage());
    expect(storedEntryCount()).toBe(0);
  });
});

/* ── RL2-NEGCACHE-02 error frame after output ──────────────────── */

describe('RL2-NEGCACHE-02 error frame after output has started', () => {
  it('RL2-NEGCACHE-02 keeps the already output body, reports the error, does not resend, no new store entry', async () => {
    const relayModel = model('vision-unknown');
    const { store, provider } = setup([relayModel]);
    responders = [sse([
      { choices: [{ index: 0, delta: { content: 'partial ' } }] },
      { error: { message: 'upstream exploded', type: 'invalid_request_error', code: 400 } },
    ], false)];
    const { events, handle } = await sendRelay(store, provider, relayModel, userMessage([imageAttachment]));
    expect(sent).toHaveLength(1);
    expect(textOf(events)).toBe('partial ');
    expect(errorsOf(events)).toHaveLength(1);
    expect(storedEntryCount()).toBe(0);
    expect(handle.getRelayImageRejected?.()).toBe(false);
  });
});

/* ── RL2-NEGCACHE-04 protocol-level fallback ───────────────────────── */

describe('RL2-NEGCACHE-04 protocol-level fallback (fixture protocolFallbackCases)', () => {
  it.each(negative.protocolFallbackCases)('RL2-NEGCACHE-04 $caseId', (item) => {
    expect(decideRelayProtocolFallback({
      current: full(item.current),
      source: item.source,
      candidates: item.candidates.map(full),
      status: item.status,
      body: item.body,
      contentType: item.contentType,
      outputStarted: item.outputStarted,
      alreadySwitched: item.alreadySwitched,
    })).toBe(item.expectNext ? full(item.expectNext) : null);
  });

  it('RL2-NEGCACHE-04 the five fallback cases are in the execution list', () => {
    expect(negative.protocolFallbackCases.map((item) => item.caseId)).toEqual(expect.arrayContaining([
      'status_405_tries_next_candidate',
      'status_403_with_route_phrase_tries_next_candidate',
      'status_403_without_route_phrase_does_not_switch',
      'status_401_does_not_switch',
      'status_429_does_not_switch',
      'html_page_with_200_tries_next_candidate',
    ]));
  });

  it('RL2-NEGCACHE-04 the route-level rejection decision matches fixture protocolFallbackRules (probe and fallback share this one)', () => {
    const rules = negative.protocolFallbackRules;
    expect(rules).toMatchObject({ statuses: [404, 405, 415], phraseStatuses: [403] });
    for (const status of rules.statuses) expect(isRelayRouteRejection({ status }), String(status)).toBe(true);
    for (const status of rules.phraseStatuses) {
      for (const phrase of rules.phrases) {
        expect(isRelayRouteRejection({ status, body: `X ${phrase.toUpperCase()} Y` }), phrase).toBe(true);
        // A phrase counts only on the registered status code.
        expect(isRelayRouteRejection({ status: 400, body: phrase })).toBe(false);
      }
      expect(isRelayRouteRejection({ status, body: 'forbidden' })).toBe(false);
      expect(isRelayRouteRejection({ status })).toBe(false);
    }
    for (const status of [400, 401, 402, 422, 429, 500, 502, 503]) {
      expect(isRelayRouteRejection({ status, body: rules.phrases[0] }), String(status)).toBe(false);
    }
    expect(isRelayRouteRejection({ status: undefined })).toBe(false);
    // A 2xx that is a web page counts as a route-level rejection; a normal 2xx (JSON / SSE / empty body) does not.
    expect(rules.htmlSuccessIsRouteRejection).toBe(true);
    expect(isRelayRouteRejection({ status: 200, contentType: 'text/html; charset=utf-8' })).toBe(true);
    expect(isRelayRouteRejection({ status: 200, body: '<!DOCTYPE html><html></html>' })).toBe(true);
    expect(isRelayRouteRejection({ status: 200, body: '{"id":"ok"}' })).toBe(false);
    expect(isRelayRouteRejection({ status: 200, contentType: 'text/event-stream', body: 'data: {}' })).toBe(false);
    expect(isRelayRouteRejection({ status: 200 })).toBe(false);
  });

  it('RL2-NEGCACHE-04 production send receives a 200 web page (before output) -> switches to candidate Chat and succeeds; with no other candidate it reports a web-page error', async () => {
    const relayModel = model('claude-html', { relayTransport: 'anthropic_messages', relayTransportSource: 'reachable' });
    const htmlPage = () => new Response('<!doctype html><html><body><div id="root"></div></body></html>', {
      status: 200, headers: { 'Content-Type': 'text/html; charset=utf-8' },
    });
    const switched = setup([relayModel], { transport: 'auto', authMode: 'auto' });
    rememberRelayCatalogEndpointTypes(switched.provider.id, { [relayModel.id]: ['anthropic', 'openai'] });
    responders = [htmlPage, chatOk('VIA-CHAT')];
    const first = await sendRelay(switched.store, switched.provider, relayModel, userMessage());
    expect(sent.map((item) => item.url)).toEqual([
      expect.stringMatching(/\/messages$/),
      expect.stringMatching(/\/chat\/completions$/),
    ]);
    expect(textOf(first.events)).toBe('VIA-CHAT');
    expect(errorsOf(first.events)).toEqual([]);
    expect(switched.store.getState().providers[0]!.models[0]).toMatchObject({
      relayTransport: 'openai_chat_completions', relayTransportSource: 'observed',
    });

    sent.length = 0;
    const pinned = model('claude-html', { relayTransport: 'anthropic_messages', relayTransportSource: 'user' });
    const kept = setup([pinned], { transport: 'auto', authMode: 'auto' });
    responders = [htmlPage];
    const second = await sendRelay(kept.store, kept.provider, pinned, userMessage());
    expect(sent).toHaveLength(1);
    expect(errorsOf(second.events)).toEqual([expect.objectContaining({ status: 200, relayHTMLPage: true })]);
    expect(storedEntryCount()).toBe(0);
  });

  const AUTO_CONNECTION: Provider['relayRequested'] = { transport: 'auto', authMode: 'auto' };
  const rejectWith = (status: number, message: string) => () => new Response(
    JSON.stringify({ error: { message } }),
    { status, headers: { 'Content-Type': 'application/json' } },
  );

  it('RL2-NEGCACHE-04 production send 403 with a registered phrase -> switches to candidate Chat and succeeds; 403 without the phrase does not switch', async () => {
    const relayModel = model('claude-fallback', { relayTransport: 'anthropic_messages', relayTransportSource: 'reachable' });
    const phrase = negative.protocolFallbackRules.phrases[0]!;

    const switched = setup([relayModel], AUTO_CONNECTION);
    rememberRelayCatalogEndpointTypes(switched.provider.id, { [relayModel.id]: ['anthropic', 'openai'] });
    responders = [rejectWith(403, `This group ${phrase}`), chatOk('VIA-CHAT')];
    const first = await sendRelay(switched.store, switched.provider, relayModel, userMessage());
    expect(sent.map((item) => item.url)).toEqual([
      expect.stringMatching(/\/messages$/),
      expect.stringMatching(/\/chat\/completions$/),
    ]);
    expect(textOf(first.events)).toBe('VIA-CHAT');
    expect(switched.store.getState().providers[0]!.models[0]).toMatchObject({
      relayTransport: 'openai_chat_completions', relayTransportSource: 'observed',
    });

    sent.length = 0;
    const kept = setup([relayModel], AUTO_CONNECTION);
    responders = [rejectWith(403, 'forbidden')];
    const second = await sendRelay(kept.store, kept.provider, relayModel, userMessage());
    expect(sent).toHaveLength(1);
    expect(errorsOf(second.events)).toEqual([expect.objectContaining({ status: 403 })]);
    expect(kept.store.getState().providers[0]!.models[0]!.relayTransport).toBe('anthropic_messages');
  });

  it('RL2-NEGCACHE-04 production send 405 -> switches candidate; 401 / 429 do not switch', async () => {
    const relayModel = responsesModel('reachable');
    for (const [status, expectSends] of [[405, 2], [401, 1], [429, 1]] as const) {
      sent.length = 0;
      const { store, provider } = setup([relayModel], AUTO_CONNECTION);
      rememberRelayCatalogEndpointTypes(provider.id, { [relayModel.id]: ['openai-response', 'openai'] });
      responders = [reject(status), chatOk('SWITCHED')];
      await sendRelay(store, provider, relayModel, userMessage());
      expect(sent, String(status)).toHaveLength(expectSends);
    }
  });

  it('RL2-NEGCACHE-04 user-selected connection protocol: a model following the connection gets 404 without switching protocol, and the catalog endpoint types are not consulted', async () => {
    const relayModel = model('gpt-follow');
    const { store, provider } = setup([relayModel]);
    expect(provider.relayRequested?.transport).toBe('openai_chat_completions');
    rememberRelayCatalogEndpointTypes(provider.id, { [relayModel.id]: ['openai', 'openai-response'] });
    responders = [reject(404), chatOk('NEVER')];
    const { events } = await sendRelay(store, provider, relayModel, userMessage());
    expect(sent.map((item) => item.url)).toEqual([expect.stringMatching(/\/chat\/completions$/)]);
    expect(errorsOf(events)).toEqual([expect.objectContaining({ status: 404 })]);
    expect(store.getState().providers[0]!.models[0]!.relayTransport).toBeUndefined();

    // Contrast: the same model on an auto-detected connection still switches to the next candidate as before.
    sent.length = 0;
    const auto = setup([relayModel], AUTO_CONNECTION);
    rememberRelayCatalogEndpointTypes(auto.provider.id, { [relayModel.id]: ['openai', 'openai-response'] });
    responders = [reject(404), reject(404)];
    await sendRelay(auto.store, auto.provider, relayModel, userMessage());
    expect(sent.map((item) => item.url)).toEqual([
      expect.stringMatching(/\/chat\/completions$/),
      expect.stringMatching(/\/responses$/),
    ]);
  });

  function responsesModel(source: AIModel['relayTransportSource']) {
    return model('gpt-fallback', { relayTransport: 'openai_responses', relayTransportSource: source });
  }

  it('RL2-NEGCACHE-04 production send 404 -> switches to candidate Chat and succeeds -> model relayTransport=Chat, source=observed', async () => {
    const relayModel = responsesModel('reachable');
    const { store, provider } = setup([relayModel]);
    rememberRelayCatalogEndpointTypes(provider.id, { [relayModel.id]: ['openai-response', 'openai'] });
    responders = [reject(404), chatOk('SWITCHED')];
    const { events } = await sendRelay(store, provider, relayModel, userMessage());
    expect(sent.map((item) => item.url)).toEqual([
      expect.stringMatching(/\/responses$/),
      expect.stringMatching(/\/chat\/completions$/),
    ]);
    expect(textOf(events)).toBe('SWITCHED');
    expect(errorsOf(events)).toEqual([]);
    const after = store.getState().providers[0]!.models[0]!;
    expect(after.relayTransport).toBe('openai_chat_completions');
    expect(after.relayTransportSource).toBe('observed');
    expect(storedEntryCount()).toBe(0);
  });

  it('RL2-NEGCACHE-04 user source does not switch protocol', async () => {
    const relayModel = responsesModel('user');
    const { store, provider } = setup([relayModel]);
    rememberRelayCatalogEndpointTypes(provider.id, { [relayModel.id]: ['openai-response', 'openai'] });
    responders = [reject(404)];
    const { events } = await sendRelay(store, provider, relayModel, userMessage());
    expect(sent).toHaveLength(1);
    expect(errorsOf(events)).toEqual([expect.objectContaining({ status: 404 })]);
    expect(store.getState().providers[0]!.models[0]!.relayTransport).toBe('openai_responses');
    expect(store.getState().providers[0]!.models[0]!.relayTransportSource).toBe('user');
  });

  it('RL2-NEGCACHE-04 switches only once: after switching it still fails, reports the second error, does not switch again, writes no value and records no negative cache', async () => {
    const relayModel = responsesModel('reachable');
    const { store, provider } = setup([relayModel]);
    rememberRelayCatalogEndpointTypes(provider.id, { [relayModel.id]: ['openai-response', 'openai'] });
    responders = [reject(404), reject(415)];
    const { events } = await sendRelay(store, provider, relayModel, userMessage([imageAttachment]));
    expect(sent).toHaveLength(2);
    expect(errorsOf(events)).toEqual([expect.objectContaining({ status: 415 })]);
    const after = store.getState().providers[0]!.models[0]!;
    expect(after.relayTransport).toBe('openai_responses');
    expect(after.relayTransportSource).toBe('reachable');
    expect(storedEntryCount()).toBe(0);
  });
});

/* ── Clearing keys ─────────────────────────────────────── */

/**
  * The fake relay's capability test response: carries evidence. A tool request answers with a get_current_time call,
  * the rest (text / vision) answer with the visible body red; the stream format follows the protocol.
 */
function capTestEvidenceBody(protocol: 'messages' | 'chat', requestBody: unknown): string {
  const wantsTool = String(requestBody ?? '').includes('get_current_time');
  if (protocol === 'messages') {
    const start = 'event: message_start\ndata: {"type":"message_start","message":{"id":"m1","type":"message","role":"assistant","content":[]}}\n\n';
    const stop = 'event: message_stop\ndata: {"type":"message_stop"}\n\n';
    if (wantsTool) {
      return start
        + 'event: content_block_start\ndata: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"tu1","name":"get_current_time","input":{}}}\n\n'
        + 'event: content_block_delta\ndata: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{}"}}\n\n'
        + 'event: content_block_stop\ndata: {"type":"content_block_stop","index":0}\n\n'
        + 'event: message_delta\ndata: {"type":"message_delta","delta":{"stop_reason":"tool_use"}}\n\n'
        + stop;
    }
    return start
      + 'event: content_block_delta\ndata: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Red"}}\n\n'
      + stop;
  }
  if (wantsTool) {
    return 'data: {"id":"c1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"role":"assistant","tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"get_current_time","arguments":"{}"}}]}}]}\n\n'
      + 'data: {"id":"c1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}\n\ndata: [DONE]\n\n';
  }
  return 'data: {"id":"c1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"role":"assistant","content":"Red"}}]}\n\n'
    + 'data: {"id":"c1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}\n\ndata: [DONE]\n\n';
}

describe('RL2-NEGCACHE-01 where keys are cleared', () => {
  it('RL2-NEGCACHE-01 a capability test write-back clears image and toolCall of the current protocol of the model, file is kept', async () => {
    const relayModel = model('cap-test');
    const { store, provider } = setup([relayModel]);
    const key = { connectionId: provider.id, modelId: relayModel.id, transport: effectiveTransport(provider, relayModel) };
    for (const kind of ['image', 'toolCall', 'file'] as const) recordRelayNegativeCache({ ...key, kind });
    // Vision / tools are written only when the response carries evidence: the fake relay answers a red body or a get_current_time call per request.
    const result = await runRelayCapabilityTest(store, provider.id, relayModel.id, {
      send: async (request) => ({
        status: 200, contentType: 'text/event-stream', body: capTestEvidenceBody('chat', request.body),
      }),
    });
    expect(result?.outcome).toBe('completed');
    expect(negCached(provider, relayModel, 'image')).toBe(false);
    expect(negCached(provider, relayModel, 'toolCall')).toBe(false);
    expect(negCached(provider, relayModel, 'file')).toBe(true);
  });

  it('RL2-NEGCACHE-01 re-detect clears the whole connection, other connections are kept', async () => {
    const relayModel = model('redetect');
    const { store, provider } = setup([relayModel]);
    recordRelayNegativeCache({ connectionId: provider.id, modelId: 'a', transport: 'openai_chat_completions', kind: 'image' });
    recordRelayNegativeCache({ connectionId: 'other', modelId: 'a', transport: 'openai_chat_completions', kind: 'image' });
    await redetectRelayModels(store, provider, { lookupFamily: async () => undefined, ping: async () => false } as never);
    expect(isRelayNegativeCached({ connectionId: provider.id, modelId: 'a', transport: 'openai_chat_completions', kind: 'image' })).toBe(false);
    expect(isRelayNegativeCached({ connectionId: 'other', modelId: 'a', transport: 'openai_chat_completions', kind: 'image' })).toBe(true);
  });
});

/* ── auto connections take the key by effectiveTransport (unified across all three clients) ──────── */

describe('RL2-NEGCACHE-03 an auto / unconfigured connection does not have incomplete identity: the key is taken by effectiveTransport (auto -> Chat)', () => {
  it.each([
    ['auto', { transport: 'auto', authMode: 'bearer' }],
    ['no protocol config', { authMode: 'bearer' }],
  ] as const)('RL2-NEGCACHE-03 %s connection, model without protocol, vision unknown -> entry visible; after recording the Chat-key image it is hidden', (_label, requested) => {
    const relayModel = model('auto-vision');
    const provider = { ...relayProvider([relayModel]), relayRequested: { ...requested } } as Provider;
    beginCapabilityEvidenceIdentityIfAbsent(getActiveUIDSync(), provider.id);
    const support = { image: true, nativeFile: false, textFileInline: true };
    expect(effectiveTransport(provider, relayModel)).toBe('openai_chat_completions');
    expect(resolveAttachmentCapabilities(provider, relayModel, support).supportsImage).toBe(true);
    recordRelayNegativeCache({
      connectionId: provider.id, modelId: relayModel.id, transport: 'openai_chat_completions', kind: 'image',
    });
    expect(resolveAttachmentCapabilities(provider, relayModel, support).supportsImage).toBe(false);
  });
});

/* ── Resending after a protocol switch does not send the original protocol's native file block to the new protocol ───────────── */

describe('RL2-NEGCACHE-04 switching to a protocol that does not accept native files: use the text-fallback version, and do not switch if there is none', () => {
  const PDF = 'application/pdf';
  const RAW_PDF = 'JVBERi0xLjQKb3JpdmVvUkVMQVk=';
  const pdfModel = () => model('gpt-file', {
    relayTransport: 'openai_responses', relayTransportSource: 'reachable',
    nativeFileMimes: [PDF], pdfNativeDefault: true,
  });
  const textPdf = { id: 'f1', kind: 'file', fileName: 'report.pdf', mimeType: PDF,
    originalBase64Data: RAW_PDF, base64Data: 'EXTRACTED-BODY-TEXT', extractedTotalLines: 1 } as Attachment;
  const scannedPdf = { id: 'f2', kind: 'file', fileName: 'scan.pdf', mimeType: PDF,
    originalBase64Data: RAW_PDF, base64Data: '', extractionErrorCode: 'scanned_pdf' } as Attachment;

  it('RL2-NEGCACHE-04 Responses with input_file -> 404 (text fallback on the same protocol still 404) -> switches to Chat sending injected text, without a file block', async () => {
    const relayModel = pdfModel();
    const { store, provider } = setup([relayModel]);
    rememberRelayCatalogEndpointTypes(provider.id, { [relayModel.id]: ['openai-response', 'openai'] });
    responders = [reject(404), reject(404), chatOk('VIA-CHAT')];
    const { events } = await sendRelay(store, provider, relayModel, userMessage([textPdf]));
    expect(sent.map((item) => item.url)).toEqual([
      expect.stringMatching(/\/responses$/),
      expect.stringMatching(/\/responses$/),
      expect.stringMatching(/\/chat\/completions$/),
    ]);
    expect(sent[0]!.body).toContain(RAW_PDF);
    expect(sent[2]!.body).toContain('EXTRACTED-BODY-TEXT');
    expect(sent[2]!.body).not.toContain(RAW_PDF);
    expect(sent[2]!.body).not.toContain('application/pdf;base64');
    expect(textOf(events)).toBe('VIA-CHAT');
    expect(store.getState().providers[0]!.models[0]!.relayTransport).toBe('openai_chat_completions');
  });

  it('RL2-NEGCACHE-04 only scanned documents (no text-fallback version) -> does not switch protocol, reports the original error', async () => {
    const relayModel = pdfModel();
    const { store, provider } = setup([relayModel]);
    rememberRelayCatalogEndpointTypes(provider.id, { [relayModel.id]: ['openai-response', 'openai'] });
    responders = [reject(404)];
    const { events } = await sendRelay(store, provider, relayModel, userMessage([scannedPdf]));
    expect(sent).toHaveLength(1);
    expect(sent[0]!.body).toContain(RAW_PDF);
    expect(errorsOf(events)).toEqual([expect.objectContaining({ status: 404 })]);
    expect(store.getState().providers[0]!.models[0]!.relayTransport).toBe('openai_responses');
  });
});

/* ── Image is recorded only when there is no positive evidence of any grade (fixture imageRecordCases) ──── */

describe('RL2-NEGCACHE-03 criteria for recording image (fixture imageRecordCases)', () => {
  const fixtureModel = (item: (typeof negative.imageRecordCases)[number]): AIModel => model('img-record', {
    ...(item.modelDeclaresImage ? { capabilities: ['text', 'image'] } : {}),
    ...(item.engineDeclarationImage !== null ? { engineDeclaration: { image: item.engineDeclarationImage } } : {}),
    ...(item.override ? { relayCapabilityOverrides: { image: item.override } } : {}),
  });

  // An engine declaration counts only on a local engine connection: fixture cases with a declaration land on a connection with an engineProfile.
  const fixtureProvider = (item: (typeof negative.imageRecordCases)[number]) => (item.engineDeclarationImage !== null
    ? { relayRequested: { transport: 'openai_chat_completions', authMode: 'none', engineProfile: 'ollama' } as Provider['relayRequested'] }
    : { relayRequested: relayProvider([]).relayRequested });

  it.each(negative.imageRecordCases)('RL2-NEGCACHE-03 $caseId', (item) => {
    expect(shouldRecordRelayImageRejection({
      provider: fixtureProvider(item),
      model: fixtureModel(item),
      rejected: item.rejected,
      outputStarted: item.outputStarted,
      protocolSwitched: item.protocolSwitched,
    })).toBe(item.expectRecord);
  });

  it.each(negative.imageRecordCases.filter((item) => !item.outputStarted && !item.protocolSwitched))(
    'RL2-NEGCACHE-03 production send path $caseId',
    async (item) => {
      const relayModel = fixtureModel(item);
      const { store, provider } = setup([relayModel], fixtureProvider(item).relayRequested);
      responders = [reject(item.rejected ? 400 : 500)];
      const { handle } = await sendRelay(store, provider, relayModel, userMessage([imageAttachment]));
      expect(sent[0]!.body).toContain(IMAGE_B64);
      expect(negCached(provider, relayModel, 'image')).toBe(item.expectRecord);
      expect(handle.getRelayImageRejected?.()).toBe(item.expectRecord);
    },
  );
});

/* ── Only an override of true beats the image negative cache ─────────────── */

describe('RL2-NEGCACHE-03 only an override of true beats the image negative cache', () => {
  const support = { image: true, nativeFile: false, textFileInline: true };

  it('RL2-NEGCACHE-03 evidence is supported but not from an override (model capabilities contain image): an unexpired negative cache still hides it', () => {
    const relayModel = model('img-inherited', { capabilities: ['text', 'image'] });
    const { provider } = setup([relayModel]);
    expect(resolveModelCapabilityEvidence({
      key: 'vision_input', provider, model: relayModel, streamOptions: streamOptionsFor(provider, relayModel),
    }).support).toBe('supported');
    expect(resolveAttachmentCapabilities(provider, relayModel, support).supportsImage).toBe(true);
    recordRelayNegativeCache({
      connectionId: provider.id, modelId: relayModel.id, transport: effectiveTransport(provider, relayModel), kind: 'image',
    });
    expect(resolveAttachmentCapabilities(provider, relayModel, support).supportsImage).toBe(false);
  });

  it('RL2-NEGCACHE-03 an engine declaration of true is likewise hidden by an unexpired negative cache; an override of true beats it', () => {
    const declared = model('img-engine', { engineDeclaration: { image: true } });
    const { provider } = setup([declared]);
    recordRelayNegativeCache({
      connectionId: provider.id, modelId: declared.id, transport: effectiveTransport(provider, declared), kind: 'image',
    });
    expect(resolveAttachmentCapabilities(provider, declared, support).supportsImage).toBe(false);
    const overridden: AIModel = { ...declared, relayCapabilityOverrides: { image: { value: true, source: 'tested' } } };
    expect(resolveAttachmentCapabilities(provider, overridden, support).supportsImage).toBe(true);
  });
});

describe('an engine declaration counts as positive vision evidence only on a local engine connection', () => {
  it('a leftover engineDeclaration.image on a remote Relay does not block "unknown"; on a local engine connection it blocks', () => {
    const declared = model('decl', { engineDeclaration: { image: true } });
    expect(relayImageSupportUnknown(relayProvider([declared]), declared)).toBe(true);
    const local = { relayRequested: { transport: 'openai_chat_completions', authMode: 'none', engineProfile: 'ollama' } as Provider['relayRequested'] };
    expect(relayImageSupportUnknown(local, declared)).toBe(false);
  });
});

/* ── RL2-FIRSTSEND first send of an unverified model ──────────────── */

describe('RL2-FIRSTSEND first send of an unverified model goes through the first-send protocol pure function (production send path + fake relay)', () => {
  const AUTO = { transport: 'auto', authMode: 'bearer' } as Provider['relayRequested'];

  function messagesOk(text = 'ANSWER'): () => Response {
    const frames = [
      { type: 'message_start', message: { id: 'm', model: 'claude', usage: { input_tokens: 1, output_tokens: 0 } } },
      { type: 'content_block_start', index: 0, content_block: { type: 'text', text: '' } },
      { type: 'content_block_delta', index: 0, delta: { type: 'text_delta', text } },
      { type: 'content_block_stop', index: 0 },
      { type: 'message_delta', delta: { stop_reason: 'end_turn' }, usage: { output_tokens: 1 } },
      { type: 'message_stop' },
    ];
    return () => new Response(
      frames.map((frame) => `event: ${frame.type}\ndata: ${JSON.stringify(frame)}\n\n`).join(''),
      { status: 200, headers: { 'Content-Type': 'text/event-stream' } },
    );
  }

  const keyOf = (provider: Provider, relayModel: AIModel, transport: RelayModelTransport, kind: RelayNegativeCacheKind) => (
    isRelayNegativeCached({ connectionId: provider.id, modelId: relayModel.id, transport, kind })
  );

  it('RL2-FIRSTSEND-01 Claude family (auto): 1 request hits .../messages, body.max_tokens > 0; success writes Messages, observed', async () => {
    const relayModel = model('claude-sonnet-first');
    families.set(relayModel.id, 'anthropic');
    const { store, provider } = setup([relayModel], AUTO);
    responders = [messagesOk('HELLO')];
    const { events } = await sendRelay(store, provider, relayModel, userMessage());
    expect(sent).toHaveLength(1);
    expect(sent[0]!.url).toMatch(/\/messages$/);
    expect((JSON.parse(sent[0]!.body) as { max_tokens?: number }).max_tokens).toBeGreaterThan(0);
    expect(textOf(events)).toBe('HELLO');
    expect(errorsOf(events)).toEqual([]);
    const after = store.getState().providers[0]!.models[0]!;
    expect(after.relayTransport).toBe('anthropic_messages');
    expect(after.relayTransportSource).toBe('observed');
  });

  it('RL2-FIRSTSEND-02 /messages returns 404 -> switches to the next candidate /chat/completions and succeeds (2 requests total), records observed Chat; 400 does not fall back', async () => {
    const relayModel = model('claude-fallback-first');
    families.set(relayModel.id, 'anthropic');
    const { store, provider } = setup([relayModel], AUTO);
    responders = [reject(404), chatOk('SWITCHED')];
    const { events } = await sendRelay(store, provider, relayModel, userMessage());
    expect(sent.map((item) => item.url)).toEqual([
      expect.stringMatching(/\/messages$/),
      expect.stringMatching(/\/chat\/completions$/),
    ]);
    expect(textOf(events)).toBe('SWITCHED');
    const after = store.getState().providers[0]!.models[0]!;
    expect(after.relayTransport).toBe('openai_chat_completions');
    expect(after.relayTransportSource).toBe('observed');

    const second = model('claude-400-first');
    families.set(second.id, 'anthropic');
    const other = setup([second], AUTO);
    sent.length = 0;
    responders = [reject(400)];
    const result = await sendRelay(other.store, other.provider, second, userMessage());
    expect(sent).toHaveLength(1);
    expect(sent[0]!.url).toMatch(/\/messages$/);
    expect(errorsOf(result.events)).toEqual([expect.objectContaining({ status: 400 })]);
    expect(other.store.getState().providers[0]!.models[0]!.relayTransport).toBeUndefined();
  });

  it('RL2-FIRSTSEND-03 unknown family -> /chat/completions, success does not write the protocol', async () => {
    const relayModel = model('mystery-first');
    const { store, provider } = setup([relayModel], AUTO);
    responders = [chatOk()];
    await sendRelay(store, provider, relayModel, userMessage());
    expect(sent).toHaveLength(1);
    expect(sent[0]!.url).toMatch(/\/chat\/completions$/);
    expect(store.getState().providers[0]!.models[0]!.relayTransport).toBeUndefined();
  });

  it('RL2-FIRSTSEND-04 OpenAI family -> 1 /chat/completions, does not write the protocol', async () => {
    const relayModel = model('gpt-first');
    families.set(relayModel.id, 'openai');
    const { store, provider } = setup([relayModel], AUTO);
    responders = [chatOk()];
    await sendRelay(store, provider, relayModel, userMessage());
    expect(sent).toHaveLength(1);
    expect(sent[0]!.url).toMatch(/\/chat\/completions$/);
    expect(store.getState().providers[0]!.models[0]!.relayTransport).toBeUndefined();
  });

  it('RL2-FIRSTSEND-05b unverified Claude family with a file without extracted text, Messages cannot send files natively -> first send still goes through Chat; if it can send natively, Messages', async () => {
    const scanned = { id: 'scan-1', kind: 'file', fileName: 'scan.pdf', mimeType: 'application/pdf',
      originalBase64Data: 'JVBERi0xLjQKRmlyc3RTZW5kU2Nhbg==', base64Data: '', extractionErrorCode: 'scanned_pdf' } as Attachment;
    const blocked = model('claude-scan-first', { relayCapabilityOverrides: { file: { value: false, source: 'user' } } });
    families.set(blocked.id, 'anthropic');
    const first = setup([blocked], AUTO);
    responders = [chatOk('VIA-CHAT')];
    const result = await sendRelay(first.store, first.provider, blocked, userMessage([scanned]));
    expect(sent).toHaveLength(1);
    expect(sent[0]!.url).toMatch(/\/chat\/completions$/);
    expect(textOf(result.events)).toBe('VIA-CHAT');
    expect(first.store.getState().providers[0]!.models[0]!.relayTransport).toBeUndefined();

    // Contrast: Messages can send files natively (no file override) -> first send Messages
    const open = model('claude-scan-open');
    families.set(open.id, 'anthropic');
    const second = setup([open], AUTO);
    sent.length = 0;
    responders = [messagesOk('VIA-MESSAGES')];
    await sendRelay(second.store, second.provider, open, userMessage([scanned]));
    expect(sent).toHaveLength(1);
    expect(sent[0]!.url).toMatch(/\/messages$/);
  });

  it('RL2-FIRSTSEND-06 Claude family image send gets 400 -> failed; the image negative cache key lands on Messages; observed not recorded; vision entry hidden, advanced page vision row detected', async () => {
    const relayModel = model('claude-vision-first');
    families.set(relayModel.id, 'anthropic');
    const { store, provider } = setup([relayModel], AUTO);
    responders = [reject(400)];
    const { events, handle } = await sendRelay(store, provider, relayModel, userMessage([imageAttachment]));
    expect(sent).toHaveLength(1);
    expect(sent[0]!.url).toMatch(/\/messages$/);
    expect(errorsOf(events)).toEqual([expect.objectContaining({ status: 400 })]);
    expect(handle.getRelayImageRejected?.()).toBe(true);
    expect(keyOf(provider, relayModel, 'anthropic_messages', 'image')).toBe(true);
    expect(keyOf(provider, relayModel, 'openai_chat_completions', 'image')).toBe(false);
    const after = store.getState().providers[0]!.models[0]!;
    expect(after.relayTransport).toBeUndefined();
    expect(resolveAttachmentCapabilities(provider, after, { image: true, nativeFile: false, textFileInline: true })
      .supportsImage).toBe(false);
    const imageRow = relayModelAdvancedBoard({ provider, model: after, now: Date.now() }).capabilityRows
      .find((row) => row.cap === 'image');
    expect(imageRow?.source).toBe('detected');
  });

  it('RL2-FIRSTSEND-07 tool rejection negative cache is written under Messages (Chat key has no entry), tool capability ruling false', () => {
    const relayModel = model('claude-tools-first');
    families.set(relayModel.id, 'anthropic');
    const { provider } = setup([relayModel], AUTO);
    const identity: ToolCallRecoveryIdentity = {
      accountId: getActiveUIDSync(),
      connectionId: provider.id,
      authMode: 'bearer',
      canonicalModelId: relayModel.id,
      finalTransport: 'anthropic_messages',
    };
    recordToolCallFallback(provider, relayModel, identity, {
      status: 400, structuredError: { error: { message: 'tools is not supported by this model' } },
    }, 'anthropic_messages');
    expect(keyOf(provider, relayModel, 'anthropic_messages', 'toolCall')).toBe(true);
    expect(keyOf(provider, relayModel, 'openai_chat_completions', 'toolCall')).toBe(false);
    expect(toolCallRememberedUnsupported(provider, relayModel, identity)).toBe(true);
    expect(resolveModelCapabilityEvidence({
      key: 'tool_call', provider, model: relayModel, streamOptions: streamOptionsFor(provider, relayModel),
    }).support).toBe('unsupported');
  });

  it('RL2-FIRSTSEND-08 first send Messages, this time actually sent as Chat and tools rejected -> toolCall negative cache is under the Chat key, the Messages key has no entry', () => {
    const relayModel = model('claude-tools-sent-chat');
    families.set(relayModel.id, 'anthropic');
    const { provider } = setup([relayModel], AUTO);
    expect(relayFirstSendTransport(provider, relayModel)).toBe('anthropic_messages');
    const identity: ToolCallRecoveryIdentity = {
      accountId: getActiveUIDSync(),
      connectionId: provider.id,
      authMode: 'bearer',
      canonicalModelId: relayModel.id,
      finalTransport: 'openai_chat',
    };
    recordToolCallFallback(provider, relayModel, identity, {
      status: 400, structuredError: { error: { message: 'tools is not supported by this model' } },
    }, 'openai_chat_completions');
    expect(keyOf(provider, relayModel, 'openai_chat_completions', 'toolCall')).toBe(true);
    expect(keyOf(provider, relayModel, 'anthropic_messages', 'toolCall')).toBe(false);
  });

  /** The production executor of the capability test; only the last hop of sending is replaced, recording the actual upstream address. */
  async function runCapabilityTestCapturing(store: ReturnType<typeof createAppStore>, provider: Provider, relayModel: AIModel) {
    const urls: string[] = [];
    const result = await runRelayCapabilityTest(store, provider.id, relayModel.id, {
      send: async (request) => {
        const upstream = Object.entries(request.headers ?? {})
          .find(([name]) => name.toLowerCase() === 'x-relay-upstream-url')?.[1] ?? request.url;
        urls.push(upstream);
        return { status: 200, contentType: 'text/event-stream', body: capTestEvidenceBody(upstream.endsWith('/messages') ? 'messages' : 'chat', request.body) };
      },
    });
    return { result, urls };
  }

  function seedBothKeys(provider: Provider, relayModel: AIModel) {
    for (const transport of ['anthropic_messages', 'openai_chat_completions'] as const) {
      for (const kind of ['image', 'toolCall'] as const) {
        recordRelayNegativeCache({ connectionId: provider.id, modelId: relayModel.id, transport, kind });
      }
    }
  }

  it('RL2-CAPTEST-FIRSTSEND-01 unverified Claude family on an auto connection (first send Messages, effective Chat): the test sends via Messages, clears the Messages key, the Chat key is untouched', async () => {
    const relayModel = model('claude-captest-first');
    families.set(relayModel.id, 'anthropic');
    const { store, provider } = setup([relayModel], AUTO);
    expect(effectiveTransport(provider, relayModel)).toBe('openai_chat_completions');
    seedBothKeys(provider, relayModel);

    expect(relayCapabilityTestTransport(provider, relayModel)).toBe('messages');
    const { result, urls } = await runCapabilityTestCapturing(store, provider, relayModel);

    expect(result.outcome).toBe('completed');
    expect(result.written).toBe(true);
    expect(urls.length).toBeGreaterThan(0);
    expect(urls.every((url) => url.endsWith('/messages'))).toBe(true);
    expect(keyOf(provider, relayModel, 'anthropic_messages', 'image')).toBe(false);
    expect(keyOf(provider, relayModel, 'anthropic_messages', 'toolCall')).toBe(false);
    expect(keyOf(provider, relayModel, 'openai_chat_completions', 'image')).toBe(true);
    expect(keyOf(provider, relayModel, 'openai_chat_completions', 'toolCall')).toBe(true);
  });

  it('RL2-CAPTEST-FIRSTSEND-02 first send = effective protocol (OpenAI family): the test sends via Chat as before and clears the Chat key', async () => {
    const relayModel = model('gpt-captest-first');
    families.set(relayModel.id, 'openai');
    const { store, provider } = setup([relayModel], AUTO);
    seedBothKeys(provider, relayModel);

    expect(relayCapabilityTestTransport(provider, relayModel)).toBe('chat');
    const { result, urls } = await runCapabilityTestCapturing(store, provider, relayModel);

    expect(result.outcome).toBe('completed');
    expect(urls.every((url) => url.endsWith('/chat/completions'))).toBe(true);
    expect(keyOf(provider, relayModel, 'openai_chat_completions', 'image')).toBe(false);
    expect(keyOf(provider, relayModel, 'openai_chat_completions', 'toolCall')).toBe(false);
    expect(keyOf(provider, relayModel, 'anthropic_messages', 'image')).toBe(true);
    expect(keyOf(provider, relayModel, 'anthropic_messages', 'toolCall')).toBe(true);
  });
});
