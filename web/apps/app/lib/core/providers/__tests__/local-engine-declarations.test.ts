import fs from 'node:fs';
import path from 'node:path';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { makeRelayRequested, type AIModel, type LocalEngineKind, type Provider } from '@oriveo/shared';
import { connectLocalEngineInBrowser, fingerprintLocalEngineInBrowser } from '../local-browser-probe';
import { createRelayManualModel } from '../../provider-model-ops';
import { resolveAttachmentCapabilities, resolveProviderAttachmentSupport } from '../../chat/attachment-policy';
import { resolveModelCapabilityEvidence } from '../../chat/capability-evidence';
import { buildProviderStreamOptions, buildStreamOptionsFromIntent } from '../../chat/stream-options';
import {
  beginCapabilityEvidenceIdentityIfAbsent,
  resetCapabilityEvidenceIdentitiesForTesting,
} from '../capability-evidence-identity';
import { getActiveUIDSync } from '../../../infra/storage/partition';

const mocks = vi.hoisted(() => ({ sendMessageStream: vi.fn() }));

vi.mock('../adapters/relay', () => ({
  sendMessageStream: (...args: unknown[]) => mocks.sendMessageStream(...args),
}));

type RecordedResponse = { status: number; contentType: string; body?: unknown; text?: string };
type RecordedExchange = {
  request: { method: string; path: string; body?: { model?: string } };
  response: RecordedResponse;
};
type RecordedEngine = {
  status: 'recorded' | 'pending';
  records?: RecordedExchange[];
  instances?: Record<string, { records: RecordedExchange[] }>;
};
type ResponsePointer = { engine: string; instance?: string; all?: boolean; path?: string };
type Expectations = {
  channels: Record<string, string> & { byEngine: Record<string, string[]> };
  fingerprint: {
    requests: string[];
    cases: Array<{
      caseId: string;
      status?: 'pending';
      unreachable?: boolean;
      responses: ResponsePointer[];
      expect: { outcome: 'engine' | 'generic' | 'manual'; engineProfile?: string; channel?: string };
    }>;
  };
  declarations: {
    cases: Array<{
      caseId: string;
      engine: LocalEngineKind;
      instance?: string;
      modelId: string;
      inChatCatalog?: boolean;
      expect?: { image: boolean | null; toolCall: boolean | null; thinking: boolean | null };
    }>;
  };
};

function fixture<T>(name: string): T {
  let directory = process.cwd();
  while (path.dirname(directory) !== directory) {
    const candidate = path.join(directory, 'shared/test-fixtures/local-engine', name);
    if (fs.existsSync(candidate)) return JSON.parse(fs.readFileSync(candidate, 'utf8')) as T;
    directory = path.dirname(directory);
  }
  throw new Error(`local engine fixture ${name} not found`);
}

const expectations = fixture<Expectations>('engine-expectations.v1.json');
const recordings = fixture<{ engines: Record<string, RecordedEngine> }>('engine-declarations.v1.json');
const ENDPOINT = 'http://127.0.0.1:18080';

function recordsOf(engine: string, instance?: string): RecordedExchange[] {
  const entry = recordings.engines[engine];
  if (!entry || entry.status !== 'recorded') throw new Error(`${engine} has no recording`);
  const records = instance ? entry.instances?.[instance]?.records : entry.records;
  if (!records) throw new Error(`${engine}/${instance ?? '-'} has no records`);
  return records;
}

/** Fake server: replies only with the recorded originals; any path the fixture does not list gets 404 text/plain (fixture $comment). */
function serveRecordings(pointers: ResponsePointer[], unreachable = false) {
  const served: RecordedExchange[] = pointers.flatMap((pointer) => {
    const records = recordsOf(pointer.engine, pointer.instance);
    return pointer.all ? records : records.filter((record) => record.request.path === pointer.path);
  });
  const requests: string[] = [];
  vi.spyOn(globalThis, 'fetch').mockImplementation(async (input, init) => {
    const url = new URL(String(input));
    const method = init?.method ?? 'GET';
    requests.push(`${method} ${url.pathname}`);
    if (unreachable) throw new TypeError('Failed to fetch');
    const requestedModel = typeof init?.body === 'string'
      ? (JSON.parse(init.body) as { model?: string }).model
      : undefined;
    const hit = served.find((record) => record.request.method === method
      && record.request.path === url.pathname
      && (record.request.body?.model === undefined || record.request.body.model === requestedModel));
    if (!hit) {
      return new Response('404 page not found', { status: 404, headers: { 'content-type': 'text/plain' } });
    }
    const payload = hit.response.body !== undefined ? JSON.stringify(hit.response.body) : hit.response.text ?? '';
    return new Response(payload, { status: hit.response.status, headers: { 'content-type': hit.response.contentType } });
  });
  return requests;
}

