// @vitest-environment jsdom
//
// Connection-level web fragments for relays (fixture shared/test-fixtures/relay/web-fragment.v1.json).
// The five fixture sections go case by case: validate / merge / legacy / citation / presentation, with test names like RELAY-WEBFRAG-<section>-<caseId>.
// Validation, merging and citation derivation are shared pure functions; the old-field mapping goes through the decode-point function, and the profile is injected by the fixture legacyProfiles as an object of the same shape;
// presentation goes through the production model options form function. There is also reading / saving / clearing / deleting a connection in local storage.

import { existsSync, readFileSync } from 'node:fs';
import path from 'node:path';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

// Chat web preferences are stored by runtime identity; this file has no metadata snapshot, so a revision is added. The nometa case sets null (no-metadata identity).
const runtimeMock = vi.hoisted(() => ({ revision: 'runtime-relay-web' as string | null }));
vi.mock('../../metadata/metadata-client', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../../metadata/metadata-client')>();
  return {
    ...actual,
    getCapabilityRuntime: () => actual.getCapabilityRuntime()
      ?? (runtimeMock.revision ? ({ revision: runtimeMock.revision } as never) : null),
  };
});
import type { AIModel, Provider, RelayRequestedConfig } from '@oriveo/shared';
import { relayWebFragmentHash } from '@oriveo/core/providers/relay-web-probe';
import {
  RELAY_WEB_FORBIDDEN_TOP_LEVEL_KEYS,
  RELAY_WEB_FRAGMENT_MAX_BYTES,
  RELAY_WEB_FRAGMENT_TEMPLATES,
  RELAY_WEB_TRANSPORTS,
  mergeRelayWebFragment,
  relayWebCitationProfile,
  validateRelayWebFragment,
  type RelayWebTransport,
} from '@oriveo/shared/relay/web-fragments';
import {
  RELAY_LEGACY_WEB_PROFILE_TRANSPORT,
  effectiveRelayWebFragments,
} from '@oriveo/shared/relay/legacy-web-search';
import { resolveModelOptionCapabilityShape, type ModelOptionCapabilityInput } from '../model-option-capability-shape';
import { modelOptionDisclosureStatusCopy, modelOptionsTileStatusCopy, MODEL_OPTION_LINK_KEYS } from '../model-options-copy';
import {
  RELAY_WEB_FRAGMENTS_STORAGE_KEY,
  clearRelayWebFragment,
  deleteRelayWebFragmentsConnection,
  readStoredRelayWebFragments,
  replaceRelayWebFragments,
  saveRelayWebFragment,
} from '../relay-web-fragments';
import {
  relayWebModelOptionFacts,
  relayWebPreferenceDefaultFor,
  resolveRelayWebPresentation,
  relayWebProviderDefault,
  writeRelayWebProbeRecord,
  type RelayWebStatusId,
} from '../relay-web-probe-records';
import { buildProviderStreamOptions, buildStreamOptionsFromIntent, filterRequestCapabilityIntent } from '../stream-options';
import {
  RELAY_PREFERENCE_FALLBACK_REVISION,
  capabilityPreferenceIdentity,
  capabilityRuntimeIdentity,
  displayCapabilityPreferences,
  resolveCapabilityPreferences,
  saveCapabilityPreferences,
} from '../capability-preference-settings';
import { webPreferenceReachesTheWire } from '../capability-control-presentation';
import { sendWithRelayRejectionLoop } from '../relay-rejection-loop';
import { createAppStore } from '../../store/app-store';
import type { StreamOptions } from '@oriveo/core/providers/types';
import { buildRelayChatRequest } from '../../providers/adapters/relay';
import { rememberRelayCatalogEndpointTypes } from '../../providers/relay-probe-candidates';
import { effectiveTransport } from '@oriveo/core/providers/relay-effective';

