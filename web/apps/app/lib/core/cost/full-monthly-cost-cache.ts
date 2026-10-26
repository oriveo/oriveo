/**
 * Full current-month cost cache.
 *
 * Background: hydrateStore sets store.conversations[i].messages to [] for lazy loading, so
 * buildMonthlyCostSummary / buildMonthlyCostByProvider computed from the store almost always end
 * up with totalCost close to 0. The providers cost card would then disappear even when local
 * history clearly has costs.
 *
 * This reads all conversations, messages included, straight from IDB, so the local monthly cost
 * is accurate even offline.
 *
 * The module-level cache avoids flicker across route changes: getCachedFullMonthlyCost() is
 * immediately available while refreshFullMonthlyCost() refreshes quietly in the background.
 * Concurrent calls are deduplicated, and a failure keeps the previous cache.
 */

import type { Conversation, Provider } from '@oriveo/shared';
import type { MonthlyCostSummary } from './cost-summary';
import {
  buildDailyNonUsdCostsLast7DaysByProvider,
  buildMonthlyBilledMessageCountByProvider,
  buildMonthlyCostByProvider,
  buildMonthlyCostSummary,
  buildMonthlyNonUsdCostByProvider,
} from './cost-summary';
import type { NonUsdCostTotals } from './cost-currency';
import { getAllConversations } from '../../infra/storage/idb';

export interface FullMonthlyCost {
  summary: MonthlyCostSummary;
  /** Current-month USD cost per providerID. */
  byProvider: Map<string, number>;
  /** Current-month non-USD totals per providerID; providers without any do not appear. */
  nonUsdByProvider: Map<string, NonUsdCostTotals>;
  /** Daily non-USD totals for the last 7 days per providerID (the last slot is today). */
  nonUsdDailyByProvider: Map<string, Array<NonUsdCostTotals | undefined>>;
  /** Current-month billed message count per providerID (normalizeUUID); providers without any do not appear. */
  billedMessageCountByProvider: Map<string, number>;
}

let memoryCache: FullMonthlyCost | null = null;
let inflight: Promise<FullMonthlyCost | null> | null = null;
const listeners = new Set<() => void>();

function notify(): void {
  listeners.forEach((listener) => listener());
}

export function getCachedFullMonthlyCost(): FullMonthlyCost | null {
  return memoryCache;
}

/**
 * IDB supplies the historical conversations; when the store already has messages (the user
 * visited the conversation, or just sent one) the fresher store data wins, so costs are not lost
 * between chat writing to the store and putConversation reaching IDB.
 */
function mergeForCost(idb: Conversation[], storeConversations: Conversation[]): Conversation[] {
  if (storeConversations.length === 0) return idb;
  const storeById = new Map(storeConversations.map((c) => [c.id, c]));
  const idbIds = new Set(idb.map((c) => c.id));
  const merged = idb.map((idbConv) => {
    const storeConv = storeById.get(idbConv.id);
    if (storeConv && storeConv.messages.length > 0) return storeConv;
    return idbConv;
  });
  // New conversations that exist in the store but have not been written to IDB yet must count too.
  for (const storeConv of storeConversations) {
    if (!idbIds.has(storeConv.id) && storeConv.messages.length > 0) {
      merged.push(storeConv);
    }
  }
  return merged;
}

/**
 * Read all conversations from IDB and recompute the current-month cost. Concurrent calls are
 * deduplicated, and a failure keeps the previous cache, so brief hiccups never clear the UI.
 *
 * @param storeConversations Conversations currently in the store, which take precedence over stale IDB data.
 */
export function refreshFullMonthlyCost(
  providers: Provider[],
  storeConversations: Conversation[] = [],
): Promise<FullMonthlyCost | null> {
  if (inflight) return inflight;

  inflight = (async () => {
    try {
      const all = await getAllConversations();
      const merged = mergeForCost(all, storeConversations);
      const next: FullMonthlyCost = {
        summary: buildMonthlyCostSummary(merged, providers),
        byProvider: buildMonthlyCostByProvider(merged),
        nonUsdByProvider: buildMonthlyNonUsdCostByProvider(merged),
        nonUsdDailyByProvider: buildDailyNonUsdCostsLast7DaysByProvider(merged),
        billedMessageCountByProvider: buildMonthlyBilledMessageCountByProvider(merged),
      };
      memoryCache = next;
      notify();
      return next;
    } catch {
      return memoryCache;
    } finally {
      inflight = null;
    }
  })();

  return inflight;
}

export function subscribeFullMonthlyCost(listener: () => void): () => void {
  listeners.add(listener);
  return () => {
    listeners.delete(listener);
  };
}

/** Called by chat operations after writing a new assistant message so the next read sees the current value. */
export function invalidateFullMonthlyCost(): void {
  memoryCache = null;
  notify();
}
