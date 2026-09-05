import type { AIModel, Provider } from '@oriveo/shared';
import { resolveControl } from '@oriveo/core/providers/request-preference/capability-runtime';
import { canonicalRecipeTransport } from '@oriveo/core/providers/request-builders/capability-execution';
import type { CapabilityKey } from '@oriveo/core/providers/request-preference/types';
import { codexReasoningEffort } from '@oriveo/core/providers/openai-subscription';
import {
  getCapabilityRuntime,
  getDeclaredReasoningLevels,
  getModelTransport,
  subscriptionDeclaredReasoningLevels,
} from '../metadata/metadata-client';
import { currentCapabilityEvidenceModel, resolveModelCapabilityEvidence } from './capability-evidence';
import { customFragmentOwnerFacts } from './custom-fragment-settings';
import { modelControlWebReachesTheWire, resolveModelControlStatus } from './model-control-capability-layout';
import { subscriptionFinalTransport } from './capability-preference-settings';

export type CapabilityControlPresentation = {
  state: 'auto_available' | 'managed_only' | 'custom_only' | 'unavailable' | 'unknown';
  availableIntents: readonly string[];
  /** Stable runtime verdict, for localized UI diagnostics only (never raw server prose). */
  reasonCode?: string;
  /**
   * true when this verdict came from a legacy profile fallback rather than a v2 recipe, so
   * diagnostics can tell them apart. Comparing `reasonCode === 'legacy_profile'` would be
   * equivalent but more brittle: renaming the constant silently loses the signal and the type
   * system cannot catch it. reasonCode stays reserved for user-facing text.
   */
  viaLegacyProfile: boolean;
};

/** Only local message keys cross the UI boundary; Server reasonCode is never prose. */
export function capabilityControlReasonMessageKey(
  state: CapabilityControlPresentation['state'],
  reasonCode: string | undefined,
):
  | 'capabilityControlReasonPending'
  | 'capabilityControlReasonUnsupported'
  | 'capabilityControlReasonExternalConnector'
  | 'capabilityControlReasonCustom'
  | 'capabilityControlReasonUnknown' {
  // State is the Server verdict. reasonCode is an open, supplementary diagnostic
  // vocabulary and must never turn custom_only into unavailable (or vice versa).
  if (state === 'custom_only') return 'capabilityControlReasonCustom';
  if (state === 'unknown') return 'capabilityControlReasonPending';
  if (reasonCode === 'relay_user_directory') return 'capabilityControlReasonCustom';
  if (reasonCode === 'endpoint_route_pending' || reasonCode === 'model_route_pending'
    || reasonCode === 'official_source_insufficient' || reasonCode === 'source_review_expired'
    || reasonCode === 'provider_kill_switch') return 'capabilityControlReasonPending';
  // The provider does have this capability, but only as a separate external service / MCP
  // connector outside this connection's chat request. Folding it into the generic
  // "not supported" copy would hide the boundary from the user.
  if (reasonCode === 'external_connector_only') return 'capabilityControlReasonExternalConnector';
  if (reasonCode === 'no_official_managed_search' || reasonCode === 'transport_not_supported'
    || reasonCode === 'model_capability_absent' || reasonCode === 'retired_model_alias'
    || reasonCode === 'upstream_parameter_not_declared') return 'capabilityControlReasonUnsupported';
  return state === 'unavailable'
    ? 'capabilityControlReasonUnsupported'
    : 'capabilityControlReasonUnknown';
}

const LEGACY_REASONING_INTENTS: Record<string, string> = {
  fast: 'low', balanced: 'balanced', deep: 'deep', max: 'max',
};

/**
 * The legacy request profile from bundled provider config `.profiles`.
 *
 * This is NOT a client-side model-id heuristic — it is the same Server-authored
 * profile the request builders actually dispatch (`resolveWebSearchProfile` /
 * `resolveReasoningParams`). Reading it back is therefore allowed where the rule against
 * guessing applies: what is banned is inventing a capability from a model id, not consuming a
 * capability the catalog already published.
 */
