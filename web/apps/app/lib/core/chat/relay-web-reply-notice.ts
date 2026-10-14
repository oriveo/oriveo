/**
 * Reply notice for relay web search (fixture web-probe.v1.json chatCases replyNotice): when the web switch is on
 * but the delivered request carried no web fragment (current record rejected / fallback target protocol rejected / resent without the fragment after web parameters were rejected),
 * a one-line secondary note is attached under that assistant reply. Kept in session memory only: no message field, nothing persisted, nothing sent to the cloud,
 * and it disappears when the page is refreshed.
 */
import { create } from 'zustand';
import type { Provider } from '@oriveo/shared';
import type { StreamOptions } from '@oriveo/core/providers/types';

export type RelayWebReplyNotice = 'web_not_used';

const useReplyNoticeStore = create<{ notices: Readonly<Record<string, RelayWebReplyNotice>> }>(() => ({ notices: {} }));

/** Write / clear by assistant message id (null clears). */
export function setRelayWebReplyNotice(messageId: string, notice: RelayWebReplyNotice | null): void {
  useReplyNoticeStore.setState(({ notices }) => {
    if (notice === null) {
      if (!(messageId in notices)) return { notices };
      const next = { ...notices };
      delete next[messageId];
      return { notices: next };
    }
    return { notices: { ...notices, [messageId]: notice } };
  });
}

export function relayWebReplyNotice(messageId: string): RelayWebReplyNotice | undefined {
  return useReplyNoticeStore.getState().notices[messageId];
}

/** For message bubble subscriptions. */
export function useRelayWebReplyNotice(messageId: string): RelayWebReplyNotice | undefined {
  return useReplyNoticeStore((state) => state.notices[messageId]);
}

/**
 * Notice decision at delivery: relay, web switch on this turn (`relayWebOn`, the web intent after the outbound gate), and the delivered request carried no fragment -> web_not_used.
 * Switch off, or a fragment was carried -> null. A failed send does not call this (a failure attaches no notice).
 */
export function relayWebReplyNoticeFor(
  provider: Pick<Provider, 'kind'>,
  delivered: Pick<StreamOptions, 'relayWebOn' | 'relayWebFragment'> | undefined,
): RelayWebReplyNotice | null {
  if (provider.kind !== 'relay' || !delivered?.relayWebOn) return null;
  return delivered.relayWebFragment === undefined ? 'web_not_used' : null;
}
