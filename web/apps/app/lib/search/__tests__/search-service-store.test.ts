import 'fake-indexeddb/auto';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import JSZip from 'jszip';
import { openDB } from 'idb';
import { resolveDefaultSearchService, searchResultCount, RESULT_COUNT_DEFAULT } from '@oriveo/core/search/search-settings';
import { resetDBConnection } from '../../infra/storage/idb';
import { resetImageDBConnection } from '../../infra/storage/image-store';
import { deletePartitionData, setActiveUID } from '../../infra/storage/partition';
import {
  closeSearchDB,
  getDefaultSearchServiceId,
  getSearchDBName,
  hasGuestSearchServices,
  listSearchServices,
  migrateGuestSearchData,
  readSearchServiceKey,
  removeSearchService,
  saveCustomSearchService,
  savePresetSearchService,
  setDefaultSearchServiceId,
  SEARCH_DB_VERSION,
  type StoredCustomSearchService,
  type StoredPresetSearchService,
} from '../search-service-store';

// Local storage of external search services: partition store, presets bind a host / reuse stores only a connection reference, custom keys bind an origin, nothing in backups.

vi.mock('../../core/sync', async () => {
  const actual = await vi.importActual<typeof import('../../core/sync')>('../../core/sync');
  return { ...actual, getSyncAdapter: () => ({ didUpdatePreferences: vi.fn() }) };
});

if (typeof Blob.prototype.arrayBuffer !== 'function') {
  Blob.prototype.arrayBuffer = function () {
    return new Promise((resolve, reject) => {
      const reader = new FileReader();
      reader.onload = () => resolve(reader.result as ArrayBuffer);
      reader.onerror = reject;
      reader.readAsArrayBuffer(this);
    });
  };
}

const { subtle } = globalThis.crypto ?? {};
if (!subtle || !subtle.digest) {
  const nodeCrypto = await import('node:crypto');
  Object.defineProperty(globalThis, 'crypto', { value: nodeCrypto.webcrypto, writable: true, configurable: true });
}

const UID = 'user-a';

const presetService = (over: Partial<StoredPresetSearchService> = {}): StoredPresetSearchService => ({
  id: 'svc-preset',
  kind: 'preset',
  serviceId: 'kimi',
  regionId: 'cn',
  boundHost: 'api.moonshot.cn',
  connectionRef: null,
  createdAt: 1,
  updatedAt: 1,
  ...over,
});

const customService = (over: Partial<StoredCustomSearchService> = {}): StoredCustomSearchService => ({
  id: 'svc-custom',
  kind: 'custom',
  name: 'Home SearXNG',
  protocol: 'searxng',
  address: 'https://searx.example.com/base',
  mapping: null,
  createdAt: 2,
  updatedAt: 2,
  ...over,
});

beforeEach(async () => {
  await closeSearchDB(UID);
  await closeSearchDB('guest');
  resetDBConnection();
  resetImageDBConnection();
  for (const db of await indexedDB.databases()) {
    if (db.name) indexedDB.deleteDatabase(db.name);
  }
  await setActiveUID(UID);
});

