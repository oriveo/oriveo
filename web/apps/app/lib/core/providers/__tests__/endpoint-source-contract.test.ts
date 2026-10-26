import 'fake-indexeddb/auto';
/**
 * @vitest-environment jsdom
 */
// Official provider endpointSource fixture replayed case by case.
// Config goes through production metadata decoding (seed -> initMetadata -> getPublicProviderConfig / getProviderTransport),
// and the request-time address goes through production resolveBaseURL.
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { Provider } from '@oriveo/shared';
import { normalizeEndpointSourceURL } from '@oriveo/core/providers/transport/endpoint-resolver';
import { pruneBlobs } from '../../../infra/storage/blob-cache';
import { __seedMetadataCacheForTest as seedMetadataCache } from '../../metadata/metadata-client';

type RawConfig = Record<string, unknown> & { kind: string; defaultBaseURL: string };
type Fixture = {
  configs: Record<string, RawConfig>;
  classifyCases: Array<{ caseId: string; config: string; baseURLText: string | null; expect: string }>;
  resolveCases: Array<{
    caseId: string;
    config: string;
    stored: { baseURLText: string; endpointSource: string | null };
    metadataPatch: Record<string, unknown> | 'absent';
    classifyWithBaseMetadataFirst?: boolean;
    expectEndpointSource?: string;
    expectBaseURL: string;
  }>;
  writeCases: Array<{
    caseId: string;
    config: string;
    action: 'setup' | 'editBaseURL' | 'syncApply' | 'syncUpload';
    regionId?: string | null;
    before?: { baseURLText: string; endpointSource: string };
    baseURLText?: string;
    expect: Record<string, string>;
  }>;
  metadataPresets: Record<string, Record<string, unknown>>;
  builtInDefaults: Record<string, string>;
  identityRegions: Record<string, Array<{ id: string; baseURL: string }>>;
  reconcileCases: Array<StoredCase & {
    expect: { endpointSource: string | null; baseURLText: string | null };
    expectRequestBaseURL: string;
  }>;
  identityCases: Array<StoredCase & { expectRegionId: string }>;
  echoCases: Array<StoredCase & { expectRegionId: string }>;
  regionPickerCases: Array<{ caseId: string; config: string; metadataPatch: MetadataPatch; expectShown: boolean }>;
  builtInCases: Array<{
    caseId: string;
    kind?: string;
    kinds?: string[];
    expectRegionIds?: string[];
    expectDefaultMatchKey?: string;
    expectEqualsBuiltInDefaults?: boolean;
  }>;
};
type MetadataPatch = Record<string, unknown> | 'absent' | string;
type StoredCase = {
  caseId: string;
  config: string;
  metadataPatch: MetadataPatch;
  stored: { baseURLText: string | null; endpointSource: string | null };
};

const repositoryRoot = resolve(process.cwd(), '../../..');
const fixture = JSON.parse(readFileSync(
  resolve(repositoryRoot, 'shared/test-fixtures/provider-catalog/endpoint-source.v1.json'),
  'utf8',
)) as Fixture;

/** Fixture metadataPatch: `regionOptions.<id>.baseURL` / `regionOptions.<id>` (null = delete) / `defaultBaseURL`. */
function applyMetadataPatch(config: RawConfig, patch: Record<string, unknown>): RawConfig {
  const next: RawConfig = JSON.parse(JSON.stringify(config));
  for (const [path, value] of Object.entries(patch)) {
    const parts = path.split('.');
    if (parts[0] === 'regionOptions' && parts[1]) {
      const regions = (next.regionOptions as Array<Record<string, unknown>>) ?? [];
      if (parts.length === 2) {
        next.regionOptions = value === null ? regions.filter((option) => option.id !== parts[1]) : regions;
      } else {
        next.regionOptions = regions.map((option) => option.id === parts[1]
          ? { ...option, [parts[2]!]: value }
          : option);
      }
    } else {
      next[path] = value;
    }
  }
  return next;
}

