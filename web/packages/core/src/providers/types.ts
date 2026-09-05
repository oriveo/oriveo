import type {
  AIModel,
  Citation,
  ReasoningMode,
  RelayKeyValue,
  RelayWebSearchToolName,
} from '@oriveo/shared/pure-types';
import type { UsageBreakdown } from '../chat/usage-breakdown';
import type { CapabilityPreferenceInput, CapabilityRecipeOmission, GenerationParameterOverrides, GenerationParameterProfile } from './request-builders/types';
import type { CapabilityLearningIdentity } from './unsupported-param';
import type { ContinuationIntent } from './request-preference/continuation';
import type {
  ProviderErrorNextAction,
  ProviderErrorSeverity,
  ProviderErrorSource,
  ProviderQuotaSource,
} from './errors';

export interface StreamUsage {
  prompt_tokens?: number;
  completion_tokens?: number;
  total_tokens?: number;
  breakdown?: UsageBreakdown;
  /**
   * Normalised usage snapshot that can be stored directly on a single message. Managed billing
   * settles on this field, so its generic cache-write bucket is not disguised as an Anthropic
   * 5m/1h pricing field.
   */
  messageUsage?: {
    inputTokens: number;
    outputTokens: number;
    /**
     * Cache read/write are **optional**: the managed service always sends both keys (as 0 even for
     * upstreams without caching), so they only reflect what upstream actually reported when
     * `usage_source = upstream_reported`. Every other source must leave them absent - otherwise an
     * estimated 0 renders as "no cache hit this time".
     */
    cachedInputTokens?: number;
    cacheCreationInputTokens?: number;
  };
}

/** One streamed delta fragment of an OpenAI-compatible `tool_calls`. */
export interface StreamToolCallDelta {
  index: number;
  id?: string;
  type?: string;
  name?: string;
  arguments?: string;
}

export type ToolConfirmationReason = 'sensitive' | 'high_cost' | 'broad_read';

export type StreamEvent =
  | { type: 'delta'; content: string; managedSequence?: number }
  | { type: 'reasoning'; content: string; managedSequence?: number }
  | { type: 'image'; url: string }
  | { type: 'model'; modelID: string }
  | { type: 'usage'; usage: StreamUsage }
  | { type: 'done' }
  | { type: 'citations'; citations: Citation[] }
  | { type: 'tool_calls'; toolCalls: StreamToolCallDelta[] }
  | { type: 'tool_call'; tool: string; args: Record<string, unknown>; step: number }
  | { type: 'tool_result'; tool: string; summary: string; step: number }
  /** Recipe-required opaque replay state. Local-only; never persisted to conversation/sync/telemetry. */
  | { type: 'continuation'; continuation: ContinuationIntent }
  | { type: 'confirm_required'; reason: ToolConfirmationReason; detail: Record<string, unknown> }
  | {
      type: 'error';
      error: string;
      errorDetail?: string;
      errorKind?: string;
      i18nKey?: 'moderation' | 'imageGenUser';
      nextAction?: ProviderErrorNextAction;
      retryable?: boolean;
      source?: ProviderErrorSource;
      severity?: ProviderErrorSeverity;
      status?: number;
      upstreamURL?: string;
      quotaSource?: ProviderQuotaSource;
      managedErrorCode?: string;
      managedErrorAction?: string;
      managedErrorReasonCode?: string;
      managedErrorRiskRef?: string;
      /** Remaining wait in seconds as reported by the managed service; converted to an absolute unblock timestamp before it is stored. */
      managedErrorRetryAfterSeconds?: number;
      traceId?: string;
    };

export interface StreamHandle {
  stream: ReadableStream<StreamEvent>;
  abort: () => void;
  /** Local-only proxy execution context; never forwarded to an upstream provider. */
  getCapabilityResultContext?: () => unknown;
  /** Resolves when the proxy has received final response headers (also null when the header is absent). */
  capabilityResultContextReady?: Promise<unknown>;
  /** Local-only: exact custom + pre-token upstream 400; no response text is retained. */
  getCapabilityCustomRetryEligible?: () => boolean;
  /** Local-only deterministic rejection descriptor; never parsed from prose. */
  getCapabilityRecoveryDescriptor?: () => unknown;
  /** Local-only structured HTTP rejection; never persisted or emitted as a stream event. */
  getToolCallRejectionContext?: () => unknown;
}

export interface SyncResult {
  models: AIModel[];
  recommended: AIModel[];
}

