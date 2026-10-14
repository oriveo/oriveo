// @vitest-environment jsdom
//
// Capability matrix: subscription connections (every SUB cell).
// Upstream /models uses the shared fixture subscription-models.v1.json, attached to the subscription connection via the production decoder + production catalog mapping;
// assertions look at the production decision / shape functions / copy mapping, and the request body actually handed out when the production send orchestration goes
// browser egress -> the real /api/chat/stream route -> upstream egress. Upstream lives only in-process (fetch stub); no real Provider is hit.

import 'fake-indexeddb/auto';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { AIModel, Attachment, Conversation, Provider, ReasoningMode } from '@oriveo/shared';

// Server-side subscriptionAuth for the two subscription lines (same production shape as grok / openai-subscription-transport.test.ts).
const SUBSCRIPTION_METADATA = vi.hoisted(() => ({
  version: 1,
  updatedAt: '2026-10-12T00:00:00Z',
  profiles: { reasoning: {}, webSearch: {}, imageGen: {} },
  providers: {},
  providerConfigs: [
    {
      kind: 'grok',
      protocolFeatures: {
        authMethod: 'bearer',
        subscriptionAuth: {
          enabled: true,
          flow: 'oauth_device_code',
          clientId: 'b1a00492-073a-47ea-816f-4c329264a828',
          scopes: 'openid profile email offline_access grok-cli:access api:access',
          deviceAuthorizationEndpoint: 'https://auth.x.ai/oauth2/device/code',
          tokenEndpoint: 'https://auth.x.ai/oauth2/token',
          revocationEndpoint: 'https://auth.x.ai/oauth2/revoke',
          trustedAuthHosts: ['auth.x.ai'],
          trustedVerificationHosts: ['accounts.x.ai', 'x.ai'],
          resourceBaseURL: 'https://cli-chat-proxy.grok.com/v1',
          chatPath: '/chat/completions',
          responsesPath: '/responses',
          apiBackend: 'responses',
          modelsPath: '/models',
          requiredHeaders: {
            'x-grok-client-identifier': 'oriveo',
            'x-grok-client-surface': 'grok-build',
            'x-grok-client-version': '1.0.4',
            'x-xai-token-auth': 'xai-grok-cli',
          },
          pollIntervalSeconds: 5,
          pollTimeoutSeconds: 1800,
          disabledNotice: null,
        },
      },
    },
    {
      kind: 'openAI',
      protocolFeatures: {
        authMethod: 'bearer',
        subscriptionAuth: {
          enabled: true,
          flow: 'codex_device_code',
          clientId: 'app_EMoamEEZ73f0CkXaXp7hrann',
          deviceAuthorizationEndpoint: 'https://auth.openai.com/api/accounts/deviceauth/usercode',
          deviceTokenEndpoint: 'https://auth.openai.com/api/accounts/deviceauth/token',
          tokenEndpoint: 'https://auth.openai.com/oauth/token',
          redirectURI: 'https://auth.openai.com/deviceauth/callback',
          verificationURL: 'https://auth.openai.com/codex/device',
          trustedAuthHosts: ['auth.openai.com'],
          trustedVerificationHosts: ['auth.openai.com'],
          resourceBaseURL: 'https://chatgpt.com/backend-api/codex',
          chatPath: '/responses',
          modelsPath: '/models',
          requiredHeaders: { 'OpenAI-Beta': 'responses=experimental', originator: 'oriveo', version: '0.148.0' },
          pollIntervalSeconds: 5,
          pollTimeoutSeconds: 900,
        },
      },
    },
  ],
}));

