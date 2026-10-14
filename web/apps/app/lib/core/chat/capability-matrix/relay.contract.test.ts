// @vitest-environment jsdom
//
// Capability matrix: relay shape (RELAY x web search / reasoning / attachments / tools).
// Assertions look at the request body captured via transport by the production option builder buildProviderStreamOptions -> the production relay send entry sendRelayStream.

import 'fake-indexeddb/auto';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { AIModel, Attachment, ChatMessage, Provider, RelayRequestedConfig } from '@oriveo/shared';
import { sendRelayStream, type RelayOrchestratorDeps } from '@oriveo/core/providers/relay-orchestrator';
import type { CapabilityPreferenceInput } from '@oriveo/core/providers/request-builders/types';
import { ToolRegistry } from '@oriveo/core/tools/tool-registry';
import type { StreamEvent, StreamOptions } from '../../providers/types';

// ATTACH-01 needs a Relay model that hits "official catalog transport_first": only the cross-vendor match query is replaced, the rest of metadata uses the real implementation.
const catalogMatch = vi.hoisted(() => ({ next: null as unknown }));
vi.mock('../../metadata/metadata-client', async (importOriginal) => {
  const mod = await importOriginal<typeof import('../../metadata/metadata-client')>();
  return {
    ...mod,
    resolveCatalogModelAcrossProvidersWithProvider: (...args: Parameters<typeof mod.resolveCatalogModelAcrossProvidersWithProvider>) => {
      if (catalogMatch.next) {
        const value = catalogMatch.next;
        catalogMatch.next = null;
        return value as ReturnType<typeof mod.resolveCatalogModelAcrossProvidersWithProvider>;
      }
      return mod.resolveCatalogModelAcrossProvidersWithProvider(...args);
    },
  };
});

import { __resetMetadataClientForTest, DEFAULT_RELAY_RUNTIME_CONFIG, lookupModelFamilyByModel } from '../../metadata/metadata-client';
import { buildProviderStreamOptions, buildStreamOptionsFromIntent, filterRequestCapabilityIntent } from '../stream-options';
import { RELAY_WEB_FRAGMENTS_STORAGE_KEY, saveRelayWebFragment } from '../relay-web-fragments';
import { RELAY_WEB_FRAGMENT_TEMPLATES } from '@oriveo/shared/relay/web-fragments';
import { relayCapabilityTestStreamOptions } from '../../relay-capability-test-ops';
import { presentCapabilityControl } from '../capability-control-presentation';
import { additionalBodyScope, withAdditionalBody } from '../additional-body-settings';
import { writeChatTemplateThinking } from '../chat-template-thinking';
import { enrichRelayLocalModel } from '../../providers/relay-official-catalog-match';
import { buildOutboundChatHistory } from '../outbound-history';
import { sendStream } from '../../providers/service';
import { sendLibraryAgentLeg } from '../../providers/proxy-client';
import { __resetNativeFileFallbackForTest, sendWithNativeFileFallback } from '../../attachments/native-file-fallback';
import { createAppStore } from '../../store/app-store';
import { resolveAttachmentCapabilities, withoutUnreceivableImages } from '../attachment-policy';
import { recordToolCallFallback, sendWithRelayRejectionLoop, toolCallRememberedUnsupported } from '../relay-rejection-loop';
import { createRelayManualModel } from '../../provider-model-ops';
import {
  beginCapabilityEvidenceIdentityIfAbsent,
  resetCapabilityEvidenceIdentitiesForTesting,
} from '../../providers/capability-evidence-identity';
import { getActiveUIDSync } from '../../../infra/storage/partition';
import type { ToolCallRecoveryIdentity } from '../capability-recovery-runtime';

