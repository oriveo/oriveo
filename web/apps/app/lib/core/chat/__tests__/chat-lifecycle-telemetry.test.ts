// @vitest-environment jsdom
//
// Property contract regression for chat lifecycle telemetry.
//
// Runs the real sendMessage -> prepareSendStart -> runStreamPipeline -> reportSendCompletion /
// catch chain, mocking only the network layer and external side effects, and asserts against the
// props objects production code actually produces rather than hand-built events.
//
// Pinned behavior:
//   1. sent / completed / failed always carry provider_kind + model_id, and failed always carries
//      error_code;
//   2. for relay, completed / failed carry the same relay_url + relay_protocol as sent;
//   3. capability execution facts never appear in the rich properties (requested / observed /
//      unconfirmed / rejected, recipe identity and content, custom fragment owner/path/value,
//      response evidence, raw error bodies);
//   4. the Sentry suppression gate uses the same "non-empty counts as an execution fact" rule:
//      stream-runner attaches capabilityResults to every stream error, even an empty array, so a
//      presence check would silence all ordinary failures too.

import { beforeEach, describe, expect, it, vi } from 'vitest';
import type { AIModel, ChatMessage, Conversation, Provider } from '@oriveo/shared';
import { createAppStore } from '../../store/app-store';
import { continueAnswering, sendMessage } from '../operations';

const mocks = vi.hoisted(() => ({
  sendStream: vi.fn(),
  buildChatHistory: vi.fn(),
  readStream: vi.fn(),
  processImageAttachments: vi.fn(),
  enqueueUsageEvent: vi.fn(),
  checkBudgetExceeded: vi.fn(),
  trackEvent: vi.fn(),
  captureException: vi.fn(),
  // The only input to "can the web-search preference reach the wire right now": a capability
  // runtime with a web recipe. undefined by default means this metadata has no automatic web
  // configuration, so the preference compiles to no fields at all.
  capabilityRuntime: undefined as unknown,
}));

vi.mock('../../providers/service', () => ({
  sendStream: (...args: unknown[]) => mocks.sendStream(...args),
}));

vi.mock('../../../utils/chat-stream-utils', () => ({
  buildChatHistory: (...args: unknown[]) => mocks.buildChatHistory(...args),
  readStream: (...args: unknown[]) => mocks.readStream(...args),
  mapErrorKindKey: () => 'network',
  sanitizeOutboundMessages: (msgs: unknown[]) => msgs,
}));

vi.mock('../../../utils/stream-image-utils', () => ({
  processImageAttachments: (...args: unknown[]) => mocks.processImageAttachments(...args),
  backfillStorageRefs: vi.fn(),
}));

vi.mock('../../usage/usage-reporter', () => ({
  enqueueUsageEvent: (...args: unknown[]) => mocks.enqueueUsageEvent(...args),
}));

vi.mock('../../usage/budget-check', () => ({
  checkBudgetExceeded: (...args: unknown[]) => mocks.checkBudgetExceeded(...args),
}));

vi.mock('../../sync-port', () => ({
  getSyncAdapter: () => undefined,
  deleteAttachments: vi.fn(),
}));

vi.mock('../../infra/storage/partition', () => ({
  getActiveUID: vi.fn(),
}));

vi.mock('../../skills/knowledge-api', () => ({
  retrieveKnowledgeSnippets: vi.fn(),
}));

vi.mock('@sentry/nextjs', () => ({
  captureException: (...args: unknown[]) => mocks.captureException(...args),
}));

//  telemetryProviderKind / sanitizeTelemetryURL  
//  relay_url  
vi.mock('../../telemetry', async (importOriginal) => ({
  ...(await importOriginal<typeof import('../../telemetry')>()),
  trackEvent: (...args: unknown[]) => mocks.trackEvent(...args),
}));

