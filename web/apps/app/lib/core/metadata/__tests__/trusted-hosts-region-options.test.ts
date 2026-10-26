import 'fake-indexeddb/auto';
/**
 * @vitest-environment jsdom
 */
// E2-TRUST-02: the delivered regionOptions pass trustedHosts at the metadata decoding layer.
// Goes through production initMetadata decoding -> getPublicProviderConfig / getProviderTransport -> the region selector's consumer functions.
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { pruneBlobs } from '../../../infra/storage/blob-cache';
import { __seedMetadataCacheForTest as seedMetadataCache } from '../metadata-client';

const MINIMAX_REGIONS = [
  { id: 'global', label: 'Global', baseURL: 'https://api.minimax.io/v1' },
  { id: 'cn', label: 'China Mainland', baseURL: 'https://api.minimaxi.com/v1' },
];

async function loadWith(trustedHosts: unknown) {
  await seedMetadataCache({
    timestamp: Date.now(),
    data: {
      version: 1,
      contractVersion: 1,
      updatedAt: '2026-10-10T00:00:00Z',
      profiles: {},
      providers: {
        miniMax: {
          transport: { baseUrl: 'https://api.minimaxi.com', endpoints: {} },
          models: {},
        },
      },
      providerConfigs: [{
        kind: 'miniMax',
        displayName: 'MiniMax',
        defaultBaseURL: 'https://api.minimax.io/v1',
        regionOptions: MINIMAX_REGIONS,
        ...(trustedHosts !== undefined ? { trustedHosts } : {}),
      }],
    } as never,
  });
  vi.spyOn(globalThis, 'fetch').mockResolvedValue({ status: 304, ok: false, json: vi.fn() } as unknown as Response);
  const metadata = await importMetadataClient();
  await metadata.initMetadata();
  const { resolveOfficialEndpointOptions } = await import('../../../../components/providers/official-endpoint-utils');
  return { metadata, resolveOfficialEndpointOptions };
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

describe('E2-TRUST-02 regionOptions pass trustedHosts', () => {
  beforeEach(async () => {
    vi.resetModules();
    await pruneBlobs(() => true);
  });
  afterEach(async () => {
    await restoreMetadataInstance();
    vi.restoreAllMocks();
  });

  it('delivered minimaxi.com: the China-site region is kept and its base URL is allowed too', async () => {
    const { metadata, resolveOfficialEndpointOptions } = await loadWith(['minimax.io', 'minimaxi.com']);
    const config = metadata.getPublicProviderConfig('miniMax');
    expect(config?.trustedHosts).toEqual(['minimax.io', 'minimaxi.com']);
    expect(config?.regionOptions?.map((option) => option.id)).toEqual(['global', 'cn']);
    expect(resolveOfficialEndpointOptions('miniMax', config).map((option) => option.id)).toEqual(['global', 'cn']);
    expect(metadata.getProviderTransport('miniMax')?.trustedHosts).toEqual(['minimax.io', 'minimaxi.com']);
  });

  it('missing field: only the fallback registered domain minimax.io is trusted, and the China-site option is filtered out', async () => {
    const { metadata, resolveOfficialEndpointOptions } = await loadWith(undefined);
    const config = metadata.getPublicProviderConfig('miniMax');
    expect(config).not.toHaveProperty('trustedHosts');
    expect(config?.regionOptions?.map((option) => option.id)).toEqual(['global']);
    expect(resolveOfficialEndpointOptions('miniMax', config).map((option) => option.id)).toEqual(['global']);
    expect(metadata.getProviderTransport('miniMax')).not.toHaveProperty('trustedHosts');
  });

  it('a delivered value with the wrong shape is treated as a missing field (uppercase / wildcard entries are dropped one by one)', async () => {
    const { metadata } = await loadWith(['MINIMAXI.COM', '*.minimaxi.com']);
    const config = metadata.getPublicProviderConfig('miniMax');
    expect(config).not.toHaveProperty('trustedHosts');
    expect(config?.regionOptions?.map((option) => option.id)).toEqual(['global']);
  });
});