function relayProvider(id: string, requested: Partial<RelayRequestedConfig>): Provider {
  return {
    id,
    kind: 'relay',
    status: { kind: 'connected' },
    models: [],
    catalogModels: [],
    apiKey: 'sk-relay',
    apiKeyPreview: 'sk-…',
    baseURLText: 'https://relay.example',
    relayRequested: {
      authMode: 'bearer',
      securityMode: 'remote_https',
      resolvedAPIBaseURL: 'https://relay.example/v1',
      ...requested,
    },
  } as unknown as Provider;
}

function relayModel(overrides: Partial<AIModel> = {}): AIModel {
  return {
    id: 'relay-model',
    name: 'relay-model',
    capabilities: ['text'],
    reasoningModeAvailable: false,
    isAvailable: true,
    isDefault: false,
    priceTier: '',
    ...overrides,
  } as AIModel;
}

async function outboundBody(provider: Provider, model: AIModel, options?: StreamOptions): Promise<Record<string, unknown>> {
  const streamOptions = buildProviderStreamOptions(provider, options, model);
  let captured: Record<string, unknown> | undefined;
  const deps: RelayOrchestratorDeps = {
    transport: {
      fetch: async (_url, init) => {
        captured = JSON.parse(String(init.body)) as Record<string, unknown>;
        return new Response(JSON.stringify({ choices: [{ message: { content: 'ok' } }] }), { status: 200 });
      },
    },
    buildFetchArgs: (url, headers) => ({ url, headers }),
    getRelayRuntimeConfig: () => null,
  };
  const handle = sendRelayStream(provider.apiKey, model.id, [{ role: 'user', content: 'hello' }], provider.baseURLText, {
    ...streamOptions,
    relayStream: false,
  }, deps);
  await handle.stream.getReader().read();
  expect(captured, 'the production relay send path made no request').toBeDefined();
  return captured!;
}

const WEB_FIELDS = ['web_search_options', 'plugins', 'enable_search', 'googleSearch', 'google_search'];

function webToolsOf(body: Record<string, unknown>): unknown[] {
  const tools = Array.isArray(body.tools) ? body.tools as Array<Record<string, unknown>> : [];
  return tools.filter((tool) => typeof tool.type === 'string' && tool.type.startsWith('web_search')
    || 'googleSearch' in tool || 'google_search' in tool);
}

beforeEach(() => {
  localStorage.clear();
  __resetMetadataClientForTest();
  resetCapabilityEvidenceIdentitiesForTesting();
  __resetNativeFileFallbackForTest();
  catalogMatch.next = null;
});

afterEach(() => {
  localStorage.clear();
  __resetMetadataClientForTest();
  resetCapabilityEvidenceIdentitiesForTesting();
  vi.unstubAllGlobals();
});

/** The chat web switch is on (the web intent after the outbound gate). */
const WEB_ON = { supportsWebSearch: true } as StreamOptions;

