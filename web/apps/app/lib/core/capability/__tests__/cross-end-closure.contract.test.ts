// Cross-end closure shared fixture.
// Fixture: shared/test-fixtures/capability/cross-end-closure.v1.json (dateTimeCases / bundledInputCases / relayVideoEnvelopeCases);
// newChatDefaultCases live in providers/__tests__/provider-selection-snapshot.test.ts. Every case calls production functions.

import 'fake-indexeddb/auto';
import { existsSync, readFileSync } from 'node:fs';
import path from 'node:path';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { makeRelayRequested, type AIModel, type Provider } from '@oriveo/shared';
import {
  projectInputCapability,
  type InputCapabilityProjectionInput,
} from '@oriveo/core/providers/capability-evidence-facade';

vi.mock('../../../infra/storage/partition', async (importOriginal) => ({
  ...(await importOriginal<typeof import('../../../infra/storage/partition')>()),
  getActiveUIDSync: () => 'account-a',
}));

import { getActiveUIDSync } from '../../../infra/storage/partition';
import { fullOrIndex } from '../../metadata/metadata-payload-validators.generated.js';
import { resolveAttachmentCapabilities } from '../../chat/attachment-policy';
import { rememberRelayCatalogEndpointTypes } from '../../providers/relay-probe-candidates';
import { relayFirstSendTransport } from '../../providers/relay-first-send-transport';
import {
  beginCapabilityEvidenceIdentityIfAbsent,
  resetCapabilityEvidenceIdentitiesForTesting,
} from '../../providers/capability-evidence-identity';

type Protocol = 'chat' | 'responses' | 'messages';
type InputKey = 'vision_input' | 'file_input' | 'video_input';

interface ExpectedProjection {
  visible: boolean;
  editable: boolean;
  outbound: string;
  hint: string | null;
  disabledReason: string | null;
}

interface Fixture {
  dateTimeCases: { appliesTo: string[]; cases: Array<{ id: string; value: string; valid: boolean }> };
  bundledInputCases: {
    appliesTo: string[];
    cases: Array<{
      id: string;
      catalogSource: string;
      key: InputKey;
      verdict: InputCapabilityProjectionInput['verdict'];
      endImplements: boolean;
      connection: 'official' | 'relay';
      expect: ExpectedProjection;
    }>;
  };
  relayVideoEnvelopeCases: {
    appliesTo: string[];
    cases: Array<{
      id: string;
      firstSend: Protocol;
      envelope: { image: boolean; nativeFile: boolean } | null;
      connectionEvidence: null;
      key: InputKey;
      expect: ExpectedProjection;
    }>;
  };
}

function fixturePath(): string {
  let dir = process.cwd();
  for (let i = 0; i < 8; i += 1) {
    const candidate = path.join(dir, 'shared/test-fixtures/capability/cross-end-closure.v1.json');
    if (existsSync(candidate)) return candidate;
    dir = path.dirname(dir);
  }
  throw new Error('cross-end-closure.v1.json not found');
}

const FIXTURE = JSON.parse(readFileSync(fixturePath(), 'utf8')) as Fixture;

const TRANSPORT = {
  chat: 'openai_chat_completions',
  responses: 'openai_responses',
  messages: 'anthropic_messages',
} as const;
const ENDPOINT_TYPES: Readonly<Record<Protocol, string[]>> = {
  chat: ['openai'],
  responses: ['openai-response'],
  messages: ['anthropic', 'openai'],
};
const MEDIA_BY_KEY = { vision_input: 'image', file_input: 'file', video_input: 'video' } as const;

function relayConnection(id: string, firstSend: Protocol): { provider: Provider; model: AIModel } {
  const model: AIModel = {
    id: `closure-${id}`,
    name: `closure-${id}`,
    capabilities: ['text'],
    reasoningModeAvailable: false,
    isAvailable: true,
    isDefault: false,
    priceTier: '',
  };
  const requested = makeRelayRequested('openai_compatible');
  requested.authMode = 'bearer';
  requested.transport = 'auto';
  requested.resolvedAPIBaseURL = 'https://api.closure.dev/v1';
  const provider: Provider = {
    id: 'relay-closure',
    kind: 'relay',
    customName: 'closure.dev',
    status: { kind: 'connected' },
    models: [model],
    catalogModels: [model],
    apiKey: 'sk-relay-closure-0123456789',
    apiKeyPreview: 'sk-r…6789',
    baseURLText: 'https://api.closure.dev',
    relayKind: 'openai_compatible',
    relayRequested: requested,
    relayResolvedBaseURLText: 'https://api.closure.dev/v1',
    relayResolvedAuthMode: 'bearer',
  };
  rememberRelayCatalogEndpointTypes(provider.id, { [model.id]: ENDPOINT_TYPES[firstSend] });
  beginCapabilityEvidenceIdentityIfAbsent(getActiveUIDSync(), provider.id);
  return { provider, model };
}

beforeEach(() => {
  localStorage.clear();
  resetCapabilityEvidenceIdentitiesForTesting();
});

describe('CLOSURE dateTimeCases', () => {
  it('applies to web', () => {
    expect(FIXTURE.dateTimeCases.appliesTo).toContain('web');
    expect(FIXTURE.dateTimeCases.cases.length).toBeGreaterThan(0);
  });
  for (const c of FIXTURE.dateTimeCases.cases) {
    it(`CLOSURE-${c.id}`, () => {
      const payload = { metadataSchema: 2, metadataRevision: 1, generatedAt: c.value, contractVersion: 1, providers: {} };
      const valid = fullOrIndex(payload);
      expect(valid).toBe(c.valid);
      if (!c.valid) {
        expect(fullOrIndex.errors?.some((error) => error.keyword === 'format' && error.instancePath === '/generatedAt')).toBe(true);
      }
    });
  }
});

describe('CLOSURE bundledInputCases', () => {
  it('applies to web', () => {
    expect(FIXTURE.bundledInputCases.appliesTo).toContain('web');
    expect(FIXTURE.bundledInputCases.cases.length).toBeGreaterThan(0);
  });
  for (const c of FIXTURE.bundledInputCases.cases) {
    it(`CLOSURE-${c.id}`, () => {
      // Web has no bundled-snapshot downgrade branch: bundled and online catalogs share one projection.
      expect(c.catalogSource).toBe('bundled');
      const projection = projectInputCapability({
        key: c.key,
        verdict: c.verdict,
        endImplements: c.endImplements,
        override: null,
        negativeCacheHit: false,
        connection: c.connection,
      });
      expect(projection).toEqual(c.expect);
    });
  }
});

describe('CLOSURE relayVideoEnvelopeCases', () => {
  it('applies to web', () => {
    expect(FIXTURE.relayVideoEnvelopeCases.appliesTo).toContain('web');
    expect(FIXTURE.relayVideoEnvelopeCases.cases.length).toBeGreaterThan(0);
  });
  for (const c of FIXTURE.relayVideoEnvelopeCases.cases) {
    it(`CLOSURE-${c.id}`, () => {
      const { provider, model } = relayConnection(c.id, c.firstSend);
      expect(relayFirstSendTransport(provider, model)).toBe(TRANSPORT[c.firstSend]);
      const support = c.envelope ? { ...c.envelope, textFileInline: true } : null;
      const capabilities = resolveAttachmentCapabilities(provider, model, support);
      const media = MEDIA_BY_KEY[c.key];
      expect(capabilities.projections[media]).toEqual(c.expect);
      expect(capabilities.disabledReasons[media]).toBe(c.expect.disabledReason);
    });
  }
});
