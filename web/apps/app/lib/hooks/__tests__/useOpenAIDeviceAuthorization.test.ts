// @vitest-environment jsdom
//
// Polling state machine for the two-stage Codex device code flow.
//
// The core rule pinned here is that **a transient transport error is not a terminal state**:
// authorization asks the user to switch to another tab, and while they are away the background tab's
// requests get throttled or cut off by the browser. Declaring failure there means the very act of
// completing the authorization aborts it. Every client has hit this same shape, and on Web the rule
// previously had no regression test pinning it down.

import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { act, renderHook } from '@testing-library/react';
import type { OpenAISubscriptionAuthConfig } from '@oriveo/core/providers/openai-subscription';

const requestOpenAIDeviceAuthorization = vi.fn();
const pollOpenAIDeviceToken = vi.fn();
const refreshMetadataOnCodexClientVersionRejected = vi.fn();

vi.mock('../../core/providers/openai-subscription', () => ({
  requestOpenAIDeviceAuthorization: (...args: unknown[]) => requestOpenAIDeviceAuthorization(...args),
  pollOpenAIDeviceToken: (...args: unknown[]) => pollOpenAIDeviceToken(...args),
  refreshMetadataOnCodexClientVersionRejected: (...args: unknown[]) =>
    refreshMetadataOnCodexClientVersionRejected(...args),
}));

import { useOpenAIDeviceAuthorization } from '../useOpenAIDeviceAuthorization';

const CONFIG = {
  clientId: 'client',
  deviceAuthorizationEndpoint: 'https://auth.openai.com/api/accounts/deviceauth/usercode',
  deviceTokenEndpoint: 'https://auth.openai.com/api/accounts/deviceauth/token',
  tokenEndpoint: 'https://auth.openai.com/oauth/token',
  verificationURL: 'https://auth.openai.com/codex/device',
  redirectURI: 'https://auth.openai.com/deviceauth/callback',
  trustedVerificationHosts: ['auth.openai.com'],
  resourceBaseURL: 'https://chatgpt.com/backend-api/codex',
  requiredHeaders: {},
  modelsPath: '/models',
  chatPath: '/responses',
  modelsURL: 'https://chatgpt.com/backend-api/codex/models',
  responsesURL: 'https://chatgpt.com/backend-api/codex/responses',
  pollIntervalSeconds: 5,
  pollTimeoutSeconds: 900,
} as OpenAISubscriptionAuthConfig;

const AUTHORIZATION = {
  deviceAuthID: 'da_1',
  userCode: 'AB-12',
  verificationURL: 'https://auth.openai.com/codex/device',
  expiresIn: 600,
  interval: 1,
};

const CREDENTIAL = { accessToken: 'at', accountID: 'acc-1', obtainedAt: 1 };

beforeEach(() => {
  // Only fake the timing APIs the polling loop needs: faking the whole set also takes over the
  // queueMicrotask / performance the React scheduler relies on, and renderHook then renders nothing.
  vi.useFakeTimers({ toFake: ['setTimeout', 'clearTimeout', 'Date'] });
  requestOpenAIDeviceAuthorization.mockReset().mockResolvedValue({ ok: true, value: AUTHORIZATION });
  pollOpenAIDeviceToken.mockReset();
  refreshMetadataOnCodexClientVersionRejected.mockReset();
});

afterEach(() => {
  vi.useRealTimers();
});

/**
 * Advances one polling interval and drains the pending promises.
 *
 * `waitFor` is not used: it polls on a real timer, and these tests fake setTimeout out, so the wait
 * condition would never be re-evaluated - which shows up as a uniform 5s timeout.
 */
async function tick(seconds = 1) {
  await act(async () => {
    await vi.advanceTimersByTimeAsync(seconds * 1000);
  });
}

/** Drains microtasks only, without advancing time - for the single setState after an async mock resolves. */
async function flush() {
  await act(async () => {
    await vi.advanceTimersByTimeAsync(0);
  });
}