describe('RELAY x web search (chat switch + effective fragment)', () => {
  it('CAP-RELAY-WEB-01 fragment stored -> with the switch on, the production path request body merges the fragment per mergeCases; with it off, nothing is carried', async () => {
    const chat = relayProvider('relay-web-01', { transport: 'openai_chat_completions' });
    expect(saveRelayWebFragment(chat.id, 'openai_chat_completions', '{"plugins":[{"id":"web","max_results":5}]}').ok).toBe(true);
    const chatBody = await outboundBody(chat, relayModel(), WEB_ON);
    expect(chatBody.plugins).toEqual([{ id: 'web', max_results: 5 }]);
    expect(chatBody.model).toBe('relay-model');
    expect(await outboundBody(chat, relayModel(), { supportsWebSearch: false })).not.toHaveProperty('plugins');

    const responses = relayProvider('relay-web-01b', { transport: 'openai_responses' });
    expect(saveRelayWebFragment(responses.id, 'openai_responses', '{"tools":[{"type":"web_search"}]}').ok).toBe(true);
    const responsesBody = await outboundBody(responses, relayModel(), WEB_ON);
    // tools are appended after the builder's own tools.
    expect(responsesBody.tools).toEqual([{ type: 'image_generation' }, { type: 'web_search' }]);
  });

  it('CAP-RELAY-WEB-02 no stored fragment and no legacy field: switch off -> no web search fields at all; switch on -> only the template of that protocol (even when the model inherits the official web profile)', async () => {
    const inherited = relayModel({ capabilities: ['text', 'web'], webSearchProfile: 'oai_responses_web' });
    const wantsWeb: StreamOptions = { supportsWebSearch: true, capabilityPreferences: { web: 'automatic' } } as StreamOptions;
    const noWeb: StreamOptions = { supportsWebSearch: false, capabilityPreferences: { web: 'off' } } as StreamOptions;
    for (const transport of ['openai_responses', 'gemini_generate_content', 'openai_chat_completions', 'anthropic_messages'] as const) {
      const off = await outboundBody(relayProvider(`relay-web-02-${transport}`, { transport }), inherited, noWeb);
      expect(webToolsOf(off), transport).toEqual([]);
      for (const field of WEB_FIELDS) expect(off, `${transport}.${field}`).not.toHaveProperty(field);

      const on = await outboundBody(relayProvider(`relay-web-02-${transport}`, { transport }), inherited, wantsWeb);
      const template = RELAY_WEB_FRAGMENT_TEMPLATES[transport] as Record<string, unknown>;
      for (const [key, value] of Object.entries(template)) {
        if (Array.isArray(value)) {
          expect(on[key], `${transport}.${key}`).toEqual(expect.arrayContaining(value));
          // Only the template's web tool is present; the official web profile is not injected on top.
          expect(webToolsOf(on).length, transport).toBe(value.length);
        } else {
          expect(on[key], `${transport}.${key}`).toEqual(value);
        }
      }
    }
  });

  it('CAP-RELAY-WEB-03 legacy connection hasWebSearch=true, no profile, Responses -> request body same as the template, and the stored connection config is not rewritten', async () => {
    const provider = relayProvider('relay-web-03', { transport: 'openai_responses', hasWebSearch: true });
    const before = structuredClone(provider.relayRequested);
    const body = await outboundBody(provider, relayModel(), WEB_ON);
    expect(body.tools).toEqual([{ type: 'image_generation' }, { type: 'web_search' }]);
    expect(provider.relayRequested).toEqual(before);
    expect(localStorage.getItem(RELAY_WEB_FRAGMENTS_STORAGE_KEY)).toBeNull();
  });

  it('test-capability requests do not carry the connection-level fragment', () => {
    const provider = relayProvider('relay-web-test', { transport: 'openai_chat_completions' });
    saveRelayWebFragment(provider.id, 'openai_chat_completions', '{"web_search_options":{}}');
    expect(buildProviderStreamOptions(provider, WEB_ON, relayModel())?.relayWebFragment).toEqual({ web_search_options: {} });
    expect(relayCapabilityTestStreamOptions(provider, relayModel(), 'toolCall').relayWebFragment).toBeUndefined();
  });

  it('local engine connections do not read the fragment', () => {
    const provider = relayProvider('relay-web-local', { transport: 'openai_chat_completions', engineProfile: 'ollama' });
    saveRelayWebFragment(provider.id, 'openai_chat_completions', '{"web_search_options":{}}');
    expect(buildProviderStreamOptions(provider, WEB_ON, relayModel())?.relayWebFragment).toBeUndefined();
  });
});

/* -- reasoning / attachments / tools -- */

/** by-model view: put model-facts tiers into the production cache (family path when the relay has no official catalog match). */
async function seedByModelFacts(modelID: string, reasoningEfforts: string[]): Promise<void> {
  vi.stubGlobal('fetch', vi.fn(async () => new Response(JSON.stringify({
    data: { revision: 'r1', byModel: { [modelID]: { family: 'google', providerKind: 'gemini', facts: { reasoningEfforts } } } },
  }), { status: 200 })));
  expect(await lookupModelFamilyByModel(modelID)).toBe('google');
  vi.unstubAllGlobals();
}

