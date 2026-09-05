import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { describe, expect, it, vi } from 'vitest';

/**
 * Drives the real verdict functions with the **metadata slice production actually serves**.
 *
 * Why not another set of hand-written fixtures: the previous round of verification was all "unit
 * tests pass / curl shows the right field / deploy returned 200", none of which says anything about
 * what the user sees on screen, and every test built its own data to make its own assertion hold.
 * The state/profile combinations here are lifted verbatim from the live metadata response, so the
 * assertions are about models users really hit that day.
 *
 * The slice itself lives in `shared/model-contracts/`, so one snapshot of production truth feeds the
 * real verdict function of each client and whichever one drifts turns red first.
 * The expected values live in that same slice (`expectedVerdicts`) - keeping a separate copy per
 * client would lock nothing at all.
 */

// vitest starts with cwd = apps/app; three levels up (apps -> web -> repository root) reaches shared/.
const snapshot = JSON.parse(
  readFileSync(
    resolve(process.cwd(), '../../..', 'shared/model-contracts/production-capability-snapshot.json'),
    'utf-8',
  ),
) as {
  profiles: { reasoning: Record<string, { levels: string[] }> };
  models: Record<string, unknown>;
  expectedVerdicts: Record<string, unknown>;
};

const runtime = vi.hoisted(() => ({
  catalog: null as any,
  reasoningLevels: [] as string[],
}));

/**
 * Every recipeRef that appears in the slice must be registered in the runtime.
 *
 * This mock used to pass `recipes: {}` with a comment claiming it only had to be non-empty, which
 * made the suite falsely green: `resolveControl` looks recipeRef up in `recipes`, and a miss is
 * judged `dangling_recipe_ref` and degrades the whole entry to unknown, so every auto_available
 * control carrying a recipeRef fell through to the legacy path - the assertion about "not consulting
 * the legacy profile" was in fact passing via the legacy profile. Production really does publish
 * these recipes (that is why the controls carry a recipeRef), so filling them in is the true shape.
 */
const publishedRecipes = Object.fromEntries(
  Object.values(snapshot.models as Record<string, { capabilityControls: Record<string, { recipeRef?: string }> }>)
    .flatMap((entry) => Object.values(entry.capabilityControls))
    .map((control) => control.recipeRef)
    .filter((ref): ref is string => typeof ref === 'string')
    .map((ref) => [ref, {}]),
);

vi.mock('../metadata/metadata-client', () => ({
  // The production capabilityRuntime is published; recipe compilation is locked by the
  // request-compiler contract tests, so all that is needed here is a resolvable recipeRef, letting
  // auto_available controls take the v2 branch for real.
  getCapabilityRuntime: () => ({ recipes: publishedRecipes, sourceIndex: {}, controlDefinitions: {} }),
  getModelTransport: () => undefined,
  resolveCatalogModel: () => runtime.catalog,
  getDeclaredReasoningLevels: (name?: string | null) => (
    name ? snapshot.profiles.reasoning[name]?.levels ?? [] : []
  ),
}));

// eslint-disable-next-line import/first -- vi.mock must be evaluated before the module under test
import { presentCapabilityControl } from './capability-control-presentation';

type SnapshotModel = {
  providerKind: string;
  modelId: string;
  capabilities: string[];
  profiles: { reasoning: string | null; webSearch: string | null };
  capabilityControls: Record<string, { state?: string; reasonCode?: string }>;
  transport: string;
};

type ExpectedVerdict = {
  state: string;
  viaLegacyProfile: boolean;
  /** Omitted means the exact levels are unconstrained; only state and viaLegacyProfile are checked. */
  intents?: string[];
};

const models = snapshot.models as unknown as Record<string, SnapshotModel>;
const expectedVerdicts = Object.fromEntries(
  Object.entries(snapshot.expectedVerdicts).filter(([key]) => key !== '$comment'),
) as Record<string, Record<'web' | 'reasoning', ExpectedVerdict>>;

const CAPABILITIES = ['web', 'reasoning'] as const;

function verdict(key: string, capability: 'web' | 'reasoning') {
  const entry = models[key];
  const provider = { id: 'p', kind: entry.providerKind, status: { kind: 'connected' } } as any;
  runtime.catalog = {
    capabilities: entry.capabilities,
    profiles: { webSearch: entry.profiles.webSearch, reasoning: entry.profiles.reasoning },
    transport: entry.transport,
  };
  const model = {
    id: entry.modelId,
    capabilities: entry.capabilities,
    capabilityControls: entry.capabilityControls,
  } as any;
  return presentCapabilityControl(provider, model, capability);
}