function generationSucceeds() {
  mocks.sendMessageStream.mockReturnValue({
    abort: vi.fn(),
    stream: new ReadableStream<string>({
      start(controller) {
        controller.enqueue('ok');
        controller.close();
      },
    }),
  });
}

function engineOf(engine: LocalEngineKind, instance?: string): ResponsePointer[] {
  return [{ engine, instance, all: true }];
}

/** The fixture's null = missing key. */
function declarationFromExpect(value: { image: boolean | null; toolCall: boolean | null; thinking: boolean | null }) {
  return Object.fromEntries(Object.entries(value).filter(([, item]) => item !== null));
}

beforeEach(() => {
  vi.restoreAllMocks();
  mocks.sendMessageStream.mockReset();
  Object.defineProperty(navigator, 'permissions', {
    configurable: true,
    value: { query: vi.fn().mockResolvedValue({ state: 'granted' }) },
  });
});

describe('RL2-ENGINE-01 local engine fingerprint (production fetch hits the recorded originals)', () => {
  for (const item of expectations.fingerprint.cases) {
    if (item.status === 'pending') {
      it(`RL2-ENGINE-01 ${item.caseId} is still pending (recording absent, no hand-written response)`, () => {
        for (const pointer of item.responses) {
          expect(recordings.engines[pointer.engine]?.status).toBe('pending');
        }
      });
      it.skip(`RL2-ENGINE-01 ${item.caseId}`, () => {});
      continue;
    }
    it(`RL2-ENGINE-01 ${item.caseId}`, async () => {
      const requests = serveRecordings(item.responses, item.unreachable === true);
      const result = await fingerprintLocalEngineInBrowser({ endpoint: ENDPOINT, securityMode: 'local_http' });

      // All five read-only GETs are sent, no more and no fewer.
      expect([...requests].sort()).toEqual(expectations.fingerprint.requests.map((p) => `GET ${p}`).sort());
      if (item.expect.outcome === 'manual') {
        expect(result).toEqual({ outcome: 'manual' });
      } else if (item.expect.outcome === 'generic') {
        expect(result).toEqual({ outcome: 'generic', channel: expectations.channels[item.expect.channel!] });
      } else {
        expect(result).toEqual({
          outcome: 'engine',
          engineProfile: item.expect.engineProfile,
          channel: expectations.channels[item.expect.channel!],
        });
      }
    });
  }
});

describe('RL2-ENGINE-01 a failed request only makes that criterion miss', () => {
  it('RL2-ENGINE-01 401 / 403 / non-JSON / network errors never throw, and fall to generic by the remaining criteria', async () => {
    const ollamaModels = recordsOf('ollama').find((record) => record.request.path === '/v1/models')!.response;
    vi.spyOn(globalThis, 'fetch').mockImplementation(async (input) => {
      const pathname = new URL(String(input)).pathname;
      if (pathname === '/props') return new Response('{}', { status: 401, headers: { 'content-type': 'application/json' } });
      if (pathname === '/api/tags') return new Response(JSON.stringify({ models: [] }), { status: 403, headers: { 'content-type': 'application/json' } });
      if (pathname === '/api/v0/models') return new Response('<html>', { status: 200, headers: { 'content-type': 'text/html' } });
      if (pathname === '/version') throw new TypeError('Failed to fetch');
      return new Response(JSON.stringify(ollamaModels.body), { status: 200, headers: { 'content-type': ollamaModels.contentType } });
    });
    await expect(fingerprintLocalEngineInBrowser({ endpoint: ENDPOINT, securityMode: 'local_http' }))
      .resolves.toEqual({ outcome: 'generic', channel: expectations.channels.chat });
  });

  it('RL2-ENGINE-01 when the connection policy rejects, no request is sent and nothing throws, landing on manual', async () => {
    const fetchMock = vi.spyOn(globalThis, 'fetch');
    // A public plaintext address is rejected by the connection policy under local_http.
    await expect(fingerprintLocalEngineInBrowser({ endpoint: 'http://203.0.113.9:8080', securityMode: 'local_http' }))
      .resolves.toEqual({ outcome: 'manual' });
    expect(fetchMock).not.toHaveBeenCalled();
  });
});

