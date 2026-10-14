// @vitest-environment jsdom
//
// Relay web_search truth (capability badge / model library globe): user override > current record (searched / rejected) > unknown;
// "current" = the record hash equals the effective fragment (the stored one, or the template when none is stored). Fixture shared/test-fixtures/relay/web-probe.v1.json presentationCases,
// per caseId: RL2-WEBPROBE-08 STATE-<caseId> (truth, and whether the composer web control can be toggled). Records are really written through production writeRelayWebProbeRecord.

import { existsSync, readFileSync } from 'node:fs';
import path from 'node:path';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import type { AIModel, Provider } from '@oriveo/shared';
import { relayWebFragmentHash } from '@oriveo/core/providers/relay-web-probe';
import type { RelayWebTransport } from '@oriveo/shared/relay/web-fragments';
import { effectiveTransport } from '@oriveo/core/providers/relay-effective';
import { resolveModelCapabilityEvidence } from '../../chat/capability-evidence';
import { capabilityAvailableForDisplay, webPreferenceReachesTheWire } from '../../chat/capability-control-presentation';
import { RELAY_WEB_FRAGMENT_TEMPLATES } from '@oriveo/shared/relay/web-fragments';
import { replaceRelayWebFragments } from '../../chat/relay-web-fragments';
import { relayWebFragmentForChat, relayWebPreferenceDefaultFor, writeRelayWebProbeRecord } from '../../chat/relay-web-probe-records';
import type { RelayCapabilityEvidenceIdentity } from '../truth/capability-truth-adapter';
import { relayFirstSendTransport } from '../../providers/relay-first-send-transport';
import { rememberRelayCatalogEndpointTypes } from '../../providers/relay-probe-candidates';

type Json = Record<string, unknown>;
type StateCase = {
  caseId: string;
  savedFragment: boolean;
  record: { result: 'searched' | 'rejected' | 'silent'; fragmentHash: 'current' | 'other' } | null;
  userOverride: boolean | null;
  expect: { row: 'toggle' | 'toggleDisabled'; truth: 'supported' | 'unsupported' | 'unknown' };
};

const cases: StateCase[] = (() => {
  let dir = __dirname;
  for (;;) {
    const candidate = path.join(dir, 'shared', 'test-fixtures', 'relay', 'web-probe.v1.json');
    if (existsSync(candidate)) {
      return (JSON.parse(readFileSync(candidate, 'utf8')) as { presentationCases: { cases: StateCase[] } }).presentationCases.cases;
    }
    const parent = path.dirname(dir);
    if (parent === dir) throw new Error('web-probe.v1.json not found');
    dir = parent;
  }
})();

const CONNECTION = 'relay-web-truth-1';
const TRANSPORT: RelayWebTransport = 'openai_chat_completions';
const FRAGMENT: Json = { web_search_options: { search_context_size: 'high' } };
const TEMPLATE: Json = RELAY_WEB_FRAGMENT_TEMPLATES[TRANSPORT] as Json;
const OTHER_FRAGMENT: Json = { web_search_options: { search_context_size: 'low' } };
const model: AIModel = {
  id: 'truth-model', name: 'truth-model', capabilities: ['text'], reasoningModeAvailable: false, isAvailable: true, isDefault: true, priceTier: '',
};
const provider = {
  id: CONNECTION, kind: 'relay', status: { kind: 'connected' }, models: [model], catalogModels: [], apiKey: 'sk-relay', apiKeyPreview: '••',
  baseURLText: 'https://relay.example/v1', relayKind: 'openai_compatible',
  relayRequested: { transport: TRANSPORT, authMode: 'auto' },
} as unknown as Provider;
const identity: RelayCapabilityEvidenceIdentity = {
  partitionId: 'partition-1',
  connectionInstanceId: CONNECTION,
  connectionGeneration: 'gen-1',
  credentialEpoch: 'epoch-1',
  endpointFingerprint: 'fp-1',
};

function arrange(item: StateCase): { provider: Provider; model: AIModel } {
  localStorage.clear();
  replaceRelayWebFragments(CONNECTION, item.savedFragment ? { [TRANSPORT]: FRAGMENT } : {});
  if (item.record) {
    writeRelayWebProbeRecord({ connectionId: CONNECTION, modelId: model.id, transport: TRANSPORT }, {
      result: item.record.result,
      source: 'tested',
      at: '2026-10-14T12:00:00.000Z',
      fragmentHash: relayWebFragmentHash(item.record.fragmentHash === 'current' ? (item.savedFragment ? FRAGMENT : TEMPLATE) : OTHER_FRAGMENT),
    });
  }
  const arranged: AIModel = item.userOverride === null
    ? model
    : { ...model, relayCapabilityOverrides: { web: { value: item.userOverride, source: 'user' } } };
  return { provider: { ...provider, models: [arranged] } as Provider, model: arranged };
}