type Json = Record<string, unknown>;
type Fixture = {
  transports: RelayWebTransport[];
  templates: Record<RelayWebTransport, Json>;
  limits: { maxBytes: number; forbiddenTopLevelKeys: string[] };
  validateCases: Array<{ caseId: string; raw?: string; rawPadTo?: number; expect: { ok: boolean; error?: string; key?: string } }>;
  mergeCases: Array<{ caseId: string; transport: RelayWebTransport; builderBody: Json; fragment: Json; expect: Json }>;
  legacyProfiles: Record<string, Json>;
  profileTransport: Record<string, RelayWebTransport>;
  legacyCases: Array<{ caseId: string; stored: Json; relayRequested: Json; expect: Json }>;
  citationCases: Array<{ caseId: string; transport: RelayWebTransport; fragment: Json | null; expect: string | null }>;
  presentationCases: Array<{
    caseId: string;
    engineProfile: string | null;
    protocolUndecided: boolean;
    effectiveTransport: RelayWebTransport;
    fragments: Json;
    expect: { shape: string; status?: string; action?: string; link?: string };
  }>;
};

const fixture: Fixture = (() => {
  let dir = __dirname;
  for (;;) {
    const candidate = path.join(dir, 'shared', 'test-fixtures', 'relay', 'web-fragment.v1.json');
    if (existsSync(candidate)) return JSON.parse(readFileSync(candidate, 'utf8')) as Fixture;
    const parent = path.dirname(dir);
    if (parent === dir) throw new Error('web-fragment.v1.json not found');
    dir = parent;
  }
})();

// Copy assertions read the production en resources (messages/en.json) and do not hand-write translations.
const enMessages: Json = JSON.parse(readFileSync(path.join(__dirname, '../../../../messages/en.json'), 'utf8'));
function en(key: string): string | undefined {
  let value: unknown = enMessages;
  for (const part of key.split('.')) value = (value as Json | undefined)?.[part];
  return typeof value === 'string' ? value : undefined;
}

const legacyProfileLookup = (name: string) => {
  const mergeParams = fixture.legacyProfiles[name];
  return mergeParams ? { mergeParams } : null;
};

function rawOf(item: Fixture['validateCases'][number]): string {
  if (item.rawPadTo === undefined) return item.raw ?? '';
  return `{"x":"${'a'.repeat(item.rawPadTo - 8)}"}`;
}

describe('RELAY-WEBFRAG constants match the fixture', () => {
  it('protocol order, template, 8 KB limit and forbidden top-level keys', () => {
    expect([...RELAY_WEB_TRANSPORTS]).toEqual(fixture.transports);
    expect(RELAY_WEB_FRAGMENT_TEMPLATES).toEqual(fixture.templates);
    expect(RELAY_WEB_FRAGMENT_MAX_BYTES).toBe(fixture.limits.maxBytes);
    expect([...RELAY_WEB_FORBIDDEN_TOP_LEVEL_KEYS]).toEqual(fixture.limits.forbiddenTopLevelKeys);
    expect(RELAY_LEGACY_WEB_PROFILE_TRANSPORT).toEqual(fixture.profileTransport);
  });
});

describe('RELAY-WEBFRAG-validate', () => {
  for (const item of fixture.validateCases) {
    it(`RELAY-WEBFRAG-validate-${item.caseId}`, () => {
      const result = validateRelayWebFragment(rawOf(item));
      if (item.expect.ok) {
        expect(result.ok, item.caseId).toBe(true);
      } else {
        expect(result, item.caseId).toMatchObject({
          ok: false,
          error: item.expect.error,
          ...(item.expect.key ? { key: item.expect.key } : {}),
        });
      }
    });
  }
});

describe('RELAY-WEBFRAG-merge', () => {
  for (const item of fixture.mergeCases) {
    it(`RELAY-WEBFRAG-merge-${item.caseId}`, () => {
      const body = structuredClone(item.builderBody);
      const fragment = structuredClone(item.fragment);
      mergeRelayWebFragment(item.transport, body, fragment);
      expect(body, item.caseId).toEqual(item.expect);
      // The fragment object itself is not rewritten (every request uses it again).
      expect(fragment, item.caseId).toEqual(item.fragment);
    });
  }
});