// Partial mock: keep the real exports (buildProviderStreamOptions needs the relay runtime config)
// and only make catalog lookups return empty, so a fixture without metadata does not throw across
// the whole send path.
vi.mock('../../metadata/metadata-client', async () => {
  const actual = await vi.importActual<typeof import('../../metadata/metadata-client')>(
    '../../metadata/metadata-client',
  );
  return {
    ...actual,
    resolveCatalogModel: vi.fn(() => null),
    getCapabilityRuntime: () => mocks.capabilityRuntime,
  };
});

/** Capability runtime including a web recipe; only with it does the `web` control resolve to auto_available. */
const webCapabilityRuntime = {
  schemaVersion: 2,
  revision: 'web-search-wire-test',
  generatedAt: '2026-08-24T00:00:00Z',
  recipes: { 'fixture.web': { id: 'fixture.web' } },
  controlDefinitions: {},
  sourceIndex: {},
};

const capabilityContext = {
  version: 1 as const,
  revision: 'lifecycle-telemetry-test',
  entries: [{
    owner: 'web' as const,
    source: 'provider_recipe' as const,
    wireApplied: true,
    protocol: 'openai_chat',
    responseParserKind: 'openai_proxy_sse',
    definition: {
      capability: 'web' as const,
      protocol: 'openai_chat',
      responseParserKind: 'openai_proxy_sse',
      signals: [{ producerEvent: 'citations' as const, pointer: '/choices/*/delta/annotations', nonEmpty: true as const }],
    },
  }],
};

function makeOfficialProvider(overrides: Partial<Provider> = {}): Provider {
  return {
    id: 'p-openai',
    kind: 'openAI',
    status: { kind: 'connected' },
    models: [],
    catalogModels: [],
    apiKey: 'sk-test',
    apiKeyPreview: '••test',
    ...overrides,
  };
}

function makeRelayProvider(overrides: Partial<Provider> = {}): Provider {
  return {
    id: 'relay-1',
    kind: 'relay',
    status: { kind: 'connected' },
    models: [],
    catalogModels: [],
    apiKey: 'sk-relay',
    apiKeyPreview: '••relay',
    // userinfo and query must be redacted: relays commonly put the token in one of those two places.
    baseURLText: 'https://user:pass@relay.example.com:8443/v1?key=secret',
    relayResolvedBaseURLText: 'https://user:pass@relay.example.com:8443/v1?key=secret',
    relayResolvedTransport: 'anthropic_messages',
    relayResolvedAuthMode: 'bearer',
    relayRequested: { transport: 'anthropic_messages', authMode: 'bearer', stream: true },
    ...overrides,
  };
}

function makeModel(overrides: Partial<AIModel> = {}): AIModel {
  return {
    id: 'gpt-4o',
    name: 'GPT-4o',
    capabilities: ['text'],
    reasoningModeAvailable: false,
    isAvailable: true,
    isDefault: true,
    priceTier: '$',
    promptPrice: 0.001,
    completionPrice: 0.002,
    ...overrides,
  };
}

function makeConversation(provider: Provider, overrides: Partial<Conversation> = {}): Conversation {
  const seed: ChatMessage = {
    id: 'm-assistant-0', role: 'assistant', text: 'previous',
    providerID: provider.id, providerKind: provider.kind, providerName: 'Seed',
    modelID: 'gpt-4o', modelName: 'GPT-4o', estimatedCost: 0, state: 'delivered',
  };
  return {
    id: 'conv-1',
    title: 'Chat',
    hasCustomTitle: false,
    providerID: provider.id,
    providerKind: provider.kind,
    modelID: 'gpt-4o',
    previewText: '',
    estimatedCost: 0,
    isDraft: false,
    messages: [seed],
    draftText: '',
    createdAt: '2026-08-24T00:00:00.000Z',
    updatedAt: '2026-08-24T00:00:00.000Z',
    ...overrides,
  };
}

/** Props of the single call for an event, which also pins down that there is no second bare event of the same name. */
function propsOf(event: string): Record<string, unknown> {
  const calls = mocks.trackEvent.mock.calls.filter(([name]) => name === event);
  expect(calls).toHaveLength(1);
  const props = calls[0]![1];
  // A bare event (props undefined) is the target here: the dashboard then shows only super props and no dimensions at all.
  expect(props).toBeDefined();
  return props as Record<string, unknown>;
}

