import type {
  ProviderKind,
  ProviderConnectionState,
  ModelCapability,
  ChatRole,
  ChatMessageState,
  ProviderErrorSource,
  AttachmentKind,
  LoginMethod,
  ThemeOption,
  LanguageOption,
  SendShortcut,
} from './enums';
import type {
  RelayKind,
  RelayRequestedConfig,
  RelayImageConfig,
} from './relay';

/* ── Model ────────────────────────────────────────────── */

/**
 * Per-model override for the attachment extraction thresholds.
 * Unset fields fall back to the client defaults: 500 lines, 100KB per file, 100KB total.
 */
export interface AttachmentExtractionLimits {
  maxLines?: number;
  maxBytes?: number;
  totalCap?: number;
  maxInputFileBytes?: number;
  /** Managed: max raw attachment bytes for a whole request including history. Unused by BYOK. */
  maxRequestAttachmentBytes?: number;
  /** Managed: server-issued max attachment count per message. Unused by BYOK. */
  maxAttachments?: number;
}

/**
 * Strictly decoded form of the server metadata public capability evidence view.
 *
 * This is not the raw wire payload: provenance such as `sourceRef`, `artifactHash`,
 * decision notes and endpoints never reaches this type. Callers must still resolve
 * against the current connection query before using the facade.
 */
export interface CapabilityEvidenceCandidateView {
  key: string;
  support: 'supported' | 'unsupported' | 'unknown';
  source: 'server_typed' | 'server_profile' | 'operator_override';
  grade: 'machine_verified' | 'effect_verified' | 'declared' | 'operator';
  scope: 'provider_model_transport';
  providerKind: string;
  modelId: string;
  transport: string;
  /** Comes only from the HTTP ETag; never fabricated from the metadata snapshot version. */
  metadataRevision?: string;
  generationRevision?: string;
  /** Opaque revision of the public evidence view; not interchangeable with the metadata ETag. */
  evidenceRevision?: string;
  observedAt?: number;
  expiresAt?: number;
}