describe('RELAY-WEBFRAG-legacy', () => {
  for (const item of fixture.legacyCases) {
    it(`RELAY-WEBFRAG-legacy-${item.caseId}`, () => {
      const requested = { transport: 'openai_responses', ...item.relayRequested } as RelayRequestedConfig;
      const before = structuredClone(requested);
      expect(effectiveRelayWebFragments(item.stored, requested, legacyProfileLookup), item.caseId).toEqual(item.expect);
      // Mapped at read time, not written back.
      expect(requested, item.caseId).toEqual(before);
    });
  }
});

describe('RELAY-WEBFRAG-legacy supplement', () => {
  it('metadata has this profile but the protocol table does not -> not mapped', () => {
    const lookup = (name: string) => (name === 'new_server_web' ? { mergeParams: { web: true } } : legacyProfileLookup(name));
    const requested = { transport: 'openai_responses', hasWebSearch: true, webSearchProfile: 'new_server_web' } as RelayRequestedConfig;
    expect(effectiveRelayWebFragments({}, requested, lookup)).toEqual({});
  });
});

describe('RELAY-WEBFRAG-citation', () => {
  for (const item of fixture.citationCases) {
    it(`RELAY-WEBFRAG-citation-${item.caseId}`, () => {
      expect(relayWebCitationProfile(item.transport, item.fragment), item.caseId).toBe(item.expect);
    });
  }
});

describe('RELAY-WEBFRAG-presentation', () => {
  for (const item of fixture.presentationCases) {
    it(`RELAY-WEBFRAG-presentation-${item.caseId}`, () => {
      const input: ModelOptionCapabilityInput = {
        capability: 'web',
        // Relay web has no official recipe: the ruling state has no effect here, the form looks only at the connection-level fragment.
        status: 'unknown',
        availableIntents: [],
        connection: 'custom',
        isWritable: true,
        protocolUndecided: item.protocolUndecided,
        rejectedIntents: [],
        chatTemplateThinkingIsOn: false,
        supportsChatTemplate: false,
        relayWeb: {
          localEngine: item.engineProfile !== null,
          hasFragment: item.fragments[item.effectiveTransport] !== undefined,
        },
      };
      const shape = resolveModelOptionCapabilityShape(input);
      expect(shape.kind, item.caseId).toBe(item.expect.shape);
      if (shape.kind === 'disclosure') {
        expect(en(modelOptionDisclosureStatusCopy(shape.status, 'web').key), item.caseId).toBe(item.expect.status);
        if (item.expect.action) expect(shape.link, item.caseId).toBe(item.expect.action);
      }
    });
  }
});

describe('RELAY-WEBFRAG local storage (oriveo.relay-web-fragments.v1)', () => {
  beforeEach(() => localStorage.clear());

  it('saving a fragment validates first: error codes match the fixture and nothing is persisted; a valid one is stored by connection id', () => {
    expect(saveRelayWebFragment('c1', 'openai_responses', '{}')).toMatchObject({ ok: false, error: 'empty' });
    expect(readStoredRelayWebFragments('c1')).toEqual({});
    expect(saveRelayWebFragment('c1', 'openai_responses', '{"tools":[{"type":"web_search"}]}').ok).toBe(true);
    expect(saveRelayWebFragment('c1', 'anthropic_messages', JSON.stringify(fixture.templates.anthropic_messages)).ok).toBe(true);
    expect(saveRelayWebFragment('c2', 'openai_chat_completions', '{"web_search_options":{}}').ok).toBe(true);
    expect(readStoredRelayWebFragments('c1')).toEqual({
      openai_responses: { tools: [{ type: 'web_search' }] },
      anthropic_messages: fixture.templates.anthropic_messages,
    });
    expect(JSON.parse(localStorage.getItem(RELAY_WEB_FRAGMENTS_STORAGE_KEY) ?? '{}')).toHaveProperty('connections.c2');
  });

  it('clearing a fragment clears only that fragment; deleting the connection deletes the whole entry', () => {
    saveRelayWebFragment('c1', 'openai_responses', '{"tools":[{"type":"web_search"}]}');
    saveRelayWebFragment('c1', 'gemini_generate_content', '{"tools":[{"googleSearch":{}}]}');
    saveRelayWebFragment('c2', 'openai_chat_completions', '{"web_search_options":{}}');
    clearRelayWebFragment('c1', 'openai_responses');
    expect(readStoredRelayWebFragments('c1')).toEqual({ gemini_generate_content: { tools: [{ googleSearch: {} }] } });
    deleteRelayWebFragmentsConnection('c1');
    expect(readStoredRelayWebFragments('c1')).toEqual({});
    expect(readStoredRelayWebFragments('c2')).toEqual({ openai_chat_completions: { web_search_options: {} } });
  });

  it('corrupt data reads as empty', () => {
    localStorage.setItem(RELAY_WEB_FRAGMENTS_STORAGE_KEY, '{oops');
    expect(readStoredRelayWebFragments('c1')).toEqual({});
  });
});

