import fs from 'node:fs';
import path from 'node:path';
import { act, renderHook } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import {
  localEngineChannelCandidates,
  makeRelayRequested,
  type AIModel,
  type Provider,
  type RelayKind,
  type RelayRequestedConfig,
} from '@oriveo/shared';
import { createAppStore } from '../../store/app-store';
import { createRelayManualModel } from '../../provider-model-ops';
import { buildRelaySettingsCandidate } from '../../provider-ops';
import { planRelaySettingsSave } from '../provider-sync';
import { PROVIDER_VALIDATION_MESSAGES } from '../validation-messages';
import { redetectRelayModels } from '../../relay-model-probe-ops';
import { chatTemplateThinkingApplies } from '../../chat/chat-template-thinking';
import {
  modelOptionLocalEngine,
  resolveModelOptionCapabilityShape,
  type ModelOptionCapabilityInput,
} from '../../chat/model-option-capability-shape';
import { MODEL_OPTION_NOTICE_STATUS_KEYS } from '../../chat/model-options-copy';
import { useProviderActions } from '../../../hooks/useProviderActions';

const holder = vi.hoisted(() => ({ store: null as unknown, sendMessageStream: vi.fn() }));

vi.mock('next/navigation', () => ({ useRouter: () => ({ push: vi.fn() }) }));
vi.mock('../../../../providers/StoreProvider', () => ({ getVanillaStore: () => holder.store }));
vi.mock('../../sync', () => ({ getSyncAdapter: () => undefined }));
vi.mock('../adapters/relay', () => ({
  sendMessageStream: (...args: unknown[]) => holder.sendMessageStream(...args),
}));
vi.mock('../../metadata/metadata-client', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../../metadata/metadata-client')>();
  return { ...actual, getRelayRuntimeConfig: () => actual.DEFAULT_RELAY_RUNTIME_CONFIG };
});

