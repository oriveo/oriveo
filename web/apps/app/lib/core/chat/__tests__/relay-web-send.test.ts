import 'fake-indexeddb/auto';
// @vitest-environment jsdom
/**
 * Relay web search send (fixture shared/test-fixtures/relay/web-probe.v1.json chatCases + scenario):
 * per caseId through the production send chain sendMessage -> upstream rejection loop (first send switches protocol / protocol fallback / resend without the fragment) -> production Relay orchestration layer,
 * with upstream replies injected; asserts the protocol and fragment of every attempt, the reply notice, the local record writes, and the panel web row after sending.
 * The web switch is read and written through the production composer (composer-web-preference, the same entry as ChatView), and the panel row goes through the production shape function.
 */
import { existsSync, readFileSync } from 'node:fs';
import path from 'node:path';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { AIModel, Provider } from '@oriveo/shared';
import type { StreamOptions } from '@oriveo/core/providers/types';

const mocks = vi.hoisted(() => ({
  sendStream: vi.fn(),
  buildChatHistory: vi.fn(),
  store: null as unknown,
}));
// Chat preferences are stored by runtime identity: this file's metadata snapshot has no capability runtime, so a revision is added (same as after a production cold start).
vi.mock('../../metadata/metadata-client', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../../metadata/metadata-client')>();
  return {
    ...actual,
    getCapabilityRuntime: () => actual.getCapabilityRuntime() ?? ({ revision: 'runtime-relay-web' } as never),
  };
});
vi.mock('../../../../providers/StoreProvider', () => ({ getVanillaStore: () => mocks.store }));
vi.mock('@sentry/nextjs', () => ({ captureException: vi.fn(), addBreadcrumb: vi.fn(), withScope: vi.fn() }));
vi.mock('../../providers/service', () => ({ sendStream: (...args: unknown[]) => mocks.sendStream(...args) }));
vi.mock('../../../utils/chat-stream-utils', async () => ({
  ...await vi.importActual<typeof import('../../../utils/chat-stream-utils')>('../../../utils/chat-stream-utils'),
  buildChatHistory: (...args: unknown[]) => mocks.buildChatHistory(...args),
}));
vi.mock('../../usage/usage-reporter', () => ({ enqueueUsageEvent: vi.fn(async () => undefined) }));
vi.mock('../../usage/budget-check', () => ({ checkBudgetExceeded: vi.fn() }));
vi.mock('../../sync', () => ({ getSyncAdapter: () => undefined, deleteAttachments: vi.fn() }));
vi.mock('../../skills/knowledge-api', () => ({ retrieveKnowledgeSnippets: vi.fn() }));

import { sendRelayStream } from '@oriveo/core/providers/relay-orchestrator';
import { relayWebFragmentHash } from '@oriveo/core/providers/relay-web-probe';
import { decidedTransport } from '@oriveo/core/providers/relay-effective';
import { RELAY_WEB_FRAGMENT_TEMPLATES, type RelayWebTransport } from '@oriveo/shared/relay/web-fragments';
import { createAppStore } from '../../store/app-store';
import { __resetMetadataClientForTest, __seedMetadataCacheForTest, getCapabilityRuntime, initMetadata } from '../../metadata/metadata-client';
import { sendMessage } from '../operations';
import { batchAppendStreaming } from '../stream-batcher';
import { replaceRelayWebFragments } from '../relay-web-fragments';
import { readRelayWebProbeRecord, relayWebModelOptionFacts, writeRelayWebProbeRecord } from '../relay-web-probe-records';
import { rememberRelayCatalogEndpointTypes } from '../../providers/relay-probe-candidates';
import { readComposerCapabilityPreferences, writeComposerWebPreference } from '../composer-web-preference';
import {
  capabilityPreferenceIdentity,
  encodeCapabilityTransportIdentity,
  exportCapabilityPreferenceSyncPayload,
  relayWebPreferenceIdentity,
  saveCapabilityPreferences,
} from '../capability-preference-settings';
import { migrateDraftScopedModelControls } from '../draft-scope-migration';
import { webPreferenceReachesTheWire } from '../capability-control-presentation';
import { resolveModelOptionCapabilityShape } from '../model-option-capability-shape';
import { resolveModelControlsEditability, resolveModelControlsIdentityGap } from '../model-control-capability-layout';
import { relayWebReplyNotice } from '../relay-web-reply-notice';