/** No field name or value of a capability execution fact may appear in lifecycle telemetry. */
function expectNoCapabilityFacts(props: Record<string, unknown>): void {
  for (const key of Object.keys(props)) {
    expect(key).not.toMatch(/capabilit|recipe|fragment|evidence|revision|signals|parser|wire_applied/i);
  }
  const serialized = JSON.stringify(props);
  expect(serialized).not.toMatch(/"(requested|observed|unconfirmed|rejected|recovered)"/);
  expect(serialized).not.toMatch(/lifecycle-telemetry-test/);
  expect(serialized).not.toMatch(/openai_proxy_sse/);
}

async function send(provider: Provider, model: AIModel, webSearchEnabled?: boolean) {
  const conversation = makeConversation(provider);
  const store = createAppStore({ providers: [provider], conversations: [conversation] });
  await sendMessage(
    { store, appendChunk: vi.fn(), te: (key: string) => key },
    {
      text: 'hello', prevMessages: conversation.messages, conversation, provider, model,
      reasoningMode: 'automatic',
      ...(webSearchEnabled === undefined ? {} : { webSearchEnabled }),
    },
  ).done;
}

beforeEach(() => {
  vi.clearAllMocks();
  mocks.capabilityRuntime = undefined;
  mocks.buildChatHistory.mockResolvedValue([{ role: 'user', content: 'hello' }]);
  //   P5 wire fact 
  mocks.sendStream.mockReturnValue({
    stream: {} as ReadableStream,
    abort: vi.fn(),
    getCapabilityResultContext: () => capabilityContext,
    capabilityResultContextReady: Promise.resolve(capabilityContext),
  });
  mocks.readStream.mockResolvedValue({
    fullText: 'Hello there',
    reasoningText: '',
    usage: { prompt_tokens: 10, completion_tokens: 5, total_tokens: 15 },
    imageAttachments: [],
    servedModelID: 'gpt-4o',
    citations: undefined,
  });
  mocks.processImageAttachments.mockResolvedValue({
    finalText: 'Hello there',
    processedAttachments: [],
  });
  mocks.enqueueUsageEvent.mockResolvedValue(undefined);
});

