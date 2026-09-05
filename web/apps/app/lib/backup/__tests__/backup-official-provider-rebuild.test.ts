/**
 * Hard constraints for backup import:
 *
 *   - an official provider (anything other than Relay) must never have
 *     `catalogModels` restored, in any of the three import modes
 *   - the `models` of an official provider must be rebuilt through the metadata resolver
 *   - focuses on the new-provider branch of `applyRestoredKeys` (merge mode with nothing local,
 *     plus importNew and replaceAll)
 *   - Relay is allowed to keep its `catalogModels`
 */

import 'fake-indexeddb/auto';
import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import type { Provider } from '@oriveo/shared';
import {
  resetDBConnection,
  getAllProviders,
  clearAllProviders,
} from '../../infra/storage/idb';
import { setActiveUID } from '../../infra/storage/partition';
import { resetImageDBConnection } from '../../infra/storage/image-store';
import { pruneBlobs } from '../../infra/storage/blob-cache';
import {
  __seedMetadataCacheForTest,
  __resetMetadataClientForTest,
} from '../../core/metadata/metadata-client';

/* ── crypto polyfill ─────────────────────────────────── */
const { subtle } = globalThis.crypto ?? {};
if (!subtle || !subtle.digest) {
  const nodeCrypto = await import('node:crypto');
  Object.defineProperty(globalThis, 'crypto', {
    value: nodeCrypto.webcrypto,
    writable: true,
    configurable: true,
  });
}

const { executeImport, generateImportPreview } = await import('..');

/* -- metadata mock: inject the catalog of an official qwen provider -- */
// Metadata is injected through the real metadata-client cache path, whose medium is IndexedDB (see
// blob-cache), so the existing singleton's exported interface does not have to change.
beforeEach(async () => {
  const fakeMetadata = {
    version: 1,
    contractVersion: 1,
    updatedAt: '2026-04-18T00:00:00Z',
    profiles: { reasoning: {}, webSearch: {}, imageGen: {} },
    providers: {
      qwen: {
        displayName: 'Qwen',
        defaultModelId: 'qwen3.6-plus',
        validationModelId: 'qwen3.6-plus',
        attachmentSupport: { image: true, nativeFile: false, textFileInline: true },
        resolveMap: {
          'qwen3.6-plus': 'qwen3.6-plus',
          'qwen3.6-plus-2026-04-02': 'qwen3.6-plus',
        },
        models: {
          'qwen3.6-plus': {
            canonicalModelId: 'qwen3.6-plus',
            aliases: ['qwen3.6-plus-2026-04-02'],
            displayName: 'Qwen 3.6 Plus',
            capabilities: ['text'],
            pricingStatus: 'priced',
            pricing: { promptPerMToken: 1, completionPerMToken: 3 },
          },
          'qwen-turbo': {
            canonicalModelId: 'qwen-turbo',
            displayName: 'Qwen Turbo',
            capabilities: ['text'],
            pricingStatus: 'free',
          },
        },
      },
    },
    providerConfigs: [],
  };

  // Seeding goes through the exported test API rather than a hand-written storage key, so the test
  // follows a change of cache medium instead of silently landing on the "metadata unavailable" branch.
  await __seedMetadataCacheForTest({ data: fakeMetadata, timestamp: Date.now() });
});

beforeEach(async () => {
  __resetMetadataClientForTest();
  await setActiveUID('guest');
  resetDBConnection();
  resetImageDBConnection();
  await clearAllProviders();
});

afterEach(async () => {
  __resetMetadataClientForTest();
  await pruneBlobs('oriveo:metadata:c', []);
});

function makeBackupFile(providers: Provider[]) {
  return {
    version: 1,
    exportedAt: new Date().toISOString(),
    containsKeys: false,
    data: {
      conversations: [],
      providers,
      folders: [],
      skills: [],
    },
  };
}

