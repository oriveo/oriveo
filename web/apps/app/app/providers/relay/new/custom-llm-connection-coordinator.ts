'use client';

import { useCallback, useEffect, useRef, useState } from 'react';
import type { LocalBrowserConnectionResult } from '../../../../lib/core/providers/local-browser-probe';
import type { RelayDiscoveryResult } from '../../../../lib/core/providers/probe/probe-runner';

/**
 * The single owner of connection attempts on the "add a custom LLM" page.
 *
 * Relay and local engines still run their own protocol probes (the latter has to connect directly
 * from the browser and cannot go through a relay proxy), but cancellation, results, generation
 * and submittability are decided only here. That way a stale async result can neither be
 * displayed again nor persisted after the segment is switched.
 */
export type CustomLLMScenario = 'relay' | 'local';

export type CustomLLMConnectionValue = RelayDiscoveryResult | LocalBrowserConnectionResult;

/** Records probe facts only; neither the UI nor persistence may read "request finished" as "connection verified". */
export interface CustomLLMConnectionEvidence {
  verification: boolean;
  catalog: boolean;
  canCommit: boolean;
}

export type CustomLLMActionPhase = 'ready' | 'detecting' | 'ready_to_commit' | 'failed';

export interface CustomLLMConnectionResult<T extends CustomLLMConnectionValue = CustomLLMConnectionValue> {
  scenario: CustomLLMScenario;
  generation: number;
  value: T;
  evidence: CustomLLMConnectionEvidence;
}

export interface CustomLLMConnectionCoordinator {
  result: CustomLLMConnectionResult | null;
  phase: CustomLLMActionPhase;
  /** The single busy state and runnable condition for every scenario; child components must not keep their own discover/connect phase. */
  canRun: boolean;
  invalidate: () => void;
  run: <T extends CustomLLMConnectionValue>(
    scenario: CustomLLMScenario,
    operation: (signal: AbortSignal) => Promise<T>,
    evidenceFor: (value: T) => CustomLLMConnectionEvidence,
    failureFor: (error: unknown) => T,
  ) => Promise<CustomLLMConnectionResult<T> | null>;
  canCommit: (result: CustomLLMConnectionResult | null) => boolean;
}

export function useCustomLLMConnectionCoordinator(): CustomLLMConnectionCoordinator {
  const [result, setResult] = useState<CustomLLMConnectionResult | null>(null);
  const [phase, setPhase] = useState<CustomLLMActionPhase>('ready');
  const generationRef = useRef(0);
  const controllerRef = useRef<AbortController | null>(null);

  useEffect(() => () => {
    generationRef.current += 1;
    controllerRef.current?.abort();
    controllerRef.current = null;
  }, []);

  const invalidate = useCallback(() => {
    generationRef.current += 1;
    controllerRef.current?.abort();
    controllerRef.current = null;
    setResult(null);
    setPhase('ready');
  }, []);

  const run = useCallback(async <T extends CustomLLMConnectionValue>(
    scenario: CustomLLMScenario,
    operation: (signal: AbortSignal) => Promise<T>,
    evidenceFor: (value: T) => CustomLLMConnectionEvidence,
    failureFor: (error: unknown) => T,
  ): Promise<CustomLLMConnectionResult<T> | null> => {
    generationRef.current += 1;
    const generation = generationRef.current;
    controllerRef.current?.abort();
    const controller = new AbortController();
    controllerRef.current = controller;
    setResult(null);
    setPhase('detecting');

    try {
      let value: T;
      try {
        value = await operation(controller.signal);
      } catch (error) {
        // Cancellation is the normal end of a stale generation; every other exception has to be
        // converted into the same result/phase, rather than child components each keeping their
        // own network error state.
        if (controller.signal.aborted) return null;
        value = failureFor(error);
      }
      if (generation !== generationRef.current || controller.signal.aborted) return null;
      const evidence = evidenceFor(value);
      const next: CustomLLMConnectionResult<T> = { scenario, generation, value, evidence };
      setResult(next);
      setPhase(evidence.canCommit ? 'ready_to_commit' : 'failed');
      return next;
    } finally {
      if (generation === generationRef.current) {
        controllerRef.current = null;
        setPhase((current) => current === 'detecting' ? 'ready' : current);
      }
    }
  }, []);

  const canCommit = useCallback((candidate: CustomLLMConnectionResult | null) => (
    candidate !== null
    && candidate === result
    && candidate.generation === generationRef.current
    && phase !== 'detecting'
    && candidate.evidence.canCommit
  ), [phase, result]);

  return { result, phase, canRun: phase !== 'detecting', invalidate, run, canCommit };
}
