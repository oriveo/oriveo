import type { ProviderKind, RelayAuthMode, RelayRequestedConfig, RelayTransport } from '@oriveo/shared/pure-types';

export type OfficialProviderKind = Exclude<ProviderKind, 'relay'>;

export interface ProviderInvalidKeySignalContract {
  status?: number;
  bodyIncludes?: readonly string[];
}

export interface ProviderValidationContract {
  probe?: 'list_models' | 'key_info' | string;
  modelID?: string;
  authMode?: Exclude<RelayAuthMode, 'auto'>;
  probePath?: string;
  headerProfile?: string;
  invalidKeySignals?: readonly ProviderInvalidKeySignalContract[];
}

export interface RelayEndpointContract {
  baseURL: string;
  transport: Exclude<RelayTransport, 'auto'>;
  authMode: Exclude<RelayAuthMode, 'auto'>;
  /** Explicit user-initiated verification must use this model for a 1-token generation request. */
  modelID?: string;
  /** A full validation request must use the same serializable Relay config the chat itself uses; main must not guess the auth, headers or query on its own. */
  securityMode?: RelayRequestedConfig['securityMode'];
  codexCompatIdentity?: RelayRequestedConfig['codexCompatIdentity'];
  customUserAgent?: RelayRequestedConfig['customUserAgent'];
  headers?: RelayRequestedConfig['headers'];
  queryParams?: RelayRequestedConfig['queryParams'];
  disableResponseStorage?: RelayRequestedConfig['disableResponseStorage'];
}

export interface OfficialProviderValidateRequest {
  providerKind: OfficialProviderKind;
  apiKeyRef: string;
  /** Draft key for pre-save validation only. Stored providers must use apiKeyRef. */
  plaintextKey?: string;
  /** Custom endpoint override for an official provider (self-hosted or openai-compatible); empty means probe the default endpoint for the kind. */
  baseURL?: string;
  providerConfigId?: string;
  regionId?: string;
  validation?: ProviderValidationContract;
  relay?: never;
}

export interface RelayProviderValidateRequest {
  providerKind: 'relay';
  apiKeyRef: string;
  /** Draft key for pre-save validation only. Stored providers must use apiKeyRef. */
  plaintextKey?: string;
  relay: RelayEndpointContract;
  providerConfigId?: never;
  regionId?: never;
  validation?: never;
}

export type ProviderValidateRequest = OfficialProviderValidateRequest | RelayProviderValidateRequest;

export interface OfficialProviderModelsRequest {
  providerKind: OfficialProviderKind;
  apiKeyRef: string;
  providerConfigId?: string;
  regionId?: string;
  relay?: never;
}

export interface RelayProviderModelsRequest {
  providerKind: 'relay';
  apiKeyRef: string;
  relay: RelayEndpointContract;
  providerConfigId?: never;
  regionId?: never;
}

export type ProviderModelsRequest = OfficialProviderModelsRequest | RelayProviderModelsRequest;

/** Three-state key validation result. invalid is a normal return value and does not block saving. */
export interface ProviderValidateResponse {
  result: 'valid' | 'invalid' | 'unverified';
  /** Upstream HTTP status when a response arrived; absent on a timeout or network error. */
  status?: number;
}

export interface ProviderModelsResponse {
  data: Array<{ id: string }>;
}

/**
 * "Clear learned capabilities" clears every entry under a **connection plus model**, across all
 * endpoint and revision variants. Only the renderer has the first 4 connection identity fields,
 * and without any one of them main cannot locate the partition and honestly clears nothing (an
 * older client sent only the last 3 and silently no-opped). endpointFingerprint is kept as a
 * request shape check: it proves the connection can form a valid production endpoint.
 */
export interface ProviderClearUnsupportedParamLearningRequest {
  providerKind: 'relay';
  modelID: string;
  endpointFingerprint: string;
  partitionId: string;
  connectionInstanceId: string;
  connectionGeneration: string;
  credentialEpoch: string;
}

/**
 * The preload `window.oriveo.provider` bridge: a saved key only ever travels as an apiKeyRef, while
 * a new draft may carry plaintextKey once from renderer to main for real validation. main never
 * returns, persists or logs the plaintext.
 */
export interface OriveoProviderBridge {
  validate(req: ProviderValidateRequest): Promise<ProviderValidateResponse>;
  models(req: ProviderModelsRequest): Promise<ProviderModelsResponse>;
  clearUnsupportedParamLearning(req: ProviderClearUnsupportedParamLearningRequest): Promise<void>;
}
