/**
 * Client-relevant sections of request_shape_contract.v2: wireNaming, stateRequirements,
 * reasoningIntents and failSafe.
 *
 * Only the three things the clients really read are consumed here:
 * - validateEnvelope: whether the capabilityRuntime envelope sent by the server is valid at all.
 *   An invalid one is ignored as a whole, never half-applied, and chat continues
 *   (failSafe.chatAlwaysContinues).
 * - resolveControl(s): a single provider's capabilityControls (web, reasoning, generation)
 *   degrade independently per key. A dangling recipeRef, a cross-revision cache window or an
 *   unknown state all degrade to "no automatic configuration" rather than to an error.
 * - validateIntents: the selectable reasoning levels must be an ordered subset of off, low,
 *   balanced, deep and max. A sparse subset is shown as-is, and intermediate levels the provider
 *   does not offer are never filled in.
 *
 * Relay uses a fixed verdict because a user-owned directory has no catalog source to cite.
 */

import { CAPABILITY_KEYS, REASONING_INTENTS, type CapabilityKey, type ControlAvailability, type ProviderKind, type ReasoningIntent } from './types';

const RUNTIME_ENVELOPE_KEY = 'capabilityRuntime';
const RUNTIME_SCHEMA_VERSION = 2;
const RUNTIME_ENVELOPE_FIELDS = ['schemaVersion', 'revision', 'generatedAt', 'recipes', 'controlDefinitions', 'sourceIndex'] as const;

export interface EnvelopeValidationResult {
  applied: boolean;
  action: 'apply_runtime' | 'ignore_runtime';
  reason: string | null;
  chatContinues: true;
}

/** payload is the top-level object of the metadata snapshot; unknown fields are always ignored (see failSafe.unknownEnvelopeField). */
export function validateEnvelope(payload: Readonly<Record<string, unknown>> | null | undefined): EnvelopeValidationResult {
  const fail = (reason: string): EnvelopeValidationResult => ({
    applied: false, action: 'ignore_runtime', reason, chatContinues: true,
  });
  if (payload == null || !Object.hasOwn(payload, RUNTIME_ENVELOPE_KEY)) {
    return fail('missing_runtime_envelope');
  }
  const envelope = payload[RUNTIME_ENVELOPE_KEY] as Readonly<Record<string, unknown>> | null | undefined;
  if (envelope == null || envelope.schemaVersion !== RUNTIME_SCHEMA_VERSION) return fail('unknown_schema_version');
  for (const field of RUNTIME_ENVELOPE_FIELDS) {
    if (!Object.hasOwn(envelope, field)) return fail('missing_envelope_field');
  }
  // Fields added within the same schemaVersion are forward compatible: ignore them rather than discarding the whole payload.
  return { applied: true, action: 'apply_runtime', reason: null, chatContinues: true };
}

interface FixedVerdict {
  providerKind: ProviderKind;
  state: ControlAvailability;
  reasonCode: string;
  autoRecipeAllowed: boolean;
}

/** relay payload uses a fixed verdict */
const FIXED_VERDICTS: readonly FixedVerdict[] = [
  { providerKind: 'relay', state: 'custom_only', reasonCode: 'relay_user_directory', autoRecipeAllowed: false },
];

interface SourceRefExemption {
  providerKind: ProviderKind;
  state: ControlAvailability;
  reasonCode: string;
}

/** One per fixed verdict above: these (provider, state, reasonCode) combinations are exempt from sourceRefs validation. */
const SOURCE_REF_EXEMPTIONS: readonly SourceRefExemption[] = [
  { providerKind: 'relay', state: 'custom_only', reasonCode: 'relay_user_directory' },
];

const CONTROL_STATES = new Set<ControlAvailability>(['auto_available', 'managed_only', 'custom_only', 'unavailable', 'unknown']);
const NON_AUTO_MIN_SOURCE_REFS = 1;
const FORBIDDEN_CUSTOM_ROOTS = new Set(['auth', 'headers', 'query', 'endpoint', 'base_url', 'transport_route', 'model_route', 'continuation_state', 'model', 'messages', 'input', 'contents', 'prompt', 'attachments', 'instructions', 'system', 'stream', 'stream_options', 'tools', 'tool_choice', 'plugins']);
const FORBIDDEN_CUSTOM_SEGMENTS = new Set(['__proto__', 'prototype', 'constructor']);

export interface CapabilityControl {
  state: string;
  recipeRef?: string | null;
  reasonCode?: string;
  sourceRefs?: readonly string[];
  availableIntents?: readonly string[];
  customControlRefs?: readonly string[];
}

/**
 * Closed enum from request_shape_contract.v2 controlDefinitions.riskTiers. The server sends it as
 * a required field, and the client uses it to show a cost or privacy notice on the control itself.
 */
export const CAPABILITY_RISK_TIERS = ['standard', 'cost_impacting', 'privacy_impacting'] as const;
export type CapabilityRiskTier = typeof CAPABILITY_RISK_TIERS[number];

