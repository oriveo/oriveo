import 'fake-indexeddb/auto';
import { existsSync, readFileSync } from 'node:fs';
import path from 'node:path';
import { afterAll, beforeAll, describe, expect, it, vi } from 'vitest';
import type { AIModel, Attachment, Provider } from '@oriveo/shared';
import { buildProviderRequest } from '@oriveo/core/providers/request-builders/dispatch';
import type { RuntimeMetadataResponse } from '@oriveo/core/providers/request-builders/runtime';
import { decideAttachmentRoute } from '../attachments/attachment-router';
import { resolveAttachmentLine } from '../attachments/attachment-transport-resolver';
import { modelCapabilityEvidenceQuery, resolveModelCapabilityEvidence } from '../chat/capability-evidence';
import {
  buildProviderStreamOptions,
  buildStreamOptionsFromIntent,
  filterRequestCapabilityIntent,
} from '../chat/stream-options';
import {
  __resetMetadataClientForTest,
  __settleMetadataBackgroundWorkForTest,
  initMetadata,
} from '../metadata/metadata-client';
import { buildCatalogModel } from '../providers/catalog-model';
import { capabilityTruthRegistry } from './truth/capability-truth-registry';
import { officialTruthAdapter } from './truth/official-truth-adapter';
import { hostedProviderFormOf, providerFormOf, type ProviderForm } from './truth/provider-form';
import { relayTruthAdapter } from './truth/relay-truth-adapter';
import { subscriptionTruthAdapter } from './truth/subscription-truth-adapter';

type Support = 'supported' | 'unsupported' | 'unknown';
type OfficialTruth = {
  vision_input: Support;
  file_input: Support;
  web_search: Support;
  tool_call: Support;
  reasoning_tiers: string[];
};
type OfficialKey = 'vision_input' | 'web_search' | 'tool_call';
type TruthContract = {
  forms: {
    order: ProviderForm[];
    cases: { kind: Provider['kind']; authMode: NonNullable<Provider['authMode']>; form: ProviderForm }[];
    adapters: Record<ProviderForm, string>;
  };
  fixtures: {
    official_metadata: {
      recorded_at: string;
      etag: string;
      selection: { providerKind: Provider['kind']; modelId: string }[];
      response: { code: number; data: RuntimeMetadataResponse; message: string };
    };
  };
  expected: {
    official: Record<string, OfficialTruth>;
    official_sources: Record<OfficialKey, { source: string; grade: string }>;
    official_wire: {
      model: string;
      web: 'automatic' | 'force';
      body_must_contain?: string[];
      body_must_not_contain?: string[];
    }[];
  };
};

// The fixture is read-only shared contract data: `response` is the recorded production metadata
// payload and `expected` holds the per-model verdicts. Providers and models are never hand-built
// here beyond the connection identity; models come from the production catalog mapping.
const contract = JSON.parse(
  readFileSync(repoFile('shared/model-contracts/capability_truth_contract.v1.json'), 'utf8'),
) as TruthContract;

// The evidence key's tier vocabulary is ReasoningMode; the catalog tiers differ only in low <-> fast.
const REASONING_MODE_TO_TIER = { fast: 'low', balanced: 'balanced', deep: 'deep', max: 'max' } as const;

function supportedReasoningTiers(target: Provider, model: AIModel): string[] {
  return (Object.keys(REASONING_MODE_TO_TIER) as (keyof typeof REASONING_MODE_TO_TIER)[])
    .filter((mode) => resolveModelCapabilityEvidence({
      key: `reasoning_level/${mode}`, provider: target, model,
    }).support === 'supported')
    .map((mode) => REASONING_MODE_TO_TIER[mode]);
}

