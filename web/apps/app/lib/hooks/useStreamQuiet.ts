'use client';

import { useEffect, useState } from 'react';
import { STREAM_QUIET_THRESHOLD_MS } from '../core/chat/stream-activity-presentation';

const NEVER = Symbol('never-quiet');

/**
 * Whether the visible content has paused: true once `signal` has stayed the same for
 * {@link STREAM_QUIET_THRESHOLD_MS}.
 *
 * The state records which signal the pause was established for, not a boolean. As soon as the
 * signal changes the result is false again within that same render, so the pause of the previous
 * stretch never paints one extra frame.
 */
export function useStreamQuiet(active: boolean, signal: string | number): boolean {
  const [quietFor, setQuietFor] = useState<string | number | typeof NEVER>(NEVER);

  useEffect(() => {
    if (!active) return;
    const timer = setTimeout(() => setQuietFor(signal), STREAM_QUIET_THRESHOLD_MS);
    return () => clearTimeout(timer);
  }, [active, signal]);

  return active && quietFor === signal;
}