type Json = Record<string, unknown>;
type Transport = 'anthropic_messages' | 'openai_chat_completions';
type Attempt = { status: number; body?: string; sse?: 'plain_text' | 'chat_url_citation'; classification?: 'model_access_denied' };
type ChatCase = {
  caseId: string;
  webOn: boolean;
  userOverride: boolean | null;
  firstTransport: Transport;
  savedFragments: Transport[];
  records: Partial<Record<Transport, 'rejected'>>;
  attempts: Attempt[];
  expect: {
    attempts: Array<{ transport: Transport; fragment: 'saved' | 'template' | null }>;
    replyNotice: 'web_not_used' | null;
    recordWrites: Array<{ transport: Transport; result: string; source: string }>;
    sendFails?: boolean;
    panelAfter: { row: 'toggle' | 'toggleDisabled'; isOn: boolean };
  };
};
type EvidenceCase = { caseId: string; status: number | null; sse?: string[]; body?: unknown };

function fixtureFile(name: string): Json {
  let dir = __dirname;
  for (;;) {
    const candidate = path.join(dir, 'shared', 'test-fixtures', 'relay', name);
    if (existsSync(candidate)) return JSON.parse(readFileSync(candidate, 'utf8')) as Json;
    const parent = path.dirname(dir);
    if (parent === dir) throw new Error(`${name} not found`);
    dir = parent;
  }
}
type KeyCase = {
  caseId: string;
  modelId: string;
  transports?: Array<Transport | null>;
  steps?: Array<{ transport?: Transport | null; write?: 'on' | 'off'; conversation: string; firstSend?: boolean; transportAfter?: Transport }>;
  legacyRecord?: { finalTransport: string; runtimeRevision: string; scope: 'connection_model'; web: 'automatic' | 'off' };
  fixedRecord?: { scope: 'connection_model'; web: 'automatic' | 'off' };
  expect: { wire?: string; canonicalModelId?: string; sameRecordForAll?: boolean; readConversation?: string; isOn?: boolean; fixedRecordWritten?: boolean };
};
const webProbe = fixtureFile('web-probe.v1.json') as {
  preferenceIdentity: { wire: string; cases: KeyCase[] };
  chatCases: { cases: ChatCase[]; scenario: { expect: { panelAfter: { row: string; isOn: boolean }; secondSendFirstAttempt: { transport: Transport; fragment: 'template' } } } };
  evidenceCases: EvidenceCase[];
};
const keyAccess = fixtureFile('key-access.v1.json') as { classifyCases: Array<{ caseId: string; status: number; body: string; expect: string }> };
const evidence = (caseId: string) => webProbe.evidenceCases.find((item) => item.caseId === caseId)!;
const accessDenied = keyAccess.classifyCases.find((item) => item.expect === 'model_access_denied')!;

const METADATA_FIXTURE = {
  version: 1, contractVersion: 1, updatedAt: '2026-08-08T00:00:00Z',
  profiles: { reasoning: {}, webSearch: {}, imageGen: {} }, providers: {}, providerConfigs: [],
};

const CONNECTION = 'relay-auto-web';
const CONVERSATION = 'conv-web-1';
const DRAFT = 'draft-web-1';
/** A stored fragment that differs from the template, so the request body shows which one was sent. */
const SAVED: Record<Transport, Json> = {
  anthropic_messages: { tools: [{ type: 'web_search_20250305', name: 'web_search', max_uses: 2 }] },
  openai_chat_completions: { web_search_options: { search_context_size: 'high' } },
};
const TEMPLATE = RELAY_WEB_FRAGMENT_TEMPLATES as Record<RelayWebTransport, Json>;
const claude = {
  id: 'claude-sonnet-4', name: 'claude-sonnet-4', capabilities: ['text'], reasoningModeAvailable: false, isAvailable: true, isDefault: true, priceTier: '',
} as AIModel;
/** An auto connection whose model has no protocol of its own (unverified); the first catalog endpoint type is anthropic -> the first send is Messages. */
function autoProvider(model: AIModel): Provider {
  return {
    id: CONNECTION, kind: 'relay', status: { kind: 'connected' }, models: [model], catalogModels: [], apiKey: 'sk-relay', apiKeyPreview: '••',
    baseURLText: 'https://relay.example/v1',
    relayRequested: { transport: 'auto', resolvedAPIBaseURL: 'https://relay.example/v1' },
  } as unknown as Provider;
}