/** Endpoint source section: a string = metadataPresets name (a key without a dot is replaced wholesale); "absent" = no metadata. */
function caseMetadata(configName: string, patch: MetadataPatch): RawConfig | null {
  const base = fixture.configs[configName]!;
  if (patch === 'absent') return null;
  if (typeof patch === 'string') return { ...base, ...fixture.metadataPresets[patch]! } as RawConfig;
  return applyMetadataPatch(base, patch);
}

type MetadataClientModule = typeof import('../../metadata/metadata-client');

// The latest instance dynamically imported after a case's vi.resetModules; afterEach waits for its
// background refresh / persistence to settle and then restores it, so nothing leaks into the next case.
let metadataInstance: MetadataClientModule | null = null;

async function importMetadataClient(): Promise<MetadataClientModule> {
  metadataInstance = await import('../../metadata/metadata-client');
  return metadataInstance;
}

async function restoreMetadataInstance(): Promise<void> {
  if (!metadataInstance) return;
  await metadataInstance.__settleMetadataBackgroundWorkForTest();
  metadataInstance.__resetMetadataClientForTest();
  metadataInstance = null;
}

async function loadMetadata(config: RawConfig | null) {
  vi.resetModules();
  await pruneBlobs(() => true);
  if (config) {
    await seedMetadataCache({
      timestamp: Date.now(),
      data: {
        version: 1,
        contractVersion: 1,
        updatedAt: '2026-10-11T00:00:00Z',
        profiles: {},
        providers: {
          [config.kind]: { transport: { baseUrl: config.defaultBaseURL, endpoints: {} }, models: {} },
        },
        providerConfigs: [{ displayName: config.kind, ...config }],
      } as never,
    });
  }
  vi.spyOn(globalThis, 'fetch').mockResolvedValue({ status: 304, ok: false, json: vi.fn() } as unknown as Response);
  const metadata = await importMetadataClient();
  await metadata.initMetadata();
  // Assert after the background refresh settles: otherwise the resolver may read the pre-refresh address (the missing_source case flakes)
  await metadata.__settleMetadataBackgroundWorkForTest();
  const endpointSource = await import('../endpoint-source');
  const resolver = await import('../transport/endpoint-resolver');
  return { metadata, endpointSource, resolver };
}

/** Production modules used by the endpoint source section; loaded only in the new cases, leaving the module graph of old cases unchanged. */
async function loadE3(config: RawConfig | null) {
  const loaded = await loadMetadata(config);
  const catalog = await import('../../../../app/providers/new/provider-config-catalog');
  const migration = await import('../../provider-id-migration');
  const endpointUtils = await import('../../../../components/providers/official-endpoint-utils');
  const configPackage = await import('@oriveo/config');
  return { ...loaded, catalog, migration, endpointUtils, configPackage };
}

function officialProvider(kind: string, stored: { baseURLText?: string | null; endpointSource?: string | null }): Provider {
  return {
    id: `${kind}-1`,
    kind: kind as Provider['kind'],
    status: { kind: 'connected' },
    models: [],
    catalogModels: [],
    apiKey: 'sk-test',
    apiKeyPreview: 'sk-…',
    ...(stored.baseURLText != null ? { baseURLText: stored.baseURLText } : {}),
    ...(stored.endpointSource != null ? { endpointSource: stored.endpointSource as Provider['endpointSource'] } : {}),
  };
}

