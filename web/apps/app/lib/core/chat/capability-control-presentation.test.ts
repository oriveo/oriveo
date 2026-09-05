import { describe, expect, it, vi } from 'vitest';

const runtime = vi.hoisted(() => ({
  current: null as any,
  transport: undefined as string | undefined,
  catalog: null as any,
  reasoningLevels: [] as string[],
}));
// resolveCatalogModel/getDeclaredReasoningLevels feed the legacy fallback with the Server
// profile; these fixtures always return empty, so every assertion here exercises the pure
// v2 decision, and the fallback branch has dedicated cases below.
vi.mock('../metadata/metadata-client', () => ({
  getCapabilityRuntime: () => runtime.current,
  getModelTransport: () => runtime.transport,
  resolveCatalogModel: () => runtime.catalog ?? null,
  getDeclaredReasoningLevels: () => runtime.reasoningLevels ?? [],
}));
import {
  capabilityControlIsConfigurable,
  capabilityControlReasonMessageKey,
  hasExactCapabilityTransportRecipe,
  legacyCapabilityFallback,
  presentCapabilityControl,
} from './capability-control-presentation';

const provider = { id: 'provider', kind: 'openAI', status: { kind: 'connected' } } as any;
const model = (control: any) => ({ id: 'model', capabilityControls: { web: control } }) as any;
describe('capability control presentation', () => {
  it('keeps exact Web intents for the Composer instead of reasoning-only filtering', () => {
    runtime.current = { recipes: { web_recipe: {} }, sourceIndex: {} };
    expect(presentCapabilityControl(provider, model({ state: 'auto_available', recipeRef: 'web_recipe', availableIntents: ['force'] }), 'web')).toMatchObject({ state: 'auto_available', availableIntents: ['force'] });
  });
  it('returns an honest resolver reason for dangling runtime recipes', () => {
    runtime.current = { recipes: {}, sourceIndex: {} };
    expect(presentCapabilityControl(provider, model({ state: 'auto_available', recipeRef: 'missing' }), 'web')).toMatchObject({ state: 'unknown', reasonCode: 'dangling_recipe_ref' });
  });
  it('fails closed when the selected model transport differs from the exact catalog transport', () => {
    runtime.current = { recipes: { web_recipe: {} }, sourceIndex: {} };
    runtime.transport = 'openai_responses';
    expect(presentCapabilityControl(provider, { ...model({ state: 'auto_available', recipeRef: 'web_recipe' }), transport: 'openai_chat_completions' }, 'web')).toMatchObject({ state: 'unknown', reasonCode: 'transport_mismatch' });
    runtime.transport = undefined;
  });
  it('maps only stable reason tokens to local message keys', () => {
    expect(capabilityControlReasonMessageKey('unavailable', 'transport_not_supported')).toBe('capabilityControlReasonUnsupported');
    expect(capabilityControlReasonMessageKey('custom_only', 'relay_user_directory')).toBe('capabilityControlReasonCustom');
    expect(capabilityControlReasonMessageKey('auto_available', 'untrusted server prose')).toBe('capabilityControlReasonUnknown');
    expect(capabilityControlReasonMessageKey('custom_only', 'transport_not_supported')).toBe('capabilityControlReasonCustom');
    expect(capabilityControlReasonMessageKey('unknown', 'future_reason_code')).toBe('capabilityControlReasonPending');
  });
  it('keeps unknown configurable while explicit negative states remain read-only', () => {
    expect(capabilityControlIsConfigurable({ state: 'unknown' })).toBe(true);
    expect(capabilityControlIsConfigurable({ state: 'auto_available' })).toBe(true);
    expect(capabilityControlIsConfigurable({ state: 'unavailable' })).toBe(false);
    expect(capabilityControlIsConfigurable({ state: 'custom_only' })).toBe(false);
  });
  // Having an external connector or MCP but not on the chat request path must stay
  // distinguishable, in what the user sees, from having none at all; otherwise both
  // collapse into the same "not supported".
  it('separates an external-connector-only capability from a plain unsupported one', () => {
    expect(capabilityControlReasonMessageKey('unavailable', 'external_connector_only')).toBe('capabilityControlReasonExternalConnector');
    expect(capabilityControlReasonMessageKey('unavailable', 'no_official_managed_search')).toBe('capabilityControlReasonUnsupported');
  });
  // Reverse assertion: a new reasonCode only explains why, and must neither raise the state nor invent available steps.
  it('keeps an external-connector-only control unavailable with no intents', () => {
    runtime.current = {
      recipes: {},
      sourceIndex: { 'minimax.text_api': {}, 'minimax.web_search_mcp': {} },
    };
    const presented = presentCapabilityControl(provider, model({
      state: 'unavailable', reasonCode: 'external_connector_only',
      sourceRefs: ['minimax.text_api', 'minimax.web_search_mcp'],
    }), 'web');
    expect(presented).toEqual({
      state: 'unavailable', availableIntents: [], reasonCode: 'external_connector_only',
      viaLegacyProfile: false,
    });
  });

  // ── Legacy profile fallback ────────────────────────────────────
  // Observed in production: v2 reports unknown/official_source_insufficient for web across
  // the whole Qwen family, while the server has been publishing
  // `profiles.webSearch: qwen_web` and the request builder really does send enable_search.
  // Reporting unknown lights the web badge in the model library while chat can never send
  // it, so the two surfaces contradict each other and the feature regresses.
  describe('legacy profile fallback', () => {
    const web = (capabilities: string[], webSearch?: string) => ({
      id: 'model', capabilities, capabilityControls: {},
    }) as any;

    it('falls back to the Server-published Web profile when v2 has no recipe yet', () => {
      runtime.current = { recipes: {}, sourceIndex: {} };
      runtime.catalog = { profiles: { webSearch: 'qwen_web' }, capabilities: ['text', 'web'] };
      // The diagnostic bit reads a boolean rather than the reasonCode string; comparing
      // strings would be equivalent but more fragile. reasonCode is kept because the copy
      // still uses it.
      expect(legacyCapabilityFallback(provider, web(['text', 'web']), 'web')).toMatchObject({
        state: 'auto_available', reasonCode: 'legacy_profile', viaLegacyProfile: true,
      });
    });

    it('keeps an explicit v2 unavailable above any legacy profile', () => {
      runtime.current = { recipes: {}, sourceIndex: {} };
      runtime.catalog = { profiles: { webSearch: 'qwen_web' }, capabilities: ['text', 'web'] };
      const presented = presentCapabilityControl(provider, model({
        state: 'unavailable', reasonCode: 'transport_not_supported',
      }), 'web');
      expect(presented.state).toBe('unavailable');
      expect(presented.viaLegacyProfile).toBe(false);
    });

    it('stays honestly unknown when neither v2 nor a Server profile says anything', () => {
      runtime.current = { recipes: {}, sourceIndex: {} };
      runtime.catalog = { profiles: {}, capabilities: ['text'] };
      expect(presentCapabilityControl(provider, web(['text']), 'web')).toEqual({
        state: 'unknown', availableIntents: [], viaLegacyProfile: false,
      });
    });

    it('maps declared legacy reasoning levels onto v2 intent vocabulary', () => {
      runtime.current = { recipes: {}, sourceIndex: {} };
      runtime.catalog = { profiles: { reasoning: 'qwen_deep' }, capabilities: ['text'] };
      runtime.reasoningLevels = ['fast', 'balanced', 'deep', 'max'];
      expect(legacyCapabilityFallback(provider, web(['text']), 'reasoning')).toMatchObject({
        state: 'auto_available', availableIntents: ['low', 'balanced', 'deep', 'max'],
        viaLegacyProfile: true,
      });
      runtime.reasoningLevels = [];
    });

    // Having an automatic configuration but no ladder is a real production shape: reasoning
    // on openAI/gpt-5-pro and gpt-5.2-chat-latest is auto_available with empty
    // availableIntents and no legacy profile. It is neither a legacy fallback nor broken,
    // and both diagnostic bits have to say so honestly.
    it('keeps a published recipe with no intent ladder auto_available and not legacy', () => {
      runtime.current = { recipes: { reasoning_recipe: {} }, sourceIndex: {} };
      runtime.catalog = { profiles: {}, capabilities: ['text', 'reasoning'] };
      const presented = presentCapabilityControl(provider, {
        id: 'model', capabilities: ['text', 'reasoning'],
        capabilityControls: { reasoning: { state: 'auto_available', recipeRef: 'reasoning_recipe' } },
      } as any, 'reasoning');
      expect(presented).toEqual({
        state: 'auto_available', availableIntents: [], viaLegacyProfile: false,
      });
    });
  });
});

