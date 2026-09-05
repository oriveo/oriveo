/**
 * Module-level lifecycle listeners: visibilitychange / pagehide handling across all active streams.
 *
 * They live at module level rather than inside a ChatView hook because:
 *   - background streams: navigating to a non-chat route such as /settings unmounts ChatView, and
 *     with the listener bound in a hook the cleanup would leave a later tab crash or pagehide with
 *     no sessionStorage backup, losing every partial stream;
 *   - both listeners handle a lifecycle signal that spans all active conversations, so they are
 *     unrelated to any ChatView instance and should live outside the React lifecycle.
 *
 * Registration:
 *   - installed explicitly by bootstrap once StoreProvider has created the store
 *   - loading the module has no side effects, so a listener cannot react to a lifecycle event
 *     before the store is initialized
 *   - tests call installStreamLifecycleListeners() when they need it
 */

import {
  backupAllStreamsToSessionStorage,
  flushAllStreamsForLifecycle,
} from './active-streams';

let installed = false;

function handleVisibility(): void {
  if (typeof document === 'undefined') return;
  if (document.visibilityState !== 'hidden') return;
  // hidden: flush every conversation partial into message.text; state stays generating because the stream may still be running
  flushAllStreamsForLifecycle();
}

function handlePageHide(): void {
  // 1) write pending batcher output into the store
  // 2) write every partial into sessionStorage (an IDB commit is not guaranteed in a synchronous context)
  flushAllStreamsForLifecycle();
  backupAllStreamsToSessionStorage();
}

/**
 * Install the lifecycle listeners. Idempotent: repeated calls register once.
 * Production calls this from bootstrap.ts; tests call it as needed.
 */
export function installStreamLifecycleListeners(): void {
  if (installed) return;
  if (typeof document === 'undefined' || typeof window === 'undefined') return;
  installed = true;
  document.addEventListener('visibilitychange', handleVisibility);
  window.addEventListener('pagehide', handlePageHide);
}

/** Test only: remove the listeners and allow re-registration. */
export function __resetStreamLifecycleListenersForTests(): void {
  if (typeof document !== 'undefined') {
    document.removeEventListener('visibilitychange', handleVisibility);
  }
  if (typeof window !== 'undefined') {
    window.removeEventListener('pagehide', handlePageHide);
  }
  installed = false;
}
