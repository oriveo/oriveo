import type { Provider } from '@oriveo/shared';
import { COST_EPSILON } from '../../utils/format-utils';
import { normalizeUUID } from '../../utils/id-utils';
import { getEffectiveStatusKind, type EffectiveStatusKind } from './provider-status';

function statusPriority(kind: EffectiveStatusKind): number {
  if (kind === 'connected') return 0;
  if (kind === 'syncing') return 1;
  return 2; // issue and needsKey are both treated as unhealthy
}

/**
 * Spotlight (featured) provider on the providers page (fixture provider-catalog/provider-spotlight.v1.json): only 1 card.
 * Candidates = providers with a billed message this month (in any currency); ordered by this month's billed message count
 * descending, ties broken by this month's USD amount (non-USD is neither converted nor added), then by status
 * connected > syncing > issue (needsKey counts as issue), then by the original list order.
 * With no candidate the status rule applies: take the first by status, and by list order within the same status.
 *
 * @param billedMessageCountByProvider keyed by the providerID after normalizeUUID
 * @param usdCostByProvider this month's USD amount
 */
export function selectSpotlightProvider(
  providers: Provider[],
  billedMessageCountByProvider: Map<string, number>,
  usdCostByProvider: Map<string, number>,
): Provider | null {
  const eligible = providers
    .map((provider, index) => ({
      provider,
      index,
      count: billedMessageCountByProvider.get(normalizeUUID(provider.id)) ?? 0,
      usd: usdCostByProvider.get(provider.id) ?? 0,
      status: statusPriority(getEffectiveStatusKind(provider)),
    }));
  if (eligible.length === 0) return null;
  const candidates = eligible.filter((entry) => entry.count > 0);
  if (candidates.length > 0) {
    candidates.sort((a, b) => {
      if (a.count !== b.count) return b.count - a.count;
      if (Math.abs(a.usd - b.usd) > COST_EPSILON) return b.usd - a.usd;
      if (a.status !== b.status) return a.status - b.status;
      return a.index - b.index;
    });
    return candidates[0].provider;
  }
  const byStatus = [...eligible].sort((a, b) => a.status - b.status || a.index - b.index);
  return byStatus[0].provider;
}