/* -- Web search is a chat switch (shared/test-fixtures/relay/web-probe.v1.json presentationCases) -- */

type WebProbePresentationCase = {
  caseId: string;
  savedFragment: boolean;
  record: { result: 'searched' | 'rejected' | 'silent'; fragmentHash: 'current' | 'other' } | null;
  userOverride: boolean | null;
  webPreference: 'on' | 'off' | null;
  expect: {
    row: 'toggle' | 'toggleDisabled';
    isOn: boolean;
    statusId: RelayWebStatusId;
    retestLink?: 'openConnectionWebSearch' | 'testCapabilities';
    sendsFragment: boolean;
    sentFragment?: 'saved' | 'template';
    replyNotice?: 'web_not_used' | null;
  };
};

const webProbePresentation: WebProbePresentationCase[] = (() => {
  let dir = __dirname;
  for (;;) {
    const candidate = path.join(dir, 'shared', 'test-fixtures', 'relay', 'web-probe.v1.json');
    if (existsSync(candidate)) return (JSON.parse(readFileSync(candidate, 'utf8')) as { presentationCases: { cases: WebProbePresentationCase[] } }).presentationCases.cases;
    const parent = path.dirname(dir);
    if (parent === dir) throw new Error('web-probe.v1.json not found');
    dir = parent;
  }
})();

const PROBE_CONNECTION = 'relay-web-probe-1';
const PROBE_CONVERSATION = 'conv-relay-web-1';
const PROBE_TRANSPORT: RelayWebTransport = 'openai_chat_completions';
const TEMPLATE_FRAGMENT = fixture.templates[PROBE_TRANSPORT];
/** A stored fragment that differs from the template, so the request body shows which one was sent. */
const SAVED_FRAGMENT: Json = { web_search_options: { search_context_size: 'high' } };
const OTHER_FRAGMENT: Json = { web_search_options: { search_context_size: 'low' } };
const probeModel: AIModel = {
  id: 'probe-model', name: 'probe-model', capabilities: ['text'], reasoningModeAvailable: false, isAvailable: true, isDefault: true, priceTier: '',
};
const probeProvider = {
  id: PROBE_CONNECTION, kind: 'relay', status: { kind: 'connected' }, models: [probeModel], catalogModels: [], apiKey: 'sk-relay', apiKeyPreview: '••',
  baseURLText: 'https://relay.example/v1', relayKind: 'openai_compatible',
  relayRequested: { transport: PROBE_TRANSPORT, authMode: 'auto' },
} as unknown as Provider;
const probeKey = { connectionId: PROBE_CONNECTION, modelId: probeModel.id, transport: PROBE_TRANSPORT };

/** State id -> en copy (web_user_on = the source badge "Set by you"). */
const STATUS_COPY: Record<RelayWebStatusId, string> = {
  web_probe_searched: 'Search confirmed',
  web_probe_silent: 'Didn’t search when tested',
  web_probe_rejected: 'This model rejects the web search settings',
  web_probe_unverified: 'Set · not verified',
  web_probe_untested: 'Not tested yet',
  web_user_off: 'Turned off in this model’s Advanced settings',
  web_user_on: 'Set by you',
};

type ProbeArrangement = Pick<WebProbePresentationCase, 'savedFragment' | 'record' | 'userOverride' | 'webPreference'>;