const sent: Array<{ transport: Transport; body: Json }> = [];
let queue: Array<(transport: Transport) => Response> = [];

function transportOfURL(url: string): Transport {
  if (url.includes('/messages')) return 'anthropic_messages';
  if (url.includes('/chat/completions')) return 'openai_chat_completions';
  throw new Error(`unexpected url ${url}`);
}

function sseResponse(lines: string[]): Response {
  return new Response(`${lines.join('\n')}\n`, { status: 200, headers: { 'Content-Type': 'text/event-stream' } });
}

function answer(attempt: Attempt): (transport: Transport) => Response {
  return (transport) => {
    if (attempt.sse === 'plain_text') {
      return sseResponse(evidence(transport === 'anthropic_messages' ? 'messages_text_only_silent' : 'chat_text_only_silent').sse!);
    }
    if (attempt.sse === 'chat_url_citation') return sseResponse(evidence('chat_url_citation_searched').sse!);
    const body = attempt.classification === 'model_access_denied' ? accessDenied.body : attempt.body ?? '{}';
    return new Response(body, { status: attempt.status, headers: { 'Content-Type': 'application/json' } });
  };
}

/** Which fragment this request body carried: stored / template / none. */
function fragmentOf(transport: Transport, body: Json): 'saved' | 'template' | null | 'other' {
  const carries = (fragment: Json) => Object.keys(fragment).every((key) => JSON.stringify(body[key]) === JSON.stringify(fragment[key]));
  if (carries(SAVED[transport])) return 'saved';
  if (carries(TEMPLATE[transport])) return 'template';
  const keys = [...Object.keys(SAVED[transport]), ...Object.keys(TEMPLATE[transport])];
  return keys.some((key) => key in body) ? 'other' : null;
}

function effectiveFragment(item: Pick<ChatCase, 'savedFragments'>, transport: Transport): Json {
  return item.savedFragments.includes(transport) ? SAVED[transport] : TEMPLATE[transport];
}

/** The panel web row (the same production decisions as ModelOptionsPopover: identity gap -> choose a protocol first; otherwise the relay web form). */
function panelRow(provider: Provider, model: AIModel, conversationId: string | undefined, draftSessionId = DRAFT) {
  const identity = capabilityPreferenceIdentity(provider, model);
  const editability = resolveModelControlsEditability({
    providerKind: provider.kind, ...(identity ? { transportIdentity: identity.transportIdentity } : {}), runtimeIsReadOnly: false,
  });
  const identityGap = resolveModelControlsIdentityGap({
    providerKind: provider.kind,
    relayTransportIsDecided: Boolean(decidedTransport(provider, model)),
    runtimeIsReady: getCapabilityRuntime() != null,
  });
  const values = readComposerCapabilityPreferences({ provider, model, conversationId, draftSessionId });
  const shape = resolveModelOptionCapabilityShape({
    capability: 'web', status: 'unknown', availableIntents: [], selectedIntent: values.web, connection: 'custom', isWritable: true,
    protocolUndecided: identityGap === 'relayTransportUndecided' && editability === 'runtimeIdentityUnavailable',
    rejectedIntents: [], chatTemplateThinkingIsOn: false, supportsChatTemplate: false,
    relayWeb: relayWebModelOptionFacts(provider, model),
  });
  if (shape.kind !== 'toggle') return { kind: shape.kind };
  return { row: shape.disabled === true ? 'toggleDisabled' : 'toggle', isOn: shape.isOn };
}

/** The webSearchEnabled ChatView sends with: the stored web preference + whether it can reach the wire (same read as readStoredWebIntent). */
function composerWebOn(provider: Provider, model: AIModel, conversationId: string | undefined, draftSessionId = DRAFT): boolean {
  const values = readComposerCapabilityPreferences({ provider, model, conversationId, draftSessionId });
  const identity = capabilityPreferenceIdentity(provider, model);
  return values.web !== 'off' && webPreferenceReachesTheWire({
    provider, model, ...(identity ? { transportIdentity: identity.transportIdentity } : {}),
  });
}