vi.mock('../../../infra/storage/partition', async (importOriginal) => ({
  ...(await importOriginal<typeof import('../../../infra/storage/partition')>()),
  getActiveUIDSync: () => 'uid-subscription',
}));
// Surroundings of the send orchestration (same seams as managed.contract.test.ts): prompt injection, settlement reporting, sync, analytics, library.
vi.mock('../prompt-injection', async (importOriginal) => ({
  ...(await importOriginal<typeof import('../prompt-injection')>()),
  buildPromptInjectionContext: vi.fn(async () => ({ systemContent: '', memoryInjected: false, retrievalCost: 0 })),
}));
vi.mock('../send-completion', () => ({ reportSendCompletion: vi.fn(), reportUsageAndBudget: vi.fn() }));
vi.mock('../../sync', () => ({ getSyncAdapter: vi.fn(() => null) }));
vi.mock('../../telemetry', async (importOriginal) => ({
  ...(await importOriginal<typeof import('../../telemetry')>()),
  trackEvent: vi.fn(),
}));
vi.mock('../../library/api', () => ({
  executeLibraryTool: vi.fn(),
  executeLibraryResearch: vi.fn(async () => ({ status: 'ok', results: [], citations: [] })),
}));
vi.mock('../../library/confirmation', () => ({
  requestLibraryConfirmation: vi.fn(async () => true),
  clearOwnLibraryConfirmation: vi.fn(),
}));
vi.mock('../../../infra/storage/image-store', () => ({
  loadImageBase64: vi.fn(async () => null),
  imageSizeBytes: vi.fn(async () => 0),
}));
// Subscription-delivered config: the browser side and the route side each read one copy of metadata; both are fed the same subscriptionAuth here,
// and the config is resolved by the production parse function. The model-facts sidecar does not take part (the sole authority for subscription capabilities is upstream /models).
vi.mock('../../metadata/metadata-client', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../../metadata/metadata-client')>();
  const grok = await import('@oriveo/core/providers/grok-subscription');
  const codex = await import('@oriveo/core/providers/openai-subscription');
  const auth = (kind: string) => SUBSCRIPTION_METADATA.providerConfigs
    .find((config) => config.kind === kind)?.protocolFeatures.subscriptionAuth;
  return {
    ...actual,
    ensureModelFacts: async () => {},
    getGrokSubscriptionAuthConfig: () => {
      const availability = grok.resolveGrokSubscriptionAuth(auth('grok'), { platform: 'web' });
      return availability.state === 'available' ? availability.config : null;
    },
    getOpenAISubscriptionAuthConfig: () => {
      const availability = codex.resolveOpenAISubscriptionAuth(auth('openAI'), { platform: 'web' });
      return availability.state === 'available' ? availability.config : null;
    },
  };
});
vi.mock('../../../../app/api/chat/stream/runtime', async (importOriginal) => {
  return {
    ...(await importOriginal<typeof import('../../../../app/api/chat/stream/runtime')>()),
    getRuntimeMetadata: async () => SUBSCRIPTION_METADATA,
  };
});
// The SSRF guard does real DNS resolution; upstream is in-process, so this check is let through.
vi.mock('../../../../app/api/_shared/ssrf-guard', async (importOriginal) => ({
  ...(await importOriginal<typeof import('../../../../app/api/_shared/ssrf-guard')>()),
  assertUrlNotSsrf: vi.fn(async () => ({ ok: true })),
}));

import { decodeGrokSubscriptionModelDescriptors } from '@oriveo/core/providers/grok-subscription';
import { decodeCodexModelDescriptors } from '@oriveo/core/providers/openai-subscription';
import { attachmentTransportProfile } from '@oriveo/core/providers/attachment-transport';
import { buildGrokSubscriptionModels } from '../../providers/grok-subscription-catalog';
import { buildOpenAISubscriptionModels } from '../../providers/openai-subscription-catalog';
import { resolveAttachmentLine } from '../../attachments/attachment-transport-resolver';
import { __resetNativeFileFallbackForTest } from '../../attachments/native-file-fallback';
import { presentCapabilityControl } from '../capability-control-presentation';
import { resolveModelControlStatus } from '../model-control-capability-layout';
import {
  resolveModelOptionCapabilityShape,
  type ModelOptionCapabilityInput,
} from '../model-option-capability-shape';
import { modelOptionsPanelModel, type ModelOptionsPanelFacts } from '../model-options-panel-model';
import { modelOptionsTileBodyCopy, modelOptionsTileStatusCopy } from '../model-options-copy';
import { sendMessage } from '../operations-send';
import { sendLibraryMessage } from '../operations-library-send';
import { createAppStore } from '../../store/app-store';
import { POST as chatStreamRoute } from '../../../../app/api/chat/stream/route';
import en from '../../../../messages/en.json';

