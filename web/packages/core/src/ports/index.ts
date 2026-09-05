import type {
  AIModel,
  ProviderKind,
  RelayAuthMode,
  RelayTransport,
  Telemetry,
} from '@oriveo/shared/pure-types';

export interface TransportRequestInit {
  // DELETE is used to remove a knowledge vector store or file; FormData is used for multipart
  // knowledge file uploads. Existing chat/relay callers only use GET/POST with a string body, and
  // the undici / fetch implementations support all of this natively.
  method: 'GET' | 'POST' | 'DELETE';
  headers: Record<string, string>;
  body?: string | FormData;
  signal?: AbortSignal;
}

export interface TransportResponse {
  ok: boolean;
  status: number;
  url: string;
  headers: { get(name: string): string | null };
  body: ReadableStream<Uint8Array> | null;
  text(): Promise<string>;
}

export interface TransportPort {
  fetch(url: string, init: TransportRequestInit): Promise<TransportResponse>;
}

/**
 * Upstream request transport: returns a real Response so executeProviderRequest and the response
 * adapter can use .json()/.body. Structurally compatible with TransportPort (a Response is
 * assignable to TransportResponse), so one undici implementation can serve both.
 */
export interface UpstreamTransport {
  fetch(url: string, init: TransportRequestInit): Promise<Response>;
}

/** Image downloader: url -> data URL on success, or null when the download fails or is not possible, in which case the caller falls back to the original url. */
export type ImageDownloader = (url: string) => Promise<string | null>;

export type CryptoKeyLike = unknown;

export interface CryptoPort {
  getRandomValues(arr: Uint8Array): Uint8Array;
  deriveAesKey(password: string, salt: Uint8Array): Promise<CryptoKeyLike>;
  encryptAesGcm(key: CryptoKeyLike, iv: Uint8Array, data: Uint8Array): Promise<ArrayBuffer>;
  decryptAesGcm(key: CryptoKeyLike, iv: Uint8Array, data: Uint8Array): Promise<ArrayBuffer>;
  sha256(data: Uint8Array): Promise<ArrayBuffer>;
}

export interface ClockPort {
  now(): number;
}

export type TelemetryPort = Telemetry;

export interface PricingInput {
  promptPrice?: number;
  completionPrice?: number;
}

export interface ResolvedModelLite {
  id: string;
  canonicalModelId?: string;
  providerKind: string;
  capabilities?: readonly string[];
  reasoningProfile?: string;
  webSearchProfile?: string;
  imageGenProfile?: string;
  transport?: string;
}

export interface MetadataInvalidKeySignal {
  status?: number;
  bodyIncludes?: readonly string[];
}

export interface MetadataValidationContract {
  probe?: 'list_models' | 'key_info' | string;
  modelID?: string;
  authMode?: Exclude<RelayAuthMode, 'auto'>;
  probePath?: string;
  headerProfile?: string;
  invalidKeySignals?: readonly MetadataInvalidKeySignal[];
}

export interface MetadataProviderConfig {
  providerKind: ProviderKind | string;
  displayName?: string;
  endpoint?: string;
  regionOptions?: readonly unknown[];
  attachmentSupport?: unknown;
  validation?: MetadataValidationContract;
  models?: readonly AIModel[];
  [key: string]: unknown;
}

/** Runtime metadata only describes the remote protocols; the native llama.cpp /completion path is a local engine path and is not in this table. */
export type RelayRuntimeTransportKey = Exclude<RelayTransport, 'auto' | 'llamacpp_native'>;

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
  defaultAuthMode: Exclude<RelayAuthMode, 'auto'>;
  defaultVersion: string;
  acceptedVersions: readonly string[];
  // Strict union rather than string, so narrowing in relay-runtime-support leaves no string
  // residue. Keep this in sync with the metadata client when the backend adds a value.
  headerProfile: 'none' | 'anthropic_v2023_06_01' | 'gemini_key' | 'codex_responses';
  codexIdentityDefault: boolean;
  webSearchToolName: 'web_search' | 'web_search_preview' | 'disabled' | 'google_search';
  imageRoute: 'inline_responses_tool' | 'images_endpoint' | 'gemini_modality' | 'unsupported';
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
  officialProviderWhitelist: readonly string[];
  transportEnvelopes: Record<RelayRuntimeTransportKey, RelayTransportEnvelope>;
  transportRules: Record<RelayRuntimeTransportKey, RelayTransportRule>;
  verificationPolicy: RelayVerificationPolicy;
  featureGatingPolicy: RelayFeatureGatingPolicy;
}

export interface MetadataLookupPort {
  lookupPricing(modelId: string, providerKind: string): PricingInput | null;
  resolveCatalogModel(modelId: string, providerKind: string): ResolvedModelLite | null;
  lookupProviderConfig(providerKind: string): MetadataProviderConfig | null;
  lookupRelayRuntimeConfig(): RelayRuntimeConfig | null;
  metadataContractVersion(): number | string | null;
}

export interface EnvPort {
  appVersion?: string;
}

export interface CorePorts {
  transport: TransportPort;
  crypto: CryptoPort;
  clock: ClockPort;
  telemetry: TelemetryPort;
  metadata: MetadataLookupPort;
  env: EnvPort;
}

export function createNoopTelemetryPort(): TelemetryPort {
  return {
    isEnabled: () => false,
    identify: () => undefined,
    track: () => undefined,
    page: () => undefined,
    reset: () => undefined,
    setSuperProperties: () => undefined,
    optIn: () => undefined,
    optOut: () => undefined,
    shutdown: () => undefined,
  };
}