/** Production intent chain for chat sends: panel preference -> final outbound gate -> outbound options (same order as operations-send). */
function intentOptions(provider: Provider, model: AIModel, preferences: CapabilityPreferenceInput): StreamOptions | undefined {
  const preliminary = buildProviderStreamOptions(provider, buildStreamOptionsFromIntent(model, 'automatic', false, undefined, preferences), model);
  const intent = filterRequestCapabilityIntent({
    provider, model, reasoningMode: 'automatic', webSearchEnabled: false, streamOptions: preliminary,
  });
  return buildStreamOptionsFromIntent(model, intent.reasoning, intent.supportsWebSearch, undefined, intent.capabilityPreferences);
}

function connected(provider: Provider): Provider {
  beginCapabilityEvidenceIdentityIfAbsent(getActiveUIDSync(), provider.id);
  return provider;
}

const PDF = 'application/pdf';
const RAW_PDF = 'JVBERi0xLjQKb3JpdmVv';
const textPdf = { id: 'report.pdf', kind: 'file', fileName: 'report.pdf', mimeType: PDF, originalBase64Data: RAW_PDF, base64Data: 'EXTRACTED-BODY-TEXT', extractedTotalLines: 1 } as Attachment;
const imageAttachment = { id: 'img-1', kind: 'image', mimeType: 'image/png', base64Data: 'iVBORw0KGgoORIVEOIMAGE' } as Attachment;