/** Kept for readers that still consume the older profile shape; the current presentation does not. */
export function legacyCapabilityFallback(
  provider: Provider,
  model: AIModel,
  capability: CapabilityKey,
  resolvedModel?: ReturnType<typeof currentCapabilityEvidenceModel>,
): CapabilityControlPresentation | undefined {
  // Relay directories come from the user's own machine; they never carry an
  // official Server profile, so there is nothing authoritative to fall back to.
  if (provider.kind === 'relay') return undefined;
  const current = resolvedModel ?? currentCapabilityEvidenceModel(provider, model);
  const evidenceSupported = (key: 'web_search' | `reasoning_level/${string}`) => (
    resolveModelCapabilityEvidence({ key, provider, model }).support === 'supported'
  );
  if (capability === 'web') {
    // Manually added models and older persisted records can be missing the capabilities array entirely, so it must not be assumed present.
    const byProfile = (current.capabilities ?? []).includes('web') && Boolean(current.webSearchProfile);
    return byProfile || evidenceSupported('web_search')
      ? { state: 'auto_available', availableIntents: ['off', 'automatic'], reasonCode: 'legacy_profile', viaLegacyProfile: true }
      : undefined;
  }
  if (capability === 'reasoning') {
    // Declared profile levels first; the evidence facade is the second source so
    // a future Server-published `reasoning_level/*` verdict still lights the control
    // up without a profile. Today's production metadata publishes neither
    // `reasoning_level/*` nor `web_search` candidates, so profiles carry it alone.
    const levels = getDeclaredReasoningLevels(current.reasoningProfile);
    const byEvidence = levels.length === 0
      ? (Object.keys(LEGACY_REASONING_INTENTS) as (keyof typeof LEGACY_REASONING_INTENTS)[])
        .filter((level) => evidenceSupported(`reasoning_level/${level}`))
      : [];
    const effective = levels.length > 0 ? levels : byEvidence;
    return effective.length > 0
      ? {
          state: 'auto_available',
          availableIntents: effective.map((level) => LEGACY_REASONING_INTENTS[level] ?? level),
          reasonCode: 'legacy_profile',
          viaLegacyProfile: true,
        }
      : undefined;
  }
  return undefined;
}

/**
 * Capability verdict for the subscription paths (Grok subscription and Codex).
 *
 * Subscription models are not in the metadata catalog and never have a v2 control. Falling back to
 * `unknown` would make the UI render "not adjustable" for a capability the upstream explicitly
 * declares, leaving the user with no switch at all. The authority for these paths is not the
 * catalog anyway: the subscription's own `/models` endpoint declares capabilities per model, and
 * that is the only legitimate authority here.
 *
 * Both subscription paths allow a capability only when the upstream declares it per model. Grok
 * additionally requires the final protocol to be Responses; an explicit chat declaration has no
 * real web_search and must stay unavailable.
 */
