// @vitest-environment jsdom
//
// Connection-level web fragments for relays (fixture shared/test-fixtures/relay/web-fragment.v1.json).
// The five fixture sections go case by case: validate / merge / legacy / citation / presentation, with test names like RELAY-WEBFRAG-<section>-<caseId>.
// Validation, merging and citation derivation are shared pure functions; the old-field mapping goes through the decode-point function, and the profile is injected by the fixture legacyProfiles as an object of the same shape;
// presentation goes through the production model options form function. There is also reading / saving / clearing / deleting a connection in local storage.

import { existsSync, readFileSync } from 'node:fs';
import path from 'node:path';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
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
import { modelOptionDisclosureStatusCopy, MODEL_OPTION_NOTICE_STATUS_KEYS, modelOptionNoticeBodyCopy, MODEL_OPTION_LINK_KEYS } from '../model-options-copy';
import {
  RELAY_WEB_FRAGMENTS_STORAGE_KEY,
  clearRelayWebFragment,
  deleteRelayWebFragmentsConnection,
  readStoredRelayWebFragments,
  replaceRelayWebFragments,
  saveRelayWebFragment,
} from '../relay-web-fragments';
import {
  relayWebFragmentForChat,
  relayWebModelOptionFacts,
  writeRelayWebProbeRecord,
} from '../relay-web-probe-records';
import { buildProviderStreamOptions } from '../stream-options';
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
      if (shape.kind === 'notice') {
        expect(en(MODEL_OPTION_NOTICE_STATUS_KEYS[shape.status]), item.caseId).toBe(item.expect.status);
        expect(shape.link, item.caseId).toBe(item.expect.link);
        expect(modelOptionNoticeBodyCopy(shape.body).key).toBe('common.modelOptionsRelayWebManualBody');
        expect(MODEL_OPTION_LINK_KEYS[shape.link!]).toBe('common.modelOptionsRelayWebOpenSettings');
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

/* ── The local probe record drives the web row and whether chat attaches the fragment (shared/test-fixtures/relay/web-probe.v1.json presentationCases) ── */

type WebProbePresentationCase = {
  caseId: string;
  hasFragment: boolean;
  record: { result: 'searched' | 'rejected' | 'silent'; fragmentHash: 'current' | 'other' } | null;
  expect: { state: string; statusId: string; sendsFragment: boolean; retestLink?: string };
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
const PROBE_TRANSPORT: RelayWebTransport = 'openai_chat_completions';
const PROBE_FRAGMENT = fixture.templates[PROBE_TRANSPORT];
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

/** State id -> en copy and form. */
const STATUS_COPY: Record<string, { shape: 'disclosure' | 'notice'; status: string; body?: string }> = {
  web_probe_searched: { shape: 'disclosure', status: 'Search confirmed' },
  web_probe_silent: { shape: 'disclosure', status: 'Didn’t search when tested' },
  web_probe_unverified: { shape: 'disclosure', status: 'Set · not verified' },
  web_probe_rejected: { shape: 'notice', status: 'This model rejects the web search settings', body: 'Test again in Web Search' },
  needs_manual_setup: { shape: 'notice', status: 'Needs manual setup' },
};

function arrangeProbeCase(item: Pick<WebProbePresentationCase, 'hasFragment' | 'record'>): void {
  localStorage.clear();
  replaceRelayWebFragments(PROBE_CONNECTION, item.hasFragment ? { [PROBE_TRANSPORT]: PROBE_FRAGMENT } : {});
  if (item.record) {
    writeRelayWebProbeRecord(probeKey, {
      result: item.record.result,
      source: 'tested',
      at: '2026-10-13T12:00:00.000Z',
      fragmentHash: relayWebFragmentHash(item.record.fragmentHash === 'current' ? PROBE_FRAGMENT : OTHER_FRAGMENT),
    });
  }
}

describe('RL2-WEBPROBE-PRES', () => {
  beforeEach(() => localStorage.clear());

  for (const item of webProbePresentation) {
    it(`RL2-WEBPROBE-PRES-${item.caseId}`, () => {
      arrangeProbeCase(item);
      const shape = resolveModelOptionCapabilityShape({
        capability: 'web',
        status: 'unknown',
        availableIntents: [],
        connection: 'custom',
        isWritable: true,
        protocolUndecided: false,
        rejectedIntents: [],
        chatTemplateThinkingIsOn: false,
        supportsChatTemplate: false,
        relayWeb: relayWebModelOptionFacts(probeProvider, probeModel),
      });
      const expected = STATUS_COPY[item.expect.statusId]!;
      expect(shape.kind, item.caseId).toBe(expected.shape);
      if (shape.kind === 'disclosure') {
        expect(en(modelOptionDisclosureStatusCopy(shape.status, 'web').key), item.caseId).toBe(expected.status);
        // There is a fragment and it is not rejected: the whole row taps through to the web search page of that connection.
        expect(shape.link, item.caseId).toBe('openConnectionWebSearch');
      }
      if (shape.kind === 'notice') {
        expect(en(MODEL_OPTION_NOTICE_STATUS_KEYS[shape.status]), item.caseId).toBe(expected.status);
        expect(shape.link, item.caseId).toBe('openConnectionWebSearch');
        if (expected.body) expect(en(modelOptionNoticeBodyCopy(shape.body).key), item.caseId).toBe(expected.body);
      }
      if (item.expect.retestLink) {
        expect(shape.kind, item.caseId).toBe('notice');
        expect(shape.kind === 'notice' && shape.link, item.caseId).toBe(item.expect.retestLink);
      }
      expect(relayWebFragmentForChat(probeProvider, probeModel, PROBE_TRANSPORT) !== undefined, item.caseId).toBe(item.expect.sendsFragment);
    });
  }
});

describe('RL2-WEBPROBE-CHAT-01', () => {
  beforeEach(() => localStorage.clear());

  function chatBody(): Json {
    const options = buildProviderStreamOptions(probeProvider, undefined, probeModel);
    const request = buildRelayChatRequest('sk-relay', probeModel.id, [{ role: 'user', content: 'hi' }], probeProvider.baseURLText, options);
    return JSON.parse(request.body) as Json;
  }
  const fragmentKeys = Object.keys(PROBE_FRAGMENT);

  it('RL2-WEBPROBE-CHAT-01 rejected record under the current fragment: the production chat request body does not contain the fragment', () => {
    arrangeProbeCase({ hasFragment: true, record: { result: 'rejected', fragmentHash: 'current' } });
    const body = chatBody();
    for (const key of fragmentKeys) expect(body).not.toHaveProperty(key);
  });

  const attaches: Array<[string, WebProbePresentationCase['record']]> = [
    ['silent', { result: 'silent', fragmentHash: 'current' }],
    ['untested', null],
    ['stale rejected', { result: 'rejected', fragmentHash: 'other' }],
    ['searched', { result: 'searched', fragmentHash: 'current' }],
  ];
  for (const [label, record] of attaches) {
    it(`RL2-WEBPROBE-CHAT-01 ${label}: the fragment is attached as usual`, () => {
      arrangeProbeCase({ hasFragment: true, record });
      const body = chatBody();
      for (const key of fragmentKeys) expect(body, label).toHaveProperty(key, (PROBE_FRAGMENT as Json)[key]);
    });
  }
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

  it('RL2-WEBPROBE-PRES first-send anthropic_messages: after writing searched the panel shows Search confirmed', () => {
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
    expect(shape.kind).toBe('disclosure');
    expect(shape.kind === 'disclosure' && en(modelOptionDisclosureStatusCopy(shape.status, 'web').key)).toBe('Search confirmed');
  });

  it('RL2-WEBPROBE-CHAT-01 first-send anthropic_messages: after rejected the chat request body does not contain the fragment', () => {
    writeRelayWebProbeRecord(messagesKey, {
      result: 'rejected', source: 'tested', at: '2026-10-13T12:00:00.000Z', fragmentHash: relayWebFragmentHash(messagesFragment),
    });
    // Production send loop: after the first send switches protocol, options are re-resolved with the first-send protocol, and the fragment decision follows the first-send protocol.
    const sent: Array<StreamOptions | undefined> = [];
    sendWithRelayRejectionLoop({
      store: createAppStore({ providers: [autoProvider] }),
      provider: autoProvider,
      model: claude,
      history: [{ role: 'user', content: 'hi' }] as never,
      streamOptions: buildProviderStreamOptions(autoProvider, undefined, claude),
      send: (_history, options) => {
        sent.push(options);
        return { stream: new ReadableStream({ start: (ctrl) => ctrl.close() }), abort: () => {} } as never;
      },
    });
    expect(sent[0]?.relayTransport).toBe('anthropic_messages');
    expect(sent[0]?.relayWebFragment).toBeUndefined();
  });
});