export type ContentPart =
  | { type: 'text'; text: string }
  | {
      type: 'image_url';
      image_url: {
        url: string;
        /**
         * OpenAI vision detail level ('auto' / 'low' / 'high'), defaulting to 'auto' so the default
         * is explicit and a UI toggle can be added later.
         * Only the openai_chat / openai_responses transports consume it; others ignore the field.
         */
        detail?: 'auto' | 'low' | 'high';
      };
    }
  | { type: 'video_url'; video_url: { url: string } }
  | {
      type: 'file';
      file: {
        filename: string;
        /**
         * data URI, filled when route=native: data:<mime>;base64,<raw>.
         * route=client_extract builds no file part at all (it goes through text + AttachmentInjector).
         */
        file_data: string;
        mimeType?: string;
        // Extraction metadata used by AttachmentInjector to build the block header.
        extractedTotalLines?: number;
        extractedTruncated?: boolean;
        extractedSizeBytes?: number;
        // Why the native route was taken (scanned_pdf fallback / Office native / Gemini PDF default).
        extractionErrorCode?: string;
      };
    };

export interface StreamOptions {
  reasoning?: ReasoningMode;
  /**
   * This request uses Grok subscription (OAuth) credentials instead of an API key.
   *
   * **Local-only field**: the proxy layer uses it to stamp `authMode` on its own route and to route
   * error classification through subscription semantics - the same 403 means "your xAI subscription
   * tier does not allow third-party apps" here and "invalid key" in key mode, and collapsing the two
   * into one message sends the user down the wrong recovery path.
   */
  grokSubscriptionAuth?: boolean;
  /**
   * This request uses Codex (ChatGPT subscription sign-in) credentials instead of an API key.
   *
   * **Local-only field**, structurally the same as `grokSubscriptionAuth` but not mergeable with it:
   * the two chains differ in endpoints, hard body constraints and failure copy, and a single boolean
   * would leave the route unable to tell which chain to switch to.
   */
  openAISubscriptionAuth?: boolean;
  /**
   * The `chatgpt-account-id` Codex requires on every outbound request.
   *
   * It is extracted from the id_token at authorization time and checked to be non-empty, then passed
   * through verbatim; it is never re-derived from the access token, since the id_token is what
   * actually carries that claim.
   */
  openAISubscriptionAccountID?: string;
  /**
   * Upstream declares web search support for this model (a non-empty `web_search_tool_type` in the
   * Codex `/models` response).
   *
   * This and `supportsWebSearch` (what the user asked for on this turn) are **two independent facts**;
   * `tools` is only assembled when both hold. Collapsing them into one boolean would make "the user
   * left it off" indistinguishable from "upstream does not support it", which are two very different
   * things to tell a user.
   */
  openAISubscriptionWebSearchDeclared?: boolean;
  /**
   * Reasoning levels upstream declares for this model (`supported_reasoning_levels` in the Codex
   * `/models` response).
   *
   * Subscription models are absent from the metadata catalog and never get an official recipe, so this
   * declaration is the only legitimate authority for level admission on this chain. Empty means
   * upstream declared nothing, so no effort is injected at all.
   */
  upstreamReasoningLevels?: readonly string[];
  upstreamDefaultReasoningLevel?: string;
  upstreamApiBackend?: string;
  grokSubscriptionWebSearchDeclared?: boolean;
  /** Local-only opaque continuation sent solely to Oriveo's proxy for an explicit user continue/retry. */
  continuation?: ContinuationIntent;
  supportsImageGen?: boolean;
  /**
   * Relay web search switch, decided from model capability + transport envelope + user intent in
   * `stream-options.ts`. The adapter layer only consumes the boolean and no longer decides for itself.
   */
  supportsWebSearch?: boolean;
  /** Typed intent consumed by the recipe compiler. */
  capabilityPreferences?: CapabilityPreferenceInput;
  /** Explicit resend descriptors consumed only by the official recipe compiler. */
  capabilityRecipeOmissions?: CapabilityRecipeOmission[];
  /** Local explicit-resend latch: lets the located owner leave dormant for this one request. */
  capabilityRecipeResendOwners?: Array<'web' | 'reasoning' | 'generation'>;
  /** Model default saved on this device, or the per-conversation override. When unset, no extra field is sent. */
  generationParameters?: GenerationParameterOverrides;
  /** Local-only developer fragment. It is compiled at the production request boundary. */
  customFragment?: { raw: string };
  /** Owner-scoped local-only custom fields. Presence selects Custom even when the draft is empty. */
  customFragments?: Partial<Record<'web' | 'reasoning' | 'generation', { raw: string }>>;
  /** Profile the caller already expanded from this model's metadata. A direct Relay connection must not guess it from a same-named model. */
  generationProfile?: GenerationParameterProfile;
  /**
   * Connection-level capability identity, the write gate for the parameter-rejection self-healing
   * negative cache. core can read neither localStorage nor the metadata ETag, so it only accepts a
   * plain value object injected by the caller; absent means fail-closed (each request still retries
   * on its own, but no cross-request cache is established).
   */
  capabilityIdentity?: CapabilityLearningIdentity;
  /** Local-only identity for the dormant rejection cache; stripped before proxy/upstream serialization. */
  capabilityRecoveryIdentity?: {
    connectionId: string;
    canonicalModelId: string;
    finalTransport: string;
    runtimeRevision: string;
  };
  relayResolvedBaseURLText?: string;
  relayResolvedAPIBaseURLIsExact?: boolean;
  relayTransport?:
    | 'openai_responses'
    | 'openai_chat_completions'
    | 'anthropic_messages'
    | 'gemini_generate_content'
    | 'llamacpp_native';
  /** Engine explicitly declared by Relay; used to pick the matching engine generation template. */
  relayEngineProfile?: 'llamacpp' | 'ollama' | 'lmstudio' | 'vllm' | 'openwebui';
  relayAuthMode?:
    | 'none'
    | 'bearer'
    | 'x_api_key'
    | 'x_goog_api_key'
    | 'query_key';
  relaySecurityMode?: 'remote_https' | 'local_http' | 'private_vpn' | 'tofu_https';
  /** Production-builder probe limit; undefined omits the field, 0 remains explicit if a caller supplies it. */
  relayMaxOutputTokens?: number;
  relayHeaderProfile?: 'none' | 'anthropic_v2023_06_01' | 'gemini_key';
  relayFamilyHint?: 'openai' | 'anthropic' | 'gemini' | 'unknown';
  /**
   * Free-form `service_tier` entered in advanced mode.
   * Only forwarded upstream on OpenAI-family relay transports (Responses / Chat Completions); other
   * transports ignore it silently.
   */
  relayServiceTier?: string;
  /**
   * Raw `reasoning_effort` entered in advanced mode, including extension values such as `xhigh`.
   * Takes precedence over the `reasoning` mapping and is forwarded upstream verbatim.
   */
  relayReasoningEffort?: 'low' | 'medium' | 'high' | 'xhigh';
  /** Relay advanced-mode stream switch; defaults to true, and an explicit false must take the non-streaming runtime. */
  relayStream?: boolean;
  /** `disable_response_storage` enabled in advanced mode; forwarded on the Responses transport only. */
  relayDisableResponseStorage?: boolean;
  /** Relay Codex compatibility identity switch; when false, Codex UA / Originator / session_id / OpenAI-Beta are explicitly not injected. */
  relayCodexCompatIdentity?: boolean;
  /** Custom Relay User-Agent; only written upstream by the Node proxy or a non-browser direct connection. */
  relayCustomUserAgent?: string;
  /** Custom Relay headers, applied last and overriding system-generated headers. */
  relayHeaders?: RelayKeyValue[];
  /** Custom Relay query parameters, applied last and overriding system-generated query. */
  relayQueryParams?: RelayKeyValue[];
  /** `tool.model` image tool model (e.g. `gpt-image-2`). Only takes effect with Responses + image_generation. */
  relayImageToolModelID?: string;
  /* -- `/images/generations` request parameters (imagesEndpoint route) --
   * All come from the same-named fields on provider.relayRequested; when absent the parameter is not
   * sent and upstream picks its own default.
   */
  /** 1024x1024 / 1024x1536 / 1536x1024 / auto and so on; the accepted values depend on the upstream model. */
  relayImageSize?: string;
  /** gpt-image: low / medium / high / auto; dall-e-3: standard / hd */
  relayImageQuality?: string;
  /** dall-e-3 only: vivid / natural */
  relayImageStyle?: string;
  /** How many images to generate. */
  relayImageCount?: number;
  /** b64_json / url. gpt-image-* does not accept this parameter, and buildImagesGenerationsBody skips it automatically. */
  relayImageResponseFormat?: string;
  /**
   * The **main model ID** actually sent upstream for inline image generation on Responses (chat-driven).
   *
   * When the user picks a dedicated image model such as `gpt-image-*`, it cannot go in body.model
   * because it is not a chat model; `pickChatDriverModelID` swaps in a chat model and the original
   * model moves down into `relayImageToolModelID`.
   * undefined means keep the model.id the caller passed in.
   */
  relayDriverModelID?: string;
  /**
   * Protocol name of the web search tool on the Codex / openai_responses transport.
   * undefined lets the adapter fall back to 'web_search', which matches relays that track the
   * protocol closely. Older relays that only accept web_search_preview are switched to
   * 'web_search_preview' by hand in custom expert mode.
   * 'disabled' means the tool is never assembled, even when web search is on in the chat UI.
   */
  relayWebSearchToolName?: RelayWebSearchToolName;
}
