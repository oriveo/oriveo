/**
 * Shared pure types for request builders.
 * RequestParams is the shape of a chat stream request after route validation, shared by core
 * and main.
 */

import type { ProviderKind, ReasoningMode } from '@oriveo/shared/pure-types';
import type { ProxyMessage, ProxyToolDefinition } from './runtime';
import type { ContinuationIntent } from '../request-preference/continuation';
import type { OwnerId } from '../request-preference/types';

/** Typed user intent; it is not a wire fragment, and recipes remain the sole compiler. */
export type CapabilityPreferenceInput = {
  web: 'off' | 'automatic' | 'force';
  reasoningIntent?: 'off' | 'low' | 'balanced' | 'deep' | 'max';
};

/** Exact, user-confirmed omission from a previously rejected official recipe. */
export type CapabilityRecipeOmission = {
  recipeRef: string;
  locatedPointers: string[];
};

export type GenerationParameterOverride<T> =
  | { state: 'inherit' }
  | { state: 'omit' }
  | { state: 'value'; value: T };

export type GenerationParameterKey =
  | 'max_output_tokens'
  | 'stop'
  | 'reasoning_effort'
  | 'reasoning_budget'
  | 'reasoning_mode'
  | 'temperature'
  | 'top_p'
  | 'top_k'
  | 'min_p'
  | 'frequency_penalty'
  | 'presence_penalty'
  | 'repeat_penalty'
  | 'seed'
  | 'response_format'
  | 'json_schema'
  | 'verbosity'
  | 'logprobs'
  | 'top_logprobs'
  | 'route_require_parameters'
  | 'typical_p'
  | 'mirostat'
  | 'mirostat_tau'
  | 'mirostat_eta'
  | 'dry_multiplier'
  | 'dry_base'
  | 'dry_allowed_length'
  | 'dry_penalty_last_n'
  | 'dry_sequence_breakers'
  | 'xtc_probability'
  | 'xtc_threshold'
  | 'repeat_last_n'
  | 'samplers'
  | 'ignore_eos';

export type GenerationParameterValue =
  | number
  | string
  | boolean
  | string[]
  | Record<string, unknown>;

export interface GenerationParameterOverrides {
  [key: string]: GenerationParameterOverride<GenerationParameterValue> | undefined;
  temperature?: GenerationParameterOverride<number>;
}

/** Bundled generation profile */
export interface GenerationParameterProfile {
  template: string;
  /** Opaque revision of the server profile's normalization semantics; absent in the legacy protocol. */
  revision?: string;
  parameters: Array<{
    id: string;
    support: string;
    source: string;
    group?: string;
    valueSchema?: string;
    range?: { min?: number; max?: number; minExclusive?: number; maxExclusive?: number; step?: number };
    enumValues?: Array<string | number>;
    fixedValue?: GenerationParameterValue;
    defaultDescription?: string | number;
    interactionGroup?: string;
    conflictsWith?: string[];
    requires?: Array<Record<string, unknown>>;
    constraints?: Array<Record<string, unknown>>;
    portability?: string;
    risk?: string;
  }>;
  wire: Record<string, string>;
}