export interface AIModel {
  id: string;
  canonicalModelId?: string;
  name: string;
  /**
   * Free-form capability string rather than a constrained union; unknown values are
   * ignored so new capabilities stay forward compatible. Example value: 'native_pdf'.
   */
  capabilities: string[];
  /**
   * Whether the model supports OpenAI-compatible tool calls.
   *
   * Missing means unknown, not false (same tri-state as `libraryAgentic` below): the field
   * is simply absent on a cold start or before the catalog has synced this model, and
   * rendering a definite "not supported" there reports a lookup gap as a model limitation.
   * Call sites must handle three states (unknown means pending or force refresh) and must
   * never collapse it with `?? false`.
   */
  toolCall?: boolean | null;
  /**
   * Server-authoritative: whether this model can drive agentic library retrieval
   * (= toolCall && transport==openai_chat && not in weakModelDenylist).
   *
   * A `null` is an authoritative unknown and must not fall back to an older value; an
   * absent field means an older server did not send it, and only then may the client
   * fall back to deriving the value locally.
   */
  libraryAgentic?: boolean | null;
  /**
   * Reasoning levels the upstream declares for this model (subscription transports only:
   * Codex `supported_reasoning_levels`, Grok `reasoning_efforts[].value`). Empty or missing
   * means the upstream declared none, so no effort is injected on outbound requests.
   *
   * Persisted locally but never synced: the sync envelope is an allowlist mapping so it
   * excludes this by construction, and `sync-mappings.test.ts` pins that. The risk behind
   * the no-sync rule is a synced stale value being sent after an upstream renames its
   * levels; a local copy cannot go stale that way because the catalog is rebuilt wholesale
   * on every refresh, and dropping it would leave the reasoning-level control missing
   * after every cold start until the user syncs by hand.
   */
  upstreamReasoningLevels?: string[];
  /** Local-only subscription `/models` default; excluded from cloud mappings. */
  upstreamDefaultReasoningLevel?: string;
  /** Local-only subscription protocol declaration (`responses` / `chat`). */
  upstreamApiBackend?: string;
  reasoningModeAvailable: boolean;
  isAvailable: boolean;
  isDefault: boolean;
  isRecommended?: boolean;
  priceTier: string;
  summary?: string;
  groupKey?: string;
  groupName?: string;
  sortRank?: number;
  badgeOrder?: string[];
  createdAt?: number;
  promptPrice?: number;
  completionPrice?: number;
  contextLength?: number;
  maxOutputTokens?: number;
  /** USD per 1M cached input tokens. */
  cacheReadInputPerMToken?: number;
  /** Generic cache write price in USD per 1M tokens. */
  cacheCreationInputPerMToken?: number;
  /** Anthropic 5-minute cache write price in USD per 1M tokens. */
  cacheWrite5mPerMToken?: number;
  /** Anthropic 1-hour cache write price in USD per 1M tokens. */
  cacheWrite1hPerMToken?: number;
  reasoningProfile?: string;
  webSearchProfile?: string;
  imageGenProfile?: string;
  /**
   * Authoritative per-model request controls. This is deliberately
   * declarative metadata, not an observed capability result: the composer
   * keeps its entry points visible and uses `state` only to describe whether
   * automatic configuration is available.
   */
  capabilityControls?: Record<string, {
    state: string;
    recipeRef?: string | null;
    reasonCode?: string;
    sourceRefs?: readonly string[];
    availableIntents?: readonly string[];
    customControlRefs?: readonly string[];
  }>;
  /** Generation parameter template and capability references from server metadata; the wire shape is expanded from that metadata at runtime. */
  generationProfile?: {
    template?: string;
    /** Opaque revision the server derives from the normalized profile semantics. */
    revision?: string;
    parameters?: Array<{
      id?: string;
      support?: string;
      source?: string;
      group?: string;
      valueSchema?: string;
      range?: { min?: number; max?: number; minExclusive?: number; maxExclusive?: number; step?: number };
      enumValues?: Array<string | number>;
      fixedValue?: unknown;
      defaultDescription?: string | number;
      interactionGroup?: string;
      conflictsWith?: string[];
      constraints?: Array<Record<string, unknown>>;
      portability?: string;
      risk?: string;
    }>;
    wire?: Record<string, string>;
    transport?: string;
  };
  /**
   * Server capability evidence candidates that passed allowlist decoding.
   * Absent means metadata sent none or they were untrusted, and consumers must fail
   * safe by treating the capability as unknown.
   */
  capabilityEvidenceCandidates?: CapabilityEvidenceCandidateView[];
  /**
   * Public evidence keys claimed by the current server namespace. A key stays
   * owned even when its candidate was rejected by the client decoder, so
   * consumers can fail closed instead of reviving legacy metadata.
   */
  capabilityEvidenceOwnedKeys?: string[];
  /** Present server namespace failed schema/candidates validation. */
  capabilityEvidenceViewMalformed?: boolean;
  /** Current metadata HTTP ETag; when absent the snapshot version must not be used in its place. */
  metadataRevision?: string;
  /** Local engine catalog state. Missing means not observed, never implicitly loaded. */
  localLoadState?: 'loaded' | 'loading' | 'unloaded' | 'unknown';
  /** Where inference actually runs; Ollama :cloud models are proxied_cloud. */
  executionLocality?: 'local' | 'proxied_cloud' | 'unknown';
  /**
   * Transport kind, for example `openai_chat` or `gemini_generate`.
   * The client picks its Strategy from this value; unrecognized kinds are filtered at
   * the catalog stage so the model stays hidden.
   */
  transport?: string;
  /**
   * Optional minimum client version (SemVer).
   * A client older than minClientVersion hides the model in the catalog.
   */
  minClientVersion?: string;
  /**
   * Marks a model the user typed in by hand; the write paths (createManualModel /
   * saveManualModel) set it, and catalog sync leaves it false or undefined.
   * A shared schema field, replacing the older id-prefix convention.
   */
  isManual?: boolean;
  /**
   * Per-model override of the attachment extraction thresholds, sent by backend metadata.
   * Long-context models (Claude 200K, Gemini 2M) can relax the default 500 lines / 100KB.
   */
  attachmentExtraction?: AttachmentExtractionLimits;
  /**
   * File mime types the model handles natively.
   * AttachmentRouter combines this with originalBase64Data and the size thresholds to
   * choose between native and client_extract. Missing or empty means no native file
   * support, so routing always uses client extract.
   */
  nativeFileMimes?: string[];
  /**
   * Whether PDFs default to native handling (true: text PDFs prefer native, as on Gemini;
   * false: client extract by default, with native only as a fallback for scanned files).
   * A read-only field rather than a hardcoded provider check, so changing the effective
   * override on the backend takes effect without a client change.
   */
  pdfNativeDefault?: boolean;
}

