import { existsSync, readFileSync } from 'node:fs';
import path from 'node:path';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { makeRelayRequested, type AIModel, type Provider, type RelayModelTransport } from '@oriveo/shared';
import { effectiveTransport } from '@oriveo/core/providers/relay-effective';
import {
  RELAY_NEGATIVE_CACHE_STORAGE_KEY,
  RELAY_NEGATIVE_CACHE_TTL_MS,
  clearRelayNegativeCache,
  clearRelayNegativeCacheConnection,
  isRelayNegativeCached,
  recordRelayNegativeCache,
  type RelayNegativeCacheKind,
} from '../relay-negative-cache';
import { resolveAttachmentCapabilities, resolveProviderAttachmentSupport } from '../attachment-policy';
import { resolveModelCapabilityEvidence } from '../capability-evidence';
import { buildProviderStreamOptions, buildStreamOptionsFromIntent } from '../stream-options';
import { inputNegativeCacheTarget, resolveInputCapabilityProjections } from '../../capability/truth/input-truth-adapter';
import { INPUT_NEGATIVE_CACHE_TTL_MS, recordInputNegativeCache } from '../../capability/input-negative-cache';
import { createRelayManualModel } from '../../provider-model-ops';
import {
  beginCapabilityEvidenceIdentityIfAbsent,
  resetCapabilityEvidenceIdentitiesForTesting,
} from '../../providers/capability-evidence-identity';
import { getActiveUIDSync } from '../../../infra/storage/partition';

type ShortTransport = 'chat' | 'responses' | 'messages' | 'gemini';
interface KeyPoint { connectionId: string; modelId: string; transport: ShortTransport; kind: RelayNegativeCacheKind; at: number }
interface Fixture {
  ttlSeconds: number;
  transports: Record<ShortTransport, RelayModelTransport>;
  keyCases: Array<{ caseId: string; record: KeyPoint; query: KeyPoint; expectHit: boolean }>;
  clearCases: Array<{
    caseId: string;
    action: 'testedResult' | 'userOverride' | 'redetect';
    kind?: RelayNegativeCacheKind;
    target: { connectionId: string; modelId?: string; transport?: ShortTransport };
    before: Array<[string, string, ShortTransport, RelayNegativeCacheKind]>;
    after: Array<[string, string, ShortTransport, RelayNegativeCacheKind]>;
  }>;
  visionEntryCases: Array<{
    caseId: string;
    form: 'relay' | 'official';
    envelopeAllowsImage: boolean;
    engineDeclarationImage: boolean | null;
    override: { value: boolean; source: 'user' | 'tested' } | null;
    imageNegCached: boolean;
    expectVisible: boolean;
    /** Expectation of the three-valued projection; a case that carries it asserts this instead of expectVisible. */
    e39Expect?: { visible: boolean; editable: boolean };
  }>;
}

const fixture: Fixture = (() => {
  let dir = process.cwd();
  for (let depth = 0; depth < 8; depth += 1) {
    const candidate = path.join(dir, 'shared', 'test-fixtures', 'relay', 'negative-cache.v1.json');
    if (existsSync(candidate)) return JSON.parse(readFileSync(candidate, 'utf8')) as Fixture;
    dir = path.dirname(dir);
  }
  throw new Error('negative-cache.v1.json not found');
})();

// The fixture time unit is seconds; storage uses milliseconds, and the clock is injected by the caller.
const ms = (seconds: number) => seconds * 1000;
const full = (transport: ShortTransport) => fixture.transports[transport];

afterEach(() => {
  localStorage.clear();
});