describe('production capability snapshot', () => {
  it('keeps Qwen unknown when the exact v2 recipe is not published yet', () => {
    // Live: capabilityControls.web = unknown/official_source_insufficient. Even though the existing
    // profiles.webSearch still carries qwen_web, a new client must not treat that as an automatic
    // configuration. The valid final body for ordinary chat is locked separately by the production
    // builder contract tests.
    expect(verdict('qwen/qwen3-max', 'web')).toMatchObject({
      state: 'unknown',
      viaLegacyProfile: false,
    });
  });

  it('keeps Web off where the recipe positively says this transport cannot do it', () => {
    // Live: unavailable/transport_not_supported - the official note says Responses API only.
    expect(verdict('qwen/qwen3.6-plus', 'web').state).toBe('unavailable');
  });

  it('honours a published v2 recipe without consulting any legacy profile', () => {
    for (const [key, capability] of [['zhipu/glm-4.6', 'web'], ['anthropic/claude-fable-5', 'reasoning']] as const) {
      const presented = verdict(key, capability);
      expect(presented.state, `${key}/${capability}`).toBe('auto_available');
      expect(presented.viaLegacyProfile, `${key}/${capability}`).toBe(false);
    }
  });

  it('does not invent Web for a model that has neither a control nor a profile', () => {
    expect(verdict('anthropic/claude-fable-5', 'web').state).toBe('unavailable');
  });

  it('leaves an explicitly unsupported reasoning control unavailable', () => {
    // Live, 128 openRouter models are unavailable/upstream_parameter_not_declared with no legacy
    // reasoning profile - the fallback must not promote them to available.
    expect(verdict('openRouter/anthropic/claude-opus-4.5', 'reasoning').state).toBe('unavailable');
  });

  it('exposes legacy reasoning tiers in v2 intent vocabulary', () => {
    const presented = verdict('zhipu/glm-4.6', 'reasoning');
    expect(presented.state).toBe('auto_available');
  });

  // -- Full per-model matrix ------------------------------------------------
  //
  // Testing only "a few hand-picked models that have capabilities" is exactly what went wrong last
  // time: 362 of the 764 live models cannot emit a single web search tool, and most users land on
  // the empty side. This runs the real verdict for **every** model in the slice, against the
  // expectedVerdicts the slice carries.

  it('covers every model in the shared slice — no cherry-picking', () => {
    expect(Object.keys(expectedVerdicts).sort()).toEqual(Object.keys(models).sort());
  });

  it.each(CAPABILITIES)('resolves %s for every production model exactly as the shared table says', (capability) => {
    let available = 0;
    let unavailable = 0;
    for (const key of Object.keys(models)) {
      const expected = expectedVerdicts[key]![capability];
      const presented = verdict(key, capability);
      expect(presented.state, `${key}/${capability} state`).toBe(expected.state);
      expect(presented.viaLegacyProfile, `${key}/${capability} viaLegacyProfile`).toBe(expected.viaLegacyProfile);
      if (expected.intents) {
        expect([...presented.availableIntents], `${key}/${capability} intents`).toEqual(expected.intents);
      }
      // The shared test for badge and control must be decided by state alone; nowhere may add a rule of its own.
      const usable = presented.state === 'auto_available' || presented.state === 'managed_only';
      usable ? (available += 1) : (unavailable += 1);
    }
    // The empty side is a first-class case: if the slice is ever trimmed down to only the capable
    // models, these two turn red.
    expect(available, `${capability}: available side must not be empty`).toBeGreaterThan(0);
    expect(unavailable, `${capability}: unavailable side must not be empty`).toBeGreaterThan(0);
  });

  // -- "Automatic configuration but no ladder" is a first-class state, not a broken auto_available --
  //
  // Production evidence: reasoning for openAI/gpt-5-pro and gpt-5.2-chat-latest is auto_available
  // with an empty availableIntents and no legacy reasoning profile. That is deliberate on the server
  // side (the pro variant rejects low, and these two single-value models accept only high and medium
  // respectively; with no selectable level there is no point drawing a button that must fail). The
  // client must not downgrade this to unavailable, nor invent levels - that leads straight to "the
  // panel says available and offers no level at all".
  it.each(['openAI/gpt-5-pro', 'openAI/gpt-5.2-chat-latest'])(
    'keeps %s reasoning auto_available with an honestly empty intent ladder',
    (key) => {
      const entry = models[key]!;
      // Prove the premise: the slice itself has this shape, rather than the assertion assuming it.
      expect(entry.capabilityControls.reasoning!.state, `${key} slice state`).toBe('auto_available');
      expect((entry.capabilityControls.reasoning as { availableIntents?: string[] }).availableIntents,
        `${key} slice has no availableIntents`).toBeUndefined();
      expect(entry.profiles.reasoning, `${key} slice has no legacy reasoning profile`).toBeNull();

      const presented = verdict(key, 'reasoning');
      expect(presented.state).toBe('auto_available');
      expect(presented.availableIntents).toEqual([]);
      expect(presented.viaLegacyProfile).toBe(false);
    },
  );
});
