/**
 * Model metadata client.
 *
 * Resolves pricing, capabilities and canonical model identity from the bundled/local catalog.
 * Cache strategy: IndexedDB blob plus memory, 24h TTL, with ETag revalidation.
 */

import type {
  AIModel,
  ModelCapability,
  ProviderKind,
  ReasoningMode,
} from "@oriveo/shared";
import type {
  ProviderTransportDefinition,
  StreamShape,
  TransportEndpoints,
} from "@oriveo/core/metadata/types";
import type { GenerationParameterProfile, GenerationParameterValue } from '@oriveo/core/providers/request-builders/types';
import type { CapabilityRuntimeEnvelope } from '@oriveo/core/providers/request-builders/capability-execution';
import type { CapabilityControl } from '@oriveo/core/providers/request-preference/capability-runtime';
import {
  resolveGrokSubscriptionAuth,
  type GrokSubscriptionAuthConfig,
  type GrokSubscriptionAvailability,
} from "@oriveo/core/providers/grok-subscription";
import {
  resolveOpenAISubscriptionAuth,
  type OpenAISubscriptionAuthConfig,
  type OpenAISubscriptionAvailability,
} from "@oriveo/core/providers/openai-subscription";
import { PUBLIC_METADATA_BASE_URL } from "@oriveo/shared";
import { APP_VERSION } from "../../version";
import { readBlob, writeBlob, pruneBlobs } from "../../infra/storage/blob-cache";
import { safeLocalStorage } from "../../infra/storage/web-storage";
import { SUPPORTED_CONTRACT_VERSION } from "./metadata-runtime";
import { fetchWithReachability } from "../reachability/reachability-fetch";
import {
  DEFAULT_LIBRARY_RUNTIME_CONFIG as SHARED_DEFAULT_LIBRARY_RUNTIME_CONFIG,
  type LibraryRuntimeConfig,
} from "../library/types";

// The protocol types now live in @oriveo/core, while the cache implementation stays here; re-exported below.
export type { ProviderTransportDefinition, StreamShape, TransportEndpoints };

type NullableString = string | null | undefined;
type CapabilityEvidenceCandidateView = NonNullable<AIModel["capabilityEvidenceCandidates"]>[number];

export interface ProviderAttachmentSupport {
  image: boolean;
  video?: boolean;
  nativeFile: boolean;
  textFileInline: boolean;
}

export interface ProviderRegionOption {
  id: string;
  label: string;
  baseURL: string;
  privacyPolicyURL?: string;
  apiKeyHelpURL?: string;
}

export interface PublicProviderConfig {
  kind: string;
  displayName: string;
  shortName?: NullableString;
  selectionLabel?: NullableString;
  autoFillNote?: NullableString;
  defaultBaseURL: string;
  apiKeyPlaceholder?: NullableString;
  apiKeyHelpURL?: NullableString;
  apiProtocol?: string;
  protocolFeatures?: Record<string, unknown>;
  category?: string;
  supportsAutoSync?: boolean;
  attachmentSupport?: ProviderAttachmentSupport;
  modelFilter?: Record<string, unknown> | null;
  regionOptions?: ProviderRegionOption[] | null;
  sortOrder?: number;
}

export type ProbeCandidatePriority = "default" | "extended" | "scenario";

export interface RelayProbeAPIRootCandidate {
  rootPath: string;
  priority: ProbeCandidatePriority;
}

export interface RelayProbePreflightFingerprint {
  name: string;
  path: string;
  method: "GET" | "HEAD" | "POST";
  inferTransports: string[];
  inferApiRoot: string;
  inferAuthMode?: string;
}

export interface RelayProbeCatalogStep {
  kind: string;
  path: string;
  authModes: string[];
}

export interface RelayProbePolicy {
  version: number;
  defaultFamilyHint: "openai" | "anthropic" | "gemini" | "unknown";
  apiRootCandidates: RelayProbeAPIRootCandidate[];
  preflightFingerprints: RelayProbePreflightFingerprint[];
  catalogDiscovery: RelayProbeCatalogStep[];
  transportOrder: Record<
    "openai" | "anthropic" | "gemini" | "unknown",
    string[]
  >;
  transportSteps: Array<Record<string, unknown>>;
  failureFingerprints: Array<Record<string, unknown>>;
  fallbackPolicy: {
    allowManualModel: boolean;
    requireCatalogBeforeManual: boolean;
  };
  probeBudget: {
    maxConcurrency: number;
    maxPreflightRequests: number;
    maxCatalogRequests: number;
    maxHandshakeAttempts: number;
    maxDurationMs: number;
    abortOnRateLimit: boolean;
  };
  stopRules: {
    stopOnFirstTransportSuccess: boolean;
    stopOnAuthFailure: boolean;
    stopOnCliOnlyFingerprint: boolean;
    stopOnBudgetExceeded: boolean;
  };
  userAgent: {
    template: string;
    applyOn: "native_only";
  };
}

export interface ModelPricing {
  promptPerMToken: number | null;
  completionPerMToken: number | null;
  cachedInputPerMToken?: number | null;
  costPerUnit?: number | null;
  costInputBatches?: number | null;
  costOutputBatches?: number | null;
  costInputPriority?: number | null;
  costOutputPriority?: number | null;
  cacheReadInputPerMToken?: number | null;
  /** Legacy field, kept as a fallback for the 5m cache write price. */
  cacheCreationInputPerMToken?: number | null;
  /** Anthropic 5min TTL cache write price per 1M tokens (the x1.25 tier). */
  cacheWrite5mPerMToken?: number | null;
  /** Anthropic 1h TTL cache write price per 1M tokens (the x2.0 tier). */
  cacheWrite1hPerMToken?: number | null;
}

export type ModelPricingStatus = "priced" | "free" | "unknown";

export interface ModelSourceSummary {
  sourceKind: string;
  sourceName: string;
  fetchedAt: string;
}

export interface ModelProfileRefs {
  reasoning?: NullableString;
  webSearch?: NullableString;
  imageGen?: NullableString;
  generation?: {
    template?: string;
    /** Current wire: profiles.generation.revision. */
    revision?: string;
    /** lean wire: reference into top-level generationParameterTables. */
    parametersRef?: string;
    parameters?: Array<{
      id?: string;
      support?: string;
      source?: string;
      enumValues?: Array<string | number>;
    }>;
  };
}

export interface ModelUIHints {
  groupKey?: string;
  groupName?: string;
  rank?: number;
  recommended?: boolean;
  badgeOrder?: string[];
}

// StreamShape now lives in @oriveo/core/metadata/types; it is imported and re-exported at the top of this file.

interface ReasoningProfileDefinition {
  transport?: string;
  fallbackProfile?: string;
  levels?: string[];
  defaultLevel?: string;
  params?: Record<string, Record<string, unknown>>;
  streamShape?: StreamShape;
}

interface WebSearchProfileDefinition {
  mergeParams?: Record<string, unknown>;
  maxToolLoops?: number;
  streamShape?: StreamShape;
}

interface ImageGenProfileDefinition {
  mergeParams?: Record<string, unknown>;
  streamShape?: StreamShape;
  requestDefaults?: Record<string, unknown>;
}

/**
 * Closed enum for the model.transport field of the provider capability spec v2 (section 5.1.8).
 *
 * The client picks its protocol strategy from this value. An unknown kind hides the model and
 * reports telemetry rather than throwing, so every other model stays usable.
 */
export type TransportKind =
  | "openai_chat"
  | "openai_responses"
  | "anthropic_messages"
  | "gemini_generate"
  | "dashscope_native"
  | "openai_images"
  | "gemini_image"
  | "qwen_image"
  | "grok_image"
  | "zhipu_image"
  | "anthropic_files"
  | "openai_files";

// TransportEndpoints and ProviderTransportDefinition now live in @oriveo/core/metadata/types; both are imported and re-exported at the top of this file.

interface ModelMetadata {
  canonicalModelId?: string;
  /** Opaque sidecar for the first-party self-heal reporter; never write it into domain models or upstream requests. */
  modelRef?: string;
  aliases?: string[];
  displayName?: string;
  /**
   * Upstream vendor behind an aggregator provider (openRouter / siliconFlow), stated explicitly by
   * the catalog. Clients must not parse it out of the model id slug; see vendorIntegrityExpectations
   * in metadata_authoritative_contract.v1.json. Direct providers carry neither of these two fields.
   */
  vendorKey?: string | null;
  vendorName?: string | null;
  contextLength?: number;
  maxOutputTokens?: number;
  supportsTemperature?: boolean;
  billingSku?: string;
  pricingUnit?: string;
  regionScope?: string;
  currencyCode?: string;
  sourceSummary?: ModelSourceSummary;
  pricing?: ModelPricing;
  pricingStatus?: ModelPricingStatus;
  capabilities?: string[];
  /** Whether the model supports tool calls. Absent means unknown, not false. */
  toolCall?: boolean | null;
  /** Authoritative flag for agentic library retrieval. Absent means the client falls back to local inference. */
  libraryAgentic?: boolean | null;
  supportsPdfInput?: boolean;
  supportsServiceTier?: boolean;
  profiles?: ModelProfileRefs;
  /** v2 controls; legacy profiles are compatibility-only. */
  capabilityControls?: Record<string, CapabilityControl>;
  uiHints?: ModelUIHints;
  /** Provider capability spec v2 section 5.1.8: routing kind, defaulted from the provider's defaultTransport. */
  transport?: TransportKind | string;
  /**
   * Provider capability spec v2 section 8.4: optional minimum client version (SemVer).
   * Compared at startup; the model is hidden from the picker when the running client is older.
   * Stacks with the unknown-transport-kind hiding rule.
   */
  minClientVersion?: string;
  /** Per-model override for the attachment extraction threshold. */
  attachmentExtraction?: {
    maxLines?: number;
    maxBytes?: number;
    totalCap?: number;
    maxInputFileBytes?: number;
  };
  /** Raw server namespace. It is decoded through the local allowlist only. */
  capabilityEvidenceView?: unknown;
  /** Persisted allowlisted result; decoded again before each consumer boundary. */
  capabilityEvidenceCandidates?: unknown;
  /** Persisted public key ownership; decoded through the same key allowlist. */
  capabilityEvidenceOwnedKeys?: unknown;
  /** Persisted schema-level validity bit; raw payload is never retained. */
  capabilityEvidenceViewMalformed?: unknown;
}

interface ProviderData {
  displayName?: string;
  attachmentSupport?: ProviderAttachmentSupport;
  defaultModelId?: string;
  validation?: ProviderValidation;
  resolveMap?: Record<string, string>;
  models: Record<string, ModelMetadata>;
  /** Provider capability spec v2 section 5.1.7: base URL plus endpoints. */
  transport?: ProviderTransportDefinition;
}

/**
 * BYOK key validation contract, read from catalog.providers[*].validation so it can change without
 * a client release.
 * Probes a model-independent endpoint (list_models / key_info) and decides purely from the HTTP
 * status code plus body text; provider-internal error codes are never parsed.
 */
export interface ProviderValidation {
  /** Either `list_models` (GET /models) or `key_info` (OpenRouter's GET /key). */
  probe?: string;
  /** Probe path, relative to the resolved baseURL, such as `/models` or `/key`. */
  probePath?: string;
  /** Auth mode: `bearer` / `x_api_key` / `query_key`. */
  authMode?: "bearer" | "x_api_key" | "query_key";
  /** Header profile: `none` / `anthropic_v2023_06_01` / `openrouter`. */
  headerProfile?: "none" | "anthropic_v2023_06_01" | "openrouter";
  /** Signals that prove a key is invalid; matching any one of them is enough. */
  invalidKeySignals?: Array<{
    status?: number;
    /** AND semantics: every string must appear in the response body, as a case-sensitive literal substring. */
    bodyIncludes?: string[];
  }>;
}

// Relay runtime rule contract, read from catalog.relayRuntimeConfig.
// Clients only consume it; missing fields fall back to DEFAULT_RELAY_RUNTIME_CONFIG.

export type RelayTransportKey =
  | "openai_responses"
  | "openai_chat_completions"
  | "anthropic_messages"
  | "gemini_generate_content";

export interface RelayTransportEnvelope {
  image: boolean;
  nativeFile: boolean;
  textFileInline: boolean;
  webSearch: boolean;
  imageGeneration: boolean;
  reasoning: boolean;
}

export interface RelayTransportRule {
  providerPriority: string | null;
  defaultAuthMode: "bearer" | "x_api_key" | "x_goog_api_key" | "query_key";
  defaultVersion: string;
  acceptedVersions: string[];
  headerProfile:
    "none" | "anthropic_v2023_06_01" | "gemini_key" | "codex_responses";
  codexIdentityDefault: boolean;
  webSearchToolName:
    "web_search" | "web_search_preview" | "disabled" | "google_search";
  imageRoute:
    | "inline_responses_tool"
    | "images_endpoint"
    | "gemini_modality"
    | "unsupported";
  forceStreamForImageGeneration: boolean;
}

export interface RelayVerificationPolicy {
  hardFailedExpiryDays: number;
  softFailedRetryAfterSeconds: number;
  verifiedCacheDays: number;
}

export interface RelayFeatureGatingPolicy {
  showActualModelIdHint: boolean;
  showSoftFailHint: boolean;
}

export interface RelayRuntimeConfig {
  version: string;
  officialProviderWhitelist: string[];
  transportEnvelopes: Record<RelayTransportKey, RelayTransportEnvelope>;
  transportRules: Record<RelayTransportKey, RelayTransportRule>;
  verificationPolicy: RelayVerificationPolicy;
  featureGatingPolicy: RelayFeatureGatingPolicy;
}

/**
 * The source of truth for the library runtime policy types is `core/library/types.ts`; this module
 * only re-exports them.
 *
 * Keeping a trimmed local copy meant later fields such as enabled / availableProviders /
 * directMaxDocuments / directContextMaxChars were dropped from the return literal below even though
 * the catalog carried them. A duplicated type definition always drifts, so both sides share one.
 */
export type { LibraryRuntimeConfig };

export interface ClientRuntimePlatformGate {
  minSupportedBuild: number;
  storeUrl: string;
  message: string;
}

export interface ClientRuntimeConfig {
  featureFlags: Record<string, boolean>;
  appGate: {
    ios: ClientRuntimePlatformGate;
    android: ClientRuntimePlatformGate;
    maintenanceBanner: {
      id: string;
      text: string;
      level: "info" | "warn";
    };
  };
  freeAccessGrant: {
    limits: {
      customSkills: number;
      pinnedSkills: number;
      pinnedConversations: number;
      folders: number;
      syncDevices: number;
      storageBytes: number;
      singleFileBytes: number;
    };
    features: Record<string, boolean>;
  };
  // param = the fixed parameter name used when the pattern has no capture group (see UnsupportedParamPatternDefinition in @oriveo/core)
  selfHealPatterns: Array<{ pattern: string; flags?: string; param?: string }>;
  networkPolicy: {
    chatTimeoutSecs: number;
    streamTimeoutSecs: number;
    imageGenTimeoutSecs: number;
    keyValidationTimeoutSecs: number;
    upstreamFirstByteTimeoutSecs: number;
  };
  promptBudget: {
    totalChars: number;
    pinnedNotesMaxCount: number;
    pinnedNotesBudgetChars: number;
    noteRecallLimit: number;
  };
  attachment: {
    maxFiles: number;
    maxNativeBytesByProvider: Record<string, number>;
  };
  budgetAlert?: {
    thresholds: number[];
    debounceMins: number;
  };
  updatedAt?: string;
}