/* ── Provider ─────────────────────────────────────────── */

/**
 * How a provider instance authenticates. Defaults to `apiKey`, which is also how older
 * records decode.
 *
 * Only the connection type is synced, never the credential. That lets an OpenAI or Grok
 * connection show "sign in again on this device" elsewhere while the OAuth
 * access/refresh/id tokens and the account id stay on the machine that obtained them.
 * A connection that already holds local credentials is not overwritten by the remote mode.
 */
export type ProviderAuthMode = 'apiKey' | 'subscription';

/**
 * Local credentials obtained from a subscription sign-in (OAuth device code).
 *
 * Stored in IndexedDB alongside `apiKey` and never added to the sync
 * allowlist; cleared together with the provider object when it is deleted.
 */
export interface ProviderSubscriptionCredential {
  accessToken: string;
  /**
   * The upstream rotates this on every renewal, so the new value has to be written back after a
   * refresh; otherwise the ability to renew is lost.
   */
  refreshToken?: string;
  /** Absolute expiry (epoch milliseconds). Absent means the upstream did not say, so no proactive refresh. */
  expiresAt?: number;
  scopes?: string;
  obtainedAt: number;
  /**
   * Codex only: the `chatgpt-account-id` decoded from `id_token` during the token
   * exchange. Every outbound request must carry it.
   *
   * Keeping a copy here is deliberate: the claim is only reliably present at exchange
   * time (it lives in the id_token, and the access token is not guaranteed to carry it),
   * so every consumer reads this parsed value instead of looking it up again. Looking it
   * up again surfaces as "cannot list models" right after a successful authorization.
   */
  accountID?: string;
  /** Codex only: refresh responses usually omit the id_token, so this preserves the account info. */
  idToken?: string;
  /** Codex only: ChatGPT plan tier (plus, pro, ...). Diagnostics only, never used in a decision. */
  planType?: string;
}

export interface Provider {
  id: string;
  kind: ProviderKind;
  status: ProviderConnectionState;
  models: AIModel[];
  catalogModels: AIModel[];
  lastCheckedAt?: string;
  apiKey: string;
  apiKeyPreview: string;
  lastError?: string;
  baseURLText?: string;
  /** relay only: user-supplied name for the relay vendor. */
  customName?: string;
  /** relay only: UI preset kind; takes no part in runtime routing. */
  relayKind?: RelayKind;
  /** relay probe result: later chats should connect directly to this canonical base URL. */
  relayResolvedBaseURLText?: string;
  relayResolvedTransport?:
    | "openai_responses"
    | "openai_chat_completions"
    | "anthropic_messages"
    | "gemini_generate_content"
    | "llamacpp_native";
  relayResolvedAuthMode?:
    | "none"
    | "bearer"
    | "x_api_key"
    | "x_goog_api_key"
    | "query_key";
  relayResolvedHeaderProfile?: "none" | "anthropic_v2023_06_01" | "gemini_key";
  relayResolvedFamilyHint?: "openai" | "anthropic" | "gemini" | "unknown";
  relayProbeVersion?: number;
  relayCapabilityBitmap?: {
    modelsList: boolean;
    responses: boolean;
    chatCompletions: boolean;
    messages: boolean;
    geminiGenerateContent: boolean;
  };
  relayLastProbeAt?: string;
  relayLastProbeErrorClass?:
    | "auth_failed"
    | "permission_denied"
    | "route_not_found"
    | "method_not_allowed"
    | "catalog_unavailable"
    | "model_not_found"
    | "rate_limited"
    | "server_error"
    | "network_error"
    | "response_shape_mismatch"
    | "cli_only"
    | "budget_exceeded"
    | "unknown";
  relayFingerprintKey?: string;
  /** User request intent (transport / auth / reasoning / serviceTier / headers); tunable in advanced mode. */
  relayRequested?: RelayRequestedConfig;
  /** Relay image generation: whether it is on, which mode, and which model does the drawing. */
  relayImage?: RelayImageConfig;
  /** Connection auth mode, defaulting to apiKey. Local field, not synced. */
  authMode?: ProviderAuthMode;
  /** Grok subscription credential. Local field, not synced; set only when authMode='subscription'. */
  grokSubscription?: ProviderSubscriptionCredential;
  /**
   * Codex (ChatGPT subscription) credential. Local field, not synced; set only when
   * authMode='subscription'.
   *
   * Kept separate from `grokSubscription` rather than sharing one field: `authMode` says
   * only that a connection uses a subscription, not which transport it uses. Sharing one
   * field would degrade the test to guessing the owner from the kind, and a single branch
   * that maps `provider.kind` to the wrong credential would send a Grok token to Codex.
   */
  openAISubscription?: ProviderSubscriptionCredential;
  /** LWW baseline timestamp; older records default to the distant past. */
  updatedAt?: string;
  /**
   * Updated only when the listener reports !isPending; LWW reads this field.
   *
   * The `firestore` prefix is historical. It survives as a wire name because backup archives
   * written by every client carry it, so renaming the field would break archives across all of
   * them; the same applies to each `firestoreUpdatedAt` / `firestoreMetadataUpdatedAt` below.
   */
  firestoreUpdatedAt?: string;
}

