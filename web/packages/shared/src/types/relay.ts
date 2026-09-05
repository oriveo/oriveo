/**
 * Relay configuration contract.
 *
 * `relayResolved*` holds runtime probe results (see models.ts).
 * `relayRequested` holds the fields the user asks for.
 */

export type RelayTransport =
  | 'auto'
  | 'openai_responses'
  | 'openai_chat_completions'
  | 'anthropic_messages'
  | 'gemini_generate_content'
  /** llama.cpp native server `/completion`; used only when engineProfile=llamacpp is explicit. */
  | 'llamacpp_native';

export type RelayAuthMode =
  | 'auto'
  | 'none'
  | 'bearer'
  | 'x_api_key'
  | 'x_goog_api_key'
  | 'query_key';

export type RelayReasoningEffort =
  | 'automatic'
  | 'low'
  | 'medium'
  | 'high'
  | 'xhigh';

export type RelayKind =
  | 'openai_compatible'
  | 'codex_style'
  | 'anthropic_compatible'
  | 'gemini_compatible'
  | 'custom';

export type RelayImageMode = 'same_model' | 'tool_model';

export type RelayImageOutputFormat = 'png' | 'jpeg';

/**
 * Protocol name of the web search tool under the Codex / openai_responses transport.
 * - `web_search` (recommended): follows the OpenAI recommendation and the Codex relays that track
 *   the protocol closely (packy and ylsagi are the common ones)
 * - `web_search_preview` (legacy): still supported by OpenAI, used by older relays and passthrough
 *   stacks such as oneapi/cc-switch
 * - `disabled`: never attach the web_search tool, even when web search is on in the chat UI
 *
 * With no value set the adapter falls back to 'web_search'. Exposed only in custom expert mode.
 */
export type RelayWebSearchToolName = 'web_search' | 'web_search_preview' | 'disabled';

export interface RelayKeyValue {
  key: string;
  value: string;
}

/** Fields the user requests (user-editable or already recognized). HTTP requests are built from these. */
export interface RelayRequestedConfig {
  transport: RelayTransport;
  authMode: RelayAuthMode;
  /** Missing values intentionally preserve the historical remote HTTPS boundary. */
  securityMode?: import('../relay/endpoint-policy').RelayConnectionSecurityMode;
  /** Exact API root confirmed by Quick Setup; the runtime must not guess a version on top of it. */
  resolvedAPIBaseURL?: string;
  /** Explicit local engine profile. Absent for every existing/cloud Relay. */
  engineProfile?: 'llamacpp' | 'ollama' | 'lmstudio' | 'vllm' | 'openwebui';
  /** SHA-256 leaf certificate pin for explicit TOFU HTTPS mode. */
  certificateFingerprint?: string;
  modelID?: string;
  reasoningEffort?: RelayReasoningEffort;
  /** Free-form string, passed upstream only on OpenAI-style transports; other transports ignore it silently but keep the field */
  serviceTier?: string;
  stream?: boolean;
  disableResponseStorage?: boolean;
  headers?: RelayKeyValue[];
  queryParams?: RelayKeyValue[];
  codexCompatIdentity?: boolean;
  customUserAgent?: string;
  /**
   * Protocol name of the web search tool under the Codex / openai_responses transport. Editable
   * only in custom expert mode. With no value set the adapter falls back to 'web_search', which
   * covers packy and ylsagi; older relays can be switched back to 'web_search_preview' by hand.
   */
  webSearchToolName?: RelayWebSearchToolName;
  // Image generation parameters, exposed in the UI only when the default model has the imageGen
  // capability; at runtime the modelID decides whether they are spliced into the body on the
  // OpenAI Images or compatible path.
  /** dall-e-3: 1024x1024 / 1792x1024 / 1024x1792; gpt-image-1: 1024x1024 / 1024x1536 / 1536x1024 / auto */
  imageSize?: string;
  /** dall-e-3: standard / hd; gpt-image-1: low / medium / high / auto */
  imageQuality?: string;
  /** dall-e-3 only: vivid / natural */
  imageStyle?: string;
  /** How many images to generate; dall-e-3=1, dall-e-2/gpt-image=1-10 */
  imageCount?: number;
  /** b64_json / url; not sent for gpt-image-1, which defaults to b64_json */
  imageResponseFormat?: string;
  /**
   * Relay web search capability declaration.
   * - hasWebSearch=true exposes the web search switch in the UI for relay models
   * - webSearchProfile names the backend profile (for example oai_responses_web or ant_web_tool)
   * - transportKind names the protocol routing kind (distinct from the `transport` field:
   *   transport is the RelayTransport runtime enum, transportKind is the strategy kind)
   */
  hasWebSearch?: boolean;
  webSearchProfile?: string;
  transportKind?: string;
}

/** Explicit image capability switch. The protocol parsing path is decided internally and is not a user field. */
export interface RelayImageConfig {
  enabled: boolean;
  mode: RelayImageMode;
  /** Only takes effect when mode = 'tool_model' */
  toolModelID?: string;
  outputFormat?: RelayImageOutputFormat;
}