const ROOT = resolve(__dirname, '../../../../../../..');
const fixture = JSON.parse(readFileSync(
  resolve(ROOT, 'shared/test-fixtures/provider-catalog/subscription-models.v1.json'), 'utf8',
)) as {
  grok_models: unknown;
  codex_models: unknown;
  expected: {
    'grok-4.6': {
      web: { state: string; intents: string[]; reasonCode: string; presentation: string };
      webRow: { shape: string; status: string; body: string; link: null };
      outboundToolsWithWebPreferenceOff: Array<{ type: string }>;
      automaticEffort: string;
      fileLine: { nativeFileBlock: string; nativeFiles: string };
    };
    'gpt-5.6-sol': {
      web: { state: string; intents: string[]; reasonCode: string; presentation: string };
      reasoningIntents: string[];
      effortForIntent: Record<string, string>;
      automaticEffort: null;
    };
  };
};
const expected = fixture.expected;

const GROK = 'grok-4.6';
const SOL = 'gpt-5.6-sol';
const GROK_UPSTREAM = 'https://cli-chat-proxy.grok.com/v1/responses';
const CODEX_UPSTREAM = 'https://chatgpt.com/backend-api/codex/responses';

function grokConnection(): { provider: Provider; model: AIModel } {
  const models = buildGrokSubscriptionModels(decodeGrokSubscriptionModelDescriptors(fixture.grok_models));
  const provider = {
    id: '22222222-2222-4222-8222-222222222222', kind: 'grok', status: { kind: 'connected' },
    models, catalogModels: [], apiKey: '', apiKeyPreview: '', authMode: 'subscription',
    grokSubscription: { accessToken: 'grok-at', obtainedAt: Date.now(), expiresAt: Date.now() + 3_600_000 },
  } as unknown as Provider;
  return { provider, model: pick(models, GROK) };
}

function codexConnection(): { provider: Provider; model: AIModel } {
  const models = buildOpenAISubscriptionModels(decodeCodexModelDescriptors(fixture.codex_models));
  const provider = {
    id: '11111111-1111-4111-8111-111111111111', kind: 'openAI', status: { kind: 'connected' },
    models, catalogModels: [], apiKey: '', apiKeyPreview: '', authMode: 'subscription',
    openAISubscription: { accessToken: 'codex-at', accountID: 'acc-1', obtainedAt: Date.now(), expiresAt: Date.now() + 3_600_000 },
  } as unknown as Provider;
  return { provider, model: pick(models, SOL) };
}

function pick(models: AIModel[], id: string): AIModel {
  const found = models.find((entry) => entry.id === id);
  if (!found) throw new Error(`mapped subscription catalog has no ${id}`);
  return found;
}

/** Same production inputs as ModelOptionsPopover (writable connection). */
function productionInput(provider: Provider, model: AIModel, capability: 'web' | 'reasoning', selectedIntent?: string): ModelOptionCapabilityInput {
  const control = presentCapabilityControl(provider, model, capability);
  return {
    capability,
    status: resolveModelControlStatus(control),
    availableIntents: control.availableIntents,
    ...(selectedIntent ? { selectedIntent } : {}),
    connection: 'official',
    isWritable: true,
    protocolUndecided: false,
    rejectedIntents: [],
    chatTemplateThinkingIsOn: false,
    supportsChatTemplate: false,
  };
}

function englishCopy(key: string | undefined): string | undefined {
  if (!key) return undefined;
  const [namespace, name] = key.split('.');
  return (en as unknown as Record<string, Record<string, string>>)[namespace][name];
}

function webTileCopy(provider: Provider, model: AIModel, selectedIntent: string): { status?: string; body?: string; corner: string } {
  const panel = modelOptionsPanelModel({
    isManaged: false,
    connection: 'official',
    connectionName: provider.kind,
    web: productionInput(provider, model, 'web', selectedIntent),
    reasoning: productionInput(provider, model, 'reasoning'),
    chatTemplateState: 'off',
    hasAlternativeModels: { web: false, reasoning: false },
    hasReadOnlyReason: false,
    generationRows: [],
    notes: {
      web: { overridden: false, riskTiers: [], upstreamRejected: false },
      reasoning: { overridden: false, riskTiers: [], upstreamRejected: false },
    },
    vision: { entryVisible: false, isRelayForm: false, noPositiveEvidence: false },
    file: { nativeFileMimes: [], pdfNativeDefault: false },
  } as ModelOptionsPanelFacts);
  const tile = panel.tiles.find((entry) => entry.kind === 'capability' && entry.capability === 'web');
  if (!tile) throw new Error('no web tile');
  const status = modelOptionsTileStatusCopy(tile);
  const body = modelOptionsTileBodyCopy(tile);
  return {
    status: englishCopy(status && 'key' in status ? status.key : undefined),
    body: englishCopy(body && 'key' in body ? body.key : undefined),
    corner: tile.corner,
  };
}