/* ── Chat ─────────────────────────────────────────────── */

export interface Attachment {
  id: string;
  kind: AttachmentKind;
  fileName: string;
  mimeType: string;
  /** Inline bytes for kind === 'file'; what actually goes to the model. */
  base64Data?: string;
  /** Original bytes kept for download when base64Data holds an extracted or converted form. */
  downloadBase64Data?: string;
  /** ImageStore key for kind === 'image'; image bytes are never inlined onto the message. */
  localImageID?: string;
  /** Remote object key, once the attachment has been uploaded. */
  storageRef?: string;
  /** Small inline preview for kind === 'image', so a list renders without loading the full image. */
  thumbnailBase64?: string;
  /** Byte size of the file the user picked; used for client-side checks such as the Managed total attachment cap. */
  originalSizeBytes?: number;
  // File extraction metadata, used by AttachmentInjector and AttachmentPreview.
  extractedTotalLines?: number;
  extractedTruncated?: boolean;
  extractedSizeBytes?: number;
  // Raw PDF binary as base64, kept when extractionErrorCode === 'scanned_pdf' so the native fallback can run.
  originalBase64Data?: string;
  // Open vocabulary: 'encrypted_pdf' | 'scanned_pdf' | 'password_protected_office' | ...
  extractionErrorCode?: string;
}

/**
 * A web search citation.
 *
 * Normalized in each provider adapter's parseChunk from the streaming chunks; dedup
 * uses the url as primary key and title+snippet as secondary key.
 *
 * - `url` is required and keeps its original scheme (https is not forced);
 * - `index` is the footnote number in the text (supplied by OpenAI Responses and Gemini);
 * - `startIndex` / `endIndex` mark the associated character range (supplied by OpenAI annotations).
 */
export interface Citation {
  url: string;
  title?: string;
  snippet?: string;
  faviconUrl?: string;
  docId?: string;
  source?: string;
  anchor?: string;
  lastEdited?: string;
  index?: number;
  startIndex?: number;
  endIndex?: number;
}

export type ResearchStepStatus = 'pending' | 'running' | 'completed' | 'failed';

export interface ResearchStep {
  /** Mobile agent-loop identity. Optional for documents written by older Web builds. */
  id?: string;
  tool: string;
  label: string;
  status: ResearchStepStatus;
  /** One-based agent leg. Optional for documents written by older Web builds. */
  step?: number;
}

export type QuoteContentKind = 'prose' | 'code' | 'table';

/**
 * Immutable message-level snapshot for a single selection Ask action.
 * The wire shape is shared with iOS and Android; string segments avoid
 * cross-platform UTF-16/grapheme offset drift.
 */
export interface QuoteContext {
  schemaVersion: number;
  sourceMessageId: string;
  sourceRole: ChatRole;
  contentKind: QuoteContentKind;
  leadingText: string;
  selectedText: string;
  trailingText: string;
  contextTruncated: boolean;
}

