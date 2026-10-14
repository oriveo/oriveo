/**
 * Relay key access classification (RK-2; contract C3 section 8, first item). Fixture: shared test-fixtures/relay/key-access.v1.json.
 *
 * SEND-* go through the production send chain: `buildOutboundChatHistory` → `sendWithRelayRejectionLoop` → `sendWithNativeFileFallback`
 * → production `sendStream` (Relay orchestration layer); only `fetch` is replaced with a fake relay.
 */
import 'fake-indexeddb/auto';
import { existsSync, readFileSync } from 'node:fs';
import path from 'node:path';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { AIModel, Attachment, ChatMessage, Provider } from '@oriveo/shared';
import { classifyRelayKeyAccess, relayGenerationKeyStatus } from '@oriveo/core/providers/relay-key-access';
import { resolveProviderAPIKey } from '@oriveo/core/providers/provider-credential';
import type { StreamEvent } from '../types';
import { createAppStore } from '../../store/app-store';
import { sendStream } from '../service';
import { sendWithNativeFileFallback } from '../../attachments/native-file-fallback';
import { buildOutboundChatHistory } from '../../chat/outbound-history';
import { buildProviderStreamOptions, buildStreamOptionsFromIntent } from '../../chat/stream-options';
import { sendWithRelayRejectionLoop } from '../../chat/relay-rejection-loop';
import { RELAY_NEGATIVE_CACHE_STORAGE_KEY } from '../../chat/relay-negative-cache';
import { createRelayManualModel } from '../../provider-model-ops';
import { rememberRelayCatalogEndpointTypes } from '../relay-probe-candidates';
import { recordRelayKeyAccessOnDelivered } from '../relay-key-access-writeback';
import { reportSendCompletion } from '../../chat/send-completion';
import { extractRelayPingFailureDetails } from '../ping-relay';
import {
  beginCapabilityEvidenceIdentityIfAbsent,
  resetCapabilityEvidenceIdentitiesForTesting,
} from '../capability-evidence-identity';
import { getActiveUIDSync } from '../../../infra/storage/partition';

interface Fixture {
  classifyCases: Array<{ caseId: string; status: number; body: string; expect: string }>;
  sendCases: Array<{
    caseId: string;
    provider?: 'single_key';
    status: number;
    body: string;
    boundKeyID: string;
    expect: {
      deniedKeyID?: string | null;
      negativeCacheWrites: number;
      requestsSent?: number;
      keyStatus?: string;
      keyHTTPStatus?: number;
      relayKeys?: Array<{ id: string; apiKey: string }>;
    };
  }>;
  generationCases: { cases: Array<{ caseId: string; status: number | null; body: string; expect: string | null }> };
}

const fixture: Fixture = (() => {
  let dir = process.cwd();
  for (let depth = 0; depth < 8; depth += 1) {
    const candidate = path.join(dir, 'shared', 'test-fixtures', 'relay', 'key-access.v1.json');
    if (existsSync(candidate)) return JSON.parse(readFileSync(candidate, 'utf8')) as Fixture;
    dir = path.dirname(dir);
  }
  throw new Error('key-access.v1.json not found');
})();

describe('KEY-ACCESS classification function (Web classifyRelayKeyAccess)', () => {
  it.each(fixture.classifyCases)('KEY-ACCESS-$caseId', (c) => {
    expect(classifyRelayKeyAccess(c.status, c.body)).toBe(c.expect);
  });
});

describe('KEY-ACCESS-GEN key status of generation requests (Web relayGenerationKeyStatus)', () => {
  it.each(fixture.generationCases.cases)('KEY-ACCESS-GEN-$caseId', (c) => {
    expect(relayGenerationKeyStatus(c.status, c.body)).toBe(c.expect);
  });
});

/* ── production send chain ──────────────────────────────────────── */

const sent: Array<{ url: string; body: string }> = [];
let responders: Array<() => Response> = [];

beforeEach(() => {
  sent.length = 0;
  responders = [];
  localStorage.clear();
  resetCapabilityEvidenceIdentitiesForTesting();
  vi.stubGlobal('fetch', vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = new Headers(init?.headers).get('X-Relay-Upstream-URL') ?? String(input instanceof Request ? input.url : input);
    sent.push({ url, body: typeof init?.body === 'string' ? init.body : '' });
    const next = responders.shift();
    return next ? next() : new Response('not found', { status: 404 });
  }));
});

afterEach(() => {
  vi.unstubAllGlobals();
  localStorage.clear();
  resetCapabilityEvidenceIdentitiesForTesting();
});

const respond = (status: number, body: string) => () => new Response(body, {
  status, headers: { 'Content-Type': 'application/json' },
});