/* -- In-process upstream: the browser egress connects to the real route, and the route egress lands here -- */

type UpstreamCall = { url: string; body: Record<string, unknown> };
let upstreamCalls: UpstreamCall[] = [];
let upstreamReply: (call: UpstreamCall, index: number) => Response;

function responsesSse(text: string): Response {
  const events = [
    { type: 'response.output_text.delta', delta: text },
    { type: 'response.completed', response: { id: 'resp-1', status: 'completed', usage: { input_tokens: 1, output_tokens: 1 } } },
  ];
  return new Response(
    events.map((event) => `event: ${event.type}\ndata: ${JSON.stringify(event)}\n\n`).join(''),
    { status: 200, headers: { 'Content-Type': 'text/event-stream' } },
  );
}

function rejected(): Response {
  return new Response(JSON.stringify({ error: { message: 'rejected by test upstream' } }), {
    status: 400, headers: { 'Content-Type': 'application/json' },
  });
}

async function fakeFetch(input: RequestInfo | URL, init?: RequestInit): Promise<Response> {
  const url = typeof input === 'string' ? input : input instanceof URL ? input.toString() : input.url;
  if (url === '/api/chat/stream') {
    return chatStreamRoute(new Request('http://localhost/api/chat/stream', init) as never);
  }
  if (url === GROK_UPSTREAM || url === CODEX_UPSTREAM) {
    const call = { url, body: JSON.parse(String(init?.body)) as Record<string, unknown> };
    upstreamCalls.push(call);
    return upstreamReply(call, upstreamCalls.length - 1);
  }
  return new Response('not found', { status: 404 });
}

function conversation(provider: Provider, model: AIModel): Conversation {
  return {
    id: `conv-${provider.kind}`, title: 'Subscription', hasCustomTitle: false, providerID: provider.id,
    providerKind: provider.kind, modelID: model.id, previewText: '', estimatedCost: 0, isDraft: false,
    messages: [], draftText: '',
    createdAt: '2026-10-12T00:00:00.000Z', updatedAt: '2026-10-12T00:00:00.000Z',
  } as Conversation;
}

/** Production plain send orchestration: prepare -> outbound gate -> stream-runner -> browser egress -> route -> upstream. */
async function sendTurn(input: {
  provider: Provider; model: AIModel;
  reasoningMode: ReasoningMode;
  web: 'off' | 'automatic';
  attachments?: Attachment[];
}) {
  // Same shape as production: the panel tier writes a typed preference (reasoningIntent), and the chip also carries the same tier into the send as reasoningMode.
  const reasoningIntent = input.reasoningMode === 'automatic' ? undefined
    : input.reasoningMode === 'fast' ? 'low' : input.reasoningMode;
  const conv = conversation(input.provider, input.model);
  const store = createAppStore({ providers: [{ ...input.provider, models: [input.model] }], conversations: [conv] });
  await sendMessage({ store, appendChunk: vi.fn(), te: (key) => key }, {
    text: 'hello', prevMessages: [], conversation: conv, provider: input.provider, model: input.model,
    reasoningMode: input.reasoningMode, webSearchEnabled: input.web !== 'off',
    capabilityPreferences: { web: input.web, ...(reasoningIntent ? { reasoningIntent } : {}) },
    ...(input.attachments ? { attachments: input.attachments } : {}),
  }).done;
  return store;
}

const PDF_BYTES = Buffer.from('%PDF-1.4\n%%EOF\n', 'latin1').toString('base64');
const EXTRACTED = 'ORIVEO-PDF-MARKER-7391 extracted body';

/** A PDF with no extractable text: if the allowlist has PDF, it goes as a native file block. */
function scannedPdf(): Attachment {
  return {
    id: 'att-1', kind: 'file', fileName: 'marker.pdf', mimeType: 'application/pdf',
    originalBase64Data: PDF_BYTES,
    extractionErrorCode: 'scanned_pdf',
  } as Attachment;
}

/** A PDF with extracted text: when going native, keep a text-injection fallback version (a scanned copy has no text to fall back to). */
function textPdf(): Attachment {
  return {
    id: 'att-2', kind: 'file', fileName: 'marker.pdf', mimeType: 'application/pdf',
    originalBase64Data: PDF_BYTES, base64Data: EXTRACTED, extractedTotalLines: 1,
  } as Attachment;
}