/**
 * A candidate model must carry a recipe written for its own protocol.
 *
 * `presentCapabilityControl` answers what the server decided and stops one check short of
 * this one: a recipe written for another protocol is dropped whole at outbound compile time
 * with `transport_mismatch`. Without this check, "show supported models" becomes a second
 * dead end, when it is the only way out of the "unavailable" row.
 */
describe('candidate models must carry a recipe for the exact transport', () => {
  const catalogModel = (control: any, transport?: string) => ({
    id: 'model', transport, capabilityControls: { web: control },
  }) as any;

  it('counts a model as a candidate only when the recipe protocol matches the catalog protocol', () => {
    runtime.current = { recipes: { web_recipe: { transport: { protocol: 'openai_responses' } } }, sourceIndex: {} };
    runtime.transport = 'openai_responses';
    expect(hasExactCapabilityTransportRecipe(
      provider, catalogModel({ state: 'auto_available', recipeRef: 'web_recipe' }), 'web',
    )).toBe(true);
  });

  it('does not count a model whose recipe was written for another protocol', () => {
    runtime.current = { recipes: { web_recipe: { transport: { protocol: 'openai_chat' } } }, sourceIndex: {} };
    runtime.transport = 'openai_responses';
    expect(hasExactCapabilityTransportRecipe(
      provider, catalogModel({ state: 'auto_available', recipeRef: 'web_recipe' }), 'web',
    )).toBe(false);
  });

  it('normalizes catalog transport aliases against the recipe vocabulary (gemini_generate and gemini_generate_content)', () => {
    runtime.current = { recipes: { web_recipe: { transport: { protocol: 'gemini_generate_content' } } }, sourceIndex: {} };
    runtime.transport = 'gemini_generate';
    expect(hasExactCapabilityTransportRecipe(
      provider, catalogModel({ state: 'auto_available', recipeRef: 'web_recipe' }), 'web',
    )).toBe(true);
  });

  it('rejects a dangling recipeRef, a missing runtime and a missing control alike', () => {
    runtime.current = { recipes: {}, sourceIndex: {} };
    runtime.transport = 'openai_responses';
    expect(hasExactCapabilityTransportRecipe(
      provider, catalogModel({ state: 'auto_available', recipeRef: 'missing' }), 'web',
    )).toBe(false);
    expect(hasExactCapabilityTransportRecipe(
      provider, catalogModel({ state: 'auto_available' }), 'web',
    )).toBe(false);
    expect(hasExactCapabilityTransportRecipe(provider, { id: 'model' } as any, 'web')).toBe(false);
    expect(hasExactCapabilityTransportRecipe(undefined, catalogModel({ state: 'auto_available' }), 'web')).toBe(false);
  });

  it('leaves states other than auto_available alone, since the contract gives them no recipe', () => {
    runtime.current = { recipes: {}, sourceIndex: {} };
    runtime.transport = 'openai_responses';
    expect(hasExactCapabilityTransportRecipe(
      provider, catalogModel({ state: 'custom_only' }), 'web',
    )).toBe(true);
  });
});
