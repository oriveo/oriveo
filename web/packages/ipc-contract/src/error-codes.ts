export const IPC_ERROR_CODES = [
  'IPC_UPSTREAM_NETWORK',
  'IPC_UPSTREAM',
  'IPC_CANCELLED',
  'IPC_SSRF_BLOCKED',
  'IPC_FORBIDDEN_CHANNEL',
  'IPC_RATE_LIMITED',
  'IPC_AUTH',
  'IPC_PROVIDER_QUOTA',
  'IPC_ENTITLEMENT_QUOTA',
  'IPC_BAD_REQUEST',
  'IPC_UNAVAILABLE',
  'IPC_EMPTY_RESPONSE',
  'IPC_OFFLINE',
  'IPC_TIMEOUT',
  'IPC_MAIN_CRASH',
  'IPC_PAYLOAD_TOO_LARGE',
  'IPC_PATH_NORMALIZE',
  'IPC_BACKPRESSURE',
  'IPC_KNOWLEDGE',
  'IPC_INTERNAL',
] as const;

export type IpcErrorCode = (typeof IPC_ERROR_CODES)[number];

export type IpcQuotaSource = 'provider' | 'entitlement';

export interface IpcErrorMeta {
  i18nKey: string;
  retryable: boolean;
  quotaSource?: IpcQuotaSource;
}

export const ERROR_CODE_META: Record<IpcErrorCode, IpcErrorMeta> = {
  IPC_UPSTREAM_NETWORK: { i18nKey: 'error.network', retryable: true },
  IPC_UPSTREAM: { i18nKey: 'error.upstream', retryable: true },
  IPC_CANCELLED: { i18nKey: 'error.cancelled', retryable: false },
  IPC_SSRF_BLOCKED: { i18nKey: 'error.ssrfBlocked', retryable: false },
  IPC_FORBIDDEN_CHANNEL: { i18nKey: 'error.unexpected', retryable: false },
  IPC_RATE_LIMITED: { i18nKey: 'error.rateLimited', retryable: true },
  IPC_AUTH: { i18nKey: 'error.invalidKey', retryable: false },
  IPC_PROVIDER_QUOTA: { i18nKey: 'error.providerQuota', retryable: false, quotaSource: 'provider' },
  IPC_ENTITLEMENT_QUOTA: { i18nKey: 'error.entitlementQuota', retryable: false, quotaSource: 'entitlement' },
  IPC_BAD_REQUEST: { i18nKey: 'error.badRequest', retryable: false },
  IPC_UNAVAILABLE: { i18nKey: 'error.unavailable', retryable: true },
  IPC_EMPTY_RESPONSE: { i18nKey: 'error.emptyResponse', retryable: true },
  IPC_OFFLINE: { i18nKey: 'error.offline', retryable: true },
  IPC_TIMEOUT: { i18nKey: 'error.timeout', retryable: true },
  IPC_MAIN_CRASH: { i18nKey: 'error.appRecovering', retryable: true },
  IPC_PAYLOAD_TOO_LARGE: { i18nKey: 'error.fileTooLarge', retryable: false },
  IPC_PATH_NORMALIZE: { i18nKey: 'error.pathConflict', retryable: false },
  IPC_BACKPRESSURE: { i18nKey: 'error.streamInterrupted', retryable: true },
  IPC_KNOWLEDGE: { i18nKey: 'error.knowledge', retryable: true },
  IPC_INTERNAL: { i18nKey: 'error.unexpected', retryable: true },
};