/** Chat stream request parameters after route validation. */
export interface RequestParams {
  providerKind: ProviderKind;
  apiKey: string;
  modelID: string;
  messages: ProxyMessage[];
  baseURL?: string;
  /** Internal builder/testing mode. The public chat route remains streaming. */
  stream?: boolean;
  /** Opaque local-only state, supplied by the client continuation store after validation. */
  continuation?: ContinuationIntent;
  tools?: ProxyToolDefinition[];
  toolChoice?: 'auto' | 'none' | 'required';
  options?: {
    reasoning?: ReasoningMode;
    supportsImageGen?: boolean;
    supportsWebSearch?: boolean;
    /**
     * The `chatgpt-account-id` every Codex subscription request must carry.
     *
     * Parsed from the id_token and checked non-empty during authorization, then passed through
     * unchanged. Never re-derived downstream: the id_token is what carries the claim, and an
     * access token is not guaranteed to have it.
     */
    openAISubscriptionAccountID?: string;
    /**
     * Upstream declared web search for this model (Codex `/models` returns a non-empty
     * `web_search_tool_type`).
     *
     * Independent from `supportsWebSearch`, which is the user's intent this round; tools are
     * only assembled when both hold.
     */
    openAISubscriptionWebSearchDeclared?: boolean;
    /**
     * Reasoning levels upstream declares for this model (Codex `/models`
     * `supported_reasoning_levels`).
     *
     * Subscription models are absent from the metadata catalog and never have an official
     * recipe, so this declaration is the only legitimate authority for level admission on this
     * route. Empty means upstream declared nothing, so no effort is injected.
     */
    upstreamReasoningLevels?: readonly string[];
    upstreamDefaultReasoningLevel?: string;
    upstreamApiBackend?: string;
    grokSubscriptionWebSearchDeclared?: boolean;
    capabilityPreferences?: CapabilityPreferenceInput;
    /** Explicit resend: omit only the located operation(s), never the whole owner. */
    capabilityRecipeOmissions?: CapabilityRecipeOmission[];
    generationParameters?: GenerationParameterOverrides;
    generationProfile?: GenerationParameterProfile;
    /** A raw fragment stays request-local and is losslessly compiled before it can touch the wire.
     * Ownership is deliberately absent: it is derived from the active runtime recipe/profile,
     * never trusted from a caller-controlled payload. */
    customFragment?: { raw: string };
    /** Owner-scoped developer mode. Presence selects Custom for that
     * owner even when raw is empty, suppressing its recipe and typed fields. */
    customFragments?: Partial<Record<OwnerId, { raw: string }>>;
  };
}

export interface ProviderRequest {
  url: string;
  headers: Record<string, string>;
  body: Record<string, unknown>;
  fallback?: ProviderRequest;
  responseAdapter?:
    | 'openai_images_api'
    | 'minimax_images_api'
    | 'minimax_chat_stream'
    | 'qwen_images_api'
    | 'siliconflow_images_api'
    | 'moonshot_tool_loop'
    | 'moonshot_formula_fiber_loop'
    | 'gemini_interactions';
  moonshotMaxToolLoops?: number;
  /** Local response-state producer selected by the same authoritative recipe as the request.
   * Never serialized upstream; shells pass it to the protocol parser only. */
  continuationCapture?: {
    kind: string;
    protocol: string;
    responseParserKind: string;
  };
  /** Formula/Fiber is activated by the capabilityRuntime recipe only; tools enter the first leg after the official GET returns them. */
  moonshotFormula?: {
    uri: string;
    toolsPath: string;
    fibersPath: string;
    argumentsMode: 'verbatim';
    resultPaths: readonly string[];
  };
  /** Local facts for the request compiler; never put on the wire. */
  capabilityExecution?: {
    recipeRefs: string[];
    delta: Record<string, unknown>;
    redactedPreview: Record<string, unknown>;
    /** Owner-level wire facts; no result state may borrow another owner's delta. */
    wireAppliedOwners?: Partial<Record<'web' | 'reasoning' | 'generation', boolean>>;
    /** Custom never receives automatic evidence or recovery. */
    customOwners?: Array<'web' | 'reasoning' | 'generation'>;
    /** Exact leaf pointers emitted by each final custom compiler source. */
    customAppliedPointers?: Partial<Record<'web' | 'reasoning' | 'generation', string[]>>;
    /** Frozen same-envelope definitions selected at builder compile time; never serialized upstream. */
    resultEnvelope?: unknown;
  };
}

export const JSON_HEADERS = {
  'Content-Type': 'application/json',
  Accept: 'application/json',
} as const;

export const STREAM_HEADERS = {
  ...JSON_HEADERS,
  Accept: 'text/event-stream, application/json',
} as const;
