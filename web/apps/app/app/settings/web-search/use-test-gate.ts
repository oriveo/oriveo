// "Test passes before saving" state machine shared by the connect page, custom consent and detail key change.

import { useCallback, useState } from 'react';
import { searchTestPresentation, type SearchTestOutcome, type SearchTestPresentation } from '@oriveo/core/search/search-settings';

export type TestGateState =
  | { phase: 'idle' }
  | { phase: 'testing' }
  | { phase: 'passed'; presentation: Extract<SearchTestPresentation, { state: 'passed' }> }
  | { phase: 'failed'; presentation: Extract<SearchTestPresentation, { state: 'failed' }> };

/**
 * run(test, save): runs the test search; only a passed outcome calls `save`. Results live in memory only.
 * `initial` lets the dev shots render an already finished outcome (production starts idle).
 */
export function useTestGate(initial: TestGateState = { phase: 'idle' }) {
  const [state, setState] = useState<TestGateState>(initial);
  const run = useCallback(async (test: () => Promise<SearchTestOutcome>, save?: () => Promise<void>) => {
    setState({ phase: 'testing' });
    let outcome: SearchTestOutcome;
    try {
      outcome = await test();
    } catch {
      outcome = { ok: false, error: null };
    }
    const presentation = searchTestPresentation({ outcome });
    if (presentation.state === 'passed') {
      if (save) await save();
      setState({ phase: 'passed', presentation });
    } else {
      setState({ phase: 'failed', presentation });
    }
    return presentation;
  }, []);
  const reset = useCallback(() => setState({ phase: 'idle' }), []);
  return { state, run, reset };
}