describe('RL2-ENGINE-02 per-model declarations (production connector hits the recorded originals)', () => {
  for (const item of expectations.declarations.cases) {
    const recorded = recordings.engines[item.engine]?.status === 'recorded';
    if (!recorded) {
      // vLLM has no recording: the connector reads no response body, so an empty declaration can only come from the same production parse function.
      it(`RL2-ENGINE-02 ${item.caseId} the engine declares no capabilities`, async () => {
        const { localEngineModelDeclaration } = await import('@oriveo/shared');
        expect(localEngineModelDeclaration(item.engine, { id: item.modelId }, undefined))
          .toEqual(declarationFromExpect(item.expect!));
      });
      continue;
    }
    it(`RL2-ENGINE-02 ${item.caseId}`, async () => {
      serveRecordings(engineOf(item.engine, item.instance));
      generationSucceeds();
      const result = await connectLocalEngineInBrowser({
        engine: item.engine,
        endpoint: ENDPOINT,
        securityMode: 'local_http',
      });
      expect(result).toMatchObject({ state: 'ready', generationVerified: true });
      const model = result.models.find((row) => row.id === item.modelId);
      if (item.inChatCatalog === false) {
        expect(result.modelIDs).not.toContain(item.modelId);
        expect(model).toBeUndefined();
        return;
      }
      expect(result.modelIDs).toContain(item.modelId);
      const expected = declarationFromExpect(item.expect!);
      if (Object.keys(expected).length === 0) {
        expect(model).not.toHaveProperty('engineDeclaration');
      } else {
        expect(model?.engineDeclaration).toEqual(expected);
      }
    });
  }
});