describe('useOpenAIDeviceAuthorization', () => {
  it('continues after a transient transport failure on the first poll and eventually succeeds', async () => {
    // Declaring failure here looks like: the user approves in the browser, comes back, and finds the flow already errored out.
    pollOpenAIDeviceToken
      .mockResolvedValueOnce({ ok: false, error: 'transport' })
      .mockResolvedValueOnce({ ok: false, error: 'authorizationPending' })
      .mockResolvedValueOnce({ ok: true, value: CREDENTIAL });

    const { result } = renderHook(() => useOpenAIDeviceAuthorization(CONFIG));
    act(() => result.current.start());
    await flush();
    expect(result.current.phase.kind).toBe('awaitingAuthorization');

    await tick();
    expect(result.current.phase.kind).toBe('awaitingAuthorization');
    await tick();
    expect(result.current.phase.kind).toBe('awaitingAuthorization');
    await tick();

    expect(result.current.phase).toEqual({ kind: 'succeeded', credential: CREDENTIAL });
    expect(pollOpenAIDeviceToken).toHaveBeenCalledTimes(3);
  });

  it('lengthens the interval on slow_down instead of failing (RFC 8628)', async () => {
    pollOpenAIDeviceToken
      .mockResolvedValueOnce({ ok: false, error: 'slowDown' })
      .mockResolvedValueOnce({ ok: true, value: CREDENTIAL });

    const { result } = renderHook(() => useOpenAIDeviceAuthorization(CONFIG));
    act(() => result.current.start());
    await flush();
    expect(result.current.phase.kind).toBe('awaitingAuthorization');

    await tick(1);
    expect(pollOpenAIDeviceToken).toHaveBeenCalledTimes(1);
    // The interval goes from 1 to 6 seconds, so no second request one second later.
    await tick(1);
    expect(pollOpenAIDeviceToken).toHaveBeenCalledTimes(1);
    await tick(5);
    expect(pollOpenAIDeviceToken).toHaveBeenCalledTimes(2);
    expect(result.current.phase.kind).toBe('succeeded');
  });

  it('treats a user denial as terminal and stops polling', async () => {
    pollOpenAIDeviceToken.mockResolvedValue({ ok: false, error: 'accessDenied' });

    const { result } = renderHook(() => useOpenAIDeviceAuthorization(CONFIG));
    act(() => result.current.start());
    await flush();
    expect(result.current.phase.kind).toBe('awaitingAuthorization');

    await tick();
    expect(result.current.phase).toEqual({ kind: 'failed', error: 'accessDenied' });
    await tick(10);
    expect(pollOpenAIDeviceToken).toHaveBeenCalledTimes(1);
  });

  it('treats 426 as terminal and triggers one forced config refresh', async () => {
    pollOpenAIDeviceToken.mockResolvedValue({ ok: false, error: 'clientVersionRejected' });

    const { result } = renderHook(() => useOpenAIDeviceAuthorization(CONFIG));
    act(() => result.current.start());
    await flush();
    expect(result.current.phase.kind).toBe('awaitingAuthorization');

    await tick();
    expect(result.current.phase.kind).toBe('failed');
    expect(refreshMetadataOnCodexClientVersionRejected)
      .toHaveBeenCalledWith('clientVersionRejected');
  });

  it('stops polling once the short code expires, so upstream gets no useless traffic', async () => {
    pollOpenAIDeviceToken.mockResolvedValue({ ok: false, error: 'authorizationPending' });
    requestOpenAIDeviceAuthorization.mockResolvedValue({
      ok: true, value: { ...AUTHORIZATION, expiresIn: 2 },
    });

    const { result } = renderHook(() => useOpenAIDeviceAuthorization(CONFIG));
    act(() => result.current.start());
    await flush();
    expect(result.current.phase.kind).toBe('awaitingAuthorization');

    await tick(1);
    await tick(1);
    await tick(1);
    await flush();
    expect(result.current.phase).toEqual({ kind: 'failed', error: 'codeExpired' });
    const callsAtExpiry = pollOpenAIDeviceToken.mock.calls.length;
    await tick(10);
    expect(pollOpenAIDeviceToken).toHaveBeenCalledTimes(callsAtExpiry);
  });

  it('does not start the flow without a config and reports configuration unavailable', async () => {
    const { result } = renderHook(() => useOpenAIDeviceAuthorization(null));
    act(() => result.current.start());
    expect(result.current.phase).toEqual({ kind: 'failed', error: 'configurationUnavailable' });
    expect(requestOpenAIDeviceAuthorization).not.toHaveBeenCalled();
  });

  it('returns to idle and stops polling after cancel', async () => {
    pollOpenAIDeviceToken.mockResolvedValue({ ok: false, error: 'authorizationPending' });

    const { result } = renderHook(() => useOpenAIDeviceAuthorization(CONFIG));
    act(() => result.current.start());
    await flush();
    expect(result.current.phase.kind).toBe('awaitingAuthorization');
    await tick();
    const callsBeforeCancel = pollOpenAIDeviceToken.mock.calls.length;

    act(() => result.current.cancel());
    expect(result.current.phase).toEqual({ kind: 'idle' });
    await tick(10);
    expect(pollOpenAIDeviceToken).toHaveBeenCalledTimes(callsBeforeCancel);
  });

  it('polls with the identifiers obtained by this round of device authorization', async () => {
    pollOpenAIDeviceToken.mockResolvedValue({ ok: true, value: CREDENTIAL });

    const { result } = renderHook(() => useOpenAIDeviceAuthorization(CONFIG));
    act(() => result.current.start());
    await flush();
    expect(result.current.phase.kind).toBe('awaitingAuthorization');
    await tick();

    expect(pollOpenAIDeviceToken).toHaveBeenCalledWith('da_1', 'AB-12');
  });
});