describe('backup import: official provider catalogModels hard constraint', () => {
  it('importNew mode: strips catalogModels for official provider and rebuilds via metadata', async () => {
    // Make sure metadata-client has a snapshot to read
    const { initMetadata } = await import('../../core/metadata/metadata-client');
    await initMetadata().catch(() => {});

    const backupProvider: Provider = {
      id: 'qwen-prov',
      kind: 'qwen',
      status: { kind: 'connected' },
      models: [
        {
          id: 'qwen3.6-plus-2026-04-02',
          name: 'Dated',
          capabilities: ['text'],
          reasoningModeAvailable: false,
          isAvailable: true,
          isDefault: true,
          priceTier: '',
        },
        {
          id: 'deprecated-xyz',
          name: 'Gone',
          capabilities: ['text'],
          reasoningModeAvailable: false,
          isAvailable: true,
          isDefault: false,
          priceTier: '',
        },
      ],
      catalogModels: [
        {
          id: 'qwen-stale-catalog',
          name: 'Stale',
          capabilities: ['text'],
          reasoningModeAvailable: false,
          isAvailable: true,
          isDefault: false,
          priceTier: '',
        },
      ],
      apiKey: 'sk-xxx',
      apiKeyPreview: 'sk-x',
    };

    const backup = makeBackupFile([backupProvider]);
    const preview = await generateImportPreview(backup as never, new Map());
    await executeImport(preview, 'importNew');

    const stored = (await getAllProviders()).find((p) => p.id === 'qwen-prov');
    expect(stored).toBeTruthy();
    expect(stored!.catalogModels).toEqual([]);
    // deprecated-xyz is pruned
    expect(stored!.models.some((m) => m.id === 'deprecated-xyz')).toBe(false);
    // qwen3.6-plus, the canonical id, is in the catalog
    expect(stored!.models.some((m) => m.id === 'qwen3.6-plus')).toBe(true);
  });

  it('merge mode new-provider branch (local absent): strips catalogModels', async () => {
    const { initMetadata } = await import('../../core/metadata/metadata-client');
    await initMetadata().catch(() => {});

    const backupProvider: Provider = {
      id: 'qwen-new',
      kind: 'qwen',
      status: { kind: 'connected' },
      models: [],
      catalogModels: [
        {
          id: 'qwen-legacy',
          name: 'Legacy',
          capabilities: ['text'],
          reasoningModeAvailable: false,
          isAvailable: true,
          isDefault: false,
          priceTier: '',
        },
      ],
      apiKey: 'sk',
      apiKeyPreview: 'sk',
    };

    const backup = makeBackupFile([backupProvider]);
    const preview = await generateImportPreview(backup as never, new Map());
    await executeImport(preview, 'merge');

    const stored = (await getAllProviders()).find((p) => p.id === 'qwen-new');
    expect(stored).toBeTruthy();
    expect(stored!.catalogModels).toEqual([]);
  });

  it('replaceAll mode: strips catalogModels for official provider', async () => {
    const { initMetadata } = await import('../../core/metadata/metadata-client');
    await initMetadata().catch(() => {});

    const backupProvider: Provider = {
      id: 'qwen-replace',
      kind: 'qwen',
      status: { kind: 'connected' },
      models: [],
      catalogModels: [
        {
          id: 'old-model',
          name: 'Old',
          capabilities: ['text'],
          reasoningModeAvailable: false,
          isAvailable: true,
          isDefault: false,
          priceTier: '',
        },
      ],
      apiKey: 'sk',
      apiKeyPreview: 'sk',
    };

    const backup = makeBackupFile([backupProvider]);
    const preview = await generateImportPreview(backup as never, new Map());
    await executeImport(preview, 'replaceAll');

    const stored = (await getAllProviders()).find((p) => p.id === 'qwen-replace');
    expect(stored).toBeTruthy();
    expect(stored!.catalogModels).toEqual([]);
  });

  it('preserves relay catalogModels on import', async () => {
    const relayProvider: Provider = {
      id: 'relay-1',
      kind: 'relay',
      status: { kind: 'connected' },
      customName: 'My Relay',
      models: [],
      catalogModels: [
        {
          id: 'custom-model-1',
          name: 'Custom',
          capabilities: ['text'],
          reasoningModeAvailable: false,
          isAvailable: true,
          isDefault: false,
          priceTier: '',
        },
      ],
      apiKey: 'sk',
      apiKeyPreview: 'sk',
      baseURLText: 'https://example.com',
    };

    const backup = makeBackupFile([relayProvider]);
    const preview = await generateImportPreview(backup as never, new Map());
    await executeImport(preview, 'importNew');

    const stored = (await getAllProviders()).find((p) => p.id === 'relay-1');
    expect(stored).toBeTruthy();
    // Relay must keep its catalogModels
    expect(stored!.catalogModels.length).toBeGreaterThan(0);
    expect(stored!.catalogModels[0].id).toBe('custom-model-1');
    // The object executeImport really restores must return to the unverified issue state even when
    // the backup says connected; a hand-made resetProviderStatus return value would prove nothing.
    expect(stored).toMatchObject({
      status: { kind: 'issue', message: 'Restored from backup' },
      lastCheckedAt: undefined,
      lastError: undefined,
    });
  });
});