export interface ChatMessage {
  id: string;
  role: ChatRole;
  text: string;
  reasoningText?: string;
  /**
   * Reasoning duration in milliseconds: from the first reasoning chunk of the stream to
   * the first text chunk, or to the done event when no text chunk ever arrives.
   * Continuations add to prev.reasoningDurationMs. Older messages lack the field and the
   * UI then falls back to "Show thinking".
   */
  reasoningDurationMs?: number;
  /** Local execution facts. Only normalized parser evidence can mark observed. */
  capabilityResults?: Array<{
    owner: 'web' | 'reasoning' | 'generation';
    state: 'not_requested' | 'requested' | 'observed' | 'unconfirmed' | 'rejected' | 'recovered';
    source: 'provider_recipe' | 'custom';
    revision: string;
  }>;
  /** Native tool requests that reached ordinary chat without an active executor. */
  unhandledToolCalls?: Array<{
    id: string;
    name: string;
    arguments: string;
  }>;
  /** Device-local explanation for a one-shot resend that intentionally omitted tools. */
  toolFallbackNotice?: 'library_not_searched' | 'web_recovered';
  /** Local-only CTA gate; never synced. Means exact custom + pre-token upstream 400 only. */
  capabilityCustomRetryEligible?: boolean;
  /** Local-only explicit resend descriptor. Saved preferences are retained dormant. */
  capabilityRecovery?: {
    version: 1;
    action: 'user_confirmed_resend_without_located_setting';
    source: 'provider_recipe' | 'custom';
    owners: Array<'web' | 'reasoning' | 'generation'>;
    locatedPointers: string[];
    recipeRef?: string;
  };
  providerID?: string;
  providerKind: ProviderKind;
  providerName: string;
  modelID?: string;
  modelName: string;
  servedModelID?: string;
  estimatedCost: number;
  /** All input tokens for the request, including plain input plus cache reads and cache writes. */
  inputTokens?: number;
  /** All output tokens for the request; reasoning tokens are included when the upstream counts them. */
  outputTokens?: number;
  state: ChatMessageState;
  errorTitle?: string;
  errorDetail?: string;
  /**
   * Semantic identifier for the failure (ProviderError.kind).
   * errorTitle/errorDetail hold localized text captured at evaluation time and must not
   * drive logic: they do not update when the language changes, so matching English
   * keywords fails in every other locale. Recovery actions always read this field.
   */
  errorKind?: string;
  /**
   * Which side the error came from. `provider` means an official provider or relay
   * returned a response: the UI shows only the redacted upstream text, Sentry must drop
   * it, and the kind alone decides the recovery action.
   */
  errorSource?: ProviderErrorSource;
  attachments?: Attachment[];
  /** One-turn selected-text reference; never shares pinned-note lifetime. */
  quoteContext?: QuoteContext;
  /**
   * Web search citations. Only carried by assistant messages that triggered a web search,
   * normalized while the adapter parses the stream. Undefined on older messages.
   */
  citations?: Citation[];
  /** Whether this assistant message was generated by the Library agent. */
  libraryResearchEnabled?: boolean;
  /** Persisted progress rows of the library agent loop. */
  researchSteps?: ResearchStep[];
  /** ISO 8601 UTC set at creation. Optional so older backups still import. */
  createdAt?: string;
  imageUrl?: string;
  imageBase64?: string;
  imageSettings?: ImageSettings;
  /**
   * Input tokens served from a provider cache.
   * Assistant messages that hit a cache (OpenAI, Anthropic, Gemini, DeepSeek, Moonshot
   * and others) store this, so the UI can show the saving and split the input cost at
   * the cache rate.
   */
  cachedInputTokens?: number;
  /** Total input tokens written to cache; the 5m/1h fields remain for splitting the cost. */
  cacheCreationInputTokens?: number;
  /**
   * Tokens written to the Anthropic 5min TTL cache, billed at 1.25x.
   * Always undefined or 0 on non-Anthropic models.
   */
  cacheCreation5mTokens?: number;
  /**
   * Tokens written to the Anthropic 1h TTL cache, billed at 2.0x.
   * Always undefined or 0 on non-Anthropic models.
   */
  cacheCreation1hTokens?: number;
  /**
   * Where the cost figure came from: `upstream` is an exact cost returned by the upstream
   * (OpenRouter, Grok), `localEstimate` is computed locally from metadata pricing, and
   * `unknown` means it could not be estimated.
   */
  costSource?: 'upstream' | 'localEstimate' | 'unknown' | 'subscription';
}

