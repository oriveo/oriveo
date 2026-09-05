import { useState, useMemo, useEffect, useRef, useCallback } from 'react';
import type { Conversation } from '@oriveo/shared';
import { warmConversationInStore } from '../../../lib/core/chat/conversation-bootstrap';
import {
  resolveChatLoadState,
  isChatLoadSkeleton,
  isChatComposerBlocked,
  CHAT_LOAD_STALL_TIMEOUT_MS,
  type BackfillPhase,
  type ChatLoadState,
} from '../../../lib/core/chat/chat-load-state';
import { loadSyncCore } from '../../../lib/core/sync-lazy';
import { getActiveUIDSync } from '../../../lib/infra/storage/partition';
import { useAppStore } from '../../../providers/StoreProvider';

/**
 * Load orchestration for entering an existing conversation.
 *
 * Two stages: warm the conversation out of IndexedDB, then a 12s watchdog that marks the load
 * stalled. The decisions themselves live in the pure functions in chat-load-state.ts; this hook
 * only advances the inputs.
 *
 * With a sync backend installed there is a third stage between the two, where history that exists
 * remotely but not on this device is restored; `backfillPhase` is the input that stage feeds.
 *
 * Note where a timeout lands: never on "empty plus writable". Letting the user type when there is
 * no local text but history may still arrive means they keep chatting in a conversation that looks
 * blank while its context is silently lost. A timeout therefore always lands on stalled: error
 * card, retry as the primary action, composer disabled.
 */
export function useConversationHydration(
  effectiveId: string | null | undefined,
  conversation: Conversation | undefined,
) {
  const lastResolvedConversationIdRef = useRef<string | null>(null);
  const stallTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  /** Read the state at the moment the watchdog fires; the setTimeout closure cannot see the latest loadState. */
  const loadStateRef = useRef<ChatLoadState>('bootstrapping');
  // A workspace switch always advances hydrationPhase; subscribing to it triggers a re-render and
  // the sync UID then changes the effect identity, so an A to B account switch on the same
  // conversation ID also cancels A's stale result.
  useAppStore((state) => state.hydrationPhase);
  const partitionUID = getActiveUIDSync();

  const [backfillPhase, setBackfillPhase] = useState<BackfillPhase>('idle');
  const [hasStalled, setHasStalled] = useState(false);
  const [localLoadFailed, setLocalLoadFailed] = useState(false);
  const [retryToken, setRetryToken] = useState(0);
  const [syncListenerEpoch, setSyncListenerEpoch] = useState(0);

  // A backend can be installed or removed at any time. Subscribing to that lifecycle re-evaluates
  // the conversation that is currently open instead of leaving it on a stale phase.
  useEffect(() => {
    let cancelled = false;
    let unsubscribe: (() => void) | undefined;
    void loadSyncCore().then(({ subscribeSyncAdapter }) => {
      if (cancelled) return;
      // Keep lightweight test / embedded sync shims compatible with the hook.
      if (typeof subscribeSyncAdapter !== 'function') return;
      unsubscribe = subscribeSyncAdapter(() => {
        setSyncListenerEpoch((epoch) => epoch + 1);
      });
    });
    return () => {
      cancelled = true;
      unsubscribe?.();
    };
  }, []);

  useEffect(() => {
    if (!effectiveId) {
      lastResolvedConversationIdRef.current = null;
      return;
    }
    if (conversation) {
      lastResolvedConversationIdRef.current = effectiveId;
    }
  }, [effectiveId, conversation]);

  const clearStallTimer = useCallback(() => {
    if (stallTimerRef.current) {
      clearTimeout(stallTimerRef.current);
      stallTimerRef.current = null;
    }
  }, []);

  useEffect(() => {
    if (!effectiveId) return;

    const signal = { cancelled: false };
    setBackfillPhase('idle');
    setHasStalled(false);
    setLocalLoadFailed(false);

    clearStallTimer();
    stallTimerRef.current = setTimeout(() => {
      if (signal.cancelled) return;
      // This only covers "bootstrap never settles", never an in-flight restore. Otherwise the flag
      // would be set silently at 12s and a restore that afterwards confirms there really are zero
      // messages would still be judged stalled, putting this surface on an error card where the
      // same situation reads as empty everywhere else.
      if (loadStateRef.current !== 'bootstrapping') return;
      setHasStalled(true);
    }, CHAT_LOAD_STALL_TIMEOUT_MS);

    void (async () => {
      let warmed: Conversation | undefined;
      try {
        warmed = await warmConversationInStore(effectiveId);
      } catch {
        if (!signal.cancelled) setLocalLoadFailed(true);
        return;
      }
      if (signal.cancelled) return;
      if (warmed && warmed.messages.length > 0) return;

      // Nothing restored this conversation's bodies, and that has to leave a trace: 'skipped' is
      // what lets the state machine report a conversation with metadata but no messages as
      // "history could not be restored" instead of holding the skeleton until the watchdog fires.
      if (!signal.cancelled) setBackfillPhase('skipped');
    })();

    return () => {
      signal.cancelled = true;
      clearStallTimer();
    };
  }, [effectiveId, retryToken, clearStallTimer, partitionUID, syncListenerEpoch]);

  const hasLoadedSummary = lastResolvedConversationIdRef.current === effectiveId;

  const loadState: ChatLoadState = useMemo(
    () =>
      resolveChatLoadState({
        requestedConversationId: effectiveId,
        conversation,
        hasLoadedSummary,
        localLoadFailed,
        backfillPhase,
        // Whether the timer has passed the threshold is decided by setTimeout; the pure function only cares whether the elapsed time is at or above it.
        elapsedSinceEnterMs: hasStalled ? CHAT_LOAD_STALL_TIMEOUT_MS : 0,
      }),
    // hasLoadedSummary is derived from a ref and does not drive re-renders on its own, but it only
    // changes the outcome when conversation goes from present to absent, and that change always
    // comes with a re-render.
    [effectiveId, conversation, hasLoadedSummary, localLoadFailed, backfillPhase, hasStalled],
  );

  // Stop the timer once a terminal state is reached, otherwise a confirmed-empty result would be
  // overwritten as stalled at 12s: the timeout ranks ahead of it in the priority chain.
  useEffect(() => {
    loadStateRef.current = loadState;
    if (loadState === 'bootstrapping' || loadState === 'backfilling') return;
    clearStallTimer();
  }, [loadState, clearStallTimer]);

  /** Primary action on the stalled card: reset the timer and run the load again. */
  const retryHydration = useCallback(() => {
    setRetryToken((token) => token + 1);
  }, []);

  /**
   * "Stop restoring": settle on the stalled card with retry as the primary action.
   *
   * A restore has no upper time limit, because a long conversation on a slow connection is not a
   * failure, so the user needs a way out that the watchdog does not provide.
   */
  const cancelBackfill = useCallback(() => {
    setBackfillPhase((phase) => (phase === 'running' ? 'failed' : phase));
  }, []);

  return {
    loadState,
    retryHydration,
    cancelBackfill,
    shouldShowConversationBootstrap: isChatLoadSkeleton(loadState),
    isComposerBlocked: isChatComposerBlocked(loadState),
  };
}
