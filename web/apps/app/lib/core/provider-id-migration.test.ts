import { describe, expect, it } from 'vitest';
import type { Provider } from '@oriveo/shared';
import { planProviderIdMigration } from './provider-id-migration';
import { resolveProviderSetupCatalog } from '../../app/providers/new/provider-config-catalog';

const catalog = resolveProviderSetupCatalog(null);

// Deterministic id for openRouter with no region, from the golden vectors
const OPENROUTER_DET = '644B24B7-E017-5253-BDDA-2E1D24A0608E';

function provider(partial: Partial<Provider> & { id: string; kind: Provider['kind'] }): Provider {
  return {
    status: { kind: 'connected' },
    models: [],
    catalogModels: [],
    apiKey: '',
    apiKeyPreview: '',
    ...partial,
  } as Provider;
}

describe('planProviderIdMigration', () => {
  it('a single official instance with a random id collapses to its deterministic id', async () => {
    const plan = await planProviderIdMigration(
      [provider({ id: 'random-x', kind: 'openRouter', apiKey: 'sk-1' })],
      catalog,
    );
    expect(plan.changed).toBe(true);
    expect(plan.nextProviders).toHaveLength(1);
    expect(plan.nextProviders[0].id).toBe(OPENROUTER_DET);
    expect(plan.toDelete).toContain('random-x');
    expect(plan.toPut.map((p) => p.id)).toContain(OPENROUTER_DET);
  });

  it('two duplicates with the same kind and apiKey collapse into one deterministic id, merging their models', async () => {
    const plan = await planProviderIdMigration(
      [
        provider({ id: 'rand-a', kind: 'openRouter', apiKey: 'sk-1', models: [{ id: 'm1' } as never] }),
        provider({ id: 'rand-b', kind: 'openRouter', apiKey: 'sk-1', models: [{ id: 'm2' } as never] }),
      ],
      catalog,
    );
    expect(plan.changed).toBe(true);
    const survivors = plan.nextProviders.filter((p) => p.kind === 'openRouter');
    expect(survivors).toHaveLength(1);
    expect(survivors[0].id).toBe(OPENROUTER_DET);
    expect(survivors[0].models.map((m) => m.id).sort()).toEqual(['m1', 'm2']);
    expect(plan.toDelete).toEqual(expect.arrayContaining(['rand-a', 'rand-b'].filter((x) => x !== OPENROUTER_DET)));
  });

  it('same kind but different apiKey: one collapses to the deterministic id and the other keeps its random id', async () => {
    const plan = await planProviderIdMigration(
      [
        provider({ id: 'rand-a', kind: 'openRouter', apiKey: 'sk-1' }),
        provider({ id: 'rand-b', kind: 'openRouter', apiKey: 'sk-2' }),
      ],
      catalog,
    );
    expect(plan.changed).toBe(true);
    const ids = plan.nextProviders.filter((p) => p.kind === 'openRouter').map((p) => p.id);
    expect(ids).toContain(OPENROUTER_DET);
    // An instance created with a different key keeps its original random id
    expect(ids).toContain('rand-b');
    expect(ids).toHaveLength(2);
  });

  it('does not rewrite relay ids', async () => {
    const plan = await planProviderIdMigration(
      [
        provider({ id: 'relay-1', kind: 'relay', apiKey: 'sk' }),
      ],
      catalog,
    );
    expect(plan.changed).toBe(false);
    expect(plan.nextProviders.map((p) => p.id)).toEqual(['relay-1']);
    expect(plan.toDelete).toHaveLength(0);
  });

  it('an official instance that already has a deterministic id is left unchanged', async () => {
    const plan = await planProviderIdMigration(
      [provider({ id: OPENROUTER_DET, kind: 'openRouter', apiKey: 'sk-1' })],
      catalog,
    );
    expect(plan.changed).toBe(false);
    expect(plan.toDelete).toHaveLength(0);
    expect(plan.nextProviders[0].id).toBe(OPENROUTER_DET);
  });
});