function bodyHas(body: unknown, type: string): boolean {
  return JSON.stringify(body).includes(`"type":"${type}"`);
}

beforeEach(() => {
  localStorage.clear();
  __resetNativeFileFallbackForTest();
  upstreamCalls = [];
  upstreamReply = () => responsesSse('ok');
  vi.stubGlobal('fetch', vi.fn(fakeFetch));
});

afterEach(() => {
  vi.unstubAllGlobals();
});

describe('CAP-SUB · web search', () => {
  it('CAP-SUB-WEB-01 gpt-5.6-sol preference off -> no web_search outbound; on -> present', async () => {
    const { provider, model } = codexConnection();
    const control = presentCapabilityControl(provider, model, 'web');
    expect(control).toMatchObject({
      state: expected[SOL].web.state, availableIntents: expected[SOL].web.intents, reasonCode: expected[SOL].web.reasonCode,
    });
    expect(resolveModelControlStatus(control)).toBe(expected[SOL].web.presentation);
    expect(resolveModelOptionCapabilityShape(productionInput(provider, model, 'web', 'off')).kind).toBe('toggle');

    await sendTurn({ provider, model, reasoningMode: 'automatic', web: 'off' });
    await sendTurn({ provider, model, reasoningMode: 'automatic', web: 'automatic' });
    expect(upstreamCalls.map((call) => call.url)).toEqual([CODEX_UPSTREAM, CODEX_UPSTREAM]);
    expect(JSON.stringify(upstreamCalls[0].body)).not.toContain('web_search');
    expect(upstreamCalls[1].body.tools).toEqual(expect.arrayContaining([expect.objectContaining({ type: 'web_search' })]));
  });

  it('CAP-SUB-WEB-02 grok-4.6 decision -> alwaysOn -> Always on notice (verbatim); preference off -> outbound tools contain web_search', async () => {
    const { provider, model } = grokConnection();
    const control = presentCapabilityControl(provider, model, 'web');
    expect(control).toMatchObject({
      state: expected[GROK].web.state, availableIntents: expected[GROK].web.intents, reasonCode: expected[GROK].web.reasonCode,
    });
    expect(resolveModelControlStatus(control)).toBe(expected[GROK].web.presentation);
    expect(resolveModelOptionCapabilityShape(productionInput(provider, model, 'web', 'off'))).toEqual({
      kind: 'notice', capability: 'web', status: 'alwaysOn', body: { kind: 'subscriptionAlwaysSearches' },
    });
    expect(webTileCopy(provider, model, 'off')).toEqual({
      status: expected[GROK].webRow.status, body: expected[GROK].webRow.body, corner: 'none',
    });

    await sendTurn({ provider, model, reasoningMode: 'automatic', web: 'off' });
    expect(upstreamCalls).toHaveLength(1);
    expect(upstreamCalls[0].url).toBe(GROK_UPSTREAM);
    expect(upstreamCalls[0].body.tools).toEqual(expected[GROK].outboundToolsWithWebPreferenceOff);
  });
});

describe('CAP-SUB · reasoning', () => {
  it('CAP-SUB-REASON-01 gpt-5.6-sol intents == [low,balanced,deep,max]；balanced → medium，max → xhigh', async () => {
    const { provider, model } = codexConnection();
    expect(presentCapabilityControl(provider, model, 'reasoning').availableIntents).toEqual(expected[SOL].reasoningIntents);

    await sendTurn({ provider, model, reasoningMode: 'balanced', web: 'off' });
    await sendTurn({ provider, model, reasoningMode: 'max', web: 'off' });
    expect(upstreamCalls).toHaveLength(2);
    expect((upstreamCalls[0].body.reasoning as { effort?: string }).effort).toBe(expected[SOL].effortForIntent.balanced);
    expect((upstreamCalls[1].body.reasoning as { effort?: string }).effort).toBe(expected[SOL].effortForIntent.max);
  });

  it('CAP-SUB-REASON-02 gpt-5.6-sol automatic -> no reasoning.effort outbound', async () => {
    const { provider, model } = codexConnection();
    await sendTurn({ provider, model, reasoningMode: 'automatic', web: 'off' });
    expect(upstreamCalls).toHaveLength(1);
    expect(expected[SOL].automaticEffort).toBeNull();
    expect((upstreamCalls[0].body.reasoning as { effort?: string } | undefined)?.effort).toBeUndefined();
  });
});