/** Lands the fixture input in production storage: fragment, record (current = hash of the effective fragment), user override, this session's chat web preference; returns the model. */
function arrangeProbeCase(item: ProbeArrangement): { provider: Provider; model: AIModel } {
  localStorage.clear();
  replaceRelayWebFragments(PROBE_CONNECTION, item.savedFragment ? { [PROBE_TRANSPORT]: SAVED_FRAGMENT } : {});
  const effective = item.savedFragment ? SAVED_FRAGMENT : TEMPLATE_FRAGMENT;
  if (item.record) {
    writeRelayWebProbeRecord(probeKey, {
      result: item.record.result,
      source: 'tested',
      at: '2026-10-13T12:00:00.000Z',
      fragmentHash: relayWebFragmentHash(item.record.fragmentHash === 'current' ? effective : OTHER_FRAGMENT),
    });
  }
  const model: AIModel = item.userOverride === null
    ? probeModel
    : { ...probeModel, relayCapabilityOverrides: { web: { value: item.userOverride, source: 'user' } } };
  const provider = { ...probeProvider, models: [model] } as Provider;
  if (item.webPreference !== null) {
    const identity = capabilityPreferenceIdentity(provider, model)!;
    saveCapabilityPreferences(
      { ...identity, scope: 'conversation_connection_model', conversationId: PROBE_CONVERSATION },
      { web: item.webPreference === 'on' ? 'automatic' : 'off' },
    );
  }
  return { provider, model };
}

/** The chat web preference the panel reads: the same read as ChatView's restored state (ladder + relay default layer). */
function displayedWebPreference(provider: Provider, model: AIModel): string {
  const defaultWeb = relayWebPreferenceDefaultFor(provider, model);
  return displayCapabilityPreferences({
    ...capabilityPreferenceIdentity(provider, model)!, conversationId: PROBE_CONVERSATION, ...(defaultWeb ? { defaultWeb } : {}),
  }).web;
}

function relayWebRow(provider: Provider, model: AIModel) {
  return resolveModelOptionCapabilityShape({
    capability: 'web',
    status: 'unknown',
    availableIntents: [],
    selectedIntent: displayedWebPreference(provider, model),
    connection: 'custom',
    isWritable: true,
    protocolUndecided: false,
    rejectedIntents: [],
    chatTemplateThinkingIsOn: false,
    supportsChatTemplate: false,
    relayWeb: relayWebModelOptionFacts(provider, model),
  });
}

/** Production send construction (same order as operations-send): ladder resolves the preference -> outbound gate -> final options -> relay request body. */
function productionChatBody(provider: Provider, model: AIModel, streamOptions?: StreamOptions): Json {
  const identity = capabilityPreferenceIdentity(provider, model)!;
  const preferences = resolveCapabilityPreferences({
    ...identity, conversationId: PROBE_CONVERSATION, providerDefault: relayWebProviderDefault(provider, model),
  });
  const preliminary = buildProviderStreamOptions(provider, buildStreamOptionsFromIntent(model, undefined, undefined, undefined, preferences), model);
  const intent = filterRequestCapabilityIntent({
    provider, model, reasoningMode: 'automatic', webSearchEnabled: undefined,
    webReachesTheWire: webPreferenceReachesTheWire({ provider, model, transportIdentity: identity.transportIdentity }),
    streamOptions: preliminary,
  });
  const options = streamOptions ?? buildProviderStreamOptions(
    provider,
    buildStreamOptionsFromIntent(model, intent.reasoning, intent.supportsWebSearch, undefined, intent.capabilityPreferences),
    model,
  );
  const request = buildRelayChatRequest('sk-relay', model.id, [{ role: 'user', content: 'hi' }], provider.baseURLText, options);
  return JSON.parse(request.body) as Json;
}

