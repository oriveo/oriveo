import 'fake-indexeddb/auto';
/**
 * @vitest-environment jsdom
 *
 * Tool-call evidence derived from models.dev arrives as source=server_typed, grade=declared.
 * The decoding allowlist used to accept only machine_verified, so candidates were dropped at decoding:
 * supported models showed as unknown while unsupported ones still got tools sent.
 *
 * The corpus is the shared metadata_catalog_contract.v1.json as is, and model ids are read from it; every assertion reads
 * what the production decoding (index + catalog assembly / lean fallback) and resolveModelCapabilityEvidence actually produce.
 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { readFileSync } from 'node:fs';
import type { AIModel, Provider } from '@oriveo/shared';
import { pruneBlobs } from '../../../infra/storage/blob-cache';

interface Candidate { key: string; source: string; grade: string; support: string; observedAt?: number }
interface CatalogModel { transport?: string; capabilityEvidenceRef?: string }
interface Catalog {
  data: {
    models: Record<string, CatalogModel>;
    tables: { capabilityEvidence: Record<string, { candidates?: Candidate[] }> };
  };
}
interface Fixture {
  indexResponse: unknown;
  catalogResponses: Record<string, Catalog>;
  leanEquivalent: { data: { providers: Record<string, { models: Record<string, Record<string, unknown>> }> } };
}

const fixture = JSON.parse(readFileSync(
  '../../../shared/model-contracts/metadata_catalog_contract.v1.json',
  'utf8',
)) as Fixture;

/** The tool_call candidate in the corpus with server_typed + declared (found by support, no hardcoded id). */
function declaredToolCall(support: 'supported' | 'unsupported') {
  for (const [kind, catalog] of Object.entries(fixture.catalogResponses)) {
    for (const [modelId, model] of Object.entries(catalog.data.models)) {
      const view = model.capabilityEvidenceRef
        ? catalog.data.tables.capabilityEvidence[model.capabilityEvidenceRef]
        : undefined;
      const candidate = view?.candidates?.find((entry) => (
        entry.key === 'tool_call'
        && entry.source === 'server_typed'
        && entry.grade === 'declared'
        && entry.support === support
      ));
      if (candidate) return { kind, modelId, transport: model.transport, candidate };
    }
  }
  throw new Error(`corpus has no server_typed/declared tool_call ${support} candidate`);
}

const SUPPORTED = declaredToolCall('supported');
const UNSUPPORTED = declaredToolCall('unsupported');

function json(body: unknown, etag: string): Response {
  return new Response(JSON.stringify(body), {
    status: 200,
    headers: { 'Content-Type': 'application/json', ETag: etag },
  });
}

function splitServer(url: string): Response {
  if (url.endsWith('view=index&schema=3')) return json(fixture.indexResponse, '"index-1"');
  const kind = /provider=([^&]+)/.exec(url)?.[1];
  const catalog = kind ? fixture.catalogResponses[decodeURIComponent(kind)] : undefined;
  return catalog ? json(catalog, `"catalog-${kind}"`) : new Response(null, { status: 404 });
}

function leanServer(body: unknown) {
  return (url: string): Response => (
    url.includes('view=index') ? new Response(null, { status: 400 }) : json(body, '"lean-1"')
  );
}

async function load(route: (url: string) => Response) {
  vi.resetModules();
  vi.spyOn(globalThis, 'fetch').mockImplementation(async (input) => route(String(input)));
  const metadata = await importMetadataClient();
  metadata.__resetMetadataClientForTest();
  metadata.setMetadataCatalogDemandSource(() => ({
    providerKinds: Object.keys(fixture.catalogResponses),
    hasRelay: false,
  }));
  await metadata.refreshMetadata();
  const evidence = await import('../../chat/capability-evidence');
  return { metadata, evidence };
}

function toolCall(
  evidence: Awaited<ReturnType<typeof load>>['evidence'],
  target: { kind: string; modelId: string; transport?: string },
) {
  const provider = { id: `p-${target.kind}`, kind: target.kind, apiKey: 'k', models: [] } as unknown as Provider;
  const model = {
    id: target.modelId,
    name: target.modelId,
    capabilities: ['text'],
    transport: target.transport,
  } as unknown as AIModel;
  return evidence.resolveModelCapabilityEvidence({ key: 'tool_call', provider, model });
}

type MetadataClientModule = typeof import('../metadata-client');

// The latest instance dynamically imported after vi.resetModules in a case; afterEach waits for its background refresh / persistence to settle before restoring,
// so nothing leaks into the next case.
let metadataInstance: MetadataClientModule | null = null;

async function importMetadataClient(): Promise<MetadataClientModule> {
  metadataInstance = await import('../metadata-client');
  return metadataInstance;
}

async function restoreMetadataInstance(): Promise<void> {
  if (!metadataInstance) return;
  await metadataInstance.__settleMetadataBackgroundWorkForTest();
  metadataInstance.__resetMetadataClientForTest();
  metadataInstance = null;
}

describe('server_typed + declared tool_call evidence (models.dev source)', () => {
  beforeEach(async () => {
    vi.restoreAllMocks();
    // The candidate carries observedAt/expiresAt; pin the clock so freshness does not drift with the real date
    vi.useFakeTimers({ toFake: ['Date'] });
    vi.setSystemTime(Math.max(
      SUPPORTED.candidate.observedAt ?? 0,
      UNSUPPORTED.candidate.observedAt ?? 0,
    ) + 1000);
    await pruneBlobs('oriveo:metadata:', []);
  });

  afterEach(async () => {

    await restoreMetadataInstance();
    vi.useRealTimers();
    await new Promise((resolve) => setTimeout(resolve, 20));
    await pruneBlobs('oriveo:metadata:', []);
  });

  it.each([
    ['index + catalog', () => splitServer],
    ['lean fallback', () => leanServer(fixture.leanEquivalent)],
  ])('%s: declared candidates enter the central ruling and supported / unsupported each take effect', async (_label, server) => {
    const { metadata, evidence } = await load(server());

    const supported = metadata.resolveCatalogModel(SUPPORTED.modelId, SUPPORTED.kind);
    expect(supported?.capabilityEvidenceCandidates).toEqual([expect.objectContaining({
      key: 'tool_call',
      source: 'server_typed',
      grade: 'declared',
      support: 'supported',
    })]);
    expect(toolCall(evidence, SUPPORTED)).toMatchObject({
      support: 'supported',
      source: 'server_typed',
      grade: 'declared',
      requestPolicy: 'allow',
    });
    expect(toolCall(evidence, UNSUPPORTED)).toMatchObject({
      support: 'unsupported',
      source: 'server_typed',
      grade: 'declared',
      requestPolicy: 'omit_unsupported',
    });
  });

  it('server_typed with a grade outside the allowlist (observed) is still dropped at decoding', async () => {
    const lean = structuredClone(fixture.leanEquivalent);
    const model = lean.data.providers[SUPPORTED.kind].models[SUPPORTED.modelId];
    model.capabilityEvidenceView = {
      candidates: [{ ...SUPPORTED.candidate, grade: 'observed' }],
    };
    const { metadata, evidence } = await load(leanServer(lean));

    expect(metadata.resolveCatalogModel(SUPPORTED.modelId, SUPPORTED.kind)?.capabilityEvidenceCandidates)
      .toEqual([]);
    expect(toolCall(evidence, SUPPORTED)).toMatchObject({ support: 'unknown', grade: 'none' });
  });
});