describe('endpoint-source.v1 fixture', () => {
  beforeEach(async () => {
    await pruneBlobs(() => true);
  });
  afterEach(async () => {
    // Settle the background refresh and restore, so it does not write back to the cache only after the next case seeds (cross-case data leakage)
    await restoreMetadataInstance();
    vi.restoreAllMocks();
  });

  for (const testCase of fixture.classifyCases) {
    it(`ENDPOINT-SOURCE-${testCase.caseId}`, async () => {
      const { endpointSource } = await loadMetadata(fixture.configs[testCase.config]!);
      expect(endpointSource.classifyProviderEndpointSource(
        testCase.config,
        testCase.baseURLText ?? undefined,
      )).toBe(testCase.expect);
    });
  }

  for (const testCase of fixture.resolveCases) {
    it(`ENDPOINT-SOURCE-${testCase.caseId}`, async () => {
      const base = fixture.configs[testCase.config]!;
      let stored = { ...testCase.stored };
      if (testCase.classifyWithBaseMetadataFirst) {
        const { endpointSource } = await loadMetadata(base);
        const patch = endpointSource.endpointSourcePatchForBaseURL(
          testCase.config,
          stored.baseURLText,
        );
        expect(patch.endpointSource).toBe(testCase.expectEndpointSource);
        stored = { ...stored, endpointSource: patch.endpointSource ?? null };
      }
      const { resolver } = await loadMetadata(testCase.metadataPatch === 'absent'
        ? null
        : applyMetadataPatch(base, testCase.metadataPatch));
      // The address actually produced by the production resolver (computed at request time)
      expect(resolver.resolveBaseURL(officialProvider(testCase.config, stored), testCase.config))
        .toBe(testCase.expectBaseURL);
    });
  }

  // The community edition has no cloud sync: the sync landing / upload cases of the shared fixture do not apply.
  for (const testCase of fixture.writeCases.filter((item) => item.action === 'setup' || item.action === 'editBaseURL')) {
    it(`ENDPOINT-SOURCE-${testCase.caseId}`, async () => {
      const config = fixture.configs[testCase.config]!;
      const { endpointSource, metadata } = await loadMetadata(config);
      const decoded = endpointSource.endpointConfigFromPublic(metadata.getPublicProviderConfig(testCase.config));
      switch (testCase.action) {
        case 'setup': {
          const form = endpointSource.buildOfficialSetupEndpoint({
            kind: testCase.config,
            config: decoded!,
            regionId: testCase.regionId ?? null,
          });
          expect(form.fields).toEqual([]);
          expect(form.result).toMatchObject(testCase.expect);
          break;
        }
        case 'editBaseURL': {
          // Production address-change entry: the result updateProviderBaseURL writes into the store
          const { createAppStore } = await import('../../store/app-store');
          const providerOps = await import('../../provider-ops');
          const store = createAppStore();
          const provider = officialProvider(testCase.config, testCase.before!);
          store.setState({ providers: [provider] });
          providerOps.updateProviderBaseURL(store, provider, testCase.baseURLText!);
          expect(store.getState().providers.find((item) => item.id === provider.id))
            .toMatchObject(testCase.expect);
          break;
        }
      }
    });
  }
  // -- Endpoint source section --------------------

  for (const testCase of fixture.reconcileCases) {
    it(`ENDPOINT-SOURCE-${testCase.caseId}`, async () => {
      const kind = fixture.configs[testCase.config]!.kind;
      const { endpointSource, resolver } = await loadE3(caseMetadata(testCase.config, testCase.metadataPatch));
      const stored = { ...officialProvider(kind, testCase.stored), updatedAt: '2026-10-01T00:00:00.000Z' };
      // Request time: the production address-fetching entry first runs the same rules in memory on an existing record
      expect(endpointSource.requestBaseURLText(stored) ?? resolver.resolveBaseURL(stored, kind))
        .toBe(testCase.expectRequestBaseURL);
      // Startup backfill: the record production backfillOfficialEndpointSources writes into the store
      const { createAppStore } = await import('../../store/app-store');
      const store = createAppStore();
      store.setState({ providers: [stored] });
      await endpointSource.backfillOfficialEndpointSources(store);
      const after = store.getState().providers[0]!;
      expect(after.endpointSource ?? null).toBe(testCase.expect.endpointSource);
      expect(after.baseURLText ?? null).toBe(testCase.expect.baseURLText);
      expect(after.updatedAt).toBe(stored.updatedAt);
    });
  }

  it('ENDPOINT-SOURCE-identity_regions_frozen_table_matches_fixture', async () => {
    const { catalog } = await loadE3(null);
    expect(catalog.IDENTITY_REGIONS).toEqual(fixture.identityRegions);
  });

  for (const testCase of fixture.identityCases) {
    it(`ENDPOINT-SOURCE-${testCase.caseId}`, async () => {
      const kind = fixture.configs[testCase.config]!.kind;
      const { catalog, migration, metadata } = await loadE3(caseMetadata(testCase.config, testCase.metadataPatch));
      // Production function shared by migration grouping and registration
      expect(migration.resolveRegionId(
        officialProvider(kind, testCase.stored),
        catalog.resolveRegionLookupCatalog(metadata.listPublicProviderConfigs()),
      )).toBe(testCase.expectRegionId);
    });
  }

  for (const testCase of fixture.echoCases) {
    it(`ENDPOINT-SOURCE-${testCase.caseId}`, async () => {
      const kind = fixture.configs[testCase.config]!.kind;
      const { endpointUtils, metadata } = await loadE3(caseMetadata(testCase.config, testCase.metadataPatch));
      const config = metadata.getPublicProviderConfig(kind);
      // Same combination as the detail page: options (through the trusted table) + the saved region as filler, then echoed by source / literal
      const options = endpointUtils.withStoredOfficialEndpointOption(
        endpointUtils.resolveOfficialEndpointOptions(kind, config),
        endpointUtils.resolveOfficialEndpointLookupOptions(kind, config),
        testCase.stored.baseURLText ?? undefined,
      );
      expect(endpointUtils.resolveSelectedOfficialEndpointId(
        options,
        testCase.stored.baseURLText ?? undefined,
        undefined,
        testCase.stored.endpointSource ?? undefined,
      )).toBe(testCase.expectRegionId);
    });
  }

  for (const testCase of fixture.regionPickerCases) {
    it(`ENDPOINT-SOURCE-${testCase.caseId}`, async () => {
      const kind = fixture.configs[testCase.config]!.kind;
      const { catalog, endpointUtils, metadata } = await loadE3(caseMetadata(testCase.config, testCase.metadataPatch));
      // Both the detail page (BaseURLEditor renders a selector when endpointOptions is non-empty and saves by region) and the add-site page show the catalog
      const detailOptions = endpointUtils.resolveOfficialEndpointOptions(kind, metadata.getPublicProviderConfig(kind));
      const setupOptions = catalog.resolveProviderSetupCatalog(metadata.listPublicProviderConfigs())
        .configsByKind[kind as 'qwen'].regionOptions;
      expect(detailOptions.length > 0).toBe(testCase.expectShown);
      expect(setupOptions.length > 0).toBe(testCase.expectShown);
    });
  }

  for (const testCase of fixture.builtInCases) {
    it(`ENDPOINT-SOURCE-${testCase.caseId}`, async () => {
      const { catalog, endpointUtils, resolver, configPackage } = await loadE3(null);
      if (testCase.expectRegionIds) {
        const kind = fixture.configs[testCase.kind!]!.kind;
        const setupIds = catalog.resolveProviderSetupCatalog(null)
          .configsByKind[kind as 'qwen'].regionOptions.map((option) => option.id);
        const detailIds = endpointUtils.resolveOfficialEndpointOptions(kind, null).map((option) => option.id);
        expect(setupIds).toEqual(testCase.expectRegionIds);
        expect(detailIds).toEqual(testCase.expectRegionIds);
      }
      if (testCase.expectDefaultMatchKey) {
        const kind = fixture.configs[testCase.kind!]!.kind;
        // The address written by the add-site page when there is no metadata, and the final built-in fallback of the request chain
        expect(normalizeEndpointSourceURL(
          configPackage.providerDefaults[kind as 'qwen'].defaultBaseURL,
        )).toBe(testCase.expectDefaultMatchKey);
        expect(normalizeEndpointSourceURL(
          resolver.resolveBaseURL(officialProvider(kind, {}), kind),
        )).toBe(testCase.expectDefaultMatchKey);
      }
      if (testCase.expectEqualsBuiltInDefaults) {
        for (const name of testCase.kinds!) {
          const kind = fixture.configs[name]!.kind;
          expect(normalizeEndpointSourceURL(configPackage.providerDefaults[kind as 'qwen'].defaultBaseURL))
            .toBe(normalizeEndpointSourceURL(fixture.builtInDefaults[name]));
        }
      }
    });
  }
});