describe('chat lifecycle telemetry property contract', () => {
  it('official provider: sent / completed still carry provider_kind + model_id even when the stream exposes execution facts', async () => {
    await send(makeOfficialProvider(), makeModel());

    const sent = propsOf('chat_message_sent');
    expect(sent).toMatchObject({ provider_kind: 'openai', model_id: 'gpt-4o' });
    const completed = propsOf('chat_message_completed');
    expect(completed).toMatchObject({ provider_kind: 'openai', model_id: 'gpt-4o' });
    expect(completed.latency_ms).toBeTypeOf('number');
    expect(completed.cost_usd_micros).toBeTypeOf('number');
    //   relay  
    expect(sent.relay_url).toBeUndefined();
    expect(completed.relay_url).toBeUndefined();
    expectNoCapabilityFacts(sent);
    expectNoCapabilityFacts(completed);

    // The execution facts written onto the message are unchanged: local visibility does not depend
    // on where the telemetry boundary sits.
    expect(mocks.trackEvent).not.toHaveBeenCalledWith('chat_message_failed', expect.anything());
  });

  it('official provider failure: failed carries provider_kind / model_id / error_code / latency_ms and no error body', async () => {
    mocks.readStream.mockRejectedValueOnce(
      Object.assign(new Error('upstream body must remain local'), { kind: 'rate_limited', source: 'provider' }),
    );

    await send(makeOfficialProvider(), makeModel());

    const failed = propsOf('chat_message_failed');
    expect(failed).toMatchObject({
      provider_kind: 'openai',
      model_id: 'gpt-4o',
      error_code: 'rate_limited',
    });
    expect(failed.latency_ms).toBeTypeOf('number');
    expect(JSON.stringify(failed)).not.toMatch(/upstream body must remain local/);
    expectNoCapabilityFacts(failed);
    //   sent  
    expect(propsOf('chat_message_sent')).toMatchObject({ provider_kind: 'openai', model_id: 'gpt-4o' });
  });

  it('relay success: completed carries the same redacted relay_url / relay_protocol as sent', async () => {
    await send(makeRelayProvider(), makeModel());

    const sent = propsOf('chat_message_sent');
    const completed = propsOf('chat_message_completed');
    expect(sent).toMatchObject({
      provider_kind: 'relay',
      model_id: 'custom',
      relay_url: 'https://relay.example.com:8443/v1',
      relay_protocol: 'anthropic_messages',
    });
    expect(completed.relay_url).toBe(sent.relay_url);
    expect(completed.relay_protocol).toBe(sent.relay_protocol);
    // The served model reported by the upstream also comes from the user's private catalog and must be reduced as well.
    expect(completed).toMatchObject({ provider_kind: 'relay', model_id: 'custom', served_model_id: 'custom' });
    // Credentials never reach telemetry: userinfo and query are stripped by the same redaction function.
    for (const props of [sent, completed]) {
      expect(JSON.stringify(props)).not.toMatch(/pass|secret/);
    }
    expectNoCapabilityFacts(completed);
  });

  it('relay image generation: image_generated reduces model_id to custom as well', async () => {
    mocks.processImageAttachments.mockResolvedValueOnce({
      finalText: 'Hello there',
      processedAttachments: [{ id: 'img-1', kind: 'image', fileName: 'a.png', mimeType: 'image/png', localImageID: 'l1' }],
    });

    await send(makeRelayProvider(), makeModel());

    expect(propsOf('image_generated')).toMatchObject({ provider_kind: 'relay', model_id: 'custom' });
  });

  it('relay failure: failed also carries relay_url / relay_protocol, so the relay address does not vanish from the dashboard', async () => {
    mocks.readStream.mockRejectedValueOnce(
      Object.assign(new Error('relay 502 body'), { kind: 'server_error', source: 'provider' }),
    );

    await send(makeRelayProvider(), makeModel());

    const sent = propsOf('chat_message_sent');
    const failed = propsOf('chat_message_failed');
    expect(failed).toMatchObject({
      provider_kind: 'relay',
      model_id: 'custom',
      error_code: 'server_error',
      relay_url: 'https://relay.example.com:8443/v1',
      relay_protocol: 'anthropic_messages',
    });
    expect(failed.relay_url).toBe(sent.relay_url);
    expect(failed.relay_protocol).toBe(sent.relay_protocol);
    expect(JSON.stringify(failed)).not.toMatch(/relay 502 body|pass|secret/);
    expectNoCapabilityFacts(failed);
  });
});