const IMAGE_B64 = 'iVBORw0KGgoKEYACCESS';
const imageAttachment = { id: 'img-1', kind: 'image', mimeType: 'image/png', base64Data: IMAGE_B64 } as Attachment;

function userMessage(attachments?: Attachment[]): ChatMessage {
  return {
    id: 'u1', role: 'user', text: 'Look', providerKind: 'relay', providerName: 'Relay', modelName: 'm',
    estimatedCost: 0, state: 'delivered', createdAt: '2026-10-12T00:00:00Z',
    ...(attachments ? { attachments } : {}),
  } as ChatMessage;
}

function relayModel(id: string, extra: Partial<AIModel> = {}): AIModel {
  return { ...createRelayManualModel(id, true), ...extra };
}

/** Two keys: primary key sk-a (initial) + k-claude (sk-claude); or a single key (no relayKeys). */
function setup(models: AIModel[], multiKey: boolean) {
  const provider = {
    id: 'relay-key-access',
    kind: 'relay',
    status: { kind: 'connected' },
    models,
    catalogModels: models,
    apiKey: 'sk-a',
    apiKeyPreview: 'sk-...a',
    baseURLText: 'https://relay.example.com/v1',
    relayKind: 'openai_compatible',
    relayRequested: { transport: 'openai_chat_completions', authMode: 'bearer' },
    ...(multiKey ? { relayKeys: [{ id: 'initial', apiKey: '' }, { id: 'k-claude', apiKey: 'sk-claude' }] } : {}),
  } as Provider;
  const store = createAppStore();
  store.getState().addProvider(provider);
  beginCapabilityEvidenceIdentityIfAbsent(getActiveUIDSync(), provider.id);
  return { store, provider };
}

async function sendRelay(
  store: ReturnType<typeof createAppStore>,
  provider: Provider,
  model: AIModel,
  message: ChatMessage,
): Promise<StreamEvent[]> {
  const streamOptions = buildProviderStreamOptions(provider, buildStreamOptionsFromIntent(model, 'automatic', false), model);
  const history = await buildOutboundChatHistory({}, { messages: [message], provider, model, streamOptions });
  const handle = sendWithRelayRejectionLoop({
    store,
    provider,
    model,
    history,
    streamOptions,
    send: (outbound, options) => sendWithNativeFileFallback(outbound, (h) => sendStream(
      provider.kind, resolveProviderAPIKey(provider, model.id), model.id, h, provider.baseURLText, options,
    )),
  });
  const events: StreamEvent[] = [];
  const reader = handle.stream.getReader();
  while (true) {
    const { done, value } = await reader.read();
    if (done) return events;
    events.push(value);
  }
}

function negativeCacheEntries(): number {
  const raw = localStorage.getItem(RELAY_NEGATIVE_CACHE_STORAGE_KEY);
  return raw ? (JSON.parse(raw) as { entries: unknown[] }).entries.length : 0;
}

const errorsOf = (events: StreamEvent[]) => events.filter((event) => event.type === 'error');

/** Production delivered exit: after delivery, the normal / library / MCP send paths all go only through reportSendCompletion. */
function deliverThroughProductionExit(store: ReturnType<typeof createAppStore>, provider: Provider, model: AIModel) {
  reportSendCompletion({
    store,
    provider,
    model,
    conversationId: 'conv-key-access',
    effectiveConversation: undefined,
    skillId: undefined,
    usage: undefined,
    cost: 0,
    costSource: 'unknown',
    servedModelID: undefined,
    processedAttachments: [],
    promptContext: { retrievalCost: 0 },
    sendStartedAt: Date.now(),
    completedAt: new Date().toISOString(),
  });
}

