export type RelayProbeErrorClass =
  | 'auth_failed'
  | 'permission_denied'
  | 'route_not_found'
  | 'method_not_allowed'
  | 'catalog_unavailable'
  | 'model_not_found'
  | 'rate_limited'
  | 'server_error'
  | 'network_error'
  | 'response_shape_mismatch'
  | 'cli_only'
  | 'budget_exceeded'
  | 'unknown';

export interface BrowserRuntimeIssue {
  errorClass: RelayProbeErrorClass;
  message: string;
  shouldBlock: boolean;
}

export function classifyBrowserRuntimeError(error: unknown): BrowserRuntimeIssue {
  const detail = error instanceof Error ? error.message.trim() : String(error ?? '').trim();
  const normalized = detail.toLowerCase();

  if (normalized.includes('aborted')) {
    return {
      errorClass: 'unknown',
      message: detail || 'Probe aborted.',
      shouldBlock: false,
    };
  }

  if (
    error instanceof TypeError ||
    normalized.includes('failed to fetch') ||
    normalized.includes('load failed') ||
    normalized.includes('networkerror') ||
    normalized.includes('cors')
  ) {
    return {
      errorClass: 'network_error',
      message: 'The browser blocked direct access to this relay. It is likely missing CORS or preflight support.',
      shouldBlock: true,
    };
  }

  return {
    errorClass: 'unknown',
    message: detail || 'Browser direct probe failed.',
    shouldBlock: false,
  };
}

export function classifyHTTPStatus(
  status: number,
  fallbackMessage: string,
): BrowserRuntimeIssue {
  if (status === 401) {
    return { errorClass: 'auth_failed', message: fallbackMessage, shouldBlock: true };
  }
  if (status === 403) {
    return { errorClass: 'permission_denied', message: fallbackMessage, shouldBlock: true };
  }
  if (status === 404) {
    return { errorClass: 'route_not_found', message: fallbackMessage, shouldBlock: false };
  }
  if (status === 405) {
    return { errorClass: 'method_not_allowed', message: fallbackMessage, shouldBlock: false };
  }
  if (status === 429) {
    return { errorClass: 'rate_limited', message: fallbackMessage, shouldBlock: true };
  }
  if (status >= 500) {
    return { errorClass: 'server_error', message: fallbackMessage, shouldBlock: false };
  }
  return { errorClass: 'unknown', message: fallbackMessage, shouldBlock: false };
}