describe('RL2-WEBPROBE-14 model options web row', () => {
  beforeEach(() => localStorage.clear());

  for (const item of webProbePresentation) {
    it(`RL2-WEBPROBE-14 PRES-${item.caseId}`, () => {
      const { provider, model } = arrangeProbeCase(item);
      const shape = relayWebRow(provider, model);
      // Reply notice: switch on but no fragment sent -> web_not_used, otherwise null.
      expect(resolveRelayWebPresentation(relayWebModelOptionFacts(provider, model), displayedWebPreference(provider, model) as 'off' | 'automatic').replyNotice ?? null, item.caseId)
        .toBe(item.expect.replyNotice ?? null);
      expect(shape.kind, item.caseId).toBe('toggle');
      if (shape.kind !== 'toggle') return;
      expect(shape.disabled === true ? 'toggleDisabled' : 'toggle', item.caseId).toBe(item.expect.row);
      expect(shape.isOn, item.caseId).toBe(item.expect.isOn);
      expect(shape.relayStatus, item.caseId).toBe(item.expect.statusId);
      expect(shape.link, item.caseId).toBe(item.expect.retestLink);
      const status = modelOptionsTileStatusCopy({ kind: 'capability', capability: 'web', row: shape, corner: 'switch' });
      expect(en(status!.key), item.caseId).toBe(STATUS_COPY[item.expect.statusId]);
      // Retest link copy: a rejected stored fragment -> Test again in Web Search; a rejected template -> Test capabilities.
      if (shape.link) {
        expect(en(MODEL_OPTION_LINK_KEYS[shape.link]), item.caseId)
          .toBe(shape.link === 'openConnectionWebSearch' ? 'Test again in Web Search' : 'Test capabilities');
      }
    });
  }

  it('RL2-WEBPROBE-14 nometa no-metadata identity: the switch can be stored, read back after re-entering, and the request body carries the fragment', () => {
    runtimeMock.revision = null;
    try {
      const { provider, model } = arrangeProbeCase({ savedFragment: false, record: null, userOverride: null, webPreference: null });
      expect(capabilityRuntimeIdentity(provider, model)).toBeNull();
      const identity = capabilityPreferenceIdentity(provider, model)!;
      expect(identity.runtimeRevision).toBe(RELAY_PREFERENCE_FALLBACK_REVISION);
      // Template, never set: off by default, no fragment sent.
      expect(relayWebRow(provider, model)).toMatchObject({ kind: 'toggle', isOn: false });
      expect(productionChatBody(provider, model)).not.toHaveProperty('web_search_options');
      // Turn it on (same write as ChatView: conversation scope) -> reading again still gives on -> the request body carries the template.
      saveCapabilityPreferences({ ...identity, scope: 'conversation_connection_model', conversationId: PROBE_CONVERSATION }, { web: 'automatic' });
      expect(displayedWebPreference(provider, model)).toBe('automatic');
      expect(relayWebRow(provider, model)).toMatchObject({ kind: 'toggle', isOn: true });
      expect(productionChatBody(provider, model)).toHaveProperty('web_search_options', TEMPLATE_FRAGMENT.web_search_options);
    } finally {
      runtimeMock.revision = 'runtime-relay-web';
    }
  });

  it('no longer shows "Needs manual setup" or "configure in web search settings"', () => {
    for (const item of webProbePresentation) {
      const { provider, model } = arrangeProbeCase(item);
      const shape = relayWebRow(provider, model);
      expect(shape.kind, item.caseId).not.toBe('notice');
    }
  });
});

describe('RL2-WEBPROBE-02 the switch decides the request body (production builder)', () => {
  beforeEach(() => localStorage.clear());
  const webKeys = Object.keys(TEMPLATE_FRAGMENT);

  for (const item of webProbePresentation) {
    it(`RL2-WEBPROBE-02 BODY-${item.caseId}`, () => {
      const { provider, model } = arrangeProbeCase(item);
      const body = productionChatBody(provider, model);
      if (!item.expect.sendsFragment) {
        for (const key of webKeys) expect(body, item.caseId).not.toHaveProperty(key);
        return;
      }
      const sent = item.expect.sentFragment === 'saved' ? SAVED_FRAGMENT : TEMPLATE_FRAGMENT;
      for (const key of Object.keys(sent)) expect(body, item.caseId).toHaveProperty(key, sent[key]);
    });
  }

  it('RL2-WEBPROBE-02 the library / MCP path (singleSend web off) carries no fragment', () => {
    const { provider, model } = arrangeProbeCase({ savedFragment: true, record: null, userOverride: null, webPreference: 'on' });
    const options = buildProviderStreamOptions(provider, buildStreamOptionsFromIntent(model, undefined, false), model);
    expect(options?.relayWebFragment).toBeUndefined();
  });
});