describe('RL2-WEBPROBE-STATE', () => {
  beforeEach(() => localStorage.clear());

  for (const item of cases) {
    it(`RL2-WEBPROBE-08 STATE-${item.caseId}`, () => {
      const arranged = arrange(item);
      const truth = resolveModelCapabilityEvidence({
        key: 'web_search',
        provider: arranged.provider,
        model: arranged.model,
        effectiveTransport: TRANSPORT,
        relayIdentity: identity,
      });
      expect(truth.support, item.caseId).toBe(item.expect.truth);
      // The badge / model library globe read the same truth: only supported lights up.
      expect(capabilityAvailableForDisplay(arranged.provider, arranged.model, 'web'), item.caseId).toBe(item.expect.truth === 'supported');
      // Composer web control: tappable (toggle) = the web preference can reach the wire; greyed out = it cannot.
      expect(webPreferenceReachesTheWire({ provider: arranged.provider, model: arranged.model }), item.caseId)
        .toBe(item.expect.row === 'toggle');
    });
  }
});

// The fragment gate and the record both read the first-send protocol (consistent with iOS / Android); a fragment on the effective protocol does not count.
describe('RL2-WEBPROBE-STATE first-send protocol != effective protocol', () => {
  const AUTO_CONNECTION = 'relay-web-truth-auto';
  const claude: AIModel = { ...model, id: 'claude-sonnet-4', name: 'claude-sonnet-4' };
  const autoProvider = {
    ...provider, id: AUTO_CONNECTION, models: [claude], relayRequested: { transport: 'auto', authMode: 'auto' },
  } as unknown as Provider;
  const messagesFragment: Json = { tools: [{ type: 'web_search_20250305', name: 'web_search' }] };
  const messagesKey = { connectionId: AUTO_CONNECTION, modelId: claude.id, transport: 'anthropic_messages' };
  const effective = effectiveTransport(autoProvider, claude);
  const autoIdentity = { ...identity, connectionInstanceId: AUTO_CONNECTION };

  beforeEach(() => {
    localStorage.clear();
    // The first catalog endpoint type is anthropic: on an auto connection this model first sends Messages.
    rememberRelayCatalogEndpointTypes(AUTO_CONNECTION, { [claude.id]: ['anthropic', 'openai'] });
  });
  afterEach(() => rememberRelayCatalogEndpointTypes(AUTO_CONNECTION, undefined));

  const truthOf = () => resolveModelCapabilityEvidence({
    key: 'web_search', provider: autoProvider, model: claude, effectiveTransport: effective, relayIdentity: autoIdentity,
  }).support;
  // The web switch is tappable (when on, it sends the effective fragment of the first-send protocol).
  const sendsFragment = () => webPreferenceReachesTheWire({ provider: autoProvider, model: claude });
  const write = (result: 'searched' | 'rejected') => writeRelayWebProbeRecord(messagesKey, {
    result, source: 'tested', at: '2026-10-14T12:00:00.000Z', fragmentHash: relayWebFragmentHash(messagesFragment),
  });

  it('precondition: the first-send protocol is Messages, the effective protocol is not', () => {
    expect(relayFirstSendTransport(autoProvider, claude)).toBe('anthropic_messages');
    expect(effective).not.toBe('anthropic_messages');
  });

  it('first-send protocol has a fragment + searched -> supported, the switch is tappable', () => {
    replaceRelayWebFragments(AUTO_CONNECTION, { anthropic_messages: messagesFragment });
    write('searched');
    expect(truthOf()).toBe('supported');
    expect(sendsFragment()).toBe(true);
  });

  it('first-send protocol has a fragment + rejected -> unsupported; the switch stays tappable, this turn sends no fragment', () => {
    replaceRelayWebFragments(AUTO_CONNECTION, { anthropic_messages: messagesFragment });
    write('rejected');
    expect(truthOf()).toBe('unsupported');
    expect(sendsFragment()).toBe(true);
    expect(relayWebFragmentForChat(autoProvider, claude, 'anthropic_messages', true)).toBeUndefined();
  });

  it('first-send protocol has a fragment + untested -> unknown, the switch is tappable', () => {
    replaceRelayWebFragments(AUTO_CONNECTION, { anthropic_messages: messagesFragment });
    expect(truthOf()).toBe('unknown');
    expect(sendsFragment()).toBe(true);
  });

  it('only the effective protocol has a fragment and record (first-send protocol has none) -> does not count: the first-send protocol uses the template, untested -> unknown, the switch is tappable and off by default', () => {
    replaceRelayWebFragments(AUTO_CONNECTION, { [effective]: FRAGMENT });
    writeRelayWebProbeRecord({ connectionId: AUTO_CONNECTION, modelId: claude.id, transport: effective }, {
      result: 'searched', source: 'tested', at: '2026-10-14T12:00:00.000Z', fragmentHash: relayWebFragmentHash(FRAGMENT),
    });
    expect(truthOf()).toBe('unknown');
    expect(sendsFragment()).toBe(true);
    expect(relayWebPreferenceDefaultFor(autoProvider, claude)).toBe('off');
  });
});
