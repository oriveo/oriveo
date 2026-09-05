'use client';

/**
 * Device code state machine for the Grok subscription sign-in.
 *
 * Upstream sets the polling pace: `interval` comes from the upstream response, and a `slow_down`
 * adds 5 seconds. That is what RFC 8628 requires, and polling faster only earns more `slow_down`
 * responses or gets the client flagged as abusive.
 */

import { useCallback, useEffect, useRef, useState } from 'react';
import type { ProviderSubscriptionCredential } from '@oriveo/shared';
import type {
  GrokDeviceAuthorization,
  GrokSubscriptionAuthConfig,
  GrokSubscriptionErrorKind,
} from '@oriveo/core/providers/grok-subscription';
import {
  pollGrokDeviceToken,
  refreshMetadataOnClientVersionRejected,
  requestGrokDeviceAuthorization,
} from '../core/providers/grok-subscription';

export type GrokAuthorizationPhase =
  | { kind: 'idle' }
  | { kind: 'requesting' }
  | { kind: 'awaitingAuthorization'; authorization: GrokDeviceAuthorization }
  | { kind: 'succeeded'; credential: ProviderSubscriptionCredential }
  | { kind: 'failed'; error: GrokSubscriptionErrorKind };

/** Fixed backoff increment for `slow_down` (RFC 8628 section 3.5). */
const SLOW_DOWN_STEP_SECONDS = 5;

function delay(seconds: number, signal: AbortSignal): Promise<void> {
  return new Promise((resolve) => {
    const timer = setTimeout(resolve, seconds * 1000);
    signal.addEventListener('abort', () => {
      clearTimeout(timer);
      resolve();
    }, { once: true });
  });
}

export interface UseGrokDeviceAuthorization {
  phase: GrokAuthorizationPhase;
  didOpenVerificationPage: boolean;
  start: () => void;
  cancel: () => void;
  markVerificationPageOpened: () => void;
}

export function useGrokDeviceAuthorization(
  config: GrokSubscriptionAuthConfig | null,
): UseGrokDeviceAuthorization {
  const [phase, setPhase] = useState<GrokAuthorizationPhase>({ kind: 'idle' });
  const [didOpenVerificationPage, setDidOpenVerificationPage] = useState(false);
  const abortRef = useRef<AbortController | null>(null);

  const cancel = useCallback(() => {
    abortRef.current?.abort();
    abortRef.current = null;
    setPhase({ kind: 'idle' });
    setDidOpenVerificationPage(false);
  }, []);

  // On an explicit exit or unmount, the device code already issued simply expires; no upstream call is needed.
  useEffect(() => () => abortRef.current?.abort(), []);

  const start = useCallback(() => {
    if (!config) {
      setPhase({ kind: 'failed', error: 'configurationUnavailable' });
      return;
    }
    // Cancel the previous round first, so a repeated call cannot leave two pollers hitting upstream.
    abortRef.current?.abort();
    const controller = new AbortController();
    abortRef.current = controller;
    setDidOpenVerificationPage(false);
    setPhase({ kind: 'requesting' });

    void (async () => {
      const requested = await requestGrokDeviceAuthorization(config);
      if (controller.signal.aborted) return;
      if (!requested.ok) {
        refreshMetadataOnClientVersionRejected(requested.error);
        setPhase({ kind: 'failed', error: requested.error });
        return;
      }
      const authorization = requested.value;
      setPhase({ kind: 'awaitingAuthorization', authorization });

      let interval = Math.max(1, authorization.interval ?? config.pollIntervalSeconds);
      // The upstream expires_in wins, with the served timeout as a backstop: polling past the point
      // where the short code has expired is pointless and only generates useless upstream traffic.
      const deadline =
        Date.now() + Math.min(authorization.expiresIn, config.pollTimeoutSeconds) * 1000;

      while (!controller.signal.aborted) {
        if (Date.now() >= deadline) {
          setPhase({ kind: 'failed', error: 'codeExpired' });
          return;
        }
        await delay(interval, controller.signal);
        if (controller.signal.aborted) return;

        const polled = await pollGrokDeviceToken(authorization.deviceCode);
        if (controller.signal.aborted) return;
        if (polled.ok) {
          setPhase({ kind: 'succeeded', credential: polled.value });
          return;
        }
        if (polled.error === 'authorizationPending') continue;
        if (polled.error === 'slowDown') {
          interval += SLOW_DOWN_STEP_SECONDS;
          continue;
        }
        // A transport error is **transient** and must not be treated as terminal: authorization
        // requires the user to switch to another tab, during which the browser can throttle or cut
        // requests from the background tab, and the network may simply hiccup. Failing here means
        // the act of completing the authorization is what aborts it. A real disconnection is caught
        // by the deadline, and the user can cancel at any time.
        if (polled.error === 'transport') continue;
        refreshMetadataOnClientVersionRejected(polled.error);
        setPhase({ kind: 'failed', error: polled.error });
        return;
      }
    })();
  }, [config]);

  const markVerificationPageOpened = useCallback(() => setDidOpenVerificationPage(true), []);

  return { phase, didOpenVerificationPage, start, cancel, markVerificationPageOpened };
}