type Channel = 'chat' | 'native';
type Expectations = {
  channels: { chat: string; native: string; byEngine: Record<string, Channel[]>; selectorShownOnlyWhenMoreThanOne: boolean };
  thinking: {
    cases: Array<{
      caseId: string;
      engineProfile: string | null;
      channel: Channel;
      declaredThinking: boolean | null;
      expect: 'toggle' | 'nonChatNotice' | 'usesModelDefaultNotice' | 'unsupported';
    }>;
  };
  edit: {
    connection: { baseURL: string; relayRequested: RelayRequestedConfig };
    cases: Array<{
      caseId: string;
      change: { baseURL?: string; apiKey?: string; transport?: RelayRequestedConfig['transport']; relayKind?: string };
      verification?: 'passes' | 'fails';
      expect: { keepsEngineFields: boolean; verifiesDefaultModel?: boolean | 'as today'; transport?: string; verified?: boolean };
    }>;
  };
};
type RecordedExchange = {
  request: { method: string; path: string; body?: { model?: string } };
  response: { status: number; contentType: string; body?: unknown; text?: string };
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
const recordings = fixture<{ engines: Record<string, { status: string; records?: RecordedExchange[] }> }>('engine-declarations.v1.json');
const ENGINE_FIELDS = ['engineProfile', 'securityMode', 'certificateFingerprint'] as const;
const DEFAULT_MODEL = 'local-default';

function engineFieldsOf(requested: RelayRequestedConfig | null | undefined) {
  return Object.fromEntries(ENGINE_FIELDS.map((key) => [key, requested?.[key]]));
}

function editConnection(): Provider {
  const { baseURL, relayRequested } = expectations.edit.connection;
  const model = createRelayManualModel(DEFAULT_MODEL, true);
  return {
    id: 'local-edit',
    kind: 'relay',
    status: { kind: 'connected' },
    models: [model],
    catalogModels: [model],
    apiKey: '',
    apiKeyPreview: '',
    baseURLText: baseURL,
    relayKind: 'openai_compatible',
    relayRequested: { ...relayRequested, authMode: 'none', modelID: DEFAULT_MODEL } as RelayRequestedConfig,
  };
}

beforeEach(() => {
  vi.restoreAllMocks();
  holder.sendMessageStream.mockReset();
  localStorage.clear();
  Object.defineProperty(navigator, 'permissions', {
    configurable: true,
    value: { query: vi.fn().mockResolvedValue({ state: 'granted' }) },
  });
});

describe('RL2-ENGINE-04 the local engine thinking row is judged by the write-path table (production projection)', () => {
  for (const item of expectations.thinking.cases) {
    it(`RL2-ENGINE-04 ${item.caseId}`, () => {
      const transport = expectations.channels[item.channel] as RelayRequestedConfig['transport'];
      const requested: RelayRequestedConfig = {
        transport,
        authMode: 'none',
        ...(item.engineProfile ? { engineProfile: item.engineProfile as RelayRequestedConfig['engineProfile'] } : {}),
      };
      const model: AIModel = {
        ...createRelayManualModel('local-model', true),
        ...(item.declaredThinking === null ? {} : { engineDeclaration: { thinking: item.declaredThinking } }),
      };
      // Same input slots as the model options popover: the protocol gate is given as before, and local engine facts are taken from the connection and model by production functions.
      const localEngine = modelOptionLocalEngine({ baseURLText: 'http://127.0.0.1:18080', relayRequested: requested }, model);
      const input: ModelOptionCapabilityInput = {
        capability: 'reasoning',
        status: 'unknown',
        availableIntents: [],
        connection: 'custom',
        isWritable: true,
        protocolUndecided: false,
        rejectedIntents: [],
        chatTemplateThinkingIsOn: false,
        supportsChatTemplate: chatTemplateThinkingApplies(transport),
        ...(localEngine ? { localEngine } : {}),
      };
      const shape = resolveModelOptionCapabilityShape(input);
      switch (item.expect) {
        case 'toggle':
          expect(shape).toMatchObject({ kind: 'toggle', target: { kind: 'chatTemplateThinking' } });
          break;
        case 'nonChatNotice':
          expect(shape).toMatchObject({ kind: 'notice', status: 'needsOwnConfiguration', body: { kind: 'customOnly' } });
          break;
        case 'usesModelDefaultNotice':
          expect(shape).toMatchObject({ kind: 'notice', status: 'modelDefault' });
          // Use only existing copy: "Uses the model’s default".
          expect(MODEL_OPTION_NOTICE_STATUS_KEYS[(shape as { status: 'modelDefault' }).status])
            .toBe('common.modelOptionsUsesModelDefault');
          break;
        case 'unsupported':
          expect(shape).toMatchObject({ kind: 'disclosure', status: { kind: 'modelLacksCapability' } });
          break;
      }
    });
  }
});

describe('RL2-ENGINE-03 channel candidates only by channels.byEngine', () => {
  for (const [engine, channels] of Object.entries(expectations.channels.byEngine)) {
    it(`RL2-ENGINE-03 channel candidates of ${engine}`, () => {
      const candidates = localEngineChannelCandidates(engine as RelayRequestedConfig['engineProfile']);
      expect(candidates.transports).toEqual(channels.map((channel) => expectations.channels[channel]));
      expect(candidates.showsSelector).toBe(channels.length > 1);
    });
  }
});

describe('RL2-ENGINE-03 editing a local connection keeps the three engine fields', () => {
  beforeEach(() => {
    const store = createAppStore();
    store.getState().addProvider(editConnection());
    holder.store = store;
  });

  const store = () => holder.store as ReturnType<typeof createAppStore>;
  const original = () => engineFieldsOf(expectations.edit.connection.relayRequested);

  function generation(result: 'passes' | 'fails') {
    return vi.spyOn(globalThis, 'fetch').mockImplementation(async () => (result === 'passes'
      ? new Response(JSON.stringify({
        content: 'ok',
        choices: [{ index: 0, message: { role: 'assistant', content: 'ok' }, finish_reason: 'stop' }],
      }), { status: 200, headers: { 'content-type': 'application/json' } })
      : new Response(JSON.stringify({ error: { message: 'upstream down' } }), {
        status: 500, headers: { 'content-type': 'application/json' },
      })));
  }

  for (const item of expectations.edit.cases) {
    it(`RL2-ENGINE-03 ${item.caseId}`, async () => {
      const canonical = store().getState().providers[0];
      if (item.change.relayKind) {
        // Every type the client offers must keep the three fields (RelayDetail switching type goes through makeRelayRequested).
        const kinds: RelayKind[] = ['openai_compatible', 'codex_style', 'anthropic_compatible', 'gemini_compatible', 'custom'];
        for (const kind of kinds) {
          expect(engineFieldsOf(makeRelayRequested(kind, canonical.relayRequested!)), kind).toEqual(original());
        }
        return;
      }
      if (item.change.baseURL) {
        const relayRequested = { ...canonical.relayRequested!, resolvedAPIBaseURL: undefined };
        const candidate = buildRelaySettingsCandidate(canonical, {
          baseURLText: item.change.baseURL, relayKind: canonical.relayKind!, relayRequested,
        });
        expect(planRelaySettingsSave(canonical, candidate).needsVerification).toBe(true);
        expect(engineFieldsOf(candidate.relayRequested)).toEqual(original());
        return;
      }
      if (item.change.apiKey) {
        const candidate = { ...canonical, apiKey: item.change.apiKey };
        expect(planRelaySettingsSave(canonical, candidate).needsVerification).toBe(true);
        expect(engineFieldsOf(candidate.relayRequested)).toEqual(original());
        return;
      }

      // Change channel: reuse the existing "Verify and save"; on verification failure take the existing "Save anyway (unverified)".
      const fetchMock = generation(item.verification!);
      const view = renderHook(() => useProviderActions(canonical));
      const patch = {
        relayKind: canonical.relayKind!,
        relayRequested: { ...canonical.relayRequested!, transport: item.change.transport! },
      };
      expect(view.result.current.relaySettingsSavePlan(patch).needsVerification).toBe(true);
      await act(async () => {
        await expect(view.result.current.saveRelaySettings(patch)).resolves.toBe(item.expect.verified);
      });
      expect(fetchMock).toHaveBeenCalled();
      if (!item.expect.verified) {
        await act(async () => {
          await expect(view.result.current.saveRelaySettingsUnverified()).resolves.toBe(true);
        });
      }
      const saved = store().getState().providers[0];
      expect(saved.relayRequested?.transport).toBe(item.expect.transport);
      expect(engineFieldsOf(saved.relayRequested)).toEqual(original());
      expect(saved.status).toEqual(item.expect.verified
        ? { kind: 'connected' }
        : { kind: 'issue', message: PROVIDER_VALIDATION_MESSAGES.unverified });
      view.unmount();
    });
  }
});

describe('RL2-ENGINE-02 re-detecting a local connection', () => {
  it('RL2-ENGINE-02 when re-detection cannot read declarations, the old declarations are kept', async () => {
    vi.spyOn(globalThis, 'fetch').mockRejectedValue(new TypeError('Failed to fetch'));
    const old = { image: true, toolCall: false, thinking: false };
    const model: AIModel = { ...createRelayManualModel('qwen3:0.6b', true), engineDeclaration: old };
    const provider: Provider = {
      id: 'local-ollama-down', kind: 'relay', status: { kind: 'connected' }, models: [model], catalogModels: [model],
      apiKey: '', apiKeyPreview: '', baseURLText: 'http://127.0.0.1:18080', relayKind: 'openai_compatible',
      relayRequested: { transport: 'openai_chat_completions', authMode: 'none', securityMode: 'local_http', engineProfile: 'ollama', modelID: 'qwen3:0.6b' },
    };
    const store = createAppStore();
    store.getState().addProvider(provider);
    holder.store = store;
    await redetectRelayModels(store, provider);
    expect(store.getState().providers[0].models[0].engineDeclaration).toEqual(old);
    expect(holder.sendMessageStream).not.toHaveBeenCalled();
  });

  it('RL2-ENGINE-02 re-detection refreshes declarations and does not touch overrides', async () => {
    const records = recordings.engines.ollama.records!;
    const requests: string[] = [];
    vi.spyOn(globalThis, 'fetch').mockImplementation(async (input, init) => {
      const url = new URL(String(input));
      const method = init?.method ?? 'GET';
      requests.push(`${method} ${url.pathname}`);
      const requestedModel = typeof init?.body === 'string'
        ? (JSON.parse(init.body) as { model?: string }).model
        : undefined;
      const hit = records.find((record) => record.request.method === method
        && record.request.path === url.pathname
        && (record.request.body?.model === undefined || record.request.body.model === requestedModel));
      if (!hit) return new Response('404 page not found', { status: 404, headers: { 'content-type': 'text/plain' } });
      const payload = hit.response.body !== undefined ? JSON.stringify(hit.response.body) : hit.response.text ?? '';
      return new Response(payload, { status: hit.response.status, headers: { 'content-type': hit.response.contentType } });
    });
    holder.sendMessageStream.mockReturnValue({
      abort: vi.fn(),
      stream: new ReadableStream<string>({ start(controller) { controller.enqueue('ok'); controller.close(); } }),
    });

    const overrides = { vision_input: 'unsupported' } as unknown as NonNullable<AIModel['relayCapabilityOverrides']>;
    const qwen3: AIModel = {
      ...createRelayManualModel('qwen3:0.6b', true),
      // The old declaration is the opposite of the recording: after re-detection it must be replaced by what the connector read this time.
      engineDeclaration: { image: true, toolCall: false, thinking: false },
      relayCapabilityOverrides: overrides,
    };
    const provider: Provider = {
      id: 'local-ollama',
      kind: 'relay',
      status: { kind: 'connected' },
      models: [qwen3],
      catalogModels: [qwen3],
      apiKey: '',
      apiKeyPreview: '',
      baseURLText: 'http://127.0.0.1:18080',
      relayKind: 'openai_compatible',
      relayRequested: {
        transport: 'openai_chat_completions',
        authMode: 'none',
        securityMode: 'local_http',
        engineProfile: 'ollama',
        modelID: 'qwen3:0.6b',
        resolvedAPIBaseURL: 'http://127.0.0.1:18080/v1',
      },
    };
    const store = createAppStore();
    store.getState().addProvider(provider);
    holder.store = store;

    await redetectRelayModels(store, provider);

    const refreshed = store.getState().providers[0];
    const expected = { image: false, toolCall: true, thinking: true };
    const model = refreshed.models.find((item) => item.id === 'qwen3:0.6b')!;
    expect(model.engineDeclaration).toEqual(expected);
    expect(model.relayCapabilityOverrides).toEqual(overrides);
    expect(refreshed.catalogModels.find((item) => item.id === 'qwen3:0.6b')?.engineDeclaration).toEqual(expected);
    // Local only clears and does not re-probe: the connection protocol stays put.
    expect(refreshed.relayRequested?.transport).toBe('openai_chat_completions');
    // Read-only: no generation request was made (including Ollama /api/show, which makes the engine load the model), and the connector's verification generation was not called either.
    expect(requests.every((request) => request.startsWith('GET '))).toBe(true);
    expect(requests.some((request) => /chat|completion|generate|\/api\/show/.test(request))).toBe(false);
    expect(holder.sendMessageStream).not.toHaveBeenCalled();
  });
});