export interface ImageSettings {
  size?: string;
  quality?: string;
  style?: string;
}

export interface Conversation {
  id: string;
  title: string;
  hasCustomTitle: boolean;
  providerID: string;
  modelID: string;
  /**
   * Provider kind bound to the conversation; required. List icon rendering reads this
   * field directly with no fallback: no providers.find(), no scan over messages, no
   * inference from providerID. Creation paths must require it in the factory signature.
   */
  providerKind: ProviderKind;
  /**
   * Redundant field: the UI preset kind of a relay provider (openai_compatible,
   * anthropic_compatible and so on), used to pick the brand logo in the list for the
   * same reason as providerKind. Undefined for non-relay conversations.
   */
  relayKind?: RelayKind;
  previewText: string;
  estimatedCost: number;
  isDraft: boolean;
  messages: ChatMessage[];
  draftText: string;
  updatedAt: string;
  /** Conversation creation time; required on create, and relied on by the list, sorting and sync. */
  createdAt: string;
  /** Updated only when the listener reports !isPending; LWW reads this field. Historical name, kept for backup-archive compatibility across clients. */
  firestoreUpdatedAt?: string;
  /** Owning folder id; undefined means uncategorized. */
  folderID?: string;
  /** Per-conversation memory switch; undefined counts as true. */
  useMemory?: boolean;
  /** Note ids pinned into this conversation's prompt context. Local on Free; synced with the conversation on Pro. */
  pinnedNoteIds?: string[];
  /** Associated skill id, recorded when the conversation starts from a skill; immutable afterwards. */
  skillId?: string;
  /** Remote message count, shown as a fallback before messages are lazily loaded. */
  remoteMessageCount?: number;
  /** Metadata-level LWW tracking for changes that do not affect ordering: rename, model switch, folder move. Historical name, kept for backup-archive compatibility across clients. */
  firestoreMetadataUpdatedAt?: string;
  /**
   * A read-only conflict copy produced by the merge wizard: hidden from the sidebar list, still
   * matched by full-text search.
   */
  isConflictCopy?: boolean;
  /** Points at the original conversation, so a copy can find its source. */
  conflictOriginId?: string;
  /**
   * Soft-delete timestamp (ISO 8601). Rarely used locally, where deleting removes the
   * record from the store outright, but the merge algorithm `resolveDeletedAt` needs it
   * to detect a remote record coming back from the dead.
   */
  deletedAt?: string;
}

/* ── Folder ──────────────────────────────────────────── */

export interface Folder {
  id: string;
  name: string;
  sortOrder: number;
  colorTag?: string;
  createdAt: string;   // ISO 8601
  updatedAt: string;   // ISO 8601
  /** Remote confirmation timestamp, used for LWW. Historical name, kept for backup-archive compatibility across clients. */
  firestoreUpdatedAt?: string;
}

/* ── Note ─────────────────────────────────────────────── */

/**
 * A provenance entry for a note. Cross-checking against another model, folder summaries
 * and AI post-processing all leave more than one source, which is stored structurally
 * here rather than inlined into the body. Mostly origin and crosscheck in practice: the
 * original answer and the cross-model check. Display-name fields are snapshots taken at
 * capture time, so a later catalog refresh cannot drift the attribution.
 */
export interface ProvenanceEntry {
  kind: 'origin' | 'crosscheck' | 'digest' | 'transform';
  modelID?: string;
  modelName?: string;
  providerKind?: ProviderKind;
  providerName?: string;
  conversationId?: string;
  messageId?: string;
  at: string;                      // ISO 8601
}

/**
 * A note. The body is kept inline and the fields stay flat, in the same style as Conversation, so
 * a storage backend that merges per field writes only what changed rather than the whole document.
 */
export interface Note {
  id: string;                       // Canonical UUID, from createCanonicalUUID
  title: string;                    // Derived from the body until the user edits it
  /** Title source. The placeholder is the first line of the body; 'manual' means the user edited it. */
  titleSource: 'placeholder' | 'manual';
  body: string;                     // Markdown
  /** Snapshot of the AI answer as captured, so it survives deletion of the source conversation. Omitted means none. */
  bodySnapshot?: string;
  /** Free-form user note, kept separate from the body. */
  userNote?: string;
  tags: string[];                   // Always an array; "no tags" is [], never null or omitted
  /** Owning note folder id; undefined means uncategorized. */
  noteFolderID?: string;