describe('RL2-WEBPROBE panel / chat use the same protocol as the probe (the first-send protocol of the model)', () => {
  const AUTO_CONNECTION = 'relay-web-probe-auto';
  const claude: AIModel = { ...probeModel, id: 'claude-sonnet-4', name: 'claude-sonnet-4' };
  const autoProvider = {
    ...probeProvider, id: AUTO_CONNECTION, models: [claude], relayRequested: { transport: 'auto', authMode: 'auto' },
  } as unknown as Provider;
  const messagesFragment = fixture.templates.anthropic_messages;
  const messagesKey = { connectionId: AUTO_CONNECTION, modelId: claude.id, transport: 'anthropic_messages' };

  beforeEach(() => {
    localStorage.clear();
    // The first catalog endpoint type is anthropic: on an auto connection this model first sends Messages.
    rememberRelayCatalogEndpointTypes(AUTO_CONNECTION, { [claude.id]: ['anthropic', 'openai'] });
    replaceRelayWebFragments(AUTO_CONNECTION, { anthropic_messages: messagesFragment });
  });
  afterEach(() => rememberRelayCatalogEndpointTypes(AUTO_CONNECTION, undefined));

  it('RL2-WEBPROBE-14 first-send anthropic_messages: after writing searched the web row status is Search confirmed', () => {
    // Precondition: effectiveTransport is not the first-send protocol, so the case can tell the two apart.
    expect(effectiveTransport(autoProvider, claude)).not.toBe('anthropic_messages');
    writeRelayWebProbeRecord(messagesKey, {
      result: 'searched', source: 'tested', at: '2026-10-13T12:00:00.000Z', fragmentHash: relayWebFragmentHash(messagesFragment),
    });
    const shape = resolveModelOptionCapabilityShape({
      capability: 'web', status: 'unknown', availableIntents: [], connection: 'custom', isWritable: true, protocolUndecided: false,
      rejectedIntents: [], chatTemplateThinkingIsOn: false, supportsChatTemplate: false,
      relayWeb: relayWebModelOptionFacts(autoProvider, claude),
    });
    expect(shape.kind).toBe('toggle');
    expect(shape.kind === 'toggle' && shape.relayStatus).toBe('web_probe_searched');
    // The first-send protocol has a stored fragment and nothing was ever set: on by default.
    expect(relayWebPreferenceDefaultFor(autoProvider, claude)).toBe('automatic');
  });

  it('RL2-WEBPROBE-02 first-send anthropic_messages: with the switch on, the Messages fragment is carried after the first send switches protocol; after rejected it is not', () => {
    const sendOnce = () => {
      const sent: Array<StreamOptions | undefined> = [];
      sendWithRelayRejectionLoop({
        store: createAppStore({ providers: [autoProvider] }),
        provider: autoProvider,
        model: claude,
        history: [{ role: 'user', content: 'hi' }] as never,
        streamOptions: buildProviderStreamOptions(autoProvider, buildStreamOptionsFromIntent(claude, undefined, true), claude),
        send: (_history, options) => {
          sent.push(options);
          return { stream: new ReadableStream({ start: (ctrl) => ctrl.close() }), abort: () => {} } as never;
        },
      });
      return sent[0];
    };
    expect(sendOnce()?.relayTransport).toBe('anthropic_messages');
    expect(sendOnce()?.relayWebFragment).toEqual(messagesFragment);

    writeRelayWebProbeRecord(messagesKey, {
      result: 'rejected', source: 'tested', at: '2026-10-13T12:00:00.000Z', fragmentHash: relayWebFragmentHash(messagesFragment),
    });
    // Production send loop: after the first send switches protocol, options are re-resolved with the first-send protocol, and the fragment decision follows the first-send protocol.
    expect(sendOnce()?.relayTransport).toBe('anthropic_messages');
    expect(sendOnce()?.relayWebFragment).toBeUndefined();
  });
});