describe('SUB · reasoning (non-CAP)', () => {
  it('SUB-REASON-grok_automatic_sends_declared_default grok-4.6 with no tier picked -> outbound reasoning.effort == the default marked by upstream /models', async () => {
    const { provider, model } = grokConnection();
    await sendTurn({ provider, model, reasoningMode: 'automatic', web: 'off' });
    expect(upstreamCalls).toHaveLength(1);
    expect(upstreamCalls[0].url).toBe(GROK_UPSTREAM);
    expect((upstreamCalls[0].body.reasoning as { effort?: string } | undefined)?.effort).toBe(expected[GROK].automaticEffort);
  });
});

describe('CAP-SUB · attachments', () => {
  it('CAP-SUB-ATTACH-01 Grok subscription Responses line = input_file + alwaysWithTextFallback; PDF -> outbound contains input_file', async () => {
    const { provider, model: mapped } = grokConnection();
    const model = { ...mapped, nativeFileMimes: ['application/pdf'] };
    const line = await resolveAttachmentLine({ provider, model });
    expect(line).toEqual({ transport: 'grok_subscription_responses', toolLoop: false, exact: true });
    expect(attachmentTransportProfile(line.transport)).toMatchObject(expected[GROK].fileLine);

    await sendTurn({ provider, model, reasoningMode: 'automatic', web: 'off', attachments: [scannedPdf()] });
    expect(upstreamCalls).toHaveLength(1);
    expect(bodyHas(upstreamCalls[0].body.input, 'input_file')).toBe(true);
  });

  it('CAP-SUB-ATTACH-02 upstream first request 400 before output -> resend as text once: the second request body has no input_file and contains the text injection, and succeeds', async () => {
    const { provider, model: mapped } = grokConnection();
    // A text PDF going native needs the model marked pdfNativeDefault (given only in tests like nativeFileMimes; the production path does not produce it).
    const model = { ...mapped, nativeFileMimes: ['application/pdf'], pdfNativeDefault: true };
    upstreamReply = (_call, index) => (index === 0 ? rejected() : responsesSse('fallback ok'));

    const store = await sendTurn({ provider, model, reasoningMode: 'automatic', web: 'off', attachments: [textPdf()] });
    expect(upstreamCalls).toHaveLength(2);
    expect(bodyHas(upstreamCalls[0].body.input, 'input_file')).toBe(true);
    expect(JSON.stringify(upstreamCalls[0].body.input)).not.toContain(EXTRACTED);
    expect(bodyHas(upstreamCalls[1].body.input, 'input_file')).toBe(false);
    expect(JSON.stringify(upstreamCalls[1].body.input)).toContain(EXTRACTED);
    const messages = store.getState().conversations.find((entry) => entry.id === `conv-${provider.kind}`)?.messages ?? [];
    const assistant = messages.find((message) => message.role === 'assistant');
    expect(assistant?.text).toContain('fallback ok');
    expect(assistant?.state).not.toBe('failed');
  });
});

describe('CAP-SUB · tools', () => {
  it('CAP-SUB-TOOL-01 grok-4.6 library on: the production library send orchestration outbound carries function tools', async () => {
    const { provider, model } = grokConnection();
    const conv = conversation(provider, model);
    const store = createAppStore({
      providers: [provider],
      conversations: [conv],
      libraryConnections: [{ id: 'notion-1', provider: 'notion', displayName: 'Notion', scopes: [], status: 'active' }],
    });
    await sendLibraryMessage({ store, appendChunk: vi.fn(), te: (key) => key }, {
      text: 'Find the roadmap', prevMessages: [], conversation: conv, provider, model,
      reasoningMode: 'automatic', cancelledText: 'Cancelled', errorTitle: 'Failed', errorDetail: 'Try again',
      errorDetails: {
        library_needs_reauth: 'Reconnect', library_quota_exceeded: 'Quota',
        library_rate_limited: 'Busy', library_unavailable: 'Unavailable',
      },
    }).done;

    expect(upstreamCalls.length).toBeGreaterThanOrEqual(1);
    expect(upstreamCalls[0].url).toBe(GROK_UPSTREAM);
    const tools = upstreamCalls[0].body.tools as Array<{ type: string; name?: string }>;
    expect(tools.some((tool) => tool.type === 'function')).toBe(true);
  });
});