function userMessage(attachments: Attachment[]): ChatMessage {
  return {
    id: 'u1', role: 'user', text: 'Look', providerKind: 'relay', providerName: 'Relay', modelName: 'm',
    estimatedCost: 0, state: 'delivered', createdAt: '2026-10-12T00:00:00Z', attachments,
  } as ChatMessage;
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

/** Fake relay: replies in order and records every request body. */
function stubUpstream(responders: Array<() => Response>): string[] {
  const bodies: string[] = [];
  vi.stubGlobal('fetch', vi.fn(async (_input: unknown, init?: RequestInit) => {
    bodies.push(typeof init?.body === 'string' ? init.body : '');
    const next = responders.shift();
    return next ? next() : new Response('not found', { status: 404 });
  }));
  return bodies;
}

const reject400 = () => new Response(JSON.stringify({ error: { message: 'upstream said no' } }), {
  status: 400, headers: { 'Content-Type': 'application/json' },
});
const anthropicOk = () => new Response([
  { type: 'message_start', message: { id: 'm', model: 'claude', usage: { input_tokens: 1, output_tokens: 0 } } },
  { type: 'content_block_start', index: 0, content_block: { type: 'text', text: '' } },
  { type: 'content_block_delta', index: 0, delta: { type: 'text_delta', text: 'ANSWER' } },
  { type: 'content_block_stop', index: 0 },
  { type: 'message_stop' },
].map((frame) => `event: ${frame.type}\ndata: ${JSON.stringify(frame)}\n\n`).join(''), {
  status: 200, headers: { 'Content-Type': 'text/event-stream' },
});

describe('RELAY x reasoning (model-facts tiers)', () => {
  it('CAP-RELAY-REASON-01 gemini-2.5-pro with model-facts low/medium/high/xhigh picking max -> request body thinkingBudget = 24576', async () => {
    await seedByModelFacts('gemini-2.5-pro', ['low', 'medium', 'high', 'xhigh']);
    const provider = connected(relayProvider('relay-reason-01', { transport: 'gemini_generate_content' }));
    const model = relayModel({ id: 'gemini-2.5-pro', name: 'gemini-2.5-pro' });
    const control = presentCapabilityControl(provider, model, 'reasoning');
    expect(control.state).toBe('auto_available');
    expect(control.availableIntents).toEqual(['automatic', 'low', 'balanced', 'deep', 'max']);
    const body = await outboundBody(provider, model, intentOptions(provider, model, { web: 'off', reasoningIntent: 'max' }));
    expect((body.generationConfig as { thinkingConfig?: { thinkingBudget?: number } }).thinkingConfig?.thinkingBudget).toBe(24576);
  });

  it('with model-facts tiers and the preference at default (automatic) -> the production request body has no reasoning fields, byte-identical to the no-tier case', async () => {
    const provider = connected(relayProvider('relay-reason-default', { transport: 'gemini_generate_content' }));
    const model = relayModel({ id: 'gemini-2.5-pro', name: 'gemini-2.5-pro' });
    const without = await outboundBody(provider, model, intentOptions(provider, model, { web: 'off' }));
    await seedByModelFacts('gemini-2.5-pro', ['low', 'medium', 'high', 'xhigh']);
    expect(presentCapabilityControl(provider, model, 'reasoning').availableIntents[0]).toBe('automatic');
    const body = await outboundBody(provider, model, intentOptions(provider, model, { web: 'off' }));
    expect(body.generationConfig).toBeUndefined();
    expect(JSON.stringify(body)).toBe(JSON.stringify(without));
  });

  it('CAP-RELAY-REASON-02 Chat protocol, no model-facts -> after turning on the template switch the request body has chat_template_kwargs.enable_thinking = true, other fields unchanged', async () => {
    const provider = connected(relayProvider('relay-reason-02', { transport: 'openai_chat_completions' }));
    const model = relayModel({ id: 'qwen3-local' });
    const control = presentCapabilityControl(provider, model, 'reasoning');
    expect(control.state).not.toBe('auto_available');
    expect(control.availableIntents).toEqual([]);
    const scope = additionalBodyScope(provider, model);
    const send = () => outboundBody(provider, model, withAdditionalBody(
      buildProviderStreamOptions(provider, intentOptions(provider, model, { web: 'off' }), model), { provider, model },
    ));
    const before = await send();
    expect(writeChatTemplateThinking(true, scope)).toBe(true);
    const after = await send();
    expect(after.chat_template_kwargs).toEqual({ enable_thinking: true });
    const { chat_template_kwargs: _kwargs, ...rest } = after;
    expect(rest).toEqual(before);
  });
});

describe('RELAY x attachments', () => {
  it('CAP-RELAY-ATTACH-01 a Messages model whose protocol source is observed inherits the PDF allowlist -> request body contains "type":"document"', async () => {
    catalogMatch.next = {
      matchedProviderKind: 'anthropic', canonicalModelId: 'claude-sonnet-4.5', source: 'transport_first',
      metadata: {
        canonicalModelId: 'claude-sonnet-4.5', displayName: 'Claude Sonnet 4.5', pricingStatus: 'unknown',
        capabilities: ['text', 'image', 'file'], pricing: null, profiles: {},
        nativeFileMimes: [PDF], pdfNativeDefault: true,
      },
    };
    const model = enrichRelayLocalModel(
      relayModel({ id: 'claude-sonnet-4.5', relayTransport: 'anthropic_messages', relayTransportSource: 'observed' }),
      'anthropic_messages', DEFAULT_RELAY_RUNTIME_CONFIG,
    );
    expect(model.nativeFileMimes).toEqual([PDF]);
    const provider = connected(relayProvider('relay-attach-01', { transport: 'anthropic_messages' }));
    const options = buildProviderStreamOptions(provider, undefined, model);
    const history = await buildOutboundChatHistory({}, { messages: [userMessage([textPdf])], provider, model, streamOptions: options });
    const bodies = stubUpstream([anthropicOk]);
    await drain(sendStream(provider.kind, provider.apiKey, model.id, history, provider.baseURLText, options).stream);
    expect(bodies[0]).toContain('"type":"document"');
  });

  it('CAP-RELAY-ATTACH-02 upstream rejects the document with 400 before any output -> resend as text once', async () => {
    const model = relayModel({ id: 'claude-relay', relayTransport: 'anthropic_messages', relayTransportSource: 'observed', nativeFileMimes: [PDF], pdfNativeDefault: true, capabilities: ['text', 'file'] });
    const provider = connected(relayProvider('relay-attach-02', { transport: 'anthropic_messages' }));
    const options = buildProviderStreamOptions(provider, undefined, model);
    const history = await buildOutboundChatHistory({}, { messages: [userMessage([textPdf])], provider, model, streamOptions: options });
    const bodies = stubUpstream([reject400, anthropicOk]);
    const events = await drain(sendWithNativeFileFallback(history, (outbound) => sendStream(
      provider.kind, provider.apiKey, model.id, outbound, provider.baseURLText, options,
    )).stream);
    expect(bodies).toHaveLength(2);
    expect(bodies[0]).toContain('"type":"document"');
    expect(bodies[1]).not.toContain('"type":"document"');
    expect(bodies[1]).toContain('EXTRACTED-BODY-TEXT');
    expect(events.some((event) => event.type === 'error')).toBe(false);
  });

  it('CAP-RELAY-ATTACH-03 image recognition unknown -> photo library entry visible, hidden after recording an image negative cache', async () => {
    const store = createAppStore();
    const model = createRelayManualModel('vision-unknown');
    const provider = relayProvider('relay-attach-03', { transport: 'openai_chat_completions' });
    store.getState().addProvider(provider);
    connected(provider);
    const support = { image: true, nativeFile: false, textFileInline: true };
    expect(resolveAttachmentCapabilities(provider, model, support).supportsImage).toBe(true);
    const options = buildProviderStreamOptions(provider, buildStreamOptionsFromIntent(model, 'automatic', false), model);
    const messages = withoutUnreceivableImages([userMessage([imageAttachment])], provider, model, options);
    const history = await buildOutboundChatHistory({}, { messages, provider, model, streamOptions: options });
    stubUpstream([reject400]);
    await drain(sendWithRelayRejectionLoop({
      store, provider, model, history, streamOptions: options,
      send: (outbound, sendOptions) => sendStream(provider.kind, provider.apiKey, model.id, outbound, provider.baseURLText, sendOptions),
    }).stream);
    expect(resolveAttachmentCapabilities(provider, model, support).supportsImage).toBe(false);
  });
});

describe('RELAY x tools', () => {
  it('CAP-RELAY-TOOL-01 after recording a toolCall negative cache the first-leg request body carries no tools', async () => {
    const model = createRelayManualModel('tool-model');
    const provider = connected(relayProvider('relay-tool-01', { transport: 'openai_chat_completions' }));
    const identity: ToolCallRecoveryIdentity = {
      accountId: getActiveUIDSync(), connectionId: provider.id, authMode: 'bearer', canonicalModelId: 'tool-model', finalTransport: 'openai_chat',
    };
    expect(toolCallRememberedUnsupported(provider, model, identity)).toBe(false);
    recordToolCallFallback(provider, model, identity, { status: 400, structuredError: { error: { message: 'tools are not supported' } } } as never, 'openai_chat_completions');
    const toolsEnabled = !toolCallRememberedUnsupported(provider, model, identity);
    expect(toolsEnabled).toBe(false);
    // The tool loop with toolsMode 'disabled' sends the definition of an empty registry (tool-call-loop), and the first leg goes out through production sendLibraryAgentLeg.
    const tools = toolsEnabled ? [{ type: 'function', function: { name: 'search', parameters: {} } }] : ToolRegistry.empty.definitions;
    const bodies = stubUpstream([() => new Response('data: [DONE]\n\n', { status: 200, headers: { 'Content-Type': 'text/event-stream' } })]);
    await drain(sendLibraryAgentLeg(provider.kind, provider.apiKey, model.id, [{ role: 'user', content: 'hi' }], tools as never, provider.baseURLText, buildProviderStreamOptions(provider, undefined, model)).stream);
    expect(bodies).toHaveLength(1);
    expect(JSON.parse(bodies[0]!)).not.toHaveProperty('tools');
  });
});
