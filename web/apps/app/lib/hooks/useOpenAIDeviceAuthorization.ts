'use client';

/**
 * Two-stage device code state machine for the Codex ChatGPT subscription sign-in.
 *
 * Upstream sets the polling pace: `interval` comes from the upstream response, and a `slow_down`
 * adds 5 seconds, as RFC 8628 requires. Polling faster only earns more `slow_down` responses, or
 * gets the client flagged as abusive.
 *
 * The state machine has the same shape as the Grok one (requesting, awaiting, then succeeded or
 * failed) because the PKCE exchange is folded into the server side: a single poll either returns
 * usable credentials or a well-defined intermediate state.
 */

import { useCallback, useEffect, useRef, useState } from 'react';
import type { ProviderSubscriptionCredential } from '@oriveo/shared';
import type {
  OpenAIDeviceAuthorization,
  OpenAISubscriptionAuthConfig,
  OpenAISubscriptionErrorKind,
} from '@oriveo/core/providers/openai-subscription';
import {
  pollOpenAIDeviceToken,
  refreshMetadataOnCodexClientVersionRejected,
  requestOpenAIDeviceAuthorization,
} from '../core/providers/openai-subscription';

export type OpenAIAuthorizationPhase =
  | { kind: 'idle' }
  | { kind: 'requesting' }
  | { kind: 'awaitingAuthorization'; authorization: OpenAIDeviceAuthorization }
  | { kind: 'succeeded'; credential: ProviderSubscriptionCredential }
  /** `upstreamStatus` is set only for `upstream`, the case no rule claimed, so the copy can explain itself. */
  | { kind: 'failed'; error: OpenAISubscriptionErrorKind; upstreamStatus?: number };

/** Fixed backoff step for `slow_down` (RFC 8628 section 3.5). */
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

export interface UseOpenAIDeviceAuthorization {
  phase: OpenAIAuthorizationPhase;
  didOpenVerificationPage: boolean;
  start: () => void;
  cancel: () => void;
  markVerificationPageOpened: () => void;
}

export function useOpenAIDeviceAuthorization(
  config: OpenAISubscriptionAuthConfig | null,
): UseOpenAIDeviceAuthorization {
  const [phase, setPhase] = useState<OpenAIAuthorizationPhase>({ kind: 'idle' });
  const [didOpenVerificationPage, setDidOpenVerificationPage] = useState(false);
  const abortRef = useRef<AbortController | null>(null);

  const cancel = useCallback(() => {
    abortRef.current?.abort();
    abortRef.current = null;
    setPhase({ kind: 'idle' });
    setDidOpenVerificationPage(false);
  }, []);

  // The user quitting or the component unmounting: an issued device code expires on its own, so
  // there is nothing to call upstream, and Codex offers no revocation endpoint either.
  useEffect(() => () => abortRef.current?.abort(), []);

  const start = useCallback(() => {
    if (!config) {
      setPhase({ kind: 'failed', error: 'configurationUnavailable' });
      return;
    }
    // A repeated call cancels the previous round first, so two polls never hit upstream at once.
    abortRef.current?.abort();
    const controller = new AbortController();
    abortRef.current = controller;
    setDidOpenVerificationPage(false);
    setPhase({ kind: 'requesting' });

    void (async () => {
      const requested = await requestOpenAIDeviceAuthorization(config);
      if (controller.signal.aborted) return;
      if (!requested.ok) {
        refreshMetadataOnCodexClientVersionRejected(requested.error);
        setPhase({ kind: 'failed', error: requested.error, upstreamStatus: requested.upstreamStatus });
        return;
      }
      const authorization = requested.value;
      setPhase({ kind: 'awaitingAuthorization', authorization });

      let interval = Math.max(1, authorization.interval ?? config.pollIntervalSeconds);
      // The upstream expires_in wins, with the configured timeout as a backstop: polling past the
      // short code's expiry achieves nothing and only creates useless upstream traffic.
      const deadline =
        Date.now() + Math.min(authorization.expiresIn, config.pollTimeoutSeconds) * 1000;

      while (!controller.signal.aborted) {
        if (Date.now() >= deadline) {
          setPhase({ kind: 'failed', error: 'codeExpired' });
          return;
        }
        await delay(interval, controller.signal);
        if (controller.signal.aborted) return;

        const polled = await pollOpenAIDeviceToken(
          authorization.deviceAuthID,
          authorization.userCode,
        );
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
        // A transport error is **transient** and must not be treated as terminal: authorization asks
        // the user to finish in another tab, and while that tab is in the background the browser may
        // throttle or cut the request, and the network may simply blip. Failing here would mean the
        // act of completing the authorization is what interrupts it. A real disconnect is caught by
        // the deadline, and the user can cancel at any time.
        if (polled.error === 'transport') continue;
        refreshMetadataOnCodexClientVersionRejected(polled.error);
        setPhase({ kind: 'failed', error: polled.error, upstreamStatus: polled.upstreamStatus });
        return;
      }
    })();
  }, [config]);

  const markVerificationPageOpened = useCallback(() => setDidOpenVerificationPage(true), []);

  return { phase, didOpenVerificationPage, start, cancel, markVerificationPageOpened };
}