describe('KEY-ACCESS send paths (fixture sendCases, production send chain)', () => {
  for (const c of fixture.sendCases) {
    it(`KEY-ACCESS-${c.caseId}`, async () => {
      const singleKey = c.provider === 'single_key';
      const delivered = c.status >= 200 && c.status < 300;
      // Source-reachable Responses model + catalog declares Chat: a protocol fallback would send a second request; with an image and unknown vision: entering the capability loop would record image.
      // A model on a single-key connection carries no key fields (fixture: no model key fields are written).
      const model = relayModel('gpt-5', {
        ...(singleKey ? {} : { relayKeyID: c.boundKeyID }), relayTransport: 'openai_responses', relayTransportSource: 'reachable',
      });
      const { store, provider } = setup([model], !singleKey);
      rememberRelayCatalogEndpointTypes(provider.id, { 'gpt-5': ['openai-response', 'openai'] });
      responders = [respond(c.status, c.body), respond(200, '{}')];

      const events = await sendRelay(store, provider, model, userMessage([imageAttachment]));

      if (delivered) {
        // Delivered: the delivered exit shared by all three send paths (production reportSendCompletion).
        expect(errorsOf(events)).toEqual([]);
        deliverThroughProductionExit(store, provider, model);
      } else {
        expect(errorsOf(events)).toEqual([expect.objectContaining({ status: c.status })]);
      }
      expect(negativeCacheEntries()).toBe(c.expect.negativeCacheWrites);
      if (c.expect.requestsSent !== undefined) expect(sent).toHaveLength(c.expect.requestsSent);
      const after = store.getState().providers[0]!;
      const afterModel = after.models.find((item) => item.id === 'gpt-5')!;
      expect(afterModel.relayDeniedKeyID ?? null).toBe(c.expect.deniedKeyID ?? null);
      // No-access does not switch transport: the model transport stays as is.
      expect(afterModel.relayTransport).toBe('openai_responses');
      const key = after.relayKeys?.find((item) => item.id === c.boundKeyID);
      if (c.expect.keyStatus) {
        expect(key?.status).toEqual({
          state: c.expect.keyStatus,
          ...(c.expect.keyHTTPStatus !== undefined ? { httpStatus: c.expect.keyHTTPStatus } : {}),
          checkedAt: expect.any(String),
        });
      } else {
        expect(key?.status).toBeUndefined();
      }
      if (c.expect.relayKeys) {
        expect(after.relayKeys?.map(({ id, apiKey }) => ({ id, apiKey }))).toEqual(c.expect.relayKeys);
        for (const item of after.models) {
          expect(item).not.toHaveProperty('relayKeyID');
          expect(item).not.toHaveProperty('relayListedByKeyIDs');
        }
      }
    });
  }

  it('KEY-ACCESS-SEND-responses_image_tool_no_resend Responses with image_generation tool judged no-access: do not drop the tool / do not downgrade and resend', async () => {
    const model = relayModel('gpt-image-2', { relayKeyID: 'k-claude', relayTransport: 'openai_responses', relayTransportSource: 'user' });
    const { store, provider } = setup([model], true);
    responders = [respond(403, '{"error":{"message":"\u8be5\u4ee4\u724c\u65e0\u6743\u8bbf\u95ee\u6a21\u578b gpt-image-2","type":"new_api_error","code":""}}'), respond(200, '{}')];
    await sendRelay(store, provider, model, userMessage());
    expect(sent).toHaveLength(1);
    expect(sent[0]!.body).toContain('"image_generation"');
    expect(negativeCacheEntries()).toBe(0);
    expect(store.getState().providers[0]!.models[0]!.relayDeniedKeyID).toBe('k-claude');
  });

  it('KEY-REDACT-send_and_ping_failure_mask_all_connection_keys', async () => {
    const model = relayModel('gpt-5', { relayKeyID: 'initial' });
    const { provider } = setup([model], true);
    // Send: the upstream echoed another key's value.
    responders = [respond(400, '{"error":{"message":"bad request, other key rk2SecretValueQ7 leaked"}}')];
    const options = {
      ...buildProviderStreamOptions(provider, buildStreamOptionsFromIntent(model, 'automatic', false), model),
      relayConnectionKeySecrets: ['sk-a', 'rk2SecretValueQ7'],
    };
    const handle = sendStream(provider.kind, resolveProviderAPIKey(provider, model.id), model.id,
      [{ role: 'user', content: 'hi' }], provider.baseURLText, options);
    const events: StreamEvent[] = [];
    const reader = handle.stream.getReader();
    for (let next = await reader.read(); !next.done; next = await reader.read()) events.push(next.value);
    const text = JSON.stringify(errorsOf(events));
    expect(text).toContain('400');
    expect(text).not.toContain('rk2SecretValueQ7');
    // Test-connection failure card: the same full key list.
    const details = extractRelayPingFailureDetails(
      { kind: 'badRequest', detail: 'echo rk2SecretValueQ7', status: 400 },
      { apiKey: 'sk-a', relayRequested: provider.relayRequested!, connectionKeySecrets: ['sk-a', 'rk2SecretValueQ7'] },
    );
    expect(JSON.stringify(details)).not.toContain('rk2SecretValueQ7');
  });

  it('KEY-ACCESS-SEND-single_key_denied_writes_initial', async () => {
    const model = relayModel('gpt-5');
    const { store, provider } = setup([model], false);
    responders = [respond(403, '{"error":{"message":"\u8be5\u4ee4\u724c\u65e0\u6743\u8bbf\u95ee\u6a21\u578b gpt-5","type":"new_api_error","code":""}}')];
    await sendRelay(store, provider, model, userMessage());
    const after = store.getState().providers[0]!;
    expect(after.models[0]!.relayDeniedKeyID).toBe('initial');
    expect(after).not.toHaveProperty('relayKeys');
    expect(sent).toHaveLength(1);
  });

  it('KEY-ACCESS-SEND-flat_code_403_judged_on_raw_body', async () => {
    // sub2api top-level {code,message}: the errorDetail allowlist fragment has no top-level code, so classification must use the raw text.
    const model = relayModel('gpt-5', { relayKeyID: 'k-claude' });
    const { store, provider } = setup([model], true);
    responders = [respond(403, '{"code":"INSUFFICIENT_BALANCE","message":"Insufficient balance"}')];
    await sendRelay(store, provider, model, userMessage());
    const key = store.getState().providers[0]!.relayKeys!.find((item) => item.id === 'k-claude')!;
    expect(key.status).toEqual({ state: 'limited', httpStatus: 403, checkedAt: expect.any(String) });
  });

  it('KEY-ACCESS-SEND-none_keeps_capability_loop', async () => {
    // A capability rejection classified as none still enters the loop (records image) and writes no key fields.
    const model = relayModel('gpt-5', { relayKeyID: 'k-claude' });
    const { store, provider } = setup([model], true);
    responders = [respond(400, '{"error":{"message":"This model does not support image input","type":"invalid_request_error"}}')];
    await sendRelay(store, provider, model, userMessage([imageAttachment]));
    expect(negativeCacheEntries()).toBe(1);
    const after = store.getState().providers[0]!;
    expect(after.models[0]!.relayDeniedKeyID).toBeUndefined();
    expect(after.relayKeys!.find((item) => item.id === 'k-claude')!.status).toBeUndefined();
  });

  it('RL2-KEYSTATUS-19 key value replaced while a send is in flight → neither 401 nor delivery writes status (production send chain)', async () => {
    const model = relayModel('gpt-5', { relayKeyID: 'k-claude' });
    const { store, provider } = setup([model], true);
    const rotate = () => store.getState().updateProvider(provider.id, {
      relayKeys: [{ id: 'initial', apiKey: '' }, { id: 'k-claude', apiKey: 'sk-claude-rotated' }],
    });
    responders = [() => {
      rotate();
      return new Response('{"error":{"message":"Invalid API key"}}', { status: 401, headers: { 'Content-Type': 'application/json' } });
    }];

    const events = await sendRelay(store, provider, model, userMessage());
    expect(errorsOf(events)).toEqual([expect.objectContaining({ status: 401 })]);
    expect(store.getState().providers[0]!.relayKeys!.find((key) => key.id === 'k-claude')!.status).toBeUndefined();

    // Delivered: the connection at send start (old value) goes through the production delivered exit; that key's value has been replaced → do not write normal.
    responders = [respond(200, '')];
    const start = store.getState().providers[0]!;
    store.getState().updateProvider(provider.id, {
      relayKeys: [{ id: 'initial', apiKey: '' }, { id: 'k-claude', apiKey: 'sk-claude-rotated-2' }],
    });
    deliverThroughProductionExit(store, start, model);
    expect(store.getState().providers[0]!.relayKeys!.find((key) => key.id === 'k-claude')!.status).toBeUndefined();
  });

  it('KEY-ACCESS-SEND-delivered_clears_denial_and_marks_ok', () => {
    const model = relayModel('gpt-5', { relayKeyID: 'k-claude', relayDeniedKeyID: 'k-claude' });
    const { store, provider } = setup([model], true);
    store.getState().updateProvider(provider.id, {
      relayKeys: [{ id: 'initial', apiKey: '' }, { id: 'k-claude', apiKey: 'sk-claude', status: { state: 'invalid', httpStatus: 401 } }],
    });
    const start = store.getState().providers[0]!;
    recordRelayKeyAccessOnDelivered(store, start, start.models[0]!);
    const after = store.getState().providers[0]!;
    expect(after.models[0]).not.toHaveProperty('relayDeniedKeyID');
    expect(after.relayKeys![1]!.status).toEqual({ state: 'ok', checkedAt: expect.any(String) });
    // The other key's marker is not cleared.
    const other = relayModel('gpt-4o', { relayKeyID: 'k-claude', relayDeniedKeyID: 'initial' });
    store.getState().updateProvider(provider.id, { models: [other] });
    const again = store.getState().providers[0]!;
    recordRelayKeyAccessOnDelivered(store, again, other);
    expect(store.getState().providers[0]!.models[0]!.relayDeniedKeyID).toBe('initial');
  });
});
