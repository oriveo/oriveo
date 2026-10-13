/**
 * A credential-less copy of a provider must not replace the API key stored on this device.
 *
 * When the store has not been hydrated (providers is empty) but is already
 * `hydrationPhase === 'ready'`, a provider that enters it without a key is persisted as a whole
 * row and would overwrite the row with the same id that still holds the key.
 */

import 'fake-indexeddb/auto';

import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import type { Provider } from '@oriveo/shared';

import { createAppStore } from '../store/app-store';
import { subscribeToChanges } from '../store/persistence';
import { getAllProviders, putProvider, resetDBConnection } from '../../infra/storage/idb';
import { setActiveUID } from '../../infra/storage/partition';

const PROVIDER_ID = '11111111-2222-5333-8444-555555555555';

function makeProvider(overrides: Partial<Provider> = {}): Provider {
  return {
    id: PROVIDER_ID,
    kind: 'openAI',
    status: { kind: 'connected' },
    models: [],
    catalogModels: [],
    apiKey: 'sk-my-key',
    apiKeyPreview: '••••-key',
    ...overrides,
  };
}

async function settleIDBWrites() {
  for (let i = 0; i < 5; i += 1) await new Promise((resolve) => setTimeout(resolve, 0));
}

describe('providers entering a store that was never hydrated', () => {
  let unsubscribe: (() => void) | null = null;

  beforeEach(async () => {
    resetDBConnection();
    await setActiveUID('guest');
    await putProvider(makeProvider());
  });

  afterEach(() => {
    unsubscribe?.();
    unsubscribe = null;
  });

  it('a credential-less copy does not overwrite the apiKey of the stored row with the same id', async () => {
    // End state of the startup timeout fallback: never hydrated, providers empty, yet already
    // ready with the persistence subscribers attached.
    const store = createAppStore();
    store.setState({ hydrationPhase: 'ready' });
    unsubscribe = subscribeToChanges(store);

    store.setState({ providers: [makeProvider({ apiKey: '', apiKeyPreview: '' })] });
    await settleIDBWrites();

    const persisted = await getAllProviders();
    expect(persisted).toHaveLength(1);
    expect(persisted[0].apiKey).toBe('sk-my-key');
    // The copy in the store is swapped back to the stored row, so the list no longer asks for a key.
    expect(store.getState().providers).toHaveLength(1);
    expect(store.getState().providers[0].apiKey).toBe('sk-my-key');
  });

  it('clearing the key on a hydrated store is persisted as usual', async () => {
    const store = createAppStore();
    store.setState({ providers: await getAllProviders(), hydrationPhase: 'ready' });
    unsubscribe = subscribeToChanges(store);

    store.getState().updateProvider(PROVIDER_ID, { apiKey: '', apiKeyPreview: '' });
    await settleIDBWrites();

    expect((await getAllProviders())[0].apiKey).toBe('');
  });

  it('a new provider with no stored row is written as usual', async () => {
    const store = createAppStore();
    const stored = await getAllProviders();
    store.setState({ providers: stored, hydrationPhase: 'ready' });
    unsubscribe = subscribeToChanges(store);

    store.setState({
      providers: [
        ...stored,
        makeProvider({ id: '99999999-2222-5333-8444-555555555555', kind: 'anthropic', apiKey: '', apiKeyPreview: '' }),
      ],
    });
    await settleIDBWrites();

    const persisted = await getAllProviders();
    expect(persisted.map((provider) => provider.kind).sort()).toEqual(['anthropic', 'openAI']);
  });
});