describe('RL2-NEGCACHE-01 Relay negative cache storage (fixture keyCases / clearCases)', () => {
  it('RL2-NEGCACHE-01 TTL matches the fixture (7 days)', () => {
    expect(RELAY_NEGATIVE_CACHE_TTL_MS).toBe(ms(fixture.ttlSeconds));
  });

  it.each(fixture.keyCases)('RL2-NEGCACHE-01 $caseId', ({ record, query, expectHit }) => {
    recordRelayNegativeCache({ ...record, transport: full(record.transport) }, ms(record.at));
    expect(isRelayNegativeCached({ ...query, transport: full(query.transport) }, ms(query.at))).toBe(expectHit);
  });

  it.each(fixture.clearCases)('RL2-NEGCACHE-01 $caseId', ({ action, kind, target, before, after }) => {
    const at = 1000;
    for (const [connectionId, modelId, transport, entryKind] of before) {
      recordRelayNegativeCache({ connectionId, modelId, transport: full(transport), kind: entryKind }, ms(at));
    }
    if (action === 'redetect') {
      clearRelayNegativeCacheConnection(target.connectionId);
    } else {
      const kinds: RelayNegativeCacheKind[] = action === 'testedResult' ? ['image', 'toolCall'] : [kind!];
      clearRelayNegativeCache(
        { connectionId: target.connectionId, modelId: target.modelId!, transport: full(target.transport!) },
        kinds,
      );
    }
    const remaining = before.filter(([connectionId, modelId, transport, entryKind]) => isRelayNegativeCached(
      { connectionId, modelId, transport: full(transport), kind: entryKind },
      ms(at + 1),
    ));
    expect(remaining).toEqual(after);
  });

  it('RL2-NEGCACHE-01 corrupt stored data reads as empty, and writing does not throw', () => {
    localStorage.setItem(RELAY_NEGATIVE_CACHE_STORAGE_KEY, '{not json');
    const key = { connectionId: 'c1', modelId: 'm1', transport: full('chat'), kind: 'image' as const };
    expect(isRelayNegativeCached(key, ms(10))).toBe(false);
    expect(() => recordRelayNegativeCache(key, ms(10))).not.toThrow();
    expect(isRelayNegativeCached(key, ms(11))).toBe(true);
  });
});