  // Source, written once at capture and essentially fixed; used to jump back to the conversation and to badge attribution.
  sourceConversationId?: string;    // Which conversation it came from
  sourceMessageId?: string;         // Which message it points at (on web, the MessageListItem data-message-id)
  sourceModelID?: string;           // Machine model id
  /** Model display name snapshot, frozen at capture time so a catalog refresh cannot drift the attribution. */
  sourceModelName?: string;
  sourceProviderKind?: ProviderKind; // Source brand, for list accent colors and badges, with no fallback
  /** Provider display name snapshot. */
  sourceProviderName?: string;
  sourcePrompt?: string;            // What was asked at the time
  /** Distinguishes the four capture entry points; unknown values degrade to 'blank'. */
  captureKind: 'fullAnswer' | 'selection' | 'userMessage' | 'blank';

  /** Multi-source provenance: cross-checks, summaries and AI post-processing leave more than one source, stored structurally instead of inlined into the body. */
  provenance?: ProvenanceEntry[];

  isPinned?: boolean;               // Absent means not pinned

  createdAt: string;                // ISO 8601
  updatedAt: string;                // ISO 8601
  /** Drives the LWW decision; updated only when the listener reports !isPending, never on a local write. Historical name, kept for backup-archive compatibility across clients. */
  firestoreUpdatedAt?: string;
  /** Soft-delete tombstone; non-empty means deleted and moved to the trash. */
  deletedAt?: string;
}

/* ── Note Folder ──────────────────────────────────────── */

export interface NoteFolder {
  id: string;
  name: string;                     // At most 30 characters
  sortOrder: number;                // Spaced by 1000 so a move can bisect
  colorTag?: string;                // Key into FOLDER_COLORS, shared with Folder
  createdAt: string;                // ISO 8601
  updatedAt: string;                // ISO 8601
  /** Remote confirmation timestamp, used for LWW. Historical name, kept for backup-archive compatibility across clients. */
  firestoreUpdatedAt?: string;
  /**
   * Soft-delete tombstone, deliberately present here even though Folder has no such
   * field: deleting a note folder must propagate reliably across devices and cascade to
   * clear note.noteFolderID, and a hard delete is unreliable on a flaky or offline
   * connection. The trash UI lists notes only; a deleted note folder disappears and its
   * notes return to uncategorized.
   */
  deletedAt?: string;
}

/* ── Quick Prompt ─────────────────────────────────────── */

export interface QuickPrompt {
  id: string;
  title: string;
  prompt: string;
}

/* ── Auth / Account ───────────────────────────────────── */

export interface LoginMethodConnection {
  method: LoginMethod;
  isLinked: boolean;
}

export type AvatarSource = 'custom' | 'social' | 'none';

export interface UserProfile {
  name: string;
  email: string;
  activeLogin: LoginMethod;
  linkedMethods: LoginMethodConnection[];
  avatarURL?: string;
  avatarSource?: AvatarSource;
}

/* ── Preferences ──────────────────────────────────────── */

export interface AppPreference {
  theme: ThemeOption;
  /** Whether the user has explicitly chosen a theme. false or missing means never set, and the product default is dark.
   *  Sync contract: only an explicit choice writes the cloud theme field (including 'system'); this flag is not synced as a field of its own.
   *  Legacy records: when missing, infer from theme !== 'system', since older data only persisted an explicit non-system choice. */
  themeSetByUser?: boolean;
  language: LanguageOption;
  sendShortcut: SendShortcut;
  memoryText?: string;                  // Up to 2000 grapheme clusters
  memoryAntiForgetEnabled?: boolean;    // Defaults to false
  memoryAntiForgetText?: string;        // Up to 200 grapheme clusters
  memoryUpdatedAt?: string;             // ISO 8601
  hasSeenNoteCaptureHint?: boolean;     // One-off UI hint; local to this client
}

/* ── Session ──────────────────────────────────────────── */

export interface LastUsedModelRef {
  providerID: string;
  modelID: string;
}