export interface CapabilityControlDefinition {
  id: string;
  owner: string;
  targetPointer: string;
  sourceRefs: readonly string[];
  /** undefined when unknown or missing: no notice is shown, and the control is never dropped because of it (failSafe.unknownEnvelopeField). */
  riskTier?: CapabilityRiskTier;
}

/**
 * Risk tiers this control must warn about in advance. Only the privacy and cost tiers produce a
 * notice; `standard` and any unknown value stay silent, because the client must not invent a
 * notice the server never sent. Privacy is listed before cost.
 */
export function customControlRiskTiers(
  definitions: readonly CapabilityControlDefinition[],
): CapabilityRiskTier[] {
  const present = new Set(definitions.map((definition) => definition.riskTier));
  return (['privacy_impacting', 'cost_impacting'] as const).filter((tier) => present.has(tier));
}

export interface ControlResolutionContext {
  /** The recipe ids actually registered for this provider in the current capabilityRuntime snapshot. */
  recipes: readonly string[];
  /** capabilityRuntime.sourceIndex: any sourceRefs other than auto_available must resolve in here. */
  sourceIndex: Readonly<Record<string, unknown>>;
  controlDefinitions: Readonly<Record<string, unknown>>;
}

export type ControlResolutionReason =
  | 'unknown_state'
  | 'fixed_verdict_violation'
  | 'missing_recipe_ref'
  | 'dangling_recipe_ref'
  | 'unexpected_recipe_ref'
  | 'missing_reason_code'
  | 'missing_source_refs'
  | 'unresolved_source_ref'
  | 'invalid_available_intent'
  | 'duplicate_available_intent'
  | 'unordered_available_intents'
  | 'intents_not_applicable'
  | 'invalid_custom_control_refs'
  | 'unresolved_custom_control_ref'
  | 'custom_control_owner_mismatch'
  | 'managed_custom_control_forbidden'
  | null;

export interface ControlResolutionResult {
  valid: boolean;
  state: string;
  action: 'apply_recipe' | 'no_auto_config';
  reason: ControlResolutionReason;
}

/** Degradation verdict for one capability (web, reasoning, generation) under one provider. */
export function resolveControl(
  providerKind: ProviderKind,
  capability: CapabilityKey,
  control: CapabilityControl,
  ctx: ControlResolutionContext,
): ControlResolutionResult {
  const noAuto = (valid: boolean, state: string, reason: ControlResolutionReason): ControlResolutionResult => ({
    valid, state, action: 'no_auto_config', reason,
  });

  if (!CONTROL_STATES.has(control.state as ControlAvailability)) {
    return noAuto(true, 'unknown', 'unknown_state');
  }

  const verdict = FIXED_VERDICTS.find((entry) => entry.providerKind === providerKind);
  if (verdict != null && !verdict.autoRecipeAllowed && control.state === 'auto_available') {
    return noAuto(false, verdict.state, 'fixed_verdict_violation');
  }

  if (control.availableIntents != null) {
    const intents = validateIntents(capability, control.availableIntents);
    if (!intents.valid) return noAuto(false, control.state, intents.reason);
  }
  const customRefs = control.customControlRefs ?? [];
  if (!Array.isArray(customRefs) || new Set(customRefs).size !== customRefs.length) {
    return noAuto(false, control.state, 'invalid_custom_control_refs');
  }
  if (control.state === 'managed_only' && customRefs.length > 0) {
    return noAuto(false, control.state, 'managed_custom_control_forbidden');
  }
  for (const ref of customRefs) {
    const definition = parseControlDefinition(ctx.controlDefinitions[ref]);
    if (!definition) return noAuto(false, control.state, 'unresolved_custom_control_ref');
    if (definition.owner !== capability) return noAuto(false, control.state, 'custom_control_owner_mismatch');
    if (definition.sourceRefs.some((sourceRef) => !Object.hasOwn(ctx.sourceIndex, sourceRef))) {
      return noAuto(false, control.state, 'unresolved_custom_control_ref');
    }
  }

  if (control.state === 'auto_available') {
    if (control.recipeRef == null) return noAuto(false, 'unknown', 'missing_recipe_ref');
    if (!ctx.recipes.includes(control.recipeRef)) {
      // The client caches metadata for at most 24h, so a local snapshot that cannot reach the recipeRef is a normal window: degrade the whole entry, never half-apply.
      return noAuto(true, 'unknown', 'dangling_recipe_ref');
    }
    return { valid: true, state: 'auto_available', action: 'apply_recipe', reason: null };
  }

  if (control.recipeRef != null) {
    return noAuto(false, control.state, 'unexpected_recipe_ref');
  }
  if (typeof control.reasonCode !== 'string' || control.reasonCode.length === 0) {
    return noAuto(false, control.state, 'missing_reason_code');
  }

  const exempt = SOURCE_REF_EXEMPTIONS.some((entry) => entry.providerKind === providerKind
    && entry.state === control.state
    && entry.reasonCode === control.reasonCode);
  if (!exempt) {
    const refs = control.sourceRefs ?? [];
    if (refs.length < NON_AUTO_MIN_SOURCE_REFS) return noAuto(false, control.state, 'missing_source_refs');
    if (refs.some((key) => !Object.hasOwn(ctx.sourceIndex, key))) {
      return noAuto(false, control.state, 'unresolved_source_ref');
    }
  }
  return noAuto(true, control.state, null);
}