describe('search service store', () => {
  it('a separate store is created per account partition', async () => {
    await savePresetSearchService(UID, presetService(), { key: 'sk-preset' });
    const names = (await indexedDB.databases()).map((d) => d.name);
    expect(names).toContain(getSearchDBName(UID));
    expect(getSearchDBName(UID)).toBe('oriveo-search--user-a');
    expect(await listSearchServices('user-b')).toEqual([]);
  });

  it('preset: key bound to the host; a reused connection stores only the connection reference, no key', async () => {
    await savePresetSearchService(UID, presetService(), { key: 'sk-preset' });
    expect(await readSearchServiceKey(UID, 'svc-preset')).toBe('sk-preset');

    await savePresetSearchService(UID, presetService({ connectionRef: 'provider-kimi' }));
    expect(await readSearchServiceKey(UID, 'svc-preset')).toBeNull();
    await savePresetSearchService(UID, presetService({ connectionRef: null }));
    expect(await readSearchServiceKey(UID, 'svc-preset')).toBeNull();
  });

  it('key is normalized before saving: leading / trailing whitespace trimmed; non-compliant writes nothing', async () => {
    expect(await savePresetSearchService(UID, presetService(), { key: '  sk-abc123\n' })).toEqual({ ok: true });
    expect(await readSearchServiceKey(UID, 'svc-preset')).toBe('sk-abc123');
    expect(await saveCustomSearchService(UID, customService(), { key: 'tvly-密钥' })).toEqual({ ok: false, error: 'key_invalid' });
    expect(await savePresetSearchService(UID, presetService({ boundHost: 'api.moonshot.ai' }), { key: ' \t ' })).toEqual({ ok: false, error: 'key_empty' });
    expect((await listSearchServices(UID)).map((s) => [s.id, s.kind === 'preset' ? s.boundHost : null])).toEqual([['svc-preset', 'api.moonshot.cn']]);
    // Host re-confirmed (saved with the new boundHost, no key): the key is rebound and kept
    expect(await savePresetSearchService(UID, presetService({ boundHost: 'api.moonshot.ai' }))).toEqual({ ok: true });
    expect(await readSearchServiceKey(UID, 'svc-preset')).toBe('sk-abc123');
  });

  it('custom: path change keeps the key, origin change clears it', async () => {
    await saveCustomSearchService(UID, customService(), { key: 'searx-secret' });
    await saveCustomSearchService(UID, customService({ address: 'https://searx.example.com/other' }));
    expect(await readSearchServiceKey(UID, 'svc-custom')).toBe('searx-secret');

    await saveCustomSearchService(UID, customService({ address: 'https://searx.example.com:8443/other' }));
    expect(await readSearchServiceKey(UID, 'svc-custom')).toBeNull();

    await saveCustomSearchService(UID, customService(), { key: 'again' });
    await removeSearchService(UID, 'svc-custom');
    expect(await readSearchServiceKey(UID, 'svc-custom')).toBeNull();
    expect((await listSearchServices(UID)).map((s) => s.id)).toEqual([]);
  });

  it('results per search is stored on the service record, default 5 when absent', async () => {
    await savePresetSearchService(UID, presetService());
    await saveCustomSearchService(UID, customService({ resultCount: 8 }));
    const [preset, custom] = await listSearchServices(UID);
    expect(searchResultCount(preset.resultCount)).toBe(RESULT_COUNT_DEFAULT);
    expect(custom.resultCount).toBe(8);
  });

  it('default service id: store / read, isolated per account partition, after deleting a service falls back to the earliest via resolveDefaultSearchService', async () => {
    expect(await getDefaultSearchServiceId(UID)).toBeNull();
    await savePresetSearchService(UID, presetService());
    await saveCustomSearchService(UID, customService());
    await setDefaultSearchServiceId(UID, 'svc-custom');
    expect(await getDefaultSearchServiceId(UID)).toBe('svc-custom');
    expect(await getDefaultSearchServiceId('user-b')).toBeNull();

    const resolve = async () => resolveDefaultSearchService({
      serviceIds: (await listSearchServices(UID)).map((s) => s.id),
      storedDefault: await getDefaultSearchServiceId(UID),
    });
    expect(await resolve()).toBe('svc-custom');
    await removeSearchService(UID, 'svc-custom');
    expect(await resolve()).toBe('svc-preset');
    expect(await getDefaultSearchServiceId(UID)).toBeNull();
  });

  it('v1 store upgraded to v2: services and keys kept, meta table added', async () => {
    expect(SEARCH_DB_VERSION).toBe(2);
    await closeSearchDB(UID);
    const v1 = await openDB(getSearchDBName(UID), 1, {
      upgrade(db) {
        db.createObjectStore('services', { keyPath: 'id' });
        db.createObjectStore('credentials');
      },
    });
    await v1.put('services', presetService());
    await v1.put('credentials', { key: 'sk-old', boundTo: 'api.moonshot.cn' }, 'svc-preset');
    v1.close();
    expect((await listSearchServices(UID)).map((s) => s.id)).toEqual(['svc-preset']);
    expect(await readSearchServiceKey(UID, 'svc-preset')).toBe('sk-old');
    await setDefaultSearchServiceId(UID, 'svc-preset');
    expect(await getDefaultSearchServiceId(UID)).toBe('svc-preset');
  });

  it('guest migration carries the default id (account originally had no services); when the account already has services its default is untouched', async () => {
    await savePresetSearchService('guest', presetService());
    await saveCustomSearchService('guest', customService());
    await setDefaultSearchServiceId('guest', 'svc-custom');
    expect(await migrateGuestSearchData(UID)).toBe(2);
    expect(await getDefaultSearchServiceId(UID)).toBe('svc-custom');

    // Account already has services and never stored a default: the guest's default is not carried over
    await saveCustomSearchService('user-c', customService({ id: 'svc-own', createdAt: 0 }));
    await setDefaultSearchServiceId('guest', 'svc-preset');
    expect(await migrateGuestSearchData('user-c')).toBe(2);
    expect(await getDefaultSearchServiceId('user-c')).toBeNull();
    await closeSearchDB('user-c');
  });

  it('deleting the stored default id clears that key too; deleting another service leaves it alone', async () => {
    await savePresetSearchService(UID, presetService());
    await saveCustomSearchService(UID, customService());
    await setDefaultSearchServiceId(UID, 'svc-custom');
    await removeSearchService(UID, 'svc-preset');
    expect(await getDefaultSearchServiceId(UID)).toBe('svc-custom');
    await removeSearchService(UID, 'svc-custom');
    expect(await getDefaultSearchServiceId(UID)).toBeNull();
  });

  it('preset record stores the display name at save time', async () => {
    await savePresetSearchService(UID, presetService({ name: 'Kimi' }));
    const [saved] = await listSearchServices(UID);
    expect(saved.kind === 'preset' ? saved.name : null).toBe('Kimi');
  });

  it('guest migration: services and keys go into the account together, half-finished ones are not carried, idempotent, key lands only in the account partition by service id', async () => {
    await savePresetSearchService('guest', presetService(), { key: 'sk-guest' });
    await saveCustomSearchService('guest', customService(), { key: 'searx-guest' });
    await saveCustomSearchService('guest', customService({ id: 'svc-draft', pendingAdd: true }), { key: 'draft-key' });
    expect(await hasGuestSearchServices()).toBe(true);

    expect(await migrateGuestSearchData(UID)).toBe(2);
    // Running again is idempotent
    expect(await migrateGuestSearchData(UID)).toBe(0);
    expect((await listSearchServices(UID)).map((s) => s.id)).toEqual(['svc-preset', 'svc-custom']);
    expect(await readSearchServiceKey(UID, 'svc-preset')).toBe('sk-guest');
    expect(await readSearchServiceKey(UID, 'svc-custom')).toBe('searx-guest');
    // The half-finished entry and its key did not leak into the account partition
    expect(await readSearchServiceKey(UID, 'svc-draft')).toBeNull();
    expect(await migrateGuestSearchData('guest')).toBe(0);
  });

  it('guest with no search store: neither probing nor migration creates it', async () => {
    expect(await hasGuestSearchServices()).toBe(false);
    expect(await migrateGuestSearchData(UID)).toBe(0);
    expect((await indexedDB.databases()).some((database) => database.name === getSearchDBName('guest'))).toBe(false);
  });

  it('deleting the partition deletes the search store too', async () => {
    await saveCustomSearchService(UID, customService(), { key: 'searx-secret' });
    await closeSearchDB(UID);
    await deletePartitionData(UID);
    expect((await indexedDB.databases()).map((d) => d.name)).not.toContain(getSearchDBName(UID));
  });

  it('exported backups exclude it: even an export containing keys shows no search services or keys', async () => {
    await savePresetSearchService(UID, presetService(), { key: 'sk-preset-backup-probe' });
    await saveCustomSearchService(UID, customService(), { key: 'searx-backup-probe' });
    const { exportBackup } = await import('../../backup');
    for (const options of [{ includeApiKeys: false }, { includeApiKeys: true, password: 'pw-123456' }]) {
      const zip = await JSZip.loadAsync(await (await exportBackup(options)).arrayBuffer());
      const texts = await Promise.all(Object.values(zip.files).filter((f) => !f.dir).map((f) => f.async('string')));
      const all = texts.join('\n');
      expect(all).not.toContain('sk-preset-backup-probe');
      expect(all).not.toContain('searx-backup-probe');
      expect(all).not.toContain('searx.example.com');
      expect(all).not.toContain('svc-preset');
    }
  });
});