function subscriptionCapabilityControl(
  provider: Provider,
  model: AIModel,
  capability: CapabilityKey,
): CapabilityControlPresentation {
  if (capability === 'web') {
    if (provider.kind === 'grok' && subscriptionFinalTransport(provider, model) !== 'openai_responses') {
      return {
        state: 'unavailable', availableIntents: [],
        reasonCode: 'upstream_transport_without_web_search', viaLegacyProfile: false,
      };
    }
    return (model.capabilities ?? []).includes('web')
      ? {
          state: 'auto_available',
          availableIntents: provider.kind === 'grok' ? ['automatic'] : ['off', 'automatic'],
          reasonCode: 'subscription_upstream_declared', viaLegacyProfile: false,
        }
      : {
          state: 'unavailable', availableIntents: [],
          reasonCode: 'model_capability_absent', viaLegacyProfile: false,
        };
  }
  if (capability === 'reasoning') {
    // Filter the available levels with the same function used on the outbound path, so every level
    // shown in the UI maps to a value the upstream actually accepts. A second mapping would drift,
    // which is exactly how the UI ends up offering a choice that is sent as something else.
    const declared = subscriptionDeclaredReasoningLevels(provider.kind, model);
    const intents = (Object.keys(LEGACY_REASONING_INTENTS) as Array<keyof typeof LEGACY_REASONING_INTENTS>)
      .filter((mode) => codexReasoningEffort(mode, declared) !== undefined)
      .map((mode) => LEGACY_REASONING_INTENTS[mode] ?? mode);
    return intents.length > 0
      ? {
          state: 'auto_available', availableIntents: intents,
          reasonCode: 'subscription_upstream_declared', viaLegacyProfile: false,
        }
      : {
          state: 'unavailable', availableIntents: [],
          reasonCode: 'upstream_parameter_not_declared', viaLegacyProfile: false,
        };
  }
  // Every other capability has no declared source on the subscription paths, so report unknown honestly.
  return { state: 'unknown', availableIntents: [], viaLegacyProfile: false };
}

/**
 * The single capability verdict for one provider/model/capability. Both the chat
 * composer controls and the model-list badges resolve through this function, so
 * "the library says it supports Web / the composer cannot turn Web on" is
 * structurally impossible rather than merely tested against.
 *
 * Precedence:
 *   1. A valid v2 control decides, including an explicit `unavailable` — a
 *      recipe that positively says "this transport/model cannot do it" outranks
 *      any older profile.
 *   2. `unknown` or a missing runtime remains honest `unknown`; new clients do
 *      not revive legacy profiles. The reader above exists only for older callers.
 */
export function presentCapabilityControl(
  provider: Provider | undefined,
  model: AIModel | undefined,
  capability: CapabilityKey,
  /** Pass an already-resolved catalog projection to avoid re-resolving it per capability. */
  resolvedModel?: ReturnType<typeof currentCapabilityEvidenceModel>,
): CapabilityControlPresentation {
  void resolvedModel;
  if (!provider || !model) return { state: 'unknown', availableIntents: [], viaLegacyProfile: false };
  // Subscription paths exit early: their capability authority is the upstream /models declaration,
  // not the catalog (see the function comment above). This must come before the catalog transport
  // check, because subscription models are not in the catalog at all and would only fall to unknown.
  if (provider.authMode === 'subscription') {
    return subscriptionCapabilityControl(provider, model, capability);
  }
  // A persisted model can survive a metadata refresh. Do not present a
  // recipe when the selected model and catalog would dispatch different transports.
  const catalogTransport = getModelTransport(model.id, provider.kind);
  if (catalogTransport && model.transport && catalogTransport !== model.transport) {
    return { state: 'unknown', availableIntents: [], reasonCode: 'transport_mismatch', viaLegacyProfile: false };
  }
  const runtime = getCapabilityRuntime();
  const control = model.capabilityControls?.[capability];
  if (!runtime || !control) {
    return { state: 'unknown', availableIntents: [], viaLegacyProfile: false };
  }
  const resolved = resolveControl(provider.kind, capability, control, {
    recipes: Object.keys(runtime.recipes ?? {}),
    sourceIndex: runtime.sourceIndex ?? {},
    controlDefinitions: runtime.controlDefinitions ?? {},
  });
  const state = ['auto_available', 'managed_only', 'custom_only', 'unavailable', 'unknown'].includes(resolved.state)
    ? resolved.state as CapabilityControlPresentation['state']
    : 'unknown';
  return {
    state,
    availableIntents: resolved.valid && Array.isArray(control.availableIntents)
      ? control.availableIntents
      : [],
    ...(resolved.reason ?? control.reasonCode ? { reasonCode: resolved.reason ?? control.reasonCode } : {}),
    viaLegacyProfile: false,
  };
}

