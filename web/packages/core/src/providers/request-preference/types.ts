/**
 * Shared vocabulary for request_preference_contract.v2 and request_shape_contract.v2.
 *
 * These types are a verbatim transcription of the `vocabulary`, `wireNaming` and
 * `controlStates` sections of those two contracts, not shapes invented in this module.
 * Both contracts require the vocabulary to stay byte-identical, so it is maintained once
 * here and shared by `request-preference` and `capability-runtime`.
 */

/** The three request preference owners: web, reasoning and generation. They are also the keys of capabilityControls. */
export type OwnerId = 'web' | 'reasoning' | 'generation';

export const OWNER_IDS: readonly OwnerId[] = ['web', 'reasoning', 'generation'];

/** The three states of a single-scope override: inherit falls through, while omit and value both stop the lookup (value includes the number 0). */
export type OverrideState = 'inherit' | 'value' | 'omit';

/** Owner-level feature selection mode: follow the official server recipe, or use a custom one. */
export type ValueMode = 'preset' | 'custom';

/** Availability of a capability for the current provider and model. Same source as the controlStates section of the shape contract. */
export type ControlAvailability = 'auto_available' | 'managed_only' | 'custom_only' | 'unavailable' | 'unknown';

/** Access identity behind a connection: managed, BYOK developer, or relay developer. */
export type ConnectionAccess = 'managed' | 'byok_developer' | 'relay_developer';

/** Execution form a recipe takes when applied. plugin was folded into the request_overlay target root and is not a separate kind. */
export type ExecutionKind =
  | 'request_overlay'
  | 'server_tool'
  | 'client_tool_loop'
  | 'endpoint_route'
  | 'model_route'
  | 'external_connector'
  | 'unavailable';

/** Open set of continuation states. fiber was folded into a tool_loop variant and is not a separate kind. */
export type ContinuationKind = 'none' | 'previous_id' | 'replay_blocks' | 'replay_reasoning' | 'tool_loop';

/** Final state once request-construction facts (requested) and response-execution facts (observed) are kept apart. */
export type ResultState = 'not_requested' | 'requested' | 'observed' | 'unconfirmed' | 'rejected' | 'recovered';

/** Kinds of evidence that prove a feature really took effect in the response. */
export type ObservationEvidenceKind =
  | 'provider_tool_result'
  | 'citation'
  | 'grounding'
  | 'thinking_block'
  | 'reasoning_usage';

/**
 * The seven scope levels, highest priority first. This is the only scope priority list in
 * the v2 contract, and it is not the same as the five-level v1 resolver still used by
 * apps/app/lib/core/chat/generation-parameter-settings.ts; see the note at the top of
 * resolver.ts.
 */
export type ScopeId =
  | 'single_send'
  | 'conversation_connection_model'
  | 'skill_agent'
  | 'connection_model'
  | 'connection'
  | 'provider_recipe'
  | 'provider_default';

export const SCOPE_PRIORITY: readonly ScopeId[] = [
  'single_send',
  'conversation_connection_model',
  'skill_agent',
  'connection_model',
  'connection',
  'provider_recipe',
  'provider_default',
];

/** The three capabilityControls keys, the same set as OwnerId (wireNaming.capabilityControlKeys). */
export type CapabilityKey = OwnerId;

export const CAPABILITY_KEYS: readonly CapabilityKey[] = OWNER_IDS;

/** request_shape_contract.v2 providerKindUniverse */
export type ProviderKind =
  | 'openRouter'
  | 'openAI'
  | 'anthropic'
  | 'gemini'
  | 'groq'
  | 'deepseek'
  | 'siliconFlow'
  | 'togetherAI'
  | 'fireworksAI'
  | 'miniMax'
  | 'zhipu'
  | 'qwen'
  | 'grok'
  | 'moonshot'
  | 'mistral'
  | 'relay';

/** Reasoning effort ladder as a product concept. The available steps are a subset of the recipe's and are never padded out; see capability-runtime.ts. */
export const REASONING_INTENTS = ['off', 'low', 'balanced', 'deep', 'max'] as const;
export type ReasoningIntent = (typeof REASONING_INTENTS)[number];