describe('capability truth contract: provider form derivation', () => {
  it('derives the form for every contract case in the fixed order', () => {
    expect(contract.forms.cases.length).toBeGreaterThan(0);
    for (const row of contract.forms.cases) {
      expect(providerFormOf({ kind: row.kind, authMode: row.authMode }), `${row.kind}/${row.authMode}`)
        .toBe(row.form);
      // No form is served by a hosted catalog in this build.
      expect(hostedProviderFormOf(row.kind), `${row.kind} hosted form`).toBeUndefined();
    }
    // The table must cover every form, otherwise a branch can silently regress.
    expect([...new Set(contract.forms.cases.map((row) => row.form))].sort())
      .toEqual([...contract.forms.order].sort());
  });

  it('carries the raw connection authMode on the production evidence identity', () => {
    // The identity is built by the production modelCapabilityEvidenceQuery; connections follow
    // the kind x authMode table of the contract.
    expect(contract.forms.cases.length).toBeGreaterThan(0);
    for (const row of contract.forms.cases) {
      const connection = {
        id: `identity-${row.kind}-${row.authMode}`, kind: row.kind, authMode: row.authMode,
        models: [], catalogModels: [], status: { kind: 'connected' }, apiKey: '', apiKeyPreview: '',
      } as unknown as Provider;
      expect(providerFormOf(connection), `${row.kind}/${row.authMode} form`).toBe(row.form);
      const model = buildCatalogModel({
        providerKind: row.kind, runtimeModelId: 'identity-probe', fallbackName: 'identity-probe',
      });
      expect(modelCapabilityEvidenceQuery({ provider: connection, model }).authMode, `${row.kind}/${row.authMode}`)
        .toBe(row.authMode);
    }
  });

  it('gives every catalog_absent candidate the grade none on the catalog-backed subscription adapter', () => {
    // There is no recorded subscription fixture: the snapshot content is irrelevant here, only the
    // state "snapshot fetched, model not in it" matters, so the production mapping builds the
    // snapshot entry and no capability bits are invented.
    const snapshotModel = buildCatalogModel({
      providerKind: 'openAI', runtimeModelId: 'subscription-snapshot-entry', fallbackName: 'snapshot',
    });
    const subscription = {
      id: 'subscription-absent', kind: 'openAI', authMode: 'subscription',
      models: [snapshotModel], catalogModels: [snapshotModel],
      status: { kind: 'connected' }, apiKey: '', apiKeyPreview: '',
    } as unknown as Provider;
    const absentModel: AIModel = { ...snapshotModel, id: 'not-in-subscription-snapshot', canonicalModelId: undefined };
    const transport = modelCapabilityEvidenceQuery({ provider: subscription, model: absentModel })
      .effectiveTransport;
    expect(transport).not.toBe('unknown');
    const candidates = subscriptionTruthAdapter.candidates({
      provider: subscription, model: absentModel, effectiveTransport: transport,
    });
    const absent = candidates.filter((candidate) => candidate.source === 'catalog_absent');
    expect(absent.length).toBeGreaterThan(0);
    expect(absent.map((candidate) => [candidate.support, candidate.grade]))
      .toEqual(absent.map(() => ['unknown', 'none']));
  });

  it('hands every form to the adapter the contract names', () => {
    const named: Record<string, unknown> = {
      SubscriptionTruthAdapter: subscriptionTruthAdapter,
      OfficialTruthAdapter: officialTruthAdapter,
      RelayTruthAdapter: relayTruthAdapter,
    };
    for (const form of contract.forms.order) {
      const expected = named[contract.forms.adapters[form]];
      expect(expected, `${form} adapter name`).toBeDefined();
      expect(capabilityTruthRegistry.adapterFor(form), `${form} adapter`).toBe(expected);
    }
  });
});