export function resolveCustomControlDefinitions(
  capability: CapabilityKey,
  control: CapabilityControl | undefined,
  controlDefinitions: Readonly<Record<string, unknown>>,
  sourceIndex: Readonly<Record<string, unknown>>,
): CapabilityControlDefinition[] {
  if (!control || control.state === 'managed_only') return [];
  const refs = control.customControlRefs ?? [];
  if (!Array.isArray(refs) || new Set(refs).size !== refs.length) return [];
  const definitions: CapabilityControlDefinition[] = [];
  for (const ref of refs) {
    const definition = parseControlDefinition(controlDefinitions[ref]);
    if (!definition || definition.id !== ref || definition.owner !== capability
      || !safeCustomTargetPointer(definition.targetPointer)
      || definition.sourceRefs.length === 0
      || definition.sourceRefs.some((sourceRef) => !Object.hasOwn(sourceIndex, sourceRef))) return [];
    definitions.push(definition);
  }
  return definitions;
}

function safeCustomTargetPointer(pointer: string): boolean {
  if (!pointer.startsWith('/') || pointer === '/') return false;
  const segments = pointer.slice(1).split('/').map((segment) => segment.replaceAll('~1', '/').replaceAll('~0', '~'));
  return !FORBIDDEN_CUSTOM_ROOTS.has(segments[0] ?? '')
    && segments.every((segment) => segment.length > 0 && !FORBIDDEN_CUSTOM_SEGMENTS.has(segment));
}

function parseControlDefinition(value: unknown): CapabilityControlDefinition | null {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return null;
  const definition = value as Record<string, unknown>;
  if (typeof definition.id !== 'string' || typeof definition.owner !== 'string'
    || typeof definition.targetPointer !== 'string' || !Array.isArray(definition.sourceRefs)
    || definition.sourceRefs.some((ref) => typeof ref !== 'string')) return null;
  // riskTier follows the forward-compatibility rule within one schemaVersion: a newly added
  // unknown tier only means "no notice for this one" and must not cause the whole control to be
  // dropped, which would take custom capabilities down with it.
  return {
    ...(definition as unknown as CapabilityControlDefinition),
    riskTier: CAPABILITY_RISK_TIERS.includes(definition.riskTier as CapabilityRiskTier)
      ? definition.riskTier as CapabilityRiskTier
      : undefined,
  };
}

export interface ControlsResolutionResult {
  unknownCapabilities: string[];
  results: Partial<Record<CapabilityKey, ControlResolutionResult>>;
}

/** Resolve capabilityControls as a whole: unknown capability keys are collected separately and ignored rather than blocking the remaining keys. */
export function resolveControls(
  providerKind: ProviderKind,
  capabilityControls: Readonly<Record<string, CapabilityControl>>,
  ctx: ControlResolutionContext,
): ControlsResolutionResult {
  const results: Partial<Record<CapabilityKey, ControlResolutionResult>> = {};
  const unknownCapabilities: string[] = [];
  for (const [capability, control] of Object.entries(capabilityControls)) {
    if (!CAPABILITY_KEYS.includes(capability as CapabilityKey)) {
      unknownCapabilities.push(capability);
      continue;
    }
    results[capability as CapabilityKey] = resolveControl(providerKind, capability as CapabilityKey, control, ctx);
  }
  return { unknownCapabilities, results };
}

const INTENT_ORDER = new Map(REASONING_INTENTS.map((value, index) => [value, index]));

export type IntentRejectReason =
  | 'intents_not_applicable'
  | 'invalid_available_intent'
  | 'duplicate_available_intent'
  | 'unordered_available_intents';

export interface IntentValidationResult {
  valid: boolean;
  reason: IntentRejectReason | null;
  intents: readonly string[];
}

/** Reasoning uses an ordered sparse ladder; Web only exposes the exact optional force intent. */
export function validateIntents(capability: CapabilityKey, intents: readonly string[]): IntentValidationResult {
  const fail = (reason: IntentRejectReason): IntentValidationResult => ({ valid: false, reason, intents });
  if (capability === 'web') return intents.length === 1 && intents[0] === 'force'
    ? { valid: true, reason: null, intents }
    : fail('invalid_available_intent');
  if (capability !== 'reasoning') return fail('intents_not_applicable');
  if (intents.some((value) => !INTENT_ORDER.has(value as ReasoningIntent))) return fail('invalid_available_intent');
  if (new Set(intents).size !== intents.length) return fail('duplicate_available_intent');
  const positions = intents.map((value) => INTENT_ORDER.get(value as ReasoningIntent) as number);
  if (positions.some((value, index) => index > 0 && value <= positions[index - 1])) {
    return fail('unordered_available_intents');
  }
  return { valid: true, reason: null, intents };
}
