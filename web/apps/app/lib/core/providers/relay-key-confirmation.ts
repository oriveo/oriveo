/**
 * Relay signals "key value replaced / model send succeeded": replacing the primary key (provider-ops) and the send write-back emit here, and the holder of lazy-verification state
 * (relay-model-probe-ops) subscribes and clears "not connected". It goes through subscription rather than a direct call because relay-model-probe-ops
 * depends on provider-ops indirectly via provider-sync, and importing in the reverse direction would form a cycle.
 * Neither a successful catalog fetch nor a key status written as normal emits: a relay may gate only one transport, and key normal ≠ model usable.
 */

import type { StoreApi } from 'zustand';
import type { AppStore } from '../store/app-store';

export type RelayKeyConfirmationSignal =
  /** The values of these keys were replaced. */
  | { type: 'keySecretReplaced'; store: StoreApi<AppStore>; providerID: string; keyIDs: readonly string[] }
  /** A send of this model reached delivered. */
  | { type: 'modelDelivered'; providerID: string; modelID: string };

type Listener = (signal: RelayKeyConfirmationSignal) => void;

const listeners = new Set<Listener>();

export function subscribeRelayKeyConfirmation(listener: Listener): () => void {
  listeners.add(listener);
  return () => listeners.delete(listener);
}

export function emitRelayKeyConfirmation(signal: RelayKeyConfirmationSignal): void {
  for (const listener of listeners) listener(signal);
}
