import type { Conversation } from '@oriveo/shared';

/**
 * Conversation loading state machine.
 *
 * Pure functions, no side effects and no timers: the caller advances the clock through
 * elapsedSinceEnterMs, so tests can pin the 12s threshold exactly with a fake clock.
 */
export type ChatLoadState =
  | 'localFailure'
  | 'deleted'
  | 'content'
  | 'backfilling'
  | 'bootstrapping'
  | 'stalled'
  | 'empty';

/** Progress of restoring history that exists remotely but not on this device. */
export type BackfillPhase =
  | 'idle'
  /**
   * The rules decided this conversation will not start a backfill (a listener is already
   * running, the user is signed out, or no backfill is needed). Strictly distinct from 'idle'
   * (not started yet): without it the state machine cannot tell "waiting for a backfill" from
   * "no backfill is coming".
   */
  | 'skipped'
  | 'running'
  | 'succeededWithDocs'
  | 'succeededEmpty'
  | 'failed';

/**
 * Timeout from entering a conversation to declaring it stalled.
 *
 * Deliberately not the unavailableThreshold (180s) used by the home sync indicator: that answers
 * "how long before background sync counts as offline", and staring at a skeleton in the chat view
 * for three minutes is not acceptable.
 */
export const CHAT_LOAD_STALL_TIMEOUT_MS = 12_000;

export interface ChatLoadStateInput {
  requestedConversationId: string | null | undefined;
  conversation: Conversation | undefined;
  /** Whether the store has loaded this conversation's metadata at least once, which separates "not read yet" from "really gone". */
  hasLoadedSummary: boolean;
  /** The local database or observer failed to read. */
  localLoadFailed?: boolean;
  backfillPhase: BackfillPhase;
  elapsedSinceEnterMs: number;
}

function hasDraftIntent(conversation: Conversation): boolean {
  return conversation.isDraft === true || (conversation.draftText ?? '').trim().length > 0;
}

/**
 * Whether the metadata shows any sign that this conversation has remote history.
 *
 * Used only as a veto: any non-empty signal forbids falling into an empty state. Both empty-state
 * branches pass through this gate, rule 5 (no backfill will happen) and rule 9 (the backfill
 * measured zero messages). Using it the other way round, as proof that history exists, is wrong:
 * cross-device metadata can lag behind, which is exactly the trap in the older logic.
 */
function hasRemoteHistoryEvidence(conversation: Conversation): boolean {
  return (
    (conversation.remoteMessageCount ?? 0) > 0 ||
    conversation.messages.length > 0 ||
    (conversation.previewText ?? '').trim().length > 0
  );
}

/**
 * Priority chain: the first match returns, and the order must not be rearranged.
 *
 * On the question of whether history exists, previewText, remoteMessageCount and messageCount are
 * deliberately not consulted. Those fields can be missing or stale when synced from another
 * device, and guessing from them fails in both directions: guessing that history exists leaves an
 * empty conversation stuck on a skeleton forever, and guessing that it does not drops a
 * conversation with history straight onto the welcome page, where the user starts talking and
 * silently loses the context. The chain instead lets the measured number of messages returned by
 * the backfill decide: only succeededEmpty (the server really has zero) may fall into empty.
 */
export function resolveChatLoadState(input: ChatLoadStateInput): ChatLoadState {
  const {
    requestedConversationId,
    conversation,
    hasLoadedSummary,
    localLoadFailed,
    backfillPhase,
    elapsedSinceEnterMs,
  } = input;

  // 1. Local read failed
  if (localLoadFailed) return 'localFailure';

  // With no target conversation (home, or a new one) there is no history to wait for, so go straight to the welcome page.
  if (!requestedConversationId) return 'empty';

  // 2. The conversation is confirmed to be gone
  if (hasLoadedSummary && !conversation) return 'deleted';

  // 3. Body text is already local; this beats every loading state and is the structural guarantee that arriving messages always dismiss the skeleton
  if (conversation && conversation.messages.length > 0) return 'content';

  // 4. Draft: created locally and not sent yet, so there is no history to load
  if (conversation && hasDraftIntent(conversation)) return 'empty';

  // 5. No backfill will happen (a listener is running, the user is signed out, or no backfill is
  //    needed) and the metadata shows no sign of history at all.
  //    Then this really is an empty conversation (the user cleared the last message, or an empty
  //    conversation was pulled from the server), so show the welcome page.
  //
  //    This is the only exception to the measurement-first rule, and it is pinned by two
  //    conditions:
  //    (a) it applies only on the branch where no measurement can ever arrive ('skipped', never
  //        'idle');
  //    (b) the conversation must already be in hand and all three signals must be empty. Any
  //        non-empty signal keeps waiting: better stalled than letting the user start talking in
  //        a conversation that has history, since silently losing context is far worse than
  //        waiting another 12 seconds.
  //    Without this rule, a signed-in user with a running listener would sit on a skeleton for
  //    12s on any empty conversation before getting an error and a disabled composer.
  if (backfillPhase === 'skipped' && conversation && !hasRemoteHistoryEvidence(conversation)) {
    return 'empty';
  }

  // An in-flight one-time read remains visibly active even when it exceeds the
  // bootstrap watchdog threshold. The watchdog only covers unresolved startup.
  if (backfillPhase === 'running') return 'backfilling';

  // 6. Backfill failed
  if (backfillPhase === 'failed') return 'stalled';

  // 7. Timeout
  if (elapsedSinceEnterMs >= CHAT_LOAD_STALL_TIMEOUT_MS) return 'stalled';

  // 9. The backfill measured zero messages on the server, but when the metadata says this
  //    conversation has history the conclusion is not accepted: fall to stalled and offer a retry.
  //
  //    Measurement-first assumes the measurement really came from the server. Once the backfill
  //    gets an empty result from anywhere else (a remote cache fallback being the classic
  //    case), the zero is false, and falling into 'empty' would render a conversation with
  //    complete remote history as empty and still let the user start talking in it: context is
  //    silently lost, and the user is likely to delete it too.
  if (backfillPhase === 'succeededEmpty') {
    return conversation && hasRemoteHistoryEvidence(conversation) ? 'stalled' : 'empty';
  }

  // 10. Local read or listener still in progress
  return 'bootstrapping';
}

/** Skeleton form (backfilling and bootstrapping share the same skeleton). */
export function isChatLoadSkeleton(state: ChatLoadState): boolean {
  return state === 'backfilling' || state === 'bootstrapping';
}

/**
 * Whether the composer has to be disabled.
 *
 * Blocking sending while stalled is a hard requirement: at that point there is no local body text
 * but the server has history, and letting a message through would append it to a conversation
 * that looks empty, silently losing the historical context.
 */
export function isChatComposerBlocked(state: ChatLoadState): boolean {
  return isChatLoadSkeleton(state) || state === 'stalled' || state === 'localFailure';
}