describe('RL2-NEGCACHE-03 vision entry (fixture visionEntryCases, via production resolveAttachmentCapabilities)', () => {
  beforeEach(() => {
    resetCapabilityEvidenceIdentitiesForTesting();
  });
  afterEach(() => {
    resetCapabilityEvidenceIdentitiesForTesting();
  });

  function relayProvider(model: AIModel, engine: boolean): Provider {
    const requested = makeRelayRequested('openai_compatible');
    requested.authMode = 'none';
    requested.securityMode = 'local_http';
    requested.transport = 'openai_chat_completions';
    requested.resolvedAPIBaseURL = 'http://127.0.0.1:11434/v1';
    if (engine) requested.engineProfile = 'ollama';
    return {
      id: 'relay-vision-entry',
      kind: 'relay',
      status: { kind: 'connected' },
      models: [model],
      catalogModels: [model],
      apiKey: '',
      apiKeyPreview: '',
      baseURLText: 'http://127.0.0.1:11434',
      relayKind: 'openai_compatible',
      relayRequested: requested,
      relayResolvedBaseURLText: 'http://127.0.0.1:11434/v1',
      relayResolvedTransport: 'openai_chat_completions',
      relayResolvedAuthMode: 'none',
    };
  }

  /** The vision negative cache only reads v2: record one at the production write target (the same key and verdict revision as the projection). */
  function recordImageRejection(provider: Provider, model: AIModel, at = Date.now()) {
    const streamOptions = buildProviderStreamOptions(provider, buildStreamOptionsFromIntent(model, 'automatic', false), model);
    const target = inputNegativeCacheTarget(provider, model, streamOptions, 'vision_input');
    expect(target).not.toBeNull();
    recordInputNegativeCache(target!.key, { signatureId: 'test.rejected', verdictRevision: target!.verdictRevision }, at);
  }

  function officialProvider(model: AIModel): Provider {
    return {
      id: 'official-vision-entry', kind: 'openAI', status: { kind: 'connected' }, models: [model], catalogModels: [model],
      apiKey: '', apiKeyPreview: '',
    } as Provider;
  }

  it.each(fixture.visionEntryCases)('RL2-NEGCACHE-03 $caseId', (item) => {
    const base = createRelayManualModel('oriveo-fixture-vision-entry', true);
    const model: AIModel = {
      ...base,
      ...(item.engineDeclarationImage !== null ? { engineDeclaration: { image: item.engineDeclarationImage } } : {}),
      ...(item.override ? { relayCapabilityOverrides: { image: item.override } } : {}),
    };
    const provider = item.form === 'relay'
      ? relayProvider(model, item.engineDeclarationImage !== null)
      : officialProvider(model);
    beginCapabilityEvidenceIdentityIfAbsent(getActiveUIDSync(), provider.id);
    if (item.imageNegCached) recordImageRejection(provider, model);
    const envelope = resolveProviderAttachmentSupport(provider, model)
      ?? { image: true, nativeFile: false, textFileInline: true };
    const support = { ...envelope, image: item.envelopeAllowsImage };
    const supportsImage = resolveAttachmentCapabilities(provider, model, support).supportsImage;
    if (!item.e39Expect) {
      expect(supportsImage).toBe(item.expectVisible);
      return;
    }
    const streamOptions = buildProviderStreamOptions(provider, buildStreamOptionsFromIntent(model, 'automatic', false), model);
    const projection = resolveInputCapabilityProjections(provider, model, streamOptions, {
      relayEnvelopeImage: support.image,
    })?.vision_input;
    expect({ visible: projection?.visible, editable: projection?.editable }).toEqual(item.e39Expect);
    // The vision entry is exactly the projection's editable.
    expect(supportsImage).toBe(item.e39Expect.editable);
  });

  function toolSupport(provider: Provider, model: AIModel) {
    return resolveModelCapabilityEvidence({
      key: 'tool_call',
      provider,
      model,
      streamOptions: buildProviderStreamOptions(provider, buildStreamOptionsFromIntent(model, 'automatic', false), model),
    }).support;
  }

  it('Relay toolCall negative cache not expired -> tool_call unsupported; override true beats the negative cache and the engine declaration', () => {
    const base = createRelayManualModel('oriveo-fixture-tool', true);
    const declared: AIModel = { ...base, engineDeclaration: { toolCall: true } };
    const provider = relayProvider(declared, true);
    beginCapabilityEvidenceIdentityIfAbsent(getActiveUIDSync(), provider.id);
    expect(toolSupport(provider, declared)).toBe('supported');
    recordRelayNegativeCache({
      connectionId: provider.id, modelId: declared.id, transport: effectiveTransport(provider, declared), kind: 'toolCall',
    });
    expect(toolSupport(provider, declared)).toBe('unsupported');
    const overridden: AIModel = { ...declared, relayCapabilityOverrides: { toolCall: { value: true, source: 'tested' } } };
    expect(toolSupport(provider, overridden)).toBe('supported');
    const userFalse: AIModel = { ...declared, relayCapabilityOverrides: { toolCall: { value: false, source: 'user' } } };
    clearRelayNegativeCacheConnection(provider.id);
    expect(toolSupport(provider, userFalse)).toBe('unsupported');
  });

  it('RL2-NEGCACHE-03 when no connection identity is available, Relay vision unknown stays hidden (fail-closed)', () => {
    const model = createRelayManualModel('oriveo-fixture-vision-entry', true);
    const provider = relayProvider(model, false);
    // Do not register a connection identity.
    expect(resolveAttachmentCapabilities(provider, model, { image: true, nativeFile: false, textFileInline: true })
      .supportsImage).toBe(false);
  });

  it('RL2-NEGCACHE-03 after the image negative cache expires the entry comes back', () => {
    const model = createRelayManualModel('oriveo-fixture-vision-entry', true);
    const provider = relayProvider(model, false);
    beginCapabilityEvidenceIdentityIfAbsent(getActiveUIDSync(), provider.id);
    recordImageRejection(provider, model, Date.now() - INPUT_NEGATIVE_CACHE_TTL_MS - 1);
    expect(resolveAttachmentCapabilities(provider, model, { image: true, nativeFile: false, textFileInline: true })
      .supportsImage).toBe(true);
  });
});
