import { act, renderHook } from '@testing-library/react';
import { describe, expect, it } from 'vitest';
import { useCustomLLMConnectionCoordinator } from './custom-llm-connection-coordinator';
import type { RelayDiscoveryResult } from '../../../../lib/core/providers/probe/probe-runner';

describe('useCustomLLMConnectionCoordinator', () => {
  it('after switching scenarios, stale generation verification and catalog evidence can neither be committed nor navigated from', async () => {
    const { result } = renderHook(() => useCustomLLMConnectionCoordinator());
    const completed = { current: null as Awaited<ReturnType<typeof result.current.run>> };

    await act(async () => {
      completed.current = await result.current.run<RelayDiscoveryResult>('relay', async () => ({
        state: 'verified',
        attempts: [],
        retriedRequestCount: 0,
        detection: {
          apiBaseURL: 'https://relay.example.test/v1',
          transport: 'openai_chat_completions',
          authMode: 'bearer',
          modelIDs: ['gpt-test'],
          catalogModels: [],
          generationVerified: true,
          catalogEvidenceSucceeded: true,
          detectionEvidence: 'generation_probe',
        },
      }), () => ({ verification: true, catalog: true, canCommit: true }), () => ({
        state: 'failed',
        attempts: [],
        failure: 'network',
        retriedRequestCount: 0,
      }));
    });

    // `completed` is produced by the production hook rather than test-authored state; its evidence is the same rule the button and the persistence use.
    expect(completed.current?.evidence).toEqual({ verification: true, catalog: true, canCommit: true });
    expect(result.current.canCommit(completed.current)).toBe(true);

    await act(async () => {
      // Switching a local segment on a Relay goes through exactly this invalidate: abort + clear + generation++.
      result.current.invalidate();
    });

    let navigated = false;
    if (result.current.canCommit(completed.current)) navigated = true;
    expect(result.current.result).toBeNull();
    expect(result.current.phase).toBe('ready');
    expect(result.current.canCommit(completed.current)).toBe(false);
    expect(navigated).toBe(false);
  });

  it('normalizes an operation rejection into the coordinator failed phase instead of leaving the scenario child to hold the error state', async () => {
    const { result } = renderHook(() => useCustomLLMConnectionCoordinator());

    await act(async () => {
      await result.current.run(
        'local',
        async () => Promise.reject(new Error('offline')),
        (next) => ({ verification: next.generationVerified, catalog: next.modelIDs.length > 0, canCommit: false }),
        () => ({
          state: 'unreachable',
          failure: 'cors_blocked',
          endpoint: 'http://127.0.0.1:11434',
          modelIDs: [],
          models: [],
          generationVerified: false,
        }),
      );
    });

    expect(result.current.phase).toBe('failed');
    expect(result.current.result?.evidence).toEqual({ verification: false, catalog: false, canCommit: false });
    expect(result.current.canCommit(result.current.result)).toBe(false);
  });
});