describe('RL2-ENGINE-02 declarations enter capability evidence: photo library entry', () => {
  beforeEach(() => {
    resetCapabilityEvidenceIdentitiesForTesting();
  });
  afterEach(() => {
    resetCapabilityEvidenceIdentitiesForTesting();
    localStorage.clear();
  });

  /** Same shape as when the add page saves: a local Relay connection + the per-model declarations given by the connector. */
  function localProvider(
    engine: LocalEngineKind | undefined,
    connected: Awaited<ReturnType<typeof connectLocalEngineInBrowser>>,
  ): Provider {
    const requested = makeRelayRequested('openai_compatible');
    requested.authMode = 'none';
    requested.securityMode = 'local_http';
    requested.transport = 'openai_chat_completions';
    requested.resolvedAPIBaseURL = connected.apiBaseURL;
    if (engine) requested.engineProfile = engine;
    const models: AIModel[] = connected.models.map((runtime, index) => ({
      ...createRelayManualModel(runtime.id, index === 0),
      ...(runtime.engineDeclaration ? { engineDeclaration: runtime.engineDeclaration } : {}),
    }));
    return {
      id: `local-${engine ?? 'plain'}`,
      kind: 'relay',
      status: { kind: 'connected' },
      models,
      catalogModels: models,
      apiKey: '',
      apiKeyPreview: '',
      baseURLText: connected.endpoint,
      relayKind: 'openai_compatible',
      relayRequested: requested,
      relayResolvedBaseURLText: connected.apiBaseURL,
      relayResolvedTransport: 'openai_chat_completions',
      relayResolvedAuthMode: 'none',
    };
  }

  async function connectOllama() {
    serveRecordings(engineOf('ollama'));
    generationSucceeds();
    return connectLocalEngineInBrowser({ engine: 'ollama', endpoint: ENDPOINT, securityMode: 'local_http' });
  }

  /** The same production path as the attachment policy: the actually dispatched parameters decide the connection identity. */
  function evidence(provider: Provider, modelId: string, key: 'vision_input' | 'tool_call') {
    const model = provider.models.find((item) => item.id === modelId)!;
    return resolveModelCapabilityEvidence({
      key,
      provider,
      model,
      streamOptions: buildProviderStreamOptions(provider, buildStreamOptionsFromIntent(model, 'automatic', false), model),
    });
  }

  function photoEntryVisible(provider: Provider, modelId: string): boolean {
    const model = provider.models.find((item) => item.id === modelId)!;
    return resolveAttachmentCapabilities(provider, model, resolveProviderAttachmentSupport(provider, model)).supportsImage;
  }

  it('RL2-ENGINE-02 image true -> vision_input supported and the photo library entry is visible; false -> unsupported and hidden', async () => {
    const provider = localProvider('ollama', await connectOllama());
    beginCapabilityEvidenceIdentityIfAbsent(getActiveUIDSync(), provider.id);

    expect(photoEntryVisible(provider, 'oriveo-fixture-smolvlm:latest')).toBe(true);
    expect(photoEntryVisible(provider, 'qwen3:0.6b')).toBe(false);

    const vision = (modelId: string) => evidence(provider, modelId, 'vision_input');
    expect(vision('oriveo-fixture-smolvlm:latest')).toMatchObject({ support: 'supported', source: 'relay_declaration' });
    expect(vision('qwen3:0.6b')).toMatchObject({ support: 'unsupported', source: 'relay_declaration' });
  });

  it('RL2-ENGINE-02 a declaration replaces the source but not the line: when the protocol envelope cannot hold an image, image true still does not show', async () => {
    const provider = localProvider('ollama', await connectOllama());
    beginCapabilityEvidenceIdentityIfAbsent(getActiveUIDSync(), provider.id);
    const model = provider.models.find((item) => item.id === 'oriveo-fixture-smolvlm:latest')!;
    expect(evidence(provider, model.id, 'vision_input').support).toBe('supported');
    // The line gate comes from the production criterion; here only the "current protocol envelope" is swapped for one that cannot hold an image.
    const envelope = resolveProviderAttachmentSupport(provider, model);
    expect(envelope?.image).toBe(true);
    expect(resolveAttachmentCapabilities(provider, model, { ...envelope!, image: false }).supportsImage).toBe(false);
  });

  it('RL2-ENGINE-02 toolCall true / false likewise land as tool_call supported / unsupported', async () => {
    const provider = localProvider('ollama', await connectOllama());
    beginCapabilityEvidenceIdentityIfAbsent(getActiveUIDSync(), provider.id);
    const toolCall = (modelId: string) => evidence(provider, modelId, 'tool_call').support;
    expect(toolCall('qwen2.5:0.5b')).toBe('supported');
    expect(toolCall('tinyllama:latest')).toBe('unsupported');
  });

  it('RL2-ENGINE-02 a connection without engineProfile does not read declarations; image recognition unknown shows the photo library entry', async () => {
    const connected = await connectOllama();
    const provider = localProvider(undefined, connected);
    beginCapabilityEvidenceIdentityIfAbsent(getActiveUIDSync(), provider.id);
    // The same models carry declarations, but the connection has no engineProfile: declarations do not enter the evidence and image recognition is unknown;
    // Relay image recognition unknown still shows the entry (the original assertion "not visible" was rewritten accordingly).
    expect(provider.models.find((item) => item.id === 'oriveo-fixture-smolvlm:latest')?.engineDeclaration)
      .toEqual({ image: true, toolCall: false, thinking: false });
    expect(photoEntryVisible(provider, 'oriveo-fixture-smolvlm:latest')).toBe(true);
    // qwen3 declares image false, but without an engineProfile on the connection it is likewise not read and the entry still shows -- proving visibility is not from reading the declaration.
    expect(photoEntryVisible(provider, 'qwen3:0.6b')).toBe(true);
    expect(evidence(provider, 'qwen3:0.6b', 'vision_input').source).not.toBe('relay_declaration');
    expect(evidence(provider, 'qwen2.5:0.5b', 'tool_call').source).not.toBe('relay_declaration');
  });
});
