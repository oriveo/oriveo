/**
 * Retry policy, per `request_preference_contract.v2`.
 *
 *
 * A located, pre-token, side-effect-free deterministic 400 may only offer a
 * user-confirmed resend without that setting. Nothing is stripped or retried
 * silently; the saved preference remains dormant. Every other failure surfaces.
 */

import { OWNER_IDS, type OwnerId } from './types';

const ALLOWED_STATUS = 400;
const ALLOWED_ERROR_CLASS = 'optional_parameter_rejected';

export interface RetryIntent {
  source: string;
  status: number | null;
  errorClass: string;
  owner: OwnerId | null;
  locatedPointers: readonly string[];
  preToken: boolean;
  streamStarted: boolean;
  sideEffects: boolean;
  automaticRetryCount: number;
}

export type RetryAction = 'surface_error' | 'user_confirmed_resend_without_located_setting';

export interface RetryResult {
  retry: boolean;
  action: RetryAction;
  preference?: 'retain_dormant';
}

export function resolveRetry(intent: RetryIntent): RetryResult {
  const explicitResend = (intent.source === 'provider_recipe' || intent.source === 'custom')
    && intent.status === ALLOWED_STATUS
    && intent.errorClass === ALLOWED_ERROR_CLASS
    && intent.owner != null && OWNER_IDS.includes(intent.owner)
    && intent.locatedPointers.length > 0
    && intent.preToken
    && !intent.streamStarted
    && !intent.sideEffects
    && intent.automaticRetryCount === 0;

  return explicitResend
    ? { retry: false, action: 'user_confirmed_resend_without_located_setting', preference: 'retain_dormant' }
    : { retry: false, action: 'surface_error' };
}