function latest(store: ReturnType<typeof createAppStore>): { provider: Provider; model: AIModel } {
  const provider = store.getState().providers[0]!;
  return { provider, model: provider.models.find((item) => item.id === claude.id)! };
}

async function sendOnce(store: ReturnType<typeof createAppStore>, conversationId: string | undefined, draftSessionId = DRAFT) {
  mocks.store = store;
  const { provider, model } = latest(store);
  const conversation = conversationId ? store.getState().conversations.find((item) => item.id === conversationId) : undefined;
  await sendMessage(
    { store, appendChunk: (chunk: string) => batchAppendStreaming(conversationId ?? 'new', chunk), te: (k: string) => k },
    {
      text: 'What is the top news today?', prevMessages: conversation?.messages ?? [], conversation, provider, model,
      reasoningMode: 'automatic', webSearchEnabled: composerWebOn(provider, model, conversationId, draftSessionId),
      generationParameterDraftSessionId: draftSessionId,
    },
  ).done;
  const conv = conversationId
    ? store.getState().conversations.find((item) => item.id === conversationId)!
    : store.getState().conversations[0]!;
  const assistants = conv.messages.filter((message) => message.role === 'assistant');
  return { conversationId: conv.id, assistant: assistants[assistants.length - 1]! };
}

beforeEach(async () => {
  localStorage.clear();
  sent.length = 0;
  queue = [];
  __resetMetadataClientForTest();
  await __seedMetadataCacheForTest({ data: METADATA_FIXTURE, timestamp: Date.now() } as never);
  await initMetadata();
  rememberRelayCatalogEndpointTypes(CONNECTION, { [claude.id]: ['anthropic', 'openai'] });
  mocks.buildChatHistory.mockResolvedValue([{ role: 'user', content: 'What is the top news today?' }]);
  mocks.sendStream.mockReset().mockImplementation((_kind: unknown, apiKey: string, modelID: string, messages: never, baseURL: string, options: StreamOptions) =>
    sendRelayStream(apiKey, modelID, messages, baseURL, options, {
      transport: {
        fetch: async (url, init) => {
          const transport = transportOfURL(String(url));
          sent.push({ transport, body: JSON.parse(String(init.body)) as Json });
          const next = queue.shift();
          if (!next) throw new Error('no more upstream answers');
          return next(transport);
        },
      },
      buildFetchArgs: (url, headers) => ({ url, headers }),
      getRelayRuntimeConfig: () => null,
    }));
});

afterEach(() => {
  rememberRelayCatalogEndpointTypes(CONNECTION, undefined);
  __resetMetadataClientForTest();
  localStorage.clear();
});