describe('web_search_used - an outbound fact, not a user intent', () => {
  const webReadyModel = () => makeModel({
    capabilities: ['text', 'web'],
    capabilityControls: { web: { state: 'auto_available', recipeRef: 'fixture.web' } },
  } as Partial<AIModel>);

  it('web search really reached the request: exactly one event, with only provider_kind + model_id', async () => {
    mocks.capabilityRuntime = webCapabilityRuntime;

    await send(makeOfficialProvider(), webReadyModel(), true);

    // propsOf also pins down "one event per send": duplicate emissions would inflate the usage dashboard.
    expect(propsOf('web_search_used')).toEqual({ provider_kind: 'openai', model_id: 'gpt-4o' });
  });

  it('the toggle is on but this metadata has no automatic web configuration: nothing is reported', async () => {
    // No capabilityRuntime, so the control does not resolve to auto_available and the preference compiles to no outbound field.
    await send(makeOfficialProvider(), webReadyModel(), true);

    expect(mocks.trackEvent).not.toHaveBeenCalledWith('web_search_used', expect.anything());
    //   sent  
    expect(propsOf('chat_message_sent')).toMatchObject({ web_search_enabled: true });
  });

  it('does not report when web search is off (a false intent never reaches the gate)', async () => {
    mocks.capabilityRuntime = webCapabilityRuntime;

    await send(makeOfficialProvider(), webReadyModel(), false);

    expect(mocks.trackEvent).not.toHaveBeenCalledWith('web_search_used', expect.anything());
  });

  /** Continuation uses the separate operations-continue outbound path; the gate must be the same as sendMessage's. */
  async function continueWithWebSearch(webSearchEnabled: boolean) {
    const provider = makeOfficialProvider();
    const user: ChatMessage = {
      id: 'u-1', role: 'user', text: 'question', state: 'delivered',
      providerID: provider.id, providerKind: provider.kind, providerName: 'OpenAI',
      modelID: 'gpt-4o', modelName: 'GPT-4o', estimatedCost: 0,
    };
    const interrupted: ChatMessage = {
      id: 'a-1', role: 'assistant', text: 'partial', state: 'interrupted',
      providerID: provider.id, providerKind: provider.kind, providerName: 'OpenAI',
      modelID: 'gpt-4o', modelName: 'GPT-4o', estimatedCost: 0,
    };
    const conversation = makeConversation(provider, { messages: [user, interrupted] });
    const store = createAppStore({ providers: [provider], conversations: [conversation] });
    await continueAnswering(
      { store, appendChunk: vi.fn(), te: (key: string) => key },
      {
        messageId: interrupted.id, conversation, messages: [user, interrupted],
        provider, model: webReadyModel(), reasoningMode: 'automatic', webSearchEnabled,
      },
    ).done;
  }

  it('the continuation path is a real outbound too: exactly one event when web search runs', async () => {
    mocks.capabilityRuntime = webCapabilityRuntime;

    await continueWithWebSearch(true);

    expect(propsOf('web_search_used')).toEqual({ provider_kind: 'openai', model_id: 'gpt-4o' });
  });

  it('the continuation path reports nothing when web search never ran (same rule as the first send)', async () => {
    // With no capability runtime, the continuation's outbound options carry no supportsWebSearch either.
    await continueWithWebSearch(true);

    expect(mocks.trackEvent).not.toHaveBeenCalledWith('web_search_used', expect.anything());
  });

  it('relay web search is custom_only: nothing is reported without a local custom field override', async () => {
    mocks.capabilityRuntime = webCapabilityRuntime;

    await send(makeRelayProvider(), webReadyModel(), true);

    expect(mocks.trackEvent).not.toHaveBeenCalledWith('web_search_used', expect.anything());
  });
});

describe('Sentry suppression gate on the failure path', () => {
  // Only upstream faults that are Oriveo's own responsibility pass shouldReportProviderError; provider and network faults are always dropped.
  const reportableError = () =>
    Object.assign(new Error('oriveo owned failure'), { kind: 'upstream', source: 'oriveo' });

  it('an ordinary failure with no capability execution facts is still reported to Sentry', async () => {
    // No capability context exposed, so stream-runner attaches an empty array, which is not an execution fact.
    mocks.sendStream.mockReturnValue({ stream: {} as ReadableStream, abort: vi.fn() });
    mocks.readStream.mockRejectedValueOnce(reportableError());

    await send(makeOfficialProvider(), makeModel());

    expect(mocks.captureException).toHaveBeenCalledTimes(1);
  });

  it('a failure carrying non-empty capability execution facts stays suppressed', async () => {
    // The sendStream from beforeEach exposes a non-empty recipe -> requested record for wireApplied.
    mocks.readStream.mockRejectedValueOnce(reportableError());

    await send(makeOfficialProvider(), makeModel());

    expect(mocks.captureException).not.toHaveBeenCalled();
    //   Sentry 
    expect(propsOf('chat_message_failed')).toMatchObject({ provider_kind: 'openai', error_code: 'upstream' });
  });
});