/**
 * Call sites outside the panel (chip highlighting, restore state, the explicit outbound intent key)
 * have no ready status or custom facts, so recompute once from the production source. The rule
 * itself is only `modelControlWebReachesTheWire`; this just gathers the facts.
 *
 * This is meant for discrete events (effects, callbacks, the send path), not the render hot path:
 * it parses a metadata snapshot and reads the local custom configuration once.
 */
export function webPreferenceReachesTheWire(input: {
  provider?: Provider;
  model?: AIModel;
  transportIdentity?: string;
}): boolean {
  const status = resolveModelControlStatus(presentCapabilityControl(input.provider, input.model, 'web'));
  if (status === 'automaticAvailable') return true;
  if (!input.provider || !input.model || !input.transportIdentity) return false;
  return modelControlWebReachesTheWire({
    status,
    customIsActive: customFragmentOwnerFacts({
      provider: input.provider, model: input.model, transportIdentity: input.transportIdentity, owner: 'web',
    }).isActive,
  });
}

/**
 * Whether the protocol declared by this model recipe is the same one the catalog gives it.
 *
 * `presentCapabilityControl` answers "what is the server verdict for this capability", which is one
 * check short of this one: it does not verify the exact transport - **a recipe written for another
 * protocol is as good as absent**. At outbound compile time `resolveRuntimeRecipe` drops it with
 * `transport_mismatch`, so switching to that model would only lead to a second dead end. The
 * candidate rule behind "view supported models" therefore has to ask this extra question.
 *
 * States other than `auto_available` have no recipe by contract, so this check must not mark them unavailable.
 */
export function hasExactCapabilityTransportRecipe(
  provider: Provider | undefined,
  model: AIModel | undefined,
  capability: CapabilityKey,
): boolean {
  if (!provider || !model) return false;
  const control = model.capabilityControls?.[capability];
  if (!control) return false;
  if (control.state !== 'auto_available') return true;
  const runtime = getCapabilityRuntime();
  const recipeRef = control.recipeRef;
  const modelTransport = getModelTransport(model.id, provider.kind) ?? model.transport;
  if (!runtime || !recipeRef || !modelTransport) return false;
  const recipe = runtime.recipes?.[recipeRef];
  if (!recipe || typeof recipe !== 'object' || Array.isArray(recipe)) return false;
  const transport = (recipe as { transport?: { protocol?: string } }).transport?.protocol;
  return canonicalRecipeTransport(transport) === canonicalRecipeTransport(modelTransport);
}

/** D0: missing capability knowledge is still user-configurable; only a negative verdict disables it. */
export function capabilityControlIsConfigurable(
  control: Pick<CapabilityControlPresentation, 'state'>,
): boolean {
  return control.state === 'auto_available' || control.state === 'unknown';
}

/**
 * The badge/filter verdict for model lists, resolved from the same function the
 * composer uses. `custom_only` deliberately does not earn a badge: the user
 * cannot turn it on without the developer switch.
 */
export function capabilityAvailableForDisplay(
  provider: Provider | undefined,
  model: AIModel | undefined,
  capability: CapabilityKey,
  resolvedModel?: ReturnType<typeof currentCapabilityEvidenceModel>,
): boolean {
  const state = presentCapabilityControl(provider, model, capability, resolvedModel).state;
  return state === 'auto_available' || state === 'managed_only';
}

/**
 * Available web search levels are taken from `availableIntents` only under an official
 * `auto_available` recipe; every other state yields an empty list, because a `force` level without
 * an official declaration should not appear. This is deliberately asymmetric with how reasoning is
 * read (reasoning uses the resolve result directly) and must not be "unified". It lives in this
 * module because v2 state words are only allowed inside the registered verdict surface; rendering
 * components must not carry bare checks of their own.
 */
export function resolveWebAvailableIntents(control: CapabilityControlPresentation): readonly string[] {
  return control.state === 'auto_available' ? control.availableIntents : [];
}
