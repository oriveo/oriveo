import type { Provider } from '@oriveo/shared';
import { relayKeyIDs, type RelayKeyOp } from '@oriveo/shared/relay/relay-keys';
import { relayKeyNotice, relayKeyOpFetchedKeyID, sameRelayKeyNotice, type RelayKeyNotice } from './relay-keys-board';

/**
 * Keys page state (BOARD-KEYS-14 / 15): in-flight fetches are counted per key, hints are appended one by one with same-sentence dedupe;
 * each begin withdraws the previous round's hints. Pure functions; the component only calls begin / finish before and after an operation.
 */
export interface RelayKeysPageState {
  /** The keys currently fetching the catalog -> in-flight count. */
  fetching: Readonly<Record<string, number>>;
  notices: readonly RelayKeyNotice[];
}

export const initialRelayKeysPageState: RelayKeysPageState = { fetching: {}, notices: [] };

export function relayKeysPageFetchingIDs(state: RelayKeysPageState): Set<string> {
  return new Set(Object.keys(state.fetching));
}

/**
 * The keys this operation fetches the catalog for (their rows show fetching): add re-fetches all = the keys before the operation + the new key;
 * replaceSecret only that key; others fetch nothing. The outcome hint still looks only at the key given by relayKeyOpFetchedKeyID.
 */
export function relayKeyOpFetchingIDs(op: RelayKeyOp, provider: Provider | undefined): string[] {
  const keyID = relayKeyOpFetchedKeyID(op);
  if (!keyID) return [];
  if (op.type !== 'add' || !provider) return [keyID];
  return [...relayKeyIDs(provider).filter((id) => id !== keyID), keyID];
}

export function beginRelayKeyOp(
  state: RelayKeysPageState,
  op: RelayKeyOp,
  fetchedIDs: readonly string[] = relayKeyOpFetchingIDs(op, undefined),
): RelayKeysPageState {
  const fetching = { ...state.fetching };
  for (const id of fetchedIDs) fetching[id] = (fetching[id] ?? 0) + 1;
  return { fetching, notices: [] };
}

/**
 * When the same key still has other operations in flight, the one that finishes first (accepted) neither removes the fetching state nor reports, leaving it to the last one to report using the connection at its completion;
 * a rejected one is still reported. `provider` is the connection at the end of the operation.
 */
export function finishRelayKeyOp(
  state: RelayKeysPageState,
  op: RelayKeyOp,
  accepted: boolean,
  provider: Provider | undefined,
  fetchedIDs: readonly string[] = relayKeyOpFetchingIDs(op, undefined),
): RelayKeysPageState {
  const keyID = relayKeyOpFetchedKeyID(op);
  const fetching = { ...state.fetching };
  let remaining = 0;
  for (const id of fetchedIDs) {
    if (!(id in fetching)) continue;
    const left = fetching[id]! - 1;
    if (left > 0) fetching[id] = left;
    else delete fetching[id];
    // The report looks only at the one key this operation fetched (newly added / value replaced).
    if (id === keyID) remaining = left;
  }
  const notice = !accepted
    ? 'rejected'
    : remaining > 0 || !provider ? null : relayKeyNotice(provider, op, true);
  const notices = notice && !state.notices.some((item) => sameRelayKeyNotice(item, notice))
    ? [...state.notices, notice]
    : state.notices;
  return { fetching, notices };
}