describe('RL2-WEBPROBE-SEND chatCases (production send path)', () => {
  for (const item of webProbe.chatCases.cases) {
    it(`RL2-WEBPROBE-SEND-${item.caseId}`, async () => {
      replaceRelayWebFragments(CONNECTION, Object.fromEntries(item.savedFragments.map((transport) => [transport, SAVED[transport]])));
      for (const [transport, result] of Object.entries(item.records) as Array<[Transport, 'rejected']>) {
        writeRelayWebProbeRecord(
          { connectionId: CONNECTION, modelId: claude.id, transport },
          { result, source: 'tested', at: '2026-10-14T00:00:00.000Z', fragmentHash: relayWebFragmentHash(effectiveFragment(item, transport)) },
        );
      }
      const model: AIModel = item.userOverride === null
        ? claude
        : { ...claude, relayCapabilityOverrides: { web: { value: item.userOverride, source: 'user' } } };
      const provider = autoProvider(model);
      const store = createAppStore({
        providers: [provider],
        conversations: [{
          id: CONVERSATION, title: 'T', hasCustomTitle: false, providerID: provider.id, modelID: model.id, previewText: '', estimatedCost: 0,
          isDraft: false, messages: [], draftText: '', updatedAt: '2026-10-14T00:00:00.000Z',
        } as never],
      });
      // The user toggles the web switch in this session (the same write entry as ChatView).
      expect(writeComposerWebPreference({ provider, model, conversationId: CONVERSATION, draftSessionId: DRAFT }, item.webOn ? 'automatic' : 'off'), item.caseId).toBe(true);
      const before = Object.fromEntries((['anthropic_messages', 'openai_chat_completions'] as Transport[])
        .map((transport) => [transport, readRelayWebProbeRecord({ connectionId: CONNECTION, modelId: claude.id, transport })]));
      queue = item.attempts.map(answer);

      const { assistant } = await sendOnce(store, CONVERSATION);

      expect(sent.map((attempt) => ({ transport: attempt.transport, fragment: fragmentOf(attempt.transport, attempt.body) })), item.caseId)
        .toEqual(item.expect.attempts);
      expect(assistant.state, item.caseId).toBe(item.expect.sendFails ? 'failed' : 'delivered');
      expect(relayWebReplyNotice(assistant.id) ?? null, item.caseId).toBe(item.expect.replyNotice);
      for (const transport of ['anthropic_messages', 'openai_chat_completions'] as Transport[]) {
        const key = { connectionId: CONNECTION, modelId: claude.id, transport };
        const write = item.expect.recordWrites.find((entry) => entry.transport === transport);
        if (!write) {
          expect(readRelayWebProbeRecord(key), `${item.caseId} ${transport}`).toEqual(before[transport]);
          continue;
        }
        // Hash = the fragment that protocol actually sent.
        const sentFragment = effectiveFragment(item, transport);
        expect(readRelayWebProbeRecord(key), `${item.caseId} ${transport}`)
          .toMatchObject({ result: write.result, source: write.source, fragmentHash: relayWebFragmentHash(sentFragment) });
      }
      const after = latest(store);
      expect(panelRow(after.provider, after.model, CONVERSATION), item.caseId).toEqual(item.expect.panelAfter);
    });
  }
});

describe('RL2-WEBPROBE-SEND the switch does not turn itself off on the first chat', () => {
  it('RL2-WEBPROBE-SEND-first_chat_toggle_survives', async () => {
    const expected = webProbe.chatCases.scenario.expect;
    const provider = autoProvider(claude);
    const store = createAppStore({ providers: [provider], conversations: [] });

    // New conversation (no id yet): the panel web row is a switch and the user turns it on.
    expect(panelRow(provider, claude, undefined)).toEqual({ row: 'toggle', isOn: false });
    expect(writeComposerWebPreference({ provider, model: claude, conversationId: undefined, draftSessionId: DRAFT }, 'automatic')).toBe(true);
    expect(panelRow(provider, claude, undefined)).toEqual({ row: 'toggle', isOn: true });

    // First send on Messages carries the template -> route-level 404 -> falls back to Chat and delivers with the template.
    queue = [
      answer({ status: 404, body: '{"error":{"message":"Invalid URL (POST /v1/messages)"}}' }),
      answer({ status: 200, sse: 'plain_text' }),
    ];
    const first = await sendOnce(store, undefined);
    expect(first.assistant.state).toBe('delivered');
    expect(sent.map((attempt) => ({ transport: attempt.transport, fragment: fragmentOf(attempt.transport, attempt.body) }))).toEqual([
      { transport: 'anthropic_messages', fragment: 'template' },
      { transport: 'openai_chat_completions', fragment: 'template' },
    ]);
    const after = latest(store);
    expect(after.model.relayTransport).toBe('openai_chat_completions');

    // After sending, reopening the panel, reopening the conversation (new page = new draft id): the switch is still on.
    expect(panelRow(after.provider, after.model, first.conversationId)).toEqual(expected.panelAfter);
    expect(panelRow(after.provider, after.model, first.conversationId)).toEqual(expected.panelAfter);
    expect(panelRow(after.provider, after.model, first.conversationId, 'draft-reopened')).toEqual(expected.panelAfter);

    // Second send: the first send is Chat already, carrying the template.
    sent.length = 0;
    queue = [answer({ status: 200, sse: 'plain_text' })];
    const second = await sendOnce(store, first.conversationId, 'draft-reopened');
    expect(second.assistant.state).toBe('delivered');
    expect({ transport: sent[0]!.transport, fragment: fragmentOf(sent[0]!.transport, sent[0]!.body) }).toEqual(expected.secondSendFirstAttempt);
  });
});

