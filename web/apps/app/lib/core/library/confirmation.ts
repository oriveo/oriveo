import type { StoreApi } from 'zustand';
import type { AppStore } from '../store/app-store';
import type {
  LibraryConfirmationChoice,
  LibraryConfirmationRequest,
} from './types';

type PendingConfirmation = {
  id: string;
  store: StoreApi<AppStore>;
  request: LibraryConfirmationRequest;
  settle: (choice: LibraryConfirmationChoice) => void;
};

/**
 * FIFO queue of pending confirmations. The head is the dialog currently on screen and the rest wait
 * their turn.
 *
 * With a single pending slot, a newcomer's first act was to `settle('cancel')` the previous one,
 * which is the same as pressing "cancel" on someone else's dialog. Several conversations stream
 * concurrently in the background, so while conversation A sits on a confirmation, conversation B
 * can raise one too, and A would be reported as cancelled without the user touching anything.
 *
 * With a queue nothing is evicted: the UI shows only the head, and settling the head promotes the
 * next entry. Each confirmation still carries its own AbortSignal, and aborting it dequeues only
 * that entry.
 */
const queue: PendingConfirmation[] = [];

/** Dequeue and sync the display to the new head; only a head dequeue needs to touch the UI. */
function dequeue(entry: PendingConfirmation): void {
  const index = queue.indexOf(entry);
  if (index < 0) return;
  queue.splice(index, 1);
  if (index !== 0) return;
  const next = queue[0];
  if (next) {
    next.store.getState().setLibraryConfirmation(next.request);
    return;
  }
  const state = entry.store.getState();
  if (state.libraryConfirmation?.id === entry.id) {
    state.setLibraryConfirmation(null);
  }
}

export function requestLibraryConfirmation(
  store: StoreApi<AppStore>,
  request: LibraryConfirmationRequest,
  signal: AbortSignal,
): Promise<LibraryConfirmationChoice> {
  // An already-cancelled send should not take a slot in the queue, let alone displace someone else's dialog
  if (signal.aborted) return Promise.resolve('cancel');
  return new Promise((resolve) => {
    let settled = false;
    const finish = (choice: LibraryConfirmationChoice) => {
      if (settled) return;
      settled = true;
      signal.removeEventListener('abort', onAbort);
      dequeue(entry);
      resolve(choice);
    };
    const onAbort = () => finish('cancel');
    const entry: PendingConfirmation = {
      id: request.id,
      store,
      request,
      settle: finish,
    };
    signal.addEventListener('abort', onAbort, { once: true });
    queue.push(entry);
    if (queue[0] === entry) store.getState().setLibraryConfirmation(request);
  });
}

export function resolveLibraryConfirmation(choice: LibraryConfirmationChoice): void {
  // What the user clicked is always the dialog at the head of the queue
  queue[0]?.settle(choice);
}

export function cancelPendingLibraryConfirmation(): void {
  queue[0]?.settle('cancel');
}

/**
 * On wrap-up, clear only the confirmation this send raised itself.
 *
 * Sending in one conversation does not abort another, so an unconditional
 * `setLibraryConfirmation(null)` when conversation A finishes normally would wipe the dialog that
 * conversation B is still waiting on. B's promise only settles on resolve or abort, so with the
 * dialog gone nobody can ever click it: B's send hangs forever and the composer stays locked until
 * the user presses stop manually.
 */
export function clearOwnLibraryConfirmation(
  store: StoreApi<AppStore>,
  ownRequestIds: ReadonlySet<string>,
): void {
  const current = store.getState().libraryConfirmation;
  if (!current || !ownRequestIds.has(current.id)) return;
  const head = queue[0];
  // This send has already wrapped up (this is the finally), so a dialog still sitting at the head
  // would hold the slot forever and block everything queued behind it. Dequeue it and promote the next.
  if (head && head.id === current.id) {
    head.settle('cancel');
    return;
  }
  store.getState().setLibraryConfirmation(null);
}