interface MetadataResponse {
  version: number;
  /** Optional projection marker. Missing means the backwards-compatible full view. */
  view?: "lean";
  /** Tri-state model capability contract; v2 requires an explicit boolean | null on every model. */
  capabilityContractVersion?: number;
  updatedAt: string;
  profiles: {
    reasoning: Record<string, ReasoningProfileDefinition>;
    webSearch: Record<string, WebSearchProfileDefinition>;
    imageGen: Record<string, ImageGenProfileDefinition>;
    generation?: {
      parameters?: Record<string, {
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
      templates?: Record<string, { transport?: string; wire?: Record<string, string> }>;
    };
  };
  providers: Record<string, ProviderData>;
  /** lean-only dictionary of repeated per-model generation parameter matrices. */
  generationParameterTables?: Record<
    string,
    NonNullable<ModelProfileRefs["generation"]>["parameters"]
  >;
  providerConfigs?: PublicProviderConfig[];
  relayRuntimeConfig?: RelayRuntimeConfig;
  libraryRuntimeConfig?: Partial<LibraryRuntimeConfig>;
  runtimeConfig?: ClientRuntimeConfig;
  /** Authoritative recipe envelope, retained for the product UI. */
  capabilityRuntime?: CapabilityRuntimeEnvelope;
  /** Catalog-external model facts from the Server's persisted models.dev snapshot. */
  modelFacts?: Record<string, ModelFacts>;
  modelFactsRevision?: string;
}

export interface ModelFacts {
  toolCall?: boolean;
  reasoning?: boolean;
  reasoningEfforts?: string[];
  reasoningToggle?: boolean;
  modalities?: { input?: string[]; output?: string[] };
  attachment?: boolean;
  source?: string;
}

export interface ResolvedModelMetadata {
  canonicalModelId: string;
  /** Opaque sidecar for the first-party self-heal reporter; never write it into domain models or upstream requests. */
  modelRef?: string;
  displayName?: string;
  contextLength?: number;
  maxOutputTokens?: number;
  supportsTemperature?: boolean;
  billingSku?: string;
  pricingUnit?: string;
  regionScope?: string;
  currencyCode?: string;
  sourceSummary?: ModelSourceSummary;
  pricingStatus: ModelPricingStatus;
  /** Free-form strings rather than a strict union, so unknown values such as 'native_pdf' are ignored instead of rejected. */
  capabilities: string[];
  /**
   * Whether the model supports tool calls. Deliberately tri-state: `undefined` means it has not been
   * probed yet (new model, catalog snapshot not ready), not "confirmed unsupported". Collapsing it
   * with Boolean() would render "not known yet" as a definitive "not supported" during cold start.
   */
  toolCall?: boolean | null;
  /**
   * Authoritative flag for agentic library retrieval. Deliberately tri-state: `undefined` means the
   * catalog did not declare it, so the client must fall back to local inference. Squashing it to
   * false with Boolean() would hide the library entry point on every model at once.
   */
  libraryAgentic?: boolean | null;
  /** Distinguishes an authoritative v2 null from a field that is simply absent under v1. */
  capabilityContractVersion?: number;
  pricing: {
    promptPerToken: number | null;
    completionPerToken: number | null;
    cachedInputPerMToken?: number | null;
    costPerUnit?: number | null;
    costInputBatches?: number | null;
    costOutputBatches?: number | null;
    costInputPriority?: number | null;
    costOutputPriority?: number | null;
    cacheReadInputPerMToken?: number | null;
    cacheCreationInputPerMToken?: number | null;
    cacheWrite5mPerMToken?: number | null;
    cacheWrite1hPerMToken?: number | null;
  } | null;
  profiles: {
    reasoning?: string;
    webSearch?: string;
    imageGen?: string;
    generation?: {
      template?: string;
      /** Exact semantic revision of the generation profile; absent on the legacy protocol. */
      revision?: string;
      parameters?: Array<{
        id?: string;
        support?: string;
        source?: string;
        enumValues?: Array<string | number>;
      }>;
    };
  };
  capabilityControls?: Record<string, CapabilityControl>;
  /** Strictly decoded, safe server candidates. Missing is an unknown verdict. */
  capabilityEvidenceCandidates?: CapabilityEvidenceCandidateView[];
  /** Safe public keys claimed by the server namespace, including rejected candidates. */
  capabilityEvidenceOwnedKeys?: string[];
  /** Present namespace failed schema/candidates validation. */
  capabilityEvidenceViewMalformed?: boolean;
  /** Only the active HTTP ETag is eligible to become this revision. */
  metadataRevision?: string;
  supportsPdfInput?: boolean;
  supportsServiceTier?: boolean;
  /** Provider capability spec v2 section 5.1.8: protocol routing kind; unrecognized values are handled by the strategy registry. */
  transport?: string;
  /** Provider capability spec v2 section 8.4: minimum client version. */
  minClientVersion?: string;
  uiHints?: {
    groupKey?: string;
    groupName?: string;
    rank?: number;
    recommended?: boolean;
    badgeOrder?: string[];
  };
  /** Per-model override for the attachment extraction threshold, declared by the catalog. */
  attachmentExtraction?: {
    maxLines?: number;
    maxBytes?: number;
    totalCap?: number;
    maxInputFileBytes?: number;
  };
  isDefault: boolean;
}

const VALID_CAPABILITIES = new Set<ModelCapability>([
  "reasoning",
  "text",
  "image",
  "video",
  "file",
  "web",
  "imageGeneration",
]);

/**
 * Known badge-displayed capabilities, used for ordering only and never for filtering.
 * Unknown capabilities such as 'native_pdf' pass through to AIModel.capabilities[].
 */
const BADGE_CAPABILITIES = VALID_CAPABILITIES;

/**
 * Cache key bucketing:
 *   - the `oriveo:metadata:c{contractVersion}` prefix invalidates parsed caches whenever
 *     contractVersion changes
 *   - leftovers from earlier localStorage generations are cleaned at startup by
 *     {@link migrateLegacyCache}
 *   - ETags are bucketed the same way so they cannot leak across contract versions
 *
 * **Storage medium: IndexedDB, not localStorage.**
 * The snapshot measures around 3.3MB in practice, of which the providers field alone accounts for
 * 3.45MB across 15 provider catalogs. Writing that to localStorage eats 66% of Chrome's 5MB quota
 * and surfaces as `QuotaExceededError` for other keys on the same origin. The ETag is a short
 * string and is written to the same store in the same transaction, so the two can never disagree.
 */
const LEGACY_CACHE_KEY = "oriveo:metadata";
const LEGACY_ETAG_KEY = "oriveo:metadata:etag";
const CACHE_KEY_PREFIX = "oriveo:metadata:c";
const ETAG_KEY_PREFIX = "oriveo:metadata:etag:c";
const CACHE_TTL = 24 * 60 * 60 * 1000;

/** Key prefix inside the IDB blob store; deliberately shaped like the older localStorage key to make debugging easier. */
const BLOB_KEY_PREFIX = "oriveo:metadata:c";
/** Catalog-external facts are fetched and cached independently from lean metadata. */
const MODEL_FACTS_BLOB_KEY = "oriveo:metadata:model-facts:v1";

/** Snapshot and ETag are stored together, so "ETag hits 304 but the snapshot is gone" cannot happen. */
interface MetadataBlob {
  data: MetadataResponse;
  etag: string | null;
  /**
   * Which allowlist revision this blob has already been rewritten through. Absent means an older
   * cache, which is rewritten once on read. Without the marker every cold start would
   * unconditionally structured-clone the ~1.2MB snapshot and write it back to IDB, work that only
   * ever pays off on a cache written before the current rules.
   */
  allowlistVersion?: number;
}

/** Current allowlist rewrite revision. Bump it when the rewrite rules change so existing caches are reprocessed. */
const METADATA_ALLOWLIST_VERSION = 1;

interface ModelFactsBlob {
  facts: Record<string, ModelFacts>;
  revision: string;
  etag: string | null;
}

/**
 * Cache key for the contractVersion this client speaks.
 * Test fixtures reference this constant instead of hardcoding `oriveo:metadata:c1`, so bumping
 * contractVersion fails old tests loudly rather than silently landing on the "metadata unavailable"
 * branch.
 */
export const METADATA_CACHE_KEY_FOR_TESTING = `${CACHE_KEY_PREFIX}${SUPPORTED_CONTRACT_VERSION}`;

/** Same idea for the bucketed ETag key. Tests covering `metadataRevision` should use it instead of hardcoding `oriveo:metadata:etag:c1`. */
export const METADATA_ETAG_KEY_FOR_TESTING = `${ETAG_KEY_PREFIX}${SUPPORTED_CONTRACT_VERSION}`;

/**
 * Test-only: seed a snapshot into the cache medium so `initMetadata()` cold-starts from it.
 *
 * The point is that tests need not know where the cache lives. When the snapshot moved from
 * localStorage to IndexedDB, every hand-written
 * `localStorage.setItem(KEY, JSON.stringify({data, timestamp}))` across a dozen test files stopped
 * working silently: with no cache to read the code goes to the network and assertions fail in
 * confusing ways. Tests that use this API are immune to a change of medium.
 *
 * Requires IndexedDB: call `import 'fake-indexeddb/auto'` at the top of the test file.
 */
export async function __seedMetadataCacheForTest(entry: {
  // contractVersion is an extra field carried by the catalog; the production read path treats it as optional too (see initMetadata)
  data: MetadataResponse & { contractVersion?: number };
  /** Accepted for compatibility with the older CacheEntry shape; writeBlob stamps its own time, so this is ignored. */
  timestamp?: number;
  etag?: string | null;
}): Promise<void> {
  await writeBlob<MetadataBlob>(cacheKeyFor(SUPPORTED_CONTRACT_VERSION), {
    data: entry.data,
    etag: entry.etag ?? null,
  });
}

/** Test-only: read back the snapshot in the cache medium, to assert what was written. */
export async function __readMetadataCacheForTest(): Promise<MetadataBlob | null> {
  const entry = await readBlob<MetadataBlob>(cacheKeyFor(SUPPORTED_CONTRACT_VERSION));
  return entry?.value ?? null;
}

/** Test-only: read back the modelFacts sidecar stored separately from the lean snapshot. */
export async function __readModelFactsCacheForTest(): Promise<ModelFactsBlob | null> {
  const entry = await readBlob<ModelFactsBlob>(MODEL_FACTS_BLOB_KEY);
  return entry?.value ?? null;
}

function cacheKeyFor(contractVersion: number): string {
  return `${BLOB_KEY_PREFIX}${contractVersion}`;
}

function etagKeyFor(contractVersion: number): string {
  return `${ETAG_KEY_PREFIX}${contractVersion}`;
}

/** Drop every cache bucket that does not belong to the current contractVersion. */
async function pruneStaleBuckets(keepContractVersion: number): Promise<void> {
  await pruneBlobs(BLOB_KEY_PREFIX, [cacheKeyFor(keepContractVersion)]);
}

/**
 * One-time startup cleanup of metadata leftovers in localStorage.
 *
 * Covers three key generations: unbucketed `oriveo:metadata(:etag)`, bucketed
 * `oriveo:metadata:c{n}`, and bucketed ETags `oriveo:metadata:etag:c{n}`.
 * **This hands roughly 3.3MB of quota straight back to the browser** - the snapshot sitting in an
 * existing user's localStorage is the one that pushes the shared quota over its limit, so fixing only the
 * write path would not help them.
 */
function migrateLegacyCache(): void {
  safeLocalStorage.removeItem(LEGACY_CACHE_KEY);
  safeLocalStorage.removeItem(LEGACY_ETAG_KEY);
  for (const key of safeLocalStorage.keys()) {
    if (key.startsWith(CACHE_KEY_PREFIX) || key.startsWith(ETAG_KEY_PREFIX)) {
      safeLocalStorage.removeItem(key);
    }
  }
}
const SNAPSHOT_DATE_PATTERNS = [/-\d{8}$/, /-\d{4}-\d{2}-\d{2}$/];
const NON_AUTO_REASONING_MODES: ReasoningMode[] = [
  "fast",
  "balanced",
  "deep",
  "max",
];
const REASONING_MODE_ORDER: ReasoningMode[] = [
  "automatic",
  ...NON_AUTO_REASONING_MODES,
];

/**
 * Maps a web ProviderKind to the provider key used in the catalog.
 * Catalog keys are camelCase and already line up with ProviderKind.
 * relay has no catalog entry and is therefore not mapped.
 */
const KIND_MAP: Record<string, string> = {
  openAI: "openAI",
  anthropic: "anthropic",
  gemini: "gemini",
  openRouter: "openRouter",
  deepseek: "deepseek",
  grok: "grok",
  mistral: "mistral",
  groq: "groq",
  togetherAI: "togetherAI",
  fireworksAI: "fireworksAI",
  miniMax: "miniMax",
  zhipu: "zhipu",
  qwen: "qwen",
  siliconFlow: "siliconFlow",
  moonshot: "moonshot",
};

let cached: MetadataResponse | null = null;
let cachedETag: string | null = null;
let modelFactsCache: ModelFactsBlob | null = null;
let modelFactsPromise: Promise<void> | null = null;
let modelFactsInitialized = false;
/** When the in-memory snapshot was last written or confirmed; used for the startup TTL check. */
let cachedAt: number | null = null;
/** Catalog projection is memoized on the identity of the underlying snapshot, so the same snapshot is never walked twice. */
let projectedMetadataSource: MetadataResponse | null = null;
let projectedMetadataSnapshot: ReturnType<typeof projectMetadataSnapshot> | null = null;
/** Client-local content generation used by useSyncExternalStore consumers. */
let metadataContentRevision = 0;
let initPromise: Promise<void> | null = null;
let refreshPromise: Promise<void> | null = null;

/**
 * The (version, contractVersion) pair last emitted to subscribers, used to dedupe 304s.
 * A 304 means the content is unchanged, so an unchanged pair skips the emit and the subscribers
 * avoid a pointless recompute. A 200 always emits, since its content may be new.
 */
let lastEmittedSignature: string | null = null;

/**
 * Whether this session has confirmed the metadata snapshot (a decoded 200 or a cache-hit 304 both
 * count).
 *
 * Negative library routing decisions ("not supported") are gated on this. A cached snapshot can be
 * from any point in the past, for example an older config with the feature off or a stale
 * `serverResearchEnabled=false`, and answering from it before confirmation is exactly how the first
 * cold-start computation gets it wrong and only recovers after the async refresh. See
 * `snapshotConfirmed` in `LibraryResearchRoute`.
 */
let snapshotConfirmedThisSession = false;

/**
 * Metadata version subscription: subscribers are notified after every successful metadata refresh,
 * whether or not `version` changed, which is when the UI can recompute the resolved catalog.
 *
 * Trade-off: a plain subscriber set. Swap it for an EventTarget if throttling or event coalescing
 * is ever needed.
 */
export interface MetadataVersionEvent {
  version: number;
  contractVersion: number;
}

type VersionListener = (event: MetadataVersionEvent) => void;

const versionListeners = new Set<VersionListener>();

function emitVersionChange(options: { allowDedup?: boolean } = {}): void {
  if (!cached) return;
  const contractVersion =
    (cached as MetadataResponse & { contractVersion?: number })
      .contractVersion ?? 1;
  const signature = `${cached.version}|${contractVersion}`;

  // 304 and cache-hit paths (allowDedup): skip when the signature matches the last emit
  if (options.allowDedup && lastEmittedSignature === signature) return;

  lastEmittedSignature = signature;
  const event: MetadataVersionEvent = {
    version: cached.version,
    contractVersion,
  };
  for (const listener of versionListeners) {
    try {
      listener(event);
    } catch (err) {
      // A failing listener must not affect the other subscribers
      console.error("[metadata] onVersionChange listener failed", err);
    }
  }
}

/**
 * Test-only: clear every subscriber and reset the emit dedupe signature.
 *
 * The `__` prefix marks it as off limits to production code.
 */
export function __resetVersionListenersForTest(): void {
  versionListeners.clear();
  lastEmittedSignature = null;
}

/**
 * Test-only: clear the metadata singleton cache and its concurrency state, so nothing leaks
 * between test files.
 *
 * localStorage is left untouched; callers prepare their own cache fixtures.
 */
export function __resetMetadataClientForTest(): void {
  cached = null;
  cachedETag = null;
  modelFactsCache = null;
  modelFactsPromise = null;
  modelFactsInitialized = false;
  cachedAt = null;
  projectedMetadataSource = null;
  projectedMetadataSnapshot = null;
  metadataContentRevision = 0;
  initPromise = null;
  refreshPromise = null;
  versionListeners.clear();
  lastEmittedSignature = null;
  snapshotConfirmedThisSession = false;
}

/**
 * Whether this session has confirmed the metadata snapshot (200 or 304).
 *
 * Library routing uses it to decide whether it may reach the negative conclusion "not supported".
 * Positive conclusions are not gated: getting one wrong costs a single failed retrieval and a
 * graceful degrade, far less than reporting a working feature as unsupported.
 */
export function isMetadataSnapshotConfirmed(): boolean {
  return snapshotConfirmedThisSession;
}

/**
 * Subscribe to metadata refresh events. Returns an unsubscribe function.
 *
 * Used by the provider list, the model picker and the provider detail page to recompute the
 * resolved catalog and provider counts after a metadata update.
 */
export function onVersionChange(listener: VersionListener): () => void {
  versionListeners.add(listener);
  return () => {
    versionListeners.delete(listener);
  };
}

/**
 * Synchronously read the client-side metadata content generation, used as a React change signal.
 * Returns 0 before anything is loaded.
 *
 * Pair it with `onVersionChange` as the snapshot getter for `useSyncExternalStore`. Any successful
 * 200, even one whose version is unchanged, and the first session-confirming 304 produce a new
 * value. The version carried by the snapshot itself is still returned by `getMetadataVersion()`.
 */
export function getCachedMetadataVersion(): number {
  return metadataContentRevision;
}

/**
 * Whether the snapshot carries metadata for this model.
 *
 * Library routing uses it to separate "this snapshot cannot answer" from "confirmed unsupported".
 * **Checking only whether a snapshot exists is not enough**: when `initMetadata()` hits the
 * IndexedDB cache it returns immediately and refreshes in the background, so the stale snapshot in
 * hand is non-null as well, while a model the user just synced from the provider's `/models` may
 * not be in it at all and neither `libraryAgentic` nor `transport` resolves. That is "cannot tell",
 * not "unsupported". The actual decision lives in `resolveLibraryResearchRoute`; this is only the
 * minimal lookup.
 */
export function hasCatalogModel(
  modelID: string,
  providerKind: string,
): boolean {
  return Boolean(resolveCatalogModel(modelID, providerKind));
}

/** Exact catalog-external fact lookup. Missing data is unknown, never false. */
export function getModelFacts(providerKind: string, modelID: string): ModelFacts | undefined {
  const providerKey = KIND_MAP[providerKind];
  const normalized = normalizeModelFactsID(modelID);
  if (!providerKey || !normalized) return undefined;
  // An exact catalog-external lookup is the demand signal. Keep this public
  // sidecar off bootstrap; async consumers that need it before dispatch call
  // ensureModelFacts() explicitly, while presentation can update on the normal
  // metadata content revision after this background load finishes.
  if (!modelFactsInitialized) void ensureModelFacts();
  return (modelFactsCache?.facts ?? cached?.modelFacts)?.[`${providerKey}/${normalized}`];
}

export function getModelFactsRevision(): string | undefined {
  if (!modelFactsInitialized) void ensureModelFacts();
  return modelFactsCache?.revision ?? cached?.modelFactsRevision;
}

/**
 * Loads bundled/IDB model facts for subscription/catalog-external
 * consumers. Its ETag and IDB entry are deliberately separate from lean so a
 * facts-only revision never invalidates the 1.2MB catalog cache.
 */
export async function ensureModelFacts(): Promise<void> {
  if (modelFactsInitialized) return;
  if (modelFactsPromise) return modelFactsPromise;

  modelFactsPromise = (async () => {
    try {
      const persisted = await readBlob<ModelFactsBlob>(MODEL_FACTS_BLOB_KEY);
      if (!modelFactsCache && persisted?.value) {
        modelFactsCache = normalizeModelFactsBlob(persisted.value);
      }

      const headers: Record<string, string> = {};
      if (modelFactsCache?.etag) headers["If-None-Match"] = modelFactsCache.etag;
      const response = await fetchWithReachability(
        `${resolveMetadataBackendURL()}/api/metadata/model-facts`,
        { headers },
      );
      if (response.status === 304) return;
      if (response.status === 404) {
        modelFactsCache = null;
        await pruneBlobs(MODEL_FACTS_BLOB_KEY, []);
        return;
      }
      if (!response.ok) return;

      const json = await response.json();
      const data = json.data ?? json;
      if (!isRecord(data) || typeof data.revision !== "string" || !isRecord(data.facts)) {
        return;
      }
      const next = normalizeModelFactsBlob({
        revision: data.revision,
        facts: data.facts as Record<string, ModelFacts>,
        etag: response.headers.get("ETag"),
      });
      if (!next) return;
      const changed = next.revision !== modelFactsCache?.revision;
      modelFactsCache = next;
      await writeBlob<ModelFactsBlob>(MODEL_FACTS_BLOB_KEY, next);
      if (changed) {
        metadataContentRevision += 1;
        emitVersionChange();
      }
    } catch {
      // Offline/IDB failure preserves the last compatible sidecar. With no
      // cache, callers continue with honest unknown rather than false.
    } finally {
      modelFactsInitialized = true;
    }
  })().finally(() => {
    modelFactsPromise = null;
  });
  return modelFactsPromise;
}

/** First-party subscription declaration > persisted models.dev facts > unknown. */
export function subscriptionDeclaredReasoningLevels(providerKind: string, model: AIModel): string[] {
  if (model.upstreamReasoningLevels?.length) return [...model.upstreamReasoningLevels];
  return getModelFacts(providerKind, model.id)?.reasoningEfforts?.filter((value) => value.length > 0) ?? [];
}

/** First-party subscription declaration > persisted models.dev facts > unknown. */
export function subscriptionDeclaredToolCall(providerKind: string, model: AIModel): boolean | undefined {
  if (typeof model.toolCall === 'boolean') return model.toolCall;
  return getModelFacts(providerKind, model.id)?.toolCall;
}

/** Mirrors Server normalizeModelsDevJoinID; order is part of the contract. */
export function normalizeModelFactsID(modelID: string): string {
  let value = modelID.trim().toLowerCase();
  for (const prefix of ['accounts/fireworks/models/', 'accounts/fireworks/routers/', 'pro/']) {
    if (value.startsWith(prefix)) value = value.slice(prefix.length);
  }
  return value
    .replace(/(?:-\d{8}|-\d{4}-\d{2}-\d{2})$/, '')
    .replace(/(\d)p(\d)/g, '$1.$2');
}

export async function initMetadata(): Promise<void> {
  if (cached) return;
  if (initPromise) {
    await initPromise;
    return;
  }

  initPromise = (async () => {
    // One-time cleanup: drop the whole snapshot left behind in localStorage and hand ~3.3MB of quota back
    migrateLegacyCache();

    try {
      const currentKey = cacheKeyFor(SUPPORTED_CONTRACT_VERSION);
      const entry = await readBlob<MetadataBlob>(currentKey);
      if (entry) {
        const cachedContract =
          (entry.value.data as MetadataResponse & { contractVersion?: number })
            .contractVersion ?? 1;
        // Defensive: a contract mismatch should not happen, but the cache could have been modified externally
        if (cachedContract !== SUPPORTED_CONTRACT_VERSION) {
          await pruneStaleBuckets(SUPPORTED_CONTRACT_VERSION);
        } else {
          cachedETag = entry.value.etag;
          cachedAt = entry.timestamp;
          cached = normalizeMetadataEvidenceViews(
            entry.value.data,
            cachedETag ?? undefined,
          );
          adoptLegacyModelFacts(cached);
          metadataContentRevision += 1;
          // Rewrite an older cache through the allowlist so raw provenance
          // cannot survive in the cache after this client has seen it.
          // A blob already carrying the current allowlist marker is skipped: that 1.2MB
          // structured clone plus IDB write is a one-time migration cost, not something
          // every cold start should pay.
          if (entry.value.allowlistVersion !== METADATA_ALLOWLIST_VERSION) {
            persistCache(cached, cachedContract);
          }
          // Notify subscribers immediately on a cache hit (allowDedup=false, the first emit must fire)
          emitVersionChange();
          if (Date.now() - entry.timestamp < CACHE_TTL) {
            refreshInBackground();
            return;
          }
        }
      }
    } catch {
      // Corrupt cache, ignore
    }

    await fetchMetadata();
  })();

  try {
    await initPromise;
  } finally {
    initPromise = null;
  }
}

export function lookupPricing(
  modelID: string,
  providerKind: ProviderKind | string,
): { promptPerToken: number; completionPerToken: number } | null {
  const resolved = resolveCatalogModel(modelID, providerKind);
  if (!resolved?.pricing || resolved.pricingUnit !== "per_token") return null;
  if (
    resolved.pricing.promptPerToken == null ||
    resolved.pricing.completionPerToken == null
  ) {
    return null;
  }

  return {
    promptPerToken: resolved.pricing.promptPerToken,
    completionPerToken: resolved.pricing.completionPerToken,
  };
}

export function lookupCapabilities(
  modelID: string,
  providerKind: ProviderKind | string,
): string[] | null {
  const resolved = resolveCatalogModel(modelID, providerKind);
  if (!resolved || resolved.capabilities.length === 0) return null;
  return resolved.capabilities;
}

export function resolveCatalogModel(
  modelID: string,
  providerKind: ProviderKind | string,
): ResolvedModelMetadata | null {
  const entry = resolveModelEntry(modelID, providerKind);
  if (!entry) return null;
  return buildResolvedFromEntry(entry);
}

/**
 * Cross-provider lookup: tries the official providers in relayRuntimeConfig.officialProviderWhitelist
 * order and returns the first matching metadata together with the matched provider kind and a
 * source tag.
 *
 * Unlike {@link resolveCatalogModel}, this exists for relay enrichment. Relay is not itself a source
 * of truth for model mapping, so the sweep works out which official family a given model id
 * resembles.
 *
 * Match order:
 *   1. transportPriority when given, trying the client's transport-to-provider mapping first
 *   2. the remaining whitelisted providers, in order
 *   3. no match returns null and the caller falls back to relay's local semantics
 */
export type RelayCatalogMatchSource = "transport_first" | "cross_provider";

export interface RelayCatalogMatchResult {
  matchedProviderKind: string;
  canonicalModelId: string;
  metadata: ResolvedModelMetadata;
  source: RelayCatalogMatchSource;
}

export function resolveCatalogModelAcrossProvidersWithProvider(
  modelID: string,
  options?: { transportPriority?: string | null },
): RelayCatalogMatchResult | null {
  const runtimeConfig = getRelayRuntimeConfig();
  const whitelist = runtimeConfig.officialProviderWhitelist;
  const priority = options?.transportPriority?.trim() ?? null;

  const ordered: string[] = [];
  if (priority && whitelist.includes(priority)) {
    ordered.push(priority);
  }
  for (const kind of whitelist) {
    if (kind !== priority) ordered.push(kind);
  }

  for (const providerKind of ordered) {
    const entry = resolveModelEntry(modelID, providerKind);
    if (!entry) continue;
    const metadata = buildResolvedFromEntry(entry);
    return {
      matchedProviderKind: providerKind,
      canonicalModelId: metadata.canonicalModelId,
      metadata,
      source: providerKind === priority ? "transport_first" : "cross_provider",
    };
  }

  return null;
}

/**
 * Projection cache keyed by the snapshot's own model object.
 *
 * `buildResolvedFromEntry` runs the whole normalize/decode stack (pricing, profiles,
 * uiHints, capabilities, four evidence decoders) and had no cache, yet the capability
 * evidence layer reaches it 4-5 times **per model**: `currentCapabilityEvidenceModel`
 * calls `resolveCatalogModel`, and `projectModelCapabilityPresentation` /
 * `nextCapabilityEvidenceExpiry` each call `currentCapabilityEvidenceModel` several
 * times over. Opening a 355-model catalog therefore re-projected the same metadata
 * thousands of times.
 *
 * Keying on the object is sound because every field the projection reads is a function
 * of the snapshot: `resolveModelEntry` hands back `provider.models[canonicalModelId]`
 * straight out of `cached`, aliases all resolve to that one canonical key, a model
 * object belongs to exactly one provider, and `normalizeMetadataEvidenceViews` rebuilds
 * every model object for each new snapshot — so a new snapshot simply cannot collide
 * with these keys, and `cachedETag` / `capabilityContractVersion` / `view` are only ever
 * reassigned together with `cached` itself (a 304 reassigns neither).
 *
 * The projection is shared, not copied: every consumer only reads fields off it
 * (audited at the time of writing). Do not mutate a `resolveCatalogModel` result.
 */
const resolvedModelProjectionCache = new WeakMap<ModelMetadata, ResolvedModelMetadata>();

function buildResolvedFromEntry(entry: {
  treeModelId: string;
  canonicalModelId: string;
  model: ModelMetadata;
  provider: ProviderData;
  providerKind: string;
  generationParameterTables?: MetadataResponse["generationParameterTables"];
}): ResolvedModelMetadata {
  const memoized = resolvedModelProjectionCache.get(entry.model);
  if (memoized) return memoized;
  const pricing = normalizePricing(entry.model);
  const pricingStatus = normalizePricingStatus(entry.model, pricing);
  const profiles = normalizeProfiles(entry.model, entry.generationParameterTables);
  const uiHints = normalizeUIHints(entry.model.uiHints);
  const capabilities = normalizeCapabilities(
    entry.model.capabilities,
    uiHints?.badgeOrder,
  );
  const capabilityContractVersion = cached?.capabilityContractVersion;
  const usesCapabilityContractV2 =
    typeof capabilityContractVersion === "number" &&
    capabilityContractVersion >= 2;
  const evidenceContext = {
    providerKind: entry.providerKind,
    modelId: entry.treeModelId,
    transport: entry.model.transport,
    metadataRevision: cachedETag ?? undefined,
    lean: cached?.view === "lean",
  };
  const capabilityEvidenceCandidates = entry.model.capabilityEvidenceView !== undefined
    ? decodeCapabilityEvidenceView(entry.model.capabilityEvidenceView, evidenceContext)
    : decodePersistedCapabilityEvidenceCandidates(
        entry.model.capabilityEvidenceCandidates,
        evidenceContext,
      );
  const capabilityEvidenceOwnedKeys = decodeModelCapabilityEvidenceOwnedKeys(
    entry.model,
    evidenceContext.lean,
  );
  const capabilityEvidenceViewMalformed = decodeModelCapabilityEvidenceViewMalformed(
    entry.model,
    evidenceContext.lean,
  );

  const resolved: ResolvedModelMetadata = {
    canonicalModelId: entry.canonicalModelId,
    modelRef:
      typeof entry.model.modelRef === "string" &&
      /^[A-Za-z0-9_-]{22}$/.test(entry.model.modelRef)
        ? entry.model.modelRef
        : undefined,
    displayName: entry.model.displayName,
    contextLength: entry.model.contextLength,
    maxOutputTokens: entry.model.maxOutputTokens,
    supportsTemperature: entry.model.supportsTemperature,
    billingSku: entry.model.billingSku,
    pricingUnit: normalizePricingUnit(entry.model.pricingUnit),
    regionScope: entry.model.regionScope,
    currencyCode: entry.model.currencyCode,
    sourceSummary: normalizeSourceSummary(entry.model.sourceSummary),
    pricingStatus,
    capabilities,
    // A v2 null is an authoritative "unknown" and must be preserved; even when the key is missing
    // entirely, fail safe to null rather than letting a stale local value re-authorize the
    // capability. Under v1 only booleans are passed through.
    ...(usesCapabilityContractV2
      ? {
          toolCall:
            typeof entry.model.toolCall === "boolean"
              ? entry.model.toolCall
              : null,
          libraryAgentic:
            typeof entry.model.libraryAgentic === "boolean"
              ? entry.model.libraryAgentic
              : null,
        }
      : {
          ...(typeof entry.model.toolCall === "boolean"
            ? { toolCall: entry.model.toolCall }
            : {}),
          ...(typeof entry.model.libraryAgentic === "boolean"
            ? { libraryAgentic: entry.model.libraryAgentic }
            : {}),
        }),
    capabilityContractVersion,
    pricing: pricingStatus === "unknown" ? null : pricing,
    profiles,
    ...(entry.model.capabilityControls ? { capabilityControls: entry.model.capabilityControls } : {}),
    ...(capabilityEvidenceCandidates !== undefined
      ? { capabilityEvidenceCandidates }
      : {}),
    ...(capabilityEvidenceOwnedKeys !== undefined
      ? { capabilityEvidenceOwnedKeys }
      : {}),
    ...(capabilityEvidenceViewMalformed !== undefined
      ? { capabilityEvidenceViewMalformed }
      : {}),
    ...(cachedETag ? { metadataRevision: cachedETag } : {}),
    supportsPdfInput: Boolean(entry.model.supportsPdfInput),
    supportsServiceTier: Boolean(entry.model.supportsServiceTier),
    transport:
      typeof entry.model.transport === "string" && entry.model.transport.trim()
        ? entry.model.transport
        : undefined,
    minClientVersion:
      typeof entry.model.minClientVersion === "string" &&
      entry.model.minClientVersion.trim()
        ? entry.model.minClientVersion
        : undefined,
    uiHints,
    attachmentExtraction: entry.model.attachmentExtraction ?? undefined,
    isDefault: entry.provider.defaultModelId === entry.canonicalModelId,
  };
  resolvedModelProjectionCache.set(entry.model, resolved);
  return resolved;
}

/* -- Provider capability spec v2: transport and streamShape accessors -------- */

/**
 * Returns the ProviderTransportDefinition for the given provider, or null when the catalog carries
 * none, in which case callers should fall back to the built-in default table.
 */
export function getProviderTransport(
  providerKind: ProviderKind | string,
): ProviderTransportDefinition | null {
  const provider = resolveProviderData(providerKind);
  const transport = provider?.transport;
  if (!transport || typeof transport.baseUrl !== "string") return null;
  return {
    baseUrl: transport.baseUrl,
    endpoints: { ...(transport.endpoints ?? {}) },
  };
}

/** Returns the transport kind for the given model, or undefined when the catalog does not declare one. */
export function getModelTransport(
  modelID: string,
  providerKind: ProviderKind | string,
): string | undefined {
  const entry = resolveModelEntry(modelID, providerKind);
  const raw = entry?.model.transport;
  return typeof raw === "string" && raw.trim() ? raw : undefined;
}

/** Returns the streamShape of a webSearch profile, or null when it is not declared. */
export function getWebSearchStreamShape(
  profileName: NullableString,
): StreamShape | null {
  const name = normalizeProfileRef(profileName);
  if (!name) return null;
  const def = cached?.profiles?.webSearch?.[name];
  return def?.streamShape ?? null;
}

/** Returns the streamShape of a reasoning profile, or null when it is not declared. */
export function getReasoningStreamShape(
  profileName: NullableString,
): StreamShape | null {
  const name = normalizeProfileRef(profileName);
  if (!name) return null;
  const def = cached?.profiles?.reasoning?.[name];
  return def?.streamShape ?? null;
}

/** Returns the streamShape of an imageGen profile, or null when it is not declared. */
export function getImageGenStreamShape(
  profileName: NullableString,
): StreamShape | null {
  const name = normalizeProfileRef(profileName);
  if (!name) return null;
  const def = cached?.profiles?.imageGen?.[name];
  return def?.streamShape ?? null;
}

export function getImageGenProfile(profileName: NullableString): {
  name: string;
  mergeParams: Record<string, unknown>;
  requestDefaults: Record<string, unknown>;
  streamShape: StreamShape | null;
} | null {
  const name = normalizeProfileRef(profileName);
  if (!name) return null;
  const def = cached?.profiles?.imageGen?.[name];
  if (!def) return null;
  return {
    name,
    mergeParams:
      def.mergeParams && typeof def.mergeParams === "object"
        ? (def.mergeParams as Record<string, unknown>)
        : {},
    requestDefaults:
      def.requestDefaults && typeof def.requestDefaults === "object"
        ? (def.requestDefaults as Record<string, unknown>)
        : {},
    streamShape: def.streamShape ?? null,
  };
}

/**
 * Expands a model reference plus the shared generation schema from the same metadata into a profile
 * the request builders can consume. Returns undefined unless the full schema is available, because
 * the client must never guess fields or inject defaults.
 */
export function resolveGenerationProfileRef(
  ref: {
    template?: string;
    revision?: string;
    parameters?: Array<{
      id?: string;
      support?: string;
      source?: string;
      enumValues?: Array<string | number>;
    }>;
  } | null | undefined,
): GenerationParameterProfile | undefined {
  const templateName = ref?.template;
  const generation = cached?.profiles?.generation;
  const template = templateName ? generation?.templates?.[templateName] : undefined;
  if (!templateName || !template?.wire) return undefined;
  const revision = normalizeOpaqueGenerationRevision(ref?.revision);
  return {
    template: templateName,
    ...(revision ? { revision } : {}),
    wire: { ...template.wire },
    parameters: (ref?.parameters ?? []).flatMap((entry) => {
      if (!entry.id) return [];
      return [{
        id: entry.id,
        support: entry.support ?? 'unknown',
        source: entry.source ?? 'unknown',
        group: generation?.parameters?.[entry.id]?.group,
        valueSchema: generation?.parameters?.[entry.id]?.valueSchema,
        range: generation?.parameters?.[entry.id]?.range,
        // Model-level enumValues override the shared platform schema, narrowing reasoning levels to
        // the assigned profile. Falling back to the global value keeps older payloads that omit the
        // field working.
        enumValues: entry.enumValues ?? generation?.parameters?.[entry.id]?.enumValues,
        fixedValue: generation?.parameters?.[entry.id]?.fixedValue,
        defaultDescription: generation?.parameters?.[entry.id]?.defaultDescription,
        interactionGroup: generation?.parameters?.[entry.id]?.interactionGroup,
        conflictsWith: generation?.parameters?.[entry.id]?.conflictsWith,
       requires: generation?.parameters?.[entry.id]?.requires,
        constraints: generation?.parameters?.[entry.id]?.constraints,
        portability: generation?.parameters?.[entry.id]?.portability,
        risk: generation?.parameters?.[entry.id]?.risk,
      }];
    }),
  };
}

/** Returns the full webSearch profile definition, including mergeParams and streamShape. */
export function getWebSearchProfile(profileName: NullableString): {
  name: string;
  mergeParams: Record<string, unknown>;
  maxToolLoops?: number;
  streamShape: StreamShape | null;
} | null {
  const name = normalizeProfileRef(profileName);
  if (!name) return null;
  const def = cached?.profiles?.webSearch?.[name];
  if (!def) return null;
  return {
    name,
    mergeParams:
      def.mergeParams && typeof def.mergeParams === "object"
        ? (def.mergeParams as Record<string, unknown>)
        : {},
    maxToolLoops:
      typeof def.maxToolLoops === "number" ? def.maxToolLoops : undefined,
    streamShape: def.streamShape ?? null,
  };
}

/** Returns the full reasoning profile definition, including params and streamShape. */
export function getReasoningProfile(profileName: NullableString): {
  name: string;
  transport?: string;
  fallbackProfile?: string;
  levels?: string[];
  params: Record<string, Record<string, unknown>>;
  streamShape: StreamShape | null;
} | null {
  const name = normalizeProfileRef(profileName);
  if (!name) return null;
  const def = cached?.profiles?.reasoning?.[name];
  if (!def) return null;
  return {
    name,
    transport: def.transport,
    fallbackProfile: def.fallbackProfile,
    levels: Array.isArray(def.levels) ? [...def.levels] : undefined,
    params:
      def.params && typeof def.params === "object"
        ? (def.params as Record<string, Record<string, unknown>>)
        : {},
    streamShape: def.streamShape ?? null,
  };
}

/** Returns every known webSearch profile name, for the relay config dropdown and forward-compat checks. */
export function listKnownWebSearchProfiles(): string[] {
  if (!cached?.profiles?.webSearch) return [];
  return Object.keys(cached.profiles.webSearch).sort();
}

/**
 * Built-in defaults for the relay runtime rules.
 *
 * Used only when the catalog carries no relayRuntimeConfig, or an individual field is missing.
 * These values mirror the catalog defaults and must be changed together with them.
 */
export const DEFAULT_RELAY_RUNTIME_CONFIG: RelayRuntimeConfig = {
  version: "fallback",
  officialProviderWhitelist: [
    "openAI",
    "anthropic",
    "gemini",
    "deepseek",
    "miniMax",
    "zhipu",
    "qwen",
  ],
  transportEnvelopes: {
    openai_responses: {
      image: true,
      nativeFile: true,
      textFileInline: true,
      webSearch: true,
      imageGeneration: true,
      reasoning: true,
    },
    openai_chat_completions: {
      image: true,
      nativeFile: false,
      textFileInline: true,
      webSearch: false,
      imageGeneration: false,
      reasoning: true,
    },
    anthropic_messages: {
      image: true,
      nativeFile: true,
      textFileInline: true,
      webSearch: false,
      imageGeneration: false,
      reasoning: true,
    },
    gemini_generate_content: {
      image: true,
      nativeFile: true,
      textFileInline: true,
      webSearch: true,
      imageGeneration: true,
      reasoning: true,
    },
  },
  transportRules: {
    openai_responses: {
      providerPriority: "openAI",
      defaultAuthMode: "bearer",
      defaultVersion: "v1",
      acceptedVersions: ["v1"],
      headerProfile: "codex_responses",
      codexIdentityDefault: true,
      webSearchToolName: "web_search",
      imageRoute: "inline_responses_tool",
      forceStreamForImageGeneration: true,
    },
    openai_chat_completions: {
      providerPriority: "openAI",
      defaultAuthMode: "bearer",
      defaultVersion: "v1",
      acceptedVersions: ["v1"],
      headerProfile: "none",
      codexIdentityDefault: false,
      webSearchToolName: "disabled",
      imageRoute: "images_endpoint",
      forceStreamForImageGeneration: false,
    },
    anthropic_messages: {
      providerPriority: "anthropic",
      defaultAuthMode: "x_api_key",
      defaultVersion: "v1",
      acceptedVersions: ["v1"],
      headerProfile: "anthropic_v2023_06_01",
      codexIdentityDefault: false,
      webSearchToolName: "disabled",
      imageRoute: "unsupported",
      forceStreamForImageGeneration: false,
    },
    gemini_generate_content: {
      providerPriority: "gemini",
      defaultAuthMode: "x_goog_api_key",
      defaultVersion: "v1beta",
      acceptedVersions: ["v1", "v1beta"],
      headerProfile: "gemini_key",
      codexIdentityDefault: false,
      webSearchToolName: "google_search",
      imageRoute: "gemini_modality",
      forceStreamForImageGeneration: false,
    },
  },
  verificationPolicy: {
    hardFailedExpiryDays: 7,
    softFailedRetryAfterSeconds: 60,
    verifiedCacheDays: 30,
  },
  featureGatingPolicy: {
    showActualModelIdHint: true,
    showSoftFailHint: true,
  },
};

/**
 * Built-in defaults for the library agent loop, mirroring the catalog defaults.
 * When the whole block is absent or a field is invalid, the client falls back here field by field.
 */
export const DEFAULT_LIBRARY_RUNTIME_CONFIG: LibraryRuntimeConfig =
  SHARED_DEFAULT_LIBRARY_RUNTIME_CONFIG;

/**
 * Returns the current relay runtime rules, falling back field by field to the defaults.
 *
 * Enrichment, gating and adapters should read the rules only through this function and never touch
 * cached.relayRuntimeConfig directly.
 */
export function getRelayRuntimeConfig(): RelayRuntimeConfig {
  const remote = cached?.relayRuntimeConfig;
  if (!remote) return DEFAULT_RELAY_RUNTIME_CONFIG;

  const whitelist =
    Array.isArray(remote.officialProviderWhitelist) &&
    remote.officialProviderWhitelist.length > 0
      ? remote.officialProviderWhitelist
      : DEFAULT_RELAY_RUNTIME_CONFIG.officialProviderWhitelist;

  const envelopes = mergeTransportEnvelopes(remote.transportEnvelopes);
  const rules = mergeTransportRules(
    (remote as Partial<RelayRuntimeConfig>).transportRules as
      | Partial<Record<RelayTransportKey, Partial<RelayTransportRule>>>
      | undefined,
  );

  return {
    version:
      typeof remote.version === "string" && remote.version.length > 0
        ? remote.version
        : DEFAULT_RELAY_RUNTIME_CONFIG.version,
    officialProviderWhitelist: whitelist,
    transportEnvelopes: envelopes,
    transportRules: rules,
    verificationPolicy: {
      hardFailedExpiryDays:
        remote.verificationPolicy?.hardFailedExpiryDays ??
        DEFAULT_RELAY_RUNTIME_CONFIG.verificationPolicy.hardFailedExpiryDays,
      softFailedRetryAfterSeconds:
        remote.verificationPolicy?.softFailedRetryAfterSeconds ??
        DEFAULT_RELAY_RUNTIME_CONFIG.verificationPolicy
          .softFailedRetryAfterSeconds,
      verifiedCacheDays:
        remote.verificationPolicy?.verifiedCacheDays ??
        DEFAULT_RELAY_RUNTIME_CONFIG.verificationPolicy.verifiedCacheDays,
    },
    featureGatingPolicy: {
      showActualModelIdHint:
        remote.featureGatingPolicy?.showActualModelIdHint ??
        DEFAULT_RELAY_RUNTIME_CONFIG.featureGatingPolicy.showActualModelIdHint,
      showSoftFailHint:
        remote.featureGatingPolicy?.showSoftFailHint ??
        DEFAULT_RELAY_RUNTIME_CONFIG.featureGatingPolicy.showSoftFailHint,
    },
  };
}

/** Returns the library agent loop policy, merging in the built-in defaults field by field when the catalog is partial. */
export function getLibraryRuntimeConfig(): LibraryRuntimeConfig {
  const remote = cached?.libraryRuntimeConfig;
  if (!remote || typeof remote !== "object") {
    return {
      ...DEFAULT_LIBRARY_RUNTIME_CONFIG,
      toolDescriptions: { ...DEFAULT_LIBRARY_RUNTIME_CONFIG.toolDescriptions },
      weakModelDenylist: [...DEFAULT_LIBRARY_RUNTIME_CONFIG.weakModelDenylist],
    };
  }

  const toolDescriptions: Record<string, string> = {
    ...DEFAULT_LIBRARY_RUNTIME_CONFIG.toolDescriptions,
  };
  if (
    remote.toolDescriptions &&
    typeof remote.toolDescriptions === "object" &&
    !Array.isArray(remote.toolDescriptions)
  ) {
    for (const [tool, description] of Object.entries(remote.toolDescriptions)) {
      if (typeof description === "string" && description.trim()) {
        toolDescriptions[tool] = description;
      }
    }
  }

  const weakModelDenylist = Array.isArray(remote.weakModelDenylist)
    ? remote.weakModelDenylist
        .filter((modelID): modelID is string => typeof modelID === "string")
        .map((modelID) => modelID.trim())
        .filter(Boolean)
    : [...DEFAULT_LIBRARY_RUNTIME_CONFIG.weakModelDenylist];

  return {
    version: normalizeLibraryInteger(
      remote.version,
      DEFAULT_LIBRARY_RUNTIME_CONFIG.version,
      1,
    ),
    toolDescriptions:
      toolDescriptions as LibraryRuntimeConfig["toolDescriptions"],
    maxSteps: normalizeLibraryInteger(
      remote.maxSteps,
      DEFAULT_LIBRARY_RUNTIME_CONFIG.maxSteps,
      1,
    ),
    toolTimeoutMs: normalizeLibraryInteger(
      remote.toolTimeoutMs,
      DEFAULT_LIBRARY_RUNTIME_CONFIG.toolTimeoutMs,
      1,
    ),
    maxEmptyHits: normalizeLibraryInteger(
      remote.maxEmptyHits,
      DEFAULT_LIBRARY_RUNTIME_CONFIG.maxEmptyHits,
      0,
    ),
    maxSelfCorrections: normalizeLibraryInteger(
      remote.maxSelfCorrections,
      DEFAULT_LIBRARY_RUNTIME_CONFIG.maxSelfCorrections,
      0,
    ),
    tokenBudget: normalizeLibraryInteger(
      remote.tokenBudget,
      DEFAULT_LIBRARY_RUNTIME_CONFIG.tokenBudget,
      0,
    ),
    estimatedTokensPerStep: normalizeLibraryInteger(
      remote.estimatedTokensPerStep,
      DEFAULT_LIBRARY_RUNTIME_CONFIG.estimatedTokensPerStep,
      1,
    ),
    highCostConfirmationUSD: normalizeLibraryNumber(
      remote.highCostConfirmationUSD,
      DEFAULT_LIBRARY_RUNTIME_CONFIG.highCostConfirmationUSD,
      0,
    ),
    weakModelDenylist,
    sensitiveGateEnabled:
      typeof remote.sensitiveGateEnabled === "boolean"
        ? remote.sensitiveGateEnabled
        : DEFAULT_LIBRARY_RUNTIME_CONFIG.sensitiveGateEnabled,
    // Optional fields are written only when the catalog actually declares them; otherwise they stay
    // undefined and each resolve* / is* helper applies its own fallback. Baking client defaults in
    // here would make "not declared" indistinguishable from "declared with this value".
    ...(typeof remote.enabled === "boolean" ? { enabled: remote.enabled } : {}),
    ...(Array.isArray(remote.availableProviders)
      ? {
          availableProviders: remote.availableProviders.filter(
            (provider): provider is string => typeof provider === "string",
          ),
        }
      : {}),
    ...(typeof remote.directMaxDocuments === "number" &&
      Number.isInteger(remote.directMaxDocuments) &&
      remote.directMaxDocuments > 0
      ? { directMaxDocuments: remote.directMaxDocuments }
      : {}),
    ...(typeof remote.directContextMaxChars === "number" &&
      Number.isInteger(remote.directContextMaxChars) &&
      remote.directContextMaxChars > 0
      ? { directContextMaxChars: remote.directContextMaxChars }
      : {}),
    // Server-side research is the one field where absence means off: without the endpoint,
    // defaulting to true would make every retrieval hit a 404.
    serverResearchEnabled: remote.serverResearchEnabled === true,
    ...(Array.isArray(remote.serverResearchProviderDenylist)
      ? {
          serverResearchProviderDenylist:
            remote.serverResearchProviderDenylist.filter(
              (kind): kind is string => typeof kind === "string",
            ),
        }
      : {}),
    ...(typeof remote.serverResearchMaxDocuments === "number" &&
      Number.isInteger(remote.serverResearchMaxDocuments) &&
      remote.serverResearchMaxDocuments > 0
      ? { serverResearchMaxDocuments: remote.serverResearchMaxDocuments }
      : {}),
  };
}

function normalizeLibraryInteger(
  value: unknown,
  fallback: number,
  minimum: number,
): number {
  return typeof value === "number" &&
    Number.isInteger(value) &&
    value >= minimum
    ? value
    : fallback;
}

function normalizeLibraryNumber(
  value: unknown,
  fallback: number,
  minimum: number,
): number {
  return typeof value === "number" && Number.isFinite(value) && value >= minimum
    ? value
    : fallback;
}

function mergeTransportRules(
  remote:
    Partial<Record<RelayTransportKey, Partial<RelayTransportRule>>> | undefined,
): Record<RelayTransportKey, RelayTransportRule> {
  const merged = { ...DEFAULT_RELAY_RUNTIME_CONFIG.transportRules };
  if (!remote) return merged;
  for (const key of Object.keys(merged) as RelayTransportKey[]) {
    const override = remote[key];
    if (!override) continue;
    merged[key] = {
      providerPriority:
        override.providerPriority ?? merged[key].providerPriority,
      defaultAuthMode: override.defaultAuthMode ?? merged[key].defaultAuthMode,
      defaultVersion: override.defaultVersion ?? merged[key].defaultVersion,
      acceptedVersions:
        Array.isArray(override.acceptedVersions) &&
        override.acceptedVersions.length > 0
          ? override.acceptedVersions
          : merged[key].acceptedVersions,
      headerProfile: override.headerProfile ?? merged[key].headerProfile,
      codexIdentityDefault:
        override.codexIdentityDefault ?? merged[key].codexIdentityDefault,
      webSearchToolName:
        override.webSearchToolName ?? merged[key].webSearchToolName,
      imageRoute: override.imageRoute ?? merged[key].imageRoute,
      forceStreamForImageGeneration:
        override.forceStreamForImageGeneration ??
        merged[key].forceStreamForImageGeneration,
    };
  }
  return merged;
}

function mergeTransportEnvelopes(
  remote:
    | Partial<Record<RelayTransportKey, Partial<RelayTransportEnvelope>>>
    | undefined,
): Record<RelayTransportKey, RelayTransportEnvelope> {
  const merged = { ...DEFAULT_RELAY_RUNTIME_CONFIG.transportEnvelopes };
  if (!remote) return merged;
  for (const key of Object.keys(merged) as RelayTransportKey[]) {
    const override = remote[key];
    if (!override) continue;
    merged[key] = {
      image: override.image ?? merged[key].image,
      nativeFile: override.nativeFile ?? merged[key].nativeFile,
      textFileInline: override.textFileInline ?? merged[key].textFileInline,
      webSearch: override.webSearch ?? merged[key].webSearch,
      imageGeneration: override.imageGeneration ?? merged[key].imageGeneration,
      reasoning: override.reasoning ?? merged[key].reasoning,
    };
  }
  return merged;
}

/** Force a fresh read of the metadata, for cases such as a provider resync that need the latest data. */
export async function refreshMetadata(): Promise<void> {
  await fetchMetadata();
}

/**
 * Whether the startup chain should block on a metadata refresh.
 *
 * `initMetadata()` already handles a cold cache, an expired cache and background confirmation of a
 * fresh one. Bootstrap therefore blocks only when the in-memory snapshot is missing or the last
 * successful write or confirmation is older than the TTL, so an already usable IndexedDB snapshot
 * is not pushed back onto the startup critical path on every auth hydrate. An explicit provider
 * resync still calls {@link refreshMetadata} directly and ignores this TTL.
 */
export function isMetadataRefreshDue(): boolean {
  if (!cached || cachedAt === null) return true;
  const age = Date.now() - cachedAt;
  return age < 0 || age >= CACHE_TTL;
}

export function getMetadataVersion(): number | null {
  return cached?.version ?? null;
}

/**
 * Revision identifier for the current metadata snapshot, used for capability evidence and negative
 * cache partitioning. It is the same value `resolveModelMetadata` writes into `metadataRevision`:
 * **only the HTTP ETag counts**, never a snapshot version standing in for one. Without an ETag it
 * stays empty so consumers fail closed.
 */
export function getMetadataRevision(): string | undefined {
  return cachedETag ?? undefined;
}

/**
 * Returns the `contractVersion` of the current metadata; a missing value is treated as 1, the
 * initial published value. Callers use `isContractVersionDegraded()` in metadata-runtime.ts to
 * decide whether degrading is safe.
 */
export function getMetadataContractVersion(): number | null {
  if (!cached) return null;
  return (
    (cached as MetadataResponse & { contractVersion?: number })
      .contractVersion ?? 1
  );
}

/** Returns the capability contract version; absent means v1 compatibility semantics. */
export function getCapabilityContractVersion(): number | null {
  return cached?.capabilityContractVersion ?? null;
}

export function getRuntimeConfig(): ClientRuntimeConfig | null {
  return normalizeClientRuntimeConfig(cached?.runtimeConfig);
}

export function isRuntimeFeatureEnabled(key: string): boolean {
  const normalizedKey = key.trim();
  if (!normalizedKey) return true;
  return getRuntimeConfig()?.featureFlags[normalizedKey] !== false;
}

/**
 * Synchronously returns the in-memory metadata snapshot for catalog-resolver.
 * Its shape is compatible with CatalogMetadataInput by duck typing.
 */
export function getMetadataSnapshot(): ReturnType<typeof projectMetadataSnapshot> | null {
  const source = cached;
  if (!source) return null;
  if (projectedMetadataSource === source && projectedMetadataSnapshot) {
    return projectedMetadataSnapshot;
  }

  const projection = projectMetadataSnapshot(source);
  projectedMetadataSource = source;
  projectedMetadataSnapshot = projection;
  return projection;
}

function projectMetadataSnapshot(source: MetadataResponse): {
  capabilityContractVersion?: number;
  capabilityRuntime?: CapabilityRuntimeEnvelope;
  providers: Record<
    string,
    {
      defaultModelId?: string;
      models: Record<
        string,
        {
          canonicalModelId?: string;
          aliases?: string[];
          displayName?: string;
          contextLength?: number;
          billingSku?: string;
          pricingUnit?: string;
          sourceSummary?: {
            sourceKind: string;
            sourceName: string;
            fetchedAt: string;
          };
          pricing?: {
            promptPerMToken: number | null;
            completionPerMToken: number | null;
            cachedInputPerMToken?: number | null;
            costPerUnit?: number | null;
            costInputBatches?: number | null;
            costOutputBatches?: number | null;
            costInputPriority?: number | null;
            costOutputPriority?: number | null;
            cacheReadInputPerMToken?: number | null;
            cacheCreationInputPerMToken?: number | null;
            cacheWrite5mPerMToken?: number | null;
            cacheWrite1hPerMToken?: number | null;
          };
          pricingStatus?: ModelPricingStatus;
          capabilities?: string[];
          toolCall?: boolean | null;
          libraryAgentic?: boolean | null;
          supportsPdfInput?: boolean;
          supportsServiceTier?: boolean;
          profiles?: {
            reasoning?: string | null;
            webSearch?: string | null;
            imageGen?: string | null;
            generation?: {
              template?: string;
              revision?: string;
              parameters?: Array<{ id?: string; support?: string; source?: string }>;
            };
          };
          capabilityControls?: Record<string, CapabilityControl>;
          uiHints?: {
            groupKey?: string;
            groupName?: string;
            rank?: number;
            recommended?: boolean;
            badgeOrder?: string[];
          };
          /** Provider capability spec v2 sections 5.1.8 and 8.4: passed through to catalog filtering. */
          transport?: string;
          minClientVersion?: string;
          capabilityEvidenceCandidates?: CapabilityEvidenceCandidateView[];
          capabilityEvidenceOwnedKeys?: string[];
          capabilityEvidenceViewMalformed?: boolean;
          /** Comes only from the current HTTP ETag; never derived from the snapshot version. */
          metadataRevision?: string;
        }
      >;
    }
  >;
} {
  return {
    capabilityContractVersion: source.capabilityContractVersion,
    ...(source.capabilityRuntime ? { capabilityRuntime: source.capabilityRuntime } : {}),
    providers: Object.fromEntries(
      Object.entries(source.providers).map(([providerKind, provider]) => [
        providerKind,
        {
          ...provider,
          models: Object.fromEntries(
            Object.entries(provider.models).map(([modelId, model]) => {
              const {
                capabilityEvidenceView: rawCapabilityEvidenceView,
                capabilityEvidenceCandidates: persistedCandidates,
                capabilityEvidenceOwnedKeys: _persistedOwnedKeys,
                capabilityEvidenceViewMalformed: _persistedMalformed,
                ...modelWithoutEvidenceNamespaces
              } = model;
              const safeModel = allowlistedMetadataModelFields(
                modelWithoutEvidenceNamespaces,
              );
              const projectedProfiles = safeModel.profiles?.generation
                ? {
                    ...safeModel.profiles,
                    generation: normalizeGenerationProfile(
                      safeModel.profiles.generation,
                      source.generationParameterTables,
                    ),
                  }
                : safeModel.profiles;
              const evidenceContext = {
                providerKind,
                modelId,
                transport: model.transport,
                metadataRevision: cachedETag ?? undefined,
                lean: source.view === "lean",
              };
              const candidates = rawCapabilityEvidenceView !== undefined
                ? decodeCapabilityEvidenceView(rawCapabilityEvidenceView, evidenceContext)
                : decodePersistedCapabilityEvidenceCandidates(
                    persistedCandidates,
                    evidenceContext,
                  );
              const ownedKeys = decodeModelCapabilityEvidenceOwnedKeys(model, evidenceContext.lean);
              const viewMalformed = decodeModelCapabilityEvidenceViewMalformed(model, evidenceContext.lean);
              return [
                modelId,
                {
                  ...safeModel,
                  ...(projectedProfiles ? { profiles: projectedProfiles } : {}),
                  ...(candidates !== undefined
                    ? { capabilityEvidenceCandidates: candidates }
                    : {}),
                  ...(ownedKeys !== undefined
                    ? { capabilityEvidenceOwnedKeys: ownedKeys }
                    : {}),
                  ...(viewMalformed !== undefined
                    ? { capabilityEvidenceViewMalformed: viewMalformed }
                    : {}),
                  ...(cachedETag ? { metadataRevision: cachedETag } : {}),
                },
              ];
            }),
          ),
        },
      ]),
    ),
  };
}

/** Exact v2 recipe envelope for client presentation; missing means no automatic configuration. */
export function getCapabilityRuntime(): CapabilityRuntimeEnvelope | null {
  return cached?.capabilityRuntime ?? null;
}

export function listProviderModelIds(
  providerKind: ProviderKind | string,
): string[] {
  const provider = resolveProviderData(providerKind);
  if (!provider) return [];
  return Object.keys(provider.models).sort();
}

export function getProviderDefaultModelId(
  providerKind: ProviderKind | string,
): string | undefined {
  return resolveProviderData(providerKind)?.defaultModelId;
}

export function getProviderValidation(
  providerKind: ProviderKind | string,
): ProviderValidation | undefined {
  return resolveProviderData(providerKind)?.validation;
}

export function getProviderAttachmentSupport(
  providerKind: ProviderKind | string,
): ProviderAttachmentSupport | null {
  return resolveProviderData(providerKind)?.attachmentSupport ?? null;
}

/**
 * The display side of reasoning levels. The chat view's level picker calls this rather than
 * `resolveSupportedReasoningModes` in packages/core, and the two must agree word for word: the
 * injection side injects nothing when it cannot find the profile, so a display side that still
 * offered all five levels would show five purely decorative options.
 *
 * There are exactly two API-shaped differences from the runtime.ts version, and changing one means
 * changing the other:
 *   - the `metadata` parameter becomes this module's `cached` snapshot, so `!cached` is `!metadata`
 *   - `!profileName` becomes `!normalizeProfileRef(profileName)`, because this module is the
 *     boundary layer that reads raw JSON and trims everywhere (a blank string counts as absent),
 *     while runtime.ts already receives a normalized name
 */
export function getSupportedReasoningModes(
  profileName: NullableString,
): ReasoningMode[] {
  const normalizedProfile = normalizeProfileRef(profileName);
  // A missing profileName means the catalog gave this model no reasoning profile at all, and **that
  // is the normal case for relay**: catalog.providers has no relay key, so resolveCatalogModel
  // always misses and levels fall back to relay's local mapping. Narrowing here would let
  // clampReasoningMode clamp the user's choice back to automatic, and relay's reasoning_effort
  // would disappear. Only official providers are narrowed; this branch stays fail-open.
  // An empty `cached` behaves the same way, matching `!metadata` in runtime.ts.
  if (!cached || !normalizedProfile) {
    return REASONING_MODE_ORDER;
  }

  // A profile name that is not in the profile table (withdrawn, or this snapshot is stale), or a
  // profile with no declared levels: the injection side returns null here, so the display side must
  // collapse to Auto only.
  const levels = cached.profiles?.reasoning?.[normalizedProfile]?.levels;
  if (!levels || levels.length === 0) {
    return ["automatic"];
  }

  const supported = NON_AUTO_REASONING_MODES.filter((mode) =>
    levels.includes(mode),
  );
  if (supported.length === 0) {
    return ["automatic"];
  }

  return ["automatic", ...supported];
}

/**
 * Strict metadata declaration for evidence adapters. Unlike the UI-facing
 * `getSupportedReasoningModes`, this never provides a Relay/cold-start
 * fallback: absent profile data is an empty evidence set, hence unknown.
 */
export function getDeclaredReasoningLevels(
  profileName: NullableString,
): ReasoningMode[] {
  const normalizedProfile = normalizeProfileRef(profileName);
  if (!cached || !normalizedProfile) return [];
  const levels = cached.profiles?.reasoning?.[normalizedProfile]?.levels;
  if (!levels || levels.length === 0) return [];
  return NON_AUTO_REASONING_MODES.filter((mode) => levels.includes(mode));
}

/** Strict production default; missing, unknown, or undeclared values stay absent. */
export function getDeclaredReasoningDefaultLevel(
  profileName: NullableString,
): ReasoningMode | undefined {
  const normalizedProfile = normalizeProfileRef(profileName);
  if (!cached || !normalizedProfile) return undefined;
  const profile = cached.profiles?.reasoning?.[normalizedProfile];
  const defaultLevel = profile?.defaultLevel?.trim();
  if (!defaultLevel || !NON_AUTO_REASONING_MODES.includes(defaultLevel as ReasoningMode)) {
    return undefined;
  }
  return profile?.levels?.includes(defaultLevel)
    ? defaultLevel as ReasoningMode
    : undefined;
}

export function clampReasoningMode(
  mode: ReasoningMode,
  profileName: NullableString,
): ReasoningMode {
  const supportedModes = getSupportedReasoningModes(profileName);
  if (supportedModes.includes(mode)) {
    return mode;
  }

  const modeIndex = REASONING_MODE_ORDER.indexOf(mode);
  for (let index = modeIndex - 1; index >= 0; index -= 1) {
    const candidate = REASONING_MODE_ORDER[index];
    if (supportedModes.includes(candidate)) {
      return candidate;
    }
  }

  return "automatic";
}

export function listPublicProviderConfigs(): PublicProviderConfig[] {
  if (!cached?.providerConfigs) return [];
  return [...cached.providerConfigs].sort(compareProviderConfigs);
}

export function hasPublicProviderConfigSource(): boolean {
  return Array.isArray(cached?.providerConfigs);
}

export function getPublicProviderConfig(
  providerKind: ProviderKind | string,
): PublicProviderConfig | null {
  const backendKind = KIND_MAP[providerKind] ?? providerKind;
  return (
    listPublicProviderConfigs().find((config) => config.kind === backendKind) ??
    null
  );
}

export function getRelayProbePolicy(): RelayProbePolicy | null {
  const raw = getPublicProviderConfig("relay")?.protocolFeatures?.probePolicy;
  return normalizeRelayProbePolicy(raw);
}

/**
 * Availability of the Grok subscription sign-in, as a tri-state.
 *
 * "Not declared" and "deliberately switched off" are different: the first should hide the entry
 * point entirely, while the second must relay `disabledNotice` to already connected users rather
 * than failing silently.
 */
export function getGrokSubscriptionAvailability(): GrokSubscriptionAvailability {
  return resolveGrokSubscriptionAuth(
    getPublicProviderConfig("grok")?.protocolFeatures?.subscriptionAuth,
    { appVersion: APP_VERSION, platform: "web" },
  );
}

/** Subscription config when available; `null` means it is not declared or has been switched off by the kill switch. */
export function getGrokSubscriptionAuthConfig(): GrokSubscriptionAuthConfig | null {
  const availability = getGrokSubscriptionAvailability();
  return availability.state === "available" ? availability.config : null;
}

/**
 * Availability of the Codex ChatGPT subscription sign-in, as a tri-state.
 *
 * Kept separate from the Grok pair rather than generalized into one function: the two flows differ
 * in `flow` version bits, required fields and host allowlist, so merging them would mean every new
 * field on one side has to touch the other side's checks, and a branch would eventually be missed.
 */
export function getOpenAISubscriptionAvailability(): OpenAISubscriptionAvailability {
  return resolveOpenAISubscriptionAuth(
    getPublicProviderConfig("openAI")?.protocolFeatures?.subscriptionAuth,
    { appVersion: APP_VERSION, platform: "web" },
  );
}

/** Codex subscription config when available; `null` means it is not declared or has been switched off by the kill switch. */
export function getOpenAISubscriptionAuthConfig(): OpenAISubscriptionAuthConfig | null {
  const availability = getOpenAISubscriptionAvailability();
  return availability.state === "available" ? availability.config : null;
}

function resolveModelEntry(
  modelID: string,
  providerKind: ProviderKind | string,
): {
  treeModelId: string;
  canonicalModelId: string;
  model: ModelMetadata;
  provider: ProviderData;
  providerKind: string;
  generationParameterTables?: MetadataResponse["generationParameterTables"];
} | null {
  const source = cached;
  if (!source) return null;
  const resolvedProviderKind = KIND_MAP[providerKind] ?? providerKind;
  const provider = source.providers[resolvedProviderKind];
  if (!provider?.models) return null;

  // resolveMap is the only authority for aliases/date-suffix normalization.
  // A minimal lean fixture can omit it and still address an exact models key,
  // but the client must not revive the retired local alias inference.
  const canonicalModelId = provider.resolveMap
    ? lookupCandidates(modelID)
        .map(
          (candidate) =>
            provider.resolveMap?.[candidate] ??
            (provider.models[candidate] ? candidate : null),
        )
        .find((candidate): candidate is string => Boolean(candidate))
    : provider.models[modelID]
      ? modelID
      : null;
  if (!canonicalModelId) return null;

  const model = provider.models[canonicalModelId];
  if (!model) return null;

  return {
    treeModelId: canonicalModelId,
    canonicalModelId: model.canonicalModelId ?? canonicalModelId,
    model,
    provider,
    providerKind: resolvedProviderKind,
    generationParameterTables: source.generationParameterTables,
  };
}

function resolveProviderData(
  providerKind: ProviderKind | string,
): ProviderData | null {
  if (!cached) return null;

  const backendKind = KIND_MAP[providerKind] ?? providerKind;
  return cached.providers[backendKind] ?? null;
}

function normalizeRelayProbePolicy(raw: unknown): RelayProbePolicy | null {
  if (!isRecord(raw)) return null;

  const version = normalizePositiveInteger(raw.version);
  const defaultFamilyHint = normalizeFamilyHint(raw.defaultFamilyHint);
  const apiRootCandidates = normalizeAPIRootCandidates(raw.apiRootCandidates);
  const preflightFingerprints = normalizePreflightFingerprints(
    raw.preflightFingerprints,
  );
  const catalogDiscovery = normalizeCatalogDiscovery(raw.catalogDiscovery);
  const transportOrder = normalizeTransportOrder(raw.transportOrder);
  const fallbackPolicy = normalizeFallbackPolicy(raw.fallbackPolicy);
  const probeBudget = normalizeProbeBudget(raw.probeBudget);
  const stopRules = normalizeStopRules(raw.stopRules);
  const userAgent = normalizeUserAgent(raw.userAgent);

  if (
    version == null ||
    defaultFamilyHint == null ||
    apiRootCandidates == null ||
    preflightFingerprints == null ||
    catalogDiscovery == null ||
    transportOrder == null ||
    fallbackPolicy == null ||
    probeBudget == null ||
    stopRules == null ||
    userAgent == null
  ) {
    return null;
  }

  return {
    version,
    defaultFamilyHint,
    apiRootCandidates,
    preflightFingerprints,
    catalogDiscovery,
    transportOrder,
    transportSteps: Array.isArray(raw.transportSteps)
      ? raw.transportSteps.filter(isRecord)
      : [],
    failureFingerprints: Array.isArray(raw.failureFingerprints)
      ? raw.failureFingerprints.filter(isRecord)
      : [],
    fallbackPolicy,
    probeBudget,
    stopRules,
    userAgent,
  };
}

function lookupCandidates(modelID: string): string[] {
  const trimmed = modelID.trim();
  if (!trimmed) return [];

  const normalized = SNAPSHOT_DATE_PATTERNS.reduce(
    (current, pattern) => current.replace(pattern, ""),
    trimmed,
  );

  return normalized === trimmed ? [trimmed] : [trimmed, normalized];
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return (
    value != null && typeof value === "object" && Array.isArray(value) === false
  );
}

const DEFAULT_CLIENT_RUNTIME_CONFIG: ClientRuntimeConfig = {
  featureFlags: {},
  appGate: {
    ios: { minSupportedBuild: 0, storeUrl: "", message: "" },
    android: { minSupportedBuild: 0, storeUrl: "", message: "" },
    maintenanceBanner: { id: "", text: "", level: "info" },
  },
  freeAccessGrant: {
    limits: {
      customSkills: 2,
      pinnedSkills: 2,
      pinnedConversations: 2,
      folders: 2,
      syncDevices: 1,
      storageBytes: 0,
      singleFileBytes: 25 * 1024 * 1024,
    },
    features: {},
  },
  selfHealPatterns: [],
  networkPolicy: {
    chatTimeoutSecs: 60,
    streamTimeoutSecs: 120,
    imageGenTimeoutSecs: 180,
    keyValidationTimeoutSecs: 18,
    upstreamFirstByteTimeoutSecs: 120,
  },
  promptBudget: {
    totalChars: 12000,
    pinnedNotesMaxCount: 3,
    pinnedNotesBudgetChars: 6000,
    noteRecallLimit: 2,
  },
  attachment: {
    maxFiles: 3,
    maxNativeBytesByProvider: {
      default: 25 * 1024 * 1024,
      openAI: 25 * 1024 * 1024,
      anthropic: 25 * 1024 * 1024,
      gemini: 20 * 1024 * 1024,
    },
  },
  budgetAlert: { thresholds: [50, 70, 80, 90], debounceMins: 30 },
};

function normalizeClientRuntimeConfig(
  raw: unknown,
): ClientRuntimeConfig | null {
  if (!isRecord(raw)) return null;
  const defaults = DEFAULT_CLIENT_RUNTIME_CONFIG;
  const appGate = isRecord(raw.appGate) ? raw.appGate : {};
  const freeAccessGrant = isRecord(raw.freeAccessGrant)
    ? raw.freeAccessGrant
    : {};
  const freeLimits = isRecord(freeAccessGrant.limits)
    ? freeAccessGrant.limits
    : {};
  const networkPolicy = isRecord(raw.networkPolicy) ? raw.networkPolicy : {};
  const promptBudget = isRecord(raw.promptBudget) ? raw.promptBudget : {};
  const attachment = isRecord(raw.attachment) ? raw.attachment : {};
  const budgetAlert = isRecord(raw.budgetAlert) ? raw.budgetAlert : null;

  return {
    featureFlags: normalizeBooleanRecord(raw.featureFlags),
    appGate: {
      ios: normalizeRuntimePlatformGate(appGate.ios, defaults.appGate.ios),
      android: normalizeRuntimePlatformGate(
        appGate.android,
        defaults.appGate.android,
      ),
      maintenanceBanner: normalizeRuntimeBanner(appGate.maintenanceBanner),
    },
    freeAccessGrant: {
      limits: {
        customSkills: normalizeFiniteNumber(
          freeLimits.customSkills,
          defaults.freeAccessGrant.limits.customSkills,
        ),
        pinnedSkills: normalizeFiniteNumber(
          freeLimits.pinnedSkills,
          defaults.freeAccessGrant.limits.pinnedSkills,
        ),
        pinnedConversations: normalizeFiniteNumber(
          freeLimits.pinnedConversations,
          defaults.freeAccessGrant.limits.pinnedConversations,
        ),
        folders: normalizeFiniteNumber(
          freeLimits.folders,
          defaults.freeAccessGrant.limits.folders,
        ),
        syncDevices: normalizeFiniteNumber(
          freeLimits.syncDevices,
          defaults.freeAccessGrant.limits.syncDevices,
        ),
        storageBytes: normalizeFiniteNumber(
          freeLimits.storageBytes,
          defaults.freeAccessGrant.limits.storageBytes,
        ),
        singleFileBytes: normalizeFiniteNumber(
          freeLimits.singleFileBytes,
          defaults.freeAccessGrant.limits.singleFileBytes,
        ),
      },
      features: normalizeBooleanRecord(freeAccessGrant.features),
    },
    selfHealPatterns: normalizeRuntimePatterns(raw.selfHealPatterns),
    networkPolicy: {
      chatTimeoutSecs: normalizeFiniteNumber(
        networkPolicy.chatTimeoutSecs,
        defaults.networkPolicy.chatTimeoutSecs,
      ),
      streamTimeoutSecs: normalizeFiniteNumber(
        networkPolicy.streamTimeoutSecs,
        defaults.networkPolicy.streamTimeoutSecs,
      ),
      imageGenTimeoutSecs: normalizeFiniteNumber(
        networkPolicy.imageGenTimeoutSecs,
        defaults.networkPolicy.imageGenTimeoutSecs,
      ),
      keyValidationTimeoutSecs: normalizeFiniteNumber(
        networkPolicy.keyValidationTimeoutSecs,
        defaults.networkPolicy.keyValidationTimeoutSecs,
      ),
      upstreamFirstByteTimeoutSecs: normalizeFiniteNumber(
        networkPolicy.upstreamFirstByteTimeoutSecs,
        defaults.networkPolicy.upstreamFirstByteTimeoutSecs,
      ),
    },
    promptBudget: {
      totalChars: normalizeFiniteNumber(
        promptBudget.totalChars,
        defaults.promptBudget.totalChars,
      ),
      pinnedNotesMaxCount: normalizeFiniteNumber(
        promptBudget.pinnedNotesMaxCount,
        defaults.promptBudget.pinnedNotesMaxCount,
      ),
      pinnedNotesBudgetChars: normalizeFiniteNumber(
        promptBudget.pinnedNotesBudgetChars,
        defaults.promptBudget.pinnedNotesBudgetChars,
      ),
      noteRecallLimit: normalizeFiniteNumber(
        promptBudget.noteRecallLimit,
        defaults.promptBudget.noteRecallLimit,
      ),
    },
    attachment: {
      maxFiles: normalizeFiniteNumber(
        attachment.maxFiles,
        defaults.attachment.maxFiles,
      ),
      maxNativeBytesByProvider:
        Object.keys(normalizeNumberRecord(attachment.maxNativeBytesByProvider))
          .length > 0
          ? normalizeNumberRecord(attachment.maxNativeBytesByProvider)
          : { ...defaults.attachment.maxNativeBytesByProvider },
    },
    budgetAlert: budgetAlert
      ? {
          thresholds: normalizeRuntimeThresholds(
            budgetAlert.thresholds,
            defaults.budgetAlert?.thresholds ?? [],
          ),
          debounceMins: normalizeFiniteNumber(
            budgetAlert.debounceMins,
            defaults.budgetAlert?.debounceMins ?? 30,
          ),
        }
      : defaults.budgetAlert,
    updatedAt: typeof raw.updatedAt === "string" ? raw.updatedAt : undefined,
  };
}

function normalizeRuntimePlatformGate(
  raw: unknown,
  defaults: ClientRuntimePlatformGate,
): ClientRuntimePlatformGate {
  const value = isRecord(raw) ? raw : {};
  return {
    minSupportedBuild: Math.max(
      0,
      normalizeFiniteNumber(
        value.minSupportedBuild,
        defaults.minSupportedBuild,
      ),
    ),
    storeUrl:
      typeof value.storeUrl === "string" ? value.storeUrl : defaults.storeUrl,
    message:
      typeof value.message === "string" ? value.message : defaults.message,
  };
}

function normalizeRuntimeBanner(
  raw: unknown,
): ClientRuntimeConfig["appGate"]["maintenanceBanner"] {
  const value = isRecord(raw) ? raw : {};
  return {
    id: typeof value.id === "string" ? value.id : "",
    text: typeof value.text === "string" ? value.text : "",
    level: value.level === "warn" ? "warn" : "info",
  };
}

function normalizeRuntimePatterns(
  raw: unknown,
): ClientRuntimeConfig["selfHealPatterns"] {
  if (!Array.isArray(raw)) return [];
  return raw.flatMap((item) => {
    if (
      !isRecord(item) ||
      typeof item.pattern !== "string" ||
      !item.pattern.trim()
    )
      return [];
    const flags = item.flags === "i" ? "i" : undefined;
    // param is passed through as-is when it is a non-empty string; shape validation is left
    // to the consumer (@oriveo/core setUnsupportedParamPatterns) so the two checks cannot drift.
    const param =
      typeof item.param === "string" && item.param.trim()
        ? item.param.trim()
        : undefined;
    return [
      {
        pattern: item.pattern,
        ...(flags ? { flags } : {}),
        ...(param ? { param } : {}),
      },
    ];
  });
}

function normalizeRuntimeThresholds(
  raw: unknown,
  defaults: number[],
): number[] {
  if (!Array.isArray(raw)) return [...defaults];
  const values = raw.filter(
    (item): item is number =>
      typeof item === "number" &&
      Number.isFinite(item) &&
      item > 0 &&
      item <= 100,
  );
  return values.length > 0 ? values : [...defaults];
}

function normalizeBooleanRecord(raw: unknown): Record<string, boolean> {
  if (!isRecord(raw)) return {};
  return Object.fromEntries(
    Object.entries(raw).filter(
      (entry): entry is [string, boolean] => typeof entry[1] === "boolean",
    ),
  );
}

function normalizeNumberRecord(raw: unknown): Record<string, number> {
  if (!isRecord(raw)) return {};
  return Object.fromEntries(
    Object.entries(raw).filter(
      (entry): entry is [string, number] =>
        typeof entry[1] === "number" && Number.isFinite(entry[1]),
    ),
  );
}

function normalizeFiniteNumber(value: unknown, fallback: number): number {
  return typeof value === "number" && Number.isFinite(value) ? value : fallback;
}

function normalizePositiveInteger(value: unknown): number | null {
  return typeof value === "number" && Number.isInteger(value) && value > 0
    ? value
    : null;
}

function normalizeBoolean(value: unknown): boolean | null {
  return typeof value === "boolean" ? value : null;
}

function normalizeFamilyHint(
  value: unknown,
): RelayProbePolicy["defaultFamilyHint"] | null {
  return value === "openai" ||
    value === "anthropic" ||
    value === "gemini" ||
    value === "unknown"
    ? value
    : null;
}

function normalizePriority(value: unknown): ProbeCandidatePriority | null {
  return value === "default" || value === "extended" || value === "scenario"
    ? value
    : null;
}

function normalizeAPIRootCandidates(
  raw: unknown,
): RelayProbeAPIRootCandidate[] | null {
  if (!Array.isArray(raw) || raw.length === 0) return null;

  const candidates = raw.flatMap((value) => {
    if (!isRecord(value)) return [];
    const rootPath =
      typeof value.rootPath === "string" ? value.rootPath.trim() : "";
    const priority = normalizePriority(value.priority);
    if (!rootPath.startsWith("/") || priority == null) return [];
    return [{ rootPath, priority }];
  });

  return candidates.length > 0 ? candidates : null;
}

function normalizePreflightFingerprints(
  raw: unknown,
): RelayProbePreflightFingerprint[] | null {
  if (!Array.isArray(raw)) return null;

  const fingerprints = raw.flatMap<RelayProbePreflightFingerprint>((value) => {
    if (!isRecord(value)) return [];
    const name = typeof value.name === "string" ? value.name.trim() : "";
    const path = typeof value.path === "string" ? value.path.trim() : "";
    const method =
      value.method === "GET" ||
      value.method === "HEAD" ||
      value.method === "POST"
        ? value.method
        : null;
    const inferApiRoot =
      typeof value.inferApiRoot === "string" ? value.inferApiRoot.trim() : "";
    const inferTransports = Array.isArray(value.inferTransports)
      ? value.inferTransports.filter(
          (item): item is string =>
            typeof item === "string" && item.trim().length > 0,
        )
      : [];

    if (
      name.length === 0 ||
      path.length === 0 ||
      inferApiRoot.startsWith("/") === false ||
      inferTransports.length === 0 ||
      method == null
    ) {
      return [];
    }

    return [
      {
        name,
        path,
        method,
        inferApiRoot,
        inferTransports,
        inferAuthMode:
          typeof value.inferAuthMode === "string"
            ? value.inferAuthMode
            : undefined,
      },
    ];
  });

  return fingerprints;
}

function normalizeCatalogDiscovery(
  raw: unknown,
): RelayProbeCatalogStep[] | null {
  if (!Array.isArray(raw)) return null;

  const steps = raw.flatMap((value) => {
    if (!isRecord(value)) return [];
    const kind = typeof value.kind === "string" ? value.kind.trim() : "";
    const path = typeof value.path === "string" ? value.path.trim() : "";
    const authModes = Array.isArray(value.authModes)
      ? value.authModes.filter(
          (item): item is string =>
            typeof item === "string" && item.trim().length > 0,
        )
      : [];
    if (
      kind.length === 0 ||
      path.startsWith("/") === false ||
      authModes.length === 0
    )
      return [];
    return [{ kind, path, authModes }];
  });

  return steps;
}

function normalizeTransportOrder(
  raw: unknown,
): RelayProbePolicy["transportOrder"] | null {
  if (!isRecord(raw)) return null;
  const normalizeList = (value: unknown): string[] | null =>
    Array.isArray(value)
      ? value.filter(
          (item): item is string =>
            typeof item === "string" && item.trim().length > 0,
        )
      : null;

  const openai = normalizeList(raw.openai);
  const anthropic = normalizeList(raw.anthropic);
  const gemini = normalizeList(raw.gemini);
  const unknown = normalizeList(raw.unknown);
  if (openai == null || anthropic == null || gemini == null || unknown == null)
    return null;

  return { openai, anthropic, gemini, unknown };
}

function normalizeFallbackPolicy(
  raw: unknown,
): RelayProbePolicy["fallbackPolicy"] | null {
  if (!isRecord(raw)) return null;
  const allowManualModel = normalizeBoolean(raw.allowManualModel);
  const requireCatalogBeforeManual = normalizeBoolean(
    raw.requireCatalogBeforeManual,
  );
  if (allowManualModel == null || requireCatalogBeforeManual == null)
    return null;
  return { allowManualModel, requireCatalogBeforeManual };
}

function normalizeProbeBudget(
  raw: unknown,
): RelayProbePolicy["probeBudget"] | null {
  if (!isRecord(raw)) return null;

  const maxConcurrency = normalizePositiveInteger(raw.maxConcurrency);
  const maxPreflightRequests = normalizePositiveInteger(
    raw.maxPreflightRequests,
  );
  const maxCatalogRequests = normalizePositiveInteger(raw.maxCatalogRequests);
  const maxHandshakeAttempts = normalizePositiveInteger(
    raw.maxHandshakeAttempts,
  );
  const maxDurationMs = normalizePositiveInteger(raw.maxDurationMs);
  const abortOnRateLimit = normalizeBoolean(raw.abortOnRateLimit);
  if (
    maxConcurrency == null ||
    maxPreflightRequests == null ||
    maxCatalogRequests == null ||
    maxHandshakeAttempts == null ||
    maxDurationMs == null ||
    abortOnRateLimit == null
  ) {
    return null;
  }

  return {
    maxConcurrency,
    maxPreflightRequests,
    maxCatalogRequests,
    maxHandshakeAttempts,
    maxDurationMs,
    abortOnRateLimit,
  };
}

function normalizeStopRules(
  raw: unknown,
): RelayProbePolicy["stopRules"] | null {
  if (!isRecord(raw)) return null;
  const stopOnFirstTransportSuccess = normalizeBoolean(
    raw.stopOnFirstTransportSuccess,
  );
  const stopOnAuthFailure = normalizeBoolean(raw.stopOnAuthFailure);
  const stopOnCliOnlyFingerprint = normalizeBoolean(
    raw.stopOnCliOnlyFingerprint,
  );
  const stopOnBudgetExceeded = normalizeBoolean(raw.stopOnBudgetExceeded);
  if (
    stopOnFirstTransportSuccess == null ||
    stopOnAuthFailure == null ||
    stopOnCliOnlyFingerprint == null ||
    stopOnBudgetExceeded == null
  ) {
    return null;
  }

  return {
    stopOnFirstTransportSuccess,
    stopOnAuthFailure,
    stopOnCliOnlyFingerprint,
    stopOnBudgetExceeded,
  };
}

function normalizeUserAgent(
  raw: unknown,
): RelayProbePolicy["userAgent"] | null {
  if (!isRecord(raw)) return null;
  const template = typeof raw.template === "string" ? raw.template.trim() : "";
  const applyOn = raw.applyOn;
  if (template.length === 0 || applyOn !== "native_only") return null;
  return { template, applyOn };
}

function normalizeCapabilities(
  capabilities: string[] | undefined,
  badgeOrder: string[] | undefined,
): string[] {
  // Keep every capability string, including unknown values such as 'native_pdf', for forward compatibility
  if (!capabilities || capabilities.length === 0) return [];

  if (!badgeOrder || badgeOrder.length === 0) return capabilities;

  // Known badge-displayed capabilities follow badgeOrder; unknown ones are appended at the end
  const hasText = capabilities.includes("text");
  const nonText = capabilities.filter((cap) => cap !== "text");
  nonText.sort((left, right) => {
    const leftIndex = badgeOrder.indexOf(left);
    const rightIndex = badgeOrder.indexOf(right);
    if (leftIndex === -1 && rightIndex === -1) return 0;
    if (leftIndex === -1) return 1;
    if (rightIndex === -1) return -1;
    return leftIndex - rightIndex;
  });

  return hasText ? ["text", ...nonText] : nonText;
}

const PUBLIC_CAPABILITY_EVIDENCE_SCHEMA = "capability-evidence-view/v1";
const PUBLIC_CAPABILITY_SUPPORT = new Set<CapabilityEvidenceCandidateView["support"]>([
  "supported",
  "unsupported",
  "unknown",
]);
const PUBLIC_CAPABILITY_SOURCE_GRADE: Record<
  CapabilityEvidenceCandidateView["source"],
  readonly CapabilityEvidenceCandidateView["grade"][]
> = {
  server_typed: ["machine_verified"],
  server_profile: ["effect_verified", "declared"],
  operator_override: ["operator"],
};
const PUBLIC_CAPABILITY_SUBKEY = /^[a-z][a-z0-9_]{0,63}$/;

interface CapabilityEvidenceDecodeContext {
  providerKind: string;
  modelId: string;
  transport: string | undefined;
  metadataRevision?: string;
  lean: boolean;
}

function isCapabilityEvidenceView(raw: unknown, lean: boolean): raw is Record<string, unknown> & {
  candidates: unknown[];
} {
  if (!isRecord(raw) || !Array.isArray(raw.candidates)) return false;
  // Full remains strict. Lean intentionally omits the redundant wrapper
  // schema, but also accepts it during a rolling server/client transition.
  return lean
    ? raw.schema === undefined || raw.schema === PUBLIC_CAPABILITY_EVIDENCE_SCHEMA
    : raw.schema === PUBLIC_CAPABILITY_EVIDENCE_SCHEMA;
}

/**
 * Decodes only the server's public v1 allowlist. Raw provenance never crosses
 * this boundary, and a malformed/forward-incompatible candidate is omitted
 * rather than promoted to a local fallback verdict.
 */
function decodeCapabilityEvidenceView(
  raw: unknown,
  context: CapabilityEvidenceDecodeContext,
): CapabilityEvidenceCandidateView[] | undefined {
  if (raw === undefined) return undefined;
  if (!isCapabilityEvidenceView(raw, context.lean)) return [];
  return decodeCapabilityEvidenceCandidateList(raw.candidates, context);
}

function decodeCapabilityEvidenceOwnedKeys(raw: unknown, lean: boolean): string[] | undefined {
  if (raw === undefined) return undefined;
  if (!isCapabilityEvidenceView(raw, lean)) return [];
  return uniquePublicCapabilityEvidenceKeys(raw.candidates);
}

function decodeCapabilityEvidenceViewMalformed(raw: unknown, lean: boolean): boolean | undefined {
  if (raw === undefined) return undefined;
  return !isCapabilityEvidenceView(raw, lean);
}

function decodePersistedCapabilityEvidenceOwnedKeys(
  raw: unknown,
  persistedCandidates: unknown,
): string[] | undefined {
  if (raw !== undefined) {
    return Array.isArray(raw)
      ? uniquePublicCapabilityEvidenceKeys(raw)
      : [];
  }
  if (persistedCandidates === undefined) return undefined;
  return Array.isArray(persistedCandidates)
    ? uniquePublicCapabilityEvidenceKeys(persistedCandidates)
    : [];
}

function uniquePublicCapabilityEvidenceKeys(values: unknown[]): string[] {
  return [...new Set(values.flatMap((value) => {
    if (typeof value === "string") {
      return isPublicCapabilityEvidenceKey(value) ? [value] : [];
    }
    if (!isRecord(value) || typeof value.key !== "string") return [];
    return isPublicCapabilityEvidenceKey(value.key) ? [value.key] : [];
  }))];
}

function decodeModelCapabilityEvidenceOwnedKeys(
  model: ModelMetadata,
  lean: boolean,
): string[] | undefined {
  if (model.capabilityEvidenceView !== undefined) {
    return decodeCapabilityEvidenceOwnedKeys(model.capabilityEvidenceView, lean);
  }
  if (model.capabilityEvidenceCandidates !== undefined
    || model.capabilityEvidenceOwnedKeys !== undefined) {
    return decodePersistedCapabilityEvidenceOwnedKeys(
      model.capabilityEvidenceOwnedKeys,
      model.capabilityEvidenceCandidates,
    );
  }
  return decodeCapabilityEvidenceOwnedKeys(model.capabilityEvidenceView, lean);
}

function decodeModelCapabilityEvidenceViewMalformed(
  model: ModelMetadata,
  lean: boolean,
): boolean | undefined {
  if (model.capabilityEvidenceView !== undefined) {
    return decodeCapabilityEvidenceViewMalformed(model.capabilityEvidenceView, lean);
  }
  if (typeof model.capabilityEvidenceViewMalformed === "boolean") {
    return model.capabilityEvidenceViewMalformed;
  }
  // A pre-field cache with a persisted namespace cannot prove that an empty
  // candidate array came from a valid empty view rather than a rejected one.
  return model.capabilityEvidenceCandidates !== undefined
    || model.capabilityEvidenceOwnedKeys !== undefined
    ? true
    : undefined;
}

/**
 * LocalStorage only ever holds this adapter's already-allowlisted output.
 * It is intentionally separate from the wire decoder so a bare candidates
 * array can never impersonate a server `capabilityEvidenceView` payload.
 */
function decodePersistedCapabilityEvidenceCandidates(
  raw: unknown,
  context: CapabilityEvidenceDecodeContext,
): CapabilityEvidenceCandidateView[] | undefined {
  if (raw === undefined) return undefined;
  if (!Array.isArray(raw)) return [];
  return decodeCapabilityEvidenceCandidateList(raw, context);
}

function decodeCapabilityEvidenceCandidateList(
  candidates: unknown[],
  context: CapabilityEvidenceDecodeContext,
): CapabilityEvidenceCandidateView[] {
  const transport = context.transport;
  if (!isSafeEvidenceString(context.providerKind)
    || !isSafeEvidenceString(context.modelId)
    || !isSafeEvidenceString(transport)) {
    return [];
  }

  return candidates.flatMap((candidate) => {
    const decoded = decodeCapabilityEvidenceCandidate(candidate, {
      ...context,
      transport,
    });
    return decoded ? [decoded] : [];
  });
}

function decodeCapabilityEvidenceCandidate(
  raw: unknown,
  context: {
    providerKind: string;
    modelId: string;
    transport: string;
    metadataRevision?: string;
    lean: boolean;
  },
): CapabilityEvidenceCandidateView | null {
  if (!isRecord(raw)) return null;

  const key = raw.key;
  const support = raw.support;
  const source = raw.source;
  const grade = raw.grade;
  const scope = raw.scope === undefined && context.lean
    ? "provider_model_transport"
    : raw.scope;
  const providerKind = raw.providerKind === undefined && context.lean
    ? context.providerKind
    : raw.providerKind;
  const modelId = raw.modelId === undefined && context.lean
    ? context.modelId
    : raw.modelId;
  const transport = raw.transport === undefined && context.lean
    ? context.transport
    : raw.transport;
  if (
    typeof key !== "string" || !isPublicCapabilityEvidenceKey(key)
    || typeof support !== "string" || !PUBLIC_CAPABILITY_SUPPORT.has(support as CapabilityEvidenceCandidateView["support"])
    || typeof source !== "string" || !(source in PUBLIC_CAPABILITY_SOURCE_GRADE)
    || typeof grade !== "string"
    || !PUBLIC_CAPABILITY_SOURCE_GRADE[source as CapabilityEvidenceCandidateView["source"]]
      .includes(grade as CapabilityEvidenceCandidateView["grade"])
    || scope !== "provider_model_transport"
    || providerKind !== context.providerKind
    || modelId !== context.modelId
    || transport !== context.transport
  ) {
    return null;
  }

  const observedAt = decodeEvidenceTimestamp(raw.observedAt);
  const expiresAt = decodeEvidenceTimestamp(raw.expiresAt);
  if ((raw.observedAt !== undefined && observedAt === undefined)
    || (raw.expiresAt !== undefined && expiresAt === undefined)
    || (observedAt !== undefined && expiresAt !== undefined && expiresAt <= observedAt)) {
    return null;
  }

  return {
    key,
    support: support as CapabilityEvidenceCandidateView["support"],
    source: source as CapabilityEvidenceCandidateView["source"],
    grade: grade as CapabilityEvidenceCandidateView["grade"],
    scope: "provider_model_transport",
    providerKind,
    modelId,
    transport,
    ...(context.metadataRevision ? { metadataRevision: context.metadataRevision } : {}),
    ...(typeof raw.generationRevision === "string" && isSafeEvidenceString(raw.generationRevision)
      ? { generationRevision: raw.generationRevision }
      : {}),
    ...(typeof raw.evidenceRevision === "string" && isSafeEvidenceString(raw.evidenceRevision)
      ? { evidenceRevision: raw.evidenceRevision }
      : {}),
    ...(observedAt !== undefined ? { observedAt } : {}),
    ...(expiresAt !== undefined ? { expiresAt } : {}),
  };
}

function isPublicCapabilityEvidenceKey(key: string): boolean {
  if (key === "web_search" || key === "vision_input" || key === "tool_call") {
    return true;
  }
  const separator = key.indexOf("/");
  if (separator <= 0 || separator === key.length - 1) return false;
  const prefix = key.slice(0, separator);
  const subkey = key.slice(separator + 1);
  return (prefix === "reasoning_level" || prefix === "generation_parameter")
    && PUBLIC_CAPABILITY_SUBKEY.test(subkey);
}

function decodeEvidenceTimestamp(raw: unknown): number | undefined {
  return typeof raw === "number" && Number.isSafeInteger(raw) && raw > 0
    ? raw
    : undefined;
}

function isSafeEvidenceString(value: unknown): value is string {
  return typeof value === "string" && value.length > 0 && value.length <= 256;
}

/**
 * Rewrites the response/cache boundary to the public allowlist. This prevents
 * an unexpected server provenance field from being retained in localStorage
 * or re-exposed by a later catalog projection.
 */
function normalizeMetadataEvidenceViews(
  data: MetadataResponse,
  metadataRevision?: string,
): MetadataResponse {
  return {
    ...data,
    ...(data.modelFacts !== undefined
      ? { modelFacts: normalizeModelFacts(data.modelFacts) }
      : {}),
    providers: Object.fromEntries(
      Object.entries(data.providers).map(([providerKind, provider]) => [
        providerKind,
        {
          ...provider,
          models: Object.fromEntries(
            Object.entries(provider.models).map(([modelId, model]) => {
              const {
                capabilityEvidenceView: rawView,
                capabilityEvidenceCandidates: persistedCandidates,
                capabilityEvidenceOwnedKeys: _persistedOwnedKeys,
                capabilityEvidenceViewMalformed: _persistedMalformed,
                ...modelWithoutEvidenceNamespaces
              } = model;
              const safeModel = allowlistedMetadataModelFields(
                modelWithoutEvidenceNamespaces,
              );
              const context = {
                providerKind,
                modelId,
                transport: model.transport,
                metadataRevision,
                lean: data.view === "lean",
              };
              const candidates = rawView !== undefined
                ? decodeCapabilityEvidenceView(rawView, context)
                : decodePersistedCapabilityEvidenceCandidates(
                    persistedCandidates,
                    context,
                  );
              const ownedKeys = decodeModelCapabilityEvidenceOwnedKeys(model, context.lean);
              const viewMalformed = decodeModelCapabilityEvidenceViewMalformed(model, context.lean);
              return [
                modelId,
                {
                  ...safeModel,
                  ...(candidates !== undefined
                    ? { capabilityEvidenceCandidates: candidates }
                    : {}),
                  ...(ownedKeys !== undefined
                    ? { capabilityEvidenceOwnedKeys: ownedKeys }
                    : {}),
                  ...(viewMalformed !== undefined
                    ? { capabilityEvidenceViewMalformed: viewMalformed }
                    : {}),
                },
              ];
            }),
          ),
        },
      ]),
    ),
  };
}

/** artifactHash and unknown future provenance fields must never enter persisted client caches. */
function normalizeModelFacts(raw: Record<string, ModelFacts>): Record<string, ModelFacts> {
  return Object.fromEntries(Object.entries(raw).flatMap(([key, value]) => {
    if (!key.includes('/') || value == null || typeof value !== 'object') return [];
    const safe: ModelFacts = {};
    if (typeof value.toolCall === 'boolean') safe.toolCall = value.toolCall;
    if (typeof value.reasoning === 'boolean') safe.reasoning = value.reasoning;
    if (Array.isArray(value.reasoningEfforts)) {
      safe.reasoningEfforts = value.reasoningEfforts.filter((item): item is string => typeof item === 'string');
    }
    if (typeof value.reasoningToggle === 'boolean') safe.reasoningToggle = value.reasoningToggle;
    if (value.modalities && typeof value.modalities === 'object') {
      const input = Array.isArray(value.modalities.input)
        ? value.modalities.input.filter((item): item is string => typeof item === 'string')
        : undefined;
      const output = Array.isArray(value.modalities.output)
        ? value.modalities.output.filter((item): item is string => typeof item === 'string')
        : undefined;
      safe.modalities = { ...(input ? { input } : {}), ...(output ? { output } : {}) };
    }
    if (typeof value.attachment === 'boolean') safe.attachment = value.attachment;
    if (typeof value.source === 'string') safe.source = value.source;
    return [[key, safe]];
  }));
}

function normalizeModelFactsBlob(raw: ModelFactsBlob): ModelFactsBlob | null {
  const revision = normalizeOpaqueGenerationRevision(raw.revision);
  if (!revision || !isRecord(raw.facts)) return null;
  return {
    revision,
    facts: normalizeModelFacts(raw.facts),
    etag: typeof raw.etag === "string" && raw.etag.length <= 256 ? raw.etag : null,
  };
}

function adoptLegacyModelFacts(data: MetadataResponse): void {
  if (!data.modelFacts || !data.modelFactsRevision || modelFactsCache) return;
  const legacy = normalizeModelFactsBlob({
    facts: data.modelFacts,
    revision: data.modelFactsRevision,
    // The main representation ETag is not valid for the sidecar endpoint.
    etag: null,
  });
  if (!legacy) return;
  modelFactsCache = legacy;
  void writeBlob<ModelFactsBlob>(MODEL_FACTS_BLOB_KEY, legacy).catch(() => {});
}

/**
 * Public model roots are an allowlist, not a provenance denylist. A future or
 * invalid server may add a private field we do not know by name; retaining a
 * generic object spread would persist that field before the evidence namespace
 * decoder gets a chance to reject it.
 */
type PublicMetadataModelFields = Omit<
  ModelMetadata,
  | "capabilityEvidenceView"
  | "capabilityEvidenceCandidates"
  | "capabilityEvidenceOwnedKeys"
  | "capabilityEvidenceViewMalformed"
>;

function allowlistedMetadataModelFields(model: ModelMetadata): PublicMetadataModelFields {
  const safe: Record<string, unknown> = {};
  const publicKeys = [
    "canonicalModelId",
    "modelRef",
    "aliases",
    "displayName",
    "vendorKey",
    "vendorName",
    "contextLength",
    "maxOutputTokens",
    "supportsTemperature",
    "billingSku",
    "pricingUnit",
    "regionScope",
    "currencyCode",
    "sourceSummary",
    "pricing",
    "pricingStatus",
    "capabilities",
    "toolCall",
    "libraryAgentic",
    "supportsPdfInput",
    "supportsServiceTier",
    "profiles",
    "capabilityControls",
    "uiHints",
    "transport",
    "minClientVersion",
    "attachmentExtraction",
  ] as const satisfies readonly (keyof ModelMetadata)[];
  for (const key of publicKeys) {
    if (model[key] !== undefined) safe[key] = model[key];
  }
  return safe as PublicMetadataModelFields;
}

function normalizePricing(model: ModelMetadata): {
  promptPerToken: number | null;
  completionPerToken: number | null;
  cachedInputPerMToken?: number | null;
  costPerUnit?: number | null;
  costInputBatches?: number | null;
  costOutputBatches?: number | null;
  costInputPriority?: number | null;
  costOutputPriority?: number | null;
  cacheReadInputPerMToken?: number | null;
  cacheCreationInputPerMToken?: number | null;
  cacheWrite5mPerMToken?: number | null;
  cacheWrite1hPerMToken?: number | null;
} | null {
  if (!model.pricing) return null;
  const promptPerMToken = model.pricing.promptPerMToken;
  const completionPerMToken = model.pricing.completionPerMToken;

  return {
    promptPerToken:
      promptPerMToken == null ? null : promptPerMToken / 1_000_000,
    completionPerToken:
      completionPerMToken == null ? null : completionPerMToken / 1_000_000,
    cachedInputPerMToken: model.pricing.cachedInputPerMToken,
    costPerUnit: model.pricing.costPerUnit,
    costInputBatches: model.pricing.costInputBatches,
    costOutputBatches: model.pricing.costOutputBatches,
    costInputPriority: model.pricing.costInputPriority,
    costOutputPriority: model.pricing.costOutputPriority,
    cacheReadInputPerMToken: model.pricing.cacheReadInputPerMToken,
    cacheCreationInputPerMToken: model.pricing.cacheCreationInputPerMToken,
    cacheWrite5mPerMToken: model.pricing.cacheWrite5mPerMToken,
    cacheWrite1hPerMToken: model.pricing.cacheWrite1hPerMToken,
  };
}

function normalizePricingStatus(
  model: ModelMetadata,
  pricing: ResolvedModelMetadata["pricing"],
): ModelPricingStatus {
  if (
    model.pricingStatus === "priced" ||
    model.pricingStatus === "free" ||
    model.pricingStatus === "unknown"
  ) {
    return model.pricingStatus;
  }

  const promptPerToken = pricing?.promptPerToken;
  const completionPerToken = pricing?.completionPerToken;

  if (
    pricing &&
    ((typeof promptPerToken === "number" && promptPerToken > 0) ||
      (typeof completionPerToken === "number" && completionPerToken > 0))
  ) {
    return "priced";
  }

  if (
    pricing &&
    normalizePricingUnit(model.pricingUnit) !== "per_token" &&
    pricing.costPerUnit != null
  ) {
    return pricing.costPerUnit > 0 ? "priced" : "free";
  }

  if (pricing && promptPerToken === 0 && completionPerToken === 0) {
    return "free";
  }

  return "unknown";
}

function normalizePricingUnit(value: string | undefined): string {
  return typeof value === "string" && value.trim() ? value : "per_token";
}

function normalizeSourceSummary(
  summary: ModelSourceSummary | undefined,
): ModelSourceSummary | undefined {
  if (!summary?.sourceKind || !summary.sourceName) return undefined;
  return summary;
}

function normalizeProfiles(
  model: ModelMetadata,
  generationParameterTables: MetadataResponse["generationParameterTables"],
): ResolvedModelMetadata["profiles"] {
  const reasoning = normalizeProfileRef(model.profiles?.reasoning);
  const webSearch = normalizeProfileRef(model.profiles?.webSearch);
  const imageGen = normalizeProfileRef(model.profiles?.imageGen);
  // generation is an object reference (template plus parameter capability table), not a profile
  // name, so it does not go through normalizeProfileRef. It is passed through verbatim, matching
  // catalog-resolver.ts and service.ts: `profiles.generation` is omitted when withdrawn, which makes
  // it undefined here and lets enrichStoredModel withdraw it downstream.
  const rawGeneration = model.profiles?.generation;
  const generation = rawGeneration
    ? normalizeGenerationProfile(rawGeneration, generationParameterTables)
    : undefined;

  return {
    ...(reasoning ? { reasoning } : {}),
    ...(webSearch ? { webSearch } : {}),
    ...(imageGen ? { imageGen } : {}),
    ...(generation ? { generation } : {}),
  };
}

function normalizeGenerationProfile(
  profile: NonNullable<ModelProfileRefs["generation"]>,
  generationParameterTables: MetadataResponse["generationParameterTables"],
): NonNullable<ResolvedModelMetadata["profiles"]["generation"]> {
  const {
    revision: rawRevision,
    parametersRef,
    parameters: inlineParameters,
    ...rest
  } = profile;
  const revision = normalizeOpaqueGenerationRevision(rawRevision);
  // A present parametersRef makes the dictionary authoritative. Missing or
  // malformed references fail closed instead of silently falling back to an
  // inline matrix from a mixed/poisoned payload. Full responses have no ref
  // and keep their existing inline representation byte-for-byte compatible.
  // The lookup uses the normalized reference rather than the raw parametersRef: the raw value is of
  // unknown provenance, fails type narrowing, and should not index an authoritative dictionary.
  const normalizedParametersRef = normalizeOpaqueGenerationRevision(parametersRef);
  const referencedParameters = normalizedParametersRef !== undefined
    ? generationParameterTables?.[normalizedParametersRef]
    : undefined;
  const parameters = parametersRef !== undefined
    ? Array.isArray(referencedParameters)
      ? referencedParameters
      : undefined
    : inlineParameters;
  return {
    ...rest,
    ...(revision ? { revision } : {}),
    ...(parameters ? { parameters } : {}),
  };
}

function normalizeOpaqueGenerationRevision(value: unknown): string | undefined {
  if (typeof value !== "string" || value.length === 0 || value.length > 256) {
    return undefined;
  }
  // Opaque means the client must neither derive nor rewrite the token. Reject
  // control characters only, so a future server algorithm need not be SHA-256.
  return /[\u0000-\u001F\u007F]/.test(value) ? undefined : value;
}

function normalizeProfileRef(value: NullableString): string | undefined {
  return typeof value === "string" && value.trim() ? value : undefined;
}

function normalizeUIHints(
  hints: ModelUIHints | undefined,
): ResolvedModelMetadata["uiHints"] | undefined {
  if (!hints) return undefined;

  // badgeOrder is free-form too; "text" is filtered out because it is not shown as a badge, and everything else is kept
  const badgeOrder = hints.badgeOrder?.filter((cap) => cap !== "text");
  if (
    !hints.groupKey &&
    !hints.groupName &&
    hints.rank == null &&
    hints.recommended == null &&
    (!badgeOrder || badgeOrder.length === 0)
  ) {
    return undefined;
  }

  return {
    groupKey: hints.groupKey,
    groupName: hints.groupName,
    rank: hints.rank,
    recommended: hints.recommended,
    badgeOrder,
  };
}

function compareProviderConfigs(
  left: PublicProviderConfig,
  right: PublicProviderConfig,
): number {
  const leftOrder = left.sortOrder ?? Number.MAX_SAFE_INTEGER;
  const rightOrder = right.sortOrder ?? Number.MAX_SAFE_INTEGER;
  if (leftOrder !== rightOrder) {
    return leftOrder - rightOrder;
  }
  return left.kind.localeCompare(right.kind);
}

async function fetchMetadata(): Promise<void> {
  if (refreshPromise) {
    await refreshPromise;
    return;
  }

  refreshPromise = (async () => {
    try {
      const backendURL = resolveMetadataBackendURL();
      const url = `${backendURL}/api/metadata?view=lean`;
      const headers: Record<string, string> = {};
      if (cachedETag) {
        headers["If-None-Match"] = cachedETag;
      }

      const res = await fetchWithReachability(url, { headers });
      if (res.status === 304) {
        // A 304 means the backend confirms the copy in hand is current, so it lifts the
        // confirmation gate exactly like a 200 does.
        const justConfirmed = !snapshotConfirmedThisSession;
        snapshotConfirmedThisSession = true;
        cachedAt = Date.now();
        // Confirmation is observable state for the library's negative gate. The
        // payload is unchanged, but useSyncExternalStore still needs one new
        // snapshot value when this session first becomes confirmed.
        if (justConfirmed) metadataContentRevision += 1;
        // The content did not change, so dedup keeps an unchanged version from repeatedly
        // re-running UI computation. The first confirmation still has to emit: the content is
        // the same but "may we conclude unsupported" changed, and subscribers need that tick to
        // turn a pending routing decision into a real verdict.
        emitVersionChange({ allowDedup: !justConfirmed });
        return;
      }
      if (!res.ok) return;

      const json = await res.json();
      // The backend wraps responses in { code, data, message }, so unwrap it.
      const data: MetadataResponse = json.data ?? json;
      const contractVersion =
        (data as MetadataResponse & { contractVersion?: number })
          .contractVersion ?? 1;

      // A contract change drops every cache bucket other than the current one.
      void pruneStaleBuckets(contractVersion);

      // The ETag lives in the same blob as the snapshot (see MetadataBlob) and persistCache
      // writes both together; only the in-memory copy is updated here so the two media can never
      // hold "an ETag with no data". A 200 without an ETag must not inherit the previous
      // payload's revision, so it is set to null and written back with the snapshot.
      cachedETag = res.headers.get("ETag");

      cached = normalizeMetadataEvidenceViews(data, cachedETag ?? undefined);
      adoptLegacyModelFacts(cached);
      // The sidecar has an independent validator. A newly accepted catalog
      // representation makes the next catalog-external demand revalidate that
      // validator; it must never inherit the lean ETag.
      modelFactsInitialized = false;
      cachedAt = Date.now();
      metadataContentRevision += 1;
      snapshotConfirmedThisSession = true;
      persistCache(cached, contractVersion);
      // A 200 always emits, because the content may be new.
      emitVersionChange();
    } catch {
      // A network error keeps the existing cache.
    }
  })();

  try {
    await refreshPromise;
  } finally {
    refreshPromise = null;
  }
}

function refreshInBackground(): void {
  fetchMetadata().catch(() => {});
}

function persistCache(data: MetadataResponse, contractVersion: number): void {
  // Deferred to idle: the IDB write itself is async, but structured-cloning a 3MB object still costs main-thread time
  const schedule =
    typeof requestIdleCallback === "function"
      ? requestIdleCallback
      : (cb: () => void) => setTimeout(cb, 0);
  schedule(() => {
    // A cache-hit allowlist rewrite is scheduled asynchronously. If a
    // newer fetch changed the contract bucket before this callback runs,
    // writing the old object would resurrect the stale bucket after prune.
    if (cached !== data) return;
    const blob: MetadataBlob = {
      data,
      etag: cachedETag,
      allowlistVersion: METADATA_ALLOWLIST_VERSION,
    };
    // writeBlob swallows its own failures: a cache write that does not land just means one more fetch next time, not an error
    void writeBlob(cacheKeyFor(contractVersion), blob);
  });
}

/**
 * Base URL of the public model catalog. Set NEXT_PUBLIC_BACKEND_URL to point at a self-hosted
 * metadata service; left unset, the app reads the catalog published for everyone.
 */
export function resolveMetadataBackendURL(): string {
  const configured = process.env.NEXT_PUBLIC_BACKEND_URL?.trim().replace(/\/+$/, "");
  return configured || PUBLIC_METADATA_BASE_URL;
}
