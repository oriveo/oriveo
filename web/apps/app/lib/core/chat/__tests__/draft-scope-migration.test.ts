/**
 * Moving model-control scopes from a draft conversation to a real one.
 *
 * A new conversation only gets its id at the moment the first message is sent, so everything the
 * user changes in the panel before that lands under a local draft id. Every send path that creates
 * a conversation therefore has to move both kinds of draft: generation parameters and typed
 * capability preferences. With the two written separately, `operations-library-send` (which runs
 * library retrieval on the first message) moved only the generation parameters, and the web search
 * and reasoning preferences the user set in the draft state were silently lost on that path.
 * Duplicating the logic per call site gives no compile-time signal when one copy is missed.
 */
import { readFileSync } from 'node:fs';
import path from 'node:path';
import { beforeEach, describe, expect, it, vi } from 'vitest';

vi.mock('../../../infra/storage/partition', () => ({ getActiveUIDSync: () => 'guest' }));
vi.mock('../../metadata/metadata-client', () => ({
  getCapabilityRuntime: () => ({ revision: 'runtime-r7' }),
  resolveCatalogModel: () => ({ canonicalModelId: 'model-a', transport: 'openai_responses' }),
}));

import {
  displayCapabilityPreferences,
  encodeCapabilityTransportIdentity,
  saveCapabilityPreferenceDraft,
} from '../capability-preference-settings';
import { loadGenerationParameterOverrides, saveGenerationParameterOverrides } from '../generation-parameter-settings';
import { migrateDraftScopedModelControls } from '../draft-scope-migration';

const memory = new Map<string, string>();
vi.stubGlobal('window', { dispatchEvent: () => true });
vi.stubGlobal('localStorage', {
  getItem: (key: string) => memory.get(key) ?? null,
  setItem: (key: string, value: string) => { memory.set(key, value); },
  removeItem: (key: string) => { memory.delete(key); },
});

const transportIdentity = encodeCapabilityTransportIdentity('openai_responses', 'runtime-r7');
const provider = { id: 'a0000000-0000-0000-0000-000000000001', kind: 'openAI', models: [] } as never;
const model = { id: 'model-a', canonicalModelId: 'model-a', transport: 'openai_responses' } as never;
const identity = {
  providerId: 'a0000000-0000-0000-0000-000000000001',
  canonicalModelId: 'model-a',
  finalTransport: 'openai_responses',
  runtimeRevision: 'runtime-r7',
  transportIdentity,
};
const conversationId = 'b0000000-0000-0000-0000-000000000009';
const draftSessionId = 'draft-session-1';

describe('migrateDraftScopedModelControls', () => {
  beforeEach(() => memory.clear());

  it('moves both kinds of draft at once: generation parameters and typed capability preferences land in the new conversation scope', () => {
    saveGenerationParameterOverrides(
      { providerId: provider.id, modelId: model.id, conversationId: draftSessionId },
      { temperature: { state: 'value', value: 0.4 } },
    );
    saveCapabilityPreferenceDraft(draftSessionId, identity, { web: 'automatic', reasoningIntent: 'deep' });

    migrateDraftScopedModelControls({ provider, model, conversation: undefined, draftSessionId, conversationId });

    expect(loadGenerationParameterOverrides({ providerId: provider.id, modelId: model.id, conversationId })?.temperature)
      .toEqual({ state: 'value', value: 0.4 });
    expect(displayCapabilityPreferences({ ...identity, conversationId }))
      .toEqual({ web: 'automatic', reasoningIntent: 'deep' });
  });

  it('moves nothing for an existing conversation or a missing draft id, neither of which has a draft scope', () => {
    saveCapabilityPreferenceDraft(draftSessionId, identity, { web: 'force' });

    migrateDraftScopedModelControls({
      provider, model, conversation: { id: conversationId } as never, draftSessionId, conversationId,
    });
    migrateDraftScopedModelControls({ provider, model, conversation: undefined, draftSessionId: undefined, conversationId });

    expect(displayCapabilityPreferences({ ...identity, conversationId }).web).toBe('off');
  });
});

/**
 * Source assertions: a behavior test can prove the helper itself is correct, but not that every
 * conversation-creating path actually calls it. That is exactly the gap - `operations-library-send`
 * did call a migration function, but one that handled a single table.
 */
describe('conversation creation points must migrate both kinds of draft', () => {
  const sendPaths = ['operations-send.ts', 'operations-library-send.ts'];

  it('both send paths go through the same helper and never call a single-table migration directly', () => {
    for (const file of sendPaths) {
      const source = readSource(file);
      expect(source, file).toContain('migrateDraftScopedModelControls(');
      // Calling a single-table migration directly opens another path that moves only half. Adding a new table means changing the helper, not adding a second line at the call site.
      expect(source, file).not.toContain('migrateGenerationParameterSession(');
      expect(source, file).not.toContain('migrateCapabilityPreferenceDraft(');
    }
  });

  it('the helper itself touches both tables', () => {
    const helper = readSource('draft-scope-migration.ts');
    expect(helper).toContain('migrateGenerationParameterSession(');
    expect(helper).toContain('migrateCapabilityPreferenceDraft(');
  });
});

function readSource(file: string): string {
  let current = process.cwd();
  while (true) {
    const candidate = path.join(current, 'apps/app/lib/core/chat', file);
    try { return readFileSync(candidate, 'utf8'); } catch { /* keep walking up */ }
    const next = path.dirname(current);
    if (next === current) throw new Error(file);
    current = next;
  }
}