describe('RL2-WEBPROBE-KEY fixed addressing of the web switch preference (production read/write)', () => {
  const keyCases = webProbe.preferenceIdentity.cases;
  const keyCase = (caseId: string) => keyCases.find((item) => item.caseId === caseId)!;
  const modelWith = (id: string, transport: Transport | null | undefined): AIModel => ({
    ...claude, id, name: id,
    ...(transport ? { relayTransport: transport, relayTransportSource: 'observed' as const } : {}),
  });
  const fixedRecords = () => exportCapabilityPreferenceSyncPayload().records
    .filter((record) => record.transportIdentity === webProbe.preferenceIdentity.wire);
  const isOn = (provider: Provider, model: AIModel, conversationId: string | undefined) =>
    readComposerCapabilityPreferences({ provider, model, conversationId, draftSessionId: DRAFT }).web !== 'off';

  it('RL2-WEBPROBE-KEY-identity_ignores_transport', () => {
    const item = keyCase('identity_ignores_transport');
    for (const transport of item.transports!) {
      const model = modelWith(item.modelId, transport);
      const identity = relayWebPreferenceIdentity(autoProvider(model), model);
      expect(identity?.transportIdentity, String(transport)).toBe(item.expect.wire);
      expect(identity?.canonicalModelId, String(transport)).toBe(item.expect.canonicalModelId);
    }
    // Written under any protocol, read back as the same record under the others.
    const [first, ...rest] = item.transports!;
    const writer = modelWith(item.modelId, first);
    expect(writeComposerWebPreference({ provider: autoProvider(writer), model: writer, conversationId: 'c1', draftSessionId: DRAFT }, 'automatic')).toBe(true);
    for (const transport of rest) {
      const reader = modelWith(item.modelId, transport);
      expect(isOn(autoProvider(reader), reader, 'c1'), String(transport)).toBe(true);
    }
    expect(fixedRecords()).toHaveLength(1);
  });

  it('RL2-WEBPROBE-KEY-write_before_transport_decided_reads_after', () => {
    const item = keyCase('write_before_transport_decided_reads_after');
    const [writeStep, sendStep] = item.steps!;
    const before = modelWith(item.modelId, writeStep!.transport);
    const provider = autoProvider(before);
    expect(writeComposerWebPreference({ provider, model: before, conversationId: undefined, draftSessionId: DRAFT }, writeStep!.write === 'on' ? 'automatic' : 'off')).toBe(true);
    // First send creates the conversation: the draft scope moves to the real conversation with the draft (the same call as sendMessage).
    migrateDraftScopedModelControls({ provider, model: before, conversation: undefined, draftSessionId: DRAFT, conversationId: sendStep!.conversation });
    const after = modelWith(item.modelId, sendStep!.transportAfter);
    expect(isOn(autoProvider(after), after, item.expect.readConversation)).toBe(item.expect.isOn);
    expect(isOn(autoProvider(after), after, item.expect.readConversation)).toBe(item.expect.isOn);
  });

  for (const caseId of ['legacy_transport_record_is_read_and_moved', 'fixed_record_wins_over_legacy']) {
    it(`RL2-WEBPROBE-KEY-${caseId}`, () => {
      const item = keyCase(caseId);
      const model = modelWith(item.modelId, 'openai_chat_completions');
      const provider = autoProvider(model);
      const fixed = relayWebPreferenceIdentity(provider, model)!;
      const legacy = item.legacyRecord!;
      saveCapabilityPreferences({
        providerId: fixed.providerId, canonicalModelId: item.modelId,
        finalTransport: legacy.finalTransport, runtimeRevision: legacy.runtimeRevision,
        transportIdentity: encodeCapabilityTransportIdentity(legacy.finalTransport, legacy.runtimeRevision),
        scope: legacy.scope,
      }, { web: legacy.web });
      if (item.fixedRecord) saveCapabilityPreferences({ ...fixed, scope: item.fixedRecord.scope }, { web: item.fixedRecord.web });
      const fixedBefore = fixedRecords();
      expect(isOn(provider, model, 'c1'), caseId).toBe(item.expect.isOn);
      const fixedAfter = fixedRecords();
      expect(fixedAfter.length > fixedBefore.length, caseId).toBe(item.expect.fixedRecordWritten);
      if (item.expect.fixedRecordWritten) {
        expect(fixedAfter.find((record) => record.scope === legacy.scope)?.web, caseId).toBe(legacy.web);
      }
    });
  }
});
