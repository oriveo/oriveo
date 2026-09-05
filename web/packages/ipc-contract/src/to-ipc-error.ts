import type { ProviderError, ProviderErrorKind, ProviderQuotaSource } from '@oriveo/core';
import type { IpcError } from './envelope';
import { ERROR_CODE_META, type IpcErrorCode, type IpcQuotaSource } from './error-codes';

const KIND_TO_CODE: Record<ProviderErrorKind, IpcErrorCode> = {
  invalidKey: 'IPC_AUTH',
  unauthorized: 'IPC_AUTH',
  badRequest: 'IPC_BAD_REQUEST',
  quotaExceeded: 'IPC_PROVIDER_QUOTA',
  rateLimited: 'IPC_RATE_LIMITED',
  unavailable: 'IPC_UNAVAILABLE',
  network: 'IPC_UPSTREAM_NETWORK',
  emptyResponse: 'IPC_EMPTY_RESPONSE',
  upstream: 'IPC_UPSTREAM',
  emptyModelCatalog: 'IPC_UPSTREAM',
  // Subscription paths: 426 and 403 mean the path is currently unusable, 401 is a credential
  // problem and 429 is a quota problem.
  grokSubscriptionUnavailable: 'IPC_UNAVAILABLE',
  grokSubscriptionIneligible: 'IPC_UNAVAILABLE',
  grokSubscriptionExpired: 'IPC_AUTH',
  grokSubscriptionQuotaExhausted: 'IPC_PROVIDER_QUOTA',
  openAISubscriptionUnavailable: 'IPC_UNAVAILABLE',
  openAISubscriptionIneligible: 'IPC_UNAVAILABLE',
  openAISubscriptionExpired: 'IPC_AUTH',
  openAISubscriptionQuotaExhausted: 'IPC_PROVIDER_QUOTA',
};

export function codeForProviderErrorKind(kind: ProviderErrorKind): IpcErrorCode {
  return KIND_TO_CODE[kind];
}

export function codeForProviderError(error: Pick<ProviderError, 'kind' | 'quotaSource'>): IpcErrorCode {
  if (error.kind !== 'quotaExceeded') return codeForProviderErrorKind(error.kind);

  switch (error.quotaSource) {
    case 'entitlement':
      return 'IPC_ENTITLEMENT_QUOTA';
    case 'provider':
    case 'unknown':
    case undefined:
      return 'IPC_PROVIDER_QUOTA';
  }
}

export function toIpcError(error: ProviderError): IpcError {
  const code = codeForProviderError(error);
  const meta = ERROR_CODE_META[code];
  return {
    code,
    message: error.message,
    i18nKey: error.i18nKey ?? meta.i18nKey,
    errorKind: error.kind,
    detail: error.detail,
    retryable: error.retryable ?? meta.retryable,
    nextAction: error.nextAction,
    source: error.source,
    severity: error.severity,
    status: error.status,
    upstreamURL: error.upstreamURL,
    quotaSource: toIpcQuotaSource(error.quotaSource) ?? meta.quotaSource,
  };
}

function toIpcQuotaSource(source: ProviderQuotaSource | undefined): IpcQuotaSource | undefined {
  switch (source) {
    case 'provider':
    case 'entitlement':
      return source;
    case 'unknown':
    case undefined:
      return undefined;
  }
}