describe('capability truth contract: official metadata through Web production paths', () => {
  const fixture = contract.fixtures.official_metadata;
  const metadata = fixture.response.data;
  const OFFICIAL_KEYS = ['vision_input', 'web_search', 'tool_call'] as const;

  // The snapshot comes in through the production metadata client: the network layer replays the
  // recorded envelope and ETag, and decoding / projection / revision all run production code.
  // The verdict clock is pinned to the recorded instant: typed candidates carry expiresAt, so with
  // the wall clock these cells would turn red a week after recording. Only Date is faked (timers
  // keep running; the metadata client and fake-indexeddb rely on them); the rest of the identity is
  // still built by the production modelCapabilityEvidenceQuery, whose `now` reads this clock.
  beforeAll(async () => {
    vi.useFakeTimers({ toFake: ['Date'] });
    vi.setSystemTime(new Date(fixture.recorded_at));
    __resetMetadataClientForTest();
    vi.spyOn(globalThis, 'fetch').mockImplementation(async (input) => {
      const url = String(input instanceof Request ? input.url : input);
      if (!/\/api\/metadata(\?|$)/.test(url)) return new Response('{}', { status: 404 });
      return new Response(JSON.stringify(fixture.response), {
        status: 200, headers: { 'Content-Type': 'application/json', ETag: fixture.etag },
      });
    });
    await initMetadata();
    await __settleMetadataBackgroundWorkForTest();
  });

  afterAll(async () => {
    await __settleMetadataBackgroundWorkForTest();
    __resetMetadataClientForTest();
    vi.restoreAllMocks();
    vi.useRealTimers();
  });

  /** The connection carries identity only; models always come from the production buildCatalogModel mapping. */
  function officialTarget(key: string): { provider: Provider; model: AIModel } {
    const selection = fixture.selection.find((item) => `${item.providerKind}/${item.modelId}` === key)!;
    const model = buildCatalogModel({
      providerKind: selection.providerKind, runtimeModelId: selection.modelId, fallbackName: selection.modelId,
    });
    return {
      model,
      provider: {
        id: `official-${selection.providerKind}`, kind: selection.providerKind, authMode: 'apiKey',
        models: [model], catalogModels: [model], status: { kind: 'connected' }, apiKey: '', apiKeyPreview: '',
      } as unknown as Provider,
    };
  }

  it('projects every recorded official model cell-by-cell from the lean metadata snapshot', () => {
    expect(fixture.selection.map((item) => `${item.providerKind}/${item.modelId}`).sort())
      .toEqual(Object.keys(contract.expected.official).sort());

    for (const [id, expected] of Object.entries(contract.expected.official)) {
      const { provider: target, model } = officialTarget(id);
      expect(providerFormOf(target), `${id} form`).toBe('official');
      // The identity's metadataRevision is the ETag of the recorded response.
      const identity = modelCapabilityEvidenceQuery({ provider: target, model });
      expect(identity.metadataRevision, `${id} revision`).toBe(fixture.etag);
      expect(identity.now, `${id} verdict clock`).toBe(Date.parse(fixture.recorded_at));

      for (const key of OFFICIAL_KEYS) {
        const resolution = resolveModelCapabilityEvidence({ key, provider: target, model });
        // Vision is judged only from capabilityControls.vision_input (a missing key resolves to
        // unknown). The snapshot was recorded before that key was delivered, so Web computes the
        // expectation from the missing key; the fixture is not re-recorded, other keys follow it.
        const visionControl = model.capabilityControls?.vision_input;
        const expectedSupport = key === 'vision_input' && !visionControl ? 'unknown' : expected[key];
        expect(resolution.support, `${id} ${key} support`).toBe(expectedSupport);
        if (resolution.support !== 'unknown') {
          expect({ source: resolution.source, grade: resolution.grade }, `${id} ${key} source`)
            .toEqual(contract.expected.official_sources[key]);
        }
      }
      expect(supportedReasoningTiers(target, model), `${id} reasoning tiers`).toEqual(expected.reasoning_tiers);
    }
  });

  it('writes the web tool into the official request body only where the recipe verdict allows it', async () => {
    expect(contract.expected.official_wire.length).toBeGreaterThan(0);
    for (const row of contract.expected.official_wire) {
      const { provider: target, model } = officialTarget(row.model);
      const preferences = { web: row.web };
      // Same chain as the send path: intent -> outbound gate (explicit web) -> final options -> production builder.
      const preliminary = buildProviderStreamOptions(
        target, buildStreamOptionsFromIntent(model, 'automatic', true, undefined, preferences), model,
      );
      const intent = filterRequestCapabilityIntent({
        provider: target, model, reasoningMode: 'automatic', webSearchEnabled: true,
        webReachesTheWire: true, streamOptions: preliminary,
      });
      expect(intent.supportsWebSearch, `${row.model} outbound gate`)
        .toBe(contract.expected.official[row.model]!.web_search === 'supported');
      const options = buildProviderStreamOptions(
        target,
        buildStreamOptionsFromIntent(
          model, intent.reasoning, intent.supportsWebSearch, undefined, intent.capabilityPreferences,
        ),
        model,
      );
      const request = await buildProviderRequest({
        providerKind: target.kind, apiKey: 'k', modelID: model.id, baseURL: 'https://contract.invalid/v1',
        messages: [{ role: 'user', content: 'hello' }],
        ...(options ? { options } : {}),
      } as Parameters<typeof buildProviderRequest>[0], async () => structuredClone(metadata));
      const body = JSON.stringify(request.body);
      for (const needle of row.body_must_contain ?? []) {
        expect(body.includes(needle), `${row.model} web=${row.web} body has ${needle}`).toBe(true);
      }
      for (const needle of row.body_must_not_contain ?? []) {
        expect(body.includes(needle), `${row.model} web=${row.web} body has ${needle}`).toBe(false);
      }
    }
  });

  it('routes a PDF to the native file line exactly where the contract says file_input is supported', async () => {
    // There is no file_input projection key; the production attachment router decides the line.
    // A scanned PDF has no injectable text, so the line depends only on "this outbound line +
    // the model's nativeFileMimes", without the pdfNativeDefault preference.
    const pdf: Attachment = {
      id: 'contract-pdf', kind: 'file', fileName: 'scan.pdf', mimeType: 'application/pdf',
      originalBase64Data: 'JVBERi0xLjQK', extractionErrorCode: 'scanned_pdf',
    };
    for (const [id, expected] of Object.entries(contract.expected.official)) {
      const { provider: target, model } = officialTarget(id);
      const line = await resolveAttachmentLine({
        provider: target, model,
        streamOptions: buildProviderStreamOptions(target, buildStreamOptionsFromIntent(model, undefined, false), model),
      });
      expect(line.exact, `${id} attachment line resolved`).toBe(true);
      expect(decideAttachmentRoute(pdf, line, model) === 'native', `${id} native file line`)
        .toBe(expected.file_input === 'supported');
    }
  });
});

function repoFile(relative: string): string {
  let current = process.cwd();
  for (;;) {
    const candidate = path.join(current, relative);
    if (existsSync(candidate)) return candidate;
    const parent = path.dirname(current);
    if (parent === current) throw new Error(`missing fixture: ${relative}`);
    current = parent;
  }
}
